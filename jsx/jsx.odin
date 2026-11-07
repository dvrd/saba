package saba_jsx

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

JSX_Error :: struct {
	file:         string,
	line, column: int,
	message:      string,
}

@(private)
JSX_Parser :: struct {
	source, file:            string,
	position, depth:         int,
	output:                  strings.Builder,
	error:                   JSX_Error,
	factory, fragment:       string,
	uses_jsx, uses_fragment: bool,
}

// The result belongs to allocator. JavaScript outside JSX is copied verbatim.
// JSX helpers are imported from Saba’s embedded runtime using private aliases.
transform_jsx :: proc(
	source, file: string,
	allocator := context.allocator,
) -> (
	javascript: string,
	error: JSX_Error,
) {
	context.allocator = allocator
	p := JSX_Parser {
		source   = source,
		file     = file,
		output   = strings.builder_make(),
		factory  = jsx_helper_name(source, "__saba_jsx"),
		fragment = jsx_helper_name(source, "__saba_Fragment"),
	}
	// A hashbang must remain the first line, before any generated import.
	if strings.has_prefix(source, "#!") {
		for p.position < len(source) && source[p.position] != '\n' do p.position += 1
		if p.position < len(source) do p.position += 1
		jsx_emit(&p, source[:p.position])
	}
	header_length := p.position
	jsx_javascript_scan(&p, statements = true)
	if p.error.message != "" {
		strings.builder_destroy(&p.output)
		return "", p.error
	}
	if !p.uses_jsx do return strings.to_string(p.output), {}
	defer strings.builder_destroy(&p.output)
	result := strings.builder_make()
	strings.write_string(&result, source[:header_length])
	strings.write_string(&result, "import { jsx as ")
	strings.write_string(&result, p.factory)
	if p.uses_fragment {
		strings.write_string(&result, ", Fragment as ")
		strings.write_string(&result, p.fragment)
	}
	strings.write_string(&result, " } from ")
	encoded, _ := json.marshal(JSX_RUNTIME_URL)
	defer delete(encoded)
	strings.write_string(&result, string(encoded))
	strings.write_string(&result, ";\n")
	strings.write_string(&result, string(p.output.buf[header_length:]))
	return strings.to_string(result), {}
}

// Reserve names across every scope, including escaped identifiers. Reserving text
// in strings/comments too is harmless and avoids needing a JavaScript scope tree.
@(private)
jsx_helper_name :: proc(source, base: string) -> string {
	decoded := strings.builder_make()
	defer strings.builder_destroy(&decoded)
	for i := 0; i < len(source); i += 1 {
		if source[i] == '\\' && i + 2 < len(source) && source[i + 1] == 'u' {
			start := i + 2
			braced := source[start] == '{'
			if braced do start += 1
			end := start
			value := 0
			for end < len(source) && end - start < 6 {
				c := source[end]
				digit := -1
				if c >= '0' && c <= '9' do digit = int(c - '0')
				if c >= 'a' && c <= 'f' do digit = int(c - 'a') + 10
				if c >= 'A' && c <= 'F' do digit = int(c - 'A') + 10
				if digit < 0 do break
				value = value * 16 + digit
				end += 1
				if !braced && end - start == 4 do break
			}
			valid := end - start == 4
			if braced {
				valid = end > start && end < len(source) && source[end] == '}'
			}
			if valid && value < 128 {
				strings.write_byte(&decoded, u8(value))
				i = end if braced else end - 1
				continue
			}
		}
		strings.write_byte(&decoded, source[i])
	}
	reserved := strings.to_string(decoded)
	name := base
	for suffix := 1; strings.contains(reserved, name); suffix += 1 {
		name = fmt.aprintf("%s_%d", base, suffix)
	}
	return name
}

@(private)
jsx_fail :: proc(p: ^JSX_Parser, message: string) {
	if p.error.message != "" do return
	line, column := 1, 1
	for r in p.source[:min(p.position, len(p.source))] {
		if r == '\n' {line += 1;column = 1} else {column += 1}
	}
	p.error = {p.file, line, column, message}
}

@(private)
jsx_emit :: proc(p: ^JSX_Parser, text: string) {
	strings.write_string(&p.output, text)
}

@(private)
jsx_quoted :: proc(p: ^JSX_Parser, text: string) {
	encoded, err := json.marshal(text)
	if err != nil {jsx_fail(p, "Could not encode JSX text");return}
	defer delete(encoded)
	jsx_emit(p, string(encoded))
}

