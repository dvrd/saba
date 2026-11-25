#+build darwin,linux
package saba_pages

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

Fifo_Page_Lookup :: struct {
	root, relative: string,
	found, allowed: bool,
	done:           sync.Sema,
}

@(test)
fifo_page_file_is_refused_without_opening_it :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 20 * time.Second)
	temporary, made := os.make_directory_temp("", "saba-pages-*", context.allocator)
	assert(made == nil)
	defer delete(temporary)
	defer os.remove_all(temporary)
	// The temporary directory can sit behind a link (/var on Darwin). Use its
	// resolved path so each lookup passes containment and reaches the type check.
	directory, resolved := filepath.abs(temporary, context.allocator)
	assert(resolved == nil)
	defer delete(directory)
	fifo := fmt.aprintf("%s/page.jsx", directory)
	defer delete(fifo)
	assert(posix.mkfifo(strings.clone_to_cstring(fifo, context.temp_allocator), {.IRUSR, .IWUSR}) == .OK)
	assert(os.symlink(fifo, fmt.tprintf("%s/link.jsx", directory)) == nil)

	for relative in ([]string{"page.jsx", "link.jsx"}) {
		lookup := Fifo_Page_Lookup {
			root     = directory,
			relative = relative,
		}
		worker := thread.create_and_start_with_poly_data(&lookup, proc(l: ^Fifo_Page_Lookup) {
			_, l.found, l.allowed = module_file(l.root, l.relative, context.temp_allocator)
			sync.sema_post(&l.done)
		})
		prompt := sync.sema_wait_with_timeout(&lookup.done, 2 * time.Second)
		if !prompt {
			writer := posix.open(strings.clone_to_cstring(fifo, context.temp_allocator), {.WRONLY, .NONBLOCK})
			if writer >= 0 {
				posix.close(writer)
			}
			sync.sema_wait(&lookup.done)
		}
		thread.join(worker)
		thread.destroy(worker)
		testing.expectf(t, prompt, "the lookup of %s waited on the FIFO", relative)
		testing.expect(t, !lookup.found && lookup.allowed)
	}

	_, refused := root_directory(fifo, context.temp_allocator)
	testing.expect(t, refused != nil)
}
