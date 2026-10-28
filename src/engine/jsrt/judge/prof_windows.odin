package jsrt_judge

// A poor man's sampling profiler for `judge eval` (JSRT_PROF=1): a thread suspends the interpreter thread every
// ~0.5 ms, records its RIP, and prints the hottest functions and source lines at exit. Needs a build with -debug
// (the PDB gives the names). Not part of the engine; a measuring aid for src/engine/jsrt.

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import win "core:sys/windows"

@(private = "file")
Aligned_Context :: struct #align (16) {
	c: win.CONTEXT,
}

@(private = "file")
prof_samples: [dynamic]u64
@(private = "file")
prof_target: win.HANDLE
@(private = "file")
prof_stop: bool
@(private = "file")
prof_thread: ^thread.Thread

prof_enabled :: proc() -> bool {
	return win.GetEnvironmentVariableW(win.L("JSRT_PROF"), nil, 0) != 0
}

prof_start :: proc() {
	prof_samples = make([dynamic]u64, 0, 1 << 20, context.allocator)
	win.timeBeginPeriod(1)
	win.DuplicateHandle(win.GetCurrentProcess(), win.GetCurrentThread(), win.GetCurrentProcess(), &prof_target, 0, false, win.DUPLICATE_SAME_ACCESS)
	prof_thread = thread.create_and_start(proc() {
		ac: Aligned_Context
		for !sync.atomic_load(&prof_stop) {
			win.Sleep(1)
			if win.SuspendThread(prof_target) == ~win.DWORD(0) {continue}
			ac.c.ContextFlags = 0x00100001 // CONTEXT_CONTROL
			if win.GetThreadContext(prof_target, &ac.c) {
				append(&prof_samples, u64(ac.c.Rip))
			}
			win.ResumeThread(prof_target)
		}
	}, context)
}

prof_report :: proc() {
	sync.atomic_store(&prof_stop, true)
	thread.join(prof_thread)
	proc_ := win.GetCurrentProcess()
	win.SymSetOptions(win.SYMOPT_LOAD_LINES)
	win.SymInitialize(proc_, nil, true)
	total := len(prof_samples)
	by_fn := make(map[string]int)
	by_line := make(map[string]int)
	cache_fn := make(map[u64]string)
	cache_ln := make(map[u64]string)
	buf: [1024]byte
	for rip in prof_samples {
		if rip not_in cache_fn {
			si := cast(^win.SYMBOL_INFOW)&buf[0]
			si.SizeOfStruct = size_of(win.SYMBOL_INFOW)
			si.MaxNameLen = (len(buf) - size_of(win.SYMBOL_INFOW)) / 2
			name := "?"
			disp: win.DWORD64
			if win.SymFromAddrW(proc_, win.DWORD64(rip), &disp, si) {
				w := cast([^]u16)&si.Name[0]
				s, _ := win.wstring_to_utf8(cast(win.wstring)w, int(si.NameLen))
				name = s
			}
			cache_fn[rip] = name
			ln := name
			line: win.IMAGEHLP_LINE64
			line.SizeOfStruct = size_of(win.IMAGEHLP_LINE64)
			d2: win.DWORD
			if win.SymGetLineFromAddrW64(proc_, win.DWORD64(rip), &d2, &line) {
				fs, _ := win.wstring_to_utf8(line.FileName, -1)
				if i := strings.last_index_byte(fs, '\\'); i >= 0 {fs = fs[i + 1:]}
				ln = fmt.aprintf("%s:%d (%s)", fs, line.LineNumber, name)
			}
			cache_ln[rip] = ln
		}
		by_fn[cache_fn[rip]] += 1
		by_line[cache_ln[rip]] += 1
	}
	dump :: proc(title: string, m: map[string]int, total: int, n: int) {
		Ent :: struct {
			k: string,
			v: int,
		}
		es := make([dynamic]Ent)
		for k, v in m {append(&es, Ent{k, v})}
		slice.sort_by(es[:], proc(a, b: Ent) -> bool {return a.v > b.v})
		fmt.eprintf("--- %s (%d samples)\n", title, total)
		for e, i in es {
			if i >= n {break}
			fmt.eprintf("%6.2f %%  %6d  %s\n", f64(e.v) * 100 / f64(max(total, 1)), e.v, e.k)
		}
	}
	dump("functions", by_fn, total, 40)
	dump("lines", by_line, total, 60)
}