@(private)
jsx_peek :: proc(p: ^JSX_Parser, offset := 0) -> u8 {
	index := p.position + offset
	return p.source[index] if index < len(p.source) else 0
}

@(private)
jsx_take :: proc(p: ^JSX_Parser, text: string) -> bool {
	if !strings.has_prefix(p.source[p.position:], text) do return false
	p.position += len(text)
	return true
}

@(private)
jsx_space :: proc(c: u8) -> bool {return c == ' ' || c == '\n' || c == '\r' || c == '\t'}
@(private)
jsx_identifier_start :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || c == '$' || c >= 128
}
@(private)
jsx_identifier_part :: proc(c: u8) -> bool {return jsx_identifier_start(c) || c >= '0' && c <= '9'}

@(private)
jsx_whitespace :: proc(p: ^JSX_Parser) {
	for jsx_space(jsx_peek(p)) do p.position += 1
}

@(private)
jsx_name :: proc(p: ^JSX_Parser) -> string {
	start := p.position
	if !jsx_identifier_start(jsx_peek(p)) {jsx_fail(p, "Expected a JSX name");return ""}
	p.position += 1
	for jsx_identifier_part(jsx_peek(p)) || jsx_peek(p) == '-' || jsx_peek(p) == '.' || jsx_peek(p) == ':' do p.position += 1
	return p.source[start:p.position]
}

// JSX whitespace follows the usual line-trimming rule, retaining intentional
// spaces on a single line and joining nonempty indented lines with one space.
@(private)
jsx_text_child :: proc(p: ^JSX_Parser, text: string) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	lines := strings.split_lines(text)
	defer delete(lines)
	last := -1
	for line, i in lines {if strings.trim_space(line) != "" do last = i}
	for raw_line, i in lines {
		line := raw_line
		line = strings.trim_right(line, "\r")
		if i > 0 do line = strings.trim_left(line, " \t")
		if i < len(lines) - 1 do line = strings.trim_right(line, " \t")
		for c in line {strings.write_rune(&b, ' ' if c == '\t' else c)}
		if len(line) > 0 && i < last do strings.write_byte(&b, ' ')
	}
	if len(b.buf) > 0 {
		jsx_emit(p, ", ")
		jsx_entity_string(p, strings.to_string(b))
	}
}

@(private)
jsx_expression :: proc(p: ^JSX_Parser, allow_empty := false) {
	if !jsx_take(p, "{") {jsx_fail(p, "Expected an expression in braces");return}
	start := len(p.output.buf)
	has_tokens := jsx_javascript_scan(p, '}', reject_spread = true)
	if !jsx_take(p, "}") {jsx_fail(p, "Unclosed JSX expression");return}
	if !has_tokens do resize(&p.output.buf, start)
	// A comment-only child is empty. An attribute expression must have a value.
	value := strings.trim_space(string(p.output.buf[start:]))
	if value == "" && !allow_empty do jsx_fail(p, "JSX attribute expressions cannot be empty")
}

