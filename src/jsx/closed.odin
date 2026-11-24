package saba_jsx

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import k "shared:kessel"

SLOT_WINDOW_URL :: "/__saba/slot-window.js"

// A proved-closed row lowers to a direct DOM loop. The signal runtime stays
// for every row this analysis rejects. Lowering is declined, not approximated,
// wherever the direct loop could differ from the runtime path.
Closed_Row :: struct {
	name, param, tag: string,
	decl_loc:         k.Loc,
	element_loc:      k.Loc,
	exported:         bool,
	statics:          [dynamic]Closed_Static,
	dynamics:         [dynamic]Closed_Dynamic,
	text:             ^k.Expression,
	fields:           [dynamic]string,
	tree:             bool,
	root:             Closed_Node,
}

Closed_Static :: struct {
	name, raw: string,
}

Closed_Dynamic :: struct {
	name: string,
	expr: ^k.Expression,
}

// The runtime bindings a lowered mount replaces. Each must be imported under
// its own name from the Saba runtime, so a look-alike from another module or a
// renamed import keeps its authored behavior.
Runtime_Imports :: struct {
	signal, keyed, mount, slot_window: bool,
}

runtime_imports :: proc(program: ^k.Program) -> (found: Runtime_Imports) {
	for statement in program.body {
		imp, ok := statement^.(^k.ImportDeclaration)
		if !ok || len(imp.attributes) != 0 || imp.phase != "" {
			continue
		}
		for spec in imp.specifiers {
			named, is_named := spec^.(k.ImportSpecifier)
			if !is_named || named.local.name != named.imported.name {
				continue
			}
			switch imp.source.value {
			case JSX_RUNTIME_URL:
				switch named.local.name {
				case "signal":
					found.signal = true
				case "keyed":
					found.keyed = true
				case "mount":
					found.mount = true
				}
			case SLOT_WINDOW_URL:
				if named.local.name == "mountSlotWindow" {
					found.slot_window = true
				}
			}
		}
	}
	return
}

// Every function a lowered mount adds at module scope. The names are reserved
// against the whole source, and the generated code reads no authored binding.
Lowered_Names :: struct {
	impl, create, move, text, attr, allocate, place, make_slot, write, fresh: string,
}

lowered_names :: proc(p: ^Emitter, index: int) -> Lowered_Names {
	name :: proc(p: ^Emitter, base: string, index: int) -> string {
		return jsx_helper_name(p.source, fmt.tprintf("__saba_%s%d", base, index))
	}
	return {
		impl = name(p, "list", index),
		create = name(p, "create", index),
		move = name(p, "move", index),
		text = name(p, "textOf", index),
		attr = name(p, "attr", index),
		allocate = name(p, "allocate", index),
		place = name(p, "place", index),
		make_slot = name(p, "makeSlot", index),
		write = name(p, "write", index),
		fresh = name(p, "mountFresh", index),
	}
}

lower_closed :: proc(p: ^Emitter, program: ^k.Program, nodes: ^[dynamic]Syntax) -> map[string]bool {
	removed: map[string]bool
	// Generated code reaches the platform through globalThis, which no module
	// or local binding may then redefine.
	if jsx_helper_name(p.source, "globalThis") != "globalThis" {
		return removed
	}
	imports := runtime_imports(program)
	if !(imports.signal && imports.keyed && imports.mount) && !imports.slot_window {
		return removed
	}
	rows := collect_closed_rows(p, program)
	if len(rows) == 0 {
		return removed
	}
	lowered: [dynamic]k.Loc
	used: map[string]bool
	for statement in program.body {
		fn, loc, found := top_function(statement)
		if !found {
			continue
		}
		if _, named := fn.id.?; !named {
			continue
		}
		names := lowered_names(p, len(lowered))
		helpers, call, row, ok := keyed_body(p, fn, rows[:], imports, names)
		if !ok {
			helpers, call, row, ok = slot_body(p, fn, rows[:], imports, names)
		}
		if !ok {
			continue
		}
		// The authored signature is copied verbatim, so its parameter names,
		// defaults and extra parameters keep their meaning.
		body := strings.concatenate(
			{helpers, p.source[loc.start:fn.body.loc.start], "{\n  return ", call, ";\n}"},
		)
		append(nodes, Syntax{loc, body, row_origin(rows[:], row)})
		append(&lowered, loc)
		used[row] = true
	}
	if len(lowered) == 0 {
		return removed
	}
	excluded: [dynamic]k.Loc
	append(&excluded, ..lowered[:])
	for &row in rows {
		if !used[row.name] || row.exported {
			continue
		}
		// Another reader of the row keeps its declaration and registration.
		own := make([dynamic]k.Loc, 0, len(lowered) + 1)
		append(&own, ..lowered[:])
		append(&own, row.decl_loc)
		if word_used(p.source, row.name, own[:]) {
			continue
		}
		append(nodes, Syntax{row.decl_loc, "", {}})
		append(&excluded, row.decl_loc)
		removed[row.name] = true
	}
	for statement in program.body {
		imp, ok := statement^.(^k.ImportDeclaration)
		if ok && runtime_source(imp) {
			append(&excluded, imp.loc)
		}
	}
	for statement in program.body {
		imp, ok := statement^.(^k.ImportDeclaration)
		if !ok || !runtime_source(imp) || len(imp.specifiers) == 0 {
			continue
		}
		prune_import(p, imp, excluded[:], nodes)
	}
	return removed
}

