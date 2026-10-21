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
	if load != nil && load.task != base.NIL_HANDLE { return {t.page == nil ? "Connecting…" : "Loading…", "", t.status} }
	if load != nil {
		for s in load.slots { if s.state == .Pending { return {"Loading modules…", "", t.status} } }
	}
	if t.page == nil { return {} }
	if load != nil && load.failed != .None { return {"Error", "bad", t.status} }   // an error page (error_pages.odin)
	switch t.page.env.location.scheme {
	case "about": return {"Built-in page", "weak", t.status}
	case "file":  return {"File", "weak", t.status}
	}
	if load != nil && load.status > 0 {
		tone := load.status < 300 ? "good" : load.status < 400 ? "weak" : "bad"
		return {fmt.tprintf("HTTP %d", load.status), tone, t.status}
	}
	return {"Done", "weak", t.status}
}

status_bar_build :: proc(app: ^App, t: ^Tab) {
	if !hud.cfg.bar_visible { hud.panel_open = false; return }
	hud_mono(app)
	graph_box: ^ui.Box
	if ui.status_bar("###statusbar") {
		// the room of the left part: its width as laid out in the frame before (a change draws one more frame)
		avail := max(f32)
		if b := ui.prev_box("###sb_left"); b != nil && b.size.x > 0 {
			avail = b.size.x
			if b.size.x != left_width_seen { left_width_seen = b.size.x; app.frames_requested = max(app.frames_requested, 2) }
		}
		if ui.status_fill("###sb_left") {
			link := hud.cfg.link_preview ? hovered_link(t) : ""
			if link != "" {
				ui.status_item(fmt.tprintf("%s###sb_link", link), tone = "", width = ui.fill())
			} else if t != nil {
				status_left(app, t, avail)
			}
		}
		graph_box = status_right(app)
	}
	if hud.panel_open && graph_box != nil { frame_stats_panel(app, t, graph_box.rect) }
}

// One item of the left part: its text, a shorter form for a narrow bar ("" = none), and how long it stays when the bar
// is too narrow for everything (higher stays longer).
Status_Left_Item :: struct {
	kind:     Status_Item,
	text:     string,
	short:    string,
	id:       string,
	tone:     string,
	tip:      string,
	priority: int,
	width:    f32,
	shown:    bool,
	cut:      f32,   // > 0: shown this wide, its text ending with "..." (the last resort)
}

// Which items of the left part fit `avail` (px), and in what form: first the short forms (lowest priority first), then
// items left out (lowest priority first, the page state never), then the last item shown cut with "...". Items
// never overlap the graph nor end mid-word against it. `measure` gives an item's width for a text.
status_left_fit :: proc(items: []Status_Left_Item, avail, sep_w: f32, measure: proc(text: string) -> f32) {
	total :: proc(items: []Status_Left_Item, sep_w: f32) -> f32 {
		w: f32
		n := 0
		for it in items { if it.shown { w += it.width; n += 1 } }
		return w + f32(max(n - 1, 0)) * sep_w
	}
	for &it in items { it.shown, it.width, it.cut = true, measure(it.text), 0 }
	if total(items, sep_w) <= avail { return }
	order := make([]int, len(items), context.temp_allocator)
	for i in 0 ..< len(items) { order[i] = i }
	// lowest priority first; equal priorities: the later item first
	for i in 1 ..< len(order) {
		for j := i; j > 0; j -= 1 {
			a, b := items[order[j - 1]], items[order[j]]
			if a.priority > b.priority || (a.priority == b.priority && order[j - 1] < order[j]) { order[j - 1], order[j] = order[j], order[j - 1] } else { break }
		}
	}
	for i in order {
		it := &items[i]
		if it.short == "" { continue }
		it.text, it.width = it.short, measure(it.short)
		if total(items, sep_w) <= avail { return }
	}
	for i in order {
		it := &items[i]
		if it.kind == .State { continue }
		it.shown = false
		if total(items, sep_w) <= avail { return }
	}
	// still too wide (a long page state): the last item shown takes what is left, cut
	for i := len(items) - 1; i >= 0; i -= 1 {
		if !items[i].shown { continue }
		rest := avail - (total(items, sep_w) - items[i].width)
		items[i].cut = max(rest, 1)
		break
	}
}

