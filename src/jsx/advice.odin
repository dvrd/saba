package saba_jsx

import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"
import k "shared:kessel"

Snapshot_Advice :: struct {
	p:         ^Emitter,
	warnings:  ^[dynamic]JSX_Error,
	allocator: mem.Allocator,
}

// Visit direct JSX reads in the returned element tree. Ordinary JavaScript
// expressions may introduce shadowing scopes, so do not infer bindings there.
advise_snapshot :: proc(
	a: ^Snapshot_Advice,
	params: []k.FunctionParameter,
	body: []^k.Statement,
	result: ^k.Expression = nil,
) {
	if len(params) != 1 {
		return
	}
	result := result
	first := params[0].pattern
	object, destructured := first.(^k.ObjectPattern)
	parameter, named := first.(^k.Identifier)
	if !destructured && !named {
		return
	}
	props := make(map[string]string)
	add_object :: proc(props: ^map[string]string, object: ^k.ObjectPattern, receiver: string) {
		for field in object.properties {
			local, ok := field.value.(^k.Identifier)
			if !ok || field.computed {
				continue
			}
			property := local.name
			if key, found := field.key.?; found {
				id, simple := key.(k.IdentifierName)
				if !simple {
					continue
				}
				property = id.name
			}
			props^[local.name] = fmt.aprintf("%s.%s", receiver, property)
		}
	}
	if destructured {
		add_object(&props, object, "props")
	}
	if result == nil && len(body) > 0 {
		ret, tail := body[len(body) - 1]^.(^k.ReturnStatement)
		if !tail {
			return
		}
		result, _ = ret.argument.?
		if named {
			for s in body[:len(body) - 1] {
				declaration, ok := s^.(^k.VariableDeclaration)
				if !ok || declaration.kind != .Const {
					continue
				}
				for d in declaration.declarations {
					pattern, obj := d.id.(^k.ObjectPattern)
					initial, has_init := d.init.?
					if !obj || !has_init {
						continue
					}
					source, direct := initial^.(^k.Identifier)
					if direct && source.name == parameter.name {
						add_object(&props, pattern, source.name)
					}
				}
			}
		}
	}
	if len(props) == 0 || result == nil {
		return
	}
	for {
		if parens, ok := result^.(^k.ParenthesizedExpression); ok {
			result = parens.expression; continue
		}
		break
	}
	#partial switch node in result^ {
	case ^k.JSXElement:
		advise_child(a, &props, node)
	case ^k.JSXFragment:
		advise_child(a, &props, node)
	}
}

advise_child :: proc(a: ^Snapshot_Advice, props: ^map[string]string, child: k.JSXChild) {
	switch v in child {
	case ^k.JSXElement:
		for item in v.opening_element.attributes {
			attr, ok := item.(k.JSXAttribute)
			if !ok {
				continue
			}
			name, simple := attr.name.(k.JSXIdentifier)
			if !simple || name.name == "ref" || strings.has_prefix(name.name, "on") {
				continue
			}
			if value, present := attr.value.?; present {
				if hole, held := value^.(^k.JSXExpressionContainer); held {
					advise_child(a, props, hole)
				}
			}
		}
		for sub in v.children {advise_child(a, props, sub)}
	case ^k.JSXFragment:
		for sub in v.children {advise_child(a, props, sub)}
	case ^k.JSXExpressionContainer:
		expr := v.expression
		for {
			if parens, ok := expr^.(^k.ParenthesizedExpression); ok {
				expr = parens.expression; continue
			}
			break
		}
		id, bare := expr^.(^k.Identifier)
		if !bare {
			return
		}
		property, tracked := props^[id.name]
		if !tracked {
			return
		}
		delete_key(props, id.name) // Report each destructured binding once per component.
		message := fmt.tprintf(
			"Destructured %s is a setup snapshot. Read %s in JSX to follow later changes.",
			id.name,
			property,
		)
		d := jsx_diagnostic(a.p, int(id.loc.start), message)
		if a.warnings != nil {
			d.message = strings.clone(d.message, a.allocator)
			// The ambient allocator is the parser arena, which is released on
			// return. A caller's empty array must grow in the caller's allocator.
			if a.warnings.allocator.procedure == nil {
				a.warnings.allocator = a.allocator
			}
			append(a.warnings, d)
		} else {
			log.warnf("%s:%d:%d: %s", d.file, d.line, d.column, d.message)
		}
	case ^k.JSXText, ^k.JSXSpreadChild:
	}
}
