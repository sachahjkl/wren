package browser

// The Memory tab: what the browser and the page hold, as bordered tiles (the process's working set and private bytes, the
// page's JavaScript heap, its document's nodes, the images, the pictures and the glyphs kept for drawing, the GPU's
// textures) with the history of the main numbers as small charts, and buttons to collect the page's garbage and to take a
// snapshot to compare with later. A sample is taken each time the tab is built (at most once a second); with "Live" on, the
// tab asks for a frame each second so the charts go on at rest (off by default: an idle browser draws nothing).

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:host"
import "wb:js"
import "wb:page"
import "toolkit:render"

Mem_Sample :: struct {
	at_ms:   f64,
	ws, private, js_heap, images, pictures, gpu, nodes: f64,
}

Dev_Memory :: struct {
	samples:  [dynamic]Mem_Sample,
	live:     bool,
	tick:     base.Handle,
	snapshot: Mem_Sample,
	has_snap: bool,
}

MEM_MAX_SAMPLES :: 600

memory_destroy :: proc() {
	m := &dev().mem
	delete(m.samples)
	if m.tick != base.NIL_HANDLE && the_app != nil { host.clear_timer(&the_app.loop, m.tick) }
	m^ = {}
}

@(private = "file")
sample_now :: proc(app: ^App, t: ^Tab) -> Mem_Sample {
	s := Mem_Sample{at_ms = ui.now_ms()}
	n := hud.nums
	s.ws, s.private = f64(n.working_set), f64(n.private_bytes)
	if t != nil && t.page != nil && t.page.js != nil && t.page.js.inst != nil { s.js_heap = js.heap_bytes(t.page.js.inst) }
	if t != nil && t.page != nil {
		s.nodes = f64(t.page.doc.nodes.count)
		is := page.images_stats(t.page)
		s.images = f64(is.bytes)
	}
	used, _ := draw.retained_bytes(&app.dc)
	s.pictures = f64(used)
	tm := render.texture_memory(&app.r)
	s.gpu = f64(tm.images + tm.glyphs + tm.targets)
	return s
}

memory_panel :: proc(app: ^App, t: ^Tab) {
	m := &dev().mem
	now := ui.now_ms()
	if len(m.samples) == 0 || now - m.samples[len(m.samples) - 1].at_ms >= 900 {
		if len(m.samples) >= MEM_MAX_SAMPLES { ordered_remove(&m.samples, 0) }
		append(&m.samples, sample_now(app, t))
	}
	cur := m.samples[len(m.samples) - 1]
	if dt_bar("###dt_mem_bar") {
		dt_gap(3)
		if dt_btn("###dt_mem_gc", .Refresh, "Collect garbage", tooltip = "Run the page's garbage collector now", enabled = t != nil && t.page != nil && t.page.js != nil && t.page.js.inst != nil).clicked {
			if t.page != nil && t.page.js != nil && t.page.js.inst != nil { js.collect(t.page.js.inst) }
			request_frames(app, 3)
			clear(&m.samples)
		}
		if dt_btn("###dt_mem_snap", .Pin, "Take a snapshot", tooltip = "Keep these numbers to compare with the next ones").clicked { m.snapshot, m.has_snap = cur, true }
		dt_vsep("###dt_mem_b0")
		if dt_chip("###dt_mem_live", "Live", m.live, "Take a sample every second while this tab is shown (the browser then draws a frame a second)").clicked { m.live = !m.live }
		dt_gap(3)
	}
	if m.live && m.tick == base.NIL_HANDLE {
		m.tick = host.set_timer(&app.loop, 1000, 0, proc(data: rawptr) {   // (the window's id: it may close before)
			w, d := devtools_of_window_id(the_app, int(uintptr(data)))
			if d == nil { return }
			d.mem.tick = base.NIL_HANDLE
			if d.visible && d.panel == .Memory && d.mem.live { window_request(the_app, w, 2) }
		}, rawptr(uintptr(active_window(app).id)), nil)
	}
	tiles := [?]struct { title: string, value: f64, get: proc(s: Mem_Sample) -> f64, bytes: bool, tip: string }{
		{"Process memory", cur.ws, proc(s: Mem_Sample) -> f64 { return s.ws }, true, "Working set of the browser process: what Windows keeps in RAM for it"},
		{"Private bytes", cur.private, proc(s: Mem_Sample) -> f64 { return s.private }, true, "Memory only this process uses"},
		{"JavaScript heap", cur.js_heap, proc(s: Mem_Sample) -> f64 { return s.js_heap }, true, "The page's engine heap"},
		{"Document nodes", cur.nodes, proc(s: Mem_Sample) -> f64 { return s.nodes }, false, "Elements, text and comments of the document"},
		{"Image cache", cur.images, proc(s: Mem_Sample) -> f64 { return s.images }, true, "Decoded images of the page"},
		{"Pictures", cur.pictures, proc(s: Mem_Sample) -> f64 { return s.pictures }, true, "Display lists the compositor keeps"},
		{"GPU textures", cur.gpu, proc(s: Mem_Sample) -> f64 { return s.gpu }, true, "Images, glyphs and layers on the graphics card"},
	}
	room := dev_width()
	cols := max(int(room / dt_px(250)), 1)
	tile_w := (room - dt_px(24)) / f32(cols) - dt_px(8)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.scroll_y("###dt_mem_scroll") {
		ui.spacer(ui.px(dt_px(8)))
		for start := 0; start < len(tiles); start += cols {
			ui.next({width = ui.fill(), height = ui.px(dt_px(96)), axis = .X})
			if ui.row(.Start, {}, fmt.tprintf("###dt_mem_row%d", start)) {
				ui.spacer(ui.px(dt_px(12)))
				for i in start ..< min(start + cols, len(tiles)) {
					tl := tiles[i]
					td := ui.frame_new(Tile_Draw)
					td.title, td.value = tl.title, tl.bytes ? fmt_bytes(int(tl.value)) : fmt_count(int(tl.value))
					td.series = make([]f32, len(m.samples), ui.frame_allocator())
					for s, k in m.samples { td.series[k] = f32(tl.get(s)) }
					if m.has_snap {
						base_v := tl.get(m.snapshot)
						diff := tl.value - base_v
						td.delta = dt_frame_str(fmt.tprintf("%s%s since the snapshot", diff >= 0 ? "+" : "\u2212", tl.bytes ? fmt_bytes(int(abs(diff))) : fmt_count(int(abs(diff)))))
						td.up = diff > 0
					}
					ui.next({width = ui.px(math.round(tile_w)), height = ui.px(dt_px(88)), cursor = .Arrow})
					tb := ui.build_box({.Clickable}, fmt.tprintf("###dt_mem_t%d", i))
					sig := ui.signal(tb)
					td.hot = sig.hovering
					tb.custom, tb.custom_user = tile_paint, td
					dt_tip(sig, tl.tip)
					ui.spacer(ui.px(dt_px(8)))
				}
			}
			ui.spacer(ui.px(dt_px(8)))
		}
		if len(m.samples) < 3 {
			ui.next({width = ui.fill(), height = ui.px(dt_px(40))})
			ui.custom("###dt_mem_hint", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
				dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x + dt_px(14), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.weak, "The charts fill as samples come: turn Live on, or use the page.")
			}, nil)
		}
	}
}

