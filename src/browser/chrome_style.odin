package browser

// The two looks of the browser's own chrome (browser.ui.chrome_style):
//   modern   flat: tabs are rounded pills on the window's color (the default; tab_strip.odin, chrome.odin as ever);
//   classic  Chrome of 2010-2015: every tab is a trapezoid with sloped sides, rounded shoulders and a concave foot that
//            flares into the toolbar's line; the current tab is *attached* to the toolbar (one gradient, no line between
//            them), the others sit lower in value and behind it, overlapping by a few pixels; gradients on the tab bar,
//            the tabs and the toolbar, light and dark hairlines that sculpt the shapes, a white sunken address field.
//
// A style is not a palette: it composes with any of them. Every color of the classic look is derived from the palette's
// background and border (shade: a mix toward white or black in sRGB values, how the toolkit steps its own states), so a
// light palette gets a light chrome and a dark one a dark chrome, and no palette is named here.
//
// Everything is drawn: polygons (the toolkit's polygon clip, antialiased) filled with its gradients; no image. The
// shapes are made once per size (the cache below) in the tab's own coordinates and only translated when drawn, so a
// frame that draws the strip again builds no geometry. The hit shape of a tab is the toolkit's `Box.slant`, which the
// window's title bar hit test follows too: the corners a tab does not cover still drag the window.
//
// The geometry (tab_dims, fillet_polyline, tab_shape_build) and the colors (classic_colors) are pure: chrome_style_test.odin.

import "core:math"
import "core:math/linalg"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:config"

CHROME_PREFS := [?]config.Def{
	{name = "browser.ui.chrome_style", kind = .String, default = {s = "modern"}, choices = {"modern", "classic"},
		description = "How the browser's own interface (tab bar, tabs, toolbar, address field) is drawn. modern: flat, tabs are rounded pills. classic: tabs are trapezoids with sloped sides, rounded shoulders and a concave foot, the current tab is attached to the toolbar (one gradient, no line between them), the others are darker and overlap behind it, with gradients and light and dark hairlines. Either one follows browser.ui.theme: the classic colors are derived from the palette, light or dark. Applies at once."},
	{name = "browser.ui.classic_slope_deg", kind = .Float, default = {f = 22}, bounded = true, min = 8, max = 40, unit = "deg",
		description = "Classic style: how far the sides of a tab lean from the vertical (Chrome of 2010-2015: about 17). The larger, the more angular the tabs and the more they overlap."},
	{name = "browser.ui.classic_gloss", kind = .Float, default = {f = 1}, bounded = true, min = 0, max = 2,
		description = "Classic style: strength of the gradients and of the difference between the current tab, the other tabs and the tab bar. 0: flat colors (the shapes and lines stay), 1: the usual look, 2: more depth."},
}

register_chrome_prefs :: proc(p: ^config.Prefs) { config.register(p, CHROME_PREFS[:]) }

Chrome_Style :: enum u8 { Modern, Classic }

Chrome_Style_Settings :: struct {
	style:     Chrome_Style,
	slope_deg: f32,
	gloss:     f32,
}

chrome_cfg: Chrome_Style_Settings
chrome_watch: int

chrome_settings_from_prefs :: proc(p: ^config.Prefs) -> Chrome_Style_Settings {
	return {
		style = config.string_of(p, "browser.ui.chrome_style") == "classic" ? .Classic : .Modern,
		slope_deg = f32(config.float_of(p, "browser.ui.classic_slope_deg")),
		gloss = f32(config.float_of(p, "browser.ui.classic_gloss")),
	}
}

chrome_style_init :: proc(app: ^App) {
	chrome_cfg = chrome_settings_from_prefs(&app.prefs)
	chrome_watch = config.watch(&app.prefs, "browser.ui.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		chrome_cfg = chrome_settings_from_prefs(p)
		app := (^App)(user)
		app.frames_requested = max(app.frames_requested, 3)
	}, app)
}

chrome_style_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, chrome_watch)
	tab_shapes_destroy()
	chrome_cfg = {}
}

