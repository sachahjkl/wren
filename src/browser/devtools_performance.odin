package browser

// The Performance tab: the frames of the shell as the status bar's graph measures them (hud.history: the phases of each frame
// in ms, from the browser's own clock), drawn larger and readable: a stacked bar per frame (tasks, style, layout, paint, the
// interface, submit, GPU) against the frame budget, the frame rate over a sliding window, the long tasks (frames over a
// threshold) as a list, and a frame's details when one is chosen (what the cascade, layout and the compositor did in it).
// The frames are the ones that happened: the browser draws nothing at rest, so a quiet page has no new bars.
//
// Recording can be stopped (the picture is a copy then) and started again; while the tab is shown the phase clock runs,
// as it does for the status bar.

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"

PERF_LONG_TASK_MS :: 50.0

Perf_Frame :: struct { v: [ui.HISTORY_SERIES]f32, t_ms: f64, tag: u64, d: Frame_Detail }

Dev_Performance :: struct {
	frozen:  bool,                     // not recording: `snap` is what is shown
	snap:    [dynamic]Perf_Frame,
	sel:     int,                      // the chosen frame (index in what is shown, -1: none)
	hide:    [Hud_Series]bool,         // phases not drawn
	list:    Dt_List,
	hover:   int,
	rate_max: f32,
}

performance_destroy :: proc() {
	p := &dev.perf
	delete(p.snap)
	dt_list_destroy(&p.list)
	p^ = {}
}

@(private = "file")
frames_now :: proc(p: ^Dev_Performance) -> []Perf_Frame {
	if p.frozen { return p.snap[:] }
	return nil
}

@(private = "file")
live_frame :: proc(i: int) -> Perf_Frame {
	s := ui.history_at(&hud.history, i)
	f := Perf_Frame{v = s.v, t_ms = s.t_ms, tag = s.tag}
	if hd := hud.details[s.tag % u64(len(hud.details))]; hd.serial == s.tag { f.d = hd }
	return f
}

@(private = "file")
count_frames :: proc(p: ^Dev_Performance) -> int { return p.frozen ? len(p.snap) : ui.history_len(&hud.history) }

@(private = "file")
frame_at :: proc(p: ^Dev_Performance, i: int) -> Perf_Frame { return p.frozen ? p.snap[i] : live_frame(i) }

@(private = "file")
cpu_total :: proc(f: Perf_Frame) -> f32 {
	t: f32
	for k in Hud_Series { if k != .GPU { t += f.v[k] } }
	return t
}

@(private = "file")
Chart_Draw :: struct {
	frames:  []Perf_Frame,
	colors:  [Hud_Series]draw.Color,
	hide:    [Hud_Series]bool,
	budget:  f32,
	scale:   f32,
	sel, hover: int,
	hot_x:   f32,
}

