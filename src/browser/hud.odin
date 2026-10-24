package browser

// Frame statistics for the status bar and the window title ("heads-up display").
//
// Each frame (prof_frame_end) becomes one sample: the wall time of its phases, stacked in the status bar's graph
// (tasks, styles, layout, paint, UI, submit; the GPU time of its draw commands arrives a few frames later), plus what
// the style, layout, compositor and Wasm steps did (Frame_Detail, for the detail panel). Numbers shown as text (frames
// per second, CPU and GPU milliseconds, memory) are refreshed every browser.status_bar.refresh_ms, the window title every
// browser.title.interval_ms: both only when frames happen. When frames stop, one wake after
// browser.status_bar.rate_window_ms brings the numbers to rest (0 frames per second) instead of leaving the last burst's.
//
// Nothing is measured when nothing shows it: with the status bar hidden and no statistics in the title, the phase
// clock, the GPU timestamp queries and the Wasm call clock are off.

import "core:fmt"
import "core:math"
import "core:strings"
import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:config"
import lay "wb:layout"
import "wb:style"
import "wb:wasm"
import "wb:base"

HUD_PREFS := [?]config.Def{
	{name = "browser.status_bar.visible", kind = .Bool, default = {b = true},
		description = "Show the status bar at the bottom of the window (Ctrl+B): the page's state on the left, the frame graph and counters on the right."},
	{name = "browser.status_bar.items", kind = .String, default = {s = "state,size,origin,requests,cookies,nodes,modules,zoom"},
		description = "What the left side of the status bar shows, in order, comma separated: state (loading, HTTP status), size (of the document), origin, requests (in progress), cookies, nodes (DOM), modules (WebAssembly), zoom (when not 100 %)."},
	{name = "browser.status_bar.metrics", kind = .String, default = {s = "graph,fps,cpu,gpu,memory"},
		description = "What the right side of the status bar shows, in order, comma separated: graph (time of the recent frames by phase; click it for details), fps (frames per second), cpu (milliseconds of work per frame), gpu (milliseconds of GPU drawing per frame), memory (working set of the process)."},
	{name = "browser.status_bar.link_preview", kind = .Bool, default = {b = true},
		description = "While the pointer is on a link, the left side of the status bar shows where it goes."},
	{name = "browser.status_bar.refresh_ms", kind = .Int, default = {i = 500}, bounded = true, min = 50, max = 10_000, unit = "ms",
		description = "How often the status bar's numbers change (they are averages over browser.status_bar.rate_window_ms). The graph follows every frame."},
	{name = "browser.status_bar.rate_window_ms", kind = .Int, default = {i = 1000}, bounded = true, min = 100, max = 10_000, unit = "ms",
		description = "Frames per second and the average times are counted over this much recent time."},
	{name = "browser.status_bar.graph.samples", kind = .Int, default = {i = 120}, bounded = true, min = 8, max = 1024, unit = "frames",
		description = "Frames shown by the status bar's graph (the most recent at the right)."},
	{name = "browser.status_bar.graph.width_em", kind = .Float, default = {f = 9}, bounded = true, min = 2, max = 80, unit = "em",
		description = "Width of the status bar's graph, in multiples of the interface's font size."},
	{name = "browser.status_bar.graph.budget_ms", kind = .Float, default = {f = 0}, bounded = true, min = 0, max = 1000, unit = "ms",
		description = "The time a frame may take: the dashed line of the graph, and what the panel counts frames over. 0 = the frame period of browser.frame.target_hz (the monitor's refresh rate: 5.56 ms at 180 Hz, 16.7 ms at 60 Hz)."},
	{name = "browser.status_bar.graph.budget_line", kind = .Bool, default = {b = true},
		description = "Draw the budget as a dashed line across the graph."},
	{name = "browser.status_bar.graph.scale_ms", kind = .Float, default = {f = 0}, bounded = true, min = 0, max = 10_000, unit = "ms",
		description = "The top of the graph is at least this much (0: the budget), so short frames stay visible; taller frames raise it (the budget line shows once it fits) up to browser.status_bar.graph.max_scale_ms."},
	{name = "browser.status_bar.graph.max_scale_ms", kind = .Float, default = {f = 100}, bounded = true, min = 0, max = 100_000, unit = "ms",
		description = "The top of the graph is at most this much: longer frames are cut and marked. 0 = no limit."},
	{name = "browser.status_bar.graph.colors", kind = .String, default = {s = ""},
		description = "Colors of the graph's phases, comma separated #rrggbb in this order: tasks, styles, layout, paint, interface, submit, GPU. Empty entries keep the default (from the theme)."},
	{name = "browser.status_bar.warn_ms", kind = .Float, default = {f = 0}, bounded = true, min = 0, max = 10_000, unit = "ms",
		description = "Frames that take longer are marked in the warning color (graph, CPU counter). 0 = browser.status_bar.warn_budgets times the budget."},
	{name = "browser.status_bar.bad_ms", kind = .Float, default = {f = 0}, bounded = true, min = 0, max = 10_000, unit = "ms",
		description = "Frames that take longer are marked in the error color (graph, CPU counter). 0 = browser.status_bar.bad_budgets times the budget."},
	{name = "browser.status_bar.warn_budgets", kind = .Float, default = {f = 1}, bounded = true, min = 0, max = 100,
		description = "Without browser.status_bar.warn_ms: frames over this many budgets are marked in the warning color. 0 = never."},
	{name = "browser.status_bar.bad_budgets", kind = .Float, default = {f = 2}, bounded = true, min = 0, max = 100,
		description = "Without browser.status_bar.bad_ms: frames over this many budgets (a missed refresh, at least) are marked in the error color. 0 = never."},
	{name = "browser.status_bar.gpu_timing", kind = .Bool, default = {b = true},
		description = "Measure the GPU time of each frame (Direct3D timestamp queries, read a few frames later: the browser never waits for them) while the status bar or the title shows it."},
	{name = "browser.status_bar.wasm_timing", kind = .Bool, default = {b = true},
		description = "Measure the time spent in WebAssembly calls on the interface thread (two clock reads per call) while the status bar shows it."},
	{name = "browser.status_bar.decimal_separator", kind = .String, default = {s = "."}, choices = {".", ","},
		description = "Decimal separator of the numbers of the status bar, its panel and the window title."},
	{name = "browser.title.format", kind = .String, default = {s = "{app} {version} · {build} · {engine} · {fps} fps · CPU {cpu} ms · GPU {gpu} ms — {page}"},
		description = "The window title. Fields: {app} {version} {commit} {date} {build} {engine} {toolkit} {fps} {cpu} {gpu} {mem} {page} (the page's title) {url}. A part between separators (\" · \", \" — \", \" | \" or browser.title.separator) whose field has no value is left out (GPU time not measured, no frames yet...)."},
	{name = "browser.title.stats", kind = .Bool, default = {b = true},
		description = "The window title shows the frame statistics fields ({fps} {cpu} {gpu} {mem}). Off: those parts are left out and the title changes only with the page."},
	{name = "browser.title.interval_ms", kind = .Int, default = {i = 500}, bounded = true, min = 100, max = 60_000, unit = "ms",
		description = "Statistics in the title change at most this often (setting the title of a window is not free); the page's title shows at once."},
	{name = "browser.title.separator", kind = .String, default = {s = " · "},
		description = "Separator of browser.title.format's parts, besides \" — \" and \" | \"."},
}

