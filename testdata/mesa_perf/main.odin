package main

import server "../../src/core"
import offload "../../src/offload"
import modules "../../src/modules"
import pages "../../src/pages"
import rt "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import pool "shared:async/offload"
import db "shared:kakunou"

// Launch from the checkout root. All trials share this loopback server and reset
// its synthetic state between trials, outside the measured windows.
State :: struct {
	database: ^db.SQLite_DB,
	port:     int,
	control:  server.Server_Control,
	served:   bool,
	lane:     pool.Pool,
	assets:   map[string]Asset,
	generated: pages.Page_Cache,
}
Asset :: struct {
	body, mime: string,
}
Operation :: enum {
	Detail,
	All,
	Open,
	Marked,
	Save,
	Reset,
}
Job :: struct {
	state:        ^State,
	operation:    Operation,
	fragment:     bool,
	request_body: []u8,
	status:       server.HTTP_Status,
	result:       string,
}
Submission :: struct {
	operationId:      string,
	expectedRevision: i64,
	title:            string,
}
Receipt :: struct {
	matches, status: i64,
	reply:           string,
}

SCHEMA :: `PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
CREATE TABLE IF NOT EXISTS bench_items(id INTEGER PRIMARY KEY, title TEXT NOT NULL, revision INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS bench_receipts(operation TEXT PRIMARY KEY, payload BLOB NOT NULL, status INTEGER NOT NULL, reply TEXT NOT NULL);
WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM numbers WHERE n<1000)
INSERT OR IGNORE INTO bench_items SELECT n, 'Item '||n, 1 FROM numbers;`
RESET :: `BEGIN IMMEDIATE;
UPDATE bench_items SET title='Item 42', revision=1 WHERE id=42;
DELETE FROM bench_receipts;
COMMIT;`
DETAIL :: "SELECT json_object('id',CAST(id AS TEXT),'title',title,'revision',revision) FROM bench_items WHERE id=42"
LIST_BEGIN :: "SELECT json_group_array(json_object('id',CAST(id AS TEXT),'title',title,'revision',revision)) FROM (SELECT id,title,revision FROM bench_items "
LIST_END :: " ORDER BY (id=42) DESC,id)"

decode_string :: proc(statement: ^db.SQLite_Statement, output: ^string) -> db.Database_Error {
	value, err := db.column_text(statement, 0, context.temp_allocator)
	output^ = value
	return err
}
read_string :: proc(state: ^State, sql: cstring) -> (string, bool) {
	value: string
	found, err := db.query_one(state.database, sql, nil, &value, decode_string)
	return value, found && err.kind == .None
}
decode_receipt :: proc(statement: ^db.SQLite_Statement, output: ^Receipt) -> db.Database_Error {
	err: db.Database_Error
	output.matches, err = db.column_int(statement, 0)
	if err.kind != .None {
		return err
	}
	output.status, err = db.column_int(statement, 1)
	if err.kind != .None {
		return err
	}
	output.reply, err = db.column_text(statement, 2, context.temp_allocator)
	return err
}

