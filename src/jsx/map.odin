package saba_jsx

import "core:mem"
import "core:strings"
import k "shared:kessel"

// Generated positions are 0-based byte columns in the emitted body. publish shifts
// them by the prepended hashbang and helper import so they describe the final file.
Source_Entry :: struct {
	generated_line, generated_column: int,
	original_line, original_column:   int,
	source_start, source_end:         int,
}

Source_Map :: struct {
	version:  int,
	file:     string,
	sources:  []string,
	names:    []string,
	mappings: string,
	entries:  []Source_Entry,
}

note_origin :: proc(p: ^Emitter, loc: k.Loc) {
	if loc.end <= loc.start || int(loc.start) > len(p.source) {
		return
	}
	note_position(p, int(loc.start), int(loc.end))
}

// Original positions advance with the emitter, so mapping every copied line
// stays linear. Columns count UTF-16 code units on both sides.
note_position :: proc(p: ^Emitter, start, end: int) {
	if p.unmapped > 0 || start > len(p.source) {
		return
	}
	if start < p.origin_pos {
		p.origin_pos, p.origin_line, p.origin_col = 0, 0, 0
	}
	for i in p.origin_pos ..< start {
		c := p.source[i]
		if c == '\n' {
			p.origin_line += 1
			p.origin_col = 0
		} else if c < 0x80 || c >= 0xc0 {
			p.origin_col += 2 if c >= 0xf0 else 1
		}
	}
	p.origin_pos = start
	entry := Source_Entry {
		generated_line = p.gen_line,
		generated_column = p.gen_col,
		original_line = p.origin_line,
		original_column = p.origin_col,
		source_start = start,
		source_end = end,
	}
	if count := len(p.origins); count > 0 {
		last := &p.origins[count - 1]
		if last.generated_line == entry.generated_line && last.generated_column == entry.generated_column {
			// A JSX element that begins a copied line replaces the line's own entry.
			last^ = entry
			return
		}
	}
	append(&p.origins, entry)
}

// Copy authored source verbatim and map the start of every copied line, so a
// position in plain JavaScript resolves to its own line after JSX above it has
// collapsed.
emit_source :: proc(p: ^Emitter, start, end: u32) {
	if end <= start {
		return
	}
	cursor := int(start)
	for cursor < int(end) {
		stop := int(end)
		if newline := strings.index_byte(p.source[cursor:end], '\n'); newline >= 0 {
			stop = cursor + newline + 1
		}
		if strings.trim_space(p.source[cursor:stop]) != "" {
			note_position(p, cursor, stop)
		}
		jsx_emit(p, p.source[cursor:stop])
		cursor = stop
	}
}

publish_source_map :: proc(
	out: ^Source_Map,
	p: ^Emitter,
	file: string,
	shift: int,
	allocator: mem.Allocator,
) {
	entries := make([]Source_Entry, len(p.origins), allocator)
	copy(entries, p.origins[:])
	for &entry in entries {
		entry.generated_line += shift
	}
	sources := make([]string, 1, allocator)
	sources[0] = strings.clone(file, allocator)
	out^ = Source_Map {
		version = 3,
		file = strings.clone(file, allocator),
		sources = sources,
		names = make([]string, 0, allocator),
		mappings = encode_mappings(entries, allocator),
		entries = entries,
	}
}

VLQ_ALPHABET :: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

encode_mappings :: proc(entries: []Source_Entry, allocator: mem.Allocator) -> string {
	b := strings.builder_make(allocator)
	prev_col := 0
	prev_orig_line := 0
	prev_orig_col := 0
	line := 0
	fresh := true
	for entry in entries {
		for line < entry.generated_line {
			strings.write_byte(&b, ';')
			line += 1
			prev_col = 0
			fresh = true
		}
		if !fresh {
			strings.write_byte(&b, ',')
		}
		fresh = false
		encode_vlq(&b, entry.generated_column - prev_col)
		encode_vlq(&b, 0)
		encode_vlq(&b, entry.original_line - prev_orig_line)
		encode_vlq(&b, entry.original_column - prev_orig_col)
		prev_col = entry.generated_column
		prev_orig_line = entry.original_line
		prev_orig_col = entry.original_column
	}
	return strings.to_string(b)
}

encode_vlq :: proc(b: ^strings.Builder, value: int) {
	vlq := u32(value) << 1
	if value < 0 {
		vlq = (u32(-value) << 1) | 1
	}
	for {
		digit := vlq & 31
		vlq >>= 5
		if vlq > 0 {
			digit |= 32
		}
		alphabet := VLQ_ALPHABET
		strings.write_byte(b, alphabet[digit])
		if vlq == 0 {
			break
		}
	}
}
