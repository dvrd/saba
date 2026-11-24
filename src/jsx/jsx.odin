package saba_jsx

import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:strings"
import k "shared:kessel"

JSX_RUNTIME_URL :: "/__saba/dom.js"

JSX_Error :: struct {
	file:         string,
	line, column: int,
	message:      string,
}

Helper :: enum {
	Factory,
	Fragment,
	Child,
	Binding,
	Text_Binding,
	Live_Prop,
	Merge,
	Register_Slot_Row,
	Effect,
	Paint,
}
helper_exports := [Helper]string {
	.Factory           = "jsx",
	.Fragment          = "Fragment",
	.Child             = "child",
	.Binding           = "binding",
	.Text_Binding      = "textBinding",
	.Live_Prop         = "liveProp",
	.Merge             = "mergeProps",
	.Register_Slot_Row = "registerSlotRow",
	.Effect            = "effect",
	.Paint             = "paint",
}

Emitter :: struct {
	source, file:    string,
	position, depth: int,
	output:          strings.Builder,
	error:           JSX_Error,
	aliases:         [Helper]string,
	gen_line:        int,
	gen_col:         int,
	origins:         [dynamic]Source_Entry,
	template:        bool,
	ranges:          [dynamic]Enclosing,
	// Source-map state. unmapped suppresses entries while text is staged in a
	// side buffer that is emitted again later.
	unmapped:                            int,
	origin_pos, origin_line, origin_col: int,
}

// Kessel v0.4.1 parses and checks recursively without a depth limit. Refuse
// input whose bracket nesting would overflow the native stack before it is
// parsed. Reflection adds several frames per syntax level, so the tree walk
// carries its own, larger frame budget.
MAX_BRACKET_DEPTH :: 256
MAX_VISIT_DEPTH :: 2500

Visit_Guard :: struct {
	depth:    int,
	exceeded: bool,
	located:  bool,
	at:       k.Loc,
}

// An estimate that never needs a tokenizer. Quoted strings are skipped to the
// end of their line. A line that starts with a letter in column zero is taken
// as a new top-level statement and resets the count, so stray brackets in
// comments, regular expressions or JSX text cannot accumulate across a file.
bracket_depth_exceeded :: proc(source: string) -> (at: int, exceeded: bool) {
	depth := 0
	for i := 0; i < len(source); i += 1 {
		switch source[i] {
		case '(', '[', '{':
			depth += 1
			if depth > MAX_BRACKET_DEPTH {
				return i, true
			}
		case ')', ']', '}':
			depth = max(depth - 1, 0)
		case '\'', '"':
			quote := source[i]
			for i += 1; i < len(source) && source[i] != quote && source[i] != '\n'; i += 1 {
				if source[i] == '\\' {
					i += 1
				}
			}
			if i < len(source) && source[i] == '\n' {
				i -= 1
			}
		case '\n':
			if i + 1 < len(source) {
				c := source[i + 1]
				if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' {
					depth = 0
				}
			}
		}
	}
	return 0, false
}

use_helper :: proc(p: ^Emitter, kind: Helper) {
	if p.aliases[kind] == "" {
		p.aliases[kind] = jsx_helper_name(p.source, fmt.tprintf("__saba_%s", helper_exports[kind]))
	}
	jsx_emit(p, p.aliases[kind])
}

// The result belongs to allocator. Keep the original source (including its hashbang)
// byte-for-byte between the outermost JSX expressions.
transform_jsx :: proc(
	source, file: string,
	allocator := context.allocator,
	source_map: ^Source_Map = nil,
) -> (
	javascript: string,
	error: JSX_Error,
) {
	page, failure := compile_module(source, file, false, allocator, nil, source_map)
	return page.javascript, failure
}

compile_page_template :: proc(
	source, file: string,
	allocator := context.allocator,
) -> (
	Page_Template,
	JSX_Error,
) {
	return compile_module(source, file, true, allocator)
}

