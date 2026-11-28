package main
import jsx "../../../../src/jsx"
import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("Usage: compile INPUT.jsx OUTPUT.js"); os.exit(2)
	}
	bytes, err := os.read_entire_file(os.args[1], context.temp_allocator)
	if err != nil {
		fmt.eprintln(err); os.exit(1)
	}
	module, diagnostic := jsx.transform_jsx(string(bytes), os.args[1], context.temp_allocator)
	if diagnostic.message != "" {
		fmt.eprintln(diagnostic); os.exit(1)
	}
	if written := os.write_entire_file(os.args[2], module); written != nil {
		fmt.eprintln(written); os.exit(1)
	}
}
