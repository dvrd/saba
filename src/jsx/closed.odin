package saba_jsx

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import k "shared:kessel"

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

// The runtime bindings a lowered mount stands in for. Each must be imported
// under its own name from the Saba runtime, so a look-alike from another
// module or a renamed import keeps its authored behavior.
Runtime_Imports :: struct {
	signal, keyed, mount: bool,
}

runtime_imports :: proc(program: ^k.Program) -> (found: Runtime_Imports) {
	for statement in program.body {
		imp, ok := statement^.(^k.ImportDeclaration)
		if !ok || len(imp.attributes) != 0 || imp.phase != "" || imp.source.value != JSX_RUNTIME_URL {
			continue
		}
		for spec in imp.specifiers {
			named, is_named := spec^.(k.ImportSpecifier)
			if !is_named || named.local.name != named.imported.name {
				continue
			}
			switch named.local.name {
			case "signal":
				found.signal = true
			case "keyed":
				found.keyed = true
			case "mount":
				found.mount = true
			}
		}
	}
	return
}

// Every function a lowered mount adds at module scope. The names are reserved
// against the whole source, and the generated code reads no authored binding.
Lowered_Names :: struct {
	impl, create, update, move, text, attr, own: string,
}

lowered_names :: proc(p: ^Emitter, index: int) -> Lowered_Names {
	name :: proc(p: ^Emitter, base: string, index: int) -> string {
		return jsx_helper_name(p.source, fmt.tprintf("__saba_%s%d", base, index))
	}
	return {
		impl = name(p, "list", index),
		create = name(p, "create", index),
		update = name(p, "update", index),
		move = name(p, "move", index),
		text = name(p, "textOf", index),
		attr = name(p, "attr", index),
		own = jsx_helper_name(p.source, fmt.tprintf("__saba_%s", helper_exports[Helper.Own])),
	}
}

