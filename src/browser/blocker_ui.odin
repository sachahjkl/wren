package browser

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:ui"
import "wb:adblock"
import "wb:blocker"
import "wb:i18n"

// The blocker's icon at the end of the address row and its panel. The icon is a shield drawn from rectangles (no glyph
// in the icon font): green when the page is filtered, grey when the blocker or this site is off, amber while only the
// built-in list is loaded. The badge counts the page's blocked requests. The panel is a dense tool: the power switch of
// the site, counters, a graph of the blocks over the page's load, the per-site switches, the matrix of the page's
// hosts by type (a click on a cell blocks, allows or resets that host and type) and the tools.

Shield_State :: enum u8 { Off, Site_Off, Active, Loading, Idle }

Shield_Draw :: struct {
	app:   ^App,
	state: Shield_State,
	count: int,
	hot:   bool,
}

SHIELD_GREEN :: draw.Color{0.20, 0.66, 0.38, 1}
SHIELD_AMBER :: draw.Color{0.93, 0.62, 0.12, 1}
SHIELD_GREY  :: draw.Color{0.55, 0.57, 0.62, 1}
BLOCK_RED    :: draw.Color{0.86, 0.25, 0.22, 1}

@(private = "file")
shield_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Shield_Draw)(user)
	r := b.rect
	c := draw.rect_center(r)
	h := (r.max.y - r.min.y) * 0.60
	w := h * 0.86
	top := c.y - h * 0.52
	col: draw.Color
	switch d.state {
	case .Active: col = SHIELD_GREEN
	case .Loading: col = SHIELD_AMBER
	case .Off, .Site_Off, .Idle: col = SHIELD_GREY
	}
	fill := col
	if d.state == .Site_Off || d.state == .Off { fill.a = 0.55 }
	// the body: a rectangle with rounded top corners over a diamond that makes the point
	body_h := h * 0.58
	draw.rect_corners(dc, {{c.x - w * 0.5, top}, {c.x + w * 0.5, top + body_h}}, {fill, fill, fill, fill}, {w * 0.16, w * 0.16, 0, 0})
	side := w * 0.5 / 1.41421356
	dc_pivot := draw.Vec2{c.x, top + body_h}
	draw.push_transform(dc, draw.affine_around(draw.affine_rotate(math.PI / 4), dc_pivot))
	draw.rect(dc, {{dc_pivot.x - side, dc_pivot.y - side}, {dc_pivot.x + side, dc_pivot.y + side}}, fill, side * 0.12)
	draw.pop_transform(dc)
	ink := ui.color("background")
	ink.a = 1
	stroke := max(w * 0.11, 1.5)
	#partial switch d.state {
	case .Active:
		// a check mark
		p := draw.Vec2{c.x - w * 0.02, top + h * 0.56}
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(math.PI / 4), p))
		draw.rect(dc, {{p.x - stroke * 0.5, p.y - w * 0.22}, {p.x + stroke * 0.5, p.y + stroke * 0.5}}, ink, stroke * 0.3)
		draw.pop_transform(dc)
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(-math.PI / 4), p))
		draw.rect(dc, {{p.x - stroke * 0.5, p.y - w * 0.34}, {p.x + stroke * 0.5, p.y + stroke * 0.5}}, ink, stroke * 0.3)
		draw.pop_transform(dc)
	case .Site_Off, .Off:
		// a slash across the shield
		p := draw.Vec2{c.x, top + h * 0.5}
		line := ui.color("text")
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(-math.PI / 4), p))
		draw.rect(dc, {{p.x - stroke * 0.5, p.y - h * 0.58}, {p.x + stroke * 0.5, p.y + h * 0.58}}, line, stroke * 0.4)
		draw.pop_transform(dc)
	}
	// the badge
	if d.count > 0 && bl.b.cfg.badge {
		text := d.count > 999 ? "999+" : fmt.tprintf("%d", d.count)
		size := ui.font_size() * 0.68
		m := font.metrics(&d.app.fonts, d.app.ui_font, size)
		tw := font.text_width(&d.app.fonts, d.app.ui_font, size, text)
		pad := size * 0.32
		bw, bh := tw + pad * 2, m.ascent - m.descent + pad * 0.6
		right, bottom := r.max.x - 1, r.max.y - (r.max.y - r.min.y) * 0.08
		br := draw.Rect{{right - bw, bottom - bh}, {right, bottom}}
		draw.rect(dc, br, BLOCK_RED, bh * 0.5)
		pen := draw.Vec2{br.min.x + pad, br.min.y + (bh - (m.ascent - m.descent)) * 0.5 + m.ascent}
		draw.text(dc, d.app.ui_font, size, pen, draw.Color{1, 1, 1, 1}, text)
	}
}