compile_module :: proc(
	source, file: string,
	template: bool,
	allocator := context.allocator,
	warnings: ^[dynamic]JSX_Error = nil,
	source_map: ^Source_Map = nil,
) -> (
	Page_Template,
	JSX_Error,
) {
	page: Page_Template
	job: k.ParseJob
	config := k.ParseConfig {
		lang_override        = k.Lang.JSX,
		source_type_override = k.SourceType.Module,
		preserve_parens      = true,
	}
	if at, deep := bracket_depth_exceeded(source); deep {
		limit := Emitter{source = source, file = file, position = at}
		jsx_fail(&limit, "Nesting exceeds 256 levels of brackets")
		return {}, limit.error
	}
	if !k.parse_job_open_inline(&job, source, config, file) {
		return {}, {file, 1, 1, "Could not initialize the JSX parser"}
	}
	defer k.parse_job_close(&job)
	context.allocator = job.arena_alloc
	k.parse_job_run(&job)
	if len(job.parser.errors) == 0 {
		k.checker_run_for_job(&job)
	}

	p := Emitter {
		source   = source,
		file     = file,
		template = template,
	}
	if len(job.parser.errors) != 0 {
		err := job.parser.errors[0]
		p.position = int(err.loc)
		// Kessel reports a closing-tag mismatch at the following token.
		if strings.has_prefix(err.message, "Expected corresponding JSX closing tag") {
			if closing := strings.last_index(source[:min(len(source), p.position)], "</");
			   closing >= 0 {
				p.position = closing
			}
		}
		jsx_fail(&p, strings.clone(err.message, allocator))
		return {}, p.error
	}
	// The parser owns an arena for this compilation. Scratch arrays and generated
	// names live there until the result has been copied to its caller.
	p.output = strings.builder_make()
	header_end := 0
	if strings.has_prefix(source, "#!") {
		header_end = strings.index_byte(source, '\n') + 1
		if header_end == 0 {
			header_end = len(source)
		}
	}
	nodes: [dynamic]Syntax
	advice := Snapshot_Advice{&p, warnings, allocator}
	guard: Visit_Guard
	visit_tree(job.program.body, &nodes, nil, advice = &advice, guard = &guard)
	if guard.exceeded {
		p.position = int(guard.at.start)
		jsx_fail(&p, "Expression nesting is too deep to compile")
		return {}, p.error
	}
	if len(nodes) == 0 {
		return Page_Template{javascript = strings.clone(source, allocator)}, {}
	}
	lowered := lower_closed(&p, job.program, &nodes)
	if p.error.message != "" {
		return {}, p.error
	}
	emit_slot_rows(&p, job.program, lowered)
	emit_span(&p, {u32(header_end), u32(len(source))}, nodes[:])
	if p.error.message != "" {
		return {}, p.error
	}

	if template {
		page = extract_page(&p, job.program, allocator)
		if p.error.message != "" {
			return {}, p.error
		}
	}
	result := strings.builder_make(allocator)
	strings.write_string(&result, source[:header_end])
	first := true
	for kind in Helper {
		if p.aliases[kind] == "" {
			continue
		}
		if first {
			strings.write_string(&result, "import { ")
		} else {
			strings.write_string(&result, ", ")
		}
		first = false
		fmt.sbprintf(&result, "%s as %s", helper_exports[kind], p.aliases[kind])
	}
	if !first {
		fmt.sbprintf(&result, " } from \"%s\";\n", JSX_RUNTIME_URL)
	}
	shift := 0
	prefix := strings.to_string(result)
	for i in 0 ..< len(prefix) {
		if prefix[i] == '\n' {
			shift += 1
		}
	}
	strings.write_string(&result, strings.to_string(p.output))
	page.javascript = strings.to_string(result)
	if source_map != nil {
		publish_source_map(source_map, &p, file, shift, allocator)
	}
	return page, {}
}

Syntax :: struct {
	loc:  k.Loc,
	node: union {
		^k.JSXElement,
		^k.JSXFragment,
		string,
	},
	origin: k.Loc,
}
Suspension :: struct {
	awaited: bool,
	yielded: ^k.YieldExpression,
}

