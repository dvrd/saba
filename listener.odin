package server

import db "shared:kakunou"

import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

DEFAULT_MAX_CONNECTIONS :: 64

Server :: struct {
	address:              string,
	port:                 int,
	max_connections:      int,
	database:             ^db.SQLite_DB,
	handler:              Handler,
	request_body_limit:   proc(request: ^Request) -> int,
	modules:              []Module_Mount,
	assets:               []Asset_Mount,
	pages:                Page_Mount,
	development:          bool,
	hot_reload_directory: string,
}

Server_Runtime :: struct {
	config:             Server,
	logger:             log.Logger,
	workers:            sync.Wait_Group,
	active_connections: int,
	reload:             Reload_State,
	modules:            []Module_Cache,
	assets:             []Asset_Cache,
	pages:              Page_Cache,
}

// The database and handler must remain valid while the server handles requests.
// Returns false on startup failure or an unrecoverable listener error.
serve :: proc(config: Server) -> bool {
	if config.handler == nil {
		log.error("Server requires a request handler")

		return false
	}
	if config.max_connections < 0 {
		log.error("Server connection limit must not be negative")
		return false
	}
	limit := config.max_connections
	if limit == 0 do limit = DEFAULT_MAX_CONNECTIONS

	module_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&module_arena)
	defer mem.dynamic_arena_destroy(&module_arena)
	modules, prepared := prepare_module_mounts(
		config.modules,
		config.development,
		mem.dynamic_arena_allocator(&module_arena),
	)
	if !prepared do return false
	pages, pages_ready := prepare_pages(
		config.pages,
		config.development,
		mem.dynamic_arena_allocator(&module_arena),
	)
	if !pages_ready do return false
	assets, assets_ready := prepare_assets(
		config.assets,
		mem.dynamic_arena_allocator(&module_arena),
	)
	if !assets_ready do return false

	address_text := config.address
	if address_text == "" do address_text = "127.0.0.1"

	address, address_ok := net.parse_ip4_address(address_text)
	if !address_ok {
		log.error("Could not parse server address:", address_text)

		return false
	}

	listener, err := net.listen_tcp(net.Endpoint{address, config.port})
	if err != nil {
		log.error("Could not start server:", err)

		return false
	}
	defer net.close(listener)

	endpoint, endpoint_err := net.bound_endpoint(listener)
	if endpoint_err != nil {
		log.error("Could not obtain listening address:", endpoint_err)

		return false
	}

	runtime := Server_Runtime {
		config  = config,
		logger  = context.logger,
		modules = modules,
		assets  = assets,
		pages   = pages,
	}
	watcher: ^thread.Thread

	defer {
		sync.atomic_store(&runtime.reload.stopped, true)

		if watcher != nil {
			thread.join(watcher)
			thread.destroy(watcher)
		}

		// Workers borrow the runtime, so keep it alive until they return.
		sync.wait_group_wait(&runtime.workers)
	}

	if config.development {
		directory := config.hot_reload_directory
		if directory == "" do directory = "web"

		signature, scan_ok := web_signature(directory)
		if !scan_ok do return false

		runtime.reload.directory = directory
		runtime.reload.initial_signature = signature
		runtime.reload.logger = context.logger

		watcher = thread.create_and_start_with_poly_data(&runtime.reload, watch_web)
		if watcher == nil {
			log.error("Could not start web watcher")

			return false
		}
	}

	log.infof("listening on http://localhost:%d", endpoint.port)

	for {
		client, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil {
			log.error("Could not accept connection:", accept_err)

			#partial switch accept_err {
			case .Invalid_Argument, .Unsupported_Socket, .Not_Listening:
				return false
			}

			time.sleep(100 * time.Millisecond)

			continue
		}

		blocking_err := net.set_blocking(client, false)
		if blocking_err != nil {
			log.error(
				"Could not configure nonblocking connection:",
				blocking_err,
				"| socket:",
				client,
			)
			net.close(client)

			continue
		}

		// Only the accept loop increments; workers can only release capacity.
		if sync.atomic_load(&runtime.active_connections) >= limit {
			reject_connection(client)
			continue
		}
		sync.atomic_add(&runtime.active_connections, 1)

		sync.wait_group_add(&runtime.workers, 1)

		worker := thread.create_and_start_with_poly_data(
			Connection_Task{client, &runtime},
			handle_connection,
			self_cleanup = true,
		)

		if worker == nil {
			sync.atomic_sub(&runtime.active_connections, 1)
			sync.wait_group_done(&runtime.workers)

			log.error("Could not create connection thread | socket:", client)
			reject_connection(client)
		}
	}
}

@(private)
reject_connection :: proc(client: net.TCP_Socket) {
	defer net.close(client)
	buffer: [RESPONSE_HEADER_LIMIT]u8
	headers, ready := response_headers(Response{status = .Service_Unavailable}, buffer[:])
	// Best effort only: waiting for a rejected client would stall acceptance.
	if ready do net.send_tcp(client, headers)
}
