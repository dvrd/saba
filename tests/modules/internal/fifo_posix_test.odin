#+build darwin,linux
package saba_modules

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

Fifo_Module_Request :: struct {
	root, relative: string,
	development:    bool,
	status:         core.HTTP_Status,
	done:           sync.Sema,
}

// Each case runs on another thread so an open of the FIFO blocks there. A
// writer opened afterwards releases a blocked reader.
module_fifo_served_promptly :: proc(t: ^testing.T, fifo: string, r: ^Fifo_Module_Request) -> bool {
	worker := thread.create_and_start_with_poly_data(r, proc(r: ^Fifo_Module_Request) {
		request := Request {
			allocator = context.temp_allocator,
			method    = "GET",
			path      = fmt.tprintf("/%s", r.relative),
		}
		response := read_module(&request, r.root, r.relative, r.development)
		r.status = response.status
		core.discard_response(&response)
		sync.sema_post(&r.done)
	})
	prompt := sync.sema_wait_with_timeout(&r.done, 2 * time.Second)
	if !prompt {
		writer := posix.open(strings.clone_to_cstring(fifo, context.temp_allocator), {.WRONLY, .NONBLOCK})
		if writer >= 0 {
			posix.close(writer)
		}
		sync.sema_wait(&r.done)
	}
	thread.join(worker)
	thread.destroy(worker)
	testing.expectf(t, prompt, "the request for %s waited on the FIFO", r.relative)
	return prompt
}

@(test)
fifo_module_is_refused_without_opening_it :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	temporary, made := os.make_directory_temp("", "saba-modules-*", context.allocator)
	assert(made == nil)
	defer delete(temporary)
	defer os.remove_all(temporary)
	// The temporary directory can sit behind a link (/var on Darwin). Use its
	// resolved path so each lookup passes containment and reaches the type check.
	directory, resolved := filepath.abs(temporary, context.allocator)
	assert(resolved == nil)
	defer delete(directory)
	fifo := fmt.aprintf("%s/pipe.js", directory)
	defer delete(fifo)
	assert(posix.mkfifo(strings.clone_to_cstring(fifo, context.temp_allocator), {.IRUSR, .IWUSR}) == .OK)
	source := fmt.tprintf("%s/source.jsx", directory)
	assert(posix.mkfifo(strings.clone_to_cstring(source, context.temp_allocator), {.IRUSR, .IWUSR}) == .OK)
	assert(os.symlink(fifo, fmt.tprintf("%s/link.js", directory)) == nil)

	for relative in ([]string{"pipe.js", "link.js", "source.js"}) {
		for development in ([]bool{false, true}) {
			request := Fifo_Module_Request {
				root        = directory,
				relative    = relative,
				development = development,
			}
			if module_fifo_served_promptly(t, source if relative == "source.js" else fifo, &request) {
				testing.expect_value(t, request.status, core.HTTP_Status.Not_Found)
			}
		}
	}

	_, refused := root_directory(fifo, context.temp_allocator)
	testing.expect(t, refused != nil)
}
