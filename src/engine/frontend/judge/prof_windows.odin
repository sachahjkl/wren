#+build windows
package judge

// `prof <file> <iters>`: a sampling profiler for the compiler. A worker thread compiles the file in a loop while
// this thread suspends it about every millisecond, records its instruction pointer, and finally maps the samples
// to function names through the PDB (dbghelp). Coarse, but it needs no external tool.

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:thread"
import "core:sync"
import win32 "core:sys/windows"
import fe "wb:engine/frontend"

PROF_SAMPLES_MAX :: 1 << 20

@(private = "file")
Prof_Job :: struct {
	src:   string,
	iters: int,
	done:  bool,
}

cmd_prof :: proc(file: string, iters: int) -> int {
	src, ok := read_file(file)
	if !ok {return 1}
	job := Prof_Job{src = src, iters = iters}
	worker := thread.create_and_start_with_data(&job, proc(p: rawptr) {
		j := (^Prof_Job)(p)
		for _ in 0 ..< j.iters {
			arena: mem.Dynamic_Arena
			mem.dynamic_arena_init(&arena)
			_ = fe.compile_program(j.src, .script, mem.dynamic_arena_allocator(&arena))
			mem.dynamic_arena_destroy(&arena)
		}
		sync.atomic_store(&j.done, true)
	})
	h := worker.win32_thread
	// (filled while the worker is suspended: it may hold the heap's lock, a map growing here would wait for it for ever)
	samples := make([]u64, PROF_SAMPLES_MAX)
	total := 0
	ctx := new(win32.CONTEXT) // heap: CONTEXT wants 16-byte alignment
	win32.timeBeginPeriod(1)
	for !sync.atomic_load(&job.done) && total < PROF_SAMPLES_MAX {
		win32.Sleep(1)
		if win32.SuspendThread(h) == max(win32.DWORD) {break}
		ctx.ContextFlags = 0x00100001 // CONTEXT_CONTROL (AMD64)
		if win32.GetThreadContext(h, ctx) {
			samples[total] = ctx.Rip
			total += 1
		}
		win32.ResumeThread(h)
	}
	thread.join(worker)
	thread.destroy(worker)

	proc_h := win32.GetCurrentProcess()
	win32.SymInitialize(proc_h, nil, true)
	by_name := make(map[string]int)
	buf := make([]u8, size_of(win32.SYMBOL_INFOW) + 512 * 2)
	counts := make(map[u64]int)
	for addr in samples[:total] { counts[addr] += 1 }
	for addr, n in counts {
		info := (^win32.SYMBOL_INFOW)(raw_data(buf))
		info.SizeOfStruct = size_of(win32.SYMBOL_INFOW)
		info.MaxNameLen = 511
		disp: win32.DWORD64
		name := "?"
		if win32.SymFromAddrW(proc_h, addr, &disp, info) {
			w := ([^]u16)(&info.Name[0])[:info.NameLen]
			s, _ := win32.utf16_to_utf8(w)
			name = s
		}
		by_name[name] += n
	}
	Entry :: struct {name: string, n: int}
	list := make([dynamic]Entry)
	for k, v in by_name {append(&list, Entry{k, v})}
	slice.sort_by(list[:], proc(a, b: Entry) -> bool {return a.n > b.n})
	fmt.printfln("%d samples", total)
	for e, i in list {
		if i >= 40 {break}
		fmt.printfln("%6.2f%%  %s", 100 * f64(e.n) / f64(max(total, 1)), e.name)
	}
	return 0
}
