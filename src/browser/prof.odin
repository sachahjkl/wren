#+vet !unused-imports
package browser

// Measurement of frames.
//
// Every build: the phase clock. prof_begin / prof_end around the steps of a frame add their wall time
// (QueryPerformanceCounter) to the frame's phases, when someone reads them: the status bar's graph and the window
// title (hud.odin), or the profiler. Off, each is one test of a flag.
//
// The profiler, compiled in only with -define:PROFILE=true (build.bat profile -> build\wren_prof.exe), records at run
// time, when the environment variable WREN_PROF names an output prefix:
//   * wall time of each phase of every frame, written as <prefix>.csv;
//   * GPU time of the frame's draw commands (the renderer's timestamp queries, read back a few frames later);
//   * with WREN_SAMPLE=1, a sampling profiler: a thread that every millisecond suspends the UI thread, reads its instruction
//     pointer and attributes it to the phase being measured; symbols come from the PDB (our code) and from DLL exports
//     (system, graphics driver). Written to <prefix>.txt together with the per-phase statistics and the process CPU time.

PROFILE :: #config(PROFILE, false)

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import win "core:sys/windows"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:images"
import lay "wb:layout"
import "wb:page"
import "wb:tools/crashtrace"
import "wb:trace"

when ODIN_OS == .Windows {
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
}

CONTEXT_CONTROL_AMD64 :: 0x100001
CONTEXT_FULL_AMD64 :: 0x10000B

// (Styles, Layout and Paint_Items run inside UI_Draw: the page is a custom box of the UI tree. Animation: the page's
// animation frame callbacks.)
Phase :: enum u8 {
	None, Idle, Frame, Wait, Events, Loop, Input, Build_UI, UI_Draw, Styles, Layout, Paint_Items, Submit, Present, Animation,
	// inside Paint_Items (its time includes theirs): the textures of images, canvases and SVG rasters made and filled
	Tex_Create, Tex_Upload,
}

// The phase clock of the frame being drawn. `on`: someone reads it this frame (hud_wants_clock, or the profiler).
Phase_Clock :: struct {
	on:      bool,
	freq:    f64,
	started: [Phase]i64,
	acc:     [Phase]f64,   // ms of each phase so far in this frame
	cur:     Phase,        // what runs now (the sampler attributes its samples to it)
}


// When the phase that runs started (WREN_SPANS), and what a span calls it.
phase_span_start: [Phase]i64
PHASE_NAMES := [Phase]string{
	.None = "none", .Idle = "idle", .Frame = "frame", .Wait = "wait", .Events = "events", .Loop = "loop", .Input = "input", .Build_UI = "build_ui", .UI_Draw = "ui_draw", .Styles = "styles", .Layout = "layout",
	.Paint_Items = "paint_items", .Submit = "submit", .Present = "present", .Animation = "animation", .Tex_Create = "tex_create", .Tex_Upload = "tex_upload",
}

// The phases as zones of the external profilers (package trace: Tracy, ETW), made once at the process's start (trace_start).
phase_sites: [Phase]trace.Site

// The external profilers (package trace), from main before any frame: nothing without their switches.
trace_start :: proc() {
	when trace.ON {
		trace.start()
		for p in Phase { trace.site_init(&phase_sites[p], fmt.tprint(p), base.permanent_allocator()) }
	}
}

// A monotonic counter for the profiler's phase timing. On Windows it is QueryPerformanceCounter (its own frequency,
// read where the samples are turned into milliseconds); elsewhere it is core:time's nanosecond tick, so the "ticks" are
// nanoseconds there (the millisecond conversion divides by the frequency the sampler records, 1e9 off Windows).
qpc :: proc "contextless" () -> i64 {
	when ODIN_OS == .Windows {
		v: win.LARGE_INTEGER
		win.QueryPerformanceCounter(&v)
		return i64(v)
	} else {
		return time.tick_now()._nsec
	}
}

// Milliseconds elapsed since a qpc() tick, always available (its own frequency: the profiler clock may be off). Used by
// the Long Animation Frames timing (page_frame.odin) to measure style and layout wall time regardless of profiling.
@(private)
qpc_freq_cached: f64

