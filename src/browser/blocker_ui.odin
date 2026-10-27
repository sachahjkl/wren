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
	app:     ^App,
	state:   Shield_State,
	count:   int,
	color:   draw.Color,   // the state's tone, from the theme
	ink:     draw.Color,   // what is drawn on the filled shield (the window's background)
	badge:   draw.Color,   // the badge's fill: the theme's accent (a count of what was stopped is good news, not an alert)
	badge_ink: draw.Color,
	focus:   draw.Color,
	radius:  f32,
}

// The tones of the blocker (the shield, the matrix, the journal) are the theme's own: the colors the security chip and the toasts
// use for good, warn, bad and weak. Read once per frame, where the interface is built (tags are a build-time scope).
SHIELD_GREEN := draw.Color{0.20, 0.66, 0.38, 1}
SHIELD_AMBER := draw.Color{0.93, 0.62, 0.12, 1}
SHIELD_GREY  := draw.Color{0.55, 0.57, 0.62, 1}
BLOCK_RED    := draw.Color{0.86, 0.25, 0.22, 1}

@(private = "file")
tone_color :: proc(tag: string) -> draw.Color {
	c := ui.color("text")
	if ui.tags(tag) { c = ui.color("text") }
	return c
}

blocker_theme :: proc() {
	SHIELD_GREEN, SHIELD_AMBER, SHIELD_GREY, BLOCK_RED = tone_color("good"), tone_color("warn"), tone_color("weak"), tone_color("bad")
}

