package server

import "core:net"
import "core:sync"
import async "shared:async"

// Optional caller-owned control. Keep at a stable address until serve returns.
// stop_server and server_endpoint may be called from another thread. A control
// can be reused after serve returns, but cannot serve two instances at once.
Server_Control :: struct {
	_mutex:                   sync.Mutex,
	_runtime:                 ^async.Runtime,
	_endpoint:                net.Endpoint,
	_in_use, _stop_requested: bool,
}

// A request made before the listener is published is remembered. Shutdown
// cancels suspended connections; callbacks already running finish cooperatively.
stop_server :: proc(control: ^Server_Control) {
	if control == nil do return
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	control._stop_requested = true
	if control._runtime != nil do async.shutdown(control._runtime)
}

server_endpoint :: proc(control: ^Server_Control) -> (net.Endpoint, bool) {
	if control == nil do return {}, false
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	return control._endpoint, control._runtime != nil
}

@(private)
claim_server :: proc(control: ^Server_Control) -> bool {
	if control == nil do return true
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	if control._in_use do return false
	control._in_use = true
	return true
}

@(private)
release_server :: proc(control: ^Server_Control) {
	if control == nil do return
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	control._runtime = nil
	control._endpoint = {}
	control._in_use = false
	control._stop_requested = false
}

@(private)
publish_server :: proc(control: ^Server_Control, runtime: ^async.Runtime, endpoint: net.Endpoint) {
	if control == nil do return
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	control._runtime = runtime
	control._endpoint = endpoint
	if control._stop_requested do async.shutdown(runtime)
}

@(private)
unpublish_server :: proc(control: ^Server_Control) {
	if control == nil do return
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	control._runtime = nil
}

@(private)
server_stop_requested :: proc(control: ^Server_Control) -> bool {
	if control == nil do return false
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	return control._stop_requested
}
