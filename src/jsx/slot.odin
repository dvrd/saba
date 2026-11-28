package saba_jsx

import "core:slice"
import "core:strings"
import k "shared:kessel"

// Only hoisted, module-scope declarations can be registered before user code
// runs. Imported row functions carry their registration through their identity.
emit_slot_rows :: proc(p: ^Emitter, program: ^k.Program) {
	for statement in program.body {
		#partial switch s in statement^ {
		case ^k.FunctionDeclaration:
			emit_slot_row(p, &s.expr)
		case ^k.ExportNamedDeclaration:
			if d, ok := s.declaration.?; ok {
				if fn, found := d^.(^k.FunctionDeclaration); found {
					emit_slot_row(p, &fn.expr)
				}
			}
		case ^k.ExportDefaultDeclaration:
			switch d in s.declaration^ {
			case ^k.Declaration:
				if fn, found := d^.(^k.FunctionDeclaration); found {
					emit_slot_row(p, &fn.expr)
				}
			case ^k.Expression:
				// Kessel represents the bare default declaration as an expression.
				// A parenthesized function here has no module-scope name.
				if fn, found := d^.(^k.FunctionExpression); found {
					emit_slot_row(p, fn)
				}
			}
		}
	}
}

slot_attribute :: proc(name: string) -> bool {
	if name == "class" || name == "title" {return true}
	if len(name) <= 5 || !(strings.has_prefix(name, "data-") || strings.has_prefix(name, "aria-")) {
		return false
	}
	for c in name[5:] {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {return false}
	}
	return true
}

Slot_Read :: struct {
	loc: k.Loc,
	field: string,
	parts: []string,
}

// Collect only calls to the row accessor used as the base of a direct property
// read. Copying the intervening source preserves numeric addition, parentheses,
// escaped templates and evaluation order without a second JavaScript printer.
slot_reads :: proc(expr: ^k.Expression, param: string, reads: ^[dynamic]Slot_Read) -> bool {
	#partial switch v in expr^ {
	case ^k.StringLiteral, ^k.NumericLiteral:
		return true
	case ^k.ParenthesizedExpression:
		return slot_reads(v.expression, param, reads)
	case ^k.BinaryExpression:
		// a + b + c is left-deep. Walk down the left operands in a loop, then
		// read the operands in source order, so a long chain costs no stack
		// and the reads stay ordered for emit_slot_expression.
		operands: [dynamic]^k.Expression
		current := expr
		for {
			binary, is_binary := current^.(^k.BinaryExpression)
			if !is_binary {
				break
			}
			if binary.operator != .Add {
				return false
			}
			append(&operands, binary.right)
			current = binary.left
		}
		if !slot_reads(current, param, reads) {
			return false
		}
		for i := len(operands) - 1; i >= 0; i -= 1 {
			if !slot_reads(operands[i], param, reads) {
				return false
			}
		}
		return true
	case ^k.TemplateLiteral:
		for hole in v.expressions {
			if !slot_reads(hole, param, reads) {return false}
		}
		return true
	case ^k.MemberExpression:
		// A chain record().author.name is one read. A single record().id keeps
		// the same span the flat emitter already replaces with row["id"].
		if v.computed || v.optional {return false}
		parts: [dynamic]string
		current := expr
		for {
			member, is_member := unwrap(current)^.(^k.MemberExpression)
			if !is_member || member.computed || member.optional {break}
			field, named := member.property^.(^k.Identifier)
			if !named {return false}
			append(&parts, field.name)
			current = member.object
		}
		call, called := unwrap(current)^.(^k.CallExpression)
		if !called || call.optional || len(call.arguments) != 0 || len(parts) == 0 {return false}
		accessor, ok := call.callee^.(^k.Identifier)
		if !ok || accessor.name != param {return false}
		for i, j := 0, len(parts) - 1; i < j; i, j = i + 1, j - 1 {
			parts[i], parts[j] = parts[j], parts[i]
		}
		label := parts[0]
		if len(parts) > 1 {
			label = strings.join(parts[:], ".")
		}
		saved := make([]string, len(parts))
		copy(saved, parts[:])
		append(reads, Slot_Read{k.get_expression_loc(expr), label, saved})
		return true
	}
	return false
}

emit_slot_expression :: proc(p: ^Emitter, expr: ^k.Expression, param: string, fields: ^[dynamic]string) -> bool {
	reads: [dynamic]Slot_Read
	if !slot_reads(expr, param, &reads) || len(reads) == 0 {return false}
	loc := k.get_expression_loc(expr)
	cursor := loc.start
	for read in reads {
		jsx_emit(p, p.source[cursor:read.loc.start])
		if len(read.parts) == 0 {
			jsx_emit(p, "row[")
			jsx_quoted(p, read.field)
			jsx_emit(p, "]")
		} else {
			for part, index in read.parts {
				jsx_emit(p, "row[" if index == 0 else "[")
				jsx_quoted(p, part)
				jsx_emit(p, "]")
			}
		}
		if !slice.contains(fields[:], read.field) {append(fields, read.field)}
		cursor = read.loc.end
	}
	jsx_emit(p, p.source[cursor:loc.end])
	return true
}