@(private)
jsx_element :: proc(p: ^JSX_Parser) {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > 128 {jsx_fail(p, "JSX nesting exceeds 128 levels");return}
	if !jsx_take(p, "<") {jsx_fail(p, "Expected <");return}
	fragment := jsx_take(p, ">")
	tag := ""
	p.uses_jsx = true
	jsx_emit(p, p.factory)
	jsx_emit(p, "(")
	if fragment {
		p.uses_fragment = true
		jsx_emit(p, p.fragment)
		jsx_emit(p, ", null")
	} else {
		tag = jsx_name(p)
		if p.error.message != "" do return
		if strings.contains(tag, ":") {jsx_fail(p, "Namespaced JSX tags are not supported");return}
		if strings.contains(tag, ".") {
			if strings.has_suffix(
				tag,
				".",
			) {jsx_fail(p, "Empty JSX component name segment");return}
			rest := tag
			for part in strings.split_iterator(&rest, ".") {
				if len(part) == 0 {jsx_fail(p, "Empty JSX component name segment");return}
				for i in 0 ..< len(part) {
					if (i == 0 && !jsx_identifier_start(part[i])) ||
					   (i > 0 && !jsx_identifier_part(part[i])) {
						jsx_fail(p, "Invalid JSX component member name");return
					}
				}
			}
		}
		if tag[0] >= 'a' && tag[0] <= 'z' && !strings.contains(tag, ".") {
			jsx_quoted(p, tag)
		} else {
			if strings.contains(
				tag,
				"-",
			) {jsx_fail(p, "Component names must be JavaScript identifiers");return}
			jsx_emit(p, tag)
		}
		jsx_emit(p, ", {")
		for p.error.message == "" {
			before := p.position
			jsx_whitespace(p)
			if jsx_take(p, "/>") {jsx_emit(p, "})");return}
			if jsx_take(p, ">") do break
			if jsx_peek(p) == 0 {jsx_fail(p, "Unclosed JSX opening tag");return}
			if p.position == before {jsx_fail(p, "Separate JSX attributes with whitespace");return}
			if jsx_take(p, "{") {
				jsx_whitespace(p)
				if !jsx_take(
					p,
					"...",
				) {jsx_fail(p, "Expected a spread attribute: {...properties}");return}
				jsx_emit(p, "...(")
				start := len(p.output.buf)
				has_tokens := jsx_javascript_scan(p, '}')
				if !has_tokens ||
				   strings.trim_space(string(p.output.buf[start:])) ==
					   "" {jsx_fail(p, "Empty spread attribute");return}
				if !jsx_take(p, "}") {jsx_fail(p, "Unclosed spread attribute");return}
				jsx_emit(p, "),")
				continue
			}
			attribute := jsx_name(p)
			if p.error.message != "" do return
			if strings.contains(
				attribute,
				".",
			) {jsx_fail(p, "JSX attribute names cannot contain a dot");return}
			jsx_quoted(p, attribute)
			jsx_emit(p, ": ")
			// Preserve separating whitespace when this is a boolean attribute.
			end := p.position
			jsx_whitespace(p)
			if jsx_take(p, "=") {
				jsx_whitespace(p)
				switch jsx_peek(p) {
				case '"', '\'':
					quote := jsx_peek(p)
					p.position += 1
					start := p.position
					for jsx_peek(p) != quote && jsx_peek(p) != 0 do p.position += 1
					if jsx_peek(p) == 0 {jsx_fail(p, "Unclosed JSX attribute string");return}
					jsx_entity_string(p, p.source[start:p.position])
					p.position += 1
				case '{':
					jsx_emit(p, "(")
					jsx_expression(p)
					jsx_emit(p, ")")
				case:
					jsx_fail(p, "Attribute values must be quoted or enclosed in braces")
				}
			} else {
				p.position = end
				jsx_emit(p, "true")
			}
			jsx_emit(p, ",")
		}
		jsx_emit(p, "}")
	}
	for p.error.message == "" {
		if jsx_take(p, "</") {
			if !fragment {
				closing := jsx_name(p)
				if closing !=
				   tag {jsx_fail(p, "JSX closing tag does not match opening tag");return}
			}
			jsx_whitespace(p)
			if !jsx_take(p, ">") {jsx_fail(p, "Expected > after JSX closing tag");return}
			jsx_emit(p, ")")
			return
		}
		switch jsx_peek(p) {
		case 0:
			jsx_fail(p, "Unclosed JSX element")
		case '<':
			jsx_emit(p, ", ")
			jsx_element(p)
		case '{':
			jsx_emit(p, ", (")
			start := len(p.output.buf)
			jsx_expression(p, true)
			if len(p.output.buf) == start {
				resize(&p.output.buf, start - len(", ("))
			} else {jsx_emit(p, ")")}
		case:
			start := p.position
			for jsx_peek(p) != 0 && jsx_peek(p) != '<' && jsx_peek(p) != '{' {
				if jsx_peek(p) == '}' {jsx_fail(p, "Escape literal } as {'}'} in JSX text");return}
				p.position += 1
			}
			jsx_text_child(p, p.source[start:p.position])
		}
	}
}