// Kessel's AST consists of structs, tagged unions, slices and pointers. Walk
// those containers without having to duplicate its JavaScript statement grammar.
// Expressions are rewritten only where their typed JSX node owns a source span.
visit_tree :: proc(
	tree: any,
	nodes: ^[dynamic]Syntax,
	suspension: ^Suspension,
	names: ^map[string]int = nil,
	jsx_names := false,
	advice: ^Snapshot_Advice = nil,
	guard: ^Visit_Guard = nil,
) {
	if tree.data == nil {
		return
	}
	if guard != nil {
		if guard.exceeded {
			return
		}
		if guard.depth >= MAX_VISIT_DEPTH {
			guard.exceeded = true
			return
		}
		guard.depth += 1
	}
	defer if guard != nil {
		guard.depth -= 1
		// Report at the innermost enclosing node that carries a span.
		if guard.exceeded && !guard.located && reflect.underlying_type_kind(tree.id) == .Struct {
			if loc, ok := reflect.struct_field_value_by_name(tree, "loc").(k.Loc); ok {
				guard.at, guard.located = loc, true
			}
		}
	}
	nodes := nodes
	suspension := suspension
	switch n in tree {
	case ^k.JSXElement:
		if nodes != nil {
			append(nodes, Syntax{n.loc, n, {}})
		}
		if suspension == nil && names == nil {
			return
		}
		nodes = nil
	case ^k.JSXFragment:
		if nodes != nil {
			append(nodes, Syntax{n.loc, n, {}})
		}
		if suspension == nil && names == nil {
			return
		}
		nodes = nil
	case ^k.FunctionDeclaration:
		if advice != nil {
			advise_snapshot(advice, n.params[:], n.body.body[:])
			remember_enclosing(advice.p, n.loc, n.params[:])
		}
		suspension = nil
	case ^k.FunctionExpression:
		if advice != nil {
			advise_snapshot(advice, n.params[:], n.body.body[:])
			remember_enclosing(advice.p, n.loc, n.params[:])
		}
		suspension = nil
	case ^k.ArrowFunctionExpression:
		if advice != nil {
			switch body in n.body {
			case ^k.Expression:
				advise_snapshot(advice, n.params[:], nil, body)
			case ^k.BlockStatement:
				advise_snapshot(advice, n.params[:], body.body[:])
			}
			remember_enclosing(advice.p, n.loc, n.params[:])
		}
		suspension = nil
	case ^k.AwaitExpression:
		if suspension != nil {
			suspension.awaited = true
		}
	case ^k.YieldExpression:
		if suspension != nil {
			suspension.yielded = n
		}
	case k.Identifier:
		if names != nil {
			names^[n.name] += 1
		}
	case k.JSXIdentifier:
		if names != nil && jsx_names {
			names^[n.name] += 1
		}
	case k.BindingIdentifier:
		if names != nil {
			names^[n.name] += 1
		}
	case k.Loc:
		return
	}
	if nodes == nil && suspension == nil && names == nil {
		return
	}
	#partial switch reflect.underlying_type_kind(tree.id) {
	case .Pointer:
		visit_tree(reflect.deref(tree), nodes, suspension, names, jsx_names, advice, guard)
	case .Union:
		visit_tree(reflect.get_union_variant(tree), nodes, suspension, names, jsx_names, advice, guard)
	case .Slice, .Dynamic_Array:
		for i in 0 ..< reflect.length(tree) {
			visit_tree(reflect.index(tree, i), nodes, suspension, names, jsx_names, advice, guard)
		}
	case .Struct:
		for i in 0 ..< reflect.struct_field_count(tree.id) {
			field := reflect.struct_field_at(tree.id, i)
			visit_tree(
				reflect.struct_field_value(tree, field),
				nodes,
				suspension,
				names,
				jsx_names,
				advice,
				guard,
			)
		}
	}
}

