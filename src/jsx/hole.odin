package saba_jsx

import "core:fmt"
import "core:slice"
import "core:strings"
import k "shared:kessel"

// The innermost function that contains a JSX expression. A zero-argument call of
// one of its parameters is the row signal. Any other call stays on the runtime.
Enclosing :: struct {
	loc:    k.Loc,
	params: [dynamic]string,
}

remember_enclosing :: proc(p: ^Emitter, loc: k.Loc, params: []k.FunctionParameter) {
	names: [dynamic]string
	for param in params {
		id, ok := param.pattern.(^k.Identifier)
		if !ok {
			continue
		}
		append(&names, id.name)
	}
	append(&p.ranges, Enclosing{loc, names})
}

enclosing_params :: proc(p: ^Emitter, loc: k.Loc) -> []string {
	best: ^Enclosing
	for &item in p.ranges {
		if loc.start < item.loc.start || loc.end > item.loc.end {
			continue
		}
		if best == nil || item.loc.end - item.loc.start < best.loc.end - best.loc.start {
			best = &item
		}
	}
	if best == nil {
		return nil
	}
	return best.params[:]
}

Direct_Kind :: enum {
	Text,
	Element,
	Hole,
}

Direct_Node :: struct {
	kind:      Direct_Kind,
	tag:       string,
	statics:   [dynamic]Closed_Static,
	raw:       string,
	text:      ^k.Expression,
	cond:      ^k.Expression,
	when_true: bool,
	children:  [dynamic]Direct_Node,
	name:      string,
	anchor:    string,
}

// A proved element-or-null child is created beside its static siblings. The
// siblings are allocated once. The hole is swapped by a tracked write that
// starts synchronously, so a prop getter, a member read or a signal call in
// the condition is followed exactly as a binding would follow it.
// Templates keep the runtime path so their extracted HTML stays stable.
emit_direct_hole :: proc(p: ^Emitter, el: ^k.JSXElement) -> bool {
	// Generated code reaches the document through globalThis, which no authored
	// binding may then redefine.
	if p.template || jsx_helper_name(p.source, "globalThis") != "globalThis" {
		return false
	}
	calls := false
	node, ok := parse_hole_host(p, el, enclosing_params(p, el.loc), &calls)
	if !ok {
		return false
	}
	index := 0
	assign_direct(&node, p, &index)
	paint := jsx_helper_name(p.source, "__saba_swap")
	jsx_emit(p, "(() => {\n")
	emit_direct_tree(p, &node)
	jsx_emit(p, "const ")
	jsx_emit(p, paint)
	jsx_emit(p, " = () => {\n")
	emit_direct_paint(p, &node)
	jsx_emit(p, "};\n")
	use_helper(p, .Paint)
	jsx_emit(p, "(")
	jsx_emit(p, paint)
	jsx_emit(p, ");\n")
	jsx_emit(p, "return ")
	jsx_emit(p, node.name)
	jsx_emit(p, ";\n})()")
	return p.error.message == ""
}

parse_hole_host :: proc(
	p: ^Emitter,
	el: ^k.JSXElement,
	params: []string,
	calls: ^bool,
) -> (
	node: Direct_Node,
	ok: bool,
) {
	tag, intrinsic := el.opening_element.name.(k.JSXIdentifier)
	if !intrinsic || !html_only_tag(tag.name) || void_tag(tag.name) {
		return
	}
	node.kind = .Element
	node.tag = tag.name
	if !direct_static_attrs(p, el, &node.statics) {
		return
	}
	holes := 0
	for child in el.children {
		#partial switch v in child {
		case ^k.JSXText:
			clean := jsx_clean_text(p.source[v.loc.start:v.loc.end])
			if clean == "" {
				continue
			}
			if !direct_text_ok(p, clean) {
				return
			}
			append(&node.children, Direct_Node{kind = .Text, raw = clean})
		case ^k.JSXElement:
			nested, parsed := parse_static_element(p, v)
			if !parsed {
				return
			}
			append(&node.children, nested)
		case ^k.JSXExpressionContainer:
			expr := v.expression
			if _, empty := expr^.(^k.JSXEmptyExpression); empty {
				continue
			}
			cond, branch, when_true, proved := proved_conditional(expr)
			if !proved || !plain_expr(cond, params, calls) {
				return
			}
			inner, parsed := parse_branch_element(p, branch, params, calls)
			if !parsed {
				return
			}
			hole := Direct_Node {
				kind = .Hole,
				when_true = when_true,
				cond = cond,
			}
			append(&hole.children, inner)
			append(&node.children, hole)
			holes += 1
		case:
			return
		}
	}
	if holes == 0 {
		return
	}
	return node, true
}

