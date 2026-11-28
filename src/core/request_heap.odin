package saba_core

import rt "base:runtime"
import "core:log"
import "core:mem"
import "core:sync"
import budget "shared:async/budget"

// The default allocator of application code while it serves one request:
// context.allocator inside the handler and inside the callbacks of the
// response it returned (deferred poll, stream producer, upgrade handler and
// their drops).
//
// It is the process heap with a record of what the request still holds. An
// allocation is freed like any other, and whatever is left when the request
// ends is freed then, so a handler that forgets to free leaks nothing. The
// other side of that rule: memory that must outlive the request (a cache
// entry, a session, state handed to another thread, a map or dynamic array of
// the application that is first filled inside a handler) has to come from an
// allocator the application names, not from the default one.
//
// A free or resize of memory the request did not allocate is refused and
// logged once per request: that memory came from another allocator and has to
// go back to it.
//
// A task has none until its request first allocates.
Request_Heap :: struct {
	mutex:      sync.Mutex,
	live:       map[rawptr]Request_Allocation,
	// Bytes the request holds, as it asked for them.
	bytes:      int,
	// A foreign free or resize was already logged for this request.
	warned:     bool,
	// The bytes of a response body on this heap that the server sends from
	// where it is, charged to the operation instead of copied.
	body_lease: budget.Lease,
}

Request_Allocation :: struct {
	size:      int,
	alignment: int,
}

// The allocator of task's request heap. The heap itself appears with the
// first allocation.
request_heap_allocator :: proc(task: ^Connection_Task) -> mem.Allocator {
	return {procedure = request_heap_procedure, data = task}
}

// Bytes the request holds on its heap.
request_heap_bytes :: proc(task: ^Connection_Task) -> int {
	heap := sync.atomic_load(&task.heap)
	if heap == nil {
		return 0
	}
	sync.lock(&heap.mutex)
	defer sync.unlock(&heap.mutex)
	return heap.bytes
}

// Whether bytes starts an allocation the request holds and lies inside it.
request_heap_owns :: proc(task: ^Connection_Task, bytes: []u8) -> bool {
	heap := sync.atomic_load(&task.heap)
	if heap == nil || len(bytes) == 0 {
		return false
	}
	sync.lock(&heap.mutex)
	defer sync.unlock(&heap.mutex)
	held, found := heap.live[raw_data(bytes)]
	return found && len(bytes) <= held.size
}

// Frees everything the request still holds, and the heap with it.
request_heap_release :: proc(task: ^Connection_Task) {
	heap := sync.atomic_exchange(&task.heap, nil)
	if heap == nil {
		return
	}
	budget.release(&heap.body_lease)
	backing := rt.heap_allocator()
	for memory, held in heap.live {
		_ = mem.free_with_size(memory, held.size, backing)
	}
	delete(heap.live)
	free(heap, backing)
}

// The heap of task's request, created when it is first needed.
@(private = "file")
request_heap_of :: proc(task: ^Connection_Task) -> ^Request_Heap {
	if heap := sync.atomic_load(&task.heap); heap != nil {
		return heap
	}
	backing := rt.heap_allocator()
	fresh, error := new(Request_Heap, backing)
	if error != nil {
		return nil
	}
	fresh.live = make(map[rawptr]Request_Allocation, backing)
	if previous, installed := sync.atomic_compare_exchange_strong(&task.heap, nil, fresh); !installed {
		delete(fresh.live)
		free(fresh, backing)
		return previous
	}
	return fresh
}

@(private = "file")
request_heap_procedure :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	task := cast(^Connection_Task)data

	switch mode {
	case .Query_Features:
		if set := cast(^mem.Allocator_Mode_Set)old_memory; set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Free_All, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	case .Free_All:
		request_heap_release(task)
		return nil, nil
	case .Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed:
	}

	if mode == .Free && old_memory == nil {
		return nil, nil
	}
	heap := request_heap_of(task)
	if heap == nil {
		return nil, .Out_Of_Memory
	}

	sync.lock(&heap.mutex)
	memory, error, stray := request_heap_serve(heap, mode, size, alignment, old_memory, loc)
	complain := stray && !heap.warned
	heap.warned ||= stray
	sync.unlock(&heap.mutex)

	// Logged outside the lock: the logger may allocate, with this allocator.
	if complain {
		log.errorf(
			"A %s of memory the request did not allocate was refused. Inside a handler context.allocator is " +
			"the request's: memory that lives longer needs an allocator the application names.",
			"free" if mode == .Free else "resize",
			location = loc,
		)
	}

	return memory, error
}

// One allocation, free or resize, with the heap's lock held. stray: the
// memory named is not the request's.
@(private = "file")
request_heap_serve :: proc(
	heap: ^Request_Heap,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	loc: rt.Source_Code_Location,
) -> (
	memory: []byte,
	error: mem.Allocator_Error,
	stray: bool,
) {
	backing := rt.heap_allocator()

	if mode == .Alloc || mode == .Alloc_Non_Zeroed || old_memory == nil {
		if size <= 0 {
			return nil, nil, false
		}
		// Room for the record first, so that a block the heap was given is
		// never one it cannot account for.
		if reserve(&heap.live, len(heap.live) + 1) != nil {
			return nil, .Out_Of_Memory, false
		}
		if mode == .Alloc || mode == .Resize {
			memory, error = mem.alloc_bytes(size, alignment, backing, loc)
		} else {
			memory, error = mem.alloc_bytes_non_zeroed(size, alignment, backing, loc)
		}
		if error != nil || memory == nil {
			return nil, error if error != nil else .Out_Of_Memory, false
		}
		heap.live[raw_data(memory)] = {size, alignment}
		heap.bytes += size
		return memory, nil, false
	}

	held, found := heap.live[old_memory]
	if !found {
		return nil, .Invalid_Pointer, true
	}

	if mode == .Free || size <= 0 {
		delete_key(&heap.live, old_memory)
		heap.bytes -= held.size
		return nil, mem.free_with_size(old_memory, held.size, backing, loc), false
	}

	// A resize: the process heap extends the block in place when it can. The
	// request's own record of the size is the one that counts.
	if reserve(&heap.live, len(heap.live) + 1) != nil {
		return nil, .Out_Of_Memory, false
	}
	aligned := max(alignment, held.alignment)
	old := (cast([^]byte)old_memory)[:held.size]
	if mode == .Resize {
		memory, error = mem.resize_bytes(old, size, aligned, backing, loc)
	} else {
		memory, error = mem.resize_bytes_non_zeroed(old, size, aligned, backing, loc)
	}
	if error != nil || memory == nil {
		// The old block is untouched and still the request's.
		return nil, error if error != nil else .Out_Of_Memory, false
	}
	if raw_data(memory) != old_memory {
		delete_key(&heap.live, old_memory)
	}
	heap.live[raw_data(memory)] = {size, aligned}
	heap.bytes += size - held.size
	return memory, nil, false
}
