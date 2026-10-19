package browser

// The status bar along the bottom of the window (browser.status_bar.*): on the left what the page is doing (loading,
// HTTP status, size, origin, requests, cookies, DOM nodes, modules, zoom), or where the link under the pointer goes; on
// the right the graph of the recent frames by phase (hud.odin) and compact counters. A click on the graph opens the
// frame statistics panel above it. Ctrl+B shows / hides the bar, Ctrl+Shift+B the panel.

import "core:fmt"
import "toolkit:draw"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:cookies"
import "wb:fetch"
import lay "wb:layout"
import "wb:page"
import "wb:url"
import "wb:wasm"

PANEL_ID :: "###frame_stats"

// Colors of the graph's phases: browser.status_bar.graph.colors, else from the theme (and hues that read on both dark
// and light palettes for the phases the theme has no color for).
hud_series_colors :: proc() -> (c: [Hud_Series]draw.Color) {
	themed :: proc(tag: string) -> draw.Color {
		col: draw.Color
		if ui.tags(tag) { col = ui.color("text") }
		return col
	}
	c[.Tasks] = themed("warn")
	c[.Styles] = draw.hex(0xa78bfaff)
	c[.Layout] = draw.hex(0xec6fc0ff)
	c[.Paint] = themed("good")
	c[.UI] = ui.color("accent")
	c[.Submit] = themed("weak")
	c[.GPU] = draw.hex(0x38bdf8ff)
	for k in Hud_Series { if v, ok := hud.cfg.colors[k].?; ok { c[k] = v } }
	return
}

// Where the link under the pointer goes ("" when the pointer is on no link).
hovered_link :: proc(t: ^Tab) -> string {
	if t == nil || t.page == nil || t.kind != .Web { return "" }
	h := t.page.style_state.hover
	if h == base.NIL_HANDLE { return "" }
	href, ok := anchor_href(t.page.doc, h)
	if !ok { return "" }
	r, rok := url.parse(href, &t.page.env.location, context.temp_allocator)
	return rok ? r.href : href
}

Page_State :: struct { text, tone, detail: string }

// The first item of the bar: what the tab is doing.
page_state :: proc(t: ^Tab) -> Page_State {
	if t == nil { return {} }
	if t.kind == .Config { return {"Settings", "weak", t.status} }
	load := t.load
	if load != nil && load.task != base.NIL_HANDLE { return {t.page == nil ? "Connecting..." : "Loading...", "", t.status} }
	if load != nil {
		for s in load.slots { if s.state == .Pending { return {"Loading modules...", "", t.status} } }
	}
	if t.page == nil { return {} }
	switch t.page.env.location.scheme {
	case "about": return {t.title == "Error" ? "Error" : "Built-in page", t.title == "Error" ? "bad" : "weak", t.status}
	case "file":  return {"File", "weak", t.status}
	}
	if load != nil && load.status > 0 {
		tone := load.status < 300 ? "good" : load.status < 400 ? "weak" : "bad"
		return {fmt.tprintf("HTTP %d", load.status), tone, t.status}
	}
	if t.title == "Error" { return {"Failed", "bad", t.status} }
	return {"Done", "weak", t.status}
}

status_bar_build :: proc(app: ^App, t: ^Tab) {
	if !hud.cfg.bar_visible { hud.panel_open = false; return }
	hud_mono(app)
	graph_box: ^ui.Box
	if ui.status_bar("###statusbar") {
		if ui.status_fill("###sb_left") {
			link := hud.cfg.link_preview ? hovered_link(t) : ""
			if link != "" {
				ui.status_item(fmt.tprintf("%s###sb_link", link), tone = "", width = ui.fill())
			} else if t != nil {
				status_left(app, t)
			}
		}
		graph_box = status_right(app)
	}
	if hud.panel_open && graph_box != nil { frame_stats_panel(app, t, graph_box.rect) }
}

