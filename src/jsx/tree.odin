package saba_jsx

import "core:strings"
import k "shared:kessel"

// A tree row is a pure projection the flat text loop cannot describe: a void
// media element, nested elements, or a proved element-or-null hole. The flat
// div, checkbox, and slot emitters stay on their existing strings.
Closed_Kind :: enum {
	Element,
	Hole,
	Text,
}

Closed_Node :: struct {
	kind:      Closed_Kind,
	tag:       string,
	checkbox:  bool,
	statics:   [dynamic]Closed_Static,
	dynamics:  [dynamic]Closed_Dynamic,
	text:      ^k.Expression,
	raw:       string,
	when_true: bool,
	cond:      ^k.Expression,
	children:  [dynamic]Closed_Node,
}

Tree_Gen :: struct {
	n, t, h, b: int,
	handles:    [dynamic]string,
}

Planned :: struct {
	kind:   Closed_Kind,
	name:   string,
	anchor: string,
	node:   Closed_Node,
}

row_origin :: proc(rows: []Closed_Row, name: string) -> k.Loc {
	row := find_row(rows, name)
	if row == nil {
		return {}
	}
	return row.element_loc
}

row_dotted :: proc(row: ^Closed_Row) -> bool {
	for field in row.fields {
		if strings.contains(field, ".") {
			return true
		}
	}
	return false
}

// Elements that exist only in the HTML namespace. The runtime chooses a
// namespace from the rendered position and switches at svg and math, and names
// such as a, title, script and style exist in more than one namespace. A tag
// outside this list keeps the runtime's createElementNS decision.
html_only_tag :: proc(name: string) -> bool {
	switch name {
	case "div", "span", "p", "ul", "ol", "li", "dl", "dt", "dd",
	     "table", "caption", "thead", "tbody", "tfoot", "tr", "td", "th",
	     "h1", "h2", "h3", "h4", "h5", "h6",
	     "main", "section", "article", "header", "footer", "nav", "aside",
	     "em", "strong", "b", "i", "small", "code", "pre", "blockquote",
	     "figure", "figcaption", "label", "button", "output",
	     "img", "video", "input":
		return true
	}
	return false
}

media_attr :: proc(tag, name: string, checkbox: bool) -> bool {
	if slot_attribute(name) {
		return true
	}
	if tag == "img" && (name == "src" || name == "alt") {
		return true
	}
	if tag == "video" && (name == "src" || name == "preload" || name == "poster") {
		return true
	}
	if checkbox && (name == "type" || name == "checked") {
		return true
	}
	return false
}

analyze_tree_row :: proc(p: ^Emitter, fn: ^k.FunctionExpression, loc: k.Loc) -> (row: Closed_Row, ok: bool) {
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
	fields: [dynamic]string
	node, parsed := analyze_element(p, el, param.name, &fields, true)
	if !parsed || !tree_shape(node) {
		return
	}
	row.name = name.name
	row.param = param.name
	row.tag = node.tag
	row.decl_loc = loc
	row.element_loc = el.loc
	row.fields = fields
	row.tree = true
	row.root = node
	return row, true
}

tree_shape :: proc(node: Closed_Node) -> bool {
	if node.kind != .Element {
		return false
	}
	if node.tag == "img" || node.tag == "video" || len(node.children) > 0 {
		return true
	}
	for child in node.children {
		if child.kind == .Hole {
			return true
		}
	}
	return false
}

