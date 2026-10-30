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
	if t.kind == .Blocker { return {"Blocker", "weak", t.status} }
	if t.kind == .Downloads { return {"Downloads", "weak", t.status} }
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
			// (the window's own: with one for all, two windows with other statuses asked each other for a frame, for ever)
			ws := window_own(app)
			if b.size.x != ws.status_left_width { ws.status_left_width = b.size.x; request_frames(app, 2) }
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
			// the tab's own log (what the Network tab lists): its requests, sockets and streams, and those still going
			n, pending := len(t.net.entries), t.net.pending
			word := n == 1 ? "request" : "requests"
			text := pending > 0 ? fmt.tprintf("%s %s, %d pending", fmt_count(n), word, pending) : fmt.tprintf("%s %s", fmt_count(n), word)
			add(&items, {kind = item, text = text, short = fmt.tprintf("%s req.", fmt_count(n)),
				id = "###sb_req", tone = pending > 0 ? "" : "weak", tip = cache_requests_tip(t), priority = 60})
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
	pacer := pacer_of(app)
	em := ui.font_size()
	n := &hud.nums
	c := hud.cfg.comma
	if remote_indicator() {
		tip(ui.status_item(fmt.tprintf("%s###sb_remote", remote_indicator_text()), tone = "warn"), remote_indicator_tip())
		ui.spacer(ui.px(em * 0.3))
	}
	for m in hud.cfg.metrics {
		switch m {
		case .Graph:
			colors := hud_series_colors()
			ui.next({width = ui.px(em * hud.cfg.graph_em), height = ui.px(ui.dense(em * 1.25))})
			flat := transmute([len(Hud_Series)]draw.Color)colors
			budget := hud_budget(app)
			opts := ui.Frame_Graph_Opts{
				colors = flat[:], series = len(Hud_Series), bars = hud.cfg.samples, budget = hud.cfg.budget_line ? budget : 0,
				scale = hud.cfg.scale > 0 ? hud.cfg.scale : budget, max_scale = hud.cfg.max_scale, warn = hud_warn(app), bad = hud_bad(app),
			}
			res := ui.frame_graph("###sb_graph", &hud.history, opts)
			graph_box = res.box
			if res.clicked { hud.panel_open = !hud.panel_open }
			if res.hovered >= 0 { graph_tooltip(app, res.hovered, colors) } else { tip(res.sig, "Time of the recent frames by phase: click for details (Ctrl+Shift+B)") }
			ui.spacer(ui.px(em * 0.3))
		case .Fps:
			tip(ui.status_item(fmt.tprintf("%.0f fps###sb_fps", n.fps), mono = true), fmt.tprintf("Frames drawn per second (last %.0f ms). Nothing changes: no frames. The screen this window is on: %s Hz%s (frames aim for %s Hz).", hud.cfg.window_ms, fmt_hz(pacer.display.hz, c), pacer.display.max_hz > pacer.display.hz * 1.05 ? fmt.tprintf(", up to %s Hz%s", fmt_hz(pacer.display.max_hz, c), pacer.variable ? ": variable refresh, frames timed by the browser" : "") : "", fmt_hz(pacer.hz, c)))
		case .Cpu:
			text := n.frames > 0 ? fmt.tprintf("CPU %s ms###sb_cpu", fmt_ms(n.cpu_mean, c)) : "CPU -- ms###sb_cpu"
			tone := "weak"
			if bad := hud_bad(app); bad > 0 && n.cpu_mean > bad { tone = "bad" } else if warn := hud_warn(app); warn > 0 && n.cpu_mean > warn { tone = "warn" }
			tip(ui.status_item(text, tone = tone, mono = true), fmt.tprintf("Work of the browser per frame, mean (waiting for the screen not counted). Budget %s ms (%s Hz)", fmt_ms(hud_budget(app), c), fmt_hz(pacer.hz, c)))
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
graph_tooltip :: proc(app: ^App, index: int, colors: [Hud_Series]draw.Color) {
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
		bad, warn := hud_bad(app), hud_warn(app)
		tone := bad > 0 && total > bad ? "bad" : warn > 0 && total > warn ? "warn" : ""
		ui.stat_row("tt_cpu", "CPU total", fmt.tprintf("%s ms", fmt_ms(total, c)), w, tone = tone)
		// the three rows are always there ("--" when the frame had none): a row that came and went as the pointer crossed the bars of a
		// graph where some frames restyle and others do not made the tooltip jump in height under it
		restyle, lay_pass, wasm := "--", "--", "--"
		if d := &hud.details[s.tag % u64(len(hud.details))]; d.serial == s.tag {
			if d.restyle != .None { restyle = restyle_text(d) }
			if d.lay_pass != .None { lay_pass = pass_name(d.lay_pass) }
			if d.wasm_calls > 0 { wasm = fmt.tprintf("%s ms, %d calls", fmt_ms(d.wasm_ms, c), d.wasm_calls) }
		}
		ui.stat_row("tt_rs", "Restyle", restyle, w, mono = false)
		ui.stat_row("tt_lp", "Layout pass", lay_pass, w, mono = false)
		ui.stat_row("tt_wasm", "WebAssembly", wasm, w)
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

// What a value reads while there is none (a step that did not run, a number not measured yet).
STAT_NONE :: "\u2014"

// A line of the panel: a section's heading, or a label and its value.
Stat_Line :: struct {
	id, label, value: string,
	heading: bool,
	mono:    bool,
	tone:    string,       // tags of the value ("", "warn", "bad")
	swatch:  draw.Color,   // not zero: a legend's colour before the label
}

// Everything the panel shows, read from the browser once per build (frame_stats_source): the lines are made from it
// alone (panel_lines), so the same sections always have the same lines, whatever is measured or not at the moment.
Panel_Source :: struct {
	n:            Hud_Numbers,
	comma:        bool,
	budget:       f32,
	pacer:        Pacer,
	no_tearing:   bool,                 // tearing asked for, not supported
	gpu_timing:   bool,
	measured_hz:  f64,
	shown_total, missed_total: u64,
	colors:       [Hud_Series]draw.Color,
	restyle:      Frame_Detail, has_restyle: bool,   // the last frame that restyled
	layout:       Frame_Detail, has_layout: bool,    // ... that laid out
	comp:         Frame_Detail, has_comp: bool,      // ... that composited the page
	gpu_have:     bool,
	gpu_last:     render.Gpu_Profile,
	gpu_cache:    draw.Layer_Cache_Stats,
	wasm_modules: int,
	wasm_timing:  bool,
	wasm_compiler: string,
	tex:          render.Texture_Memory,
	pic_used, pic_capacity: int,
	images:       page.Image_Stats,
}

frame_stats_source :: proc(app: ^App, t: ^Tab) -> (s: Panel_Source) {
	s.n = hud.nums
	s.comma = hud.cfg.comma
	s.budget = s.n.budget > 0 ? s.n.budget : hud_budget(app)
	s.pacer = pacer_of(app)^
	s.no_tearing = app.pacing.cfg.mode == .Tearing && !s.pacer.tearing
	s.gpu_timing = render.gpu_timing_enabled(&app.r)
	s.measured_hz = render.measured_refresh_hz(&app.r)
	_, s.shown_total, s.missed_total = render.present_totals(&app.r)
	s.colors = hud_series_colors()
	if d := recent_detail(proc(d: ^Frame_Detail) -> bool { return d.restyle != .None }); d != nil { s.restyle, s.has_restyle = d^, true }
	if d := recent_detail(proc(d: ^Frame_Detail) -> bool { return d.lay_pass != .None }); d != nil { s.layout, s.has_layout = d^, true }
	if d := recent_detail(proc(d: ^Frame_Detail) -> bool { return d.comp_valid }); d != nil { s.comp, s.has_comp = d^, true }
	s.gpu_have, s.gpu_last, s.gpu_cache = gpu_steps_state.have, gpu_steps_state.last, gpu_steps_state.cache
	s.wasm_modules = t != nil && t.page != nil ? len(t.page.instances) : 0
	s.wasm_timing = hud.cfg.wasm_timing
	s.wasm_compiler = config.string_of(&app.prefs, "wasm.wasmtime.compiler")
	s.tex = render.texture_memory(&app.r)
	s.pic_used, s.pic_capacity = draw.retained_bytes(&app.dc)
	s.images = page.images_stats(t != nil ? t.page : nil)
	return
}

// The panel's sections in `ncols` columns.
frame_stats_layout :: proc(ncols: int) -> [][]Panel_Section {
	// (about as many lines in each column: the panel is as tall as its longest)
	@(static, rodata) three := [][]Panel_Section{{.Frames, .Display, .Style, .Wasm}, {.Gpu_Steps, .Memory}, {.Phases, .Layout, .Compositor, .Build}}
	@(static, rodata) two := [][]Panel_Section{{.Frames, .Display, .Phases, .Style, .Layout}, {.Compositor, .Gpu_Steps, .Wasm, .Memory, .Build}}
	@(static, rodata) one := [][]Panel_Section{{.Frames, .Display, .Phases, .Style, .Layout, .Compositor, .Gpu_Steps, .Wasm, .Memory, .Build}}
	switch ncols {
	case 3: return three
	case 2: return two
	}
	return one
}

// Columns of label / value rows above the graph, in the status bar's text size: three when the window is wide enough,
// else two, else one. Its size and place never follow what is measured: every section always has the same lines (a
// value not measured or a step that did not run reads STAT_NONE), the columns have a fixed width and the values are
// in figures of one width.
frame_stats_panel :: proc(app: ^App, t: ^Tab, anchor: draw.Rect) {
	em0 := ui.font_size()
	if ui.style({font_size = f32(int(em0 * 0.88 + 0.5))}) {
		em := ui.font_size()
		n := &hud.nums
		col := em * 17
		gap := em * 0.6
		ncols := clamp(int((f32(active_window(app).win.size.x) - em) / (col + gap)), 1, 3)
		w := col * f32(ncols) + gap * f32(ncols - 1)
		src := frame_stats_source(app, t)
		// against the window's right edge, not the graph's: the counters right of the graph change width with their
		// numbers, and the panel moved with them
		at := draw.Rect{{0, anchor.min.y}, {f32(active_window(app).win.size.x) - em * 0.5, anchor.max.y}}
		if ui.popover(PANEL_ID, at, w, .Above, align_right = true) {
			ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2.1))})
			if ui.row(.Center, {}, "###fs_head") {
				ui.spacer(ui.px(em * 0.9))
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				what := n.frames > 0 ? fmt.tprintf("last %s s, %d frames", fmt_ms(f32(hud.cfg.window_ms / 1000), src.comma), n.frames) : "idle: no frames drawn lately"
				ui.label(fmt.tprintf("Frame statistics, %s###fs_title", what))
				ui.next({width = ui.px(em * 1.9), height = ui.px(em * 1.9), radius = em * CHROME_BUTTON_RADIUS})
				close := ui.icon_button("###fs_close", GLYPH_CLOSE)
				tip(close, "Close (Ctrl+Shift+B)")
				if close.clicked { hud.panel_open = false }
				ui.spacer(ui.px(em * 0.4))
			}
			ui.hline(ui.px(w))
			frame_stats_columns(&src, frame_stats_layout(ncols), col, gap)
			ui.spacer(ui.px(em * 0.5))
		}
	}
}

