package ui_store

import rt "base:runtime"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:time"
import pool "shared:async/offload"
import db "shared:kakunou"
import server "shared:saba/core"
import offload "shared:saba/offload"

// This application fixture has one editable item per tenant. The application
// supplies both the live request identity and the durable write-access check.
Access :: enum {
	Signed_Out,
	Forbidden,
	Allowed,
}
Identity :: struct {
	tenant, caller: string,
	access:         Access,
}
Authorize :: #type proc(req: ^server.Request) -> Identity
May_Write :: #type proc(tenant, caller: string) -> bool
Stage :: enum {
	Reserved,
	Writing,
	Committed,
}
Checkpoint :: #type proc(data: rawptr, stage: Stage, operation: string)
State :: struct {
	database:        ^db.SQLite_DB,
	lane:            pool.Pool,
	authorize:       Authorize,
	may_write:       May_Write,
	checkpoint:      Checkpoint,
	checkpoint_data: rawptr,
}

SCHEMA :: `PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
CREATE TABLE IF NOT EXISTS items(tenant TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL,
 revision INTEGER NOT NULL, PRIMARY KEY(tenant,id));
CREATE TABLE IF NOT EXISTS operations(tenant TEXT NOT NULL, caller TEXT NOT NULL,
 item TEXT NOT NULL, operation TEXT NOT NULL, schema INTEGER NOT NULL, method TEXT NOT NULL,
 target TEXT NOT NULL, payload BLOB NOT NULL, status INTEGER NOT NULL DEFAULT 0,
 reply TEXT NOT NULL DEFAULT '', PRIMARY KEY(tenant,caller,item,operation));`
DETAIL :: "SELECT json_object('id',id,'title',title,'revision',revision) FROM items WHERE tenant=? AND id='42'"
PENDING :: "SELECT tenant,caller,operation,payload FROM operations WHERE status=0 AND schema=1 ORDER BY rowid LIMIT 1"
RECEIPT :: "SELECT payload=?,status,reply FROM operations WHERE tenant=? AND caller=? AND item='42' AND operation=?"
LOOKUP :: `SELECT CASE WHEN status=0 THEN '{"state":"pending"}' ELSE
 json_object('state','terminal','status',status,'body',json(reply)) END
 FROM operations WHERE tenant=? AND caller=? AND item='42' AND operation=?`
HEADERS := [2]server.Header{{"Content-Type", "application/json"}, {"Cache-Control", "no-store"}}
Result :: struct {
	status: server.HTTP_Status,
	body:   string,
}
failure :: proc() -> Result {return {.Internal_Server_Error, `{"error":"storage_unavailable"}`}}
forbidden :: proc() -> Result {return {.Forbidden, `{"error":"forbidden"}`}}
c :: proc(value: string) -> cstring {
	return strings.clone_to_cstring(value, context.temp_allocator)
}

open :: proc(s: ^State, path: string, authorize: Authorize, may_write: May_Write) -> bool {
	if authorize == nil || may_write == nil {
		return false
	}
	if db.open(&s.database, c(path)).kind != .None {
		return false
	}
	s.authorize, s.may_write = authorize, may_write
	if db.execute_sql(s.database, SCHEMA).kind != .None ||
	   !recover(s) ||
	   pool.init(&s.lane, {workers = 4, capacity = 32}) != .None {
		db.close(s.database)
		s.database = nil
		return false
	}
	return true
}
close :: proc(s: ^State) {
	pool.shutdown(&s.lane)
	_ = pool.join(&s.lane)
	_ = pool.destroy(&s.lane)
	db.close(s.database)
	s.database = nil
}
seed :: proc(s: ^State, tenant: string) -> bool {
	return(
		db.insert(s.database, "INSERT OR IGNORE INTO items VALUES(?,'42','Lamp',1)", {c(tenant)}).kind ==
		.None \
	)
}
text_column :: proc(stmt: ^db.SQLite_Statement, out: ^string) -> db.Database_Error {
	err: db.Database_Error
	out^, err = db.column_text(stmt, 0, context.temp_allocator)
	return err
}