// The classic look is a row of trapezoids along the top: the tabs in a sidebar (tab_sidebar.odin) take the modern one.
classic_on :: proc() -> bool { return chrome_cfg.style == .Classic && favs.cfg.position == .Top }

////////////////////////////////
// Geometry (pure)

// A tab in pixels. `w` is the width of its foot (the sharp corners of its sides at the bar's bottom), `h` the height
// from its top to the bar's bottom.
Tab_Metrics :: struct {
	w, h:   f32,
	slope:  f32,   // degrees from the vertical
	r_top:  f32,   // radius of the shoulders
	r_foot: f32,   // radius of the concave curve of each foot
	edge:   f32,   // thickness of the hairlines (physical pixels)
}

// What follows from the metrics. The tab's box is `box_w` wide: the foot's flare reaches `ext` beyond each side.
Tab_Dims :: struct {
	run:     f32,   // how far a side leans: the top is 2 * run narrower than the foot
	ext:     f32,   // the box reaches this far beyond the foot's corner
	box_w:   f32,
	tangent: f32,   // where the foot's curve meets the bar's line: this far beyond the foot's corner
}

tab_dims :: proc(m: Tab_Metrics) -> Tab_Dims {
	a := math.to_radians(clamp(m.slope, 1, 80))
	turn := math.PI * 0.5 - a   // the outline turns by this much at each of its four corners
	tangent := m.r_foot * math.tan(turn * 0.5)
	ext := math.ceil(tangent) + 1
	return {run = m.h * math.tan(a), ext = ext, box_w = m.w + 2 * ext, tangent = tangent}
}

// How the tabs of a strip lie: `pitch` apart, each wider than that by `overlap` (the next one covers its right foot).
Classic_Geom :: struct {
	margin:  f32,   // above the tabs (the window's frame to grab and the room for the pointer)
	h:       f32,   // a tab's height
	overlap: f32,
	m:       Tab_Metrics,   // with w = 0: the rest of a tab's metrics
	d:       Tab_Dims,
}

// `bar_h`: the height of the tab bar; `gap`: the space left between the tops of two neighbours.
classic_geom :: proc(em, dpi, bar_h, slope_deg: f32) -> Classic_Geom {
	g: Classic_Geom
	g.margin = math.round(max(3 * dpi, em * 0.2))
	g.h = bar_h - g.margin
	g.m = {h = g.h, slope = slope_deg, r_top = math.round(em * 0.5), r_foot = math.round(em * 0.55), edge = max(math.round(dpi), 1)}
	g.d = tab_dims(g.m)
	g.overlap = max(2 * g.d.run - math.round(em * 0.2), 0)
	return g
}

// The sides of a tab as the toolkit's hit shape: the top corners at the shoulders' tangents, the bottom ones at the foot.
tab_slant :: proc(d: Tab_Dims) -> platform.Slant {
	return {top = {d.ext + d.run, d.ext + d.run}, bottom = {d.ext, d.ext}}
}

