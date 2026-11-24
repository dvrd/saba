package saba_jsx

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import k "shared:kessel"

// Reserve names across every scope, including escaped identifiers. Reserving text
// in strings/comments too is harmless and avoids needing a JavaScript scope tree.
jsx_helper_name :: proc(source, base: string) -> string {
	if !strings.contains(source, "\\") && !strings.contains(source, base) {
		return base
	}
	decoded := strings.builder_make()
	defer strings.builder_destroy(&decoded)

	for i := 0; i < len(source); i += 1 {
		if source[i] == '\\' && i + 2 < len(source) && source[i + 1] == 'u' {
			start := i + 2
			braced := source[start] == '{'
			if braced {
				start += 1
			}
			end := start
			value := 0

			for end < len(source) && end - start < 6 {
				c := source[end]
				digit := -1
				if jsx_digit(c) {
					digit = int(c - '0')
				}
				if c >= 'a' && c <= 'f' {
					digit = int(c - 'a') + 10
				}
				if c >= 'A' && c <= 'F' {
					digit = int(c - 'A') + 10
				}
				if digit < 0 {
					break
				}
				value = value * 16 + digit
				end += 1
				if !braced && end - start == 4 {
					break
				}
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
		name = fmt.tprintf("%s_%d", base, suffix)
	}

	return name
}

jsx_fail :: proc(p: ^Emitter, message: string) {
	if p.error.message != "" {
		return
	}
	p.error = jsx_diagnostic(p, p.position, message)
}

jsx_diagnostic :: proc(p: ^Emitter, at: int, message: string) -> JSX_Error {
	line, column := 1, 1

	for r in p.source[:min(at, len(p.source))] {
		if r == '\n' {
			line += 1
			column = 1
		} else {
			column += 1
		}
	}

	return {p.file, line, column, message}
}

jsx_emit :: proc(p: ^Emitter, text: string) {
	strings.write_string(&p.output, text)
	for i in 0 ..< len(text) {
		c := text[i]
		if c == '\n' {
			p.gen_line += 1
			p.gen_col = 0
		} else if c < 0x80 || c >= 0xc0 {
			// Source-map columns count UTF-16 code units.
			p.gen_col += 2 if c >= 0xf0 else 1
		}
	}
}

jsx_quoted :: proc(p: ^Emitter, text: string) {
	encoded, err := json.marshal(text)

	if err != nil {
		jsx_fail(p, "Could not encode JSX text")
		return
	}

	defer delete(encoded)
	jsx_emit(p, string(encoded))
}

jsx_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}
// JSX whitespace follows the usual line-trimming rule, retaining intentional
// spaces on a single line and joining nonempty indented lines with one space.
jsx_text_child :: proc(p: ^Emitter, text: string, span: k.Loc = {}) {
	if clean := jsx_clean_text(text); clean != "" {
		jsx_emit(p, ", ")
		jsx_entity_string(p, clean, span)
	}
}

jsx_clean_text :: proc(text: string) -> string {
	b := strings.builder_make()
	lines := strings.split_lines(text)
	defer delete(lines)
	last := -1

	for line, i in lines {
		if strings.trim_space(line) != "" {
			last = i
		}
	}

	for raw_line, i in lines {
		line := raw_line
		line = strings.trim_right(line, "\r")
		if i > 0 {
			line = strings.trim_left(line, " \t")
		}
		if i < len(lines) - 1 {
			line = strings.trim_right(line, " \t")
		}

		for c in line {
			strings.write_rune(&b, ' ' if c == '\t' else c)
		}

		if len(line) > 0 && i < last {
			strings.write_byte(&b, ' ')
		}
	}

	return strings.to_string(b)
}

jsx_entity_string :: proc(p: ^Emitter, text: string, span: k.Loc = {}) {
	jsx_quoted(p, jsx_decode_text(p, text, span))
}

// Decode without reporting. A row or hole whose static text cannot be decoded
// stays on the ordinary emitter, which reports the entity at its own position.
jsx_try_decode :: proc(p: ^Emitter, text: string) -> (string, bool) {
	scratch := Emitter{source = p.source, file = p.file}
	decoded := jsx_decode_text(&scratch, text)
	return decoded, scratch.error.message == ""
}

// Point an entity diagnostic at its ampersand when the authored span is known.
jsx_entity_fail :: proc(p: ^Emitter, span: k.Loc, entity, message: string) {
	if span.end > span.start && int(span.end) <= len(p.source) {
		needle := fmt.tprintf("&%s;", entity)
		if at := strings.index(p.source[span.start:span.end], needle); at >= 0 {
			p.position = int(span.start) + at
		}
	}
	jsx_fail(p, message)
}

jsx_entity_char :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || jsx_digit(c) || c == '#'
}

// An ampersand begins an entity only when a run of name characters reaches a
// semicolon. Any other ampersand is ordinary text, as in React.
jsx_decode_text :: proc(p: ^Emitter, text: string, span: k.Loc = {}) -> string {
	if !strings.contains(text, "&") {
		return text
	}
	b := strings.builder_make()

	for i := 0; i < len(text); i += 1 {
		if text[i] != '&' {
			strings.write_byte(&b, text[i])
			continue
		}

		end := i + 1
		for end < len(text) && jsx_entity_char(text[end]) {
			end += 1
		}
		if end == i + 1 || end >= len(text) || text[end] != ';' {
			strings.write_byte(&b, '&')
			continue
		}

		entity := text[i + 1:end]
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
			if entity[0] != '#' {
				jsx_entity_fail(p, span, entity, "Unsupported JSX entity; use a Unicode character or numeric entity")
				return ""
			}

			base, start := 10, 1

			if len(entity) > 1 && (entity[1] == 'x' || entity[1] == 'X') {
				base = 16
				start = 2
			}

			if start == len(entity) {
				jsx_entity_fail(p, span, entity, "Empty numeric JSX entity")
				return ""
			}

			for c in entity[start:] {
				digit := -1

				if c >= '0' && c <= '9' {
					digit = int(c - '0')
				}

				if c >= 'a' && c <= 'f' {
					digit = int(c - 'a') + 10
				}

				if c >= 'A' && c <= 'F' {
					digit = int(c - 'A') + 10
				}

				if digit < 0 || digit >= base || r > 0x10ffff / rune(base) {
					jsx_entity_fail(p, span, entity, "Invalid numeric JSX entity")
					return ""
				}

				r = r * rune(base) + rune(digit)
			}

			if !utf8.valid_rune(r) || r == 0 {
				jsx_entity_fail(p, span, entity, "Invalid Unicode JSX entity")
				return ""
			}
		}

		strings.write_rune(&b, r)
		i = end
	}

	return strings.to_string(b)
}

// The pinned parser also uses its empty-expression node for a spread with a
// missing operand. A genuinely empty child contains only whitespace/comments.
empty_jsx_hole :: proc(source: string) -> bool {
	rest := strings.trim_space(source)
	for rest != "" {
		if strings.has_prefix(rest, "/*") {
			end := strings.index(rest[2:], "*/")
			if end < 0 {
				return false
			}
			rest = rest[end + 4:]
		} else if strings.has_prefix(rest, "//") {
			end := strings.index_any(rest, "\n\r")
			if end < 0 {
				return true
			}
			rest = rest[end:]
		} else {
			return false
		}
		rest = strings.trim_space(rest)
	}
	return true
}