// Keep entity decoding deliberately strict: XML's five named entities and
// numeric Unicode entities are portable; other names receive a clear error.
@(private)
jsx_entity_string :: proc(p: ^JSX_Parser, text: string) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i := 0; i < len(text); i += 1 {
		if text[i] != '&' {strings.write_byte(&b, text[i]);continue}
		end := strings.index_byte(text[i:], ';')
		if end < 0 {strings.write_byte(&b, '&');continue}
		entity := text[i + 1:i + end]
		r: rune
		switch entity {
		case "amp":
			r = '&'
		case "lt":
			r = '<'
		case "gt":
			r = '>'
		case "quot":
			r = '"'
		case "apos":
			r = '\''
		case:
			if len(entity) == 0 || entity[0] != '#' {
				jsx_fail(p, "Unsupported JSX entity; use a Unicode character or numeric entity")
				return
			}
			base, start := 10, 1
			if len(entity) > 1 && (entity[1] == 'x' || entity[1] == 'X') {base = 16;start = 2}
			if start == len(entity) {jsx_fail(p, "Empty numeric JSX entity");return}
			for c in entity[start:] {
				digit := int(c - '0')
				if c >= 'a' && c <= 'f' {digit = int(c - 'a') + 10}
				if c >= 'A' && c <= 'F' {digit = int(c - 'A') + 10}
				if digit < 0 || digit >= base || r > 0x10ffff / rune(base) {
					jsx_fail(p, "Invalid numeric JSX entity");return
				}
				r = r * rune(base) + rune(digit)
			}
			if !utf8.valid_rune(r) || r == 0 {jsx_fail(p, "Invalid Unicode JSX entity");return}
		}
		strings.write_rune(&b, r)
		i += end
	}
	jsx_quoted(p, strings.to_string(b))
}

