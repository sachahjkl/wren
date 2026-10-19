#+vet !unused-imports
package browser

// Measurement tools, compiled in only with -define:PROFILE=true (build.bat profile -> build\browser_prof.exe). A normal build
// contains none of this: every entry point below is an empty procedure when PROFILE is false.
//
// What it records, at run time, when the environment variable WREN_PROF names an output prefix:
//   * wall time of each phase of every frame (QueryPerformanceCounter), written as <prefix>.csv;
//   * GPU time of the frame's draw commands (D3D11 timestamp queries, read back a few frames later);
//   * with WREN_SAMPLE=1, a sampling profiler: a thread that every millisecond suspends the UI thread, reads its instruction
//     pointer and attributes it to the phase being measured; symbols come from the PDB (our code) and from DLL exports
//     (system, graphics driver). Written to <prefix>.txt together with the per-phase statistics and the process CPU time.

PROFILE :: #config(PROFILE, false)

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import lay "wb:layout"

foreign import dbghelp "system:dbghelp.lib"
foreign import kernel32_prof "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32_prof {
	GetModuleHandleExW :: proc(flags: u32, address: rawptr, out: ^win.HMODULE) -> win.BOOL ---
}

CONTEXT_CONTROL_AMD64 :: 0x100001

Phase :: enum u8 {
	None, Idle, Frame, Wait, Events, Loop, Input, Build_UI, UI_Draw, Styles, Layout, Paint_Items, Submit, Present,
}

Frame_Rec :: struct {
	t_ms:   f32,
	dur:    [Phase]f32,
	gpu_ms: f32,
	items, insts, batches, elements: i32,
	// the layout pass of this frame, if any: its kind and its steps (lay.Layout.stats: box tree, layout, finishing,
	// display list, spatial index), and the paragraphs laid out ahead on the layout threads / taken
	lay_pass:  lay.Pass_Kind,
	lay_steps: [5]f32,
	lay_pre:   [2]i32,
}

// Moments of the start-up, in ms since the process was created (prof_mark).
Startup_Mark :: enum u8 {
	Main, Prefs, Window, Shell, Navigation, Renderer, UI_Fonts, Loop, First_Frame, First_Present, First_Page_Paint,
}

when PROFILE {

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
}

Sample :: struct { rip: u64, phase: Phase }

GPU_SLOTS :: 6

Prof :: struct {
	on:        bool,
	freq:      f64,
	t0:        i64,
	started:   [Phase]i64,
	acc:       [Phase]f64,
	frames:    [dynamic]Frame_Rec,
	out:       string,
	// GPU
	q_disjoint, q_begin, q_end: [GPU_SLOTS]^d3d11.IQuery,
	q_issued:  [GPU_SLOTS]bool,
	q_frame:   [GPU_SLOTS]int,    // index in `frames` the slot belongs to
	q_slot:    int,
	// sampling
	sampling:  bool,
	samples:   []Sample,
	n_samples: int,
	stop:      bool,
	target:    win.HANDLE,
	sampler:   ^thread.Thread,
	cur_phase: Phase,
	cpu0_user, cpu0_kernel: u64,
	wall0:     i64,
	cur_lay:   Frame_Rec,         // the layout pass of the frame being measured (lay_* fields)
}

prof: Prof

// QPC of each start-up moment (0: not reached). Recorded from the first line of main, before prof_init.
startup_marks: [Startup_Mark]i64

prof_mark :: proc(m: Startup_Mark) {
	if startup_marks[m] == 0 { startup_marks[m] = qpc() }
}

// The layout pass just run (after layout_document).
prof_layout :: proc(l: ^lay.Layout) {
	if !prof.on { return }
	prof.cur_lay.lay_pass = l.last_pass
	prof.cur_lay.lay_steps = l.stats
	prof.cur_lay.lay_pre = {i32(l.pre_counts[0]), i32(l.pre_counts[1])}
}

qpc :: proc() -> i64 {
	v: win.LARGE_INTEGER
	win.QueryPerformanceCounter(&v)
	return i64(v)
}

filetime_u64 :: proc(ft: win.FILETIME) -> u64 { return u64(ft.dwHighDateTime) << 32 | u64(ft.dwLowDateTime) }

process_cpu :: proc() -> (user, kernel: u64) {
	c, e, k, u: win.FILETIME
	win.GetProcessTimes(win.GetCurrentProcess(), &c, &e, &k, &u)
	return filetime_u64(u), filetime_u64(k)   // 100 ns units
}