save :: proc(job: ^Job) -> (status: server.HTTP_Status, body: string) {
	variable: Submission
	if json.unmarshal(job.request_body, &variable, allocator = context.temp_allocator) != nil ||
	   len(variable.operationId) == 0 ||
	   len(variable.operationId) > 128 ||
	   strings.contains(variable.operationId, "\x00") ||
	   strings.contains(variable.title, "\x00") {
		return .Bad_Request, `{"error":"invalid submission"}`
	}
	database := job.state.database
	id := strings.clone_to_cstring(variable.operationId, context.temp_allocator)
	// In autocommit mode this is a durable reservation. The next transaction
	// serializes competing deliveries and commits the write and receipt together.
	reserved := db.insert(
		database,
		"INSERT OR IGNORE INTO bench_receipts VALUES(?,?,0,'')",
		{id, job.request_body},
	)
	if reserved.kind != .None || db.begin_immediate(database).kind != .None {
		return .Internal_Server_Error, `{"error":"reservation failed"}`
	}
	committed := false
	defer if !committed {
		db.rollback_transaction(database)
	}
	receipt: Receipt
	found, err := db.query_one(
		database,
		"SELECT payload=?,status,reply FROM bench_receipts WHERE operation=?",
		{job.request_body, id},
		&receipt,
		decode_receipt,
	)
	if !found || err.kind != .None {
		return .Internal_Server_Error, `{"error":"receipt missing"}`
	}
	if receipt.matches == 0 {
		return .Conflict, `{"code":"operation_id_reused"}`
	}
	if receipt.status != 0 {
		return server.HTTP_Status(receipt.status), receipt.reply
	}

	if len(strings.trim_space(variable.title)) == 0 {
		status, body = .Unprocessable_Content, `{"fieldErrors":{"title":"Title is required"}}`
	} else {
		title := strings.clone_to_cstring(variable.title, context.temp_allocator)
		change := db.insert(
			database,
			"UPDATE bench_items SET title=?,revision=revision+1 WHERE id=42 AND revision=?",
			{title, variable.expectedRevision},
		)
		if change.kind != .None {
			return .Internal_Server_Error, `{"error":"update failed"}`
		}
		status = .OK if db.sqlite3_changes(database) == 1 else .Conflict
		ok: bool
		body, ok = read_string(job.state, DETAIL)
		if !ok {
			return .Internal_Server_Error, `{"error":"item missing"}`
		}
	}
	record := db.insert(
		database,
		"UPDATE bench_receipts SET status=?,reply=? WHERE operation=?",
		{i64(status), strings.clone_to_cstring(body, context.temp_allocator), id},
	)
	if record.kind != .None {
		return .Internal_Server_Error, `{"error":"receipt failed"}`
	}
	// commit_transaction consumes the connection's transaction hold even on error.
	committed = true
	if db.commit_transaction(database).kind != .None {
		return .Internal_Server_Error, `{"error":"commit failed"}`
	}
	return
}