// What the icon shows for the tab.
blocker_shield :: proc(app: ^App, t: ^Tab) -> (state: Shield_State, count: int, total_rules: int) {
	if !bl.started || !bl.b.cfg.enabled { return .Off, 0, 0 }
	if bl.b.engine != nil { total_rules = bl.b.engine.rules }
	host, ok := blocker_page_host(t)
	if !ok { return .Idle, 0, total_rules }
	if ts := blocker_tab(t); ts != nil { count = ts.blocked }
	if !blocker_site_enabled(host) { return .Site_Off, count, total_rules }
	if total_rules < 1000 { return .Loading, count, total_rules }
	return .Active, count, total_rules
}

blocker_button :: proc(app: ^App, t: ^Tab) {
	if !bl.started { return }
	em := ui.font_size()
	state, count, _ := blocker_shield(app, t)
	if !bl.b.conf.first_run && state != .Off {
		bl.b.conf.first_run = true
		blocker.conf_save(&bl.b)
		ui.toast(.Info, i18n.tr("Content blocker is on: the filter lists are downloading. The shield at the end of the address bar opens its panel; about:blocker customizes everything."))
	}
	d := ui.frame_new(Shield_Draw)
	d.app, d.state, d.count = app, state, count
	ui.next({width = ui.px(em * 2.3), height = ui.px(ui.dense(em * 2)), radius = em * CHROME_BUTTON_RADIUS})
	ui.push_tags("icon_button")
	b := ui.custom("###blocker_icon", shield_draw, d, {.Clickable, .Draw_Background, .Draw_Hot_Effects})
	ui.pop_tags()
	sig := ui.signal(b)
	key := ui.key_from_string(b.parent.key, "###blocker_panel")
	if blocker_panel_request { blocker_panel_request = false; if !ui.ctx_menu_is_open(key) { ui.ctx_menu_open_rect(key, b.rect, b.key) } }
	if sig.clicked {
		if ui.ctx_menu_is_open(key) { ui.ctx_menu_close() } else { ui.ctx_menu_open_rect(key, b.rect, b.key) }
	}
	tip_text: string
	switch state {
	case .Off: tip_text = i18n.tr("Content blocker: off (blocker.enabled)")
	case .Site_Off: tip_text = fmt.tprintf(i18n.tr("Content blocker: off on this site\n%d blocked on this page before it was switched off"), count)
	case .Idle: tip_text = i18n.tr("Content blocker: not applicable to this page")
	case .Loading: tip_text = fmt.tprintf(i18n.tr("Content blocker: base list only, the filter lists are not loaded yet\n%d blocked on this page"), count)
	case .Active: tip_text = fmt.tprintf(i18n.tr("this page, then all pages", "%d blocked on this page (%d in all)"), count, bl.b.totals.blocked)
	}
	tip(sig, tip_text)
	// the popup is built where the button is, so its position follows the row
	blocker_panel(app, t, key, state)
}

blocker_panel_request: bool

////////////////////////////////
// The panel

PANEL_W_EM :: f32(37)

@(private = "file")
Panel_State :: struct {
	rules_sorted: []blocker.Dyn_Rule,
}

@(private = "file")
panel: Panel_State

tid :: proc(text, id: string) -> string { return fmt.aprintf("%s###%s", text, id, allocator = ui.frame_allocator()) }