parse_static_element :: proc(p: ^Emitter, el: ^k.JSXElement) -> (node: Direct_Node, ok: bool) {
	tag, intrinsic := el.opening_element.name.(k.JSXIdentifier)
	if !intrinsic || !html_only_tag(tag.name) {
		return
	}
	node.kind = .Element
	node.tag = tag.name
	if !direct_static_attrs(p, el, &node.statics) {
		return
	}
	for child in el.children {
		#partial switch v in child {
		case ^k.JSXText:
			clean := jsx_clean_text(p.source[v.loc.start:v.loc.end])
			if clean == "" {
				continue
			}
			if void_tag(tag.name) || !direct_text_ok(p, clean) {
				return
			}
			append(&node.children, Direct_Node{kind = .Text, raw = clean})
		case ^k.JSXElement:
			if void_tag(tag.name) {
				return
			}
			nested, parsed := parse_static_element(p, v)
			if !parsed {
				return
			}
			append(&node.children, nested)
		case ^k.JSXExpressionContainer:
			if _, empty := v.expression^.(^k.JSXEmptyExpression); empty {
				continue
			}
			return
		case:
			return
		}
	}
	return node, true
}

parse_branch_element :: proc(
	p: ^Emitter,
	el: ^k.JSXElement,
	params: []string,
	calls: ^bool,
) -> (
	node: Direct_Node,
	ok: bool,
) {
	tag, intrinsic := el.opening_element.name.(k.JSXIdentifier)
	if !intrinsic || !html_only_tag(tag.name) {
		return
	}
	node.kind = .Element
	node.tag = tag.name
	if !direct_static_attrs(p, el, &node.statics) {
		return
	}
	for child in el.children {
		#partial switch v in child {
		case ^k.JSXText:
			clean := jsx_clean_text(p.source[v.loc.start:v.loc.end])
			if clean == "" {
				continue
			}
			if void_tag(tag.name) || !direct_text_ok(p, clean) {
				return
			}
			append(&node.children, Direct_Node{kind = .Text, raw = clean})
		case ^k.JSXElement:
			if void_tag(tag.name) {
				return
			}
			nested, parsed := parse_branch_element(p, v, params, calls)
			if !parsed {
				return
			}
			append(&node.children, nested)
		case ^k.JSXExpressionContainer:
			expr := v.expression
			if _, empty := expr^.(^k.JSXEmptyExpression); empty {
				continue
			}
			// The runtime renders a node, an array, null or a boolean
			// structurally. Only a proven string or a number literal is text.
			_, number := unwrap(expr)^.(^k.NumericLiteral)
			if void_tag(tag.name) || !(number || produces_string(expr)) || !plain_expr(expr, params, calls) {
				return
			}
			append(&node.children, Direct_Node{kind = .Text, text = expr})
		case:
			return
		}
	}
	return node, true
}

direct_text_ok :: proc(p: ^Emitter, text: string) -> bool {
	_, ok := jsx_try_decode(p, text)
	return ok
}