run :: proc(data: rawptr, _: pool.Work_Context) -> bool {
	job := cast(^Job)data
	body: string
	status: server.HTTP_Status = .OK
	switch job.operation {
	case .Save:
		if job.fragment {
			encoded, ok := decode_fragment_submission(job.request_body)
			if !ok {
				status, body = .Bad_Request, "Invalid form submission"
			} else {
				// The JSON and HTML endpoints use exactly the same durable operation.
				form_job := job^
				form_job.request_body = encoded
				status, body = save(&form_job)
				if status == .OK {
					body = ""
				}
			}
		} else {
			status, body = save(job)
		}
	case .Reset:
		if db.execute_sql(job.state.database, RESET).kind != .None {
			return false
		}
		body = "{}"
	case .All, .Open, .Marked, .Detail:
		if job.fragment {
			ok: bool
			body, ok = render_fragment(job.state, job.operation)
			if !ok {
				return false
			}
			break
		}
		sql: cstring
		#partial switch job.operation {
		case .All:
			sql = LIST_BEGIN + LIST_END
		case .Open:
			sql = LIST_BEGIN + "WHERE id%2=0" + LIST_END
		case .Marked:
			sql = LIST_BEGIN + "WHERE substr(title,1,1)='!'" + LIST_END
		case .Detail:
			sql = DETAIL
		}
		ok: bool
		body, ok = read_string(job.state, sql)
		if !ok {
			return false
		}
	}
	job.status = status
	job.result = strings.clone(body, rt.heap_allocator())
	return true
}
drop :: proc(data: rawptr) {
	job := cast(^Job)data
	delete(job.request_body, rt.heap_allocator())
	delete(job.result, rt.heap_allocator())
	free(job, rt.heap_allocator())
}
JSON_HEADERS := [2]server.Header {
	{"Content-Type", "application/json"},
	{"Cache-Control", "no-store"},
}
build :: proc(data: rawptr, allocator: mem.Allocator) -> (server.Response, bool) {
	job := cast(^Job)data
	body, err := strings.clone(job.result, allocator)
	headers := JSON_HEADERS[:]
	if job.fragment {
		headers = FRAGMENT_HEADERS[:]
		if job.operation == .Save && job.status == .OK {
			headers = FRAGMENT_SAVED_HEADERS[:]
		}
	}
	return {status = job.status, headers = headers, body = transmute([]u8)body}, err == nil
}
route :: proc(data: rawptr, _: ^server.Connection, req: ^server.Request) -> server.Response {
	state := cast(^State)data
	if req.path == "/__bench/stop" && req.method == "POST" {
		_ = server.drain_server(&state.control, time.Second)
		return {status = .OK}
	}
	if req.method == "GET" {
		if req.path == "/__bench/ready" {
			return {status = .OK}
		}
		if state.generated.build.id != "" {
			if response, matched := pages.serve_build_asset(req, state.generated); matched {
				return response
			}
			if response, matched := pages.serve_prepared_pages(req, state.generated, false); matched {
				return response
			}
		}
		key := req.path
		if key == "/" {
			key = "current"
			if strings.has_prefix(req.query, "mode=") {
				key = req.query[len("mode="):]
			}
			if strings.contains(key, "/") {
				return {status = .Not_Found}
			}
		}
		if asset, ok := state.assets[key]; ok {
			return server.make_response(
				req,
				.OK,
				{{"Content-Type", asset.mime}, {"Cache-Control", "no-cache"}},
				transmute([]u8)asset.body,
			)
		}
	}
	operation: Operation
	fragment := strings.has_prefix(req.path, "/fragments/")
	api_path := req.path
	if fragment {
		api_path = req.path[len("/fragments"):]
	} else if strings.has_prefix(req.path, "/api/") {
		api_path = req.path[len("/api"):]
	} else if req.path != "/__bench/reset" {
		return {status = .Not_Found}
	}
	switch api_path {
	case "/items/42":
		if req.method != "GET" && req.method != "PATCH" {
			return {status = .Method_Not_Allowed}
		}
		operation = .Save if req.method == "PATCH" else .Detail
	case "/__bench/reset":
		if req.path != "/__bench/reset" {
			return {status = .Not_Found}
		}
		if req.method != "POST" {
			return {status = .Method_Not_Allowed}
		}
		operation = .Reset
	case "/lists/all", "/lists/open", "/lists/marked":
		if req.method != "GET" {
			return {status = .Method_Not_Allowed}
		}
		switch api_path {
		case "/lists/all":
			operation = .All
		case "/lists/open":
			operation = .Open
		case "/lists/marked":
			operation = .Marked
		}
	case:
		return {status = .Not_Found}
	}

	job := new(Job, rt.heap_allocator())
	job.state, job.operation, job.fragment = state, operation, fragment
	if operation == .Save {
		job.request_body = make([]u8, len(req.body), rt.heap_allocator())
		copy(job.request_body, req.body)
	}
	work := pool.Work{job, run, drop}
	response, ok := offload.response(&state.lane, &work, build, 10 * time.Second)
	if !ok {
		drop(job); return {status = .Service_Unavailable}
	}
	return response
}

