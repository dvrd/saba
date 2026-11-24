package saba_jsx

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import k "shared:kessel"

// html is inserted inside the inert page host. javascript preserves the normal
// module exports and adds __sabaAttach(host, props) on supported pages.
Page_Template :: struct {
	supported:                         bool,
	html, javascript, title, manifest: string,
}

Template_Function :: struct {
	loc:  k.Loc,
	root: ^k.JSXElement,
	tree: union {
		^k.Expression,
		^k.FunctionDeclaration,
	},
}

Template_Target :: struct {
	tag:                     string, // Empty means an owned pair of comment markers.
	parent, instance, local: int,
}

Template_Build :: struct {
	p:                               ^Emitter,
	html:                            strings.Builder,
	declarations:                    strings.Builder,
	targets:                         [dynamic]Template_Target,
	components:                      map[string]Template_Function,
	names:                           map[string]int,
	expanding:                       map[string]bool,
	attach, setup_prefix:            string,
	instances, instance, next_local: int,
}

return_element :: proc(expr: ^k.Expression) -> ^k.JSXElement {
	if expr == nil {
		return nil
	}
	#partial switch v in expr^ {
	case ^k.ParenthesizedExpression:
		return return_element(v.expression)
	case ^k.JSXElement:
		return v
	}
	return nil
}

body_element :: proc(body: []^k.Statement) -> ^k.JSXElement {
	if len(body) == 0 {
		return nil
	}
	for statement in body[:len(body) - 1] {
		// A setup expression or declaration can fail during activation. Only
		// accept a tail return when earlier control flow cannot return elsewhere.
		#partial switch _ in statement^ {
		case ^k.VariableDeclaration,
		     ^k.FunctionDeclaration,
		     ^k.ExpressionStatement,
		     ^k.EmptyStatement:
		case:
			return nil
		}
	}
	ret, ok := body[len(body) - 1]^.(^k.ReturnStatement)
	if !ok {
		return nil
	}
	expr, _ := ret.argument.?
	return return_element(expr)
}

// A clone of a named function introduces a new self binding. If the author
// reads that binding or renders it recursively, retain the original function.
check_self_binding :: proc(fn: Template_Function, name: string) -> Template_Function {
	if fn.root != nil && name != "" {
		names := make(map[string]int)
		visit_tree(fn.tree, nil, nil, &names, true)
		if names[name] > 1 {
			return {}
		}
	}
	return fn
}

template_declaration :: proc(d: ^k.FunctionDeclaration) -> Template_Function {
	if d.async || d.generator {
		return {}
	}
	name := ""
	if binding, ok := d.id.?; ok {
		name = binding.name
	}
	return check_self_binding({d.loc, body_element(d.body.body[:]), d}, name)
}

template_function :: proc(expr: ^k.Expression) -> (fn: Template_Function) {
	if expr == nil {
		return
	}
	fn.tree = expr
	#partial switch v in expr^ {
	case ^k.FunctionExpression:
		if !v.async && !v.generator {
			fn.loc, fn.root = v.loc, body_element(v.body.body[:])
			if binding, ok := v.id.?; ok {
				return check_self_binding(fn, binding.name)
			}
		}
	case ^k.ArrowFunctionExpression:
		if !v.async {
			fn.loc = v.loc
			switch body in v.body {
			case ^k.Expression:
				fn.root = return_element(body)
			case ^k.BlockStatement:
				fn.root = body_element(body.body[:])
			}
		}
	case ^k.ParenthesizedExpression:
		return template_function(v.expression)
	}
	return
}

record_variables :: proc(
	b: ^Template_Build,
	decl: ^k.VariableDeclaration,
	exported: bool,
	title: ^string,
) {
	if decl.kind != .Const {
		return
	}
	for v in decl.declarations {
		id, ok := v.id.(^k.Identifier)
		expr, has_init := v.init.?
		if !ok || !has_init {
			continue
		}
		if exported && id.name == "title" {
			if literal, found := expr^.(^k.StringLiteral); found {
				title^ = literal.value
			}
		}
		if fn := template_function(expr); fn.root != nil {
			b.components[id.name] = fn
		}
	}
}