// Rounds the corners of the polyline `pts` (the first and last points stay): corner i gets the arc of radius radii[i]
// that is tangent to both its segments, or less when the segments are too short (a segment that ends at an end of the
// polyline may give it all; one between two rounded corners gives half).
fillet_polyline :: proc(pts: [][2]f32, radii: []f32, out: ^[dynamic][2]f32) {
	n := len(pts)
	if n == 0 { return }
	append(out, pts[0])
	for i in 1 ..< max(n - 1, 1) {
		p := pts[i]
		a, b := pts[i - 1] - p, pts[i + 1] - p
		la, lb := linalg.length(a), linalg.length(b)
		r := radii[i]
		if r <= 0 || la < 1e-4 || lb < 1e-4 { append(out, p); continue }
		ua, ub := a / la, b / lb
		phi := math.acos(clamp(linalg.dot(ua, ub), -1, 1))   // the angle inside the corner
		if phi < 1e-3 || phi > math.PI - 1e-3 { append(out, p); continue }
		half := math.tan(phi * 0.5)
		t := r / half
		t = min(t, (i - 1 == 0 || radii[i - 1] <= 0) ? la : la * 0.5, (i + 1 == n - 1 || radii[i + 1] <= 0) ? lb : lb * 0.5)
		r = t * half
		bis := ua + ub
		c := p + bis / linalg.length(bis) * (r / math.sin(phi * 0.5))
		t1, t2 := p + ua * t, p + ub * t
		a1 := math.atan2(t1.y - c.y, t1.x - c.x)
		delta := math.atan2(t2.y - c.y, t2.x - c.x) - a1
		for delta > math.PI { delta -= math.TAU }
		for delta < -math.PI { delta += math.TAU }
		steps := max(int(math.ceil(abs(delta) / (math.PI * 0.5) * 5)), 2)
		for k in 0 ..= steps {
			ang := a1 + delta * f32(k) / f32(steps)
			append(out, [2]f32{c.x + math.cos(ang) * r, c.y + math.sin(ang) * r})
		}
	}
	if n > 1 { append(out, pts[n - 1]) }
}

// The polygon of the region under `line` (an outline that runs left to right), the line moved by `delta` along its
// normal (positive: away from the region, up), closed far below by `bottom`.
closed_offset :: proc(out: ^[dynamic][2]f32, line: [][2]f32, delta, bottom: f32) {
	n := len(line)
	if n == 0 { return }
	for i in 0 ..< n {
		dir := line[min(i + 1, n - 1)] - line[max(i - 1, 0)]
		l := linalg.length(dir)
		nrm := l > 1e-6 ? [2]f32{dir.y, -dir.x} / l : [2]f32{0, -1}
		append(out, line[i] + nrm * delta)
	}
	append(out, [2]f32{line[n - 1].x, bottom})
	append(out, [2]f32{line[0].x, bottom})
}

// The shape of a tab in its box's coordinates (the box's top-left is the origin; the bar's bottom is y = h).
Tab_Shape :: struct {
	m:     Tab_Metrics,
	d:     Tab_Dims,
	line:  [dynamic][2]f32,   // the rounded outline, open: from the box's left side along the bar, up, over, down, along the bar
	outer: [dynamic][2]f32,   // the region under the outline moved out by one hairline: the dark line is what it shows past `mid`
	mid:   [dynamic][2]f32,   // the region itself: the light line is what it shows past `body`
	body:  [dynamic][2]f32,   // the region moved in by one hairline: the gradient
}

tab_shape_clear :: proc(s: ^Tab_Shape) {
	clear(&s.line); clear(&s.outer); clear(&s.mid); clear(&s.body)
}

tab_shape_build :: proc(s: ^Tab_Shape, m: Tab_Metrics) {
	tab_shape_clear(s)
	d := tab_dims(m)
	s.m, s.d = m, d
	h := m.h
	// the outline starts and ends where each foot's curve meets the bar's line: a flat strip out to the box's edge would end in a cut
	corners := [6][2]f32{{d.ext - d.tangent, h}, {d.ext, h}, {d.ext + d.run, 0}, {d.box_w - d.ext - d.run, 0}, {d.box_w - d.ext, h}, {d.box_w - d.ext + d.tangent, h}}
	radii := [6]f32{0, m.r_foot, m.r_top, m.r_top, m.r_foot, 0}
	fillet_polyline(corners[:], radii[:], &s.line)
	bottom := h + 4 * m.edge   // far enough that the bar's line, and everything below it, is the toolbar's to draw
	closed_offset(&s.outer, s.line[:], m.edge, bottom)
	closed_offset(&s.mid, s.line[:], 0, bottom)
	closed_offset(&s.body, s.line[:], -m.edge, bottom)
}

tab_shape_destroy :: proc(s: ^Tab_Shape) {
	delete(s.line); delete(s.outer); delete(s.mid); delete(s.body)
	s^ = {}
}