qpc_ms_since :: proc "contextless" (t0: i64) -> f64 {
	if qpc_freq_cached == 0 {
		when ODIN_OS == .Windows {
			f: win.LARGE_INTEGER
			win.QueryPerformanceFrequency(&f)
			qpc_freq_cached = f64(f)
		} else {
			qpc_freq_cached = 1e9   // qpc() returns nanoseconds off Windows
		}
	}
	if qpc_freq_cached == 0 { return 0 }
	return f64(qpc() - t0) * 1000 / qpc_freq_cached
}

prof_begin :: proc "contextless" (p: Phase) {
	trace.begin(&phase_sites[p])
	phase_span_start[p] = base.span_now()
	if !the_app.phase_clock.on { return }
	the_app.phase_clock.started[p] = qpc()
	the_app.phase_clock.cur = p
}

prof_end :: proc "contextless" (p: Phase) {
	trace.end(&phase_sites[p])
	base.span_add(.Phase, phase_span_start[p], PHASE_NAMES[p])
	if !the_app.phase_clock.on { return }
	the_app.phase_clock.acc[p] += f64(qpc() - the_app.phase_clock.started[p]) * 1000 / the_app.phase_clock.freq
	// the phase that was running underneath (if any) resumes
	switch p {
	case .Styles, .Layout, .Paint_Items: the_app.phase_clock.cur = .UI_Draw
	case .Tex_Create, .Tex_Upload: the_app.phase_clock.cur = .Paint_Items
	case .Frame, .Idle: the_app.phase_clock.cur = .None
	case .None, .Wait, .Events, .Loop, .Input, .Build_UI, .UI_Draw, .Submit, .Present, .Animation: the_app.phase_clock.cur = .Frame
	}
}

prof_frame_begin :: proc() {
	prof_mark(.First_Frame)
	trace.end_all()   // (what an early return of the last frame left open)
	the_app.phase_clock.on = hud_wants_clock() || prof_on()
	if !the_app.phase_clock.on { return }
	if the_app.phase_clock.freq == 0 {
		when ODIN_OS == .Windows {
			f: win.LARGE_INTEGER
			win.QueryPerformanceFrequency(&f)
			the_app.phase_clock.freq = f64(f)
		} else {
			the_app.phase_clock.freq = 1e9   // qpc() returns nanoseconds off Windows
		}
	}
	the_app.phase_clock.acc = {}
	prof_begin(.Frame)
}

// After the frame's present: the profiler records it, the status bar and the title take their sample.
prof_frame_end :: proc(app: ^App, items, elements: int) {
	prof_mark(.First_Present)
	trace.frame()
	trace.plot("layout items", f64(items))
	latency_probe_presented(app)   // shell_latency.odin
	if items > 0 { prof_mark(.First_Page_Paint) }
	if app.phase_clock.on {
		prof_end(.Frame)
		prof_record(app, items, elements)
	}
	gpu_steps_frame(app)
	hud_frame_end(app)
}

Frame_Rec :: struct {
	t_ms:   f32,
	budget: f32,       // the frame budget when it was made (pacing.odin)
	dur:    [Phase]f32,
	gpu_ms: f32,
	gpu_index: int,   // the renderer's index of the timed submit of this frame (-1: none)
	items, insts, batches, elements: i32,
	ui_boxes:  i32,    // boxes of the chrome's UI tree built this frame (ui.boxes_built)
	// the layout pass of this frame, if any: its kind and its steps (lay.Layout.stats: box tree, layout, finishing,
	// display list, spatial index), and the paragraphs laid out ahead on the layout threads / taken
	lay_pass:  lay.Pass_Kind,
	lay_steps: [5]f32,
	lay_pre:   [2]i32,
	lay_why:   string,   // why a full pass was not incremental (a literal of package layout)
	gpu_steps: Gpu_Steps_Frame,   // GPU time by step (gpu_steps.odin), when profiled
}