@(private = "file")
stat_pair :: proc(value, label, id: string, w: f32) {
	em := ui.font_size()
	ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2.5))})
	if ui.column(.Center) {
		ui.next({width = ui.pct(1), height = ui.px(ui.dense(em * 1.4)), text_align = ui.Text_Align.Center, font_size = em * 1.25})
		ui.label(fmt.aprintf("%s###sv_%s", value, id, allocator = ui.frame_allocator()))
		if ui.tags("weak") {
			ui.next({width = ui.pct(1), height = ui.px(ui.dense(em * 1.1)), text_align = ui.Text_Align.Center, font_size = em * 0.8})
			ui.label(fmt.aprintf("%s###sl_%s", label, id, allocator = ui.frame_allocator()))
		}
	}
}

@(private = "file")
small_button :: proc(text, id: string, w: f32, tip_text := "") -> bool {
	em := ui.font_size()
	ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 1.9)), radius = em * 0.35})
	sig := ui.button(fmt.aprintf("%s###%s", text, id, allocator = ui.frame_allocator()))
	if tip_text != "" { tip(sig, tip_text) }
	return sig.clicked
}

// Time graph: blocked requests during the page's load, as bars.
Graph_Draw :: struct { points: []u32, span_ms: u32, color, track: draw.Color }

@(private = "file")
graph_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	g := (^Graph_Draw)(user)
	r := b.rect
	draw.rect(dc, r, g.track, 3)
	if len(g.points) == 0 || g.span_ms == 0 { return }
	N :: 48
	bins: [N]int
	most := 1
	for p in g.points {
		i := min(int(u64(p) * N / u64(g.span_ms + 1)), N - 1)
		bins[i] += 1
		most = max(most, bins[i])
	}
	w := (r.max.x - r.min.x - 4) / N
	for i in 0 ..< N {
		if bins[i] == 0 { continue }
		hh := (r.max.y - r.min.y - 6) * f32(bins[i]) / f32(most)
		x := r.min.x + 2 + w * f32(i)
		draw.rect(dc, {{x + 0.5, r.max.y - 3 - hh}, {x + w - 0.5, r.max.y - 3}}, g.color, 1)
	}
}

// The matrix's columns: a kind of the dynamic rules and the request types it counts.
@(private = "file")
Column :: struct { label: string, kind: blocker.Dyn_Type, types: adblock.Resource_Set }

@(private = "file")
COLUMNS := [?]Column{
	{"*", .All, {}}, {"css", .Css, {.Stylesheet}}, {"img", .Image, {.Image}}, {"media", .Media, {.Media}}, {"font", .Font, {.Font}},
	{"script", .Script, {.Script}}, {"xhr", .Xhr, {.Xhr, .Ping, .Websocket}}, {"frame", .Frame, {.Subdocument, .Document}}, {"other", .Other, {.Other, .Object, .Csp_Report, .Webrtc, .Popup}},
}

@(private = "file")
cell_counts :: proc(row: ^blocker.Host_Row, c: Column) -> (allowed, blocked: u32) {
	if c.kind == .All {
		for r in adblock.Resource { allowed += row.cells[r].allowed; blocked += row.cells[r].blocked }
		return
	}
	for r in adblock.Resource {
		if r in c.types { allowed += row.cells[r].allowed; blocked += row.cells[r].blocked }
	}
	return
}