performance_panel :: proc(app: ^App, t: ^Tab) {
	p := &dev.perf
	if p.sel == 0 && !p.frozen && ui.history_len(&hud.history) == 0 { p.sel = -1 }
	n := count_frames(p)
	if dt_bar("###dt_perf_bar") {
		dt_gap(3)
		rec := dt_btn("###dt_perf_rec", p.frozen ? .Record : .Pause, p.frozen ? "Record" : "Stop", tooltip = p.frozen ? "Record frames again" : "Stop recording: keep what is shown", tone = p.frozen ? dtc.bad : dtc.weak)
		if rec.clicked { toggle_record(p) }
		if dt_btn("###dt_perf_clear", .Clear, tooltip = "Clear the recorded frames", enabled = n > 0).clicked {
			if p.frozen { clear(&p.snap) } else { ui.history_clear(&hud.history) }
			p.sel = -1
		}
		dt_vsep("###dt_pb0")
		// the numbers
		if n > 0 {
			ui.next({width = ui.fill(), height = ui.pct(1)})
			summary := perf_summary(p, n)
			ui.custom("###dt_perf_sum", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				s := (^string)(user)^
				dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x + dt_px(4), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.weak, s, b.rect.max.x - b.rect.min.x - dt_px(8))
			}, new_clone(dt_frame_str(summary), ui.frame_allocator()))
		} else {
			ui.spacer(ui.fill())
		}
		dt_gap(3)
	}
	// the legend: a chip per phase, a click hides or shows it
	if dt_bar("###dt_perf_legend", dtm.bar - dt_px(4)) {
		dt_gap(5)
		cols := hud_series_colors()
		for k in Hud_Series {
			ui.next({width = ui.px(math.round(dt_w(dtm.ui_font, dtm.fs, perf_names[k]) + dt_px(24))), height = ui.px(dtm.btn - dt_px(4)), cursor = .Arrow})
			cb := ui.build_box({.Clickable}, fmt.tprintf("###dt_pl%d", int(k)))
			sig := ui.signal(cb)
			ld := ui.frame_new(Legend_Draw)
			ld.name, ld.col, ld.off, ld.hot = perf_names[k], cols[k], p.hide[k], sig.hovering
			cb.custom, cb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				d := (^Legend_Draw)(user)
				r := b.rect
				cy := (r.min.y + r.max.y) * 0.5
				if d.hot { draw.rect(dc, r, dtc.hover, dtm.radius) }
				sw := dt_px(9)
				draw.rect(dc, {{r.min.x + dt_px(6), cy - sw * 0.5}, {r.min.x + dt_px(6) + sw, cy + sw * 0.5}}, d.off ? with_alpha(d.col, 0.25) : d.col, dt_px(2))
				dt_text(dc, dtm.ui_font, dtm.fs, r.min.x + dt_px(18), cy, d.off ? dtc.faint : dtc.text, d.name)
			}, ld
			if sig.clicked { p.hide[k] = !p.hide[k] }
		}
	}
	if n == 0 {
		dt_empty("###dt_perf_none", .Tab_Performance, "No frames yet", "Frames appear as the browser draws them: move the pointer over the page, scroll it, or reload it.")
		return
	}
	// the chart takes the top, the details the rest
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(.Start, {}, "###dt_perf_body") {
		ui.next({width = ui.fill(), height = ui.pct(0.5)})
		chart := ui.build_box({.Clickable}, "###dt_perf_chart")
		sig := ui.signal(chart)
		cd := ui.frame_new(Chart_Draw)
		frames := make([]Perf_Frame, n, ui.frame_allocator())
		for i in 0 ..< n { frames[i] = frame_at(p, i) }
		cd.frames, cd.colors, cd.hide = frames, hud_series_colors(), p.hide
		cd.budget = hud_budget()
		peak := f32(0)
		for f in frames { peak = max(peak, perf_height(f, p.hide)) }
		cd.scale = clamp(peak * 1.1, cd.budget * 1.6, cd.budget * 4)
		cd.sel, cd.hover = p.sel, -1
		chart_w := chart.size.x > 0 ? chart.size.x : f32(800)
		slots := max(int(chart_w / dt_px(4)), 8)
		first := max(n - slots, 0)
		if sig.hovering {
			k := int((sig.mouse.x - dt_px(34)) / max(dt_px(4), 1))
			cd.hover = clamp(first + k, 0, n - 1)
			cd.hot_x = sig.mouse.x
		}
		if sig.clicked && cd.hover >= 0 { p.sel = cd.hover }
		cd.frames = frames[first:]
		cd.sel = p.sel >= first ? p.sel - first : -1
		if cd.hover >= 0 { cd.hover -= first }
		chart.custom, chart.custom_user = chart_paint, cd
		if sig.hovering && cd.hover >= 0 && cd.hover < len(cd.frames) { frame_tip(frames[first + cd.hover], cd.colors) }
		perf_lower(app, t, p, n)
	}
}

@(private = "file")
Legend_Draw :: struct { name: string, col: draw.Color, off, hot: bool }

@(private = "file")
perf_names := [Hud_Series]string{.Tasks = "Tasks", .Styles = "Style", .Layout = "Layout", .Paint = "Paint", .UI = "Interface", .Submit = "Submit", .GPU = "GPU"}

@(private = "file")
toggle_record :: proc(p: ^Dev_Performance) {
	if p.frozen {
		p.frozen = false
		clear(&p.snap)
		return
	}
	n := ui.history_len(&hud.history)
	clear(&p.snap)
	for i in 0 ..< n { append(&p.snap, live_frame(i)) }
	p.frozen = true
}

@(private = "file")
perf_height :: proc(f: Perf_Frame, hide: [Hud_Series]bool) -> f32 {
	h: f32
	for k in Hud_Series { if !hide[k] && k != .GPU { h += f.v[k] } }
	return max(h, f.v[Hud_Series.GPU] if !hide[.GPU] else 0)
}