runtime_source :: proc(imp: ^k.ImportDeclaration) -> bool {
	if len(imp.attributes) != 0 || imp.phase != "" {
		return false
	}
	return imp.source.value == JSX_RUNTIME_URL || imp.source.value == SLOT_WINDOW_URL
}

// Drop only the specifiers no remaining code names. An import the lowered
// mounts alone used disappears, and one with other readers keeps those names.
prune_import :: proc(p: ^Emitter, imp: ^k.ImportDeclaration, excluded: []k.Loc, nodes: ^[dynamic]Syntax) {
	kept: [dynamic]string
	named: [dynamic]string
	dropped := 0
	for spec in imp.specifiers {
		switch v in spec^ {
		case k.ImportDefaultSpecifier:
			if word_used(p.source, v.local.name, excluded) {
				append(&kept, v.local.name)
			} else {
				dropped += 1
			}
		case k.ImportNamespaceSpecifier:
			if word_used(p.source, v.local.name, excluded) {
				append(&kept, js_format("* as %s", v.local.name))
			} else {
				dropped += 1
			}
		case k.ImportSpecifier:
			if word_used(p.source, v.local.name, excluded) {
				append(&named, p.source[v.loc.start:v.loc.end])
			} else {
				dropped += 1
			}
		}
	}
	if dropped == 0 {
		return
	}
	if len(named) > 0 {
		append(&kept, js_format("{ %s }", strings.join(named[:], ", ")))
	}
	if len(kept) == 0 {
		append(nodes, Syntax{imp.loc, "", {}})
		return
	}
	text := js_format(
		"import %s from %s;",
		strings.join(kept[:], ", "),
		p.source[imp.source.loc.start:imp.source.loc.end],
	)
	append(nodes, Syntax{imp.loc, text, {}})
}

// A textual search is deliberately generous. A name inside a string, a comment
// or a property access counts as a use, and so does any escaped identifier.
word_used :: proc(source, name: string, excluded: []k.Loc) -> bool {
	if strings.contains(source, "\\u") {
		return true
	}
	part :: proc(c: u8) -> bool {
		return c == '_' || c == '$' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= 0x80
	}
	for at := 0; at < len(source); {
		found := strings.index(source[at:], name)
		if found < 0 {
			return false
		}
		start := at + found
		end := start + len(name)
		at = start + 1
		if start > 0 && part(source[start - 1]) || end < len(source) && part(source[end]) {
			continue
		}
		inside := false
		for loc in excluded {
			if u32(start) >= loc.start && u32(end) <= loc.end {
				inside = true
				break
			}
		}
		if !inside {
			return true
		}
	}
	return false
}

collect_closed_rows :: proc(p: ^Emitter, program: ^k.Program) -> [dynamic]Closed_Row {
	rows: [dynamic]Closed_Row
	for statement in program.body {
		fn, loc, found := top_function(statement)
		if !found {
			continue
		}
		if row, ok := analyze_closed_row(p, fn, loc); ok {
			_, row.exported = statement^.(^k.ExportNamedDeclaration)
			append(&rows, row)
		}
	}
	return rows
}

top_function :: proc(statement: ^k.Statement) -> (fn: ^k.FunctionExpression, loc: k.Loc, ok: bool) {
	#partial switch s in statement^ {
	case ^k.FunctionDeclaration:
		return &s.expr, s.loc, true
	case ^k.ExportNamedDeclaration:
		decl, has := s.declaration.?
		if !has {
			return
		}
		fun, found := decl^.(^k.FunctionDeclaration)
		if !found {
			return
		}
		return &fun.expr, s.loc, true
	}
	return
}

analyze_closed_row :: proc(p: ^Emitter, fn: ^k.FunctionExpression, loc: k.Loc) -> (row: Closed_Row, ok: bool) {
	if row, ok = analyze_flat_row(p, fn, loc); ok {
		return
	}
	return analyze_tree_row(p, fn, loc)
}

analyze_flat_row :: proc(p: ^Emitter, fn: ^k.FunctionExpression, loc: k.Loc) -> (row: Closed_Row, ok: bool) {
	name, named := fn.id.?
	if !named || fn.async || fn.generator || len(fn.params) != 1 || len(fn.body.body) != 1 ||
	   fn.params[0].default_val != nil {
		return
	}
	param, simple := fn.params[0].pattern.(^k.Identifier)
	if !simple {
		return
	}
	el := body_element(fn.body.body[:])
	if el == nil {
		return
	}
	tag, intrinsic := el.opening_element.name.(k.JSXIdentifier)
	checkbox := intrinsic && tag.name == "input" && checkbox_input(el)
	if !intrinsic || !(checkbox || slice.contains([]string{"div", "span", "p", "li", "td", "th"}, tag.name)) {
		return
	}
	// A bare record().field can hold a node, an array or nothing at all, which
	// the runtime renders structurally. Only a proven string becomes text here.
	child := slot_text(p, el)
	if checkbox {
		if child != nil {
			return
		}
	} else if child == nil {
		return
	}
	row.name = name.name
	row.param = param.name
	row.tag = tag.name
	row.decl_loc = loc
	row.element_loc = el.loc
	row.text = child
	for item in el.opening_element.attributes {
		attr, plain := item.(k.JSXAttribute)
		if !plain {
			return {}, false
		}
		key, identifier := attr.name.(k.JSXIdentifier)
		value, initialized := attr.value.?
		allowed := slot_attribute(key.name) || (checkbox && (key.name == "type" || key.name == "checked"))
		if !identifier || !initialized || !allowed || closed_attr_named(row, key.name) {
			return {}, false
		}
		#partial switch v in value^ {
		case ^k.StringLiteral:
			// The runtime writes a static checked through the live property.
			if len(row.fields) != 0 || key.name == "checked" || !closed_static_ok(p, v) {
				return {}, false
			}
			append(&row.statics, Closed_Static{key.name, p.source[v.loc.start + 1:v.loc.end - 1]})
		case ^k.JSXExpressionContainer:
			if key.name == "type" || !remember_fields(v.expression, param.name, &row.fields) {
				return {}, false
			}
			append(&row.dynamics, Closed_Dynamic{key.name, v.expression})
		case:
			return {}, false
		}
	}
	if child != nil && !remember_fields(child, param.name, &row.fields) {
		return {}, false
	}
	return row, true
}