Submission :: struct {
	operationId:      string,
	title:            string,
	expectedRevision: i64,
}
Operation_Key :: struct {
	operationId: string,
}
Receipt_Record :: struct {
	matches, status: i64,
	reply:           string,
}
receipt_column :: proc(stmt: ^db.SQLite_Statement, out: ^Receipt_Record) -> db.Database_Error {
	err: db.Database_Error
	out.matches, err = db.column_int(stmt, 0); if err.kind != .None {
		return err
	}
	out.status, err = db.column_int(stmt, 1); if err.kind != .None {
		return err
	}
	out.reply, err = db.column_text(stmt, 2, context.temp_allocator)
	return err
}
Pending_Record :: struct {
	tenant, caller, operation: string,
	payload:                   []u8,
}
pending_column :: proc(stmt: ^db.SQLite_Statement, out: ^Pending_Record) -> db.Database_Error {
	err: db.Database_Error
	out.tenant, err = db.column_text(stmt, 0, context.temp_allocator); if err.kind != .None {
		return err
	}
	out.caller, err = db.column_text(stmt, 1, context.temp_allocator); if err.kind != .None {
		return err
	}
	out.operation, err = db.column_text(stmt, 2, context.temp_allocator); if err.kind != .None {
		return err
	}
	out.payload, err = db.column_blob(stmt, 3, context.temp_allocator)
	return err
}
checkpoint :: proc(s: ^State, stage: Stage, id: string) {
	if s.checkpoint != nil {
		s.checkpoint(s.checkpoint_data, stage, id)
	}
}
detail :: proc(s: ^State, tenant: string) -> Result {
	title: string
	found, err := db.query_one(s.database, DETAIL, {c(tenant)}, &title, text_column)
	if err.kind != .None {
		return failure()
	}
	if !found {
		return {.Not_Found, `{"error":"not_found"}`}
	}
	return {.OK, title}
}
terminal :: proc(s: ^State, op: Pending_Record) -> Result {
	if db.begin_immediate(s.database).kind != .None {
		return failure()
	}
	ended := false
	defer if !ended {
		db.rollback_transaction(s.database)
	}
	t, a, id := c(op.tenant), c(op.caller), c(op.operation)
	receipt: Receipt_Record
	found, err := db.query_one(
		s.database,
		RECEIPT,
		{op.payload, t, a, id},
		&receipt,
		receipt_column,
	)
	if !found || err.kind != .None || receipt.matches == 0 {
		return failure()
	}
	if receipt.status != 0 {
		return {server.HTTP_Status(receipt.status), receipt.reply}
	}
	result := forbidden()
	if s.may_write(op.tenant, op.caller) {
		submission: Submission
		if json.unmarshal(op.payload, &submission, allocator = context.temp_allocator) != nil ||
		   submission.expectedRevision < 1 ||
		   strings.contains(submission.title, "\x00") ||
		   len(strings.trim_space(submission.title)) == 0 {
			result = {
				.Unprocessable_Content,
				`{"fieldErrors":{"title":"A title and positive base revision are required."}}`,
			}
		} else {
			written := db.insert(
				s.database,
				"UPDATE items SET title=?,revision=revision+1 WHERE tenant=? AND id='42' AND revision=?",
				{c(submission.title), t, submission.expectedRevision},
			)
			if written.kind != .None {
				return failure()
			}
			changed := db.sqlite3_changes(s.database) == 1
			result = detail(s, op.tenant)
			if result.status == .Internal_Server_Error {
				return result
			}
			if result.status == .OK && !changed {
				result.status = .Conflict
			}
		}
	}
	checkpoint(s, .Writing, op.operation)
	err = db.insert(
		s.database,
		"UPDATE operations SET status=?,reply=? WHERE tenant=? AND caller=? AND item='42' AND operation=?",
		{i64(result.status), c(result.body), t, a, id},
	)
	if err.kind != .None {
		return failure()
	}
	ended = true
	if db.commit_transaction(s.database).kind != .None {
		return failure()
	}
	checkpoint(s, .Committed, op.operation)
	return result
}
recover :: proc(s: ^State) -> bool {
	for {
		pending: Pending_Record
		found, err := db.query_one(s.database, PENDING, nil, &pending, pending_column)
		if err.kind != .None {
			return false
		}
		if !found {
			return true
		}
		if terminal(s, pending).status == .Internal_Server_Error {
			return false
		}
	}
}
save :: proc(s: ^State, tenant, caller: string, bytes: []u8) -> Result {
	key: Operation_Key
	if json.unmarshal(bytes, &key, allocator = context.temp_allocator) != nil ||
	   len(key.operationId) == 0 ||
	   len(key.operationId) > 128 ||
	   strings.contains(key.operationId, "\x00") {
		return {.Bad_Request, `{"error":"invalid_operation_id"}`}
	}
	id := c(key.operationId)
	t, a := c(tenant), c(caller)
	// RETURNING identifies the winning reservation while SQLite still holds its statement lock.
	inserted: string
	fresh, err := db.query_one(
		s.database,
		`INSERT INTO operations(tenant,caller,item,operation,schema,method,target,payload)
 VALUES(?,?,'42',?,1,'PATCH','/api/items/42',?) ON CONFLICT DO NOTHING RETURNING operation`,
		{t, a, id, bytes},
		&inserted,
		text_column,
	)
	if err.kind != .None {
		return failure()
	}
	if !fresh {
		receipt: Receipt_Record
		found, read_err := db.query_one(
			s.database,
			RECEIPT,
			{bytes, t, a, id},
			&receipt,
			receipt_column,
		)
		if !found || read_err.kind != .None {
			return failure()
		}
		if receipt.matches == 0 {
			return {.Conflict, `{"code":"operation_id_reused"}`}
		}
		if receipt.status == 0 {
			return {.Accepted, `{"state":"pending"}`}
		}
		return {server.HTTP_Status(receipt.status), receipt.reply}
	}
	checkpoint(s, .Reserved, key.operationId)
	return terminal(s, {tenant, caller, key.operationId, bytes})
}
lookup :: proc(s: ^State, tenant, caller, id: string) -> Result {
	body: string
	found, err := db.query_one(
		s.database,
		LOOKUP,
		{c(tenant), c(caller), c(id)},
		&body,
		text_column,
	)
	if err.kind != .None {
		return failure()
	}
	if !found {
		return {.OK, `{"state":"unknown"}`}
	}
	if body == `{"state":"pending"}` {
		return {.Accepted, body}
	}
	return {.OK, body}
}
Action :: enum {
	Detail,
	Save,
	Receipt,
}
Job :: struct {
	store:              ^State,
	tenant, caller, id: string,
	action:             Action,
	body:               []u8,
	result:             Result,
}
work :: proc(data: rawptr, _: pool.Work_Context) -> bool {
	job := cast(^Job)data
	out: Result
	switch job.action {
	case .Detail:
		out = detail(job.store, job.tenant)
	case .Receipt:
		out = lookup(job.store, job.tenant, job.caller, job.id)
	case .Save:
		out = save(job.store, job.tenant, job.caller, job.body)
	}
	job.result = {out.status, strings.clone(out.body, rt.heap_allocator())}
	return true
}
drop :: proc(data: rawptr) {
	job := cast(^Job)data
	heap := rt.heap_allocator()
	delete(job.tenant, heap); delete(job.caller, heap); delete(job.id, heap)
	delete(job.body, heap); delete(job.result.body, heap); free(job, heap)
}
response :: proc(data: rawptr, allocator: mem.Allocator) -> (server.Response, bool) {
	job := cast(^Job)data
	body, err := strings.clone(job.result.body, allocator)
	return {status = job.result.status, headers = HEADERS[:], body = transmute([]u8)body},
		err == nil
}