prof_init :: proc(app: ^App) {
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

	for i in 0 ..< GPU_SLOTS {
		app.r.device->CreateQuery(&{Query = .TIMESTAMP_DISJOINT}, &prof.q_disjoint[i])
		app.r.device->CreateQuery(&{Query = .TIMESTAMP}, &prof.q_begin[i])
		app.r.device->CreateQuery(&{Query = .TIMESTAMP}, &prof.q_end[i])
	}

	if os.get_env("WREN_SAMPLE", context.temp_allocator) == "1" {
		win.timeBeginPeriod(1)
		h: win.HANDLE
		win.DuplicateHandle(win.GetCurrentProcess(), win.GetCurrentThread(), win.GetCurrentProcess(), &h, 0, false, win.DUPLICATE_SAME_ACCESS)
		prof.target = h
		prof.samples = make([]Sample, 4_000_000)
		prof.sampling = true
		prof.sampler = thread.create(sampler_proc)
		thread.start(prof.sampler)
	}
}

sampler_proc :: proc(_: ^thread.Thread) {
	for !sync.atomic_load(&prof.stop) {
		win.Sleep(1)
		if win.SuspendThread(prof.target) == ~u32(0) { continue }
		ctx: win.CONTEXT
		ctx.ContextFlags = CONTEXT_CONTROL_AMD64
		if win.GetThreadContext(prof.target, &ctx) && prof.n_samples < len(prof.samples) {
			prof.samples[prof.n_samples] = Sample{u64(ctx.Rip), prof.cur_phase}
			prof.n_samples += 1
		}
		win.ResumeThread(prof.target)
	}
}

prof_begin :: proc(p: Phase) {
	if !prof.on { return }
	prof.started[p] = qpc()
	prof.cur_phase = p
}

prof_end :: proc(p: Phase) {
	if !prof.on { return }
	prof.acc[p] += f64(qpc() - prof.started[p]) * 1000 / prof.freq
	// the phase that was running underneath (if any) resumes
	switch p {
	case .Styles, .Layout, .Paint_Items: prof.cur_phase = .UI_Draw
	case .Frame, .Idle: prof.cur_phase = .None
	case .None, .Wait, .Events, .Loop, .Input, .Build_UI, .UI_Draw, .Submit, .Present: prof.cur_phase = .Frame
	}
}

prof_frame_begin :: proc() {
	prof_mark(.First_Frame)
	if !prof.on { return }
	prof.acc = {}
	prof.cur_lay = {}
	prof_begin(.Frame)
}

prof_gpu_begin :: proc(app: ^App) {
	if !prof.on { return }
	s := prof.q_slot % GPU_SLOTS
	if prof.q_issued[s] { return }   // the previous use of this slot has not been read back yet: skip this frame
	app.r.ctx->Begin((^d3d11.IAsynchronous)(prof.q_disjoint[s]))
	app.r.ctx->End((^d3d11.IAsynchronous)(prof.q_begin[s]))
}

prof_gpu_end :: proc(app: ^App) {
	if !prof.on { return }
	s := prof.q_slot % GPU_SLOTS
	if prof.q_issued[s] { prof.q_slot += 1; return }
	app.r.ctx->End((^d3d11.IAsynchronous)(prof.q_end[s]))
	app.r.ctx->End((^d3d11.IAsynchronous)(prof.q_disjoint[s]))
	prof.q_issued[s] = true
	prof.q_frame[s] = len(prof.frames)
	prof.q_slot += 1
}

prof_gpu_collect :: proc(app: ^App) {
	if !prof.on { return }
	for s in 0 ..< GPU_SLOTS {
		if !prof.q_issued[s] { continue }
		dj: d3d11.QUERY_DATA_TIMESTAMP_DISJOINT
		if app.r.ctx->GetData((^d3d11.IAsynchronous)(prof.q_disjoint[s]), &dj, size_of(dj), {}) != 0 { continue }
		t0, t1: u64
		app.r.ctx->GetData((^d3d11.IAsynchronous)(prof.q_begin[s]), &t0, size_of(t0), {})
		app.r.ctx->GetData((^d3d11.IAsynchronous)(prof.q_end[s]), &t1, size_of(t1), {})
		prof.q_issued[s] = false
		idx := prof.q_frame[s]
		if !bool(dj.Disjoint) && dj.Frequency > 0 && idx < len(prof.frames) {
			prof.frames[idx].gpu_ms = f32(f64(t1 - t0) * 1000 / f64(dj.Frequency))
		}
	}
}

