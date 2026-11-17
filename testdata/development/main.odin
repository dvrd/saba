package development_fixture

import "core:fmt"
import "core:log"
import "core:os"
import "core:time"
import server "shared:saba"

main :: proc() {
	logger := log.create_console_logger()
	defer log.destroy_console_logger(logger)
	context.logger = logger
	handled, success := server.develop({package_directory = "src"})

	if handled {
		if !success do os.exit(1); return
	}

	_ = os.write_entire_file("running", fmt.tprintf("%d:%s", os.get_pid(), #load("value.json", string)))

	for {
		time.sleep(time.Second)
	}
}