register_hud_prefs :: proc(p: ^config.Prefs) { config.register(p, HUD_PREFS[:]) }

Status_Item :: enum u8 { State, Size, Origin, Requests, Cookies, Nodes, Modules, Zoom }
Status_Metric :: enum u8 { Graph, Fps, Cpu, Gpu, Memory }

// The phases of the graph, bottom first (the GPU time last: it runs alongside the next frames' CPU work).
Hud_Series :: enum u8 { Tasks, Styles, Layout, Paint, UI, Submit, GPU }
CPU_SERIES :: int(Hud_Series.GPU)

HUD_SERIES_NAMES := [Hud_Series]string{
	.Tasks = "Tasks", .Styles = "Styles", .Layout = "Layout", .Paint = "Paint", .UI = "Interface", .Submit = "Submit", .GPU = "GPU",
}
HUD_SERIES_HELP := [Hud_Series]string{
	.Tasks = "input, scripts", .Styles = "recalc", .Layout = "page",
	.Paint = "page, compositor", .UI = "chrome", .Submit = "draw calls", .GPU = "drawing",
}

Hud_Settings :: struct {
	bar_visible:  bool,
	items:        [dynamic]Status_Item,
	metrics:      [dynamic]Status_Metric,
	link_preview: bool,
	refresh_ms:   f64,
	window_ms:    f64,
	samples:      int,
	graph_em:     f32,
	budget, scale, max_scale, warn, bad: f32,   // as set: 0 = from the frame budget (hud_budget, hud_warn, hud_bad)
	budget_line:  bool,
	warn_budgets, bad_budgets: f32,
	colors:       [Hud_Series]Maybe(draw.Color),
	gpu_timing:   bool,
	wasm_timing:  bool,
	comma:        bool,
	title_format: string,   // owned
	title_stats:  bool,
	title_ms:     f64,
	title_sep:    string,   // owned
}

