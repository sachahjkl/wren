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

// The clock (qpc, qpc_frequency), the sampler and the symbols are the system's: prof_windows.odin, prof_other.odin.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:images"
import lay "wb:layout"
import "wb:page"
import "wb:trace"

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

// qpc() is a monotonic counter for the phase timing; qpc_frequency() is its ticks per second (the system's files).

// Milliseconds elapsed since a qpc() tick, always available (its own frequency: the profiler clock may be off). Used by
// the Long Animation Frames timing (page_frame.odin) to measure style and layout wall time regardless of profiling.
@(private)
qpc_freq_cached: f64

qpc_ms_since :: proc "contextless" (t0: i64) -> f64 {
	if qpc_freq_cached == 0 { qpc_freq_cached = qpc_frequency() }
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
	if the_app.phase_clock.freq == 0 { the_app.phase_clock.freq = qpc_frequency() }
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

prof_init :: proc(app: ^App) {
	if prof.on { return }   // (the process's profiler: the first App's thread, WREN_PROF is for a process of one App)
	out := os.get_env("WREN_PROF", context.allocator)
	if out == "" { return }
	prof.on, prof.out = true, out
	prof.freq = qpc_frequency()
	prof.t0 = qpc()
	prof.frames = make([dynamic]Frame_Rec, 0, 1 << 16)
	prof.cpu0_user, prof.cpu0_kernel = process_cpu()
	prof.wall0 = prof.t0

	if os.get_env("WREN_SAMPLE", context.temp_allocator) == "1" { prof_sampling_start(app) }   // (the system's file: a sampler where there is one)
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
