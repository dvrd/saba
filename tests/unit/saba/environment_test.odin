package server

import "core:testing"

@(test)
environment_parse_reports_the_line_of_a_malformed_value :: proc(t: ^testing.T) {
	values, line := environment_parse("A=1\nB=\"two words\" # note\n", context.temp_allocator)
	testing.expect_value(t, line, 0)
	testing.expect_value(t, values["A"], "1")
	testing.expect_value(t, values["B"], "two words")

	for source in ([]string{"A=1\nSECRET=\"abc\n", "A=1\nTRAIL=abc\\\n", "A=1\nNUL=a\x00b\n"}) {
		rejected, invalid := environment_parse(source, context.temp_allocator)
		testing.expect_value(t, invalid, 2)
		testing.expect(t, rejected == nil, "a malformed value sets nothing")
	}

	_, key_line := environment_parse("1BAD=x\n", context.temp_allocator)
	testing.expect_value(t, key_line, 1)
}
