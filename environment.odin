package server

import "core:log"
import "core:mem"
import "core:os"
import "core:strings"

// Load local defaults before constructing application configuration or workers.
// An absent file is allowed; exported variables, including empty ones, take priority.
load_environment_file :: proc(path := ".env") -> bool {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)
	data, error := os.read_entire_file(path, allocator)
	if reason, general := error.(os.General_Error); general && reason == .Not_Exist do return true
	if error != nil {log.errorf("Could not read environment file %s", path);return false}
	if len(data) > 64 * 1024 {log.errorf("Environment file exceeds 64 KiB: %s", path);return false}
	values, invalid_line := environment_parse(string(data), allocator)
	if invalid_line != 0 {
		log.errorf("Invalid environment assignment at %s:%d", path, invalid_line)
		return false
	}
	// Validate the complete file before changing the process environment.
	for key, value in values {
		_, exported := os.lookup_env(key, allocator)
		if exported do continue
		if os.set_env(key, value) !=
		   nil {log.errorf("Could not apply environment file %s", path);return false}
	}
	return true
}

@(private)
environment_key_ok :: proc(key: string) -> bool {
	if len(key) == 0 do return false
	for c, index in key {
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' do continue
		if index > 0 && c >= '0' && c <= '9' do continue
		return false
	}
	return true
}

@(private)
environment_value :: proc(raw: string, allocator: mem.Allocator) -> (string, bool) {
	value := strings.builder_make(allocator = allocator)
	line := strings.trim_left_space(raw)
	quote: byte
	kept := 0
	for index := 0; index < len(line); index += 1 {
		c := line[index]
		if c == 0 do return "", false
		if quote == 0 && c == '#' && (index == 0 || line[index - 1] == ' ' || line[index - 1] == '\t') do break
		if quote == 0 && (c == '\'' || c == '"') {quote = c;continue}
		if quote != 0 && c == quote {quote = 0;continue}
		if c == '\\' && quote != '\'' {
			index += 1
			if index >= len(line) do return "", false
			c = line[index]
			if quote == '"' {
				switch c {
				case 'n':
					c = '\n'
				case 'r':
					c = '\r'
				case 't':
					c = '\t'
				case '"', '\\', '$':
				case:
					strings.write_byte(&value, '\\')
				}
			}
		}
		strings.write_byte(&value, c)
		if quote != 0 || (c != ' ' && c != '\t') do kept = len(value.buf)
	}
	if quote != 0 do return "", false
	return strings.to_string(value)[:kept], true
}

@(private)
environment_parse :: proc(source: string, allocator: mem.Allocator) -> (map[string]string, int) {
	values := make(map[string]string, allocator)
	rest := strings.trim_prefix(source, "\xef\xbb\xbf")
	line_number := 0
	for raw in strings.split_lines_iterator(&rest) {
		line_number += 1
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' do continue
		if len(line) > 6 && line[:6] == "export" && (line[6] == ' ' || line[6] == '\t') do line = strings.trim_left_space(line[6:])
		equal := strings.index_byte(line, '=')
		key := ""
		if equal > 0 do key = strings.trim_space(line[:equal])
		value: string
		valid := environment_key_ok(key)
		if valid do value, valid = environment_value(line[equal + 1:], allocator)
		if !valid do return nil, line_number
		values[key] = value
	}
	return values, 0
}