closed_static_ok :: proc(p: ^Emitter, literal: ^k.StringLiteral) -> bool {
	_, ok := jsx_try_decode(p, p.source[literal.loc.start + 1:literal.loc.end - 1])
	return ok
}

checkbox_input :: proc(el: ^k.JSXElement) -> bool {
	if len(el.children) != 0 {
		return false
	}
	for item in el.opening_element.attributes {
		attr, plain := item.(k.JSXAttribute)
		if !plain {
			continue
		}
		key, identifier := attr.name.(k.JSXIdentifier)
		if !identifier || key.name != "type" {
			continue
		}
		value, initialized := attr.value.?
		if !initialized {
			return false
		}
		lit, is_lit := value^.(^k.StringLiteral)
		return is_lit && lit.value == "checkbox"
	}
	return false
}

closed_attr_named :: proc(row: Closed_Row, name: string) -> bool {
	for item in row.statics {
		if item.name == name {
			return true
		}
	}
	for item in row.dynamics {
		if item.name == name {
			return true
		}
	}
	return false
}

remember_fields :: proc(expr: ^k.Expression, param: string, fields: ^[dynamic]string) -> bool {
	reads: [dynamic]Slot_Read
	if !slot_reads(expr, param, &reads) || len(reads) == 0 {
		return false
	}
	for read in reads {
		if !slice.contains(fields[:], read.field) {
			append(fields, read.field)
		}
	}
	return true
}

// Names a lowered mount function declares. An authored parameter or constant
// with one of the runtime names would shadow the import the proof relies on.
shadows_runtime :: proc(names: ..string) -> bool {
	for name in names {
		switch name {
		case "signal", "keyed", "mount", "mountSlotWindow":
			return true
		}
	}
	return false
}

simple_params :: proc(fn: ^k.FunctionExpression) -> bool {
	for param in fn.params {
		name, ok := param_ident(param)
		if !ok || shadows_runtime(name) {
			return false
		}
	}
	return true
}

keyed_body :: proc(
	p: ^Emitter,
	fn: ^k.FunctionExpression,
	rows: []Closed_Row,
	imports: Runtime_Imports,
	names: Lowered_Names,
) -> (
	helpers, call, row_name: string,
	ok: bool,
) {
	if !(imports.signal && imports.keyed && imports.mount) {
		return
	}
	if fn.async || fn.generator || len(fn.params) < 2 || len(fn.body.body) != 4 || !simple_params(fn) {
		return
	}
	host, _ := param_ident(fn.params[0])
	records, _ := param_ident(fn.params[1])
	rows_name, signal_arg, rows_ok := const_init(fn.body.body[0])
	list_name, keyed_call, list_ok := const_init(fn.body.body[1])
	dispose_name, mount_call, dispose_ok := const_init(fn.body.body[2])
	if !rows_ok || !list_ok || !dispose_ok || shadows_runtime(rows_name, list_name, dispose_name) {
		return
	}
	signal_name, signal_args, signal_ok := named_call(signal_arg)
	keyed_name, keyed_args, keyed_ok := named_call(keyed_call)
	mount_name, mount_args, mount_ok := named_call(mount_call)
	if !signal_ok || signal_name != "signal" || len(signal_args.arguments) != 1 {
		return
	}
	arg, arg_ok := ident_name(signal_args.arguments[0])
	if !arg_ok || arg != records {
		return
	}
	if !keyed_ok || keyed_name != "keyed" || len(keyed_args.arguments) != 3 {
		return
	}
	head, head_ok := ident_name(keyed_args.arguments[0])
	_, key, key_ok := key_field(keyed_args.arguments[1])
	tile, tile_ok := ident_name(keyed_args.arguments[2])
	if !head_ok || head != rows_name || !key_ok || !tile_ok {
		return
	}
	row := find_row(rows, tile)
	if row == nil || !slice.contains(row.fields[:], key) {
		return
	}
	if !mount_ok || mount_name != "mount" || len(mount_args.arguments) != 2 {
		return
	}
	mount_host, mount_host_ok := ident_name(mount_args.arguments[0])
	if !mount_host_ok || mount_host != host || !bare_list_arrow(mount_args.arguments[1], list_name) {
		return
	}
	if !keyed_return(fn.body.body[3], rows_name, dispose_name) {
		return
	}
	b := Emitter{source = p.source, output = strings.builder_make()}
	if row.tree {
		tree_loop(&b, row^, key, names)
	} else if row.tag == "input" {
		checkbox_loop(&b, row^, key, names)
	} else {
		keyed_loop(&b, row^, key, names)
	}
	if b.error.message != "" {
		return
	}
	return strings.to_string(b.output), js_format("%s(%s, %s)", names.impl, host, records), row.name, true
}

