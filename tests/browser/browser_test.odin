package saba_ui_test

import store "../fixtures/apps/ui_store"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import application "shared:saba/application"
import server "shared:saba/core"

Browser_Report :: struct {
	error:                              string,
	reads, keyed, windowed, slots, mutations, templates, detached, regressions, lowered: bool,
	forwarded:                          struct {
		initial, after, snapshot, finalDetachedText:       string,
		sameNode, connectedAfterRemoval, callbackIdentity: bool,
		setups:                                            [3]int,
		cleanups, readsAfterRemoval:                       int,
	},
	scheduler:                          struct {
		values, cutoff:             string,
		currentInBatch:             int,
		untrackCaught, cycleCaught: bool,
	},
	dom:                                struct {
		ariaBefore, ariaAfter, opacity, value, selection: string,
		svg, html, nestedSVG, forwardedSVG, math:         string,
		described, disabled:                              bool,
	},
	expressions:                        struct {
		tagged, coerced, overridden, resolved, order, spread: string,
		coercions, hiddenReads:                               int,
	},
}

fixture_document :: proc(
	data: rawptr,
	connection: ^server.Connection,
	request: ^server.Request,
) -> server.Response {
	state := cast(^Browser_Server)data
	if strings.has_prefix(request.path, "/template-test/") {
		return template_response(request)
	}
	if strings.has_prefix(request.path, "/api/items/") {
		return store.handle(&state.store, connection, request)
	}
	if request.path == "/api/test-session" {
		identity := test_identity(request)
		payload, encoded := json.marshal(struct {
				session, tenant: string,
			}{identity.caller, identity.tenant}, allocator = request.allocator)
		if encoded != nil {
			return {status = .Internal_Server_Error}
		}
		return server.make_response(
			request,
			.OK,
			{{"Content-Type", "application/json"}, {"Cache-Control", "no-store"}},
			payload,
		)
	}
	if state.development && request.method == "POST" {
		switch request.path {
		case "/test-publish":
			sync.atomic_store(&state.publish, true)
			return {status = .No_Content}
		case "/test-release":
			if !sync.atomic_exchange(&state.unlocked, true) { sync.sema_post(&state.release) }
			return {status = .No_Content}
		}
	}
	if request.path == "/away" {
		content :: `<!doctype html><html><head><title>UI fixture</title></head><body><h1>Second document</h1><script type="module" src="/ui/away.js"></script></body></html>`
		return server.make_response(
			request,
			.OK,
			{{"Content-Type", "text/html; charset=utf-8"}},
			transmute([]u8)string(content),
		)
	}
	if request.path == "/history-result" && request.method == "POST" {
		sync.mutex_lock(&state.lock)
		defer sync.mutex_unlock(&state.lock)
		if state.history_size == 0 {
			state.history_size = copy(state.history[:], request.body)
		}
		return {status = .No_Content}
	}
	if request.path != "/" {
		return {status = .Not_Found}
	}
	HTML :: `<!doctype html><html><head><title>UI fixture</title></head><body><main id="app"></main><pre id="result"></pre><script type="module" src="/ui/driver.js"></script></body></html>`
	return server.make_response(
		request,
		.OK,
		{{"Content-Type", "text/html; charset=utf-8"}},
		transmute([]u8)string(HTML),
	)
}

test_identity :: proc(request: ^server.Request) -> store.Identity {
	if strings.contains(server.header_value(request, "Cookie"), "saba-test-user=second") {
		return {"other", "operator-2", .Allowed}
	}
	return {"demo", "operator", .Allowed}
}

Browser_Server :: struct {
	control:              server.Server_Control,
	directory:            string,
	development, publish, unlocked: bool,
	release:              sync.Sema,
	store:                store.State,
	lock:                 sync.Mutex,
	history:              [4096]u8,
	history_size:         int,
	done:                 bool,
	ok:                   bool,
}

serve_fixture :: proc(s: ^Browser_Server) {
	logger := log.create_console_logger()
	defer log.destroy_console_logger(logger)
	context.logger = logger
	s.ok = application.serve(
		{
			server = {
				address = "127.0.0.1",
				workers = 1,
				control = &s.control,
				handler = fixture_document,
				handler_data = s,
			},
			modules = {{directory = s.directory, prefix = "/ui/"}},
			development = s.development,
			hot_reload_directory = s.directory,
			pages = {
				templates = {
					pages = {
						{
							path = "/items/[id]",
							revalidate = true,
							variants = {
								{
									language = "en",
									source_file = fmt.tprintf("%s/item.jsx", s.directory),
									module_url = "/ui/item.js",
									recovery_label = "Reload",
								},
							},
						},
					},
				},
			},
		},
	)
	sync.atomic_store(&s.done, true)
}