@(private = "file")
Tile_Draw :: struct { title, value, delta: string, series: []f32, hot, up: bool }

// A bordered tile in the Setup dialog's language: a square frame, the title, the number, a chart of its history.
@(private = "file")
tile_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Tile_Draw)(user)
	r := b.rect
	draw.rect(dc, r, dtc.bar)
	if d.hot { draw.rect(dc, r, dtc.hover) }
	draw.rect(dc, r, dtc.border, 0, dtm.line)
	draw.rect(dc, {r.min, {r.min.x + dtm.line * 3, r.max.y}}, dtc.accent)
	x := r.min.x + dt_px(12)
	dt_text(dc, dtm.ui_font, dtm.fs, x, r.min.y + dt_px(14), dtc.weak, d.title)
	dt_text(dc, dtm.ui_font, dtm.fs * 1.7, x, r.min.y + dt_px(38), dtc.text, d.value)
	if d.delta != "" { dt_text(dc, dtm.ui_font, dtm.fs * 0.9, x, r.min.y + dt_px(56), d.up ? dtc.warn : dtc.good, d.delta, r.max.x - x - dt_px(8)) }
	// the chart
	n := len(d.series)
	if n < 2 { return }
	cx0, cx1 := r.max.x - dt_px(120), r.max.x - dt_px(10)
	cy0, cy1 := r.min.y + dt_px(12), r.max.y - dt_px(14)
	lo, hi := d.series[0], d.series[0]
	for v in d.series { lo, hi = min(lo, v), max(hi, v) }
	if hi - lo < max(hi * 0.02, 1) { lo = max(hi - max(hi * 0.2, 1), 0) }
	// the curve, one column of pixels at a time: a faint area under it, a line on top
	cols := int((cx1 - cx0) / max(dtm.line, 1))
	px := dtm.line
	prev_y: f32 = -1
	for c in 0 ..< cols {
		pos := f32(c) / f32(max(cols - 1, 1)) * f32(n - 1)
		i0 := int(pos)
		i1 := min(i0 + 1, n - 1)
		v := d.series[i0] + (d.series[i1] - d.series[i0]) * (pos - f32(i0))
		cxp := cx0 + f32(c) * px
		y := cy1 - (v - lo) / (hi - lo) * (cy1 - cy0)
		draw.rect(dc, {{cxp, y}, {cxp + px, cy1}}, with_alpha(dtc.accent, 0.12))
		top := prev_y < 0 ? y : min(y, prev_y)
		bot := prev_y < 0 ? y : max(y, prev_y)
		draw.rect(dc, {{cxp, top - px}, {cxp + px, bot + px}}, with_alpha(dtc.accent, 0.95))
		prev_y = y
	}
}
_ :: strings