@(private = "file")
perf_summary :: proc(p: ^Dev_Performance, n: int) -> string {
	if n < 2 { return "" }
	first, last := frame_at(p, 0), frame_at(p, n - 1)
	span := last.t_ms - first.t_ms
	long := 0
	total, worst: f32
	for i in 0 ..< n {
		f := frame_at(p, i)
		c := cpu_total(f)
		total += c
		worst = max(worst, c)
		if c >= PERF_LONG_TASK_MS { long += 1 }
	}
	fps := span > 0 ? f32(f64(n - 1) / (span / 1000)) : 0
	return fmt.tprintf("%d frames in %s   \u2022   %.0f fps while drawing   \u2022   CPU %.1f ms mean, %.1f ms worst   \u2022   %d long tasks (> %d ms)", n, dt_ms_text(f32(span)), fps, total / f32(n), worst, long, int(PERF_LONG_TASK_MS))
}

@(private = "file")
chart_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Chart_Draw)(user)
	r := b.rect
	left := r.min.x + dt_px(34)
	top := r.min.y + dt_px(8)
	bottom := r.max.y - dt_px(14)
	h := bottom - top
	// the grid: the budget and its multiples
	for m in 0 ..< 4 {
		v := d.budget * f32(m)
		if v > d.scale { break }
		y := bottom - v / d.scale * h
		draw.rect(dc, {{left, y}, {r.max.x - dt_px(6), y + dtm.line}}, with_alpha(dtc.border, m == 1 ? 0.95 : 0.4))
		dt_text_r(dc, dtm.mono, dtm.mono_fs * 0.85, left - dt_px(5), y, dtc.faint, m == 0 ? "0" : fmt.tprintf("%.0f", v))
	}
	bw := dt_px(4)
	gap := dtm.line
	for f, i in d.frames {
		x := left + f32(i) * bw
		if x + bw > r.max.x { break }
		y := bottom
		for k in Hud_Series {
			if d.hide[k] || k == .GPU { continue }
			v := f.v[k]
			if v <= 0 { continue }
			hh := min(v / d.scale * h, y - top)
			if hh <= 0 { break }
			draw.rect(dc, {{x, y - hh}, {x + bw - gap, y}}, d.colors[k])
			y -= hh
		}
		if !d.hide[.GPU] && f.v[Hud_Series.GPU] > 0 {
			gy := bottom - f.v[Hud_Series.GPU] / d.scale * h
			draw.rect(dc, {{x, gy - dtm.line}, {x + bw - gap, gy + dtm.line}}, d.colors[.GPU])
		}
		if y <= top + dtm.line { draw.rect(dc, {{x, top}, {x + bw - gap, top + dt_px(2)}}, dtc.bad) }
		if i == d.sel { draw.rect(dc, {{x - dtm.line, top}, {x + bw, bottom}}, with_alpha(dtc.accent, 0.22)) }
	}
	if d.hover >= 0 { draw.rect(dc, {{left + f32(d.hover) * bw, top}, {left + f32(d.hover) * bw + bw - gap, bottom}}, with_alpha(dtc.text, 0.12)) }
	// the axis
	dt_text(dc, dtm.ui_font, dtm.fs * 0.85, left, r.max.y - dt_px(4), dtc.faint, "older")
	dt_text_r(dc, dtm.ui_font, dtm.fs * 0.85, r.max.x - dt_px(6), r.max.y - dt_px(4), dtc.faint, "newer")
	dt_text_r(dc, dtm.ui_font, dtm.fs * 0.85, r.max.x - dt_px(6), top + dt_px(6), with_alpha(dtc.accent, 0.8), fmt.tprintf("budget %.1f ms", d.budget))
}