slot_body :: proc(
	p: ^Emitter,
	fn: ^k.FunctionExpression,
	rows: []Closed_Row,
	imports: Runtime_Imports,
	names: Lowered_Names,
) -> (
	helpers, call, row_name: string,
	ok: bool,
) {
	if !imports.slot_window {
		return
	}
	if fn.async || fn.generator || len(fn.params) < 3 || len(fn.body.body) != 4 || !simple_params(fn) {
		return
	}
	host, _ := param_ident(fn.params[0])
	records, _ := param_ident(fn.params[1])
	first, _ := param_ident(fn.params[2])
	view, window_call, view_ok := const_init(fn.body.body[0])
	replace_name, replace_arrow, replace_ok := const_init(fn.body.body[1])
	if !view_ok || !replace_ok || shadows_runtime(view, replace_name) {
		return
	}
	window_name, window_args, window_ok := named_call(window_call)
	if !window_ok || window_name != "mountSlotWindow" || len(window_args.arguments) != 2 {
		return
	}
	window_host, window_host_ok := ident_name(window_args.arguments[0])
	tile, tile_ok := ident_name(window_args.arguments[1])
	if !window_host_ok || window_host != host || !tile_ok {
		return
	}
	row := find_row(rows, tile)
	if row == nil || row.tree || row.text == nil || row_dotted(row) {
		return
	}
	fallback, swapped := swap_arrow(p, replace_arrow, view)
	if !swapped || !call_stmt(fn.body.body[2], replace_name, records, first) {
		return
	}
	if !slot_return(fn.body.body[3], replace_name, view) {
		return
	}
	b := Emitter{source = p.source, output = strings.builder_make()}
	slot_loop(&b, row^, fallback, names)
	if b.error.message != "" {
		return
	}
	return strings.to_string(b.output),
		js_format("%s(%s, %s, %s)", names.impl, host, records, first),
		row.name,
		true
}

find_row :: proc(rows: []Closed_Row, name: string) -> ^Closed_Row {
	for i in 0 ..< len(rows) {
		if rows[i].name == name {
			return &rows[i]
		}
	}
	return nil
}

param_ident :: proc(param: k.FunctionParameter) -> (string, bool) {
	pattern := param.pattern
	if assign, assigned := pattern.(^k.AssignmentPattern); assigned {
		pattern = assign.left
	}
	id, ok := pattern.(^k.Identifier)
	if !ok {
		return "", false
	}
	return id.name, true
}

const_init :: proc(statement: ^k.Statement) -> (name: string, init: ^k.Expression, ok: bool) {
	decl, is_decl := statement^.(^k.VariableDeclaration)
	if !is_decl || decl.kind != .Const || len(decl.declarations) != 1 {
		return
	}
	item := &decl.declarations[0]
	id, named := item.id.(^k.Identifier)
	value, has := item.init.?
	if !named || !has {
		return
	}
	return id.name, value, true
}

named_call :: proc(expr: ^k.Expression) -> (name: string, call: ^k.CallExpression, ok: bool) {
	called, is_call := unwrap(expr)^.(^k.CallExpression)
	if !is_call || called.optional {
		return
	}
	callee, is_id := called.callee^.(^k.Identifier)
	if !is_id {
		return
	}
	return callee.name, called, true
}

ident_name :: proc(expr: ^k.Expression) -> (string, bool) {
	id, ok := unwrap(expr)^.(^k.Identifier)
	if !ok {
		return "", false
	}
	return id.name, true
}

unwrap :: proc(expr: ^k.Expression) -> ^k.Expression {
	current := expr
	for {
		paren, ok := current^.(^k.ParenthesizedExpression)
		if !ok {
			return current
		}
		current = paren.expression
	}
}

key_field :: proc(expr: ^k.Expression) -> (param, field: string, ok: bool) {
	arrow, is_arrow := unwrap(expr)^.(^k.ArrowFunctionExpression)
	if !is_arrow || arrow.async || len(arrow.params) != 1 || arrow.params[0].default_val != nil {
		return
	}
	name, named := arrow.params[0].pattern.(^k.Identifier)
	if !named {
		return
	}
	body, is_expr := arrow.body.(^k.Expression)
	if !is_expr {
		return
	}
	member, is_member := unwrap(body)^.(^k.MemberExpression)
	if !is_member || member.computed || member.optional {
		return
	}
	object, object_ok := member.object^.(^k.Identifier)
	property, property_ok := member.property^.(^k.Identifier)
	if !object_ok || !property_ok || object.name != name.name {
		return
	}
	return name.name, property.name, true
}

