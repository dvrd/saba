package saba_ui_store_test

import rt "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "shared:async/http"
import "shared:surf"

ITEM :: "/api/items/42"
BARRIER :: `{"operationId":"barrier","expectedRevision":1,"title":"Changed"}`
Reply :: struct {
	status: int,
	body:   string,
}

request :: proc(port: string, path: string, payload: string = "", identity := "ana") -> Reply {
	method: http.Method = .PATCH if payload != "" else .GET
	url := fmt.tprintf("http://127.0.0.1:%s%s", port, path)
	headers := [2]http.Header{{"X-Test-Identity", identity}, {"Content-Type", "application/json"}}
	response, err := surf.execute(
		{method = method, url = url, headers = headers[:], body = transmute([]u8)payload},
		{allow_http = true, timeout = 12 * time.Second},
	)
	defer surf.response_destroy(&response)
	if err.kind != .None {
		return {}
	}
	return {int(response.status), strings.clone(string(response.body), context.temp_allocator)}
}
wait_file :: proc(path: string) -> bool {
	deadline := time.tick_add(time.tick_now(), 8 * time.Second)
	for time.tick_since(deadline) < 0 {
		if os.exists(path) {
			return true
		}
		time.sleep(3 * time.Millisecond)
	}
	return false
}
Instance :: struct {
	process: os.Process,
	port:    string,
}
start :: proc(binary, directory, stage: string) -> Instance {
	port_path := fmt.tprintf("%s/port", directory)
	if os.exists(port_path) {
		assert(os.remove(port_path) == nil)
	}
	process, err := os.process_start(
		{command = {binary, directory, stage}, stdout = os.stdout, stderr = os.stderr},
	)
	assert(err == nil)
	if !wait_file(port_path) {
		_ = os.process_kill(process); _, _ = os.process_wait(process)
		panic("receipt server did not publish a port")
	}
	bytes, read := os.read_entire_file(port_path, context.temp_allocator)
	assert(read == nil)
	return {process, string(bytes)}
}
terminate :: proc(instance: Instance) {
	_ = os.process_kill(instance.process)
	_, _ = os.process_wait(instance.process, 5 * time.Second)
}
Concurrent :: struct {
	port, payload: string,
	reply:         Reply,
}
submit :: proc(c: ^Concurrent) {
	r := request(c.port, ITEM, c.payload)
	c.reply = {r.status, strings.clone(r.body, rt.heap_allocator())}
}
launch :: proc(c: ^Concurrent) -> ^thread.Thread {
	t := thread.create_and_start_with_poly_data(c, submit)
	assert(t != nil)
	return t
}
finish :: proc(worker: ^thread.Thread) {
	thread.join(worker); thread.destroy(worker)
}