@(private = "file") left_width_seen: f32   // the left part's width in the frame before (to draw again when it changes)

@(private = "file")
status_left :: proc(app: ^App, t: ^Tab, avail: f32) {
	p := t.page
	items := make([dynamic]Status_Left_Item, 0, 8, context.temp_allocator)
	add :: proc(items: ^[dynamic]Status_Left_Item, it: Status_Left_Item) { append(items, it) }
	for item in hud.cfg.items {
		switch item {
		case .State:
			st := page_state(t)
			if st.text == "" { continue }
			add(&items, {kind = item, text = st.text, id = "###sb_state", tone = st.tone, tip = st.detail != st.text ? st.detail : "", priority = 100})
		case .Size:
			if t.load == nil || t.load.bytes <= 0 { continue }
			add(&items, {kind = item, text = fmt_bytes(t.load.bytes, hud.cfg.comma), id = "###sb_size", tone = "weak", tip = "Size of the document", priority = 50})
		case .Origin:
			if p == nil || p.env.location.scheme == "about" { continue }
			o := url.origin_serialize(p.env.origin, context.temp_allocator)
			if o == "null" { continue }   // an opaque origin (file:, data:): the state item says what it is
			short := p.env.location.host != "" && p.env.location.host != o ? p.env.location.host : ""
			add(&items, {kind = item, text = o, short = short, id = "###sb_origin", tone = "weak", tip = o, priority = 80})
		case .Requests:
			n := fetch.in_flight(&app.loader)
			add(&items, {kind = item, text = fmt.tprintf("%s request%s", fmt_count(n), n == 1 ? "" : "s"), short = fmt.tprintf("%s req.", fmt_count(n)),
				id = "###sb_req", tone = n > 0 ? "" : "weak", tip = "Requests in flight", priority = 60})
		case .Cookies:
			if p == nil || p.env.location.host == "" { continue }
			n := cookies.count_for_host(&app.profile.jar, p.env.location.host)
			add(&items, {kind = item, text = fmt.tprintf("%s cookie%s", fmt_count(n), n == 1 ? "" : "s"), short = fmt.tprintf("%s ck.", fmt_count(n)),
				id = "###sb_cookies", tone = "weak", tip = fmt.tprintf("Cookies of %s", p.env.location.host), priority = 30})
		case .Nodes:
			if p == nil { continue }
			add(&items, {kind = item, text = fmt.tprintf("%s nodes", fmt_count(p.doc.nodes.count)), short = fmt.tprintf("%s n.", fmt_count(p.doc.nodes.count)),
				id = "###sb_nodes", tone = "weak", tip = "Nodes of the document", priority = 40})
		case .Modules:
			if p == nil || len(p.instances) == 0 { continue }
			// the JavaScript realm is an instance of the engine module: shown as such, the page's own modules counted apart
			mods := len(p.instances)
			has_js := p.js != nil && p.js.inst != nil
			if has_js { mods -= 1 }
			if has_js {
				state := p.js.failed ? "JS stopped" : "JS"
				add(&items, {kind = item, text = state, short = state, id = "###sb_js", tone = p.js.failed ? "bad" : "weak",
					tip = p.js.failed ? "The page's JavaScript engine stopped (see the console)" : "This page runs JavaScript (in WebAssembly)", priority = 20})
			}
			if mods == 0 { continue }
			add(&items, {kind = item, text = fmt.tprintf("%d module%s", mods, mods == 1 ? "" : "s"), short = fmt.tprintf("%d mod.", mods),
				id = "###sb_mods", tone = "weak", tip = "WebAssembly modules of the page", priority = 20})
		case .Zoom:
			if zoom_percent(t) == 100 { continue }
			add(&items, {kind = item, text = fmt.tprintf("%d %%", zoom_percent(t)), id = "###sb_zoom", tone = "", tip = "Page zoom: click to reset (Ctrl+0)", priority = 90})
		}
	}
	em := ui.font_size()
	// as the bar lays its items out (ui.status_item): text plus 2 * (text_pad 0.35 em + padding 0.15 em), rounded up; a
	// separator 0.5 em + 1 px
	measure :: proc(text: string) -> f32 { size := ui.font_size(); return ui.text_width(ui.top_style().font, size, text) + size + 1 }
	status_left_fit(items[:], avail, em * 0.5 + max(1, ui.scale()), measure)
	first := true
	for it in items {
		if !it.shown { continue }
		if !first { ui.status_separator() }
		first = false
		width: Maybe(ui.Size) = it.cut > 0 ? ui.px(it.cut) : nil
		sig := ui.status_item(fmt.tprintf("%s%s", it.text, it.id), tone = it.tone, clickable = it.kind == .Zoom, width = width)
		if it.tip != "" { tip(sig, it.text != it.tip ? it.tip : it.text) }
		if it.kind == .Zoom && sig.clicked { zoom_set(app, t, 1) }
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
			budget := hud_budget()
			opts := ui.Frame_Graph_Opts{
				colors = flat[:], series = len(Hud_Series), bars = hud.cfg.samples, budget = hud.cfg.budget_line ? budget : 0,
				scale = hud.cfg.scale > 0 ? hud.cfg.scale : budget, max_scale = hud.cfg.max_scale, warn = hud_warn(), bad = hud_bad(),
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
			if bad := hud_bad(); bad > 0 && n.cpu_mean > bad { tone = "bad" } else if warn := hud_warn(); warn > 0 && n.cpu_mean > warn { tone = "warn" }
			tip(ui.status_item(text, tone = tone, mono = true), fmt.tprintf("Work of the browser per frame, mean (waiting for the screen not counted). Budget %s ms (%s Hz)", fmt_ms(hud_budget(), c), fmt_hz(pacer.hz, c)))
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
		bad, warn := hud_bad(), hud_warn()
		tone := bad > 0 && total > bad ? "bad" : warn > 0 && total > warn ? "warn" : ""
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

Panel_Section :: enum u8 { Frames, Display, Phases, Style, Layout, Compositor, Gpu_Steps, Wasm, Memory, Build }

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
		case 3: layout = {{.Frames, .Display, .Gpu_Steps}, {.Phases, .Style, .Layout}, {.Compositor, .Wasm, .Memory, .Build}}
		case 2: layout = {{.Frames, .Display, .Phases, .Style}, {.Layout, .Compositor, .Gpu_Steps, .Wasm, .Memory, .Build}}
		case:   layout = {{.Frames, .Display, .Phases, .Style, .Layout, .Compositor, .Gpu_Steps, .Wasm, .Memory, .Build}}
		}
		if ui.popover(PANEL_ID, anchor, w, .Above, align_right = true) {
			ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2.1))})
			if ui.row(.Center, {}, "###fs_head") {
				ui.spacer(ui.px(em * 0.9))
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				what := n.frames > 0 ? fmt.tprintf("last %s s, %d frames", fmt_ms(f32(hud.cfg.window_ms / 1000), c), n.frames) : "idle: no frames drawn lately"
				ui.label(fmt.tprintf("Frame statistics, %s###fs_title", what))
				ui.next({width = ui.px(em * 1.9), height = ui.px(em * 1.9), radius = em * CHROME_BUTTON_RADIUS})
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
		budget := n.budget > 0 ? n.budget : hud_budget()
		ui.stat_heading("frames", "FRAMES: MEAN / P95 / P99", w)
		ui.stat_row("fps", "Per second", fmt.tprintf("%.0f of %s", n.fps, fmt_hz(pacer.hz, c)), w)
		bt := fmt.tprintf("%.2f", budget)
		ui.stat_row("budget", "Budget ms", c ? decimal_comma(bt) : bt, w)
		ui.stat_row("cpu", "CPU ms", n.frames > 0 ? fmt.tprintf("%s / %s / %s", fmt_ms(n.cpu_mean, c), fmt_ms(n.cpu_p95, c), fmt_ms(n.cpu_p99, c)) : "--", w,
			tone = n.frames > 0 && n.cpu_p99 > budget ? "warn" : "")
		gpu := "not measured"
		if render.gpu_timing_enabled(&app.r) { gpu = n.gpu_n > 0 ? fmt.tprintf("%s / %s / %s", fmt_ms(n.gpu_mean, c), fmt_ms(n.gpu_p95, c), fmt_ms(n.gpu_p99, c)) : "--" }
		ui.stat_row("gpu", "GPU ms", gpu, w, tone = n.gpu_n > 0 && n.gpu_p99 > budget ? "warn" : "")
		ui.stat_row("max", "Longest, CPU / GPU", n.frames > 0 ? fmt.tprintf("%s / %s", fmt_ms(n.cpu_max, c), n.gpu_n > 0 ? fmt_ms(n.gpu_max, c) : "--") : "--", w)
		ui.stat_row("over", "Over budget", fmt.tprintf("%d + %d of %d", n.over, n.gpu_over, n.frames), w, tone = n.over + n.gpu_over > 0 ? "warn" : "")
		ui.stat_row("missed", "Missed refreshes", n.shown > 0 ? fmt.tprintf("%d of %d", n.missed, n.shown) : "--", w, tone = n.missed > 0 ? "bad" : "")
		ui.stat_row("lat", "Input to screen", n.lat_n > 0 ? fmt.tprintf("%s / %s ms", fmt_ms(n.lat_mean, c), fmt_ms(n.lat_p95, c)) : "--", w)
	case .Display:
		ui.stat_heading("display", "DISPLAY", w)
		d := pacer.display
		src := "default"
		switch d.source {
		case .Display_Config: src = "exact"
		case .Mode:           src = "mode"
		case .Dwm:            src = "DWM"
		case .Default:        src = "assumed"
		}
		ui.stat_row("d_hz", "Monitor", fmt.tprintf("%s Hz (%s)", fmt_hz(d.hz, c), src), w)
		measured := render.measured_refresh_hz(&app.r)
		ui.stat_row("d_meas", "Measured vblanks", measured > 0 ? fmt.tprintf("%s Hz", fmt_hz(measured, c)) : "--", w)
		how := pacer.timed ? "timed" : pacer.interval > 1 ? fmt.tprintf("every %d refreshes", pacer.interval) : "every refresh"
		ui.stat_row("d_target", "Target", fmt.tprintf("%s Hz, %s", fmt_hz(pacer.hz, c), how), w, mono = false)
		mode := pacer.tearing ? "tearing (variable refresh)" : "vsync"
		if pacer.cfg.mode == .Tearing && !pacer.tearing { mode = "vsync (no tearing support)" }
		ui.stat_row("d_mode", "Present", mode, w, mono = false)
		_, shown_total, missed_total := render.present_totals(&app.r)
		ui.stat_row("d_tot", "Shown / missed, total", fmt.tprintf("%d / %d", shown_total, missed_total), w)
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
	case .Gpu_Steps: panel_gpu_steps(app, w)
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
	if fullscreen_bars_capture(pos) { return true }   // and so do the bars of full screen (window_chrome.odin)
	if !hud.panel_open { return false }
	r, ok := ui.popover_rect(PANEL_ID)
	return ok && draw.rect_contains(r, pos)
}
