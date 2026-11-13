#+vet !unused-imports
package browser

// The Windows half of the frame measurement (prof.odin): the clock is QueryPerformanceCounter; the profiler's sampler
// suspends threads and reads their context, and its report names the addresses through DbgHelp and the PDB.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import win "core:sys/windows"
import "wb:stacks"

foreign import dbghelp "system:dbghelp.lib"
foreign import kernel32_prof "system:Kernel32.lib"
foreign import ntdll_prof "system:ntdll.lib"

@(default_calling_convention = "system")
foreign ntdll_prof {
	NtQuerySystemInformation :: proc(class: u32, buffer: rawptr, size: u32, returned: ^u32) -> i32 ---
}

@(default_calling_convention = "system")
foreign kernel32_prof {
	GetModuleHandleExW :: proc(flags: u32, address: rawptr, out: ^win.HMODULE) -> win.BOOL ---
	GetThreadDescription :: proc(thread: win.HANDLE, description: ^win.wstring) -> win.HRESULT ---
}

CONTEXT_CONTROL_AMD64 :: 0x100001
CONTEXT_FULL_AMD64 :: 0x10000B

// QueryPerformanceCounter: its ticks are converted with qpc_frequency.
qpc :: proc "contextless" () -> i64 {
	v: win.LARGE_INTEGER
	win.QueryPerformanceCounter(&v)
	return i64(v)
}

qpc_frequency :: proc "contextless" () -> f64 {
	f: win.LARGE_INTEGER
	win.QueryPerformanceFrequency(&f)
	return f64(f)
}