// The columns of the panel (its body); returns their row.
frame_stats_columns :: proc(src: ^Panel_Source, layout: [][]Panel_Section, col, gap: f32) -> ^ui.Box {
	w := col * f32(len(layout)) + gap * f32(max(len(layout) - 1, 0))
	ui.next({width = ui.px(w), height = ui.children_sum()})
	box: ^ui.Box
	if ui.row(.Start, {}, "###fs_cols") {
		box = ui.parent_box()
		for sections, i in layout {
			if i > 0 { ui.spacer(ui.px(gap)) }
			ui.next({width = ui.px(col), height = ui.children_sum()})
			if ui.column(.Start, {}, fmt.tprintf("###fs_col%d", i)) {
				for s in sections {
					for l in panel_lines(src, s) {
						if l.heading { ui.stat_heading(l.id, l.label, col); continue }
						ui.stat_row(l.id, l.label, l.value, col, mono = l.mono, swatch_color = l.swatch, tone = l.tone)
					}
				}
			}
		}
	}
	return box
}

// The lines of a section (temp): always the same ids in the same order for a section, whatever `src` holds.
panel_lines :: proc(src: ^Panel_Source, section: Panel_Section) -> []Stat_Line {
	out := make([dynamic]Stat_Line, context.temp_allocator)
	head :: proc(out: ^[dynamic]Stat_Line, id, text: string) { append(out, Stat_Line{id = id, label = text, heading = true}) }
	row :: proc(out: ^[dynamic]Stat_Line, id, label, value: string, mono := true, tone := "", swatch := draw.Color{}) {
		append(out, Stat_Line{id = id, label = label, value = value, mono = mono, tone = tone, swatch = swatch})
	}
	n := &src.n
	c := src.comma
	pacer := &src.pacer
	switch section {
	case .Frames:
		budget := src.budget
		head(&out, "frames", "FRAMES: MEAN / P95 / P99")
		row(&out, "fps", "Per second", fmt.tprintf("%.0f of %s", n.fps, fmt_hz(pacer.hz, c)))
		bt := fmt.tprintf("%.2f", budget)
		row(&out, "budget", "Budget ms", c ? decimal_comma(bt) : bt)
		row(&out, "cpu", "CPU ms", n.frames > 0 ? fmt.tprintf("%s / %s / %s", fmt_ms(n.cpu_mean, c), fmt_ms(n.cpu_p95, c), fmt_ms(n.cpu_p99, c)) : STAT_NONE,
			tone = n.frames > 0 && n.cpu_p99 > budget ? "warn" : "")
		gpu := "not measured"
		if src.gpu_timing { gpu = n.gpu_n > 0 ? fmt.tprintf("%s / %s / %s", fmt_ms(n.gpu_mean, c), fmt_ms(n.gpu_p95, c), fmt_ms(n.gpu_p99, c)) : STAT_NONE }
		row(&out, "gpu", "GPU ms", gpu, tone = n.gpu_n > 0 && n.gpu_p99 > budget ? "warn" : "")
		row(&out, "max", "Longest, CPU / GPU", n.frames > 0 ? fmt.tprintf("%s / %s", fmt_ms(n.cpu_max, c), n.gpu_n > 0 ? fmt_ms(n.gpu_max, c) : STAT_NONE) : STAT_NONE)
		row(&out, "over", "Over budget", fmt.tprintf("%d + %d of %d", n.over, n.gpu_over, n.frames), tone = n.over + n.gpu_over > 0 ? "warn" : "")
		row(&out, "missed", "Missed refreshes", n.shown > 0 ? fmt.tprintf("%d of %d", n.missed, n.shown) : STAT_NONE, tone = n.missed > 0 ? "bad" : "")
		row(&out, "lat", "Input to screen", n.lat_n > 0 ? fmt.tprintf("%s / %s ms", fmt_ms(n.lat_mean, c), fmt_ms(n.lat_p95, c)) : STAT_NONE)
	case .Display:
		head(&out, "display", "DISPLAY")
		d := pacer.display
		src_name := "default"
		switch d.source {
		case .Display_Config: src_name = "exact"
		case .Mode:           src_name = "mode"
		case .Dwm:            src_name = "DWM"
		case .Default:        src_name = "assumed"
		}
		row(&out, "d_hz", "Monitor", fmt.tprintf("%s Hz (%s)", fmt_hz(d.hz, c), src_name))
		row(&out, "d_max", "Top mode", fmt.tprintf("%s Hz%s", fmt_hz(d.max_hz, c), pacer.variable ? ", variable" : ""), mono = false)
		row(&out, "d_live", "Compositor now", pacer.live_hz > 0 ? fmt.tprintf("%s Hz", fmt_hz(pacer.live_hz, c)) : STAT_NONE)
		row(&out, "d_meas", "Measured vblanks", src.measured_hz > 0 ? fmt.tprintf("%s Hz", fmt_hz(src.measured_hz, c)) : STAT_NONE)
		how := pacer.timed ? "timed" : pacer.interval > 1 ? fmt.tprintf("every %d refreshes", pacer.interval) : "every refresh"
		row(&out, "d_target", "Target", fmt.tprintf("%s Hz, %s", fmt_hz(pacer.hz, c), how), mono = false)
		mode := pacer.tearing ? "tearing (variable refresh)" : "vsync"
		if src.no_tearing { mode = "vsync (no tearing support)" }
		row(&out, "d_mode", "Present", mode, mono = false)
		row(&out, "d_tot", "Shown / missed, total", fmt.tprintf("%d / %d", src.shown_total, src.missed_total))
	case .Phases:
		head(&out, "phases", "PHASES, MEAN MS")
		for k in Hud_Series {
			row(&out, fmt.tprintf("ph_%d", int(k)), fmt.tprintf("%s (%s)", HUD_SERIES_NAMES[k], HUD_SERIES_HELP[k]), fmt_ms(n.series[k], c), swatch = src.colors[k])
		}
	case .Style:
		head(&out, "style", "STYLE")
		row(&out, "rs_last", "Last", src.has_restyle ? restyle_text(&src.restyle) : "none", mono = false)
		row(&out, "rs_count", "Full / partial", fmt.tprintf("%d / %d", n.full_restyles, n.partial_restyles))
	case .Layout:
		head(&out, "layout", "LAYOUT")
		d := &src.layout
		total: f32
		for s in d.lay_steps { total += s }
		row(&out, "lp_last", src.has_layout ? fmt.tprintf("Last, %s", pass_name(d.lay_pass)) : "Last", src.has_layout ? fmt.tprintf("%s ms", fmt_ms(total, c)) : "none")
		for name, i in ([5]string{"box tree", "layout", "finishing", "display list", "bands"}) {
			row(&out, fmt.tprintf("lp_s%d", i), fmt.tprintf("  %s", name), src.has_layout && d.lay_steps[i] >= 0.01 ? fmt_ms(d.lay_steps[i], c) : STAT_NONE)
		}
		row(&out, "lp_size", "Boxes / items", src.has_layout ? fmt.tprintf("%s / %s", fmt_count(int(d.lay_boxes)), fmt_count(int(d.lay_items))) : STAT_NONE)
		row(&out, "lp_pre", "Ahead / taken", src.has_layout && d.lay_pass == .Full ? fmt.tprintf("%d / %d", d.lay_pre[0], d.lay_pre[1]) : STAT_NONE)
		row(&out, "lp_count", "Full / incr. / refresh", fmt.tprintf("%d / %d / %d", n.passes[.Full], n.passes[.Incremental], n.passes[.Refresh]))
	case .Compositor:
		head(&out, "comp", "COMPOSITOR, LAST FRAME")
		cs := src.comp.comp
		has := src.has_comp
		row(&out, "cp_chunks", "Pictures / visible", has ? fmt.tprintf("%d / %d", cs.chunks, cs.visible) : "page not drawn", mono = has)
		row(&out, "cp_replay", "Replayed / recorded", has ? fmt.tprintf("%d / %d", cs.replayed, cs.recorded) : STAT_NONE)
		row(&out, "cp_slots", "Slots / direct items", has ? fmt.tprintf("%d / %d", cs.slots_set, cs.immediate_items) : STAT_NONE)
	case .Gpu_Steps: panel_gpu_steps(&out, src)
	case .Wasm:
		head(&out, "wasm", "WEBASSEMBLY")
		row(&out, "w_mods", "Modules", fmt.tprintf("%d", src.wasm_modules))
		row(&out, "w_time", "In calls, ms / frame", src.wasm_timing ? fmt_ms(n.wasm_mean, c) : "not measured")
		row(&out, "w_engine", "Wasmtime", fmt.tprintf("%s, %s", wasm.WASMTIME_VERSION, src.wasm_compiler), mono = false)
	case .Memory:
		head(&out, "mem", "MEMORY")
		row(&out, "m_ws", "Working set", n.mem_valid ? fmt_bytes(n.working_set, c) : STAT_NONE)
		row(&out, "m_priv", "Private", n.mem_valid ? fmt_bytes(n.private_bytes, c) : STAT_NONE)
		row(&out, "m_tex", "GPU images", fmt_bytes(src.tex.images, c))
		row(&out, "m_gly", "Glyphs, layers", fmt.tprintf("%s, %s", fmt_bytes(src.tex.glyphs, c), fmt_bytes(src.tex.targets, c)))
		row(&out, "m_pic", "Pictures", fmt.tprintf("%s of %s", fmt_bytes(src.pic_used, c), fmt_bytes(src.pic_capacity, c)))
		row(&out, "m_img", fmt.tprintf("Image cache (%d)", src.images.entries), fmt.tprintf("%s of %s", fmt_bytes(src.images.bytes, c), fmt_bytes(src.images.limit, c)))
	case .Build:
		head(&out, "build", "BUILD")
		row(&out, "b_ver", "Version", APP_VERSION_SHOWN)
		row(&out, "b_commit", "Commit", APP_COMMIT_DATE != "" ? fmt.tprintf("%s, %s", app_commit(), APP_COMMIT_DATE) : app_commit())
		row(&out, "b_kind", "Build", build_description(), mono = false)
		row(&out, "b_tk", "Toolkit", ui.VERSION)
		row(&out, "b_odin", "Odin", ODIN_VERSION)
	}
	return out[:]
}