@(private = "file")
frame_tip :: proc(f: Perf_Frame, colors: [Hud_Series]draw.Color) {
	if ui.tooltip_beside() {
		w := dt_px(200)
		ui.next({width = ui.px(w), height = ui.px(dtm.row * 9 + dt_px(8)), axis = .Y})
		if ui.column(.Start, {}, "###dt_perf_tip") {
			ui.next({width = ui.fill(), height = ui.px(dtm.row)})
			ui.custom("###dt_pt0", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				f := (^Perf_Frame)(user)
				dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x + dt_px(8), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.text, fmt.tprintf("Frame %d   %.2f ms", f.tag, cpu_total(f^)))
			}, new_clone(f, ui.frame_allocator()))
			for k in Hud_Series {
				ui.next({width = ui.fill(), height = ui.px(dtm.row)})
				row := ui.frame_new(Legend_Draw)
				row.name, row.col = fmt.aprintf("%s   %.2f ms", perf_names[k], f.v[k], allocator = ui.frame_allocator()), colors[k]
				rb := ui.build_box({}, fmt.tprintf("###dt_ptr%d", int(k)))
				rb.custom, rb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
					d := (^Legend_Draw)(user)
					cy := (b.rect.min.y + b.rect.max.y) * 0.5
					sw := dt_px(9)
					draw.rect(dc, {{b.rect.min.x + dt_px(8), cy - sw * 0.5}, {b.rect.min.x + dt_px(8) + sw, cy + sw * 0.5}}, d.col, dt_px(2))
					dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x + dt_px(22), cy, dtc.weak, d.name)
				}, row
			}
		}
	}
}

// Under the chart: the long tasks at the left, the chosen frame at the right.
@(private = "file")
perf_lower :: proc(app: ^App, t: ^Tab, p: ^Dev_Performance, n: int) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row(.Start, {}, "###dt_perf_low") {
		ui.next({width = ui.pct(0.5), height = ui.fill(), axis = .Y})
		if ui.column(.Start, {.Clip}, "###dt_perf_tasks") {
			ui.next({width = ui.fill(), height = ui.px(dtm.row + dt_px(2)), bg = dtc.bar, border = dtc.border})
			hb := ui.build_box({.Draw_Background, .Draw_Side_Bottom, .Draw_Side_Top}, "###dt_perf_th")
			hb.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				cy := (b.rect.min.y + b.rect.max.y) * 0.5
				dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x + dt_px(8), cy, dtc.weak, "Slowest frames")
				dt_text_r(dc, dtm.ui_font, dtm.fs, b.rect.max.x - dt_px(8), cy, dtc.weak, "CPU")
			}
			idx := make([dynamic]int, 0, 32, context.temp_allocator)
			for i := n - 1; i >= 0 && len(idx) < 400; i -= 1 { if cpu_total(frame_at(p, i)) >= 8 { append(&idx, i) } }
			// the slowest first
			for a in 1 ..< len(idx) {
				j := a
				for j > 0 && cpu_total(frame_at(p, idx[j])) > cpu_total(frame_at(p, idx[j - 1])) { idx[j], idx[j - 1] = idx[j - 1], idx[j]; j -= 1 }
			}
			if len(idx) == 0 {
				dt_empty("###dt_perf_nolong", .Check, "No slow frame", "Every frame took less than 8 ms of CPU.")
			} else if lst, ok := dt_list("###dt_perf_list", &p.list, len(idx), dtm.row, nil, ui.fill(), ui.fill()); ok {
				for k in lst.first ..< lst.last {
					fi := idx[k]
					f := frame_at(p, fi)
					d := ui.frame_new(Task_Draw)
					d.n, d.ms, d.sel, d.long = int(f.tag), cpu_total(f), p.sel == fi, cpu_total(f) >= PERF_LONG_TASK_MS
					d.what = dt_frame_str(frame_what(f))
					ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Arrow})
					rb := ui.build_box({.Clickable}, fmt.tprintf("###dt_pk%d", k))
					sig := ui.signal(rb)
					d.hot = sig.hovering
					rb.custom, rb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
						d := (^Task_Draw)(user)
						r := b.rect
						cy := (r.min.y + r.max.y) * 0.5
						dt_row_back(dc, r, false, d.sel, d.hot, true)
						x := r.min.x + dt_px(8)
						x += dt_text(dc, dtm.mono, dtm.mono_fs, x, cy, dtc.weak, fmt.tprintf("#%d", d.n)) + dt_px(10)
						dt_text(dc, dtm.ui_font, dtm.fs, x, cy, dtc.text, d.what, r.max.x - x - dt_px(80))
						dt_text_r(dc, dtm.mono, dtm.mono_fs, r.max.x - dt_px(8), cy, d.long ? dtc.bad : dtc.text, fmt.tprintf("%.1f ms", d.ms))
					}, d
					if sig.pressed { p.sel = fi }
				}
			}
		}
		dt_vsplit_rule("###dt_perf_rule")
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(.Start, {.Clip}, "###dt_perf_detail") { frame_detail(p, n) }
	}
}