SHAPE_CACHE_N :: 4   // the tabs share one shape (one size); the new-tab button has another

Shape_Cache :: struct {
	shapes: [SHAPE_CACHE_N]Tab_Shape,
	valid:  [SHAPE_CACHE_N]bool,
	next:   int,
	built:  int,   // how many shapes were made (the tests: a frame that draws again makes none)
}

shape_cache: Shape_Cache

// The shape for `m`: the cached one, else made (replacing the oldest). The pointer is good until the next call that
// makes one: a frame uses at most SHAPE_CACHE_N sizes.
tab_shape_get :: proc(m: Tab_Metrics) -> ^Tab_Shape {
	for i in 0 ..< SHAPE_CACHE_N {
		if shape_cache.valid[i] && shape_cache.shapes[i].m == m { return &shape_cache.shapes[i] }
	}
	i := shape_cache.next
	shape_cache.next = (i + 1) % SHAPE_CACHE_N
	tab_shape_build(&shape_cache.shapes[i], m)
	shape_cache.valid[i] = true
	shape_cache.built += 1
	return &shape_cache.shapes[i]
}

tab_shapes_destroy :: proc() {
	for i in 0 ..< SHAPE_CACHE_N { tab_shape_destroy(&shape_cache.shapes[i]) }
	shape_cache = {}
}

// The order tabs are built in (the last is on top, and gets the clicks): the others left to right, then the current
// one, then the one being dragged. `order` is filled with tab indices.
tab_stack_order :: proc(n, current, dragged: int, order: ^[dynamic]int) {
	for i in 0 ..< n { if i != current && i != dragged { append(order, i) } }
	if current >= 0 && current < n && current != dragged { append(order, current) }
	if dragged >= 0 && dragged < n { append(order, dragged) }
}

////////////////////////////////
// Colors (pure)

Classic_Colors :: struct {
	dark:       bool,
	edge:       f32,     // hairline thickness, physical pixels
	strip_top, strip_bot:             draw.Color,   // the tab bar
	idle_top, idle_bot:               draw.Color,   // a tab that is not current
	hot_top, hot_bot:                 draw.Color,   // ... under the pointer
	lit_top, lit_mid, lit_bot:        draw.Color,   // the current tab (top .. the bar's bottom), the toolbar (that .. its bottom)
	edge_dark, edge_light:            draw.Color,   // the outline of a tab, the line along the toolbar's top
	rule:                             draw.Color,   // the toolbar's lower line
	field, field_top, field_edge:     draw.Color,   // the address field: its bottom, its top (the hollow), its outline
}

// `amt` of the way from `c` to white (positive) or to black (negative), in sRGB values.
shade :: proc(c: draw.Color, amt: f32) -> draw.Color {
	return amt >= 0 ? ui.srgb_step(c, {1, 1, 1, 1}, min(amt, 1)) : ui.srgb_step(c, {0, 0, 0, 1}, min(-amt, 1))
}

