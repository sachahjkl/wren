package base

// The process's allocators, and the memory tracker of the check builds.
//
// Memory that does not belong to the caller's context (shared between threads, kept by a cache, handed to a callback
// of a foreign thread, Wasm host calls) comes from `process_allocator()`, and code that runs without an Odin context
// (threads, "c" callbacks of WinHTTP, Wasmtime, the system) starts from `process_context()`, never from
// `runtime.default_context()` / `runtime.heap_allocator()` directly: in a normal build they are the process heap, in a
// build with -define:WREN_TRACK_MEMORY=true they are a tracker every thread shares, which knows every live block
// (size, place of the allocation, optionally its call stack) and reports what is still allocated at exit.
// Data kept on purpose until the process ends (tables built once, interned strings) comes from `permanent_allocator()`:
// tracked too, but counted apart and never reported as a leak.
//
// What the tracker does not see: the temporary allocators (per-thread arenas, freed in bulk), the virtual memory
// arenas (base.Scope, vmem.Arena: VirtualAlloc), native libraries (Wasmtime, Lexbor, the image decoders, DirectWrite,
// Direct3D) and memory a foreign context allocates on the heap directly. tools\endurance.ps1 watches the process's
// private bytes and handles for those.

import "base:runtime"
import "core:debug/trace"
import "core:fmt"
import "core:os"
@(require) import "core:slice"
import "core:strings"
import "core:sync"

TRACK_MEMORY :: #config(WREN_TRACK_MEMORY, false)

@(private) HEAP :: runtime.Allocator{runtime.heap_allocator_proc, nil}

// The context of code that has none of its own: the process heap, or the tracker of a check build.
process_context :: #force_inline proc "contextless" () -> runtime.Context {
	c := runtime.default_context()
	when TRACK_MEMORY { c.allocator = runtime.Allocator{tracker_proc, &tracker} }
	return c
}

process_allocator :: #force_inline proc "contextless" () -> runtime.Allocator {
	when TRACK_MEMORY { return runtime.Allocator{tracker_proc, &tracker} } else { return HEAP }
}

// For data kept until the process ends on purpose (built once, never replaced): never reported as a leak. Frees are
// allowed (a table rebuilt by a test), the block is then forgotten like any other.
permanent_allocator :: proc "contextless" () -> runtime.Allocator {
	when TRACK_MEMORY { return runtime.Allocator{tracker_proc, &permanent_marker} } else { return HEAP }
}

Mem_Stats :: struct {
	tracked:          bool,   // false in a normal build: everything below is zero
	live_bytes:       i64,    // allocated and not freed, permanent blocks excluded
	live_blocks:      i64,
	peak_bytes:       i64,
	permanent_bytes:  i64,
	permanent_blocks: i64,
	total_allocs:     i64,
	total_frees:      i64,
	foreign_frees:    i64,    // frees of blocks the tracker never saw (allocated outside it): passed to the heap
	bad_frees:        i64,    // frees of a block already freed: refused
}

mem_stats :: proc "contextless" () -> (s: Mem_Stats) {
	when TRACK_MEMORY {
		sync.mutex_lock(&tracker.lock)
		s = tracker.stats
		sync.mutex_unlock(&tracker.lock)
		s.tracked = true
	}
	return
}