load_assets :: proc(state: ^State) {
	state.assets = make(map[string]Asset)
	for file in ([]struct {
			path, url, mime: string,
		} {
			{"testdata/mesa_perf/index.html", "planned", "text/html; charset=utf-8"},
			{"testdata/mesa_perf/entry.js", "/entry.js", "text/javascript"},
			{"testdata/mesa_perf/planned.js", "/planned.js", "text/javascript"},
			{"testdata/mesa_perf/app.js", "/app.js", "text/javascript"},
			{"testdata/mesa_perf/style.css", "/style.css", "text/css"},
			{"src/modules/dom.js", "/__saba/dom.js", "text/javascript"},
		}) {
		bytes, err := os.read_entire_file(file.path, context.allocator)
		assert(err == nil, file.path)
		state.assets[file.url] = Asset{string(bytes), file.mime}
	}
	html := state.assets["planned"].body
	start := strings.index(html, "<!--screen-->")
	end := strings.index(html, "<!--/screen-->")
	assert(start >= 0 && end > start)
	current := strings.concatenate({html[:start], html[end + len("<!--/screen-->"):]})
	replaced: bool
	current, replaced = strings.replace_all(current, `src="/planned.js"`, `src="/entry.js"`)
	assert(replaced)
	state.assets["current"] = {current, "text/html; charset=utf-8"}
	load_framework_assets(state, html, current)
}

main :: proc() {
	if len(os.args) > 1 && os.args[1] == "bench" {
		os.exit(run_benchmark(os.args[2:]))
	}
	assert(len(os.args) == 4 || (len(os.args) == 5 && (os.args[4] == "--generated" || os.args[4] == "--windowed")),
		"Usage: mesa-perf PORT DB_PATH READY_FILE [--generated|--windowed] (from the checkout root)")
	port, ok := strconv.parse_int(os.args[1])
	assert(ok && port >= 0 && port <= 65535)
	state: State
	state.port = port
	load_assets(&state)
	if len(os.args) == 5 {
		mounts, mounted := modules.prepare_module_mounts(
			{{directory = "testdata/mesa_perf/lists", prefix = "/bench/"}}, false, context.allocator)
		assert(mounted, "Could not compile the benchmark list modules")
		// Both variants compile the same editor. Its relative list import resolves
		// beside the selected module URL to choose dense or windowed rendering.
		routes := []pages.Compiled_Page{
			{path = "/generated", variants = {{language = "en",
				source_file = "testdata/mesa_perf/generated.jsx", module_url = "/bench/full/editor.js",
				recovery_label = "Reload"}}},
			{path = "/windowed", variants = {{language = "en",
				source_file = "testdata/mesa_perf/generated.jsx", module_url = "/bench/windowed/editor.js",
				recovery_label = "Reload"}}},
		}
		if os.args[4] == "--generated" { routes = routes[:1] }
		state.generated, ok = pages.prepare_pages({templates = {pages = routes}}, false, context.allocator, mounts)
		assert(ok, "Could not compile the authored benchmark page")
	}
	assert(
		db.open(&state.database, strings.clone_to_cstring(os.args[2], context.temp_allocator)).kind ==
		.None,
	)
	defer db.close(state.database)
	assert(db.execute_sql(state.database, SCHEMA).kind == .None)
	assert(pool.init(&state.lane, {workers = 4, capacity = 32}) == .None)
	defer {pool.shutdown(&state.lane); _ = pool.join(&state.lane); _ = pool.destroy(&state.lane)}
	worker := thread.create_and_start_with_poly_data(&state, proc(s: ^State) {
		s.served = server.serve(
			{
				address = "127.0.0.1",
				port = s.port,
				handler = route,
				handler_data = s,
				control = &s.control,
				workers = 2,
				max_connections = 64,
				keep_alive = {enabled = true},
			},
		)
	})
	assert(worker != nil)
	defer thread.destroy(worker)
	started := time.tick_now()
	for {
		endpoint, ready := server.server_endpoint(&state.control)
		if ready {
			path := os.args[3]
			pending := fmt.tprintf("%s.pending", path)
			assert(os.write_entire_file(pending, fmt.tprintf("%d", endpoint.port)) == nil)
			assert(os.rename(pending, path) == nil)
			break
		}
		assert(
			!thread.is_done(worker) && time.tick_since(started) < 10 * time.Second,
			"Server did not start",
		)
		time.sleep(time.Millisecond)
	}
	thread.join(worker)
	assert(state.served)
}