prof_frame_end :: proc(app: ^App, items, elements: int) {
	prof_mark(.First_Present)
	if items > 0 { prof_mark(.First_Page_Paint) }
	if !prof.on { return }
	prof_end(.Frame)
	rec := Frame_Rec{t_ms = f32(f64(qpc() - prof.t0) * 1000 / prof.freq)}
	rec.lay_pass, rec.lay_steps, rec.lay_pre = prof.cur_lay.lay_pass, prof.cur_lay.lay_steps, prof.cur_lay.lay_pre
	prof.cur_lay = {}
	for p in Phase { rec.dur[p] = f32(prof.acc[p]) }
	rec.items, rec.elements = i32(items), i32(elements)
	rec.insts, rec.batches = i32(len(app.dc.insts)), i32(len(app.dc.batches))
	append(&prof.frames, rec)
	prof_gpu_collect(app)
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

prof_report :: proc() {
	if !prof.on { return }
	sync.atomic_store(&prof.stop, true)
	if prof.sampler != nil { thread.join(prof.sampler) }
	wall := f64(qpc() - prof.wall0) / prof.freq
	u, k := process_cpu()
	cpu_user, cpu_kernel := f64(u - prof.cpu0_user) / 1e7, f64(k - prof.cpu0_kernel) / 1e7

	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "wall %.2f s | cpu user %.2f s + kernel %.2f s = %.1f %% of one core | frames %d (%.1f/s)\n\n", wall, cpu_user, cpu_kernel, (cpu_user + cpu_kernel) / wall * 100, len(prof.frames), f64(len(prof.frames)) / wall)

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
	last: Frame_Rec
	if len(prof.frames) > 0 { last = prof.frames[len(prof.frames) - 1] }
	fmt.sbprintf(&sb, "\nlast frame: %d layout items, %d instances, %d batches, %d styled elements\n", last.items, last.insts, last.batches, last.elements)
	report_startup(&sb)
	report_layout_passes(&sb)

	if prof.sampling && prof.n_samples > 0 { report_samples(&sb) }

	_ = os.write_entire_file(strings.concatenate({prof.out, ".txt"}, context.temp_allocator), transmute([]byte)strings.to_string(sb))

	csv := strings.builder_make(context.temp_allocator)
	strings.write_string(&csv, "t_ms,gpu_ms,items,insts,batches,elements")
	for p in Phase { fmt.sbprintf(&csv, ",%v", p) }
	strings.write_string(&csv, ",lay_pass,lay_tree,lay_layout,lay_finish,lay_display,lay_bands,lay_ahead,lay_taken")
	strings.write_byte(&csv, '\n')
	for f in prof.frames {
		fmt.sbprintf(&csv, "%.3f,%.3f,%d,%d,%d,%d", f.t_ms, f.gpu_ms, f.items, f.insts, f.batches, f.elements)
		for p in Phase { fmt.sbprintf(&csv, ",%.3f", f.dur[p]) }
		fmt.sbprintf(&csv, ",%v", f.lay_pass)
		for s in f.lay_steps { fmt.sbprintf(&csv, ",%.3f", s) }
		fmt.sbprintf(&csv, ",%d,%d", f.lay_pre[0], f.lay_pre[1])
		strings.write_byte(&csv, '\n')
	}
	_ = os.write_entire_file(strings.concatenate({prof.out, ".csv"}, context.temp_allocator), transmute([]byte)strings.to_string(csv))
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
		fmt.sbprintf(sb, "  full pass at %8.1f ms: %7.2f ms = tree %.2f + layout %.2f + finish %.2f + display %.2f + bands %.2f; paragraphs ahead %d, taken %d\n",
			f.t_ms, total, f.lay_steps[0], f.lay_steps[1], f.lay_steps[2], f.lay_steps[3], f.lay_steps[4], f.lay_pre[0], f.lay_pre[1])
	}
}

report_samples :: proc(sb: ^strings.Builder) {
	proc_h := win.GetCurrentProcess()
	SymSetOptions(0x2 | 0x4)   // undecorate, defer loads
	SymInitialize(proc_h, ".;build", true)

	// resolve each distinct address once
	Sym :: struct { name, module: string }
	cache := make(map[u64]Sym, context.temp_allocator)
	buf: [768]u8
	resolve :: proc(addr: u64, proc_h: win.HANDLE, buf: []u8) -> Sym {
		info := (^SYMBOL_INFO)(raw_data(buf))
		info^ = {}
		info.SizeOfStruct = size_of(SYMBOL_INFO)
		info.MaxNameLen = u32(len(buf) - size_of(SYMBOL_INFO))
		disp: u64
		mod := module_of(addr)
		if SymFromAddr(proc_h, addr, &disp, info) {
			name := strings.clone(string(cstring(&info.Name[0])), context.temp_allocator)
			return {name, mod}
		}
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
}

} else {

prof_init :: proc(app: ^App) {}
prof_mark :: proc(m: Startup_Mark) {}
prof_layout :: proc(l: ^lay.Layout) {}
prof_begin :: proc(p: Phase) {}
prof_end :: proc(p: Phase) {}
prof_frame_begin :: proc() {}
prof_frame_end :: proc(app: ^App, items, elements: int) {}
prof_gpu_begin :: proc(app: ^App) {}
prof_gpu_end :: proc(app: ^App) {}
prof_report :: proc() {}

}