when PROFILE {

SYM_OPTIONS :: 0x2 | 0x4 | 0x10   // undecorate, defer loads, line numbers

SYMBOL_INFO :: struct {
	SizeOfStruct, TypeIndex: u32,
	Reserved:   [2]u64,
	Index, Size: u32,
	ModBase:    u64,
	Flags:      u32,
	Value, Address: u64,
	Register, Scope, Tag, NameLen, MaxNameLen: u32,
	Name:       [1]u8,
}

@(default_calling_convention = "system")
foreign dbghelp {
	SymInitialize :: proc(process: win.HANDLE, search_path: cstring, invade: win.BOOL) -> win.BOOL ---
	SymSetOptions :: proc(options: u32) -> u32 ---
	SymFromAddr :: proc(process: win.HANDLE, address: u64, displacement: ^u64, symbol: ^SYMBOL_INFO) -> win.BOOL ---
	SymGetLineFromAddr64 :: proc(process: win.HANDLE, address: u64, displacement: ^u32, line: ^IMAGEHLP_LINE64) -> win.BOOL ---
}

IMAGEHLP_LINE64 :: struct {
	SizeOfStruct: u32,
	Key:          rawptr,
	LineNumber:   u32,
	FileName:     cstring,
	Address:      u64,
}

// The UI thread, for the sampler (a real handle: GetCurrentThread's pseudo handle means the caller).
@(private = "file")
sampler_target: win.HANDLE

// The name of a code address. A public symbol has no size and SymFromAddr gives the nearest one before the address, however
// far: every procedure the PDB names no symbol for read as the public symbol before it. Those are named by their source line.
sym_name :: proc(proc_h: win.HANDLE, addr: u64, buf: []u8) -> (name: string, ok: bool) {
	info := (^SYMBOL_INFO)(raw_data(buf))
	info^ = {}
	info.SizeOfStruct = size_of(SYMBOL_INFO)
	info.MaxNameLen = u32(len(buf) - size_of(SYMBOL_INFO))
	disp: u64
	if !SymFromAddr(proc_h, addr, &disp, info) { return }
	if info.Size == 0 || disp >= u64(info.Size) {
		line := IMAGEHLP_LINE64{SizeOfStruct = size_of(IMAGEHLP_LINE64)}
		line_disp: u32
		if SymGetLineFromAddr64(proc_h, addr, &line_disp, &line) {
			file := string(line.FileName)
			if i := strings.last_index_any(file, "\\/"); i >= 0 { file = file[i + 1:] }
			return fmt.tprintf("%s:%d", file, line.LineNumber), true
		}
	}
	return strings.clone(string(cstring(&info.Name[0])), context.temp_allocator), true
}

filetime_u64 :: proc(ft: win.FILETIME) -> u64 { return u64(ft.dwHighDateTime) << 32 | u64(ft.dwLowDateTime) }

process_cpu :: proc() -> (user, kernel: u64) {
	c, e, k, u: win.FILETIME
	win.GetProcessTimes(win.GetCurrentProcess(), &c, &e, &k, &u)
	return filetime_u64(u), filetime_u64(k)   // 100 ns units
}

// WREN_SAMPLE=1 (prof_init): the sampler of the UI thread, and with WREN_SAMPLE_THREADS=1 the one of the other threads.
prof_sampling_start :: proc(app: ^App) {
	win.timeBeginPeriod(1)
	h: win.HANDLE
	win.DuplicateHandle(win.GetCurrentProcess(), win.GetCurrentThread(), win.GetCurrentProcess(), &h, 0, false, win.DUPLICATE_SAME_ACCESS)
	sampler_target = h
	prof.clock = &app.phase_clock
	prof.samples = make([]Sample, 400_000)
	if os.get_env("WREN_SAMPLE_STACK", context.temp_allocator) == "1" || os.get_env("WREN_SAMPLE_STACKS", context.temp_allocator) == "1" {   // (the second spelling is the one the DuckDuckGo audit used)
		prof.stacks = true
		m := win.GetModuleHandleW(nil)
		prof.exe_lo = u64(uintptr(m))
		nt := uintptr(m) + uintptr((^u32)(uintptr(m) + 0x3c)^)
		prof.exe_hi = prof.exe_lo + u64((^u32)(nt + 0x50)^)
	}
	prof.sampling = true
	prof.sampler = thread.create(sampler_proc)
	thread.start(prof.sampler)
	if os.get_env("WREN_SAMPLE_THREADS", context.temp_allocator) == "1" {
		prof.main_tid = win.GetCurrentThreadId()
		prof.osamples = make([]Osample, 600_000)
		prof.osampler = thread.create(other_sampler_proc)
		thread.start(prof.osampler)
	}
}

// The return addresses that lie in the executable (the system's frames between are skipped; the unwind uses the unwind tables the system knows, JIT code's
// included). In the copy made while the thread was stopped, once it runs again (stacks.Stack_Copy: a walk in place ended the browser on cnn.com, code without tables
// sends it through nonsense, and the lookup of the tables takes a lock the stopped thread may hold).
callers_in_exe :: proc(stack: ^stacks.Stack_Copy, ctx: ^win.CONTEXT) -> (out: [SAMPLE_DEPTH]u64) {
	pcs: [SAMPLE_WALK_MOST]u64
	n := 0
	for pc in pcs[:stacks.stack_walk(stack, ctx, pcs[:])] {
		if pc < prof.exe_lo || pc >= prof.exe_hi { continue }
		out[n] = pc
		n += 1
		if n == SAMPLE_DEPTH { return }
	}
	return
}

// A sampler's millisecond, on a high-resolution timer: a Sleep(1) lasts the system's timer period, 5 to 16 ms in a process
// without a window to show, and one load of a page was a few samples.
sample_tick :: proc(timer: rawptr) {
	if timer == nil || !pacer_timer_arm(timer, SAMPLE_PERIOD_NS) { win.Sleep(1); return }
	win.WaitForSingleObject(win.HANDLE(timer), win.INFINITE)
}

sampler_proc :: proc(_: ^thread.Thread) {
	sync.atomic_store(&sampler_tid, win.GetCurrentThreadId())   // (the other threads' sampler leaves it out)
	timer := pacer_timer_create()
	defer pacer_timer_destroy(timer)
	stack: stacks.Stack_Copy
	if prof.stacks { stacks.stack_copy_init(&stack) }
	defer stacks.stack_copy_destroy(&stack)
	for !sync.atomic_load(&prof.stop) {
		sample_tick(timer)
		if win.SuspendThread(sampler_target) == ~u32(0) { continue }
		ctx: win.CONTEXT
		ctx.ContextFlags = prof.stacks ? CONTEXT_FULL_AMD64 : CONTEXT_CONTROL_AMD64
		got := win.GetThreadContext(sampler_target, &ctx)
		if got && prof.stacks { stacks.stack_copy_take(&stack, ctx.Rsp) }
		phase := prof.clock.cur
		win.ResumeThread(sampler_target)
		if got && prof.n_samples < len(prof.samples) {
			sm := Sample{u64(ctx.Rip), phase, qpc(), {}}
			if prof.stacks { sm.from = callers_in_exe(&stack, &ctx) }
			prof.samples[prof.n_samples] = sm
			prof.n_samples += 1
		}
	}
}

module_of :: proc(addr: u64) -> string {
	h: win.HMODULE
	if !GetModuleHandleExW(0x4 | 0x2, rawptr(uintptr(addr)), &h) { return "?" }
	buf: [260]u16
	n := win.GetModuleFileNameW(h, raw_data(buf[:]), 260)
	name, _ := win.wstring_to_utf8(win.wstring(raw_data(buf[:])), int(n), context.temp_allocator)
	if i := strings.last_index_any(name, "\\/"); i >= 0 { name = name[i + 1:] }
	return name
}

// The system's list of the processes and their threads: what a thread is doing right now. (Its layout is the one the system's headers give for 64 bits.)
@(private = "file") SYSTEM_PROCESS_INFORMATION :: 5
@(private = "file") SYSTEM_LIST_BYTES :: 8 << 20
@(private = "file") LIST_NEXT_ENTRY, LIST_THREAD_COUNT, LIST_PROCESS_ID, LIST_THREADS :: 0x0, 0x4, 0x50, 0x100
@(private = "file") LIST_THREAD_BYTES, LIST_THREAD_ID, LIST_THREAD_STATE :: 0x50, 0x30, 0x44
@(private = "file") THREAD_READY, THREAD_RUNNING, THREAD_STANDBY :: 1, 2, 3
@(private = "file") THREAD_SAMPLED_RIGHTS :: 0x2 | 0x8 | 0x800   // SUSPEND_RESUME | GET_CONTEXT | QUERY_LIMITED_INFORMATION
@(private = "file") SYSCALL_OPCODE :: [2]u8{0x0F, 0x05}

// WREN_SAMPLE_THREADS=1: the other threads of the process that are on a processor or waiting for one are stopped in turn, their instruction pointers read, their stacks copied (the main thread
// has its own sampler). Which threads those are comes from the system's list, which is exact and slow (30 ms on a machine with many processes, the list being all of theirs): each thread it
// names is then followed every millisecond, for as long as the list took, until it goes back into the system.
// What was tried before, in order: the thread whose cycle counter moved most, then every thread that ran in the last second. The counter moves when a thread leaves the processor, and a list of
// the threads read twice a second never saw one that lived for a load: the samples were of threads that had just gone back to their wait (0 of 44 807 samples running on repeated loads of p10k,
// docs/performance.md round 25), and stopping a sleeping thread woke it for nothing.
other_sampler_proc :: proc(_: ^thread.Thread) {
	pid := uintptr(win.GetCurrentProcessId())
	me := win.GetCurrentThreadId()
	handles := make(map[u32]win.HANDLE)
	followed := make([dynamic]u32, 0, 64)
	list := make([]u8, SYSTEM_LIST_BYTES)
	defer delete(list)
	timer := pacer_timer_create()
	defer pacer_timer_destroy(timer)
	stack: stacks.Stack_Copy
	stacks.stack_copy_init(&stack)
	defer stacks.stack_copy_destroy(&stack)
	for !sync.atomic_load(&prof.stop) {
		began := qpc()
		clear(&followed)
		size: u32
		if NtQuerySystemInformation(SYSTEM_PROCESS_INFORMATION, raw_data(list), u32(len(list)), &size) >= 0 {
			entry := uintptr(raw_data(list))
			for entry != 0 && (^uintptr)(entry + LIST_PROCESS_ID)^ != pid {
				next := (^u32)(entry + LIST_NEXT_ENTRY)^
				entry = next == 0 ? 0 : entry + uintptr(next)
			}
			for i in 0 ..< (entry == 0 ? 0 : uintptr((^u32)(entry + LIST_THREAD_COUNT)^)) {
				row := entry + LIST_THREADS + i * LIST_THREAD_BYTES
				state := (^u32)(row + LIST_THREAD_STATE)^
				tid := u32((^uintptr)(row + LIST_THREAD_ID)^)
				if state != THREAD_RUNNING && state != THREAD_READY && state != THREAD_STANDBY { continue }
				if tid == me || tid == prof.main_tid || tid == sync.atomic_load(&sampler_tid) { continue }
				append(&followed, tid)
			}
		}
		took := qpc() - began
		until := qpc() + took
		for {
			for i := len(followed) - 1; i >= 0; i -= 1 {
				if !other_sample(followed[i], &handles, &stack) { unordered_remove(&followed, i) }
			}
			sample_tick(timer)
			if len(followed) == 0 || qpc() >= until || sync.atomic_load(&prof.stop) { break }
		}
	}
	for _, h in handles { win.CloseHandle(h) }
	delete(handles)
	delete(followed)
}

// A sample of a thread. False: it has left user code, or the process.
@(private = "file")
other_sample :: proc(tid: u32, handles: ^map[u32]win.HANDLE, stack: ^stacks.Stack_Copy) -> bool {
	h, known := handles[tid]
	if !known {
		h = win.OpenThread(THREAD_SAMPLED_RIGHTS, false, tid)
		if h == nil { return false }
		handles[tid] = h
		prof.names[tid] = thread_name(h)
	}
	if win.SuspendThread(h) == ~u32(0) {   // (it ended, and its id may come back)
		win.CloseHandle(h)
		delete_key(handles, tid)
		return false
	}
	ctx: win.CONTEXT
	ctx.ContextFlags = CONTEXT_FULL_AMD64
	got := win.GetThreadContext(h, &ctx)
	if got { stacks.stack_copy_take(stack, ctx.Rsp) }
	win.ResumeThread(h)
	if !got { return false }
	rip := u64(ctx.Rip)
	if prof.n_osamples < len(prof.osamples) {
		s := Osample{tid = tid, rip = rip}
		s.from = callers_in_exe(stack, &ctx)
		prof.osamples[prof.n_osamples] = s
		prof.n_osamples += 1
	}
	before: [2]u8
	read: uint
	win.ReadProcessMemory(win.GetCurrentProcess(), rawptr(uintptr(rip - len(before))), &before, len(before), &read)
	return before != SYSCALL_OPCODE
}


// The name a thread gave itself ("": none).
@(private = "file")
thread_name :: proc(h: win.HANDLE) -> string {
	w: win.wstring
	if GetThreadDescription(h, &w) < 0 || w == nil { return "" }
	defer win.LocalFree(rawptr(w))
	name, _ := win.wstring_to_utf8(w, -1, context.allocator)
	return name
}

@(private = "file")
sampler_tid: u32

// The other threads' samples: per thread, how much of it was spent waiting and the functions it was in when it was not, with who
// called them. A thread that spins in the kernel (a yield, a zero-timeout wait) shows as "running" in a system call.
report_threads :: proc(sb: ^strings.Builder) {
	proc_h := win.GetCurrentProcess()
	SymSetOptions(SYM_OPTIONS)
	SymInitialize(proc_h, ".;build", true)
	buf: [768]u8
	cache := make(map[u64]string, context.temp_allocator)
	sym :: proc(addr: u64, proc_h: win.HANDLE, buf: []u8, cache: ^map[u64]string) -> string {
		if s, ok := cache[addr]; ok { return s }
		name, ok := sym_name(proc_h, addr, buf)
		r := ok ? fmt.tprintf("%s!%s", module_of(addr), name) : fmt.tprintf("%s+0x%x", module_of(addr), addr & 0xffff)
		r = strings.clone(r, context.temp_allocator)
		cache[addr] = r
		return r
	}
	waiting :: proc(name: string) -> bool {
		for w in ([]string{"WaitForAlertByThread", "WaitForSingleObject", "WaitForMultipleObjects", "RemoveIoCompletion", "WaitForWorkViaWorkerFactory", "WaitOnAddress", "MsgWaitForMultipleObjects", "GetMessage", "WaitForKeyedEvent", "ZwWaitForAlertByThreadId", "SleepEx"}) {
			if strings.contains(name, w) { return true }
		}
		return false
	}
	Thread_Row :: struct { tid: u32, total, wait: int, by: map[string]int, incl: map[string]int }   // incl: by function anywhere on the stack
	rows := make(map[u32]^Thread_Row, context.temp_allocator)
	for s in prof.osamples[:prof.n_osamples] {
		r, ok := rows[s.tid]
		if !ok {
			r = new(Thread_Row, context.temp_allocator)
			r.tid = s.tid
			r.by = make(map[string]int, context.temp_allocator)
			r.incl = make(map[string]int, context.temp_allocator)
			rows[s.tid] = r
		}
		r.total += 1
		top := sym(s.rip, proc_h, buf[:], &cache)
		if waiting(top) { r.wait += 1; continue }
		key := top
		for j in 0 ..< 3 {
			a := s.from[j]
			if a == 0 { break }
			key = fmt.tprintf("%s <- %s", key, sym(a, proc_h, buf[:], &cache))
		}
		r.by[key] += 1
		// inclusive: each function once per sample (recursion counted once)
		seen: [SAMPLE_DEPTH + 1]string
		n := 0
		frames: for j in 0 ..= SAMPLE_DEPTH {
			addr := j == 0 ? s.rip : s.from[j - 1]
			if addr == 0 { break }
			name := sym(addr, proc_h, buf[:], &cache)
			for k in 0 ..< n { if seen[k] == name { continue frames } }
			seen[n] = name
			n += 1
			r.incl[name] += 1
		}
	}
	list := make([dynamic]^Thread_Row, context.temp_allocator)
	for _, r in rows { append(&list, r) }
	slice.sort_by(list[:], proc(a, b: ^Thread_Row) -> bool { return a.total - a.wait > b.total - b.wait })
	fmt.sbprintf(sb, "\n=== the other threads (WREN_SAMPLE_THREADS=1): %d samples of %d threads; the busiest first (running = not in a wait) ===\n", prof.n_osamples, len(list))
	running_all := 0
	for r in list { running_all += r.total - r.wait }
	fmt.sbprintf(sb, "all threads: %d of %d samples were not in a wait (%.1f %%)\n", running_all, prof.n_osamples, f64(running_all) * 100 / f64(max(prof.n_osamples, 1)))
	for r, i in list {
		if i >= 12 { break }
		fmt.sbprintf(sb, "\n  thread %d %s: %d samples, running %d (%.0f %%)\n", r.tid, prof.names[r.tid], r.total, r.total - r.wait, f64(r.total - r.wait) * 100 / f64(max(r.total, 1)))
		Row :: struct { k: string, v: int }
		items := make([dynamic]Row, context.temp_allocator)
		for k, v in r.by { append(&items, Row{k, v}) }
		slice.sort_by(items[:], proc(a, b: Row) -> bool { return a.v > b.v })
		for it, j in items {
			if j >= 7 { break }
			fmt.sbprintf(sb, "    %5.1f %%  %s\n", f64(it.v) * 100 / f64(max(r.total - r.wait, 1)), it.k)
		}
		clear(&items)
		for k, v in r.incl { append(&items, Row{k, v}) }
		slice.sort_by(items[:], proc(a, b: Row) -> bool { return a.v > b.v })
		fmt.sbprintf(sb, "    on the stack (inclusive):\n")
		for it, j in items {
			if j >= THREAD_INCLUSIVE_ROWS { break }
			fmt.sbprintf(sb, "    %5.1f %%  %s\n", f64(it.v) * 100 / f64(max(r.total - r.wait, 1)), it.k)
		}
	}
}

// The functions on the stack listed for each of the busiest other threads.
@(private = "file") THREAD_INCLUSIVE_ROWS :: 30

// Start-up moments since the process was created (its creation time, brought into the QPC time line).
report_startup :: proc(sb: ^strings.Builder) {
	c, e, k, u: win.FILETIME
	win.GetProcessTimes(win.GetCurrentProcess(), &c, &e, &k, &u)
	now_ft: win.FILETIME
	win.GetSystemTimePreciseAsFileTime(&now_ft)
	now_q := qpc()
	since_ms := f64(filetime_u64(now_ft) - filetime_u64(c)) / 1e4
	created := f64(now_q) - since_ms * prof.freq / 1000   // QPC of the process creation
	at :: proc(q: i64, created, freq: f64) -> f64 { return (f64(q) - created) * 1000 / freq }
	fmt.sbprintf(sb, "\n-- start-up (ms since the process was created)\n")
	for m in Startup_Mark {
		if startup_marks[m] == 0 { fmt.sbprintf(sb, "  %-17v        -\n", m); continue }
		fmt.sbprintf(sb, "  %-17v %8.1f\n", m, at(startup_marks[m], created, prof.freq))
	}
	if startup_marks[.Navigation] != 0 && startup_marks[.First_Page_Paint] != 0 {
		fmt.sbprintf(sb, "  navigation -> first page paint: %.1f ms\n", f64(startup_marks[.First_Page_Paint] - startup_marks[.Navigation]) * 1000 / prof.freq)
	}
	// the page as it ends up: the first frame that paints as many layout items as the last one
	if n := len(prof.frames); n > 0 && prof.frames[n - 1].items > 0 {
		final := prof.frames[n - 1].items
		for f in prof.frames {
			if f.items < final { continue }
			t := at(prof.t0, created, prof.freq) + f64(f.t_ms)
			fmt.sbprintf(sb, "  first frame with the page's final content (%d items): %.1f ms", final, t)
			if startup_marks[.Navigation] != 0 { fmt.sbprintf(sb, " (navigation + %.1f ms)", t - at(startup_marks[.Navigation], created, prof.freq)) }
			strings.write_byte(sb, '\n')
			break
		}
	}
}

report_samples :: proc(sb: ^strings.Builder) {
	proc_h := win.GetCurrentProcess()
	SymSetOptions(SYM_OPTIONS)
	SymInitialize(proc_h, ".;build", true)

	// resolve each distinct address once
	Sym :: struct { name, module: string }
	cache := make(map[u64]Sym, context.temp_allocator)
	buf: [768]u8
	resolve :: proc(addr: u64, proc_h: win.HANDLE, buf: []u8) -> Sym {
		mod := module_of(addr)
		if name, ok := sym_name(proc_h, addr, buf); ok { return {strings.clone(name, context.temp_allocator), mod} }
		return {fmt.tprintf("%s+0x%x", mod, addr & 0xffff), mod}
	}

	total := prof.n_samples
	idle := 0
	by_symbol := make(map[string]int, context.temp_allocator)
	by_module := make(map[string]int, context.temp_allocator)
	by_phase_symbol := make(map[Phase]map[string]int, context.temp_allocator)
	by_phase := make(map[Phase]int, context.temp_allocator)
	for s in prof.samples[:prof.n_samples] {
		sym, ok := cache[s.rip]
		if !ok { sym = resolve(s.rip, proc_h, buf[:]); cache[s.rip] = sym }
		key := fmt.tprintf("%s!%s", sym.module, sym.name)
		by_symbol[key] += 1
		by_module[sym.module] += 1
		by_phase[s.phase] += 1
		m, has := by_phase_symbol[s.phase]
		if !has { m = make(map[string]int, context.temp_allocator) }
		m[key] += 1
		by_phase_symbol[s.phase] = m
		if s.phase == .Idle { idle += 1 }
	}

	top :: proc(sb: ^strings.Builder, m: map[string]int, n: int, total: int, indent: string) {
		Row :: struct { k: string, v: int }
		rows := make([dynamic]Row, context.temp_allocator)
		for k, v in m { append(&rows, Row{k, v}) }
		slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.v > b.v })
		for r, i in rows { if i >= n { break }; fmt.sbprintf(sb, "%s%5.1f %%  %6d  %s\n", indent, f64(r.v) * 100 / f64(max(total, 1)), r.v, r.k) }
	}

	fmt.sbprintf(sb, "\n=== sampling: %d samples (1 ms), %d while idle-waiting (%.1f %%) ===\n", total, idle, f64(idle) * 100 / f64(max(total, 1)))
	fmt.sbprintf(sb, "\n-- by phase (share of all samples)\n")
	phases := make([dynamic]Phase, context.temp_allocator)
	for p in by_phase { append(&phases, p) }
	slice.sort_by(phases[:], proc(a, b: Phase) -> bool { return prof.n_samples > 0 && a < b })
	for p in phases { fmt.sbprintf(sb, "  %5.1f %%  %6d  %v\n", f64(by_phase[p]) * 100 / f64(max(total, 1)), by_phase[p], p) }
	fmt.sbprintf(sb, "\n-- by module\n")
	top(sb, by_module, 12, total, "  ")
	fmt.sbprintf(sb, "\n-- hottest functions overall\n")
	top(sb, by_symbol, 35, total, "  ")
	for p in phases {
		if p == .Idle || p == .None || by_phase[p] < 20 { continue }
		fmt.sbprintf(sb, "\n-- hottest functions in phase %v (%d samples)\n", p, by_phase[p])
		top(sb, by_phase_symbol[p], 15, by_phase[p], "  ")
	}

	// With WREN_SAMPLE_STACK=1: the samples of work (not waiting) by the functions anywhere on the stack, and what ran below
	// WREN_SAMPLE_UNDER=<function> (its callees, self and inclusive).
	if prof.stacks {
		incl := make(map[string]int, context.temp_allocator)
		under_name := os.get_env("WREN_SAMPLE_UNDER", context.temp_allocator)
		under_self := make(map[string]int, context.temp_allocator)
		under_incl := make(map[string]int, context.temp_allocator)
		under_total, active := 0, 0
		names := make([dynamic]string, 0, SAMPLE_DEPTH + 2, context.temp_allocator)
		for s in prof.samples[:prof.n_samples] {
			if s.phase == .Idle || s.phase == .Wait || s.phase == .None { continue }
			active += 1
			clear(&names)
			append(&names, cache[s.rip].name)
			for a in s.from {
				if a == 0 { break }
				cs, ok := cache[a]
				if !ok { cs = resolve(a, proc_h, buf[:]); cache[a] = cs }
				append(&names, cs.name)
			}
			at := -1
			for nm, i in names {
				dup := false
				for j in 0 ..< i { if names[j] == nm { dup = true; break } }
				if dup { continue }
				incl[nm] += 1
				if under_name != "" && at < 0 && nm == under_name { at = i }
			}
			if at >= 0 {
				under_total += 1
				under_self[names[0]] += 1
				for i in 0 ..< at {
					dup := false
					for j in 0 ..< i { if names[j] == names[i] { dup = true; break } }
					if !dup { under_incl[names[i]] += 1 }
				}
			}
		}
		fmt.sbprintf(sb, "\n-- functions on the stack of the samples of work, inclusive (%d samples; the executable's frames only)\n", active)
		top(sb, incl, 45, active, "  ")
		if under_name != "" && under_total > 0 {
			fmt.sbprintf(sb, "\n-- below %s (%d samples): what ran, self\n", under_name, under_total)
			top(sb, under_self, 25, under_total, "  ")
			fmt.sbprintf(sb, "\n-- below %s: callees, inclusive\n", under_name)
			top(sb, under_incl, 30, under_total, "  ")
		}
	}

	// the frames whose CPU work (without the wait for the screen) ran past WREN_SLOW_MS (30): what they spent it in. The
	// averages above bury a script that takes 85 ms once in 5 s.
	slow_ms := 30.0
	if v := os.get_env("WREN_SLOW_MS", context.temp_allocator); v != "" { if f, ok := strconv.parse_f64(v); ok { slow_ms = f } }
	from_ms := 0.0   // (WREN_SLOW_FROM_MS: not the load)
	if v := os.get_env("WREN_SLOW_FROM_MS", context.temp_allocator); v != "" { if f, ok := strconv.parse_f64(v); ok { from_ms = f } }
	slow := make(map[string]int, context.temp_allocator)
	slow_total, slow_frames := 0, 0
	next := 0
	for f in prof.frames {
		work := f64(f.dur[.Frame] - f.dur[.Wait] - f.dur[.Present])
		if work <= slow_ms || f64(f.t_ms) < from_ms { continue }
		slow_frames += 1
		end := f64(f.t_ms)
		start := end - f64(f.dur[.Frame])
		for next < prof.n_samples && f64(prof.samples[next].t - prof.t0) * 1000 / prof.freq < start { next += 1 }
		for j := next; j < prof.n_samples; j += 1 {
			s := prof.samples[j]
			ms := f64(s.t - prof.t0) * 1000 / prof.freq
			if ms > end { break }
			if s.phase == .Wait || s.phase == .Idle || s.phase == .Present { continue }
			sym := cache[s.rip]
			key := fmt.tprintf("%s!%s [%v]", sym.module, sym.name, s.phase)
			if s.from[0] != 0 {
				for a in s.from[:2] {
					if a == 0 { break }
					cs, ok := cache[a]
					if !ok { cs = resolve(a, proc_h, buf[:]); cache[a] = cs }
					key = fmt.tprintf("%s <- %s", key, cs.name)
				}
			}
			slow[key] += 1
			slow_total += 1
		}
	}
	if slow_frames > 0 {
		fmt.sbprintf(sb, "\n-- hottest functions in the %d frames with more than %.0f ms of CPU work (%d samples)\n", slow_frames, slow_ms, slow_total)
		top(sb, slow, 25, slow_total, "  ")
	}
}

}
