package saba_core

import "core:net"
import "core:sync"
import "core:time"

import async "shared:async"

// Optional caller-owned control. Keep at a stable address until serve returns.
// stop_server, server_endpoint and server_capacity may be called from other
// threads. Reuse only after serve returns; one control cannot serve two instances
// at once. Snapshots copy values and do not extend the runtime's lifetime.
Server_Control :: struct {
	_mutex:                   sync.Mutex,
	_runtime:                 ^async.Runtime,
	_server:                  ^Server_Runtime,
	_endpoint:                net.Endpoint,
	_in_use, _stop_requested: bool,
	_ever_published: bool,
	_drain_requested, _drain_default_requested: bool,
	_drain_timeout: time.Duration,
}

// A request made before the listener is published is remembered. Shutdown
// cancels suspended connections; callbacks already running finish cooperatively.
stop_server :: proc(control: ^Server_Control) {
	if control == nil do return
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	control._stop_requested = true
	if control._server != nil do shutdown_runtime(control._server)
}

// Return the bound endpoint while the server is published. False means no
// endpoint is currently available, including after shutdown unpublication.
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
	control._server = nil
	control._endpoint = {}
	control._ever_published = false
	control._in_use = false
	control._stop_requested = false
	control._drain_requested = false
	control._drain_default_requested = false
	control._drain_timeout = 0
}

@(private)
publish_server :: proc(
	control: ^Server_Control,
	runtime: ^Server_Runtime,
	endpoint: net.Endpoint,
) {
	if control == nil do return
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	control._ever_published = true
	control._runtime = &runtime.executor
	control._server = runtime
	control._endpoint = endpoint
	if control._stop_requested {
		shutdown_runtime(runtime)
	} else if control._drain_requested {
		if control._drain_default_requested do request_runtime_drain(runtime, 0)
		if control._drain_timeout > 0 do request_runtime_drain(runtime, control._drain_timeout)
	}
}

@(private)
unpublish_server :: proc(control: ^Server_Control) {
	if control == nil do return
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	control._runtime = nil
	control._server = nil
}

@(private)
server_stop_requested :: proc(control: ^Server_Control) -> bool {
	if control == nil do return false
	sync.lock(&control._mutex)
	defer sync.unlock(&control._mutex)
	return control._stop_requested || control._drain_requested
}