// Moments of the start-up, in ms since the process was created (prof_mark).
Startup_Mark :: enum u8 {
	Main, Prefs, Window, Shell, Navigation, Renderer, UI_Fonts, Loop, First_Frame, First_Present, First_Page_Paint,
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

SAMPLE_DEPTH :: 24
SAMPLE_PERIOD_NS :: 1_000_000
SAMPLE_WALK_MOST :: 160   // frames walked for the SAMPLE_DEPTH ones in the executable
Sample :: struct { rip: u64, phase: Phase, t: i64, from: [SAMPLE_DEPTH]u64 }   // from: the callers inside the executable, innermost first (WREN_SAMPLE_STACK=1)

// A sample of one of the process's other threads (WREN_SAMPLE_THREADS=1): where it was, and who called (the executable's frames).
Osample :: struct { tid: u32, rip: u64, from: [SAMPLE_DEPTH]u64 }


Prof :: struct {
	on:        bool,
	freq:      f64,
	t0:        i64,
	frames:    [dynamic]Frame_Rec,
	out:       string,
	gpu_next:  int,               // the renderer's timed-submit counter at the start of the frame
	// sampling
	sampling:  bool,
	samples:   []Sample,
	n_samples: int,
	stop:      bool,
	target:    win.HANDLE,
	clock:     ^Phase_Clock,   // the App's (App.phase_clock): the sampler reads its phase from its own thread
	sampler:   ^thread.Thread,
	stacks:    bool,             // the sampler also unwinds the stack (WREN_SAMPLE_STACK=1)
	osamples:  []Osample,        // the other threads, one at a time in turn (WREN_SAMPLE_THREADS=1)
	n_osamples: int,
	names:     map[u32]string,    // the other threads' names, by id (the sampler's)
	osampler:  ^thread.Thread,
	main_tid:  u32,
	exe_lo, exe_hi: u64,
	cpu0_user, cpu0_kernel: u64,
	wall0:     i64,
	cur_lay:   Frame_Rec,         // the layout pass of the frame being measured (lay_* fields)
	shown:     [dynamic]Shown_Rec,   // frames the swap chain reported on screen
	dtwin:     [dynamic]Window_Rec,  // frames of the developer tools' own window (devtools_window.odin)
}

Shown_Rec :: struct { t_ms, latency_ms: f32, missed: u32 }

// A frame of the developer tools' window: when it ended, how long it took in all, and how much of that was its present.
Window_Rec :: struct { t_ms, dur_ms, present_ms: f32 }

prof_window_frame :: proc(start, present_start: i64) {
	if !prof.on { return }
	now := qpc()
	append(&prof.dtwin, Window_Rec{t_ms = f32(f64(now - prof.t0) * 1000 / prof.freq), dur_ms = f32(f64(now - start) * 1000 / prof.freq), present_ms = f32(f64(now - present_start) * 1000 / prof.freq)})
}

// A frame on screen (hud_displayed): input latency (< 0: none) and missed refreshes, for the report.
prof_displayed :: proc(d: render.Displayed_Frame, latency_ms: f32) {
	if !prof.on { return }
	append(&prof.shown, Shown_Rec{t_ms = f32(f64(qpc() - prof.t0) * 1000 / prof.freq), latency_ms = latency_ms, missed = d.missed})
}

prof: Prof

prof_on :: proc() -> bool { return prof.on }

// QPC of each start-up moment (0: not reached). Recorded from the first line of main, before prof_init.
startup_marks: [Startup_Mark]i64

prof_mark :: proc(m: Startup_Mark) {
	if startup_marks[m] != 0 { return }
	startup_marks[m] = qpc()
	when trace.ON { trace.mark(fmt.tprint(m)) }
}

// The layout pass just run (after layout_document).
prof_layout :: proc(l: ^lay.Layout) {
	hud_layout(l)
	if !prof.on { return }
	// (a frame may run two: the one a read forced, then its own: the longer one is kept)
	sum :: proc(steps: [5]f32) -> (t: f32) { for s in steps { t += s }; return }
	if sum(l.stats) < sum(prof.cur_lay.lay_steps) { return }
	prof.cur_lay.lay_pass = l.last_pass
	prof.cur_lay.lay_steps = l.stats
	prof.cur_lay.lay_pre = {i32(l.pre_counts[0]), i32(l.pre_counts[1])}
	prof.cur_lay.lay_why = l.inc.fallback
}

filetime_u64 :: proc(ft: win.FILETIME) -> u64 { return u64(ft.dwHighDateTime) << 32 | u64(ft.dwLowDateTime) }

process_cpu :: proc() -> (user, kernel: u64) {
	c, e, k, u: win.FILETIME
	win.GetProcessTimes(win.GetCurrentProcess(), &c, &e, &k, &u)
	return filetime_u64(u), filetime_u64(k)   // 100 ns units
}

prof_init :: proc(app: ^App) {
	if prof.on { return }   // (the process's profiler: the first App's thread, WREN_PROF is for a process of one App)
	out := os.get_env("WREN_PROF", context.allocator)
	if out == "" { return }
	prof.on, prof.out = true, out
	f: win.LARGE_INTEGER
	win.QueryPerformanceFrequency(&f)
	prof.freq = f64(f)
	prof.t0 = qpc()
	prof.frames = make([dynamic]Frame_Rec, 0, 1 << 16)
	prof.cpu0_user, prof.cpu0_kernel = process_cpu()
	prof.wall0 = prof.t0

	if os.get_env("WREN_SAMPLE", context.temp_allocator) == "1" {
		win.timeBeginPeriod(1)
		h: win.HANDLE
		win.DuplicateHandle(win.GetCurrentProcess(), win.GetCurrentThread(), win.GetCurrentProcess(), &h, 0, false, win.DUPLICATE_SAME_ACCESS)
		prof.target = h
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
}

// The return addresses that lie in the executable (the system's frames between are skipped; the unwind uses the unwind tables the system knows, JIT code's
// included). In the copy made while the thread was stopped, once it runs again (crashtrace.Stack_Copy: a walk in place ended the browser on cnn.com, code without tables
// sends it through nonsense, and the lookup of the tables takes a lock the stopped thread may hold).
callers_in_exe :: proc(stack: ^crashtrace.Stack_Copy, ctx: ^win.CONTEXT) -> (out: [SAMPLE_DEPTH]u64) {
	pcs: [SAMPLE_WALK_MOST]u64
	n := 0
	for pc in pcs[:crashtrace.stack_walk(stack, ctx, pcs[:])] {
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
	stack: crashtrace.Stack_Copy
	if prof.stacks { crashtrace.stack_copy_init(&stack) }
	defer crashtrace.stack_copy_destroy(&stack)
	for !sync.atomic_load(&prof.stop) {
		sample_tick(timer)
		if win.SuspendThread(prof.target) == ~u32(0) { continue }
		ctx: win.CONTEXT
		ctx.ContextFlags = prof.stacks ? CONTEXT_FULL_AMD64 : CONTEXT_CONTROL_AMD64
		got := win.GetThreadContext(prof.target, &ctx)
		if got && prof.stacks { crashtrace.stack_copy_take(&stack, ctx.Rsp) }
		phase := prof.clock.cur
		win.ResumeThread(prof.target)
		if got && prof.n_samples < len(prof.samples) {
			sm := Sample{u64(ctx.Rip), phase, qpc(), {}}
			if prof.stacks { sm.from = callers_in_exe(&stack, &ctx) }
			prof.samples[prof.n_samples] = sm
			prof.n_samples += 1
		}
	}
}

// One frame into the record (prof_frame_end). GPU times arrive a few frames late: each goes to the frame whose
// timed submit it measured.
prof_record :: proc(app: ^App, items, elements: int) {
	if !prof.on { return }
	rec := Frame_Rec{t_ms = f32(f64(qpc() - prof.t0) * 1000 / prof.freq), gpu_index = -1, budget = frame_budget_ms(app)}
	rec.lay_pass, rec.lay_steps, rec.lay_pre, rec.lay_why = prof.cur_lay.lay_pass, prof.cur_lay.lay_steps, prof.cur_lay.lay_pre, prof.cur_lay.lay_why
	prof.cur_lay = {}
	for p in Phase { rec.dur[p] = f32(app.phase_clock.acc[p]) }
	rec.items, rec.elements = i32(items), i32(elements)
	rec.insts, rec.batches = i32(len(app.dc.insts)), i32(len(app.dc.batches))
	rec.ui_boxes = i32(ui.boxes_built(active_window(app).ui))
	if n := render.gpu_next_frame(&app.r); n > prof.gpu_next { rec.gpu_index = n - 1 }
	prof.gpu_next = render.gpu_next_frame(&app.r)
	append(&prof.frames, rec)
	if ms, index, ok := render.gpu_result(&app.r); ok {
		for k := len(prof.frames) - 1; k >= max(0, len(prof.frames) - 16); k -= 1 {
			if prof.frames[k].gpu_index == index { prof.frames[k].gpu_ms = ms; break }
		}
	}
	gpu_steps_attach(app, prof.frames[:])
}

////////////////////////////////
// Report

Stat :: struct { n: int, mean, p50, p95, p99, max, sum: f64 }

stat_of :: proc(v: []f64) -> Stat {
	if len(v) == 0 { return {} }
	s := slice.clone(v, context.temp_allocator)
	slice.sort(s)
	st := Stat{n = len(s), max = s[len(s) - 1]}
	for x in s { st.sum += x }
	st.mean = st.sum / f64(len(s))
	st.p50, st.p95, st.p99 = s[len(s) / 2], s[min(len(s) - 1, len(s) * 95 / 100)], s[min(len(s) - 1, len(s) * 99 / 100)]
	return st
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
	stack: crashtrace.Stack_Copy
	crashtrace.stack_copy_init(&stack)
	defer crashtrace.stack_copy_destroy(&stack)
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
other_sample :: proc(tid: u32, handles: ^map[u32]win.HANDLE, stack: ^crashtrace.Stack_Copy) -> bool {
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
	if got { crashtrace.stack_copy_take(stack, ctx.Rsp) }
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
prof_report :: proc(app: ^App) {
	if !prof.on { return }
	latency_probe_report()   // shell_latency.odin
	sync.atomic_store(&prof.stop, true)
	if prof.sampler != nil { thread.join(prof.sampler) }
	if prof.osampler != nil { thread.join(prof.osampler) }
	wall := f64(qpc() - prof.wall0) / prof.freq
	u, k := process_cpu()
	cpu_user, cpu_kernel := f64(u - prof.cpu0_user) / 1e7, f64(k - prof.cpu0_kernel) / 1e7

	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "wall %.2f s | cpu user %.2f s + kernel %.2f s = %.1f %% of one core | frames %d (%.1f/s)\n\n", wall, cpu_user, cpu_kernel, (cpu_user + cpu_kernel) / wall * 100, len(prof.frames), f64(len(prof.frames)) / wall)

	ds := images.decoder_stats()
	fmt.sbprintf(&sb, "image decoder threads: %d jobs, %d failed, %.1f ms busy (all threads), longest job %.1f ms\n", ds.jobs, ds.failed, ds.busy_ms, ds.longest_ms)
	report_pacing(app, &sb)
	fmt.sbprintf(&sb, "%-12s %7s %8s %8s %8s %8s %9s\n", "phase (ms)", "n", "mean", "p50", "p95", "p99", "max")
	for p in Phase {
		if p == .None || p == .Idle { continue }
		v := make([dynamic]f64, context.temp_allocator)
		for f in prof.frames { if f.dur[p] > 0 { append(&v, f64(f.dur[p])) } }
		s := stat_of(v[:])
		fmt.sbprintf(&sb, "%-12v %7d %8.3f %8.3f %8.3f %8.3f %9.3f\n", p, s.n, s.mean, s.p50, s.p95, s.p99, s.max)
	}
	gv := make([dynamic]f64, context.temp_allocator)
	for f in prof.frames { if f.gpu_ms > 0 { append(&gv, f64(f.gpu_ms)) } }
	gs := stat_of(gv[:])
	fmt.sbprintf(&sb, "%-12s %7d %8.3f %8.3f %8.3f %8.3f %9.3f\n", "GPU draw", gs.n, gs.mean, gs.p50, gs.p95, gs.p99, gs.max)
	gpu_steps_report(app, &sb, prof.frames[:])
	last: Frame_Rec
	if len(prof.frames) > 0 { last = prof.frames[len(prof.frames) - 1] }
	fmt.sbprintf(&sb, "\nlast frame: %d layout items, %d instances, %d batches, %d styled elements\n", last.items, last.insts, last.batches, last.elements)
	report_startup(&sb)
	report_layout_passes(&sb)
	video_shell_report(&sb, prof.freq)
	fmt.sbprintf(&sb, "\n-- %s\n", page.styles_stats_text())
	fmt.sbprintf(&sb, "%s\n", page.styles_stats_why())

	if prof.sampling && prof.n_samples > 0 { report_samples(&sb) }
	if prof.n_osamples > 0 { report_threads(&sb) }

	_ = os.write_entire_file(strings.concatenate({prof.out, ".txt"}, context.temp_allocator), transmute([]byte)strings.to_string(sb))

	csv := strings.builder_make(context.temp_allocator)
	strings.write_string(&csv, "t_ms,budget_ms,gpu_ms,items,insts,batches,elements,ui_boxes")
	for p in Phase { fmt.sbprintf(&csv, ",%v", p) }
	strings.write_string(&csv, ",lay_pass,lay_tree,lay_layout,lay_finish,lay_display,lay_bands,lay_ahead,lay_taken")
	gpu_steps_csv_header(&csv)
	strings.write_byte(&csv, '\n')
	for f in prof.frames {
		fmt.sbprintf(&csv, "%.3f,%.3f,%.3f,%d,%d,%d,%d,%d", f.t_ms, f.budget, f.gpu_ms, f.items, f.insts, f.batches, f.elements, f.ui_boxes)
		for p in Phase { fmt.sbprintf(&csv, ",%.3f", f.dur[p]) }
		fmt.sbprintf(&csv, ",%v", f.lay_pass)
		for s in f.lay_steps { fmt.sbprintf(&csv, ",%.3f", s) }
		fmt.sbprintf(&csv, ",%d,%d", f.lay_pre[0], f.lay_pre[1])
		gpu_steps_csv_row(&csv, f.gpu_steps)
		strings.write_byte(&csv, '\n')
	}
	_ = os.write_entire_file(strings.concatenate({prof.out, ".csv"}, context.temp_allocator), transmute([]byte)strings.to_string(csv))
	// frames on screen (swap chain statistics): <prefix>.shown.csv
	sc := strings.builder_make(context.temp_allocator)
	strings.write_string(&sc, "t_ms,latency_ms,missed\n")
	for s in prof.shown { fmt.sbprintf(&sc, "%.3f,%.3f,%d\n", s.t_ms, s.latency_ms, s.missed) }
	_ = os.write_entire_file(strings.concatenate({prof.out, ".shown.csv"}, context.temp_allocator), transmute([]byte)strings.to_string(sc))
	// frames of the developer tools' window: <prefix>.dtwin.csv
	if len(prof.dtwin) > 0 {
		wc := strings.builder_make(context.temp_allocator)
		strings.write_string(&wc, "t_ms,dur_ms,present_ms\n")
		for w in prof.dtwin { fmt.sbprintf(&wc, "%.3f,%.3f,%.3f\n", w.t_ms, w.dur_ms, w.present_ms) }
		_ = os.write_entire_file(strings.concatenate({prof.out, ".dtwin.csv"}, context.temp_allocator), transmute([]byte)strings.to_string(wc))
	}
}

// Frame pacing: the display, the budget, the frames against it, what reached the screen. CPU work = the frame without its
// wait for the screen and without Present: Present returns at once, except when the compositor has not taken the
// previous frame yet (a frame right after idle time, started between two vblanks): then it blocks until the next vblank,
// which is waiting, not work (the frame shows at the same vblank either way). Present is reported on its own.
report_pacing :: proc(app: ^App, sb: ^strings.Builder) {
	pacer := pacer_of(app)
	d := pacer.display
	budget := f64(frame_budget_ms(app))
	how := pacer.timed ? "timed" : fmt.tprintf("sync interval %d", pacer.interval)
	fmt.sbprintf(sb, "pacing: display %.3f Hz (top mode %.0f Hz%s, %v), target %.3f Hz (%s, %s), budget %.3f ms\n", d.hz, d.max_hz, pacer.variable ? ", variable" : "", d.source, pacer.hz, how, pacer.tearing ? "tearing" : "vsync", budget)
	cpu := make([dynamic]f64, 0, len(prof.frames), context.temp_allocator)
	gpu := make([dynamic]f64, 0, len(prof.frames), context.temp_allocator)
	pres := make([dynamic]f64, 0, len(prof.frames), context.temp_allocator)
	over, gover := 0, 0
	for f in prof.frames {
		w := f64(f.dur[.Frame] - f.dur[.Wait] - f.dur[.Present])
		append(&cpu, w)
		append(&pres, f64(f.dur[.Present]))
		if w > f64(f.budget) { over += 1 }
		if f.gpu_ms > 0 { append(&gpu, f64(f.gpu_ms)); if f.gpu_ms > f.budget { gover += 1 } }
	}
	cs, gs, ps := stat_of(cpu[:]), stat_of(gpu[:]), stat_of(pres[:])
	fmt.sbprintf(sb, "  CPU work  n %d  mean %.3f  p50 %.3f  p95 %.3f  p99 %.3f  max %.3f ms | over budget %d (%.2f %%)\n", cs.n, cs.mean, cs.p50, cs.p95, cs.p99, cs.max, over, f64(over) * 100 / f64(max(cs.n, 1)))
	fmt.sbprintf(sb, "  Present   p50 %.3f  p95 %.3f  p99 %.3f  max %.3f ms\n", ps.p50, ps.p95, ps.p99, ps.max)
	fmt.sbprintf(sb, "  GPU draw  n %d  mean %.3f  p50 %.3f  p95 %.3f  p99 %.3f  max %.3f ms | over budget %d (%.2f %%)\n", gs.n, gs.mean, gs.p50, gs.p95, gs.p99, gs.max, gover, f64(gover) * 100 / f64(max(gs.n, 1)))
	lat := make([dynamic]f64, 0, len(prof.shown), context.temp_allocator)
	missed := 0
	for s in prof.shown {
		missed += int(s.missed)
		if s.latency_ms >= 0 { append(&lat, f64(s.latency_ms)) }
	}
	ls := stat_of(lat[:])
	fmt.sbprintf(sb, "  on screen %d, missed refreshes %d | input -> screen n %d  mean %.2f  p50 %.2f  p95 %.2f  max %.2f ms | measured %.3f Hz\n\n", len(prof.shown), missed, ls.n, ls.mean, ls.p50, ls.p95, ls.max, render.measured_refresh_hz(&app.r))
}

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

// Layout passes by kind: how many, and their steps (ms).
report_layout_passes :: proc(sb: ^strings.Builder) {
	STEPS :: [5]string{"tree", "layout", "finish", "display", "bands"}
	steps := STEPS
	fmt.sbprintf(sb, "\n-- layout passes (ms): %-8s %7s %8s %8s %8s\n", "step", "n", "p50", "mean", "max")
	for kind in lay.Pass_Kind {
		if kind == .None { continue }
		n := 0
		for f in prof.frames { if f.lay_pass == kind { n += 1 } }
		if n == 0 { continue }
		for name, si in steps {
			v := make([dynamic]f64, context.temp_allocator)
			for f in prof.frames { if f.lay_pass == kind { append(&v, f64(f.lay_steps[si])) } }
			s := stat_of(v[:])
			fmt.sbprintf(sb, "  %-11v %-8s %7d %8.3f %8.3f %8.3f\n", kind, name, s.n, s.p50, s.mean, s.max)
		}
	}
	// every full pass, with the paragraphs laid out ahead on the layout threads
	shown := 0
	for f in prof.frames {
		if f.lay_pass != .Full || shown >= 20 { continue }
		shown += 1
		total: f32
		for s in f.lay_steps { total += s }
		fmt.sbprintf(sb, "  full pass at %8.1f ms: %7.2f ms = tree %.2f + layout %.2f + finish %.2f + display %.2f + bands %.2f; paragraphs ahead %d, taken %d%s\n",
			f.t_ms, total, f.lay_steps[0], f.lay_steps[1], f.lay_steps[2], f.lay_steps[3], f.lay_steps[4], f.lay_pre[0], f.lay_pre[1], f.lay_why != "" ? fmt.tprintf(" (not incremental: %s)", f.lay_why) : "")
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

} else {

prof_init :: proc(app: ^App) {}
prof_displayed :: proc(d: render.Displayed_Frame, latency_ms: f32) {}
prof_window_frame :: proc(start, present_start: i64) {}
prof_mark :: proc(m: Startup_Mark) {}
prof_layout :: proc(l: ^lay.Layout) { hud_layout(l) }
prof_record :: proc(app: ^App, items, elements: int) {}
prof_on :: proc() -> bool { return false }
prof_report :: proc(app: ^App) {}

}