@(private = "file")
matrix_view :: proc(app: ^App, t: ^Tab, ts: ^blocker.Tab_State, page_host, src: string, w: f32) {
	em := ui.font_size()
	host_w := em * 10.2
	cell_w := (w - host_w - em * 1.2) / f32(len(COLUMNS))
	// header
	ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 1.5))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.6))
		if ui.tags("weak") {
			ui.next({width = ui.px(host_w), height = ui.pct(1), font_size = em * 0.8})
			ui.label(tid(i18n.tr("hosts"), "mx_h"))
			for c in COLUMNS {
				ui.next({width = ui.px(cell_w), height = ui.pct(1), text_align = ui.Text_Align.Center, font_size = em * 0.8})
				ui.label(fmt.aprintf("%s###mxh_%s", c.label, c.label, allocator = ui.frame_allocator()))
			}
		}
	}
	rows := make([dynamic]^blocker.Host_Row, context.temp_allocator)
	for r in ts.order { append(&rows, r) }
	slice.sort_by(rows[:], proc(a, b: ^blocker.Host_Row) -> bool {
		if a.third_party != b.third_party { return a.third_party }
		ab, bb := 0, 0
		for r in adblock.Resource { ab += int(a.cells[r].blocked); bb += int(b.cells[r].blocked) }
		if ab != bb { return ab > bb }
		return a.host < b.host
	})
	shown := min(len(rows), 9)
	ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 1.55 * f32(max(min(len(rows), 8), 2))))})
	if ui.scroll_y("###mx_scroll") {
		for r in rows {
			ui.next({width = ui.px(w - em * 0.6), height = ui.px(ui.dense(em * 1.55))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.6))
				ui.next({width = ui.px(host_w), height = ui.pct(1), font_size = em * 0.9})
				host_label := r.host
				if len(host_label) > 26 { host_label = strings.concatenate({"…", host_label[len(host_label) - 25:]}, context.temp_allocator) }
				if r.third_party {
					if ui.tags("weak") { ui.label(fmt.aprintf("%s###mxr_%s", host_label, r.host, allocator = ui.frame_allocator())) }
				} else {
					ui.label(fmt.aprintf("%s###mxr_%s", host_label, r.host, allocator = ui.frame_allocator()))
				}
				for c, ci in COLUMNS {
					allowed, blocked := cell_counts(r, c)
					rule := blocker.dyn_get(&bl.b.dyn, src, r.host, c.kind)
					rule_g := blocker.dyn_get(&bl.b.dyn, "*", r.host, c.kind)
					eff := rule != .Noop ? rule : rule_g
					bg := draw.Color{0, 0, 0, 0}
					switch {
					case eff == .Block: bg = {BLOCK_RED.r, BLOCK_RED.g, BLOCK_RED.b, 0.42}
					case eff == .Allow: bg = {SHIELD_GREEN.r, SHIELD_GREEN.g, SHIELD_GREEN.b, 0.40}
					case blocked > 0: bg = {BLOCK_RED.r, BLOCK_RED.g, BLOCK_RED.b, 0.16}
					}
					text := "·"
					if blocked > 0 { text = fmt.tprintf("%d", blocked) } else if allowed > 0 { text = fmt.tprintf("%d", allowed) }
					ui.next({width = ui.px(cell_w - 2), height = ui.px(ui.dense(em * 1.35)), radius = em * 0.25, bg = bg, font_size = em * 0.82, text_align = ui.Text_Align.Center})
					sig := ui.button(fmt.aprintf("%s###mxc_%s_%d", text, r.host, ci, allocator = ui.frame_allocator()))
					if sig.clicked {
						// this site's rule: none -> block -> allow -> none (shift: the same for every site)
						scope_src := (sig.mods & {.Shift}) != {} || bl.panel_scope_global ? "*" : src
						cur := blocker.dyn_get(&bl.b.dyn, scope_src, r.host, c.kind)
						next: blocker.Dyn_Action
						switch cur { case .Noop: next = .Block; case .Block: next = .Allow; case .Allow: next = .Noop }
						blocker.dyn_set(&bl.b.dyn, scope_src, r.host, c.kind, next)
						blocker_rules_changed(app, t)
					}
					tip(sig, fmt.tprintf(i18n.tr("host, request type, party, blocked, allowed, site", "%s → %s (%s)\n%d blocked, %d allowed\nClick: block, allow, then reset for %s. Shift+click: the same for all sites."), r.host, c.label, r.third_party ? i18n.tr("third party") : i18n.tr("first party"), blocked, allowed, src))
				}
			}
		}
		if len(rows) == 0 {
			ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 1.6))})
			if ui.row(.Center) { ui.spacer(ui.px(em * 0.8)); if ui.tags("weak") { ui.label(tid(i18n.tr("No request yet."), "mx_none")) } }
		}
	}
	_ = shown
	_ = page_host
}

// A rule changed: the engine's decisions for the page change, the page is loaded again to apply them.
blocker_rules_changed :: proc(app: ^App, t: ^Tab) {
	bl.b.dyn.version += 1
	blocker.conf_save(&bl.b)
	blocker.touch(&bl.b)
	bl.b.conf_ver += 1
	bl.reload_pending = true
}