@(private = "file")
status_left :: proc(app: ^App, t: ^Tab) {
	first := true
	sep :: proc(first: ^bool) { if !first^ { ui.status_separator() }; first^ = false }
	p := t.page
	for item in hud.cfg.items {
		switch item {
		case .State:
			st := page_state(t)
			if st.text == "" { continue }
			sep(&first)
			sig := ui.status_item(fmt.tprintf("%s###sb_state", st.text), tone = st.tone)
			if st.detail != "" && st.detail != st.text { tip(sig, st.detail) }
		case .Size:
			if t.load == nil || t.load.bytes <= 0 { continue }
			sep(&first)
			ui.status_item(fmt.tprintf("%s###sb_size", fmt_bytes(t.load.bytes, hud.cfg.comma)))
		case .Origin:
			if p == nil || p.env.location.scheme == "about" { continue }
			o := url.origin_serialize(p.env.origin, context.temp_allocator)
			if o == "null" { continue }   // an opaque origin (file:, data:): the state item says what it is
			sep(&first)
			ui.status_item(fmt.tprintf("%s###sb_origin", o))
		case .Requests:
			n := fetch.in_flight(&app.loader)
			sep(&first)
			ui.status_item(fmt.tprintf("%s request%s###sb_req", fmt_count(n), n == 1 ? "" : "s"), tone = n > 0 ? "" : "weak")
		case .Cookies:
			if p == nil || p.env.location.host == "" { continue }
			n := cookies.count_for_host(&app.profile.jar, p.env.location.host)
			sep(&first)
			tip(ui.status_item(fmt.tprintf("%s cookie%s###sb_cookies", fmt_count(n), n == 1 ? "" : "s")), fmt.tprintf("Cookies of %s", p.env.location.host))
		case .Nodes:
			if p == nil { continue }
			sep(&first)
			ui.status_item(fmt.tprintf("%s nodes###sb_nodes", fmt_count(p.doc.nodes.count)))
		case .Modules:
			if p == nil || len(p.instances) == 0 { continue }
			sep(&first)
			ui.status_item(fmt.tprintf("%d module%s###sb_mods", len(p.instances), len(p.instances) == 1 ? "" : "s"))
		case .Zoom:
			if zoom_percent(t) == 100 { continue }
			sep(&first)
			z := ui.status_item(fmt.tprintf("%d %%###sb_zoom", zoom_percent(t)), tone = "", clickable = true)
			tip(z, "Page zoom: click to reset (Ctrl+0)")
			if z.clicked { zoom_set(app, t, 1) }
		}
	}
}

// The graph and the counters; returns the graph's box (nil when not shown).
@(private = "file")
status_right :: proc(app: ^App) -> (graph_box: ^ui.Box) {
	em := ui.font_size()
	n := &hud.nums
	c := hud.cfg.comma
	for m in hud.cfg.metrics {
		switch m {
		case .Graph:
			colors := hud_series_colors()
			ui.next({width = ui.px(em * hud.cfg.graph_em), height = ui.px(ui.dense(em * 1.25))})
			flat := transmute([len(Hud_Series)]draw.Color)colors
			opts := ui.Frame_Graph_Opts{
				colors = flat[:], series = len(Hud_Series), bars = hud.cfg.samples, budget = hud.cfg.budget,
				scale = hud.cfg.scale, max_scale = hud.cfg.max_scale, warn = hud.cfg.warn, bad = hud.cfg.bad,
			}
			res := ui.frame_graph("###sb_graph", &hud.history, opts)
			graph_box = res.box
			if res.clicked { hud.panel_open = !hud.panel_open }
			if res.hovered >= 0 { graph_tooltip(res.hovered, colors) } else { tip(res.sig, "Time of the recent frames by phase: click for details (Ctrl+Shift+B)") }
			ui.spacer(ui.px(em * 0.3))
		case .Fps:
			tip(ui.status_item(fmt.tprintf("%.0f fps###sb_fps", n.fps), mono = true), fmt.tprintf("Frames drawn per second (last %.0f ms). Nothing changes: no frames.", hud.cfg.window_ms))
		case .Cpu:
			text := n.frames > 0 ? fmt.tprintf("CPU %s ms###sb_cpu", fmt_ms(n.cpu_mean, c)) : "CPU -- ms###sb_cpu"
			tone := "weak"
			if hud.cfg.bad > 0 && n.cpu_mean > hud.cfg.bad { tone = "bad" } else if hud.cfg.warn > 0 && n.cpu_mean > hud.cfg.warn { tone = "warn" }
			tip(ui.status_item(text, tone = tone, mono = true), "Work of the browser per frame, mean (waiting for the screen not counted)")
		case .Gpu:
			text := "GPU n/a###sb_gpu"
			if render.gpu_timing_enabled(&app.r) { text = n.gpu_n > 0 ? fmt.tprintf("GPU %s ms###sb_gpu", fmt_ms(n.gpu_mean, c)) : "GPU -- ms###sb_gpu" }
			tip(ui.status_item(text, mono = true), render.gpu_timing_enabled(&app.r) ? "GPU time of the frame's drawing, mean" : "GPU time not measured (browser.status_bar.gpu_timing)")
		case .Memory:
			if !n.mem_valid { continue }
			tip(ui.status_item(fmt.tprintf("%s###sb_mem", fmt_bytes(n.working_set, c)), mono = true), fmt.tprintf("Memory of the process: working set (private %s)", fmt_bytes(n.private_bytes, c)))
		}
	}
	return
}

