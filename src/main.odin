package saba

import "core:log"
import "core:net"
import "core:os"
import "http"

main :: proc() {
	context.logger = log.create_console_logger(
		opt = {.Level, .Terminal_Color, .Thread_Id, .Date, .Time},
	)
	log.info("Starting server")
	server, err := http.create_server()
	if err != nil {
		log.error("Could not create server")
		os.exit(1)
	}
	defer http.destroy_server(server)
	http.listen(server)
}
