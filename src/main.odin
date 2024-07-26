package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"

main :: proc() {
	context.logger = log.create_console_logger(
		opt = {.Level, .Terminal_Color, .Thread_Id, .Date, .Time},
	)
	log.info("Starting server")
	run_server()
}

run_server :: proc(address := net.IP4_Address{0, 0, 0, 0}, port := 8080) -> net.Network_Error {
	endpoint := net.Endpoint{address, port}
	listen := net.listen_tcp(endpoint) or_return
	log.infof("Listening on http://{}", net.endpoint_to_string(endpoint))
	for {
		connection, connection_endpoint := net.accept_tcp(listen) or_return
		err := handle_request(connection, connection_endpoint)
		if err != nil do log.error(err)
	}
	return nil
}

handle_request :: proc(
	connection: net.TCP_Socket,
	connection_endpoint: net.Endpoint,
) -> net.Network_Error {
	defer net.close(connection)

	buf: [4096]byte
	bits := net.recv_tcp(connection, buf[:]) or_return
	if bits > 0 do log.infof("Received request")

	fmt.println("---------------------")
	fmt.println(cast(string)buf[:bits])
	fmt.println("---------------------")

	request := parse_request(buf[:bits])

	return handle_response(connection, request)
}

handle_response :: proc(connection: net.TCP_Socket, req: Request) -> net.Network_Error {
	cwd := os.get_current_directory()

	log.info("Sending response")

	file_name, ok := net.percent_decode(req.header.route, context.temp_allocator)
	if !ok {
		bits, err := net.send(connection, not_found())
		return err
	}

	full_path := filepath.join({cwd, file_name}, context.temp_allocator)
	if full_path == cwd {
		full_path = filepath.join({cwd, "index.html"}, context.temp_allocator)
	}

	// Try to open the requested file and if file not exist, response is 404 Not Found
	fd, errno := os.open(full_path)
	defer os.close(fd)
	if (errno != os.ERROR_NONE) {
		bits, err := net.send(connection, not_found())
		return err
	}

	// Get file size for Content-Length
	fi: os.File_Info
	fi, errno = os.fstat(fd)
	file_ext := filepath.ext(fi.name)[1:]

	// HTTP header
	mime_type := ext_to_content(file_ext)
	response_builder := strings.builder_make()
	defer strings.builder_destroy(&response_builder)
	strings.write_string(&response_builder, "HTTP/1.1 200 OK\r\n")
	strings.write_string(&response_builder, fmt.tprintf("Content-Type: %s\r\n", mime_type))
	strings.write_string(&response_builder, "\r\n")

	// Copy file to response buffer
	data: []byte
	data, ok = os.read_entire_file(fd)
	strings.write_bytes(&response_builder, data)

	res := strings.to_string(response_builder)
	fmt.println("----------------------")
	fmt.println(res)
	fmt.println("----------------------")
	bits, err := net.send(connection, transmute([]byte)res)

	free_all(context.temp_allocator)

	return nil
}

not_found :: proc() -> []byte {
	using strings
	b := builder_make()
	defer builder_destroy(&b)
	write_string(&b, "HTTP/1.1 404 Not Found\r\n")
	write_string(&b, "Content-Type: text/plain\r\n")
	write_string(&b, "\r\n")
	write_string(&b, "404 Not Found\n\n")
	res := to_string(b)
	fmt.println("----------------------")
	fmt.println(res)
	fmt.println("----------------------")
	return transmute([]byte)res
}
