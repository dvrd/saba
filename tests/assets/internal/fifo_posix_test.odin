#+build darwin,linux
package saba_assets

import core "../core"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

Fifo_Request :: struct {
	root, relative: string,
	development:    bool,
	status:         core.HTTP_Status,
	done:           sync.Sema,
}

asset_test_fifo :: proc(directory, name: string) -> string {
	path := fmt.aprintf("%s/%s", directory, name)
	assert(posix.mkfifo(strings.clone_to_cstring(path, context.temp_allocator), {.IRUSR, .IWUSR}) == .OK)
	return path
}

// Serve on another thread so a request that opens the FIFO blocks there, not
// in the test. A writer opened afterwards releases a blocked reader.
asset_fifo_served_promptly :: proc(t: ^testing.T, fifo: string, request: ^Fifo_Request) -> bool {
	worker := thread.create_and_start_with_poly_data(request, proc(r: ^Fifo_Request) {
		context.allocator = context.temp_allocator
		served := Request {
			allocator = context.temp_allocator,
			method    = "GET",
			path      = fmt.tprintf("/%s", r.relative),
		}
		response: Response
		if r.development {
			caches := []Asset_Cache{{mount = {directory = r.root, prefix = "/"}}}
			response, _ = serve_assets(&served, caches, true)
		} else {
			response = serve_file_stream(&served, r.root, r.relative)
		}
		r.status = response.status
		core.discard_response(&response)
		sync.sema_post(&r.done)
	})
	prompt := sync.sema_wait_with_timeout(&request.done, 2 * time.Second)
	if !prompt {
		writer := posix.open(
			strings.clone_to_cstring(fifo, context.temp_allocator),
			{.WRONLY, .NONBLOCK},
		)
		if writer >= 0 {
			posix.close(writer)
		}
		sync.sema_wait(&request.done)
	}
	thread.join(worker)
	thread.destroy(worker)
	testing.expectf(t, prompt, "the request for %s waited on the FIFO", request.relative)
	return prompt
}

@(test)
fifo_in_a_served_root_is_refused_without_opening_it :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 40 * time.Second)
	temporary := asset_test_directory()
	defer delete(temporary)
	defer os.remove_all(temporary)
	// The temporary directory can sit behind a link (/var on Darwin). Serve its
	// resolved path so each lookup reaches the file-type check.
	directory, resolved := filepath.abs(temporary, context.allocator)
	assert(resolved == nil)
	defer delete(directory)
	fifo := asset_test_fifo(directory, "pipe.txt")
	defer delete(fifo)
	assert(os.symlink(fifo, fmt.tprintf("%s/link.txt", directory)) == nil)

	// Both lookups are inside the root, so only the file type refuses them.
	_, found, allowed := module_file(directory, "pipe.txt", context.temp_allocator)
	testing.expect(t, !found && allowed)
	_, found, allowed = module_file(directory, "link.txt", context.temp_allocator)
	testing.expect(t, !found && allowed)

	for relative in ([]string{"pipe.txt", "link.txt"}) {
		for development in ([]bool{false, true}) {
			request := Fifo_Request {
				root        = directory,
				relative    = relative,
				development = development,
			}
			if asset_fifo_served_promptly(t, fifo, &request) {
				testing.expect_value(t, request.status, core.HTTP_Status.Not_Found)
			}
		}
	}

	// A FIFO given as the root itself is refused as well.
	request := Fifo_Request {
		root     = fifo,
		relative = "pipe.txt",
	}
	if asset_fifo_served_promptly(t, fifo, &request) {
		testing.expect_value(t, request.status, core.HTTP_Status.Not_Found)
	}
}