@(private = "file")
Task_Draw :: struct { n: int, ms: f32, sel, hot, long: bool, what: string }

// A thin rule between side by side panes (no drag).
dt_vsplit_rule :: proc(id: string) {
	ui.next({width = ui.px(dtm.line), height = ui.fill(), bg = dtc.border})
	ui.build_box({.Draw_Background}, id)
}

// What a frame was mostly spent on.
@(private = "file")
frame_what :: proc(f: Perf_Frame) -> string {
	best: Hud_Series
	bv: f32
	for k in Hud_Series { if k != .GPU && f.v[k] > bv { best, bv = k, f.v[k] } }
	switch best {
	case .Tasks: return f.d.wasm_ms > 0.5 ? fmt.tprintf("Scripts and tasks (%.1f ms in WebAssembly)", f.d.wasm_ms) : "Tasks, timers and input"
	case .Styles: return f.d.restyle == .Full ? fmt.tprintf("Style: full restyle of %d elements", f.d.restyled) : "Style recalculation"
	case .Layout: return fmt.tprintf("Layout (%v, %d boxes)", f.d.lay_pass, f.d.lay_boxes)
	case .Paint: return "Painting the page"
	case .UI: return "The browser's own interface"
	case .Submit: return "Submitting the frame to the GPU"
	case .GPU: return "GPU"
	}
	return ""
}

@(private = "file")
frame_detail :: proc(p: ^Dev_Performance, n: int) {
	if p.sel < 0 || p.sel >= n {
		dt_empty("###dt_perf_nosel", .Tab_Performance, "Choose a frame", "Click a bar of the chart or a slow frame to see what it did.")
		return
	}
	f := frame_at(p, p.sel)
	lines := make([dynamic][2]string, 0, 24, context.temp_allocator)
	add :: proc(l: ^[dynamic][2]string, k, v: string) { append(l, [2]string{dt_frame_str(k), dt_frame_str(v)}) }
	add(&lines, "Frame", fmt.tprintf("#%d", f.tag))
	for k in Hud_Series { add(&lines, perf_names[k], fmt.tprintf("%.2f ms", f.v[k])) }
	add(&lines, "CPU total", fmt.tprintf("%.2f ms", cpu_total(f)))
	add(&lines, "Waiting for the display", fmt.tprintf("%.2f ms", f.d.wait_ms))
	add(&lines, "Style", f.d.restyle == .None ? "no restyle" : fmt.tprintf("%v, %d elements", f.d.restyle, f.d.restyled))
	add(&lines, "Layout", fmt.tprintf("%v: %d boxes, %d items", f.d.lay_pass, f.d.lay_boxes, f.d.lay_items))
	if f.d.comp_valid { add(&lines, "Compositor", fmt.tprintf("%d pictures, %d visible, %d replayed", f.d.comp.chunks, f.d.comp.visible, f.d.comp.replayed)) }
	add(&lines, "WebAssembly", fmt.tprintf("%.2f ms in %d calls", f.d.wasm_ms, f.d.wasm_calls))
	if lst, ok := dt_list("###dt_perf_dl", &dev.perf.list, len(lines), dtm.row, nil, ui.fill(), ui.fill()); ok {
		for k in lst.first ..< lst.last {
			d := ui.frame_new(Pair_Draw_Simple)
			d.k, d.v = lines[k][0], lines[k][1]
			ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Arrow})
			rb := ui.build_box({}, fmt.tprintf("###dt_pdl%d", k))
			rb.custom, rb.custom_user = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				d := (^Pair_Draw_Simple)(user)
				cy := (b.rect.min.y + b.rect.max.y) * 0.5
				dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x + dt_px(10), cy, dtc.weak, d.k, (b.rect.max.x - b.rect.min.x) * 0.45)
				dt_text(dc, dtm.mono, dtm.mono_fs, b.rect.min.x + (b.rect.max.x - b.rect.min.x) * 0.48, cy, dtc.text, d.v, (b.rect.max.x - b.rect.min.x) * 0.5)
			}, d
		}
	}
}

Pair_Draw_Simple :: struct { k, v: string }

_ :: strings