extract_page :: proc(
	p: ^Emitter,
	program: ^k.Program,
	allocator: mem.Allocator,
) -> (
	page: Page_Template,
) {
	// Reserve the public attachment export. Reuse the legacy entry if authored
	// code already owns that spelling (including an escaped identifier).
	if jsx_helper_name(p.source, "__sabaAttach") != "__sabaAttach" {
		return
	}
	b := Template_Build {
		p            = p,
		html         = strings.builder_make(),
		declarations = strings.builder_make(),
		components   = make(map[string]Template_Function),
		names        = make(map[string]int),
		expanding    = make(map[string]bool),
		attach       = jsx_helper_name(p.source, "__saba_template"),
		setup_prefix = jsx_helper_name(p.source, "__saba_instance"),
	}
	root: Template_Function
	root_name, title: string
	for s in program.body {
		#partial switch st in s^ {
		case ^k.FunctionDeclaration:
			if name, named := st.id.?; named {
				b.components[name.name] = template_declaration(st)
			}
		case ^k.VariableDeclaration:
			record_variables(&b, st, false, &title)
		case ^k.ExportNamedDeclaration:
			if d, ok := st.declaration.?; ok {
				#partial switch decl in d^ {
				case ^k.VariableDeclaration:
					record_variables(&b, decl, true, &title)
				case ^k.FunctionDeclaration:
					if name, named := decl.id.?; named {
						b.components[name.name] = template_declaration(decl)
					}
				}
			}
		case ^k.ExportDefaultDeclaration:
			switch decl in st.declaration^ {
			case ^k.Expression:
				root = template_function(decl)
				if id, ok := decl^.(^k.Identifier); ok {
					root_name = id.name
				}
			case ^k.Declaration:
				if fn, ok := decl^.(^k.FunctionDeclaration); ok {
					root = template_declaration(fn)
				}
			}
		}
	}
	visit_tree(program.body, nil, nil, &b.names)
	if root_name != "" && b.names[root_name] == 2 {
		root = b.components[root_name]
	}
	if root.root == nil || b.names["eval"] != 0 || !template_intrinsic(root.root, "") {
		return
	}
	setup := template_instance(&b, root, -1)
	if p.error.message != "" {
		return
	}
	manifest, marshal_error := json.marshal(b.targets[:])
	if marshal_error != nil {
		jsx_fail(p, "Could not encode the template targets"); return
	}
	jsx_emit(p, fmt.tprintf("\nimport * as %s from \"/__saba/attach.js\";\n", b.attach))
	jsx_emit(p, strings.to_string(b.declarations))
	jsx_emit(p, "export function __sabaAttach(host, props) { return ")
	jsx_emit(p, fmt.tprintf("%s.attach(host, %s, () => ", b.attach, string(manifest)))
	use_helper(p, .Factory)
	jsx_emit(p, fmt.tprintf("(%s, props)); }\n", setup))
	return {
		supported = true,
		html = strings.clone(strings.to_string(b.html), allocator),
		title = strings.clone(title, allocator),
		manifest = strings.clone(string(manifest), allocator),
	}
}

// Clone the component's setup expression at module scope for this occurrence.
// All its original imports, locals and lexical captures keep their scope. The
// specialized return uses existing DOM targets. Its public component continues
// to use ordinary JSX construction for subsequently mounted instances.
template_instance :: proc(b: ^Template_Build, fn: Template_Function, parent: int) -> string {
	name := fmt.aprintf("%s_%d", b.setup_prefix, b.instances)
	previous_instance, previous_local := b.instance, b.next_local
	b.instance, b.next_local = b.instances, 0
	b.instances += 1
	defer {b.instance, b.next_local = previous_instance, previous_local}
	p := b.p
	previous := p.output
	p.output = strings.builder_make()
	// The clone is staged here and emitted again with the declarations. Count
	// its generated position once, at that later emission.
	staged_line, staged_col := p.gen_line, p.gen_col
	p.unmapped += 1
	nodes: [dynamic]Syntax
	visit_tree(fn.tree, &nodes, nil)
	before, after: [dynamic]Syntax
	for node in nodes {
		if node.loc.end <= fn.root.loc.start {
			append(&before, node)
		}
		if node.loc.start >= fn.root.loc.end {
			append(&after, node)
		}
	}
	emit_span(p, {fn.loc.start, fn.root.loc.start}, before[:])
	template_element(b, fn.root, parent)
	emit_span(p, {fn.root.loc.end, fn.loc.end}, after[:])
	fmt.sbprintf(&b.declarations, "const %s = (%s);\n", name, strings.to_string(p.output))
	p.output = previous
	p.gen_line, p.gen_col = staged_line, staged_col
	p.unmapped -= 1
	return name
}

html_text :: proc(w: ^strings.Builder, text: string) {
	for c in text {
		switch c {
		case '\r':
			strings.write_string(w, "&#13;")
		case '&':
			strings.write_string(w, "&amp;")
		case '<':
			strings.write_string(w, "&lt;")
		case '>':
			strings.write_string(w, "&gt;")
		case '"':
			strings.write_string(w, "&quot;")
		case:
			strings.write_rune(w, c)
		}
	}
}

tag_of :: proc(el: ^k.JSXElement) -> string {
	return k.jsx_element_name_string(el.opening_element.name)
}

