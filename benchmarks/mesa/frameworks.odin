package main

import server "../../src/core"
import "core:encoding/entity"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import db "shared:kakunou"

FRAGMENT_HEADERS := [2]server.Header {
	{"Content-Type", "text/html; charset=utf-8"},
	{"Cache-Control", "no-store"},
}
FRAGMENT_SAVED_HEADERS := [3]server.Header {
	{"Content-Type", "text/html; charset=utf-8"},
	{"Cache-Control", "no-store"},
	{"HX-Trigger", "mesaRefresh"},
}

// The normal Saba benchmark can run directly from a checkout without npm.
// Explicitly named, built artifacts are the only additional files served here.
load_framework_assets :: proc(state: ^State, template, empty_host: string) {
	for mode in ([]string {
			"saba-current",
			"saba-planned",
			"react",
			"solid",
			"svelte",
			"vanilla",
			"htmx",
		}) {
		bundle_path := fmt.tprintf("benchmarks/frameworks/dist/%s.js", mode)
		if !os.is_file(bundle_path) {
			continue
		}
		bundle, err := os.read_entire_file(bundle_path, context.allocator)
		assert(err == nil, bundle_path)
		url := fmt.aprintf("/frameworks/%s.js", mode)
		state.assets[url] = {string(bundle), "text/javascript"}

		html, script := empty_host, "/entry.js"
		if mode == "saba-planned" || mode == "vanilla" {
			html, script = template, "/planned.js"
		} else if mode == "htmx" {
			bytes, read_err := os.read_entire_file(
				"benchmarks/frameworks/htmx.html",
				context.allocator,
			)
			assert(read_err == nil)
			state.assets[mode] = {string(bytes), "text/html; charset=utf-8"}
			continue
		}
		replaced: bool
		html, replaced = strings.replace_all(
			html,
			fmt.tprintf(`src="%s"`, script),
			fmt.tprintf(`src="%s"`, url),
		)
		assert(replaced)
		state.assets[mode] = {html, "text/html; charset=utf-8"}
	}
}

// htmx submits a native URL-encoded form. Normalize it to the storage contract
// used by the JSON clients before reserving the operation and revision.
decode_fragment_submission :: proc(body: []u8) -> ([]u8, bool) {
	s: Submission
	seen: bit_set[enum {
		Operation,
		Revision,
		Title,
	};u8]
	raw := string(body)
	for part in strings.split_iterator(&raw, "&") {
		pos := strings.index_byte(part, '=')
		if pos < 0 {
			return nil, false
		}
		value, _ := strings.replace_all(part[pos + 1:], "+", " ", context.temp_allocator)
		ok: bool
		value, ok = net.percent_decode(value, context.temp_allocator)
		if !ok {
			return nil, false
		}
		switch part[:pos] {
		case "operationId":
			if .Operation in seen {
				return nil, false
			}
			s.operationId = value
			seen += {.Operation}
		case "expectedRevision":
			if .Revision in seen {
				return nil, false
			}
			s.expectedRevision, ok = strconv.parse_i64(value)
			if !ok {
				return nil, false
			}
			seen += {.Revision}
		case "title":
			if .Title in seen {
				return nil, false
			}
			s.title = value
			seen += {.Title}
		case:
			return nil, false
		}
	}
	if seen != {.Operation, .Revision, .Title} {
		return nil, false
	}
	bytes, err := json.marshal(s, allocator = context.temp_allocator)
	return bytes, err == nil
}

Fragment_Row :: struct {
	id, title: string,
	revision:  i64,
}

decode_fragment_row :: proc(
	stmt: ^db.SQLite_Statement,
	row: ^Fragment_Row,
) -> (
	err: db.Database_Error,
) {
	row.id, err = db.column_text(stmt, 0, context.temp_allocator)
	if err.kind != .None {
		return
	}
	row.title, err = db.column_text(stmt, 1, context.temp_allocator)
	if err.kind != .None {
		return
	}
	row.revision, err = db.column_int(stmt, 2)
	return
}

render_fragment :: proc(state: ^State, operation: Operation) -> (string, bool) {
	COLUMNS :: "SELECT CAST(id AS TEXT),title,revision FROM bench_items "
	ORDER :: " ORDER BY (id=42) DESC,id"
	if operation == .Detail {
		row: Fragment_Row
		found, err := db.query_one(
			state.database,
			COLUMNS + "WHERE id=42",
			nil,
			&row,
			decode_fragment_row,
		)
		if !found || err.kind != .None {
			return "", false
		}
		value, _ := entity.escape_html(row.title, context.temp_allocator)
		return fmt.tprintf(
				`<label for="title">Item 42</label>
<div class="fields"><input id="title" name="title" value="%s" autocomplete="off" spellcheck="false"><button id="save" type="submit" disabled>Save</button></div>
<output id="preview" for="title">%s</output>
<span id="canonical" data-revision="%d" hidden>%s</span>`,
				value,
				value,
				row.revision,
				value,
			),
			true
	}

	sql: cstring
	view: string
	#partial switch operation {
	case .All:
		sql, view = COLUMNS + ORDER, "all"
	case .Open:
		sql, view = COLUMNS + "WHERE id%2=0" + ORDER, "open"
	case .Marked:
		sql, view = COLUMNS + "WHERE substr(title,1,1)='!'" + ORDER, "marked"
	case:
		return "", false
	}
	rows, err := db.query_many(state.database, sql, nil, decode_fragment_row, max_rows = 1000)
	if err.kind != .None {
		return "", false
	}
	b := strings.builder_make(context.temp_allocator)
	strings.builder_grow(&b, len(rows) * 58)
	for row in rows {
		title, _ := entity.escape_html(row.title, context.temp_allocator)
		// id originates from SQLite's INTEGER PRIMARY KEY.
		for part in ([]string {
				`<li id="`,
				view,
				"-",
				row.id,
				`" data-id="`,
				row.id,
				`">`,
				title,
				"</li>",
			}) {
			strings.write_string(&b, part)
		}
	}
	return strings.to_string(b), true
}