// The values of one frame of the graph, next to the pointer.
@(private = "file")
graph_tooltip :: proc(index: int, colors: [Hud_Series]draw.Color) {
	s := ui.history_at(&hud.history, index)
	if s == nil { return }
	em := ui.font_size()
	c := hud.cfg.comma
	w := em * 15
	if ui.tooltip() {
		ago := ui.now_ms() - s.t_ms
		ui.stat_heading("tt_head", fmt.tprintf("Frame %d, %s s ago", s.tag, fmt_ms(f32(ago / 1000), c)), w)
		for k in Hud_Series {
			v := s.v[k]
			value := fmt_ms(v, c)
			if k == .GPU && v <= 0 { value = "--" }
			ui.stat_row(fmt.tprintf("tt_%d", int(k)), HUD_SERIES_NAMES[k], value, w, swatch_color = colors[k])
		}
		total := ui.sample_total(s, CPU_SERIES)
		tone := hud.cfg.bad > 0 && total > hud.cfg.bad ? "bad" : hud.cfg.warn > 0 && total > hud.cfg.warn ? "warn" : ""
		ui.stat_row("tt_cpu", "CPU total", fmt.tprintf("%s ms", fmt_ms(total, c)), w, tone = tone)
		if d := &hud.details[s.tag % u64(len(hud.details))]; d.serial == s.tag {
			if d.restyle != .None { ui.stat_row("tt_rs", "Restyle", restyle_text(d), w, mono = false) }
			if d.lay_pass != .None { ui.stat_row("tt_lp", "Layout pass", pass_name(d.lay_pass), w, mono = false) }
			if d.wasm_calls > 0 { ui.stat_row("tt_wasm", "WebAssembly", fmt.tprintf("%s ms, %d calls", fmt_ms(d.wasm_ms, c), d.wasm_calls), w) }
		}
		ui.spacer(ui.px(em * 0.3))
	}
}

@(private = "file")
restyle_text :: proc(d: ^Frame_Detail) -> string {
	kind := d.restyle == .Full ? "full" : "partial"
	if d.restyled < 0 { return kind }
	return fmt.tprintf("%s, %s element%s", kind, fmt_count(int(d.restyled)), d.restyled == 1 ? "" : "s")
}

@(private = "file")
pass_name :: proc(k: lay.Pass_Kind) -> string {
	switch k {
	case .None: return "none"
	case .Full: return "full"
	case .Refresh: return "refresh"
	case .Incremental: return "incremental"
	}
	return ""
}

////////////////////////////////
// Frame statistics panel

// The most recent frame of the history whose detail satisfies `pick`.
@(private = "file")
recent_detail :: proc(pick: proc(d: ^Frame_Detail) -> bool) -> ^Frame_Detail {
	for i := ui.history_len(&hud.history) - 1; i >= 0; i -= 1 {
		s := ui.history_at(&hud.history, i)
		d := &hud.details[s.tag % u64(len(hud.details))]
		if d.serial == s.tag && pick(d) { return d }
	}
	return nil
}

Panel_Section :: enum u8 { Frames, Phases, Style, Layout, Compositor, Wasm, Memory, Build }