bare_list_arrow :: proc(expr: ^k.Expression, list: string) -> bool {
	arrow, ok := unwrap(expr)^.(^k.ArrowFunctionExpression)
	if !ok || arrow.async || len(arrow.params) != 0 {
		return false
	}
	body, is_expr := arrow.body.(^k.Expression)
	if !is_expr {
		return false
	}
	fragment, is_fragment := unwrap(body)^.(^k.JSXFragment)
	if !is_fragment || len(fragment.children) != 1 {
		return false
	}
	container, is_container := fragment.children[0].(^k.JSXExpressionContainer)
	if !is_container {
		return false
	}
	name, named := ident_name(container.expression)
	return named && name == list
}

keyed_return :: proc(statement: ^k.Statement, rows, dispose: string) -> bool {
	obj, ok := return_object(statement)
	if !ok || len(obj.properties) != 2 {
		return false
	}
	replace := prop_named(obj, "replace")
	done := prop_named(obj, "dispose")
	if replace == nil || done == nil {
		return false
	}
	member, is_member := unwrap(replace.value)^.(^k.MemberExpression)
	if !is_member || member.computed || member.optional {
		return false
	}
	object, object_ok := member.object^.(^k.Identifier)
	property, property_ok := member.property^.(^k.Identifier)
	value, value_ok := ident_name(done.value)
	return object_ok && property_ok && object.name == rows && property.name == "set" && value_ok && value == dispose
}

slot_return :: proc(statement: ^k.Statement, replace, view: string) -> bool {
	obj, ok := return_object(statement)
	if !ok || len(obj.properties) != 2 {
		return false
	}
	rep := prop_named(obj, "replace")
	done := prop_named(obj, "dispose")
	if rep == nil || done == nil || !rep.shorthand {
		return false
	}
	rep_name, rep_ok := ident_name(rep.value)
	member, is_member := unwrap(done.value)^.(^k.MemberExpression)
	if !is_member || member.computed || member.optional {
		return false
	}
	object, object_ok := member.object^.(^k.Identifier)
	property, property_ok := member.property^.(^k.Identifier)
	return rep_ok && rep_name == replace && object_ok && property_ok && object.name == view && property.name == "dispose"
}

return_object :: proc(statement: ^k.Statement) -> (^k.ObjectExpression, bool) {
	ret, ok := statement^.(^k.ReturnStatement)
	if !ok {
		return nil, false
	}
	arg, has := ret.argument.?
	if !has {
		return nil, false
	}
	obj, is_obj := unwrap(arg)^.(^k.ObjectExpression)
	return obj, is_obj
}

prop_named :: proc(obj: ^k.ObjectExpression, name: string) -> ^k.Property {
	for i in 0 ..< len(obj.properties) {
		id, ok := obj.properties[i].key^.(^k.Identifier)
		if ok && id.name == name {
			return &obj.properties[i]
		}
	}
	return nil
}

// (next, nextFirst = 0) => view.replace(nextFirst, next). The default must be a
// numeric literal, which is copied into the lowered replace unchanged.
swap_arrow :: proc(p: ^Emitter, expr: ^k.Expression, view: string) -> (fallback: string, ok: bool) {
	arrow, is_arrow := unwrap(expr)^.(^k.ArrowFunctionExpression)
	if !is_arrow || arrow.async || len(arrow.params) != 2 {
		return
	}
	if _, defaulted := arrow.params[0].default_val.?; defaulted {
		return
	}
	first, first_ok := arrow.params[0].pattern.(^k.Identifier)
	if !first_ok {
		return
	}
	second: string
	initial: ^k.Expression
	#partial switch pattern in arrow.params[1].pattern {
	case ^k.Identifier:
		second = pattern.name
		initial, _ = arrow.params[1].default_val.?
	case ^k.AssignmentPattern:
		id, simple := pattern.left.(^k.Identifier)
		if !simple {
			return
		}
		second = id.name
		initial = pattern.right
	case:
		return
	}
	if initial == nil {
		return
	}
	number, numeric := initial^.(^k.NumericLiteral)
	if !numeric {
		return
	}
	body, is_expr := arrow.body.(^k.Expression)
	if !is_expr {
		return
	}
	call, is_call := unwrap(body)^.(^k.CallExpression)
	if !is_call || call.optional || len(call.arguments) != 2 {
		return
	}
	member, is_member := unwrap(call.callee)^.(^k.MemberExpression)
	if !is_member || member.computed || member.optional {
		return
	}
	object, object_ok := member.object^.(^k.Identifier)
	property, property_ok := member.property^.(^k.Identifier)
	left, left_ok := ident_name(call.arguments[0])
	right, right_ok := ident_name(call.arguments[1])
	if !object_ok || !property_ok || object.name != view || property.name != "replace" ||
	   !left_ok || !right_ok || left != second || right != first.name {
		return
	}
	return p.source[number.loc.start:number.loc.end], true
}

call_stmt :: proc(statement: ^k.Statement, name, left, right: string) -> bool {
	expr, ok := statement^.(^k.ExpressionStatement)
	if !ok {
		return false
	}
	call_name, call, called := named_call(expr.expression)
	if !called || call_name != name || len(call.arguments) != 2 {
		return false
	}
	arg0, ok0 := ident_name(call.arguments[0])
	arg1, ok1 := ident_name(call.arguments[1])
	return ok0 && ok1 && arg0 == left && arg1 == right
}