@(private = "file")
luma :: proc(c: draw.Color) -> f32 { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

@(private = "file")
shield_look :: proc(d: ^Shield_Draw, app: ^App, state: Shield_State, count: int) {
	d.app, d.state, d.count = app, state, count
	switch state {
	case .Active: d.color = SHIELD_GREEN
	case .Loading: d.color = SHIELD_AMBER
	case .Off, .Site_Off, .Idle: d.color = SHIELD_GREY
	}
	d.ink = ui.color("background")
	d.ink.a = 1
	d.badge = ui.color("accent")
	d.badge.a = 1
	light := ui.color("text")
	light.a = 1
	d.badge_ink = abs(luma(d.badge) - luma(d.ink)) > abs(luma(d.badge) - luma(light)) ? d.ink : light
	d.focus = ui.color("accent")
	d.radius = ui.font_size() * CHROME_BUTTON_RADIUS
}

// The outline of a shield in a box of `w` by `h` centered on `c`: a crest that falls to rounded shoulders, straight sides, and
// two curves that meet in a sharp tip. Symmetric; 58 points, clockwise on the screen. Built from cubic curves in a unit box
// (u across -1..1, v down 0..1).
SHIELD_MAX :: 64

@(private = "file")
shield_points :: proc(pts: ^[SHIELD_MAX]draw.Vec2, c: draw.Vec2, w, h: f32) -> int {
	half: [SHIELD_MAX / 2]draw.Vec2
	n := 0
	curve :: proc(out: []draw.Vec2, n: ^int, p0, p1, p2, p3: draw.Vec2, steps: int, first: bool) {
		for i in (first ? 0 : 1) ..= steps {
			t := f32(i) / f32(steps)
			u := 1 - t
			out[n^] = p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
			n^ += 1
		}
	}
	curve(half[:], &n, {0, 0}, {0.30, 0.10}, {0.62, 0.16}, {0.93, 0.16}, 10, true)    // the crest, falling to the shoulder
	curve(half[:], &n, {0.93, 0.16}, {1, 0.16}, {1, 0.20}, {1, 0.27}, 4, false)       // the rounded shoulder
	half[n] = {1, 0.50}; n += 1                                                       // the side
	curve(half[:], &n, {1, 0.50}, {1, 0.73}, {0.46, 0.81}, {0, 1}, 14, false)          // down to the tip
	top := c.y - h * 0.5
	at :: proc(u, v: f32, c: draw.Vec2, w, h, top: f32) -> draw.Vec2 { return {c.x + u * w * 0.5, top + v * h} }
	m := 0
	for p in half[:n] { pts[m] = at(p.x, p.y, c, w, h, top); m += 1 }
	for i := n - 2; i >= 1; i -= 1 { pts[m] = at(-half[i].x, half[i].y, c, w, h, top); m += 1 }
	return m
}

// The same shape pulled in by `d` all round (the inner edge of the outline).
@(private = "file")
shield_inset :: proc(out, pts: []draw.Vec2, d: f32) {
	n := len(pts)
	for i in 0 ..< n {
		p, a, b := pts[i], pts[(i + n - 1) % n], pts[(i + 1) % n]
		e0, e1 := p - a, b - p
		l0, l1 := max(math.sqrt(e0.x * e0.x + e0.y * e0.y), 1e-4), max(math.sqrt(e1.x * e1.x + e1.y * e1.y), 1e-4)
		n0, n1 := draw.Vec2{-e0.y / l0, e0.x / l0}, draw.Vec2{-e1.y / l1, e1.x / l1}   // inward normals (clockwise outline)
		s := n0 + n1
		ls := max(math.sqrt(s.x * s.x + s.y * s.y), 1e-4)
		s /= ls
		k := d / max(s.x * n0.x + s.y * n0.y, 0.4)
		out[i] = p + s * k
	}
}

// A stroke of `thick` between two points with round ends.
@(private = "file")
stroke :: proc(dc: ^draw.Context, a, b: draw.Vec2, thick: f32, color: draw.Color) {
	d := b - a
	l := math.sqrt(d.x * d.x + d.y * d.y)
	mid := (a + b) * 0.5
	draw.push_transform(dc, draw.affine_around(draw.affine_rotate(math.atan2(-d.x, d.y)), mid))
	draw.rect(dc, {{mid.x - thick * 0.5, mid.y - l * 0.5 - thick * 0.5}, {mid.x + thick * 0.5, mid.y + l * 0.5 + thick * 0.5}}, color, thick * 0.5)
	draw.pop_transform(dc)
}

@(private = "file")
shield_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Shield_Draw)(user)
	r := b.rect
	bh := r.max.y - r.min.y
	c := draw.rect_center(r)     // the same center as the menu button's bars and the other icons of the row
	sh := bh * 0.60               // the shield's height
	sw := sh * 0.86
	thick := max(2, bh * 0.075)   // the stroke of the menu button's bars
	pts: [SHIELD_MAX]draw.Vec2
	n := shield_points(&pts, c, sw, sh)
	bounds := draw.Rect{{c.x - sw * 0.5 - 1, c.y - sh * 0.5 - 1}, {c.x + sw * 0.5 + 1, c.y + sh * 0.5 + 1}}

	filled := d.state == .Active || d.state == .Off
	col := d.color
	if d.state == .Idle { col.a *= 0.6 }
	if filled {
		draw.push_clip_polygon(dc, pts[:n])
		draw.rect(dc, bounds, col)
		draw.pop_clip(dc)
	} else {
		ring: [2 * SHIELD_MAX + 4]draw.Vec2
		inner: [SHIELD_MAX]draw.Vec2
		shield_inset(inner[:n], pts[:n], thick)
		k := 0
		for i in 0 ..< n { ring[k] = pts[i]; k += 1 }
		ring[k] = pts[0]; k += 1
		ring[k] = inner[0]; k += 1
		for i := n - 1; i >= 1; i -= 1 { ring[k] = inner[i]; k += 1 }
		ring[k] = inner[0]; k += 1
		draw.push_clip_polygon(dc, ring[:k], true)
		draw.rect(dc, bounds, col)
		draw.pop_clip(dc)
	}

	// the glyph inside says the state
	gy := c.y - sh * 0.02
	show_glyph := !(d.count > 0 && bl.b.cfg.badge && bl.b.cfg.badge_inside && (d.state == .Active || d.state == .Loading))
	if show_glyph do switch d.state {
	case .Active:   // a check mark, knocked out of the filled shield
		stroke(dc, {c.x - sh * 0.17, gy + sh * 0.01}, {c.x - sh * 0.05, gy + sh * 0.13}, thick, d.ink)
		stroke(dc, {c.x - sh * 0.05, gy + sh * 0.13}, {c.x + sh * 0.18, gy - sh * 0.12}, thick, d.ink)
	case .Loading:   // the same check, in the outline's tone: the lists are not all there yet
		stroke(dc, {c.x - sh * 0.15, gy + sh * 0.01}, {c.x - sh * 0.04, gy + sh * 0.12}, thick, col)
		stroke(dc, {c.x - sh * 0.04, gy + sh * 0.12}, {c.x + sh * 0.16, gy - sh * 0.10}, thick, col)
	case .Off:   // a pause sign on the grey shield: the blocker as a whole is off
		stroke(dc, {c.x - sh * 0.10, gy - sh * 0.11}, {c.x - sh * 0.10, gy + sh * 0.11}, thick, d.ink)
		stroke(dc, {c.x + sh * 0.10, gy - sh * 0.11}, {c.x + sh * 0.10, gy + sh * 0.11}, thick, d.ink)
	case .Site_Off:   // a slash through the outline: off for this site
		stroke(dc, {c.x - sw * 0.62, c.y - sh * 0.56}, {c.x + sw * 0.62, c.y + sh * 0.56}, thick, col)
	case .Idle:
	}

	// the count of blocked requests: in a small badge hung on the shield's top right corner, or inside the shield (blocker.badge.style)
	if d.count > 0 && bl.b.cfg.badge && d.state != .Off && d.state != .Idle {
		text := d.count > 99 ? "99+" : fmt.tprintf("%d", d.count)
		if bl.b.cfg.badge_inside && (d.state == .Active || d.state == .Loading) {
			size := sh * (len(text) > 2 ? 0.40 : 0.50)
			tw := font.text_width(&d.app.fonts, d.app.ui_font, size, text)
			ink := d.state == .Active ? d.ink : col
			draw.text(dc, d.app.ui_font, size, {math.round(c.x - tw * 0.5), math.round(c.y + size * 0.36 + sh * 0.02)}, ink, text)
		} else if !bl.b.cfg.badge_inside {
			size := ui.font_size() * 0.57
			tw := font.text_width(&d.app.fonts, d.app.ui_font, size, text)
			bhh := math.round(size * 1.22)
			bw := math.round(max(tw + size * 0.55, bhh))
			edge := max(1, math.round(ui.scale()))
			left := math.round(c.x + sw * 0.5 - sw * 0.22)    // over a fifth of the shield's width, no more
			top := math.round(c.y - sh * 0.5 - sh * 0.16)
			top = max(top, r.min.y + edge)
			br := draw.Rect{{left, top}, {left + bw, top + bhh}}
			draw.rect(dc, {{br.min.x - edge, br.min.y - edge}, {br.max.x + edge, br.max.y + edge}}, d.ink, bhh * 0.5 + edge)
			draw.rect(dc, br, d.badge, bhh * 0.5)
			draw.text(dc, d.app.ui_font, size, {math.round(br.min.x + (bw - tw) * 0.5), math.round(br.min.y + bhh * 0.5 + size * 0.36)}, d.badge_ink, text)
		}
	}
	// keyboard focus, as a ring around the button
	if ui.focus_key() == b.key {
		draw.rect(dc, {{r.min.x + 1, r.min.y + 1}, {r.max.x - 1, r.max.y - 1}}, d.focus, d.radius, max(2, ui.scale() * 1.5))
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
		ui.toast(.Info, i18n.tr("Content blocker is on: click the shield for its panel"))
	}
	blocker_theme()
	d := ui.frame_new(Shield_Draw)
	shield_look(d, app, state, count)
	ui.next({width = ui.px(em * 2.3), height = ui.px(ui.dense(em * 2)), radius = em * CHROME_BUTTON_RADIUS})
	ui.push_tags("icon_button")
	b := ui.custom("###blocker_icon", shield_draw, d, {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects})
	ui.pop_tags()
	sig := ui.signal(b)
	key := ui.key_from_string(b.parent.key, "###blocker_panel")
	if own := window_own(app); own.blocker_panel_request { own.blocker_panel_request = false; if !ui.ctx_menu_is_open(key) { ui.ctx_menu_open_rect(key, b.rect, b.key) } }
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
	if !ui.ctx_menu_is_open(key) { tip(sig, tip_text) }
	// the popup is built where the button is, so its position follows the row
	blocker_panel(app, t, key, state)
}