emit_span :: proc(p: ^Emitter, loc: k.Loc, nodes: []Syntax) {
	slice.sort_by(nodes, proc(a, b: Syntax) -> bool {return a.loc.start < b.loc.start})
	cursor := loc.start
	for item in nodes {
		// Some shorthand/pattern nodes share references in the tree.
		if item.loc.start < cursor {
			continue
		}
		emit_source(p, cursor, item.loc.start)
		switch node in item.node {
		case ^k.JSXElement:
			emit_element(p, node, false)
		case ^k.JSXFragment:
			emit_fragment(p, node, false)
		case string:
			if item.origin.end > item.origin.start {
				note_origin(p, item.origin)
			}
			jsx_emit(p, node)
		}
		cursor = item.loc.end
	}
	emit_source(p, cursor, loc.end)
}

one_shot :: proc(expr: ^k.Expression) -> bool {
	#partial switch v in expr^ {
	case ^k.NullLiteral,
	     ^k.BooleanLiteral,
	     ^k.NumericLiteral,
	     ^k.StringLiteral,
	     ^k.BigIntLiteral,
	     ^k.Identifier,
	     ^k.FunctionExpression,
	     ^k.ArrowFunctionExpression:
		return true
	case ^k.ParenthesizedExpression:
		return one_shot(v.expression)
	}
	return false
}

Hole :: struct {
	expr:  ^k.Expression,
	nodes: [dynamic]Syntax,
	live:  bool,
}

prepare_hole :: proc(p: ^Emitter, expr: ^k.Expression, force_snapshot := false) -> (hole: Hole) {
	hole.expr = expr
	suspension: Suspension
	guard: Visit_Guard
	visit_tree(expr, &hole.nodes, &suspension, guard = &guard)
	if guard.exceeded {
		p.position = int(guard.at.start if guard.located else k.get_expression_loc(expr).start)
		jsx_fail(p, "Expression nesting is too deep to compile")
	}
	if suspension.yielded != nil {
		p.position = int(suspension.yielded.loc.start)
		jsx_fail(p, "Assign the yield result to a variable before using it in JSX")
	}
	hole.live = !force_snapshot && !suspension.awaited && !one_shot(expr)
	return
}

emit_value :: proc(p: ^Emitter, hole: Hole) {
	jsx_emit(p, "(")
	emit_span(p, k.get_expression_loc(hole.expr), hole.nodes[:])
	jsx_emit(p, ")")
}

// On success these expressions always produce a primitive string. Keep the
// original expression in the reader: coercions and getters can read signals.
produces_string :: proc(expr: ^k.Expression) -> bool {
	#partial switch v in expr^ {
	case ^k.StringLiteral, ^k.TemplateLiteral:
		return true
	case ^k.ParenthesizedExpression:
		return produces_string(v.expression)
	case ^k.BinaryExpression:
		return v.operator == .Add && (produces_string(v.left) || produces_string(v.right))
	case ^k.ConditionalExpression:
		return produces_string(v.consequent) && produces_string(v.alternate)
	case ^k.UnaryExpression:
		return v.operator == .Typeof
	}
	return false
}

emit_binding :: proc(p: ^Emitter, hole: Hole, sole_intrinsic_child := false) {
	if hole.live {
		if sole_intrinsic_child && produces_string(hole.expr) {
			use_helper(p, .Text_Binding)
		} else {
			use_helper(p, .Binding)
		}
		jsx_emit(p, "(() => ")
	}
	emit_value(p, hole)
	if hole.live {
		jsx_emit(p, ")")
	}
}

