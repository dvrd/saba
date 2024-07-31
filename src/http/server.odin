package http

import "core:log"
import "core:net"
import "core:os"
import "core:thread"

Server :: struct {
	endpoint: net.Endpoint,
	socket:   net.TCP_Socket,
	threads:  [dynamic]^thread.Thread,
}

Connection :: struct {
	server: ^Server,
	client: net.TCP_Socket,
	src:    net.Endpoint,
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

new_connection :: proc(server: ^Server) -> (conn: ^Connection, err: net.Network_Error) {
	client, src := net.accept_tcp(server.socket) or_return
	conn = new(Connection)
	conn.server = server
	conn.client = client
	conn.src = src
	return
}

listen :: proc(server: ^Server) -> net.Network_Error {
	log.infof("Listening on http://{}", to_string(server.endpoint))
	for {
		conn, err := new_connection(server)
		log.infof(
			"Received new connection [%d] at %s",
			conn.client,
			net.endpoint_to_string(conn.src),
		)
		t := thread.create(handle_connection, nil)
		if t != nil {
			t.data = conn
			t.init_context = context
			t.user_index = len(server.threads)
			append(&server.threads, t)
			thread.start(t)
		}
	}
}

handle_connection :: proc(t: ^thread.Thread) {
	conn := (cast(^Connection)t.data)
	err := handle_request(conn)
	if err != nil do log.error(err)
}

destroy_server :: proc(using s: ^Server) {
	for len(threads) > 0 {
		for i := 0; i < len(threads);  /**/{
			if t := threads[i]; thread.is_done(t) {
				log.infof("Thread %d is done\n", t.user_index)
				thread.destroy(t)

				ordered_remove(&threads, i)
			} else {
				i += 1
			}
		}
	}

	free(s)
}