// The classic look of a palette whose window color is `base` and line color `border` (linear colors, as the toolkit's).
// `gloss`: strength of the steps (browser.ui.classic_gloss).
classic_colors :: proc(base_in, border: draw.Color, gloss: f32, edge: f32) -> (c: Classic_Colors) {
	base := base_in
	base.a = 1
	luma := (render.linear_to_srgb(base.r) + render.linear_to_srgb(base.g) + render.linear_to_srgb(base.b)) / 3
	c.dark = luma < 0.5
	c.edge = edge
	k := gloss
	if !c.dark {
		c.strip_top, c.strip_bot = shade(base, -0.17 * k), shade(base, -0.27 * k)
		c.idle_top, c.idle_bot = shade(base, -0.045 * k), shade(base, -0.115 * k)
		c.lit_top, c.lit_mid, c.lit_bot = shade(base, 0.8 * k), shade(base, 0.03 * k), shade(base, -0.09 * k)
		c.edge_dark = shade(border, -0.4)
		c.edge_light = {1, 1, 1, 0.85}
		c.rule = shade(border, -0.32)
		c.field = shade(base, 0.92)
		c.field_top = shade(c.field, -0.05 * k)
		c.field_edge = shade(border, -0.22)
	} else {
		c.strip_top, c.strip_bot = shade(base, -0.3 * k), shade(base, -0.52 * k)
		c.idle_top, c.idle_bot = shade(base, 0.07 * k), shade(base, 0.025 * k)
		c.lit_top, c.lit_mid, c.lit_bot = shade(base, 0.18 * k), shade(base, 0.115 * k), shade(base, 0.065 * k)
		c.edge_dark = shade(base, -0.82)
		c.edge_light = {1, 1, 1, 0.1}
		c.rule = shade(base, -0.72)
		c.field = shade(base, -0.4)
		c.field_top = shade(c.field, -0.3 * k)
		c.field_edge = shade(base, 0.2)
	}
	// a tab under the pointer: most of the way to the current one
	c.hot_top, c.hot_bot = ui.srgb_step(c.idle_top, c.lit_top, 0.7), ui.srgb_step(c.idle_bot, c.lit_mid, 0.7)
	return
}

// This frame's colors, from the theme in force (the palette's window and border colors).
classic_colors_frame :: proc(app: ^App) -> ^Classic_Colors {
	c := ui.frame_new(Classic_Colors)
	c^ = classic_colors(ui.color("background"), ui.color("border"), chrome_cfg.gloss, max(math.round(ui_scale_of(app)), 1))
	c.edge_light = ui.tuned(c.edge_light)
	return c
}

////////////////////////////////
// Drawing

// The tab bar's gradient; written once per frame it draws (the bar is built before its tabs).
strip_bar_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	c := (^Classic_Colors)(user)
	cur_gap.valid = false
	vgradient(dc, b.rect, b.rect.min.y, b.rect.max.y, c.strip_top, c.strip_bot)
}

// Where the current tab meets the toolbar (set by its drawing, read by the toolbar's: they have no line there).
cur_gap: struct { valid: bool, x0, x1: f32 }

// `r` filled with a vertical gradient from `top` at y0 to `bot` at y1 (absolute), dithered against banding.
vgradient :: proc(dc: ^draw.Context, r: draw.Rect, y0, y1: f32, top, bot: draw.Color, tint := draw.WHITE, radii := [4]f32{}) {
	stops := [2]draw.Gradient_Stop{{color = top, pos = 0}, {color = bot, pos = 1}}
	draw.gradient(dc, r, {kind = .Linear, space = .Srgb, start = {0, y0 - r.min.y}, end = {0, y1 - r.min.y}, stops = stops[:], dither = true}, radii, tint)
}

@(private = "file")
poly_bounds :: proc(pts: [][2]f32) -> draw.Rect {
	b := draw.Rect{pts[0], pts[0]}
	for p in pts { b = {{min(b.min.x, p.x), min(b.min.y, p.y)}, {max(b.max.x, p.x), max(b.max.y, p.y)}}}
	return b
}

// Calls `fill` with the bounds of `pts` (moved by `at`) while the polygon is the clip.
@(private = "file")
with_polygon :: proc(dc: ^draw.Context, pts: [][2]f32, at: draw.Vec2, user: rawptr, fill: proc(dc: ^draw.Context, bounds: draw.Rect, user: rawptr)) {
	moved := make([][2]f32, len(pts), context.temp_allocator)
	for p, i in pts { moved[i] = p + at }
	draw.push_clip_polygon(dc, moved)
	fill(dc, poly_bounds(moved), user)
	draw.pop_clip(dc)
}

// One tab (or the new-tab button) as the strip's build left it.
Classic_Tab :: struct {
	m:        Tab_Metrics,
	c:        ^Classic_Colors,
	box:      ^ui.Box,
	top, bot: draw.Color,   // the body's gradient, at the tab's top and at the bar's bottom
	selected: f32,          // 0..1 (animated): it is the current tab
	dragging: bool,
	ghost:    f32,          // > 0: the new-tab button: drawn this opaque, with a plus
	hover:    f32,
}