// Quoted attributes the runtime writes with setAttribute under the same name.
// It routes the rest through a property, a listener, a style object or an
// error, so an element that carries one stays on the runtime path.
direct_attr_name :: proc(name: string) -> (string, bool) {
	switch name {
	case "className":
		return "class", true
	case "htmlFor":
		return "for", true
	case "ref", "children", "style", "value", "checked", "selected", "muted",
	     "innerHTML", "outerHTML", "textContent", "xmlns":
		return "", false
	}
	// HTML attribute names are case-insensitive: the runtime takes every
	// spelling of on* as an event and refuses a string for srcdoc.
	if len(name) > 2 && strings.equal_fold(name[:2], "on") || strings.equal_fold(name, "srcdoc") {
		return "", false
	}
	return name, true
}

// The runtime refuses a javascript: URL in these. A quoted value is written
// directly only when it plainly is not one: it names no scheme and holds no
// entity, or it starts with http:// or https://.
direct_url_ok :: proc(name, raw: string) -> bool {
	url := false
	for known in ([]string{"href", "src", "action", "formaction"}) {
		url ||= strings.equal_fold(name, known)
	}
	if !url {
		return true
	}
	if strings.has_prefix(raw, "http://") || strings.has_prefix(raw, "https://") {
		return !strings.contains_rune(raw, '&')
	}
	return !strings.contains_any(raw, ":&")
}

direct_static_attrs :: proc(p: ^Emitter, el: ^k.JSXElement, out: ^[dynamic]Closed_Static) -> bool {
	for item in el.opening_element.attributes {
		attr, plain := item.(k.JSXAttribute)
		if !plain {
			return false
		}
		key, identifier := attr.name.(k.JSXIdentifier)
		value, initialized := attr.value.?
		if !identifier || !initialized {
			return false
		}
		name, allowed := direct_attr_name(key.name)
		if !allowed {
			return false
		}
		lit, is_lit := value^.(^k.StringLiteral)
		if !is_lit || !closed_static_ok(p, lit) {
			return false
		}
		raw := p.source[lit.loc.start + 1:lit.loc.end - 1]
		if !direct_url_ok(name, raw) {
			return false
		}
		append(out, Closed_Static{name, raw})
	}
	return true
}

void_tag :: proc(name: string) -> bool {
	return name == "img" ||
		name == "video" ||
		name == "input" ||
		name == "br" ||
		name == "hr" ||
		name == "area" ||
		name == "base" ||
		name == "col" ||
		name == "embed" ||
		name == "link" ||
		name == "meta" ||
		name == "source" ||
		name == "track" ||
		name == "wbr"
}

plain_expr :: proc(expr: ^k.Expression, params: []string, calls: ^bool) -> bool {
	if expr == nil {
		return false
	}
	#partial switch v in unwrap(expr)^ {
	case ^k.StringLiteral, ^k.NumericLiteral, ^k.BooleanLiteral, ^k.NullLiteral, ^k.Identifier:
		return true
	case ^k.TemplateLiteral:
		for hole in v.expressions {
			if !plain_expr(hole, params, calls) {
				return false
			}
		}
		return true
	case ^k.UnaryExpression:
		return plain_expr(v.argument, params, calls)
	case ^k.BinaryExpression:
		return plain_expr(v.left, params, calls) && plain_expr(v.right, params, calls)
	case ^k.LogicalExpression:
		return plain_expr(v.left, params, calls) && plain_expr(v.right, params, calls)
	case ^k.ConditionalExpression:
		if _, found := jsx_branch(v.consequent); found {
			return false
		}
		if _, found := jsx_branch(v.alternate); found {
			return false
		}
		return plain_expr(v.test, params, calls) &&
			plain_expr(v.consequent, params, calls) &&
			plain_expr(v.alternate, params, calls)
	case ^k.MemberExpression:
		if v.computed || v.optional {
			return false
		}
		return plain_expr(v.object, params, calls) && plain_expr(v.property, params, calls)
	case ^k.CallExpression:
		if v.optional || len(v.arguments) != 0 {
			return false
		}
		id, named := v.callee^.(^k.Identifier)
		if !named || !slice.contains(params, id.name) {
			return false
		}
		calls^ = true
		return true
	}
	return false
}