analyze_element :: proc(
	p: ^Emitter,
	el: ^k.JSXElement,
	param: string,
	fields: ^[dynamic]string,
	allow_holes: bool,
) -> (
	node: Closed_Node,
	ok: bool,
) {
	tag, intrinsic := el.opening_element.name.(k.JSXIdentifier)
	if !intrinsic || !html_only_tag(tag.name) {
		return
	}
	node.kind = .Element
	node.tag = tag.name
	node.checkbox = tag.name == "input" && checkbox_input(el)
	if tag.name == "input" && !node.checkbox {
		return
	}
	seen_dynamic := false
	for item in el.opening_element.attributes {
		attr, plain := item.(k.JSXAttribute)
		if !plain {
			return {}, false
		}
		key, identifier := attr.name.(k.JSXIdentifier)
		value, initialized := attr.value.?
		if !identifier || !initialized || !media_attr(tag.name, key.name, node.checkbox) ||
		   node_attr_named(node, key.name) {
			return {}, false
		}
		#partial switch v in value^ {
		case ^k.StringLiteral:
			// The runtime writes a static checked through the live property.
			if seen_dynamic || key.name == "checked" || !closed_static_ok(p, v) {
				return {}, false
			}
			append(&node.statics, Closed_Static{key.name, p.source[v.loc.start + 1:v.loc.end - 1]})
		case ^k.JSXExpressionContainer:
			if key.name == "type" || !remember_fields(v.expression, param, fields) {
				return {}, false
			}
			seen_dynamic = true
			append(&node.dynamics, Closed_Dynamic{key.name, v.expression})
		case:
			return {}, false
		}
	}
	void := node.tag == "img" || node.tag == "video" || node.checkbox
	if void {
		if !whitespace_only(p, el) {
			return {}, false
		}
		return node, true
	}
	for child in el.children {
		#partial switch v in child {
		case ^k.JSXText:
			clean := jsx_clean_text(p.source[v.loc.start:v.loc.end])
			if clean == "" {
				continue
			}
			decoded, known := jsx_try_decode(p, clean)
			if !known {
				return {}, false
			}
			append(&node.children, Closed_Node{kind = .Text, raw = decoded})
		case ^k.JSXElement:
			nested, parsed := analyze_element(p, v, param, fields, allow_holes)
			if !parsed {
				return {}, false
			}
			append(&node.children, nested)
		case ^k.JSXExpressionContainer:
			expr := v.expression
			if _, empty := expr^.(^k.JSXEmptyExpression); empty {
				continue
			}
			if cond, branch, when_true, proved := proved_conditional(expr); proved {
				if !allow_holes || !remember_fields(cond, param, fields) {
					return {}, false
				}
				inner, parsed := analyze_element(p, branch, param, fields, false)
				if !parsed {
					return {}, false
				}
				hole := Closed_Node {
					kind = .Hole,
					when_true = when_true,
					cond = cond,
				}
				append(&hole.children, inner)
				append(&node.children, hole)
				continue
			}
			// A bare record().field can be a node, an array or nothing, which
			// the runtime renders structurally. Only a proven string is text.
			if !produces_string(expr) || !remember_fields(expr, param, fields) {
				return {}, false
			}
			append(&node.children, Closed_Node{kind = .Text, text = expr})
		case:
			return {}, false
		}
	}
	return node, true
}

node_attr_named :: proc(node: Closed_Node, name: string) -> bool {
	for item in node.statics {
		if item.name == name {
			return true
		}
	}
	for item in node.dynamics {
		if item.name == name {
			return true
		}
	}
	return false
}

whitespace_only :: proc(p: ^Emitter, el: ^k.JSXElement) -> bool {
	for child in el.children {
		#partial switch v in child {
		case ^k.JSXText:
			if jsx_clean_text(p.source[v.loc.start:v.loc.end]) != "" {
				return false
			}
		case ^k.JSXExpressionContainer:
			if _, empty := v.expression^.(^k.JSXEmptyExpression); !empty {
				return false
			}
		case:
			return false
		}
	}
	return true
}

bind_name :: proc(gen: ^Tree_Gen, prefix: string) -> string {
	index := 0
	switch prefix {
	case "n":
		index = gen.n
		gen.n += 1
	case "t":
		index = gen.t
		gen.t += 1
	case "h":
		index = gen.h
		gen.h += 1
	case "b":
		// A branch-local element. Its name is unique across nesting depths and
		// is never stored on the cell.
		index = gen.b
		gen.b += 1
		return js_format("b%d", index)
	}
	name := js_format("%s%d", prefix, index)
	append(&gen.handles, name)
	return name
}

