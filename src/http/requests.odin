package http

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"

APP_SRC := filepath.join({os.get_current_directory(), "app"})

Request :: struct {
	header: Header,
	body:   []byte,
}

parse_request :: proc(content: []byte) -> Request {
	header, content_length, ok := parse_header(content)
	body := content[len(content) - content_length:]

	return Request{header, body}
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
	log.info("Sending response")

	file_name, ok := net.percent_decode(req.header.route, context.temp_allocator)
	if !ok {
		return send_not_found(connection)
	}

	full_path := filepath.join({APP_SRC, file_name}, context.temp_allocator)
	if full_path == APP_SRC {
		full_path = filepath.join({APP_SRC, "index.html"}, context.temp_allocator)
	}

	// Try to open the requested file and if file not exist, response is 404 Not Found
	fd, errno := os.open(full_path)
	defer os.close(fd)
	if (errno != os.ERROR_NONE) {
		return send_not_found(connection)
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

send_not_found :: proc(connection: net.TCP_Socket) -> net.Network_Error {
	using strings
	b := builder_make()
	defer builder_destroy(&b)
	write_string(&b, "HTTP/1.1 404 Not Found\r\n")
	write_string(&b, "Content-Type: text/html\r\n")
	write_string(&b, "Content-Length: 0\r\n\n\n")
	res := to_string(b)
	fmt.println("----------------------")
	fmt.println(res)
	fmt.println("----------------------")

	bits, err := net.send(connection, transmute([]byte)res)
	return err
}

send_forbidden :: proc(connection: net.TCP_Socket) -> net.Network_Error {
	using strings
	b := builder_make()
	defer builder_destroy(&b)
	write_string(&b, "HTTP/1.1 403 Forbidden\r\n")
	write_string(&b, "Content-Type: text/html\r\n")
	write_string(&b, "Content-Length: 0\r\n\n\n")
	res := to_string(b)
	fmt.println("----------------------")
	fmt.println(res)
	fmt.println("----------------------")

	bits, err := net.send(connection, transmute([]byte)res)
	return err
}

send_bad_request :: proc(connection: net.TCP_Socket) -> net.Network_Error {
	using strings
	b := builder_make()
	defer builder_destroy(&b)
	write_string(&b, "HTTP/1.1 403 Forbidden\r\n")
	write_string(&b, "Content-Type: text/html\r\n")
	write_string(&b, "Content-Length: 0\r\n\n\n")
	res := to_string(b)
	fmt.println("----------------------")
	fmt.println(res)
	fmt.println("----------------------")

	bits, err := net.send(connection, transmute([]byte)res)
	return err
}