// Prints what is still allocated (grouped by place of allocation, largest first) and the counters to stdout, and to
// the file WREN_MEMTRACK_REPORT names when it is set (appended). Returns the number of leaked blocks plus the bad
// frees: 0 means clean. Call it after everything was shut down (threads joined, pages closed, caches stopped). A normal
// build reports nothing and returns 0.
mem_report :: proc(title: string) -> (problems: int) {
	when TRACK_MEMORY {
		context.allocator = runtime.heap_allocator()
		Group :: struct { loc: runtime.Source_Code_Location, stack: Stack, blocks: int, bytes: int }
		groups: map[Group_Key]Group
		defer delete(groups)
		sync.mutex_lock(&tracker.lock)
		st := tracker.stats
		for _, e in tracker.live {
			if e.permanent { continue }
			k := Group_Key{e.loc.file_path, e.loc.line, e.stack}
			g := groups[k] or_else Group{loc = e.loc, stack = e.stack}
			g.blocks += 1
			g.bytes += e.size
			groups[k] = g
		}
		bad := slice.clone(tracker.bad[:])
		sync.mutex_unlock(&tracker.lock)
		defer delete(bad)
		list := make([dynamic]Group, 0, len(groups))
		defer delete(list)
		for _, g in groups { append(&list, g) }
		slice.sort_by(list[:], proc(a, b: Group) -> bool { return a.bytes > b.bytes })

		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		fmt.sbprintfln(&b, "memtrack: %s: %d leaked block(s), %d byte(s); %d bad free(s); peak %d byte(s), %d allocation(s), %d permanent block(s) (%d byte(s)), %d foreign free(s)",
			title, st.live_blocks, st.live_bytes, st.bad_frees, st.peak_bytes, st.total_allocs, st.permanent_blocks, st.permanent_bytes, st.foreign_frees)
		for g, i in list {
			if i == REPORT_GROUPS { fmt.sbprintfln(&b, "  ... %d more place(s)", len(list) - i); break }
			fmt.sbprintfln(&b, "  leak: %d block(s), %d byte(s) at %s:%d (%s)", g.blocks, g.bytes, g.loc.file_path, g.loc.line, g.loc.procedure)
			write_stack(&b, g.stack)
		}
		for f in bad {
			fmt.sbprintfln(&b, "  bad free: %p at %s:%d (%s), the block was already freed", f.ptr, f.loc.file_path, f.loc.line, f.loc.procedure)
			write_stack(&b, f.stack)
		}
		text := strings.to_string(b)
		fmt.print(text)   // stdout: test_all's steps read it (a child's stderr would break their job)
		if path := os.get_env("WREN_MEMTRACK_REPORT", context.temp_allocator); path != "" {
			if fd, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND); err == nil {
				_, _ = os.write_string(fd, text)
				os.close(fd)
			}
		}
		return int(st.live_blocks + st.bad_frees)
	} else {
		return 0
	}
}

// Forgets every block allocated so far (they stay valid and may be freed later). For a program that cannot free what
// it allocated before some point (a third-party initialization) and wants only what follows to be checked.
mem_forget_live :: proc() {
	when TRACK_MEMORY {
		sync.mutex_lock(&tracker.lock)
		for _, &e in tracker.live {
			if e.permanent { continue }
			e.permanent = true
			tracker.stats.live_bytes -= i64(e.size); tracker.stats.live_blocks -= 1
			tracker.stats.permanent_bytes += i64(e.size); tracker.stats.permanent_blocks += 1
		}
		sync.mutex_unlock(&tracker.lock)
	}
}

////////////////////////////////
// The tracker (check builds)

// Frames of the call stack kept per block: WREN_MEMTRACK_STACK=1 at start-up (slower: every allocation walks its
// stack). Without it, the place of the allocation is the line that called the allocator (often a helper: strings.clone).
@(private) STACK_DEPTH :: 16
@(private) REPORT_GROUPS :: 60
@(private) Stack :: [STACK_DEPTH]trace.Capture_Entry

@(private) Entry :: struct {
	size:      int,
	loc:       runtime.Source_Code_Location,
	permanent: bool,
	stack:     Stack,
}

@(private) Bad_Free :: struct {
	ptr:   rawptr,
	loc:   runtime.Source_Code_Location,
	stack: Stack,
}

@(private) Group_Key :: struct { file: string, line: i32, stack: Stack }

@(private) Tracker :: struct {
	lock:      sync.Mutex,
	live:      map[rawptr]Entry,
	freed:     map[rawptr]struct{},   // freed blocks whose address was not given out again: a second free is refused
	bad:       [dynamic]Bad_Free,
	stats:     Mem_Stats,
	stacks:    int,                   // 0 unknown, 1 off, 2 on
}

@(private) tracker: Tracker
@(private) permanent_marker: u8   // the data pointer of permanent_allocator(): same tracker, blocks marked permanent