// fmt reads braces as its own placeholders. Generated JavaScript is full of
// them, so every brace in the template is taken literally.
js_format :: proc(format: string, args: ..any) -> string {
	escaped, _ := strings.replace_all(format, "{", "{{", context.temp_allocator)
	escaped, _ = strings.replace_all(escaped, "}", "}}", context.temp_allocator)
	return fmt.tprintf(escaped, ..args)
}

js_string :: proc(text: string) -> string {
	encoded, err := json.marshal(text, allocator = context.temp_allocator)
	if err != nil {
		return `""`
	}
	return string(encoded)
}

strict_attribute :: proc(name: string) -> bool {
	return strings.has_prefix(name, "data-") || strings.has_prefix(name, "aria-")
}

// The runtime removes a nullish attribute, and a false one unless it is data-*
// or aria-*, and writes true as the empty string. A proven string or a
// validated row key is written directly.
emit_attr_write :: proc(
	b: ^Emitter,
	indent, object: string,
	attr: Closed_Dynamic,
	param, key: string,
	names: Lowered_Names,
) {
	if attr.name == "checked" {
		jsx_emit(b, js_format("%s%s.checked = ", indent, object))
		emit_row_expr(b, attr.expr, param)
		jsx_emit(b, ";\n")
		return
	}
	if produces_string(attr.expr) || (key != "" && reads_only(attr.expr, param, key)) {
		jsx_emit(b, js_format("%s%s.setAttribute(%s, ", indent, object, js_string(attr.name)))
		emit_row_expr(b, attr.expr, param)
		jsx_emit(b, ");\n")
		return
	}
	jsx_emit(b, js_format("%s%s(%s, %s, ", indent, names.attr, object, js_string(attr.name)))
	emit_row_expr(b, attr.expr, param)
	jsx_emit(b, ", true);\n" if strict_attribute(attr.name) else ", false);\n")
}

emit_checked_update :: proc(b: ^Emitter, indent, object: string, attr: Closed_Dynamic, param: string) {
	jsx_emit(b, js_format("%s{\n%s  const on = ", indent, indent))
	emit_row_expr(b, attr.expr, param)
	jsx_emit(b, js_format(";\n%s  if (%s.checked !== on) %s.checked = on;\n%s}\n", indent, object, object, indent))
}

emit_attr_helper :: proc(b: ^Emitter, names: Lowered_Names) {
	jsx_emit(
		b,
		js_format(
			`function %s(element, name, value, strict) {
  if (value == null || (value === false && !strict)) element.removeAttribute(name);
  else element.setAttribute(name, value === true && !strict ? "" : globalThis.String(value));
}
`,
			names.attr,
		),
	)
}

HOST_GUARD :: `  if (!(host instanceof globalThis.Element)) throw new globalThis.TypeError("Expected a DOM element or a ref(name) reference.");
`

// The same key rules, order and messages as the runtime's keyed list.
emit_key_check :: proc(b: ^Emitter, key: string) {
	jsx_emit(
		b,
		js_format(
			`    const seen = new globalThis.Set();
    for (let i = 0; i < next.length; i++) {
      const id = next[i][%s];
      if (typeof id !== "string" && !globalThis.Number.isFinite(id)) throw new globalThis.TypeError("A row key must be a string or finite number.");
      if (seen.has(id)) throw new globalThis.Error("Duplicate row key: " + id);
      seen.add(id);
    }
`,
			js_string(key),
		),
	)
}

// Shared by the flat and the tree row. update holds the statements that bring
// an existing cell up to date with a different record object.
emit_keyed_list :: proc(b: ^Emitter, names: Lowered_Names, key, update: string) {
	quoted := js_string(key)
	jsx_emit(
		b,
		js_format(
			`function %s(parent, element, before) {
  if (element.parentNode !== parent) parent.insertBefore(element, before);
  else if (element.nextSibling !== before) {
    if (typeof parent.moveBefore === "function") parent.moveBefore(element, before);
    else parent.insertBefore(element, before);
  }
}
function %s(host, records) {
`,
			names.move,
			names.impl,
		),
	)
	jsx_emit(b, HOST_GUARD)
	jsx_emit(
		b,
		`  const cells = new globalThis.Map();
  let current = records, disposed = false;
  function render() {
    const next = globalThis.Array.from(current);
`,
	)
	emit_key_check(b, key)
	jsx_emit(
		b,
		js_format(
			`    for (const [id, cell] of cells) {
      if (!seen.has(id)) {
        cell.element.remove();
        cells.delete(id);
      }
    }
    let before = null;
    for (let i = next.length - 1; i >= 0; i--) {
      const row = next[i];
      let cell = cells.get(row[%s]);
      if (!cell) {
        cell = %s(row);
        cells.set(row[%s], cell);
      } else if (cell.record !== row) {
`,
			quoted,
			names.create,
			quoted,
		),
	)
	jsx_emit(b, update)
	jsx_emit(
		b,
		js_format(
			`        cell.record = row;
      }
      %s(host, cell.element, before);
      before = cell.element;
    }
  }
  render();
  return {
    replace(items) {
      if (disposed || globalThis.Object.is(items, current)) return;
      current = items;
      render();
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      for (const cell of cells.values()) cell.element.remove();
      cells.clear();
    },
  };
}
`,
			names.move,
		),
	)
}