// Columns of label / value rows above the graph, in the status bar's text size: three when the window is wide enough,
// else two, else one.
frame_stats_panel :: proc(app: ^App, t: ^Tab, anchor: draw.Rect) {
	em0 := ui.font_size()
	if ui.style({font_size = f32(int(em0 * 0.88 + 0.5))}) {
		em := ui.font_size()
		n := &hud.nums
		c := hud.cfg.comma
		col := em * 17
		gap := em * 0.6
		ncols := clamp(int((f32(app.win.size.x) - em) / (col + gap)), 1, 3)
		w := col * f32(ncols) + gap * f32(ncols - 1)
		layout: [][]Panel_Section
		switch ncols {
		case 3: layout = {{.Frames, .Phases}, {.Style, .Layout, .Compositor}, {.Wasm, .Memory, .Build}}
		case 2: layout = {{.Frames, .Phases, .Style, .Layout}, {.Compositor, .Wasm, .Memory, .Build}}
		case:   layout = {{.Frames, .Phases, .Style, .Layout, .Compositor, .Wasm, .Memory, .Build}}
		}
		if ui.popover(PANEL_ID, anchor, w, .Above, align_right = true) {
			ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2.1))})
			if ui.row(.Center, {}, "###fs_head") {
				ui.spacer(ui.px(em * 0.9))
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				what := n.frames > 0 ? fmt.tprintf("last %s s, %d frames", fmt_ms(f32(hud.cfg.window_ms / 1000), c), n.frames) : "idle: no frames drawn lately"
				ui.label(fmt.tprintf("Frame statistics, %s###fs_title", what))
				ui.next({width = ui.px(em * 1.9), height = ui.px(em * 1.9)})
				close := ui.icon_button("###fs_close", GLYPH_CLOSE)
				tip(close, "Close (Ctrl+Shift+B)")
				if close.clicked { hud.panel_open = false }
				ui.spacer(ui.px(em * 0.4))
			}
			ui.hline(ui.px(w))
			ui.next({width = ui.px(w), height = ui.children_sum()})
			if ui.row(.Start, {}, "###fs_cols") {
				for sections, i in layout {
					if i > 0 { ui.spacer(ui.px(gap)) }
					ui.next({width = ui.px(col), height = ui.children_sum()})
					if ui.column(.Start, {}, fmt.tprintf("###fs_col%d", i)) {
						for s in sections { panel_section(app, t, s, col) }
					}
				}
			}
			ui.spacer(ui.px(em * 0.5))
		}
	}
}