handle :: proc(s: ^State, _: ^server.Connection, req: ^server.Request) -> server.Response {
	action: Action
	id: string
	switch {
	case req.path == "/api/items/42":
		if req.method != "PATCH" && req.method != "GET" {
			return {status = .Method_Not_Allowed}
		}
		action = .Save if req.method == "PATCH" else .Detail
	case strings.has_prefix(req.path, "/api/items/42/operations/"):
		if req.method != "GET" {
			return {status = .Method_Not_Allowed}
		}
		id = req.path[len("/api/items/42/operations/"):]
		if len(id) == 0 ||
		   len(id) > 128 ||
		   strings.contains(id, "/") ||
		   strings.contains(id, "\x00") {
			return {status = .Not_Found}
		}
		action = .Receipt
	case:
		return {status = .Not_Found}
	}
	identity := s.authorize(req)
	if identity.access == .Signed_Out {
		return {status = .Unauthorized, headers = HEADERS[:]}
	}
	if identity.access != .Allowed ||
	   len(identity.tenant) == 0 ||
	   len(identity.caller) == 0 ||
	   strings.contains(identity.tenant, "\x00") ||
	   strings.contains(identity.caller, "\x00") {
		return {status = .Forbidden, headers = HEADERS[:]}
	}
	if version := server.header_value(req, "Saba-Operation-Version");
	   action == .Save && version != "" && version != "1" {
		return server.make_response(
			req,
			.Conflict,
			HEADERS[:],
			transmute([]u8)string(`{"code":"client_update_required"}`),
		)
	}
	heap := rt.heap_allocator()
	job := new(Job, heap)
	job.store, job.action = s, action
	job.tenant, job.caller, job.id =
		strings.clone(identity.tenant, heap),
		strings.clone(identity.caller, heap),
		strings.clone(id, heap)
	if action == .Save {
		job.body = make([]u8, len(req.body), heap); copy(job.body, req.body)
	}
	task := pool.Work{job, work, drop}
	res, ok := offload.response_with_unmanaged_bytes(
		&s.lane,
		&task,
		response,
		10 * time.Second,
		u64(len(req.body) + len(job.id) + len(job.tenant) + len(job.caller)),
	)
	if !ok {
		drop(job); return {status = .Service_Unavailable}
	}
	return res
}