classic_tab_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	t := (^Classic_Tab)(user)
	s := tab_shape_get(t.m)
	r := b.rect
	d := s.d
	c := t.c
	if t.ghost > 0 { draw.push_alpha(dc, t.ghost) }
	if t.dragging {
		// it floats over the others
		sh := draw.Rect{{r.min.x + d.ext + d.run * 0.4, r.min.y + 1}, {r.max.x - d.ext - d.run * 0.4, r.max.y}}
		draw.box_shadow(dc, sh, {t.m.r_top, t.m.r_top, 0, 0}, ui.font_size() * 0.35, ui.tuned({0, 0, 0, c.dark ? 0.7 : 0.38}))
	}
	flat :: proc(dc: ^draw.Context, bounds: draw.Rect, user: rawptr) { draw.rect(dc, bounds, (^draw.Color)(user)^) }
	with_polygon(dc, s.outer[:], r.min, &c.edge_dark, flat)
	with_polygon(dc, s.mid[:], r.min, &c.edge_light, flat)
	with_polygon(dc, s.body[:], r.min, t, proc(dc: ^draw.Context, bounds: draw.Rect, user: rawptr) {
		t := (^Classic_Tab)(user)
		vgradient(dc, bounds, t.box.rect.min.y, t.box.rect.max.y, t.top, t.bot)
	})
	if t.ghost > 0 {
		// a plus, a thin cross like the close button's
		ctr := draw.Vec2{(r.min.x + r.max.x) * 0.5, r.min.y + (r.max.y - r.min.y) * 0.56}
		arm := (r.max.y - r.min.y) * 0.2
		th := max(math.round(1.25 * ui.scale()), 1)
		ink := ui.color("text")
		ink.a *= 0.8
		draw.rect(dc, {{ctr.x - arm, ctr.y - th * 0.5}, {ctr.x + arm, ctr.y + th * 0.5}}, ink)
		draw.rect(dc, {{ctr.x - th * 0.5, ctr.y - arm}, {ctr.x + th * 0.5, ctr.y + arm}}, ink)
		draw.pop_alpha(dc)
		return
	}
	if t.selected > 0.5 {
		cur_gap = {true, r.min.x + d.ext - d.tangent, r.max.x - d.ext + d.tangent}
	}
}

// The end of a title that does not fit: the tab's own gradient laid over it, more and more opaque (the text fades out).
Title_Fade :: struct { tab: ^Classic_Tab, width: f32 }

title_fade_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	f := (^Title_Fade)(user)
	r := b.rect
	if b.text_dim.x <= r.max.x - r.min.x + 0.5 { return }
	t := f.tab
	n := max(int(f.width / 2), 4)
	step := f.width / f32(n)
	for k in 0 ..< n {
		x1 := r.max.x - f32(n - 1 - k) * step
		// (from under the light hairline along the top: laid over it, the fade hid it and it came back in a cut where the fade ends)
		slice := draw.Rect{{x1 - step, t.box.rect.min.y + t.m.edge}, {x1, t.box.rect.max.y}}
		a := f32(k + 1) / f32(n)
		vgradient(dc, slice, t.box.rect.min.y, t.box.rect.max.y, t.top, t.bot, {1, 1, 1, a * a * (3 - 2 * a)})
	}
}

// The metrics of the new-tab button's trapezoid (a small flare, a bit lower than a tab), the room it keeps clear of the toolbar's line,
// and how far its left foot reaches back under the last tab: so that its top corner is a tab gap (0.2 em) from the last tab's top
// corner, as two tabs' are, instead of far to the right of them.
classic_plus_metrics :: proc(cg: ^Classic_Geom, em, dpi, box_w: f32) -> (m: Tab_Metrics, gap_b, hb, pull: f32) {
	gap_b = math.round(2 * dpi)   // clear of the toolbar's line
	hb = cg.h - gap_b - math.round(em * 0.3)
	m = cg.m
	m.h = hb
	m.r_foot = math.round(em * 0.25)   // a small button: a small flare
	m.w = box_w - 2 * tab_dims(m).ext
	d := tab_dims(m)
	pull = max(math.round((cg.d.ext + cg.d.run + d.ext + d.run) * 0.5 - em * 0.2), 0)
	return
}