@(private = "file")
panel_section :: proc(app: ^App, t: ^Tab, section: Panel_Section, w: f32) {
	n := &hud.nums
	c := hud.cfg.comma
	switch section {
	case .Frames:
		ui.stat_heading("frames", "FRAMES: MEAN / P95 / MAX", w)
		ui.stat_row("fps", "Per second", fmt.tprintf("%.0f", n.fps), w)
		ui.stat_row("cpu", "CPU ms", n.frames > 0 ? fmt.tprintf("%s / %s / %s", fmt_ms(n.cpu_mean, c), fmt_ms(n.cpu_p95, c), fmt_ms(n.cpu_max, c)) : "--", w)
		gpu := "not measured"
		if render.gpu_timing_enabled(&app.r) { gpu = n.gpu_n > 0 ? fmt.tprintf("%s / -- / %s", fmt_ms(n.gpu_mean, c), fmt_ms(n.gpu_max, c)) : "--" }
		ui.stat_row("gpu", "GPU ms", gpu, w)
		if hud.cfg.budget > 0 {
			ui.stat_row("over", fmt.tprintf("Over %s ms", fmt_ms(hud.cfg.budget, c)), fmt.tprintf("%d of %d", n.over, n.frames), w, tone = n.over > 0 ? "warn" : "")
		}
	case .Phases:
		colors := hud_series_colors()
		ui.stat_heading("phases", "PHASES, MEAN MS", w)
		for k in Hud_Series {
			ui.stat_row(fmt.tprintf("ph_%d", int(k)), fmt.tprintf("%s (%s)", HUD_SERIES_NAMES[k], HUD_SERIES_HELP[k]), fmt_ms(n.series[k], c), w, swatch_color = colors[k])
		}
	case .Style:
		ui.stat_heading("style", "STYLE", w)
		last := "none"
		if d := recent_detail(proc(d: ^Frame_Detail) -> bool { return d.restyle != .None }); d != nil { last = restyle_text(d) }
		ui.stat_row("rs_last", "Last", last, w, mono = false)
		ui.stat_row("rs_count", "Full / partial", fmt.tprintf("%d / %d", n.full_restyles, n.partial_restyles), w)
	case .Layout:
		ui.stat_heading("layout", "LAYOUT", w)
		if d := recent_detail(proc(d: ^Frame_Detail) -> bool { return d.lay_pass != .None }); d != nil {
			total: f32
			for s in d.lay_steps { total += s }
			ui.stat_row("lp_last", fmt.tprintf("Last, %s", pass_name(d.lay_pass)), fmt.tprintf("%s ms", fmt_ms(total, c)), w)
			for name, i in ([5]string{"box tree", "layout", "finishing", "display list", "bands"}) {
				if d.lay_steps[i] >= 0.01 { ui.stat_row(fmt.tprintf("lp_s%d", i), fmt.tprintf("  %s", name), fmt_ms(d.lay_steps[i], c), w) }
			}
			ui.stat_row("lp_size", "Boxes / items", fmt.tprintf("%s / %s", fmt_count(int(d.lay_boxes)), fmt_count(int(d.lay_items))), w)
			if d.lay_pass == .Full { ui.stat_row("lp_pre", "Ahead / taken", fmt.tprintf("%d / %d", d.lay_pre[0], d.lay_pre[1]), w) }
		} else {
			ui.stat_row("lp_last", "Last", "none", w, mono = false)
		}
		ui.stat_row("lp_count", "Full / incr. / refresh", fmt.tprintf("%d / %d / %d", n.passes[.Full], n.passes[.Incremental], n.passes[.Refresh]), w)
	case .Compositor:
		ui.stat_heading("comp", "COMPOSITOR, LAST FRAME", w)
		if d := recent_detail(proc(d: ^Frame_Detail) -> bool { return d.comp_valid }); d != nil {
			cs := d.comp
			ui.stat_row("cp_chunks", "Pictures / visible", fmt.tprintf("%d / %d", cs.chunks, cs.visible), w)
			ui.stat_row("cp_replay", "Replayed / recorded", fmt.tprintf("%d / %d", cs.replayed, cs.recorded), w)
			ui.stat_row("cp_slots", "Slots / direct items", fmt.tprintf("%d / %d", cs.slots_set, cs.immediate_items), w)
		} else {
			ui.stat_row("cp_none", "Page", "not drawn", w, mono = false)
		}
	case .Wasm:
		ui.stat_heading("wasm", "WEBASSEMBLY", w)
		mods := t != nil && t.page != nil ? len(t.page.instances) : 0
		ui.stat_row("w_mods", "Modules", fmt.tprintf("%d", mods), w)
		ui.stat_row("w_time", "In calls, ms / frame", hud.cfg.wasm_timing ? fmt_ms(n.wasm_mean, c) : "not measured", w)
		ui.stat_row("w_engine", "Wasmtime", fmt.tprintf("%s, %s", wasm.WASMTIME_VERSION, config.string_of(&app.prefs, "wasm.wasmtime.compiler")), w, mono = false)
	case .Memory:
		ui.stat_heading("mem", "MEMORY", w)
		if n.mem_valid {
			ui.stat_row("m_ws", "Working set", fmt_bytes(n.working_set, c), w)
			ui.stat_row("m_priv", "Private", fmt_bytes(n.private_bytes, c), w)
		}
		tm := render.texture_memory(&app.r)
		ui.stat_row("m_tex", "GPU images", fmt_bytes(tm.images, c), w)
		ui.stat_row("m_gly", "Glyphs, layers", fmt.tprintf("%s, %s", fmt_bytes(tm.glyphs, c), fmt_bytes(tm.targets, c)), w)
		used, capacity := draw.retained_bytes(&app.dc)
		ui.stat_row("m_pic", "Pictures", fmt.tprintf("%s of %s", fmt_bytes(used, c), fmt_bytes(capacity, c)), w)
		is := page.images_stats(t != nil ? t.page : nil)
		ui.stat_row("m_img", fmt.tprintf("Image cache (%d)", is.entries), fmt.tprintf("%s of %s", fmt_bytes(is.bytes, c), fmt_bytes(is.limit, c)), w)
	case .Build:
		ui.stat_heading("build", "BUILD", w)
		ui.stat_row("b_ver", "Version", APP_VERSION, w)
		ui.stat_row("b_commit", "Commit", APP_COMMIT_DATE != "" ? fmt.tprintf("%s, %s", app_commit(), APP_COMMIT_DATE) : app_commit(), w)
		ui.stat_row("b_kind", "Build", build_description(), w, mono = false)
		ui.stat_row("b_tk", "Toolkit", ui.VERSION, w)
		ui.stat_row("b_odin", "Odin", ODIN_VERSION, w)
	}
}

// Ctrl+B / Ctrl+Shift+B, and the View menu.
toggle_status_bar :: proc(app: ^App) {
	set_pref_bool(app, "browser.status_bar.visible", !hud.cfg.bar_visible)
}

toggle_frame_stats :: proc(app: ^App) {
	hud.panel_open = !hud.panel_open || !hud.cfg.bar_visible
	if hud.panel_open && !hud.cfg.bar_visible { set_pref_bool(app, "browser.status_bar.visible", true) }
	app.frames_requested = max(app.frames_requested, 2)
}

set_pref_bool :: proc(app: ^App, name: string, v: bool) {
	if err := config.set_bool(&app.prefs, config.ref_of(&app.prefs, name), v); err != .None {
		ui.toast(.Warn, "%s: %s", name, config.set_error_text(err))
	}
}

// The panel takes the clicks and the wheel that land on it (the page under it does not get them).
hud_captures :: proc(pos: draw.Vec2) -> bool {
	if !hud.panel_open { return false }
	r, ok := ui.popover_rect(PANEL_ID)
	return ok && draw.rect_contains(r, pos)
}
