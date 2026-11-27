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
	collection := fmt.tprintf("-collection:shared=%s", os.get_env("SABA_TEST_SHARED", context.temp_allocator))
	handled, success := server.develop({package_directory = "src", build_arguments = {collection}})

	if handled {
		if !success {
			os.exit(1)
		}
		return
	}

	_ = os.write_entire_file("running", fmt.tprintf("%d:%s", os.get_pid(), #load("value.json", string)))

	for {
		time.sleep(time.Second)
	}
}
