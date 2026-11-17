package saba_assets

import core "../core"
import exchange "../../http/exchange"
import "core:mem"
import "core:os"
import "core:testing"

@(test)
file_ranges_validators_and_head_policy :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)
	asset_test_write(directory, "ok.txt", "0123456789")
	asset_test_write(directory, "empty.txt", "")
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	request := Request {
		method    = "GET",
		allocator = mem.dynamic_arena_allocator(&arena),
	}

	for item in ([]struct {
			method:  string,
			headers: []Header,
			status:  core.HTTP_Status,
			length:  i64,
		} {
			{"GET", nil, .OK, 10},
			{"GET", {{"Range", "bytes=2-4"}}, .Partial_Content, 3},
			{"GET", {{"Range", "bytes=11-"}}, .Range_Not_Satisfiable, 0},
			{"GET", {{"Range", "bytes=2-4,6-8"}}, .OK, 10},
			{"GET", {{"Range", "bytes=2-4"}, {"Range", "bytes=5-6"}}, .OK, 10},
			{"GET", {{"Range", "bytes=2-4"}, {"If-Range", `"generation"`}}, .Partial_Content, 3},
			{"GET", {{"Range", "bytes=2-4"}, {"If-Range", `W/"generation"`}}, .OK, 10},
			{"GET", {{"Range", "bytes=2-4"}, {"If-Range", `"old"`}}, .OK, 10},
			{"GET", {{"Range", "bytes=2-4"}, {"If-Range", `"generation"`}, {"If-Range", `"generation"`}}, .OK, 10},
			{"GET", {{"Range", "bytes=2-4"}, {"If-None-Match", `W/"generation"`}}, .Not_Modified, 0},
			{"HEAD", {{"Range", "bytes=2-4"}}, .OK, 10},
			{"HEAD", {{"If-None-Match", `"generation"`}}, .Not_Modified, 0},
		}) {
		request.method = item.method
		request.headers = item.headers
		response := serve_file_stream(&request, directory, "ok.txt", {etag = `"generation"`})
		testing.expect_value(t, response.status, item.status)
		testing.expect_value(t, response.stream.content_length, item.length)
		core.discard_response(&response)
		core.discard_response(&response)
	}

	request.method = "GET"
	request.headers = nil
	empty := serve_file_stream(&request, directory, "empty.txt")
	testing.expect_value(t, empty.status, .OK)
	testing.expect_value(t, empty.stream.content_length, 0)
	core.discard_response(&empty)
	request.headers = {{"Range", "bytes=0-"}}
	unsatisfied := serve_file_stream(&request, directory, "empty.txt")
	testing.expect_value(t, unsatisfied.status, .Range_Not_Satisfiable)
	testing.expect_value(t, unsatisfied.headers[0].value, "bytes */0")

	for path in ([]string{"../ok.txt", "%2e%2e/ok.txt", "%2fetc/passwd", ".hidden", "private.jsx", "absent.txt"}) {
		response := serve_file_stream(&request, directory, path)
		testing.expect_value(t, response.status, .Not_Found)
	}

	response := serve_file_stream(&request, directory, "ok.txt", {max_file_bytes = 9})
	testing.expect_value(t, response.status, .Internal_Server_Error)
	response = serve_file_stream(&request, directory, "ok.txt", {etag = `W/"weak"`})
	testing.expect_value(t, response.status, .Internal_Server_Error)

	for config in ([]File_Stream_Config {
			{max_file_bytes = -1},
			{chunk_bytes = -1},
			{chunk_bytes = 2 * mem.Megabyte},
			{timeout = -1},
		}) {
		response = serve_file_stream(&request, directory, "ok.txt", config)
		testing.expect_value(t, response.status, .Internal_Server_Error)
	}
}

@(test)
file_producer_reuses_one_bounded_grant_and_cleans_failures :: proc(t: ^testing.T) {
	directory := asset_test_directory()
	defer delete(directory)
	defer os.remove_all(directory)
	asset_test_write(directory, "ok.txt", "0123456789")
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	request := Request {
		method    = "GET",
		allocator = mem.dynamic_arena_allocator(&arena),
		headers   = {{"Range", "bytes=2-8"}},
	}

	// Fail the owner or lazy buffer allocation, as well as the successful path.
	for fail_at in 0 ..= 2 {
		state := Asset_Test_Allocator {
			backing = context.allocator,
			fail_at = fail_at,
		}

		allocator := mem.Allocator{asset_test_allocate, &state}
		response := serve_file_stream(&request, directory, "ok.txt", {chunk_bytes = 3, allocator = allocator})

		if fail_at == 1 {
			testing.expect_value(t, response.status, .Internal_Server_Error)
		} else {
			assert(response.status == .Partial_Content)
			transfer: exchange.Exchange
			assert(
				exchange.init(&transfer, .GET, {chunk_capacity = 1, max_retained_bytes = 3}, context.allocator).kind ==
				.None,
			)
			assert(exchange.respond(&transfer, {status = 206, content_length = 7}).kind == .None)
			actual: [7]u8
			at := 0

			for {
				io := core.Stream_IO {
					_exchange = &transfer,
				}

				step := response.stream.next(response.stream.data, &io)

				if fail_at == 2 {
					testing.expect_value(t, step, .Failed)
					break
				}

				if step == .Done {
					break
				}
				assert(step == .Chunk)
				body, valid := exchange.body(&transfer)
				assert(valid)
				copy(actual[at:], body)
				at += len(body)
				assert(exchange.release_body(&transfer))
			}

			if fail_at == 0 {
				testing.expect_value(t, string(actual[:]), "2345678")
				testing.expect_value(t, state.calls, 2)
				testing.expect_value(t, state.peak, size_of(File_Producer) + 3)
			}

			exchange.destroy(&transfer)
			core.discard_response(&response)
			core.discard_response(&response)
		}

		testing.expect_value(t, state.live, 0)
	}

	// Unexpected shrink and refused admission release even an unaccepted grant.
	for shrink in ([]bool{false, true}) {
		asset_test_write(directory, "ok.txt", "0123456789")
		state := Asset_Test_Allocator {
			backing = context.allocator,
		}

		response := serve_file_stream(
			&request,
			directory,
			"ok.txt",
			{chunk_bytes = 3, allocator = {asset_test_allocate, &state}},
		)
		if shrink {
			asset_test_write(directory, "ok.txt", "0")
		}
		transfer: exchange.Exchange
		assert(exchange.init(&transfer, .GET, {max_retained_bytes = 1}, context.allocator).kind == .None)
		assert(exchange.respond(&transfer, {status = 206, content_length = 7}).kind == .None)
		io := core.Stream_IO {
			_exchange = &transfer,
		}

		testing.expect_value(t, response.stream.next(response.stream.data, &io), .Failed)
		exchange.destroy(&transfer)
		core.discard_response(&response)
		testing.expect_value(t, state.live, 0)
	}
}
