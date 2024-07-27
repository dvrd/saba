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
	log.infof("Listening on http://{}", http.to_string(server.endpoint))
	for {
		err := http.handle_connection(server)
		if err != nil do log.error(err)
	}
}