// Ctrl+B / Ctrl+Shift+B, and the View menu.
toggle_status_bar :: proc(app: ^App) {
	set_pref_bool(app, "browser.status_bar.visible", !hud.cfg.bar_visible)
}

toggle_frame_stats :: proc(app: ^App) {
	hud.panel_open = !hud.panel_open || !hud.cfg.bar_visible
	if hud.panel_open && !hud.cfg.bar_visible { set_pref_bool(app, "browser.status_bar.visible", true) }
	request_frames(app, 2)
}

set_pref_bool :: proc(app: ^App, name: string, v: bool) {
	if err := config.set_bool(&app.prefs, config.ref_of(&app.prefs, name), v); err != .None {
		ui.toast(.Warn, "%s: %s", name, config.set_error_text(err))
	}
}

set_pref_int :: proc(app: ^App, name: string, v: int) {
	if err := config.set_int(&app.prefs, config.ref_of(&app.prefs, name), i64(v)); err != .None {
		ui.toast(.Warn, "%s: %s", name, config.set_error_text(err))
	}
}

// The panel takes the clicks and the wheel that land on it (the page under it does not get them).
hud_captures :: proc(app: ^App, pos: draw.Vec2) -> bool {
	if fullscreen_bars_capture(app, pos) { return true }   // and so do the bars of full screen (window_chrome.odin)
	if devtools_captures(pos) { return true }   // the floating developer tools (devtools.odin)
	if palette_captures(pos) { return true }   // and the command palette while it is open (palette.odin)
	if setup_captures() { return true }   // and the Setup dialog (setup.odin)
	if urlbar_captures(app, pos) { return true }   // and the address bar's suggestions (urlbar.odin)
	if !hud.panel_open { return false }
	r, ok := ui.popover_rect(PANEL_ID)
	return ok && draw.rect_contains(r, pos)
}