template_intrinsic :: proc(el: ^k.JSXElement, parent: string) -> bool {
	tag := tag_of(el)
	// Content models with automatic closing, raw text or foreign insertion
	// rules stay in a browser-owned range unless their context is known.
	switch tag {
	case "main",
	     "article",
	     "section",
	     "header",
	     "footer",
	     "aside",
	     "nav",
	     "div",
	     "span",
	     "p",
	     "h1",
	     "h2",
	     "h3",
	     "h4",
	     "h5",
	     "h6",
	     "output",
	     "b",
	     "strong",
	     "i",
	     "em",
	     "small",
	     "button",
	     "input",
	     "label",
	     "a",
	     "form",
	     "ul",
	     "ol",
	     "li",
	     "br",
	     "table",
	     "caption",
	     "thead",
	     "tbody",
	     "tfoot",
	     "tr",
	     "th",
	     "td":
	case:
		return false
	}
	if (tag == "br" || tag == "input") && len(el.children) > 0 {
		return false
	}

	switch parent {
	case "ul", "ol":
		if tag != "li" {
			return false
		}
	case "table":
		if tag != "thead" && tag != "tbody" && tag != "tfoot" && tag != "caption" {
			return false
		}
	case "thead", "tbody", "tfoot":
		if tag != "tr" {
			return false
		}
	case "tr":
		if tag != "td" && tag != "th" {
			return false
		}
	case "p",
	     "span",
	     "b",
	     "i",
	     "em",
	     "strong",
	     "small",
	     "output",
	     "a",
	     "button",
	     "label",
	     "h1",
	     "h2",
	     "h3",
	     "h4",
	     "h5",
	     "h6":
		switch tag {
		case "span", "b", "i", "em", "strong", "small", "output", "br", "input":
		case:
			return false
		}
	}
	switch tag {
	case "li":
		if parent != "ul" && parent != "ol" {
			return false
		}
	case "thead", "tbody", "tfoot", "caption":
		if parent != "table" {
			return false
		}
	case "tr":
		if parent != "thead" && parent != "tbody" && parent != "tfoot" {
			return false
		}
	case "td", "th":
		if parent != "tr" {
			return false
		}
	}
	return true
}

template_position :: proc(
	b: ^Template_Build,
	el: ^k.JSXElement,
	parent: int,
	parent_tag: string,
) -> bool {
	if !template_intrinsic(el, parent_tag) {
		return false
	}
	// The HTML parser ignores nested <form> even across an intervening div.
	if tag_of(el) == "form" {
		for i := parent; i >= 0; i = b.targets[i].parent {
			if b.targets[i].tag == "form" {
				return false
			}
		}
	}
	return true
}

attribute_html_name :: proc(key: string) -> string {
	switch key {
	case "className":
		return "class"
	case "htmlFor":
		return "for"
	}
	return key
}

write_static_attributes :: proc(b: ^Template_Build, attrs: []k.JSXAttributeItem) {
	// An unknown spread may override any earlier attribute. Emit only the
	// final known value for a given name after the last spread.
	last := make(map[string]int)
	start := 0
	for item, i in attrs {
		switch attr in item {
		case ^k.JSXSpreadAttribute:
			start = i + 1
		case k.JSXAttribute:
			if name, ok := attr.name.(k.JSXIdentifier); ok {
				last[attribute_html_name(name.name)] = i
			}
		}
	}
	for item, i in attrs {
		attr, ok := item.(k.JSXAttribute)
		if !ok || i < start {
			continue
		}
		name, named := attr.name.(k.JSXIdentifier)
		key := attribute_html_name(name.name)
		if !named || last[key] != i {
			continue
		}
		switch key {
		case "id",
		     "class",
		     "for",
		     "role",
		     "title",
		     "type",
		     "name",
		     "placeholder",
		     "disabled",
		     "readonly",
		     "required",
		     "lang",
		     "dir",
		     "tabindex",
		     "colspan",
		     "rowspan",
		     "scope",
		     "value":
		case:
			if !(strings.has_prefix(key, "aria-") || strings.has_prefix(key, "data-")) ||
			   strings.has_prefix(strings.to_lower(key), "data-saba-") {
				continue
			}
		}
		value := ""
		if strings.has_prefix(key, "aria-") || strings.has_prefix(key, "data-") || key == "value" {
			value = "true"
		}
		if expr, present := attr.value.?; present {
			v, literal := expr^.(^k.StringLiteral)
			if !literal {
				continue
			}
			value = jsx_decode_text(b.p, b.p.source[v.loc.start + 1:v.loc.end - 1], v.loc)
		}
		fmt.sbprintf(&b.html, " %s=\"", key)
		html_text(&b.html, value)
		strings.write_byte(&b.html, '"')
	}
}