// This is a lexical pass, not a JavaScript compiler. Balanced groups, comments,
// strings, regex literals and template interpolations protect embedded syntax.
@(private)
jsx_javascript_scan :: proc(
	p: ^JSX_Parser,
	stop: u8 = 0,
	statements := false,
	reject_spread := false,
	for_header := false,
) -> (
	has_tokens: bool,
) {
	p.depth += 1
	defer p.depth -= 1
	if p.depth > 128 {jsx_fail(p, "JavaScript/JSX nesting exceeds 128 levels");return}
	expect_value := true
	control_paren := false
	for_paren := false
	binding_keyword := false
	in_for_header := for_header
	statement_start := statements
	declaration_header := false
	member_name := false
	arrow_body := false
	for p.position < len(p.source) && p.error.message == "" {
		c := jsx_peek(p)
		if c == stop do return
		start := p.position
		comment := c == '/' && (jsx_peek(p, 1) == '/' || jsx_peek(p, 1) == '*')
		if reject_spread &&
		   !has_tokens &&
		   c == '.' &&
		   jsx_peek(p, 1) == '.' &&
		   jsx_peek(p, 2) == '.' {
			jsx_fail(p, "Spread expressions are unsupported here; pass the array as {items}")
			return
		}
		if !jsx_space(c) && !comment do has_tokens = true
		switch {
		case jsx_space(c):
			p.position += 1
		case c == '/' && (jsx_peek(p, 1) == '/' || jsx_peek(p, 1) == '*'):
			block := jsx_peek(p, 1) == '*'
			p.position += 2
			if block {
				for jsx_peek(p) != 0 && !(jsx_peek(p) == '*' && jsx_peek(p, 1) == '/') do p.position += 1
				if !jsx_take(p, "*/") {jsx_fail(p, "Unclosed JavaScript comment");return}
			} else {for jsx_peek(p) != 0 && jsx_peek(p) != '\n' do p.position += 1}
		case c == '\'' || c == '"':
			p.position += 1
			for jsx_peek(p) != c {
				if jsx_peek(p) == 0 ||
				   jsx_peek(p) == '\n' ||
				   jsx_peek(p) == '\r' {jsx_fail(p, "Unclosed JavaScript string");return}
				if jsx_peek(p) == '\\' && jsx_peek(p, 1) != 0 {
					p.position += 1
					if jsx_peek(p) == '\r' && jsx_peek(p, 1) == '\n' do p.position += 1
				}
				p.position += 1
			}
			p.position += 1
			expect_value = false
			statement_start = false
		case c == '`':
			jsx_emit(p, "`")
			p.position += 1
			for jsx_peek(p) != '`' && p.error.message == "" {
				if jsx_peek(p) == 0 {jsx_fail(p, "Unclosed JavaScript template literal");return}
				if jsx_take(p, "${") {
					jsx_emit(p, "${")
					jsx_javascript_scan(p, '}')
					if !jsx_take(p, "}") {jsx_fail(p, "Unclosed template interpolation");return}
					jsx_emit(p, "}")
				} else {
					start = p.position
					if jsx_peek(p) == '\\' && jsx_peek(p, 1) != 0 do p.position += 1
					p.position += 1
					jsx_emit(p, p.source[start:p.position])
				}
			}
			if !jsx_take(p, "`") {jsx_fail(p, "Unclosed template literal");return}
			jsx_emit(p, "`")
			expect_value = false
			statement_start = false
			continue
		case c == '/' && expect_value:
			p.position += 1
			in_class := false
			for {
				v := jsx_peek(p)
				if v == 0 ||
				   v == '\n' ||
				   v == '\r' {jsx_fail(p, "Unclosed JavaScript regular expression");return}
				p.position += 1
				if v == '\\' {
					if jsx_peek(p) != 0 do p.position += 1
					continue
				}
				if v == '[' do in_class = true
				if v == ']' do in_class = false
				if v == '/' && !in_class do break
			}
			for jsx_identifier_part(jsx_peek(p)) do p.position += 1
			expect_value = false
			statement_start = false
		case jsx_identifier_start(c):
			p.position += 1
			for jsx_identifier_part(jsx_peek(p)) do p.position += 1
			word := p.source[start:p.position]
			if member_name {
				member_name = false
				control_paren = false
				expect_value = false
				statement_start = false
				for_paren = false
				binding_keyword = false
			} else {
				iterable := in_for_header && word == "of" && !expect_value && !binding_keyword
				for_paren = word == "for" || for_paren && word == "await"
				binding_keyword = word == "const" || word == "let" || word == "var"
				if (word == "function" || word == "class") && statement_start do declaration_header = true
				control_paren =
					word == "if" ||
					word == "while" ||
					for_paren ||
					word == "with" ||
					word == "switch" ||
					word == "catch"
				expect_value =
					iterable ||
					control_paren ||
					word == "return" ||
					word == "throw" ||
					word == "yield" ||
					word == "await" ||
					word == "case" ||
					word == "default" ||
					word == "delete" ||
					word == "void" ||
					word == "typeof" ||
					word == "new" ||
					word == "in" ||
					word == "instanceof" ||
					word == "else" ||
					word == "do"
				statement_start =
					word == "else" ||
					word == "do" ||
					word == "try" ||
					word == "finally" ||
					word == "catch" ||
					statement_start && (word == "export" || word == "default" || word == "async")
			}
		case c >= '0' && c <= '9':
			p.position += 1
			for jsx_identifier_part(jsx_peek(p)) || jsx_peek(p) == '.' do p.position += 1
			expect_value = false
			statement_start = false
		case c == '<' &&
		     expect_value &&
		     (jsx_identifier_start(jsx_peek(p, 1)) || jsx_peek(p, 1) == '>'):
			jsx_element(p)
			expect_value = false
			statement_start = false
			continue
		case c == '(' || c == '[' || c == '{':
			closing: u8 = ')'
			if c == '[' do closing = ']'
			if c == '{' do closing = '}'
			control := control_paren
			iterable_header := c == '(' && for_paren
			brace_statement := c == '{' && (statement_start || declaration_header)
			brace_block := c == '{' && (brace_statement || !expect_value || arrow_body)
			if c == '{' do declaration_header = false
			control_paren = false
			for_paren = false
			binding_keyword = false
			arrow_body = false
			member_name = false
			jsx_emit(p, p.source[start:start + 1])
			p.position += 1
			jsx_javascript_scan(p, closing, brace_block, for_header = iterable_header)
			if jsx_peek(p) != closing {jsx_fail(p, "Unclosed JavaScript group");return}
			p.position += 1
			jsx_emit(p, p.source[p.position - 1:p.position])
			expect_value = c == '(' && control || brace_statement
			statement_start = expect_value
			continue
		case c == ')' || c == ']' || c == '}':
			jsx_fail(p, "Unexpected JavaScript closing delimiter")
			return
		case:
			p.position += 1
			control_paren = false
			for_paren = false
			binding_keyword = false
			if c == ';' do in_for_header = false
			statement_start = c == ';'
			arrow_body = c == '=' && jsx_peek(p) == '>'
			if arrow_body do p.position += 1
			member_name = c == '.' && jsx_peek(p) != '.'
			if (c == '+' || c == '-') && jsx_peek(p) == c {
				p.position += 1 // Postfix ++/-- retain the previous expression context.
			} else {expect_value = c != '.'}
		}
		jsx_emit(p, p.source[start:p.position])
	}
	return
}