hud_settings_from_prefs :: proc(p: ^config.Prefs) -> (s: Hud_Settings) {
	s.bar_visible = config.bool_of(p, "browser.status_bar.visible")
	for name in strings.split(config.string_of(p, "browser.status_bar.items"), ",", context.temp_allocator) {
		switch strings.trim_space(name) {
		case "state":    append(&s.items, Status_Item.State)
		case "size":     append(&s.items, Status_Item.Size)
		case "origin":   append(&s.items, Status_Item.Origin)
		case "requests": append(&s.items, Status_Item.Requests)
		case "cookies":  append(&s.items, Status_Item.Cookies)
		case "nodes":    append(&s.items, Status_Item.Nodes)
		case "modules":  append(&s.items, Status_Item.Modules)
		case "zoom":     append(&s.items, Status_Item.Zoom)
		}
	}
	for name in strings.split(config.string_of(p, "browser.status_bar.metrics"), ",", context.temp_allocator) {
		switch strings.trim_space(name) {
		case "graph":  append(&s.metrics, Status_Metric.Graph)
		case "fps":    append(&s.metrics, Status_Metric.Fps)
		case "cpu":    append(&s.metrics, Status_Metric.Cpu)
		case "gpu":    append(&s.metrics, Status_Metric.Gpu)
		case "memory": append(&s.metrics, Status_Metric.Memory)
		}
	}
	s.link_preview = config.bool_of(p, "browser.status_bar.link_preview")
	s.refresh_ms = f64(config.int_of(p, "browser.status_bar.refresh_ms"))
	s.window_ms = f64(config.int_of(p, "browser.status_bar.rate_window_ms"))
	s.samples = int(config.int_of(p, "browser.status_bar.graph.samples"))
	s.graph_em = f32(config.float_of(p, "browser.status_bar.graph.width_em"))
	s.budget = f32(config.float_of(p, "browser.status_bar.graph.budget_ms"))
	s.scale = f32(config.float_of(p, "browser.status_bar.graph.scale_ms"))
	s.max_scale = f32(config.float_of(p, "browser.status_bar.graph.max_scale_ms"))
	s.warn = f32(config.float_of(p, "browser.status_bar.warn_ms"))
	s.bad = f32(config.float_of(p, "browser.status_bar.bad_ms"))
	s.budget_line = config.bool_of(p, "browser.status_bar.graph.budget_line")
	s.warn_budgets = f32(config.float_of(p, "browser.status_bar.warn_budgets"))
	s.bad_budgets = f32(config.float_of(p, "browser.status_bar.bad_budgets"))
	for part, i in strings.split(config.string_of(p, "browser.status_bar.graph.colors"), ",", context.temp_allocator) {
		if i >= len(Hud_Series) { break }
		if c, ok := parse_pref_color(part); ok { s.colors[Hud_Series(i)] = c }
	}
	s.gpu_timing = config.bool_of(p, "browser.status_bar.gpu_timing")
	s.wasm_timing = config.bool_of(p, "browser.status_bar.wasm_timing")
	s.comma = config.string_of(p, "browser.status_bar.decimal_separator") == ","
	s.title_format = strings.clone(config.string_of(p, "browser.title.format"))
	s.title_stats = config.bool_of(p, "browser.title.stats")
	s.title_ms = f64(config.int_of(p, "browser.title.interval_ms"))
	s.title_sep = strings.clone(config.string_of(p, "browser.title.separator"))
	return
}

// The frame budget (ms): browser.status_bar.graph.budget_ms, else the frame period (pacing.odin).
hud_budget :: proc() -> f32 { b, _, _ := hud_thresholds(hud.cfg, frame_budget_ms()); return b }

// The warning / error thresholds (ms; 0 = none).
hud_warn :: proc() -> f32 { _, w, _ := hud_thresholds(hud.cfg, frame_budget_ms()); return w }
hud_bad :: proc() -> f32 { _, _, b := hud_thresholds(hud.cfg, frame_budget_ms()); return b }

// Budget and thresholds from the settings: set values win, else the frame period and multiples of the budget.
hud_thresholds :: proc(s: Hud_Settings, period_ms: f32) -> (budget, warn, bad: f32) {
	budget = s.budget > 0 ? s.budget : period_ms
	warn = s.warn > 0 ? s.warn : s.warn_budgets * budget
	bad = s.bad > 0 ? s.bad : s.bad_budgets * budget
	return
}

hud_settings_destroy :: proc(s: ^Hud_Settings) {
	delete(s.items)
	delete(s.metrics)
	delete(s.title_format)
	delete(s.title_sep)
	s^ = {}
}

Restyle_Kind :: enum u8 { None, Partial, Full }

// What one frame did, besides its phase times (the sample with the same serial in hud.history).
Frame_Detail :: struct {
	serial:     u64,
	gpu_index:  int,               // the renderer's timed submit of this frame (-1: none)
	wait_ms:    f32,               // waiting for the swap chain (not work)
	restyle:    Restyle_Kind,
	restyled:   i32,               // elements whose style changed (-1: unknown)
	lay_pass:   lay.Pass_Kind,
	lay_steps:  [5]f32,            // box tree, layout, finishing, display list, spatial index (ms)
	lay_boxes, lay_items: i32,
	lay_pre:    [2]i32,            // paragraphs laid out ahead on the layout threads, and taken
	comp:       Composite_Stats,
	comp_valid: bool,
	wasm_ms:    f32,
	wasm_calls: i32,
}