template_element :: proc(b: ^Template_Build, el: ^k.JSXElement, parent: int) {
	p := b.p
	tag := tag_of(el)
	target := len(b.targets)
	local := b.next_local
	b.next_local += 1
	append(&b.targets, Template_Target{tag, parent, b.instance, local})
	fmt.sbprintf(&b.html, "<%s data-saba-node=\"%d\"", tag, local)
	if local == 0 {
		fmt.sbprintf(&b.html, " data-saba-instance=\"%d\"", b.instance)
	}
	write_static_attributes(b, el.opening_element.attributes[:])
	strings.write_byte(&b.html, '>')
	jsx_emit(p, fmt.tprintf("%s.element(%d, ", b.attach, target))
	emit_attributes(p, el.opening_element, false)
	for child in el.children {
		template_child(b, child, target, tag)
	}
	jsx_emit(p, ")")
	if tag != "br" && tag != "input" {
		fmt.sbprintf(&b.html, "</%s>", tag)
	}
}

// HTML moves non-whitespace table text out of its parent. Keep that text in
// its original runtime position by inserting it only after the parser finishes.
template_text_allowed :: proc(text, parent: string) -> bool {
	if strings.contains(text, "\x00") {
		return false
	}
	switch parent {
	case "table", "thead", "tbody", "tfoot", "tr":
		return strings.trim(text, " \t\n\r\f") == ""
	}
	return true
}

template_child :: proc(b: ^Template_Build, child: k.JSXChild, parent: int, parent_tag: string) {
	p := b.p
	switch v in child {
	case ^k.JSXText:
		text := jsx_decode_text(p, jsx_clean_text(p.source[v.loc.start:v.loc.end]), v.loc)
		if template_text_allowed(text, parent_tag) {
			html_text(&b.html, text)
			return
		}
	case ^k.JSXFragment:
		for ch in v.children {template_child(b, ch, parent, parent_tag)}
		return
	case ^k.JSXElement:
		name := tag_of(v)
		if template_position(b, v, parent, parent_tag) {
			jsx_emit(p, ", ")
			template_element(b, v, parent)
			return
		}
		if fn, ok := b.components[name];
		   ok &&
		   b.names[name] == 1 &&
		   !b.expanding[name] &&
		   fn.root != nil &&
		   template_position(b, fn.root, parent, parent_tag) &&
		   b.instances < 256 {
			b.expanding[name] = true
			setup := template_instance(b, fn, parent)
			b.expanding[name] = false
			jsx_emit(p, ", ")
			use_helper(p, .Factory)
			jsx_emit(p, fmt.tprintf("(%s, ", setup))
			emit_attributes(p, v.opening_element, true)
			emit_children(p, v.children[:])
			jsx_emit(p, ")")
			return
		}
	case ^k.JSXExpressionContainer:
		if text, known := literal_child_text(v.expression);
		   known && template_text_allowed(text, parent_tag) {
			html_text(&b.html, text)
			return
		}
		if _, empty := v.expression^.(^k.JSXEmptyExpression); empty {
			return
		}
	case ^k.JSXSpreadChild:
	}
	target := len(b.targets)
	local := b.next_local
	b.next_local += 1
	append(&b.targets, Template_Target{"", parent, b.instance, local})
	fmt.sbprintf(&b.html, "<!--saba:%d:start--><!--saba:%d:end-->", local, local)
	jsx_emit(p, fmt.tprintf(", %s.range(%d, ", b.attach, target))
	switch v in child {
	case ^k.JSXElement:
		emit_element(p, v, true)
	case ^k.JSXExpressionContainer:
		expr := v.expression
		if spread, ok := expr^.(^k.SpreadElement); ok {
			expr = spread.argument
		}
		emit_binding(p, prepare_hole(p, expr))
	case ^k.JSXSpreadChild:
		emit_binding(p, prepare_hole(p, v.expression))
	case ^k.JSXText:
		jsx_quoted(p, jsx_decode_text(p, jsx_clean_text(p.source[v.loc.start:v.loc.end])))
	case ^k.JSXFragment:
	}
	jsx_emit(p, ")")
}

// Use only values whose JavaScript child normalization can be reproduced
// without evaluating application code or approximating number formatting.
literal_child_text :: proc(expr: ^k.Expression) -> (string, bool) {
	if expr == nil {
		return "", false
	}
	#partial switch v in expr^ {
	case ^k.ParenthesizedExpression:
		return literal_child_text(v.expression)
	case ^k.StringLiteral:
		return v.value, true
	case ^k.NullLiteral, ^k.BooleanLiteral:
		return "", true
	case ^k.NumericLiteral:
		if v.value >= 0 && v.value <= 9007199254740991 && f64(i64(v.value)) == v.value {
			return fmt.tprintf("%d", i64(v.value)), true
		}
	}
	return "", false
}
