package main

// The native client over async's HTTP/3 exchange. surf refuses request
// trailers, so the exchange is driven directly: one task per request on a
// short-lived runtime, and the main thread waits for each to finish.

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import async "shared:async"
import http "shared:async/http"

// One runtime and one pool for every request, so the requests share a
// connection.
Client :: struct {
	runtime: ^async.Runtime,
	pool:    ^async.H3_Pool,
	roots:   ^async.Root_Pool,
	port:    int,
}

client_open :: proc(c: ^Client, port: int, roots: ^async.Root_Pool) {
	c.runtime = new(async.Runtime, runtime.heap_allocator())
	assert(async.init(c.runtime, {workers = 1, task_capacity = 8, io_capacity = 16}).kind == .None)
	assert(async.start(c.runtime).kind == .None)
	c.pool = new(async.H3_Pool, runtime.heap_allocator())
	assert(async.h3_pool_init(c.pool, {allocator = runtime.heap_allocator()}).kind == .None)
	c.port, c.roots = port, roots
}

client_close :: proc(c: ^Client) {
	assert(async.wait_idle(c.runtime).kind == .None)
	assert(async.h3_pool_destroy(c.pool).kind == .None)
	async.shutdown(c.runtime)
	assert(async.join(c.runtime).kind == .None)
	assert(async.destroy(c.runtime).kind == .None)
	free(c.pool, runtime.heap_allocator())
	free(c.runtime, runtime.heap_allocator())
}

Post :: struct {
	task:              async.Task,
	client:            ^Client,
	url:               string,
	body:              []u8,
	trailers:          []http.Header,
	x:                 async.H3_Exchange,
	begun, sent:       bool,
	written:           int,
	headed:            bool,
	status:            int,
	// A response trailer merged into the head would show up here.
	merged:            bool,
	response:          [dynamic]u8,
	response_trailers: [dynamic]http.Header,
	error:             async.Error,
	done:              sync.Sema,
}

post_resume :: proc(data: rawptr) -> async.Resume_Result {
	p := cast(^Post)data
	if !p.begun {
		request := async.Http_Request {
			method = .POST,
			url    = p.url,
		}
		dial := async.Dial_Config {
			host     = "127.0.0.1",
			port     = p.client.port,
			deadline = async.deadline_after(p.client.runtime, 5 * time.Second),
			tls      = async.Dial_TLS{server_name = "localhost", roots = p.client.roots},
		}
		if error := async.h3_exchange_begin(p.client.pool, &p.x, &p.task, &request, i64(len(p.body)), dial); error.kind != .None {
			p.error = error
			return .Done
		}
		p.begun = true
	}
	for !p.sent && p.written < len(p.body) {
		n, error := async.h3_exchange_write(&p.x, p.body[p.written:])
		p.written += n
		if error.kind == .Pending || n == 0 && error.kind == .None {
			return async.h3_exchange_resume(&p.x)
		}
		if error.kind != .None {
			return post_end(p, error)
		}
	}
	if !p.sent {
		if error := async.h3_exchange_finish(&p.x, p.trailers); error.kind != .None {
			if error.kind == .Pending {
				return async.h3_exchange_resume(&p.x)
			}
			return post_end(p, error)
		}
		p.sent = true
	}
	if ended, result := post_take(p); ended {
		return result
	}
	result := async.h3_exchange_resume(&p.x)
	if result == .Done {
		if ended, taken := post_take(p); ended {
			return taken
		}
		return post_end(p, {kind = .Closed})
	}

	return result
}

// Takes the head and the body that arrived. True once the exchange ended.
post_take :: proc(p: ^Post) -> (bool, async.Resume_Result) {
	if !p.headed {
		head, error := async.h3_exchange_head(&p.x)
		if error.kind == .None {
			p.headed = true
			p.status = head.status
			for header in head.headers {
				if strings.equal_fold(header.name, "x-response-checksum") {
					p.merged = true
				}
			}
		} else if error.kind != .Pending {
			return true, post_end(p, error)
		}
	}
	if p.headed {
		buffer: [4096]u8
		for {
			n, error := async.h3_exchange_read(&p.x, buffer[:])
			if n > 0 {
				append(&p.response, ..buffer[:n])
				continue
			}
			if error.kind == .Peer_Closed {
				for trailer in async.h3_exchange_trailers(&p.x) {
					append(&p.response_trailers, http.Header{strings.clone(trailer.name), strings.clone(trailer.value)})
				}
				return true, post_end(p, {})
			}
			if error.kind != .Pending && error.kind != .None {
				return true, post_end(p, error)
			}
			break
		}
	}

	return false, .Waiting
}

post_end :: proc(p: ^Post, error: async.Error) -> async.Resume_Result {
	p.error = error
	async.h3_exchange_destroy(&p.x)

	return .Done
}

// POSTs body with trailers and waits for the whole response. Free the result
// with post_destroy.
post :: proc(c: ^Client, url: string, body: []u8, trailers: []http.Header) -> ^Post {
	p := new(Post, runtime.heap_allocator())
	p.client, p.url, p.body, p.trailers = c, url, body, trailers
	p.task = {
		data    = p,
		resume  = post_resume,
		on_done = proc(data: rawptr) {sync.post(&(cast(^Post)data).done)},
	}
	assert(async.spawn(c.runtime, &p.task).kind == .None)
	if !sync.sema_wait_with_timeout(&p.done, 10 * time.Second) {
		panic("the exchange did not finish in time")
	}

	return p
}

post_trailer :: proc(p: ^Post, name: string) -> (string, bool) {
	for trailer in p.response_trailers {
		if strings.equal_fold(trailer.name, name) {
			return trailer.value, true
		}
	}

	return "", false
}

post_destroy :: proc(p: ^Post) {
	for trailer in p.response_trailers {
		delete(trailer.name)
		delete(trailer.value)
	}
	delete(p.response_trailers)
	delete(p.response)
	free(p, runtime.heap_allocator())
}