// The numbers shown as text: refreshed every refresh_ms (and when frames stop).
Hud_Numbers :: struct {
	at_ms:     f64,
	frames:    int,     // frames in the window
	fps:       f32,
	cpu_mean, cpu_p95, cpu_p99, cpu_max: f32,
	gpu_mean, gpu_p95, gpu_p99, gpu_max: f32,
	gpu_n:     int,     // frames of the window with a GPU time
	over:      int,     // frames over the budget (CPU)
	gpu_over:  int,     // frames whose GPU time is over the budget
	budget:    f32,     // the budget the counts are against
	shown:     int,     // frames seen reaching the screen (swap chain statistics)
	missed:    int,     // refreshes frames of continuous runs came late for
	lat_mean, lat_p95, lat_max: f32,   // input -> screen (ms), frames built from input
	lat_n:     int,
	series:    [Hud_Series]f32,   // mean of each phase
	wasm_mean: f32,
	full_restyles, partial_restyles: int,
	passes:    [lay.Pass_Kind]int,
	// memory (Windows: GetProcessMemoryInfo)
	working_set, private_bytes: int,
	mem_valid: bool,
}

Hud :: struct {
	cfg:          Hud_Settings,
	watch:        int,
	history:      ui.Frame_History,   // series = the CPU phases (stats); the GPU time is drawn on top (v[GPU])
	details:      []Frame_Detail,      // indexed by serial % len
	serial:       u64,
	cur:          Frame_Detail,        // the frame being measured
	gpu_seen:     int,                 // renderer's timed-submit counter at the previous frame's end
	gpu_applied:  int,
	wasm_ns, wasm_calls: i64,
	style_page:   rawptr,
	style_pass, style_serial: u64,
	last_frame_ms: f64,
	nums:         Hud_Numbers,
	settle:       win.UINT_PTR,        // wake to bring the numbers to rest after the last frame (Windows thread timer)
	settle_skip:  bool,                // the frames of that wake are not samples
	title_ms:     f64,
	title_text:   string,              // owned: what the window shows
	title_page:   string,              // the tab title it was made with (identity: the tab's own string)
	title_url:    string,
	panel_open:   bool,
	shown:        [dynamic]Shown_Sample,  // frames that reached the screen, oldest first (hud_displayed)
	mono:         font.Font_Id,
	mono_tried:   bool,
}

hud: Hud

HUD_HISTORY_MIN :: 512   // samples kept at least: frames per second are counted on them

// A frame on screen: when we learnt it, its input latency (< 0: built from no input) and the refreshes it missed.
Shown_Sample :: struct { t_ms: f64, latency_ms: f32, missed: u32 }

// A frame the swap chain reports on screen (pacer_end_frame): kept for the numbers of the rate window.
hud_displayed :: proc(d: render.Displayed_Frame) {
	lat: f32 = -1
	if d.input._nsec != 0 && d.shown._nsec > d.input._nsec { lat = f32(f64(d.shown._nsec - d.input._nsec) / 1e6) }
	now := ui.now_ms()
	append(&hud.shown, Shown_Sample{t_ms = now, latency_ms = lat, missed = d.missed})
	// keep the rate window (and a bound)
	keep_from := 0
	for keep_from < len(hud.shown) && (hud.shown[keep_from].t_ms < now - hud.cfg.window_ms - 1000 || len(hud.shown) - keep_from > 8192) { keep_from += 1 }
	if keep_from > 0 { remove_range(&hud.shown, 0, keep_from) }
	prof_displayed(d, lat)
}

hud_init :: proc(app: ^App) {
	hud.cfg = hud_settings_from_prefs(&app.prefs)
	hud_resize(app)
	hud.gpu_applied = -1
	hud.watch = config.watch(&app.prefs, "browser.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		if !strings.has_prefix(name, "browser.status_bar.") && !strings.has_prefix(name, "browser.title.") { return }
		app := (^App)(user)
		hud_settings_destroy(&hud.cfg)
		hud.cfg = hud_settings_from_prefs(p)
		hud_resize(app)
		hud.title_ms, hud.nums.at_ms = 0, 0   // shows the change at the next frame
		app.frames_requested = max(app.frames_requested, 2)
	}, app)
}

@(private = "file")
hud_resize :: proc(app: ^App) {
	n := max(hud.cfg.samples, HUD_HISTORY_MIN)
	if len(hud.history.buf) == 0 {
		ui.history_init(&hud.history, n, CPU_SERIES)
		hud.details = make([]Frame_Detail, n)
	} else if n != ui.history_capacity(&hud.history) {
		ui.history_resize(&hud.history, n)
		old := hud.details
		hud.details = make([]Frame_Detail, n)
		for d in old { if d.serial > 0 { hud.details[d.serial % u64(n)] = d } }
		delete(old)
	}
}

