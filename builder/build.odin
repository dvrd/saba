package builder

import "cmd"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

BASE_SRC :: "src"
BASE_TARGET :: "saba"
CWD := os.get_current_directory()
COMPILED_BINARY := filepath.join({CWD, BASE_TARGET})

build_base :: proc() {
	args := make([dynamic]string)

	append(&args, "odin", "build")
	append(&args, BASE_SRC)
	append(&args, "-o:speed")
	append(&args, "-out:" + BASE_TARGET)
	log.debug("Building app")
	log.debug(strings.join(args[:], " "))
	err := cmd.launch(args[:])
	if err != .ERROR_NONE {
		log.error("Failed compilation of src due to:", os.get_last_error_string())
		os.exit(1)
	}
	log.debug("Successfully compiled", BASE_TARGET)
}

run_app :: proc() {
	// if !os.exists(BASE_TARGET) do build_base()

	log.debug("Executing binary at:", COMPILED_BINARY)
	err := cmd.launch({COMPILED_BINARY})
	if err != .ERROR_NONE {
		log.error("Failed compilation of src due to:", os.get_last_error_string())
		os.exit(1)
	}
}

main :: proc() {
	context.logger = log.create_console_logger(opt = log.Options{.Level, .Terminal_Color})
	cmd, ok := slice.get(os.args, 1)

	switch cmd {
	case "build":
		build_base()
	case:
		run_app()
	}
}