emit_element :: proc(p: ^Emitter, el: ^k.JSXElement, deferred: bool) {
	p.depth += 1
	defer p.depth -= 1
	p.position = int(el.loc.start)
	note_origin(p, el.loc)
	if emit_direct_hole(p, el) {
		return
	}
	if p.depth > 128 {
		jsx_fail(p, "JSX nesting exceeds 128 levels"); return
	}
	opening := el.opening_element
	tag := k.jsx_element_name_string(opening.name)
	component := true
	switch n in opening.name {
	case ^k.JSXNamespacedName:
		jsx_fail(p, "Namespaced JSX tags are not supported")
		return
	case k.JSXIdentifier:
		component = !(n.name[0] >= 'a' && n.name[0] <= 'z')
		if component && strings.contains(tag, "-") {
			jsx_fail(p, "Component names must be JavaScript identifiers"); return
		}
	case ^k.JSXMemberExpression:
	}
	use_helper(p, .Child if deferred else .Factory)
	jsx_emit(p, "(")
	if component {
		jsx_emit(p, tag)
	} else {
		jsx_quoted(p, tag)
	}
	jsx_emit(p, ", ")
	emit_attributes(p, opening, component)
	emit_children(p, el.children[:], !component && emits_one_child(p, el.children[:]))
	jsx_emit(p, ")")
}

emit_fragment :: proc(p: ^Emitter, el: ^k.JSXFragment, deferred: bool) {
	p.depth += 1
	defer p.depth -= 1
	p.position = int(el.loc.start)
	note_origin(p, el.loc)
	if p.depth > 128 {
		jsx_fail(p, "JSX nesting exceeds 128 levels"); return
	}
	use_helper(p, .Child if deferred else .Factory)
	jsx_emit(p, "(")
	use_helper(p, .Fragment)
	jsx_emit(p, ", null")
	emit_children(p, el.children[:])
	jsx_emit(p, ")")
}

// Ignore the same indentation and JSX comments as emit_children. Leave range
// boundaries between siblings so DOM normalize() cannot merge live text nodes.
emits_one_child :: proc(p: ^Emitter, children: []k.JSXChild) -> bool {
	if len(children) <= 1 {
		return len(children) == 1
	}
	found := false
	for child in children {
		#partial switch v in child {
		case ^k.JSXText:
			if jsx_clean_text(p.source[v.loc.start:v.loc.end]) == "" {continue}
		case ^k.JSXExpressionContainer:
			if _, empty := v.expression^.(^k.JSXEmptyExpression); empty {continue}
		}
		if found {return false}
		found = true
	}
	return found
}

emit_children :: proc(p: ^Emitter, children: []k.JSXChild, sole_intrinsic_child := false) {
	for child in children {
		if p.error.message != "" {
			return
		}
		switch v in child {
		case ^k.JSXText:
			p.position = int(v.loc.start)
			jsx_text_child(p, p.source[v.loc.start:v.loc.end], v.loc)
		case ^k.JSXElement:
			jsx_emit(p, ", ")
			emit_element(p, v, true)
		case ^k.JSXFragment:
			jsx_emit(p, ", ")
			emit_fragment(p, v, true)
		case ^k.JSXExpressionContainer:
			expr := v.expression
			if empty, ok := expr^.(^k.JSXEmptyExpression); ok {
				if !empty_jsx_hole(p.source[empty.loc.start:empty.loc.end]) {
					p.position = int(empty.loc.start)
					jsx_fail(p, "Expected a JSX child expression after the spread")
					return
				}
				continue
			}
			// Kessel v0.4.1 parses spread children as a SpreadElement inside
			// the container. Saba's child normalization flattens their arrays.
			spread, is_spread := expr^.(^k.SpreadElement)
			if is_spread {
				expr = spread.argument
			}
			if k.expression_inner_nil(expr) ||
			   k.get_expression_loc(expr).end <= k.get_expression_loc(expr).start {
				p.position = int(v.loc.start)
				jsx_fail(p, "Empty JSX spread child")
				return
			}
			jsx_emit(p, ", ")
			emit_binding(p, prepare_hole(p, expr), sole_intrinsic_child && !is_spread)
		case ^k.JSXSpreadChild:
			jsx_emit(p, ", ")
			emit_binding(p, prepare_hole(p, v.expression))
		}
	}
}

Attribute :: struct {
	name:           string,
	hole:           Hole,
	quoted:         string,
	span:           k.Loc,
	is_string:      bool,
	spread, getter: bool,
}