hud_destroy :: proc(app: ^App) {
	if hud.settle != 0 { win.KillTimer(nil, hud.settle) }
	config.unwatch(&app.prefs, hud.watch)
	hud_settings_destroy(&hud.cfg)
	ui.history_destroy(&hud.history)
	delete(hud.details)
	delete(hud.shown)
	delete(hud.title_text)
	hud = {}
}

// Somebody reads the frame's phases: the status bar, or statistics in the title.
hud_wants_clock :: proc() -> bool {
	return hud.cfg.bar_visible || (hud.cfg.title_stats && title_has_stats(hud.cfg.title_format)) || (dev.visible && dev.panel == .Performance)   // (the developer tools' Performance tab reads the frames too)
}

@(private = "file")
hud_wants_gpu :: proc() -> bool {
	if !hud.cfg.gpu_timing { return false }
	if hud.cfg.bar_visible { return true }
	return hud.cfg.title_stats && strings.contains(hud.cfg.title_format, "{gpu}")
}

// The style pass of the frame (after page.styles): full restyle, partial, or nothing new.
hud_styles :: proc(p: rawptr, s: ^style.Styled) {
	if !phase_clock.on || s == nil { return }
	h := &hud
	defer { h.style_page, h.style_pass, h.style_serial = p, s.pass_id, s.serial }
	if p != h.style_page { h.cur.restyle, h.cur.restyled = .None, 0; return }   // another page: nothing to compare with
	switch {
	case s.pass_id != h.style_pass:
		h.cur.restyle = .Full
		n: i32
		for c in s.by_node { if c != nil { n += 1 } }
		h.cur.restyled = n
	case s.serial != h.style_serial:
		h.cur.restyle = .Partial
		h.cur.restyled = -1
		if s.journal.on && s.journal.from <= h.style_serial {
			n: i32
			for i := len(s.journal.entries) - 1; i >= 0 && s.journal.entries[i].serial > h.style_serial; i -= 1 { n += 1 }
			h.cur.restyled = n
		}
	}
}

// The layout pass just run (prof_layout).
hud_layout :: proc(l: ^lay.Layout) {
	if !phase_clock.on { return }
	hud.cur.lay_pass = l.last_pass
	hud.cur.lay_steps = l.stats
	hud.cur.lay_pre = {i32(l.pre_counts[0]), i32(l.pre_counts[1])}
	hud.cur.lay_boxes, hud.cur.lay_items = i32(len(l.boxes)), i32(len(l.items))
}

// The end of a frame (prof_frame_end): its sample, the late GPU time of an earlier one, the numbers and the title.
hud_frame_end :: proc(app: ^App) {
	h := &hud
	now := ui.now_ms()
	if phase_clock.on { hud_sample(app, now) }
	// what to measure from the next frame on
	render.set_gpu_timing(&app.r, hud_wants_gpu() || prof_on())
	wasm.guest_timing(h.cfg.wasm_timing && h.cfg.bar_visible)
	if phase_clock.on && !h.settle_skip && (h.nums.at_ms == 0 || now - h.nums.at_ms >= h.cfg.refresh_ms) { hud_refresh(app, now) }
	hud_title(app, now)
	h.settle_skip = false
}

@(private = "file")
hud_sample :: proc(app: ^App, now: f64) {
	h := &hud
	a := &phase_clock.acc
	d := h.cur
	h.cur = {}
	d.wait_ms = f32(a[.Wait] + a[.Present])
	d.gpu_index = -1
	if n := render.gpu_next_frame(&app.r); n > h.gpu_seen { d.gpu_index = n - 1 }
	h.gpu_seen = render.gpu_next_frame(&app.r)
	ns, calls := wasm.guest_time()
	d.wasm_ms, d.wasm_calls = f32(f64(ns - h.wasm_ns) / 1e6), i32(calls - h.wasm_calls)
	h.wasm_ns, h.wasm_calls = ns, calls
	if t := current_tab(app); t != nil && t.kind == .Web && t.page != nil { d.comp, d.comp_valid = composite_stats, true }

	if !h.settle_skip {
		page_ms := a[.Styles] + a[.Layout] + a[.Paint_Items]
		h.serial += 1
		d.serial = h.serial
		s := ui.history_push(&h.history, now, h.serial)
		s.v[Hud_Series.Tasks] = f32(a[.Events] + a[.Loop] + a[.Input] + a[.Animation])
		s.v[Hud_Series.Styles] = f32(a[.Styles])
		s.v[Hud_Series.Layout] = f32(a[.Layout])
		s.v[Hud_Series.Paint] = f32(a[.Paint_Items])
		s.v[Hud_Series.UI] = f32(a[.Build_UI] + max(a[.UI_Draw] - page_ms, 0))
		// Present is waiting (for the compositor to take the previous frame), not work: like the swap chain wait, not counted
		s.v[Hud_Series.Submit] = f32(a[.Submit])
		h.details[h.serial % u64(len(h.details))] = d
		h.last_frame_ms = now
		hud_arm_settle()
	}
	// a GPU time read back now belongs to a frame a few frames ago
	if ms, index, ok := render.gpu_result(&app.r); ok && index != h.gpu_applied {
		h.gpu_applied = index
		for k in 0 ..< min(16, ui.history_len(&h.history)) {
			s := ui.history_at(&h.history, ui.history_len(&h.history) - 1 - k)
			if hd := &h.details[s.tag % u64(len(h.details))]; hd.serial == s.tag && hd.gpu_index == index {
				s.v[Hud_Series.GPU] = ms
				break
			}
		}
	}
}