assign_direct :: proc(node: ^Direct_Node, p: ^Emitter, index: ^int) {
	node.name = jsx_helper_name(p.source, fmt.tprintf("__saba_d%d", index^))
	index^ += 1
	for &child in node.children {
		assign_direct(&child, p, index)
	}
	next := ""
	for i := len(node.children) - 1; i >= 0; i -= 1 {
		if node.children[i].kind == .Hole {
			node.children[i].anchor = next
		} else {
			next = node.children[i].name
		}
	}
}

emit_direct_tree :: proc(p: ^Emitter, node: ^Direct_Node) {
	switch node.kind {
	case .Text:
		jsx_emit(p, "const ")
		jsx_emit(p, node.name)
		jsx_emit(p, " = globalThis.document.createTextNode(")
		emit_direct_text(p, node)
		jsx_emit(p, ");\n")
	case .Hole:
		jsx_emit(p, "let ")
		jsx_emit(p, node.name)
		jsx_emit(p, " = null;\n")
	case .Element:
		jsx_emit(p, "const ")
		jsx_emit(p, node.name)
		jsx_emit(p, " = globalThis.document.createElement(")
		jsx_quoted(p, node.tag)
		jsx_emit(p, ");\n")
		emit_static_attrs(p, Closed_Row{statics = node.statics}, node.name, "")
		for &child in node.children {
			emit_direct_tree(p, &child)
			if child.kind == .Hole {
				continue
			}
			jsx_emit(p, node.name)
			jsx_emit(p, ".append(")
			jsx_emit(p, child.name)
			jsx_emit(p, ");\n")
		}
	}
}

emit_direct_paint :: proc(p: ^Emitter, node: ^Direct_Node) {
	for &child in node.children {
		if child.kind != .Hole || len(child.children) == 0 {
			continue
		}
		jsx_emit(p, "if (")
		jsx_emit(p, child.name)
		jsx_emit(p, ") { ")
		jsx_emit(p, child.name)
		jsx_emit(p, ".remove(); ")
		jsx_emit(p, child.name)
		jsx_emit(p, " = null; }\n")
		jsx_emit(p, "if (")
		if !child.when_true {
			jsx_emit(p, "!(")
		}
		loc := k.get_expression_loc(child.cond)
		jsx_emit(p, p.source[loc.start:loc.end])
		if !child.when_true {
			jsx_emit(p, ")")
		}
		jsx_emit(p, ") {\n")
		emit_direct_branch(p, &child.children[0], child.name)
		jsx_emit(p, node.name)
		jsx_emit(p, ".insertBefore(")
		jsx_emit(p, child.name)
		jsx_emit(p, ", ")
		if child.anchor == "" {
			jsx_emit(p, "null")
		} else {
			jsx_emit(p, child.anchor)
		}
		jsx_emit(p, ");\n}\n")
	}
}

emit_direct_branch :: proc(p: ^Emitter, node: ^Direct_Node, var: string) {
	jsx_emit(p, var)
	jsx_emit(p, " = globalThis.document.createElement(")
	jsx_quoted(p, node.tag)
	jsx_emit(p, ");\n")
	emit_static_attrs(p, Closed_Row{statics = node.statics}, var, "")
	for &child in node.children {
		switch child.kind {
		case .Text:
			jsx_emit(p, var)
			jsx_emit(p, ".append(globalThis.document.createTextNode(")
			emit_direct_text(p, &child)
			jsx_emit(p, "));\n")
		case .Element:
			jsx_emit(p, "{\nlet ")
			jsx_emit(p, child.name)
			jsx_emit(p, " = null;\n")
			emit_direct_branch(p, &child, child.name)
			jsx_emit(p, var)
			jsx_emit(p, ".append(")
			jsx_emit(p, child.name)
			jsx_emit(p, ");\n}\n")
		case .Hole:
		}
	}
}

emit_direct_text :: proc(p: ^Emitter, node: ^Direct_Node) {
	if node.text != nil {
		loc := k.get_expression_loc(node.text)
		jsx_emit(p, p.source[loc.start:loc.end])
		return
	}
	jsx_entity_string(p, node.raw)
}