// A lowered mount keeps its authored body. The direct loop runs only for a
// host it is proved equal on: an HTML element. Any other host, a ref(name)
// reference or an element in another namespace, takes the authored statements
// and so the runtime's own handling, errors included.
//
// The direct loop places its rows before an end marker it appends to the host,
// so a host that has or later gains other children keeps the list where it was
// mounted. The list is registered with the scope that is active when it is
// mounted, as the runtime registers a mount, so disposing that scope releases
// it.
//
// A slot window is not lowered. The runtime's window enforces an empty,
// exclusive host, validates every range, recovers from foreign mutation of the
// host and gives a record with accessors tracked bindings; none of that can be
// proved here. A registered row already takes the runtime's direct writer.
lower_closed :: proc(p: ^Emitter, program: ^k.Program, nodes: ^[dynamic]Syntax) {
	// Generated code reaches the platform through globalThis, which no module
	// or local binding may then redefine.
	if !globals_unshadowed(p) {
		return
	}
	imports := runtime_imports(program)
	if !(imports.signal && imports.keyed && imports.mount) {
		return
	}
	rows := collect_closed_rows(p, program)
	if len(rows) == 0 {
		return
	}
	lowered := 0
	for statement in program.body {
		fn, loc, found := top_function(statement)
		if !found {
			continue
		}
		if _, named := fn.id.?; !named {
			continue
		}
		names := lowered_names(p, lowered)
		helpers, host, call, row, ok := keyed_body(p, fn, rows[:], imports, names)
		if !ok {
			continue
		}
		// The authored signature is copied verbatim, so its parameter names,
		// defaults and extra parameters keep their meaning. JSX in a default
		// would be copied uncompiled, so such a mount stays on the runtime.
		signature := p.source[loc.start:fn.body.loc.start]
		if strings.contains_rune(signature, '<') {
			continue
		}
		// The authored statements, compiled as they would be without lowering.
		inner: [dynamic]Syntax
		for item in nodes^ {
			if item.loc.start >= fn.body.loc.start && item.loc.end <= fn.body.loc.end {
				append(&inner, item)
			}
		}
		main := p.output
		line, column := p.gen_line, p.gen_col
		p.output = strings.builder_make()
		p.unmapped += 1
		emit_span(p, {fn.body.loc.start + 1, fn.body.loc.end}, inner[:])
		authored := strings.to_string(p.output)
		p.output = main
		p.gen_line, p.gen_col = line, column
		p.unmapped -= 1
		if p.error.message != "" {
			return
		}
		body := strings.concatenate(
			{
				helpers,
				signature,
				"{\n  if (",
				host,
				" instanceof globalThis.Element && ",
				host,
				".namespaceURI === \"http://www.w3.org/1999/xhtml\") return ",
				call,
				";",
				authored,
			},
		)
		append(nodes, Syntax{loc, body, row_origin(rows[:], row)})
		p.aliases[Helper.Own] = names.own
		lowered += 1
	}
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
		case "signal", "keyed", "mount":
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
	helpers, host_name, call, row_name: string,
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
	return strings.to_string(b.output), host, js_format("%s(%s, %s)", names.impl, host, records), row.name, true
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
emit_move_helper :: proc(b: ^Emitter, names: Lowered_Names) {
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
`,
			names.move,
		),
	)
}

emit_keyed_list :: proc(b: ^Emitter, names: Lowered_Names, key, update: string) {
	quoted := js_string(key)
	emit_move_helper(b, names)
	jsx_emit(
		b,
		js_format(
			`function %s(host, records) {
  const end = globalThis.document.createComment("");
  host.append(end);
  const cells = new globalThis.Map();
  let current = records, disposed = false;
  function render() {
    const next = globalThis.Array.from(current);
`,
			names.impl,
		),
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
    let before = end;
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
  const release = %s(end, () => {
    disposed = true;
    for (const cell of cells.values()) cell.element.remove();
    cells.clear();
    end.remove();
  });
  try {
    render();
  } catch (error) {
    release();
    throw error;
  }
  return {
    replace(items) {
      if (disposed || globalThis.Object.is(items, current)) return;
      current = items;
      render();
    },
    dispose: release,
  };
}
`,
			names.move,
			names.own,
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

// The million-row checkbox list keeps its elements in an array. While the
// keys arrive in the order they are mounted in, a record is written to the
// element at its position and nothing is looked up. When the keys change, the
// elements are matched by key, as the runtime matches them, so an element
// keeps its record, and with it focus and anything the user toggled.
checkbox_loop :: proc(b: ^Emitter, row: Closed_Row, key: string, names: Lowered_Names) {
	quoted := js_string(key)
	emit_attr_helper(b, names)
	emit_move_helper(b, names)
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
	jsx_emit(b, js_format("  return element;\n}\nfunction %s(element, row) {\n", names.update))
	for attr in row.dynamics {
		// An element keeps its key for life.
		if reads_only(attr.expr, row.param, key) {
			continue
		}
		if attr.name == "checked" {
			emit_checked_update(b, "  ", "element", attr, row.param)
		} else {
			emit_attr_write(b, "  ", "element", attr, row.param, key, names)
		}
	}
	jsx_emit(
		b,
		js_format(
			`}
function %s(host, records) {
  const end = globalThis.document.createComment("");
  host.append(end);
  let boxes = [], keys = [], rows = [], current = records, disposed = false;
  function render() {
    const next = globalThis.Array.from(current);
`,
			names.impl,
		),
	)
	emit_key_check(b, key)
	jsx_emit(
		b,
		js_format(
			`    let same = next.length === boxes.length;
    for (let i = 0; same && i < next.length; i++) same = next[i][%s] === keys[i];
    if (same) {
      for (let i = 0; i < next.length; i++) {
        if (rows[i] !== next[i]) %s(boxes[i], next[i]);
      }
      rows = next;
      return;
    }
    const created = new globalThis.Array(next.length);
    const ids = new globalThis.Array(next.length);
    if (boxes.length === 0) {
      const fragment = globalThis.document.createDocumentFragment();
      for (let i = 0; i < next.length; i++) {
        ids[i] = next[i][%s];
        created[i] = %s(next[i]);
        fragment.append(created[i]);
      }
      host.insertBefore(fragment, end);
    } else {
      const old = new globalThis.Map();
      for (let i = 0; i < keys.length; i++) old.set(keys[i], i);
      for (let i = 0; i < next.length; i++) {
        const row = next[i];
        const id = row[%s];
        const at = old.get(id);
        ids[i] = id;
        if (at === undefined) {
          created[i] = %s(row);
        } else {
          old.delete(id);
          created[i] = boxes[at];
          if (rows[at] !== row) %s(created[i], row);
        }
      }
      for (const at of old.values()) boxes[at].remove();
      let before = end;
      for (let i = next.length - 1; i >= 0; i--) {
        %s(host, created[i], before);
        before = created[i];
      }
    }
    boxes = created;
    keys = ids;
    rows = next;
  }
  const release = %s(end, () => {
    disposed = true;
    for (const box of boxes) box.remove();
    boxes = [];
    end.remove();
  });
  try {
    render();
  } catch (error) {
    release();
    throw error;
  }
  return {
    replace(items) {
      if (disposed || globalThis.Object.is(items, current)) return;
      current = items;
      render();
    },
    dispose: release,
  };
}
`,
			quoted,
			names.update,
			quoted,
			names.create,
			quoted,
			names.create,
			names.update,
			names.move,
			names.own,
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