@(test)
durable_http_receipts :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 100 * time.Second)
	work, err := os.make_directory_temp("", "saba-ui-receipts-*", context.temp_allocator)
	assert(err == nil)
	defer _ = os.remove_all(work)
	binary := fmt.tprintf("%s/fixture", work)
	compiler := os.get_env("ODIN", context.temp_allocator)
	if compiler == "" {
		compiler = "odin"
	}
	collection := fmt.tprintf(
		"-collection:shared=%s",
		os.get_env("SABA_TEST_SHARED", context.temp_allocator),
	)
	built, log, errors, build_error := os.process_exec(
		{
			command = {
				compiler,
				"build",
				"testdata/ui_store/server",
				fmt.tprintf("-out:%s", binary),
				collection,
			},
		},
		context.temp_allocator,
	)
	if !testing.expectf(
		t,
		build_error == nil && built.success,
		"compile fixture: %s%s",
		string(log),
		string(errors),
	) {
		return
	}

	{
		dir := fmt.tprintf("%s/competing", work)
		assert(os.make_directory(dir) == nil)
		process := start(binary, dir, "Reserved")
		defer terminate(process)
		first := Concurrent {
			port    = process.port,
			payload = BARRIER,
		}
		original := launch(&first)
		defer delete(first.reply.body, rt.heap_allocator())
		paused := wait_file(fmt.tprintf("%s/paused", dir))
		if !testing.expect(t, paused, "writer reached durable reservation") {
			finish(original)
			return
		}
		pending := request(process.port, ITEM + "/operations/barrier")
		duplicate := request(process.port, ITEM, BARRIER)
		testing.expect_value(t, pending.status, 202)
		testing.expect_value(t, duplicate.status, 202)
		testing.expect_value(t, request(process.port, "/health").status, 200)
		assert(os.write_entire_file(fmt.tprintf("%s/resume", dir), "go") == nil)
		finish(original)
		testing.expect_value(t, first.reply.status, 200)
		replay := request(process.port, ITEM, BARRIER)
		testing.expect_value(t, replay.body, first.reply.body)
		receipt := request(process.port, ITEM + "/operations/barrier")
		testing.expect_value(
			t,
			receipt.body,
			strings.concatenate(
				{`{"state":"terminal","status":200,"body":`, replay.body, "}"},
				context.temp_allocator,
			),
		)
		reused := request(
			process.port,
			ITEM,
			`{"operationId":"barrier","expectedRevision":2,"title":"Other"}`,
		)
		testing.expect_value(t, reused.status, 409)
		testing.expect(t, strings.contains(reused.body, "operation_id_reused"))
		testing.expect_value(
			t,
			request(process.port, ITEM + "/operations/barrier").body,
			receipt.body,
		)
		for who in ([]string{"bo", "south"}) {
			testing.expect_value(
				t,
				request(process.port, ITEM + "/operations/barrier", "", who).body,
				`{"state":"unknown"}`,
			)
		}
		testing.expect_value(
			t,
			request(process.port, ITEM + "/operations/barrier", "", "revoked").status,
			403,
		)
		testing.expect_value(t, request(process.port, ITEM, "", "anonymous").status, 401)

		bad := `{"operationId":"invalid","expectedRevision":2,"title":""}`
		invalid := request(process.port, ITEM, bad)
		testing.expect_value(t, invalid.status, 422)
		left := Concurrent {
			port    = process.port,
			payload = `{"operationId":"left","expectedRevision":2,"title":"Left"}`,
		}
		right := Concurrent {
			port    = process.port,
			payload = `{"operationId":"right","expectedRevision":2,"title":"Right"}`,
		}
		w1, w2 := launch(&left), launch(&right)
		finish(w1); finish(w2)
		defer delete(left.reply.body, rt.heap_allocator())
		defer delete(right.reply.body, rt.heap_allocator())
		testing.expect(
			t,
			(left.reply.status == 200 && right.reply.status == 409) ||
			(right.reply.status == 200 && left.reply.status == 409),
			"exactly one writer may advance a revision",
		)
		loser := &left if left.reply.status == 409 else &right
		advance := request(
			process.port,
			ITEM,
			`{"operationId":"next","expectedRevision":3,"title":"Fourth"}`,
		)
		testing.expect_value(t, advance.status, 200)
		testing.expect_value(t, request(process.port, ITEM, bad), invalid)
		testing.expect_value(t, request(process.port, ITEM, loser.payload), loser.reply)
		testing.expect_value(
			t,
			request(process.port, ITEM).body,
			`{"id":"42","title":"Fourth","revision":4}`,
		)
	}

	for stage in ([]string{"Reserved", "Writing", "Committed"}) {
		dir := fmt.tprintf("%s/%s", work, stage)
		assert(os.make_directory(dir) == nil)
		writer := start(binary, dir, stage)
		send := Concurrent {
			port    = writer.port,
			payload = BARRIER,
		}
		client := launch(&send)
		paused := wait_file(fmt.tprintf("%s/paused", dir))
		terminate(writer); finish(client)
		delete(send.reply.body, rt.heap_allocator())
		if !testing.expectf(t, paused, "reached %s before terminating process", stage) {
			continue
		}
		restarted := start(binary, dir, "none")
		item := request(restarted.port, ITEM)
		expected := `{"id":"42","title":"Changed","revision":2}`
		testing.expect_value(t, item.body, expected)
		testing.expect_value(
			t,
			request(restarted.port, ITEM + "/operations/barrier").body,
			strings.concatenate(
				{`{"state":"terminal","status":200,"body":`, expected, "}"},
				context.temp_allocator,
			),
		)
		testing.expect_value(t, request(restarted.port, ITEM, BARRIER).body, expected)
		terminate(restarted)
	}
}