@(private)
tracker_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	heap := runtime.heap_allocator()
	permanent := data == &permanent_marker
	t := &tracker
	#partial switch mode {
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil { set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features} }
		return nil, nil
	case .Query_Info, .Free_All:
		return nil, .Mode_Not_Implemented
	}
	stack: Stack
	if want_stacks() && mode != .Free { _ = trace.capture_fill(stack[:], 1) }

	sync.mutex_lock(&t.lock)
	defer sync.mutex_unlock(&t.lock)
	context.allocator = heap   // the tracker's own maps
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		r, err := heap.procedure(heap.data, mode, size, alignment, old_memory, old_size, loc)
		if err == nil && r != nil { add(t, raw_data(r), size, loc, permanent, stack) }
		return r, err
	case .Free:
		if old_memory == nil { return nil, nil }
		if e, ok := t.live[old_memory]; ok {
			remove(t, old_memory, e)
			t.freed[old_memory] = {}
		} else if old_memory in t.freed {
			if want_stacks() { _ = trace.capture_fill(stack[:], 1) }
			append(&t.bad, Bad_Free{old_memory, loc, stack})
			t.stats.bad_frees += 1
			return nil, nil   // a double free: refused, the heap stays sound
		} else {
			t.stats.foreign_frees += 1
		}
		return heap.procedure(heap.data, mode, size, alignment, old_memory, old_size, loc)
	case .Resize, .Resize_Non_Zeroed:
		e, known := t.live[old_memory]
		if old_memory != nil && !known && old_memory in t.freed {
			append(&t.bad, Bad_Free{old_memory, loc, stack})
			t.stats.bad_frees += 1
			return nil, .Invalid_Pointer
		}
		r, err := heap.procedure(heap.data, mode, size, alignment, old_memory, old_size, loc)
		if err != nil { return r, err }
		if known {
			remove(t, old_memory, e)
			permanent = e.permanent
		}
		if raw_data(r) != old_memory && old_memory != nil { t.freed[old_memory] = {} }
		if r != nil { add(t, raw_data(r), size, loc, permanent, stack) }
		return r, err
	case .Free_All, .Query_Features, .Query_Info:
	}
	return nil, .Mode_Not_Implemented
}

@(private)
add :: proc(t: ^Tracker, p: rawptr, size: int, loc: runtime.Source_Code_Location, permanent: bool, stack: Stack) {
	delete_key(&t.freed, p)
	t.live[p] = Entry{size = size, loc = loc, permanent = permanent, stack = stack}
	t.stats.total_allocs += 1
	if permanent {
		t.stats.permanent_bytes += i64(size); t.stats.permanent_blocks += 1
	} else {
		t.stats.live_bytes += i64(size); t.stats.live_blocks += 1
		t.stats.peak_bytes = max(t.stats.peak_bytes, t.stats.live_bytes)
	}
}

@(private)
remove :: proc(t: ^Tracker, p: rawptr, e: Entry) {
	delete_key(&t.live, p)
	t.stats.total_frees += 1
	if e.permanent {
		t.stats.permanent_bytes -= i64(e.size); t.stats.permanent_blocks -= 1
	} else {
		t.stats.live_bytes -= i64(e.size); t.stats.live_blocks -= 1
	}
}

@(private)
want_stacks :: proc "contextless" () -> bool {
	s := sync.atomic_load(&tracker.stacks)
	if s == 0 {
		context = runtime.default_context()
		on := os.get_env("WREN_MEMTRACK_STACK", context.temp_allocator) == "1"
		s = on ? 2 : 1
		sync.atomic_store(&tracker.stacks, s)
	}
	return s == 2
}

@(private)
write_stack :: proc(b: ^strings.Builder, stack: Stack) {
	stack := stack
	n := 0
	for f in stack { if f == 0 { break }; n += 1 }
	if n == 0 { return }
	locs, err := trace.resolve_n(stack[:n], context.allocator, context.temp_allocator)
	if err != nil { return }
	defer trace.locations_destroy(locs, context.allocator)
	shown := 0
	for l in locs {
		// the allocator's own frames (make, new, the tracker) say nothing
		if strings.has_prefix(l.procedure, "runtime::") || strings.has_prefix(l.procedure, "base::[memory.odin]") { continue }
		if l.procedure == "main" || shown == 10 { break }
		fmt.sbprintfln(b, "      %s  %s:%d", l.procedure, l.file_path, l.line)
		shown += 1
	}
}