plan_children :: proc(gen: ^Tree_Gen, node: Closed_Node) -> [dynamic]Planned {
	plans: [dynamic]Planned
	for child in node.children {
		item := Planned {
			kind = child.kind,
			node = child,
		}
		switch child.kind {
		case .Element:
			item.name = bind_name(gen, "n")
		case .Text:
			item.name = bind_name(gen, "t")
		case .Hole:
			item.name = bind_name(gen, "h")
		}
		append(&plans, item)
	}
	next := ""
	for i := len(plans) - 1; i >= 0; i -= 1 {
		if plans[i].kind == .Hole {
			plans[i].anchor = next
		} else {
			next = plans[i].name
		}
	}
	return plans
}

tree_loop :: proc(b: ^Emitter, row: Closed_Row, key: string, names: Lowered_Names) {
	emit_attr_helper(b, names)
	jsx_emit(
		b,
		js_format(
			"function %s(row) {\n    const element = globalThis.document.createElement(%s);\n",
			names.create,
			js_string(row.tag),
		),
	)
	gen := Tree_Gen{}
	emit_create_element(b, row.root, "element", true, &gen, row.param, key, names)
	jsx_emit(b, "    return { element, record: row")
	for handle in gen.handles {
		jsx_emit(b, ", ")
		jsx_emit(b, handle)
	}
	jsx_emit(b, " };\n}\n")
	update := Emitter{source = b.source, output = strings.builder_make()}
	walk := Tree_Gen{}
	emit_update_element(&update, row.root, "cell.element", &walk, row.param, key, names)
	emit_keyed_list(b, names, key, strings.to_string(update.output))
}

emit_create_element :: proc(
	b: ^Emitter,
	node: Closed_Node,
	var: string,
	root: bool,
	gen: ^Tree_Gen,
	param, key: string,
	names: Lowered_Names,
) {
	if !root {
		jsx_emit(b, js_format("    const %s = globalThis.document.createElement(%s);\n", var, js_string(node.tag)))
	}
	emit_static_attrs(b, Closed_Row{statics = node.statics}, var)
	for attr in node.dynamics {
		emit_attr_write(b, "    ", var, attr, param, key, names)
	}
	plans := plan_children(gen, node)
	for plan in plans {
		switch plan.kind {
		case .Element:
			emit_create_element(b, plan.node, plan.name, false, gen, param, key, names)
		case .Text:
			jsx_emit(b, js_format("    const %s = globalThis.document.createTextNode(", plan.name))
			emit_text_expr(b, plan.node, param)
			jsx_emit(b, ");\n")
		case .Hole:
			jsx_emit(b, js_format("    let %s = null;\n    if (", plan.name))
			emit_hole_test(b, plan.node, param)
			jsx_emit(b, ") {\n")
			emit_branch(b, plan.node.children[0], plan.name, false, gen, param, names)
			jsx_emit(b, "    }\n")
		}
	}
	for plan in plans {
		if plan.kind == .Hole {
			jsx_emit(b, js_format("    if (%s) %s.append(%s);\n", plan.name, var, plan.name))
		} else {
			jsx_emit(b, js_format("    %s.append(%s);\n", var, plan.name))
		}
	}
}