// After the last frame of a burst: one wake when the rate window has passed, so the numbers fall to rest. A thread
// timer of Windows, not one of the event loop: its message wakes the loop for exactly one frame (a task of the loop
// asks for more), which the numbers are refreshed for before it is built and which is no sample.
@(private = "file")
hud_arm_settle :: proc() {
	if hud.settle != 0 { return }
	hud.settle = win.SetTimer(nil, 0, u32(hud.cfg.window_ms) + 20, hud_settle_timer)
}

@(private = "file")
hud_settle_timer :: proc "system" (hwnd: win.HWND, msg: win.UINT, id: win.UINT_PTR, ms: win.DWORD) {
	context = base.process_context()
	win.KillTimer(nil, id)
	if id != hud.settle { return }
	hud.settle = 0
	app := the_app
	now := ui.now_ms()
	if idle := now - hud.last_frame_ms; idle < hud.cfg.window_ms {
		hud.settle = win.SetTimer(nil, 0, u32(hud.cfg.window_ms - idle) + 20, hud_settle_timer)
		return
	}
	hud.settle_skip = true   // the frame this wakes is no sample
	app.frames_requested = max(app.frames_requested, 1)   // (a wake without anything to do draws no frame)
	if phase_clock.on { hud_refresh(app, now) }
}

// The numbers of the last `window_ms`.
hud_refresh :: proc(app: ^App, now: f64) {
	h := &hud
	n := &h.nums
	n^ = {at_ms = now}
	since := now - h.cfg.window_ms
	budget := hud_budget()
	n.budget = budget
	cpu := make([dynamic]f32, 0, 256, context.temp_allocator)
	gpu := make([dynamic]f32, 0, 256, context.temp_allocator)
	oldest := now
	for i := ui.history_len(&h.history) - 1; i >= 0; i -= 1 {
		s := ui.history_at(&h.history, i)
		if s.t_ms < since { break }
		oldest = s.t_ms
		c := ui.sample_total(s, CPU_SERIES)
		append(&cpu, c)
		n.cpu_mean += c
		n.cpu_max = max(n.cpu_max, c)
		if budget > 0 && c > budget { n.over += 1 }
		for k in Hud_Series { n.series[k] += s.v[k] }
		if g := s.v[Hud_Series.GPU]; g > 0 {
			append(&gpu, g)
			n.gpu_mean += g; n.gpu_max = max(n.gpu_max, g); n.gpu_n += 1
			if budget > 0 && g > budget { n.gpu_over += 1 }
		}
		if d := &h.details[s.tag % u64(len(h.details))]; d.serial == s.tag {
			n.wasm_mean += d.wasm_ms
			switch d.restyle {
			case .None:
			case .Partial: n.partial_restyles += 1
			case .Full: n.full_restyles += 1
			}
			n.passes[d.lay_pass] += 1
		}
	}
	n.frames = len(cpu)
	if n.frames > 0 {
		f := f32(n.frames)
		n.cpu_mean /= f
		n.wasm_mean /= f
		for k in Hud_Series { n.series[k] /= f }
		n.cpu_p95, n.cpu_p99 = percentile(cpu[:], 0.95), percentile(cpu[:], 0.99)
	}
	if n.gpu_n > 0 {
		n.gpu_mean /= f32(n.gpu_n)
		n.gpu_p95, n.gpu_p99 = percentile(gpu[:], 0.95), percentile(gpu[:], 0.99)
	}
	// frames on screen in the window: missed refreshes, input latency
	lat := make([dynamic]f32, 0, 256, context.temp_allocator)
	for i := len(h.shown) - 1; i >= 0 && h.shown[i].t_ms >= since; i -= 1 {
		sh := h.shown[i]
		n.shown += 1
		n.missed += int(sh.missed)
		if sh.latency_ms >= 0 { append(&lat, sh.latency_ms); n.lat_mean += sh.latency_ms; n.lat_max = max(n.lat_max, sh.latency_ms) }
	}
	if n.lat_n = len(lat); n.lat_n > 0 {
		n.lat_mean /= f32(n.lat_n)
		n.lat_p95 = percentile(lat[:], 0.95)
	}
	// the window, or the frames the history still holds when they came faster than it keeps
	span := h.cfg.window_ms
	if n.frames == ui.history_capacity(&h.history) { span = max(now - oldest, 1) }
	n.fps = f32(f64(n.frames) * 1000 / span)
	n.working_set, n.private_bytes, n.mem_valid = process_memory()
}