slot_text :: proc(p: ^Emitter, el: ^k.JSXElement) -> ^k.Expression {
	if !emits_one_child(p, el.children[:]) {return nil}
	for child in el.children {
		if v, ok := child.(^k.JSXExpressionContainer); ok && produces_string(v.expression) {
			return v.expression
		}
	}
	return nil
}

emit_slot_row :: proc(p: ^Emitter, fn: ^k.FunctionExpression) {
	name, named := fn.id.?
	if !named || fn.async || fn.generator || len(fn.params) != 1 || len(fn.body.body) != 1 ||
	   fn.params[0].default_val != nil {return}
	param, simple := fn.params[0].pattern.(^k.Identifier)
	if !simple {return}
	el := body_element(fn.body.body[:])
	if el == nil {return}
	tag, intrinsic := el.opening_element.name.(k.JSXIdentifier)
	if !intrinsic || !slice.contains([]string{"div", "span", "p", "li", "td", "th"}, tag.name) {return}
	child := slot_text(p, el)
	if child == nil {return}

	static_attrs := Emitter{source = p.source, output = strings.builder_make()}
	writer := Emitter{source = p.source, output = strings.builder_make()}
	names, fields: [dynamic]string
	for item in el.opening_element.attributes {
		attr, plain := item.(k.JSXAttribute)
		if !plain {return}
		key, identifier := attr.name.(k.JSXIdentifier)
		value, initialized := attr.value.?
		if !identifier || !initialized || !slot_attribute(key.name) || slice.contains(names[:], key.name) {return}
		append(&names, key.name)
		#partial switch v in value^ {
		case ^k.StringLiteral:
			// The runtime creates static attributes first. Preserve the JSX
			// attribute order observable through attributes and outerHTML.
			if len(fields) != 0 {return}
			jsx_quoted(&static_attrs, key.name)
			jsx_emit(&static_attrs, ":")
			jsx_entity_string(&static_attrs, p.source[v.loc.start + 1:v.loc.end - 1])
			jsx_emit(&static_attrs, ",")
		case ^k.JSXExpressionContainer:
			if produces_string(v.expression) {
				jsx_emit(&writer, "element.setAttribute(")
				jsx_quoted(&writer, key.name)
				jsx_emit(&writer, ", ")
				if !emit_slot_expression(&writer, v.expression, param.name, &fields) {return}
				jsx_emit(&writer, "); ")
				continue
			}
			// Any other value follows the runtime's attribute rules, as the
			// closed rows do: nullish removes the attribute, false removes it
			// unless the name is data-* or aria-*, and true is the empty string.
			// The write reaches String through globalThis, so a module that
			// names globalThis keeps its row on tracked bindings.
			if !globals_unshadowed(p) {return}
			jsx_emit(&writer, "{ const value = ")
			if !emit_slot_expression(&writer, v.expression, param.name, &fields) {return}
			jsx_emit(&writer, "; if (value == null")
			if !strict_attribute(key.name) {
				jsx_emit(&writer, " || value === false")
			}
			jsx_emit(&writer, ") element.removeAttribute(")
			jsx_quoted(&writer, key.name)
			jsx_emit(&writer, "); else element.setAttribute(")
			jsx_quoted(&writer, key.name)
			jsx_emit(&writer, ", globalThis.String(value));" if strict_attribute(key.name) else ", value === true ? \"\" : globalThis.String(value));")
			jsx_emit(&writer, " } ")
		case:
			return
		}
	}
	jsx_emit(&writer, "text.data = ")
	if !emit_slot_expression(&writer, child, param.name, &fields) {return}
	for field in fields {
		if strings.contains(field, ".") {return}
	}

	use_helper(p, .Register_Slot_Row)
	jsx_emit(p, "(")
	jsx_emit(p, name.name)
	jsx_emit(p, ", {tag:")
	jsx_quoted(p, tag.name)
	jsx_emit(p, ", attrs:{")
	jsx_emit(p, strings.to_string(static_attrs.output))
	jsx_emit(p, "}, fields:[")
	for field, i in fields {
		if i != 0 {jsx_emit(p, ",")}
		jsx_quoted(p, field)
	}
	jsx_emit(p, "], write(element, text, row) { ")
	jsx_emit(p, strings.to_string(writer.output))
	jsx_emit(p, "; }});\n")
}