blocker_panel :: proc(app: ^App, t: ^Tab, key: ui.Key, state: Shield_State) {
	em := ui.font_size()
	w := em * PANEL_W_EM
	if !ui.ctx_menu(key, w) {
		if bl.reload_pending && t != nil { bl.reload_pending = false; reload(app, t) }
		return
	}
	host, has_host := blocker_page_host(t)
	ts := blocker_tab(t)
	site_key := has_host ? blocker_site_key(host) : ""
	enabled_site := has_host && blocker_site_enabled(host)

	// header: the power button and the site
	ui.spacer(ui.px(em * 0.5))
	ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 3.2))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.8))
		pd := ui.frame_new(Shield_Draw)
		pd.app, pd.state, pd.count = app, state, 0
		ui.next({width = ui.px(em * 3), height = ui.px(ui.dense(em * 3)), radius = em * 1.5})
		ui.push_tags("icon_button")
		pb := ui.custom("###bl_power", shield_draw, pd, {.Clickable, .Draw_Background, .Draw_Hot_Effects})
		ui.pop_tags()
		psig := ui.signal(pb)
		tip(psig, has_host ? (enabled_site ? i18n.tr("Turn the blocker off for this site (the page reloads)") : i18n.tr("Turn the blocker on for this site (the page reloads)")) : i18n.tr("Not applicable to this page"))
		if psig.clicked && has_host { blocker_set_site_enabled(app, t, host, !enabled_site); ui.ctx_menu_close() }
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.pct(1)})
		if ui.column(.Center) {
			ui.next({width = ui.pct(1), height = ui.px(ui.dense(em * 1.5)), font_size = em * 1.1})
			ui.label(fmt.aprintf("%s###bl_host", has_host ? host : i18n.tr("No site"), allocator = ui.frame_allocator()))
			if ui.tags("weak") {
				status := i18n.tr("Filtering is on for this site")
				switch {
				case !bl.b.cfg.enabled: status = i18n.tr("The blocker is off (blocker.enabled)")
				case !has_host: status = i18n.tr("This page is not filtered")
				case !enabled_site: status = i18n.tr("Filtering is off on this site")
				case state == .Loading: status = i18n.tr("Base list only: the lists are downloading")
				}
				ui.next({width = ui.pct(1), height = ui.px(ui.dense(em * 1.2)), font_size = em * 0.85})
				ui.label(fmt.aprintf("%s###bl_status", status, allocator = ui.frame_allocator()))
			}
		}
		ui.spacer(ui.px(em * 0.8))
	}
	ui.hline(ui.px(w))

	// counters
	page_blocked, page_total, hosts_n := 0, 0, 0
	if ts != nil { page_blocked, page_total, hosts_n = ts.blocked, ts.blocked + ts.allowed, len(ts.order) }
	pct := page_total > 0 ? 100 * page_blocked / page_total : 0
	ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2.5))})
	if ui.row(.Center) {
		stat_pair(fmt.tprintf("%d", page_blocked), i18n.tr("blocked on this page"), "pb", w * 0.28)
		stat_pair(fmt.tprintf("%d %%", pct), i18n.tr("of its requests"), "pp", w * 0.2)
		stat_pair(fmt.tprintf("%d", hosts_n), i18n.tr("hosts"), "ph", w * 0.16)
		stat_pair(fmt.tprintf("%d", bl.b.totals.blocked), i18n.tr("blocked in all"), "pt", w * 0.28)
	}
	// graph
	if ts != nil {
		g := ui.frame_new(Graph_Draw)
		g.points = ts.points[:]
		span := u32(0)
		if len(ts.points) > 0 { span = ts.points[len(ts.points) - 1] }
		g.span_ms = max(span, 500)
		g.color = {BLOCK_RED.r, BLOCK_RED.g, BLOCK_RED.b, 0.85}
		g.track = ui.color("hover_fill")
		ui.next({width = ui.px(w - em * 1.2), height = ui.px(ui.dense(em * 2.4))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.px(w - em * 1.2), height = ui.pct(1)})
			ui.custom("###bl_graph", graph_draw, g)
		}
	}
	ui.spacer(ui.px(em * 0.3))
	ui.hline(ui.px(w))

	// the site's switches
	if has_host {
		flags := blocker.site_flags(&bl.b, site_key)
		cosmetic := .No_Cosmetic not_in flags
		scriptlets := .No_Scriptlets not_in flags
		fonts := blocker.effective_fonts_of(&bl.b, flags)
		media := .Block_Media in flags
		hard := blocker.effective_hard_of(&bl.b, flags)
		ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 1.75))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.6))
			half := (w - em * 1.2) * 0.5
			ui.next({width = ui.px(half), height = ui.pct(1)})
			if ui.toggle("###sw_cos", i18n.tr("Element hiding"), &cosmetic).clicked { blocker.site_toggle(&bl.b, site_key, .No_Cosmetic, !cosmetic); blocker_apply_site(app, t) }
			ui.next({width = ui.px(half), height = ui.pct(1)})
			if ui.toggle("###sw_scr", i18n.tr("Scriptlets"), &scriptlets).clicked { blocker.site_toggle(&bl.b, site_key, .No_Scriptlets, !scriptlets); blocker_apply_site(app, t) }
		}
		ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 1.75))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.6))
			third := (w - em * 1.2) / 3
			ui.next({width = ui.px(third), height = ui.pct(1)})
			if ui.toggle("###sw_fnt", i18n.tr("Block remote fonts"), &fonts).clicked {
				blocker.site_toggle(&bl.b, site_key, .Block_Fonts, fonts)
				blocker.site_toggle(&bl.b, site_key, .Allow_Fonts, !fonts)
				blocker_apply_site(app, t)
			}
			ui.next({width = ui.px(third), height = ui.pct(1)})
			if ui.toggle("###sw_med", i18n.tr("Block large media"), &media).clicked { blocker.site_toggle(&bl.b, site_key, .Block_Media, media); blocker_apply_site(app, t) }
			ui.next({width = ui.px(third), height = ui.pct(1)})
			if ui.toggle("###sw_hard", i18n.tr("Hard mode"), &hard).clicked {
				blocker.site_toggle(&bl.b, site_key, .Hard, hard)
				blocker.site_toggle(&bl.b, site_key, .Soft, !hard)
				blocker_apply_site(app, t)
			}
		}
		ui.hline(ui.px(w))
	}

	// the matrix
	if ts != nil && has_host {
		ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 1.6))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.px(em * 12), height = ui.pct(1)})
			if ui.tags("weak") { ui.label(tid(i18n.tr("Matrix: click a cell"), "mx_title")) }
			ui.next({width = ui.fill(), height = ui.pct(1)})
			ui.spacer(ui.fill())
			ui.next({width = ui.px(em * 11), height = ui.px(ui.dense(em * 1.5))})
			ui.toggle("###mx_global", i18n.tr("All sites"), &bl.panel_scope_global)
			ui.spacer(ui.px(em * 0.6))
		}
		matrix_view(app, t, ts, host, site_key, w)
		ui.hline(ui.px(w))
	}

	// the tools
	ui.spacer(ui.px(em * 0.3))
	ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2.1))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.6))
		bw := (w - em * 1.2 - em * 0.4 * 3) / 4
		if ui.disabled(!has_host || !enabled_site) {
			if small_button(i18n.tr("Pick element"), "tl_pick", bw, i18n.tr("Aim at an element of the page and block it")) { blocker_picker_begin(app, t); ui.ctx_menu_close() }
		}
		ui.spacer(ui.px(em * 0.4))
		if small_button(i18n.tr("Log"), "tl_log", bw, i18n.tr("The request log")) { blocker_open_dashboard(app, "journal"); ui.ctx_menu_close() }
		ui.spacer(ui.px(em * 0.4))
		if small_button(i18n.tr("Dashboard"), "tl_dash", bw, i18n.tr("Lists, rules, filters, statistics")) { blocker_open_dashboard(app); ui.ctx_menu_close() }
		ui.spacer(ui.px(em * 0.4))
		if small_button(i18n.tr("Reload"), "tl_reload", bw, i18n.tr("Load the page again")) { if t != nil { reload(app, t) }; ui.ctx_menu_close() }
	}
	ui.spacer(ui.px(em * 0.5))
}

// Switches that change what the document does: the page loads again so that they apply from its first byte.
blocker_apply_site :: proc(app: ^App, t: ^Tab) {
	bl.reload_pending = true
}

_ :: strings