// The `q` quantile (0..1) of `v` (sorted in place): the smallest value at least that share of them do not exceed.
percentile :: proc(v: []f32, q: f32) -> f32 {
	if len(v) == 0 { return 0 }
	sort_f32(v)
	return v[clamp(int(f32(len(v)) * q + 0.999) - 1, 0, len(v) - 1)]
}

@(private = "file")
sort_f32 :: proc(v: []f32) {
	for i in 1 ..< len(v) {
		x := v[i]
		j := i - 1
		for j >= 0 && v[j] > x { v[j + 1] = v[j]; j -= 1 }
		v[j + 1] = x
	}
}

////////////////////////////////
// Memory of the process

@(private = "file")
Process_Memory_Counters_Ex :: struct {
	cb, page_fault_count: u32,
	peak_working_set, working_set, quota_peak_paged, quota_paged, quota_peak_nonpaged, quota_nonpaged, pagefile, peak_pagefile, private_usage: uint,
}

foreign import kernel32_hud "system:Kernel32.lib"
@(default_calling_convention = "system", private = "file")
foreign kernel32_hud {
	K32GetProcessMemoryInfo :: proc(process: win.HANDLE, counters: ^Process_Memory_Counters_Ex, cb: u32) -> win.BOOL ---
}

// Working set and private bytes of the process.
process_memory :: proc() -> (working_set, private_bytes: int, ok: bool) {
	c := Process_Memory_Counters_Ex{cb = size_of(Process_Memory_Counters_Ex)}
	if !K32GetProcessMemoryInfo(win.GetCurrentProcess(), &c, c.cb) { return }
	return int(c.working_set), int(c.private_usage), true
}

////////////////////////////////
// Formatting

// Milliseconds with the precision they deserve: 0.35, 4.2, 18.
fmt_ms :: proc(v: f32, comma := false) -> string {
	s: string
	switch {
	case v < 1:   s = fmt.tprintf("%.2f", v)
	case v < 100: s = fmt.tprintf("%.1f", v)
	case:         s = fmt.tprintf("%.0f", v)
	}
	return comma ? decimal_comma(s) : s
}

// A rate in hertz: whole when it is (180), else to the hundredth (59.94, 179.98).
fmt_hz :: proc(v: f64, comma := false) -> string {
	s := abs(v - math.round(v)) < 0.005 ? fmt.tprintf("%.0f", v) : fmt.tprintf("%.2f", v)
	return comma ? decimal_comma(s) : s
}

fmt_bytes :: proc(n: int, comma := false) -> string {
	s: string
	switch {
	case n < 1000:          s = fmt.tprintf("%d B", n)
	case n < 1000 * 1000:   s = fmt.tprintf("%.1f kB", f64(n) / 1e3)
	case n < 1000_000_000:  s = fmt.tprintf("%.0f MB", f64(n) / 1e6)
	case:                   s = fmt.tprintf("%.2f GB", f64(n) / 1e9)
	}
	return comma ? decimal_comma(s) : s
}

// 12345 -> "12 345" (thin groups: counts of nodes, cookies...).
fmt_count :: proc(n: int) -> string {
	s := fmt.tprintf("%d", n)
	if len(s) <= 4 { return s }
	b := strings.builder_make(context.temp_allocator)
	lead := len(s) % 3
	for i in 0 ..< len(s) {
		if i > 0 && (i - lead) % 3 == 0 && s[i - 1] != '-' { strings.write_byte(&b, ' ') }
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

decimal_comma :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, ".", ",", context.temp_allocator)
	return out
}

////////////////////////////////
// Window title

Title_Field :: enum u8 { App, Version, Commit, Date, Build, Engine, Toolkit, Fps, Cpu, Gpu, Mem, Page, Url }

TITLE_FIELD_NAMES := [Title_Field]string{
	.App = "app", .Version = "version", .Commit = "commit", .Date = "date", .Build = "build", .Engine = "engine",
	.Toolkit = "toolkit", .Fps = "fps", .Cpu = "cpu", .Gpu = "gpu", .Mem = "mem", .Page = "page", .Url = "url",
}

TITLE_STAT_FIELDS :: bit_set[Title_Field]{.Fps, .Cpu, .Gpu, .Mem}

title_has_stats :: proc(format: string) -> bool {
	for f in TITLE_STAT_FIELDS { if strings.contains(format, strings.concatenate({"{", TITLE_FIELD_NAMES[f], "}"}, context.temp_allocator)) { return true } }
	return false
}