keyed_loop :: proc(b: ^Emitter, row: Closed_Row, key: string, names: Lowered_Names) {
	emit_attr_helper(b, names)
	jsx_emit(b, js_format("function %s(row) {\n  return ", names.text))
	emit_row_expr(b, row.text, row.param)
	jsx_emit(
		b,
		js_format(
			";\n}\nfunction %s(row) {\n  const element = globalThis.document.createElement(%s);\n",
			names.create,
			js_string(row.tag),
		),
	)
	emit_static_attrs(b, row, "element", "  ")
	for attr in row.dynamics {
		emit_attr_write(b, "  ", "element", attr, row.param, key, names)
	}
	jsx_emit(
		b,
		js_format(
			"  const text = globalThis.document.createTextNode(%s(row));\n  element.append(text);\n  return { element, text, record: row };\n}\n",
			names.text,
		),
	)
	update := Emitter{source = b.source, output = strings.builder_make()}
	jsx_emit(
		&update,
		js_format(
			"        const value = %s(row);\n        if (cell.text.data !== value) cell.text.data = value;\n",
			names.text,
		),
	)
	for attr in row.dynamics {
		// A cell keeps its key for life, so an attribute that reads only the
		// key cannot change.
		if reads_only(attr.expr, row.param, key) {
			continue
		}
		emit_attr_write(&update, "        ", "cell.element", attr, row.param, key, names)
	}
	emit_keyed_list(b, names, key, strings.to_string(update.output))
}

// The million-row checkbox list updates by position. Keys are still validated
// as the runtime validates them, and every dynamic attribute is rewritten,
// including one that reads only the key, because a position can change record.
checkbox_loop :: proc(b: ^Emitter, row: Closed_Row, key: string, names: Lowered_Names) {
	emit_attr_helper(b, names)
	jsx_emit(
		b,
		js_format(
			"function %s(row) {\n  const element = globalThis.document.createElement(%s);\n",
			names.create,
			js_string(row.tag),
		),
	)
	emit_static_attrs(b, row, "element", "  ")
	for attr in row.dynamics {
		emit_attr_write(b, "  ", "element", attr, row.param, key, names)
	}
	jsx_emit(b, js_format("  return element;\n}\nfunction %s(host, records) {\n", names.impl))
	jsx_emit(b, HOST_GUARD)
	jsx_emit(
		b,
		`  let boxes = [], current = records, disposed = false;
  function render() {
    const next = globalThis.Array.from(current);
`,
	)
	emit_key_check(b, key)
	jsx_emit(
		b,
		js_format(
			`    if (boxes.length !== next.length) {
      const fragment = globalThis.document.createDocumentFragment();
      const created = new globalThis.Array(next.length);
      for (let i = 0; i < next.length; i++) {
        const element = %s(next[i]);
        created[i] = element;
        fragment.append(element);
      }
      const anchor = boxes.length ? boxes[boxes.length - 1].nextSibling : null;
      for (const box of boxes) box.remove();
      host.insertBefore(fragment, anchor);
      boxes = created;
      return;
    }
    for (let i = 0; i < next.length; i++) {
      const row = next[i];
      const element = boxes[i];
`,
			names.create,
		),
	)
	for attr in row.dynamics {
		if attr.name == "checked" {
			emit_checked_update(b, "      ", "element", attr, row.param)
		} else {
			emit_attr_write(b, "      ", "element", attr, row.param, key, names)
		}
	}
	jsx_emit(
		b,
		`    }
  }
  render();
  return {
    replace(items) {
      if (disposed || globalThis.Object.is(items, current)) return;
      current = items;
      render();
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      for (const box of boxes) box.remove();
      boxes = [];
    },
  };
}
`,
	)
}

// A slot remembers the last value of each field under an index, so a record
// field named element or text cannot replace the slot's own nodes.
slot_same :: proc(index: int, field: string) -> string {
	return js_format(
		`(slot.f%d === row[%s] && (typeof slot.f%d !== "object" || slot.f%d === null) && typeof slot.f%d !== "function")`,
		index,
		js_string(field),
		index,
		index,
		index,
	)
}