chromium_path :: proc() -> string {
	if path := os.get_env("SABA_CHROME", context.temp_allocator); path != "" {
		return path
	}
	when ODIN_OS == .Darwin {
		for path in ([]string {
				"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
				"/Applications/Chromium.app/Contents/MacOS/Chromium",
			}) {
			if os.exists(path) {
				return path
			}
		}
	}
	return "chromium"
}

@(test)
compiled_jsx_in_chromium :: proc(t: ^testing.T) {browser_fixture(t, false)}

@(test)
deploy_while_a_save_is_reserved :: proc(t: ^testing.T) {browser_fixture(t, true)}

@(test)
compiled_jsx_in_firefox :: proc(t: ^testing.T) {browser_fixture(t, false, .Firefox)}

@(test)
deploy_while_a_save_is_reserved_in_firefox :: proc(t: ^testing.T) {browser_fixture(t, true, .Firefox)}

@(test)
compiled_jsx_in_webkit :: proc(t: ^testing.T) {browser_fixture(t, false, .WebKit)}

@(test)
deploy_while_a_save_is_reserved_in_webkit :: proc(t: ^testing.T) {browser_fixture(t, true, .WebKit)}

browser_fixture :: proc(t: ^testing.T, deployment: bool, engine := Engine.Chromium) {
	testing.set_fail_timeout(t, engine_timeout(engine, 90 * time.Second))
	if !engine_enter(t, engine, "the compiled JSX fixture" if !deployment else "the deployment fixture") {
		return
	}
	defer engine_leave(engine)
	state := Browser_Server {
		directory   = "tests/fixtures/ui",
		development = deployment,
	}
	work, error := os.make_directory_temp("", "saba-ui-browser-*", context.temp_allocator)
	if !testing.expectf(t, error == nil, "could not create browser directory: %v", error) {
		return
	}
	defer _ = os.remove_all(work)
	opened := store.open(
		&state.store,
		fmt.tprintf("%s/items.sqlite", work),
		test_identity,
		proc(tenant, caller: string) -> bool {
			return(
				(tenant == "demo" && caller == "operator") ||
				(tenant == "other" && caller == "operator-2") \
			)
		},
	)
	if !testing.expect(t, opened, "could not open fixture database") {
		return
	}
	defer store.close(&state.store)
	if !testing.expect(
		t,
		store.seed(&state.store, "demo") && store.seed(&state.store, "other"),
		"could not seed fixture items",
	) {
		return
	}
	if deployment {
		state.directory = fmt.tprintf("%s/web", work)
		if !testing.expect(
			t,
			os.copy_directory_all(state.directory, "tests/fixtures/ui") == nil,
			"could not isolate rollout sources",
		) {
			return
		}
		state.store.checkpoint_data = &state
		state.store.checkpoint = proc(p: rawptr, stage: store.Stage, _: string) {
			if stage == .Reserved {
				sync.sema_wait(&(cast(^Browser_Server)p).release)
			}
		}
	}
	worker := thread.create_and_start_with_poly_data(&state, serve_fixture)
	if !testing.expect(t, worker != nil, "could not start the Saba fixture") {
		return
	}
	defer {
		if deployment {
			sync.sema_post(&state.release)
		}
		server.stop_server(&state.control)
		thread.join(worker)
		thread.destroy(worker)
		testing.expect(t, state.ok, "Saba could not prepare or serve the JSX fixture")
	}
	// The fixture compiles its pages before it serves: on a loaded machine
	// that takes more than ten seconds. A fixture that fails ends the wait
	// at once (done); the bound only guards a hang.
	deadline := time.tick_add(time.tick_now(), 60 * time.Second)
	for !server.server_ready(&state.control) &&
	    !sync.atomic_load(&state.done) &&
	    time.tick_since(deadline) < 0 {
		time.sleep(time.Millisecond)
	}
	endpoint, ready := server.server_endpoint(&state.control)
	if !testing.expect(
		t,
		ready && endpoint.port > 0,
		"Saba did not publish the fixture endpoint",
	) {
		return
	}

	if deployment {
		verify_native_history(t, &state, work, endpoint.port, "deploy", engine)
		return
	}

	dump_path := fmt.tprintf("%s/page.html", work)
	dump, dump_error := os.create(dump_path)
	if !testing.expectf(
		t,
		dump_error == nil,
		"could not create Chromium output file: %v",
		dump_error,
	) {
		return
	}
	defer _ = os.close(dump)
	browser := chromium_path()
	url := fmt.tprintf("http://127.0.0.1:%d/", endpoint.port)
	command := []string {
		browser,
		"--headless",
		"--no-first-run",
		"--no-default-browser-check",
		"--disable-background-networking",
		"--disable-extensions",
		"--disable-dev-shm-usage",
		"--dump-dom",
		"--virtual-time-budget=5000",
		fmt.tprintf("--user-data-dir=%s/profile", work),
		url,
	}
	if engine != .Chromium {
		browser = node_path()
		command = driver_command(engine, "dump", url, 60)
	}
	process, started := os.process_start({command = command, stdout = dump, stderr = os.stderr})
	if !testing.expectf(
		t,
		started == nil,
		"could not start %s (%v). Set SABA_CHROME to a Chromium executable",
		browser,
		started,
	) {
		return
	}
	result, waited := os.process_wait(process, engine_timeout(engine, 35 * time.Second))
	if waited != nil {
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
	}
	if !testing.expectf(
		t,
		waited == nil && result.success,
		"%s failed (%v, exit %d)",
		engine_name(engine),
		waited,
		result.exit_code,
	) {
		return
	}

	body, read_error := os.read_entire_file(dump_path, context.temp_allocator)
	if !testing.expect(t, read_error == nil, "could not read Chromium's DOM output") {
		return
	}
	html := string(body)
	marker :: `<pre id="result">`
	start := strings.index(html, marker)
	if !testing.expect(t, start >= 0, "Chromium did not load the fixture document") {
		return
	}
	content := html[start + len(marker):]
	end := strings.index(content, "</pre>")
	if !testing.expect(t, end > 0, "the browser did not complete the fixture module") {
		return
	}
	decoded, valid := net.percent_decode(content[:end], context.temp_allocator)
	if !testing.expect(t, valid, "invalid browser result encoding") {
		return
	}
	report: Browser_Report
	parsed := json.unmarshal(transmute([]u8)decoded, &report, allocator = context.temp_allocator)
	if !testing.expectf(
		t,
		parsed == nil && report.error == "",
		"browser fixture failed: %s (%v)",
		decoded,
		parsed,
	) {
		return
	}

	f := report.forwarded
	testing.expect_value(t, f.initial, "2")
	testing.expect_value(t, f.after, "3")
	testing.expect(t, f.sameNode, "badge replaced its text node")
	testing.expect_value(t, f.snapshot, "2")
	testing.expect_value(t, f.setups, [3]int{1, 1, 1})
	testing.expect_value(t, f.cleanups, 1)
	testing.expect_value(t, f.readsAfterRemoval, 0)
	testing.expect_value(t, f.finalDetachedText, "3")
	testing.expect(t, !f.connectedAfterRemoval, "badge stayed mounted")
	testing.expect(t, f.callbackIdentity, "callback prop lost identity")

	s := report.scheduler
	testing.expect_value(t, s.values, "4,10,9,10,11")
	testing.expect_value(t, s.cutoff, "1,0")
	testing.expect_value(t, s.currentInBatch, 10)
	testing.expect(
		t,
		s.untrackCaught && s.cycleCaught,
		"expected untrack and non-settling flush errors",
	)

	d := report.dom
	testing.expect_value(t, d.ariaBefore, "true")
	testing.expect_value(t, d.ariaAfter, "false")
	testing.expect(t, !d.described && !d.disabled, "attributes survived removal")
	testing.expect_value(t, d.opacity, "")
	testing.expect_value(t, d.value, "")
	testing.expect_value(t, d.selection, "1,4,backward")
	SVG :: "http://www.w3.org/2000/svg"
	testing.expect_value(t, d.svg, SVG)
	testing.expect_value(t, d.html, "http://www.w3.org/1999/xhtml")
	testing.expect_value(t, d.nestedSVG, SVG)
	testing.expect_value(t, d.forwardedSVG, SVG)
	testing.expect_value(t, d.math, "http://www.w3.org/1998/Math/MathML")

	e := report.expressions
	testing.expect_value(t, e.tagged, "b")
	testing.expect_value(t, e.coerced, "b")
	testing.expect_value(t, e.coercions, 2)
	testing.expect_value(t, e.overridden, "fixed")
	testing.expect_value(t, e.hiddenReads, 0)
	testing.expect_value(t, e.resolved, "123")
	testing.expect_value(t, e.order, "1,load,3")
	testing.expect_value(t, e.spread, "xy")
	testing.expect(t, report.reads, "shared reads fixture did not complete")
	testing.expect(t, report.keyed, "keyed rows fixture did not complete")
	testing.expect(t, report.windowed, "buffered editable row fixture did not complete")
	testing.expect(t, report.slots, "recycled slot window fixture did not complete")
	testing.expect(t, report.mutations, "mutation and editing fixture did not complete")
	testing.expect(t, report.templates, "compiled template fixture did not complete")
	testing.expect(t, report.detached, "receipt failed to update surviving searches after removing the submitting editor")
	testing.expect(t, report.regressions, "runtime regression fixture did not complete")
	testing.expect(t, report.lowered, "lowered lists and holes did not match the runtime path")
	verify_native_history(t, &state, work, endpoint.port, "same-user", engine)
	verify_native_history(t, &state, work, endpoint.port, "switch-user", engine)
}