// The title from its format: fields replaced by their values; a part (between separators) with a field that has no
// value ("") is left out, together with the separator before it.
title_compose :: proc(format, separator: string, values: [Title_Field]string, allocator := context.temp_allocator) -> string {
	seps := [3]string{separator, " — ", " | "}
	Part :: struct { text: string, sep: string }   // sep: the separator before the part
	parts := make([dynamic]Part, context.temp_allocator)
	start, sep_before := 0, ""
	i := 0
	scan: for i < len(format) {
		for s in seps {
			if s != "" && strings.has_prefix(format[i:], s) {
				append(&parts, Part{format[start:i], sep_before})
				sep_before = s
				i += len(s)
				start = i
				continue scan
			}
		}
		i += 1
	}
	append(&parts, Part{format[start:], sep_before})

	out := strings.builder_make(allocator)
	any := false
	part: for p in parts {
		b := strings.builder_make(context.temp_allocator)
		s := p.text
		for len(s) > 0 {
			open := strings.index_byte(s, '{')
			if open < 0 { strings.write_string(&b, s); break }
			close := strings.index_byte(s[open:], '}')
			if close < 0 { strings.write_string(&b, s); break }
			strings.write_string(&b, s[:open])
			name := s[open + 1:open + close]
			known := false
			for f in Title_Field {
				if TITLE_FIELD_NAMES[f] != name { continue }
				known = true
				if values[f] == "" { continue part }
				strings.write_string(&b, values[f])
			}
			if !known { strings.write_string(&b, s[open:open + close + 1]) }
			s = s[open + close + 1:]
		}
		text := strings.to_string(b)
		if strings.trim_space(text) == "" { continue }
		if any { strings.write_string(&out, p.sep) }
		strings.write_string(&out, text)
		any = true
	}
	return strings.to_string(out)
}

// The values of the title's fields now (stats: "" when not shown or not measured).
title_values :: proc(app: ^App, t: ^Tab) -> (v: [Title_Field]string) {
	h := &hud
	c := h.cfg.comma
	v[.App] = APP_NAME
	v[.Version] = APP_VERSION
	v[.Commit] = app_commit()
	v[.Date] = APP_COMMIT_DATE
	v[.Build] = build_description()
	v[.Engine] = fmt.tprintf("Wasmtime %s", wasm.WASMTIME_VERSION)
	v[.Toolkit] = fmt.tprintf("gui_toolkit %s", ui.VERSION)
	if t != nil { v[.Page], v[.Url] = t.title, t.url }
	if h.cfg.title_stats && phase_clock.on {
		n := &h.nums
		v[.Fps] = fmt.tprintf("%.0f", n.fps)
		if n.frames > 0 { v[.Cpu] = fmt_ms(n.cpu_mean, c) }
		if n.gpu_n > 0 { v[.Gpu] = fmt_ms(n.gpu_mean, c) }
		if n.mem_valid { v[.Mem] = fmt.tprintf("%d", n.working_set / 1_000_000) }
	}
	return
}

// Whether the title is composed again: at once when the page (its title or address) changed, else only for
// statistics, at most every `interval_ms`, or when they come to rest (`settling`).
title_due :: proc(same_page: bool, stats: bool, since_ms, interval_ms: f64, settling: bool) -> bool {
	if !same_page { return true }
	if !stats { return false }
	return settling || since_ms >= interval_ms
}

// Sets the window title when it changed (title_due), calling the system only when the text differs.
@(private = "file")
hud_title :: proc(app: ^App, now: f64) {
	h := &hud
	t := current_tab(app)
	page_title, page_url := "", ""
	if t != nil { page_title, page_url = t.title, t.url }
	same_page := raw_data(page_title) == raw_data(h.title_page) && len(page_title) == len(h.title_page) && raw_data(page_url) == raw_data(h.title_url)
	stats := h.cfg.title_stats && phase_clock.on && title_has_stats(h.cfg.title_format)
	if !title_due(h.title_text != "" && same_page, stats, now - h.title_ms, h.cfg.title_ms, h.settle_skip) { return }
	h.title_page, h.title_url, h.title_ms = page_title, page_url, now
	text := title_compose(h.cfg.title_format, h.cfg.title_sep, title_values(app, t))
	if text == "" { text = APP_NAME }
	if text == h.title_text { return }
	delete(h.title_text)
	h.title_text = strings.clone(text)
	platform.set_title(app.win, text)
}

////////////////////////////////
// Monospace digits

// The monospace font of the status bar's numbers (Consolas, else the toolkit's embedded one), loaded when first shown.
hud_mono :: proc(app: ^App) {
	if hud.mono_tried { return }
	hud.mono_tried = true
	id, ok, _ := font.load_system_or_embedded(&app.fonts, platform.system_font_path("consola.ttf"), font.FALLBACK_MONO_DATA)
	if ok { hud.mono = id; app.ui_state.mono_font = id }
}
