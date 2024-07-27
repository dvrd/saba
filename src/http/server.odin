package http

import "core:log"
import "core:net"
import "core:os"

Server :: struct {
	endpoint: net.Endpoint,
	socket:   net.TCP_Socket,
}

create_server :: proc(
	address := net.IP4_Address{0, 0, 0, 0},
	port := 8080,
) -> (
	s: ^Server,
	err: net.Network_Error,
) {
	s = new(Server)
	s.endpoint = net.Endpoint{address, port}
	s.socket, err = net.listen_tcp(s.endpoint)
	return
}

handle_connection :: proc(s: ^Server) -> net.Network_Error {
	connection, connection_endpoint := net.accept_tcp(s.socket) or_return
	handle_request(connection, connection_endpoint) or_return
	return nil
}