slot_loop :: proc(b: ^Emitter, row: Closed_Row, fallback: string, names: Lowered_Names) {
	emit_attr_helper(b, names)
	jsx_emit(
		b,
		js_format(
			`function %s(old, start, first, count, make) {
  const low = globalThis.Math.max(start, first);
  const high = globalThis.Math.min(start + old.length, first + count);
  if (high <= low || start === first) {
    const kept = globalThis.Math.min(count, old.length);
    if (old.length === count) return { next: old, prefix: 0, suffix: count, retired: [] };
    const next = old.slice(0, kept);
    while (next.length < count) next.push(make());
    return { next, prefix: 0, suffix: kept, retired: old.slice(kept) };
  }
  const prefix = low - first;
  const suffix = high - first;
  const free = [...old.slice(0, low - start), ...old.slice(high - start)];
  const next = new globalThis.Array(count);
  let used = 0;
  for (let i = 0; i < count; i++) {
    if (i >= prefix && i < suffix) next[i] = old[first + i - start];
    else next[i] = used < free.length ? free[used++] : make();
  }
  return { next, prefix, suffix, retired: free.slice(used) };
}
function %s(parent, plan) {
  const { next, prefix, suffix } = plan;
  for (let i = 0; i < prefix; i++) {
    const element = next[i].element;
    const before = next[prefix].element;
    if (element.parentNode === parent && typeof parent.moveBefore === "function") parent.moveBefore(element, before);
    else parent.insertBefore(element, before);
  }
  for (let i = suffix; i < next.length; i++) {
    const element = next[i].element;
    if (element.parentNode === parent && typeof parent.moveBefore === "function") parent.moveBefore(element, null);
    else parent.insertBefore(element, null);
  }
}
function %s() {
  const element = globalThis.document.createElement(%s);
`,
			names.allocate,
			names.place,
			names.make_slot,
			js_string(row.tag),
		),
	)
	emit_static_attrs(b, row, "element", "  ")
	jsx_emit(b, "  const text = globalThis.document.createTextNode(\"\");\n  element.append(text);\n  return { element, text")
	for _, index in row.fields {
		jsx_emit(b, js_format(", f%d: globalThis.NaN", index))
	}
	jsx_emit(
		b,
		js_format(
			" };\n}\nfunction %s(rows, view) {\n  for (let i = 0; i < rows.length; i++) {\n    const row = rows[i];\n    const slot = view[i];\n",
			names.write,
		),
	)
	if len(row.fields) > 0 {
		// Only an unchanged primitive proves the written values are current.
		jsx_emit(b, "    if (")
		for field, index in row.fields {
			if index > 0 {
				jsx_emit(b, " && ")
			}
			jsx_emit(b, slot_same(index, field))
		}
		jsx_emit(b, ") continue;\n")
	}
	for attr in row.dynamics {
		emit_attr_write(b, "    ", "slot.element", attr, row.param, "", names)
	}
	jsx_emit(b, "    const value = ")
	emit_row_expr(b, row.text, row.param)
	jsx_emit(b, ";\n    if (slot.text.data !== value) slot.text.data = value;\n")
	for field, index in row.fields {
		jsx_emit(b, js_format("    slot.f%d = row[%s];\n", index, js_string(field)))
	}
	jsx_emit(
		b,
		js_format(
			"  }\n}\nfunction %s(parent, next) {\n  const view = new globalThis.Array(next.length);\n  for (let i = 0; i < next.length; i++) {\n    const row = next[i];\n    const element = globalThis.document.createElement(%s);\n",
			names.fresh,
			js_string(row.tag),
		),
	)
	emit_static_attrs(b, row, "element", "    ")
	for attr in row.dynamics {
		emit_attr_write(b, "    ", "element", attr, row.param, "", names)
	}
	jsx_emit(b, "    const text = globalThis.document.createTextNode(")
	emit_row_expr(b, row.text, row.param)
	jsx_emit(b, ");\n    element.append(text);\n    parent.insertBefore(element, null);\n    view[i] = { element, text")
	for field, index in row.fields {
		jsx_emit(b, js_format(", f%d: row[%s]", index, js_string(field)))
	}
	jsx_emit(
		b,
		js_format(
			` };
  }
  return view;
}
function %s(host, records, first) {
  if (!(host instanceof globalThis.Element)) throw new globalThis.TypeError("mountSlotWindow expects a host element and a JSX row function.");
  let slots = [];
  let start = 0;
  let disposed = false;
  function replace(next, nextFirst = %s) {
    if (disposed) return;
    if (slots.length === 0) {
      slots = %s(host, next);
      start = nextFirst;
      return;
    }
    if (nextFirst === start && next.length === slots.length) {
      %s(next, slots);
      return;
    }
    const plan = %s(slots, start, nextFirst, next.length, %s);
    for (const slot of plan.retired) slot.element.remove();
    %s(next, plan.next);
    %s(host, plan);
    slots = plan.next;
    start = nextFirst;
  }
  replace(records, first);
  return {
    replace,
    dispose() {
      if (disposed) return;
      disposed = true;
      for (const slot of slots) slot.element.remove();
      slots = [];
    },
  };
}
`,
			names.impl,
			fallback,
			names.fresh,
			names.write,
			names.allocate,
			names.make_slot,
			names.write,
			names.place,
		),
	)
}

emit_static_attrs :: proc(b: ^Emitter, row: Closed_Row, element: string, indent := "    ") {
	for item in row.statics {
		if item.name == "class" {
			jsx_emit(b, indent)
			jsx_emit(b, element)
			jsx_emit(b, ".className = ")
			jsx_entity_string(b, item.raw)
			jsx_emit(b, ";\n")
		} else {
			jsx_emit(b, indent)
			jsx_emit(b, element)
			jsx_emit(b, ".setAttribute(")
			jsx_quoted(b, item.name)
			jsx_emit(b, ", ")
			jsx_entity_string(b, item.raw)
			jsx_emit(b, ");\n")
		}
	}
}

emit_row_expr :: proc(b: ^Emitter, expr: ^k.Expression, param: string) {
	fields: [dynamic]string
	emit_slot_expression(b, expr, param, &fields)
}

reads_only :: proc(expr: ^k.Expression, param, field: string) -> bool {
	member, ok := unwrap(expr)^.(^k.MemberExpression)
	if !ok || member.computed || member.optional {
		return false
	}
	call, called := member.object^.(^k.CallExpression)
	prop, named := member.property^.(^k.Identifier)
	if !called || !named || call.optional || len(call.arguments) != 0 || prop.name != field {
		return false
	}
	accessor, is_id := call.callee^.(^k.Identifier)
	return is_id && accessor.name == param
}