// The new-tab button at `x` of the tab area (the caller builds it before the tabs, which draw over its left foot): a small trapezoid of
// the same family, faint until the pointer is over it.
classic_new_tab_button :: proc(app: ^App, cg: ^Classic_Geom, cc: ^Classic_Colors, bar_h, box_w, x: f32) -> (sig: ui.Signal) {
	m, gap_b, hb, _ := classic_plus_metrics(cg, ui.font_size(), ui_scale_of(app), box_w)
	d := tab_dims(m)
	ui.next({fixed_x = x, fixed_y = bar_h - gap_b - hb, width = ui.px(d.box_w), height = ui.px(hb)})
	b := ui.build_box({.Clickable, .Focusable}, "###newtab")
	b.cursor = .Arrow
	b.slant = tab_slant(d)
	sig = ui.signal(b)
	p := ui.frame_new(Classic_Tab)
	p.m, p.c, p.box = m, cc, b
	p.hover = ui.anim(ui.key_from_string(b.key, "hov"), sig.hovering ? 1 : 0, 40)
	p.top, p.bot = ui.srgb_step(cc.idle_top, cc.hot_top, p.hover), ui.srgb_step(cc.idle_bot, cc.hot_bot, p.hover)
	p.ghost = 0.5 + 0.5 * p.hover
	b.custom, b.custom_user = classic_tab_draw, p
	return
}

// The toolbar: its gradient (the current tab's, carried on), the line along its top (dark above, light below) that the
// current tab interrupts, and the line along its bottom.
toolbar_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	c := (^Classic_Colors)(user)
	r := b.rect
	lw := c.edge
	vgradient(dc, r, r.min.y, r.max.y, c.lit_mid, c.lit_bot)
	spans: [2][2]f32 = {{r.min.x, r.max.x}, {}}
	if cur_gap.valid { spans = {{r.min.x, min(cur_gap.x0, r.max.x)}, {max(cur_gap.x1, r.min.x), r.max.x}} }
	for sp in spans {
		if sp[1] <= sp[0] { continue }
		draw.rect(dc, {{sp[0], r.min.y - lw}, {sp[1], r.min.y}}, c.edge_dark)
		draw.rect(dc, {{sp[0], r.min.y}, {sp[1], r.min.y + lw}}, c.edge_light)
	}
	draw.rect(dc, {{r.min.x, r.max.y - lw}, {r.max.x, r.max.y}}, c.rule)
}

// The address field's frame: an outline, a hollow (darker at the top) and a light line under it.
Classic_Field :: struct { c: ^Classic_Colors, radius: f32 }

field_frame_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	f := (^Classic_Field)(user)
	c := f.c
	r := b.rect
	lw := c.edge
	draw.rect(dc, r, c.field_edge, f.radius)
	inner := draw.rect_pad(r, -lw)
	ir := max(f.radius - lw, 0)
	vgradient(dc, inner, inner.min.y, inner.max.y, c.field_top, c.field, {1, 1, 1, 1}, {ir, ir, ir, ir})
	draw.rect(dc, {{r.min.x + f.radius * 0.7, r.max.y}, {r.max.x - f.radius * 0.7, r.max.y + lw}}, c.edge_light)
}

// The toolbar's row: the row `address_row` fills. Classic: it carries the toolbar's gradient and lines.
toolbar_row :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.8))})
	if !classic_on() {
		if ui.row(.Center) { address_row(app, t) }
		return
	}
	if ui.row(.Center, {}, "###toolbar") {
		b := ui.parent_box()
		b.custom, b.custom_user = toolbar_draw, classic_colors_frame(app)
		address_row(app, t)
	}
}