emit_attributes :: proc(p: ^Emitter, opening: ^k.JSXOpeningElement, component: bool) {
	attributes: [dynamic]Attribute
	prev_end := opening.loc.start
	for item in opening.attributes {
		attr: Attribute
		loc: k.Loc
		switch v in item {
		case ^k.JSXSpreadAttribute:
			attr.spread = true
			loc = v.loc
			if k.expression_inner_nil(v.argument) {
				p.position = int(loc.start)
				jsx_fail(p, "Empty spread attribute")
				return
			}
			attr.hole = prepare_hole(p, v.argument, true)
		case k.JSXAttribute:
			loc = v.loc
			switch name in v.name {
			case k.JSXIdentifier:
				attr.name = name.name
			case ^k.JSXNamespacedName:
				attr.name = fmt.tprintf("%s:%s", name.namespace.name, name.name.name)
			}
			if expr, ok := v.value.?; ok {
				#partial switch value in expr^ {
				case ^k.StringLiteral:
					attr.is_string = true
					attr.quoted = p.source[value.loc.start + 1:value.loc.end - 1]
					attr.span = value.loc
				case ^k.JSXExpressionContainer:
					if _, empty := value.expression^.(^k.JSXEmptyExpression); empty {
						p.position = int(loc.start)
						jsx_fail(p, "JSX attribute expressions cannot be empty")
						return
					}
					event :=
						len(attr.name) > 2 &&
						strings.has_prefix(attr.name, "on") &&
						attr.name[2] >= 'A' &&
						attr.name[2] <= 'Z'
					attr.hole = prepare_hole(p, value.expression, event || attr.name == "ref")
				case ^k.JSXElement, ^k.JSXFragment:
					attr.hole = prepare_hole(p, expr)
				}
				attr.getter = component && attr.hole.live
			}
		}
		if loc.start == prev_end {
			p.position = int(loc.start)
			jsx_fail(p, "Separate JSX attributes with whitespace")
			return
		}
		prev_end = loc.end
		append(&attributes, attr)
	}
	// Consecutive ordinary attributes share one object literal. Enumerate
	// spreads on reaching them, before evaluating the next attribute's value.
	parts: [dynamic][]Attribute
	start := 0
	for attr, i in attributes {
		if attr.spread || attr.getter {
			if start < i {
				append(&parts, attributes[start:i])
			}
			append(&parts, attributes[i:i + 1])
			start = i + 1
		}
	}
	if start < len(attributes) {
		append(&parts, attributes[start:])
	}
	if len(parts) == 0 {
		jsx_emit(p, "{}"); return
	}
	if len(parts) > 1 {
		use_helper(p, .Merge); jsx_emit(p, "(")
	}
	for part, index in parts {
		if index > 0 {
			jsx_emit(p, ", ")
		}
		attr := part[0]
		if attr.spread {
			// Snapshot the enumerable keys here, even for a sole spread, while
			// retaining its accessors. A later attribute can mutate this object.
			use_helper(p, .Merge)
			jsx_emit(p, "(")
			emit_value(p, attr.hole)
			jsx_emit(p, ")")
		} else if attr.getter {
			use_helper(p, .Live_Prop)
			jsx_emit(p, "(")
			jsx_quoted(p, attr.name)
			jsx_emit(p, ", () => ")
			emit_value(p, attr.hole)
			jsx_emit(p, ")")
		} else {
			jsx_emit(p, "{")
			for prop in part {
				if prop.name == "__proto__" {
					jsx_emit(p, "[")
				}
				jsx_quoted(p, prop.name)
				if prop.name == "__proto__" {
					jsx_emit(p, "]")
				}
				jsx_emit(p, ": ")
				if prop.is_string {
					jsx_entity_string(p, prop.quoted, prop.span)
				} else if prop.hole.expr != nil {
					emit_binding(p, prop.hole)
				} else {
					jsx_emit(p, "true")
				}
				jsx_emit(p, ",")
			}
			jsx_emit(p, "}")
		}
	}
	if len(parts) > 1 {
		jsx_emit(p, ")")
	}
}