// (Window_Own.blocker_panel_request: a command or the page's context menu asked for the panel.)

////////////////////////////////
// The panel

PANEL_W_EM :: f32(37)

// The toolkit reads "##" in a label as the start of a hidden part (ui/key.odin): a zero-width space keeps the text whole
// (filters and URLs have them: example.com##.banner).
label_text :: proc(s: string) -> string {
	if !strings.contains(s, "##") { return s }
	a, _ := strings.replace_all(s, "##", "#\u200b#", context.temp_allocator)
	b, _ := strings.replace_all(a, "##", "#\u200b#", context.temp_allocator)
	return b
}

tid :: proc(text, id: string) -> string { return fmt.aprintf("%s###%s", label_text(text), id, allocator = ui.frame_allocator()) }

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
	host_w := em * 8.4
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
	// (the deferred end of ctx_menu closes the popup at the end of the if statement: the whole panel is built inside it)
	if ui.ctx_menu(key, ui.font_size() * PANEL_W_EM) { panel_body(app, t, state); return }
	if bl.reload_pending && t != nil { bl.reload_pending = false; reload(app, t) }
}

@(private = "file")
panel_body :: proc(app: ^App, t: ^Tab, state: Shield_State) {
	em := ui.font_size()
	w := em * PANEL_W_EM
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
		shield_look(pd, app, state, 0)
		ui.next({width = ui.px(em * 3), height = ui.px(ui.dense(em * 3)), radius = em * 1.5})
		ui.push_tags("icon_button")
		pb := ui.custom("###bl_power", shield_draw, pd, {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects})
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
			third := (w - em * 1.2) * 0.5
			ui.next({width = ui.px(third), height = ui.pct(1)})
			if ui.toggle("###sw_fnt", i18n.tr("Block remote fonts"), &fonts).clicked {
				blocker.site_toggle(&bl.b, site_key, .Block_Fonts, fonts)
				blocker.site_toggle(&bl.b, site_key, .Allow_Fonts, !fonts)
				blocker_apply_site(app, t)
			}
			ui.next({width = ui.px(third), height = ui.pct(1)})
			if ui.toggle("###sw_med", i18n.tr("Block large media"), &media).clicked { blocker.site_toggle(&bl.b, site_key, .Block_Media, media); blocker_apply_site(app, t) }
		}
		ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 1.75))})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.px((w - em * 1.2) * 0.5), height = ui.pct(1)})
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