emit_update_element :: proc(
	b: ^Emitter,
	node: Closed_Node,
	path: string,
	gen: ^Tree_Gen,
	param, key: string,
	names: Lowered_Names,
) {
	for attr in node.dynamics {
		// A cell keeps its key for life.
		if reads_only(attr.expr, param, key) {
			continue
		}
		if attr.name == "checked" {
			emit_checked_update(b, "        ", path, attr, param)
		} else {
			emit_attr_write(b, "        ", path, attr, param, key, names)
		}
	}
	plans := plan_children(gen, node)
	for plan in plans {
		switch plan.kind {
		case .Element:
			emit_update_element(b, plan.node, js_format("cell.%s", plan.name), gen, param, key, names)
		case .Text:
			if plan.node.text == nil {
				continue
			}
			jsx_emit(b, "        {\n          const value = ")
			emit_row_expr(b, plan.node.text, param)
			jsx_emit(
				b,
				js_format(";\n          if (cell.%s.data !== value) cell.%s.data = value;\n        }\n", plan.name, plan.name),
			)
		case .Hole:
			jsx_emit(
				b,
				js_format("        if (cell.%s) { cell.%s.remove(); cell.%s = null; }\n        if (", plan.name, plan.name, plan.name),
			)
			emit_hole_test(b, plan.node, param)
			jsx_emit(b, ") {\n")
			fresh := bind_name(gen, "b")
			emit_branch(b, plan.node.children[0], fresh, true, gen, param, names)
			jsx_emit(b, js_format("          cell.%s = %s;\n          %s.insertBefore(%s, ", plan.name, fresh, path, fresh))
			if plan.anchor == "" {
				jsx_emit(b, "null")
			} else {
				jsx_emit(b, js_format("cell.%s", plan.anchor))
			}
			jsx_emit(b, ");\n        }\n")
		}
	}
}

// declare is false when var is an existing let binding. Every nested element
// takes a fresh name, so an inner block never shadows the element it is
// appended to.
emit_branch :: proc(
	b: ^Emitter,
	node: Closed_Node,
	var: string,
	declare: bool,
	gen: ^Tree_Gen,
	param: string,
	names: Lowered_Names,
) {
	jsx_emit(
		b,
		js_format(
			"      %s%s = globalThis.document.createElement(%s);\n",
			"const " if declare else "",
			var,
			js_string(node.tag),
		),
	)
	emit_static_attrs(b, Closed_Row{statics = node.statics}, var, "      ")
	for attr in node.dynamics {
		emit_attr_write(b, "      ", var, attr, param, "", names)
	}
	for child in node.children {
		switch child.kind {
		case .Text:
			jsx_emit(b, js_format("      %s.append(globalThis.document.createTextNode(", var))
			emit_text_expr(b, child, param)
			jsx_emit(b, "));\n")
		case .Element:
			nested := bind_name(gen, "b")
			emit_branch(b, child, nested, true, gen, param, names)
			jsx_emit(b, js_format("      %s.append(%s);\n", var, nested))
		case .Hole:
		}
	}
}

proved_conditional :: proc(
	expr: ^k.Expression,
) -> (
	cond: ^k.Expression,
	branch: ^k.JSXElement,
	when_true, proved: bool,
) {
	ternary, ok := unwrap(expr)^.(^k.ConditionalExpression)
	if !ok {
		return
	}
	if element, found := jsx_branch(ternary.consequent); found && nothing_branch(ternary.alternate) {
		return ternary.test, element, true, true
	}
	if element, found := jsx_branch(ternary.alternate); found && nothing_branch(ternary.consequent) {
		return ternary.test, element, false, true
	}
	return
}

jsx_branch :: proc(expr: ^k.Expression) -> (el: ^k.JSXElement, ok: bool) {
	el, ok = unwrap(expr)^.(^k.JSXElement)
	return
}

nothing_branch :: proc(expr: ^k.Expression) -> bool {
	#partial switch v in unwrap(expr)^ {
	case ^k.NullLiteral:
		return true
	case ^k.BooleanLiteral:
		return !v.value
	case ^k.Identifier:
		return v.name == "undefined"
	}
	return false
}

emit_text_expr :: proc(b: ^Emitter, node: Closed_Node, param: string) {
	if node.text != nil {
		emit_row_expr(b, node.text, param)
		return
	}
	jsx_quoted(b, node.raw)
}

emit_hole_test :: proc(b: ^Emitter, node: Closed_Node, param: string) {
	if !node.when_true {
		jsx_emit(b, "!(")
	}
	emit_row_expr(b, node.cond, param)
	if !node.when_true {
		jsx_emit(b, ")")
	}
}