// A persistent browser is required because --dump-dom exits at the first
// document. The restored document reports through HTTP after an actual Back
// traversal, a receipt read and a separate full reload.
verify_native_history :: proc(
	t: ^testing.T,
	state: ^Browser_Server,
	work: string,
	port: int,
	mode: string,
	engine: Engine,
) {
	sync.mutex_lock(&state.lock)
	state.history_size = 0
	sync.mutex_unlock(&state.lock)
	log_path := fmt.tprintf("%s/%s.log", work, mode)
	log, opened := os.create(log_path)
	if !testing.expectf(t, opened == nil, "could not create browser log: %v", opened) {
		return
	}
	defer _ = os.close(log)
	// Playwright's WebKit build never restores a page from the back/forward
	// cache (not even a static one), so Back there loads a new document.
	// Safari does restore pages; the fixture then asserts the uncached path.
	bfcache := engine != .WebKit
	url := fmt.tprintf("http://127.0.0.1:%d/items/42?history-probe&%s%s", port, mode, "" if bfcache else "&no-bfcache")
	command := []string {
		chromium_path(),
		"--headless",
		"--no-first-run",
		"--no-default-browser-check",
		"--disable-extensions",
		"--enable-logging=stderr",
		"--disable-background-networking",
		fmt.tprintf("--user-data-dir=%s/%s-profile", work, mode),
		url,
	}
	if engine != .Chromium {
		command = driver_command(engine, "navigate", url, 70)
	}
	process, started := os.process_start({command = command, stdout = log, stderr = log})
	if !testing.expectf(
		t,
		started == nil,
		"could not launch native navigation test: %v",
		started,
	) {
		return
	}
	reaped := false
	defer if !reaped {
		_ = os.process_terminate(process)
		if _, error := os.process_wait(process, 3 * time.Second); error != nil {
			_ = os.process_kill(process)
			_, _ = os.process_wait(process)
		}
	}
	// Playwright adds its own browser startup to the navigation.
	wait := 25 * time.Second if engine == .Chromium else 60 * time.Second
	until := time.tick_add(time.tick_now(), wait)
	message: string
	published := false
	for time.tick_since(until) < 0 {
		if state.development && !published && sync.atomic_load(&state.publish) {
			source := fmt.tprintf("%s/item.jsx", state.directory)
			original, read_error := os.read_entire_file(source, context.temp_allocator)
			if !testing.expect(t, read_error == nil, "could not read release A source") {
				return
			}
			updated, _ := strings.replace_all(
				string(original),
				"<h1>Edit item</h1>",
				"<h1>Review item</h1>",
				context.temp_allocator,
			)
			if !testing.expect(
				t,
				updated != string(original) && os.write_entire_file(source, updated) == nil,
				"could not stage release B",
			) {
				return
			}
			published = true
		}
		sync.mutex_lock(&state.lock)
		message = string(state.history[:state.history_size])
		sync.mutex_unlock(&state.lock)
		if message != "" {
			break
		}
		if _, error := os.process_wait(process, 30 * time.Millisecond); error != .Timeout {
			reaped = error == nil
			break
		}
	}
	if message == "" {
		output, _ := os.read_entire_file(log_path, context.temp_allocator)
		testing.expectf(
			t,
			false,
			"browser exited or timed out before the native navigation result: %s",
			string(output),
		)
		return
	}
	expected :=
		"persisted Back, changed identity, zero previous receipts, fresh authorized record" if \
			mode == "switch-user" else \
			"persisted Back, verified identity, one receipt, one committed PATCH, clean reload"
	if !bfcache {
		expected =
			"new document on Back, changed identity, zero previous receipts, fresh authorized record" if \
				mode == "switch-user" else \
				"new document on Back, one receipt, one committed PATCH, committed value"
	}
	if mode == "deploy" {
		expected = "new generation reconciled its predecessor's pending mutation"
	}
	testing.expect_value(t, message, expected)
}
