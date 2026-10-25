package browser

import "core:math"
import "core:testing"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:config"

@(private = "file")
metrics :: proc(w: f32 = 200) -> Tab_Metrics {
	return {w = w, h = 36, slope = 22, r_top = 8, r_foot = 8, edge = 1}
}

@(private = "file")
near :: proc(t: ^testing.T, got, want, eps: f32, what: string, loc := #caller_location) {
	testing.expectf(t, abs(got - want) <= eps, "%s: %v, wanted %v", what, got, want, loc = loc)
}

@(private = "file")
luma :: proc(c: draw.Color) -> f32 {
	return 0.2126 * render.linear_to_srgb(c.r) + 0.7152 * render.linear_to_srgb(c.g) + 0.0722 * render.linear_to_srgb(c.b)
}

// A tab leans by its slope: the top is 2 * run narrower than the foot, and the box keeps room for the foot's flare.
@(test)
tab_dims_follow_the_slope :: proc(t: ^testing.T) {
	m := metrics()
	d := tab_dims(m)
	near(t, d.run, 36 * math.tan(f32(22) * math.PI / 180), 0.001, "run")
	near(t, d.box_w, m.w + 2 * d.ext, 0.001, "box width")
	testing.expect(t, d.ext >= d.tangent, "the flare fits in the box")
	steeper := tab_dims({w = 200, h = 36, slope = 35, r_top = 8, r_foot = 8, edge = 1})
	testing.expect(t, steeper.run > d.run, "a greater slope leans more")
	// the curve of a foot is tangent to the bar's line `tangent` before the corner: a rounder foot flares further
	round := tab_dims({w = 200, h = 36, slope = 22, r_top = 8, r_foot = 16, edge = 1})
	testing.expect(t, round.tangent > d.tangent && round.ext > d.ext)
}

// Rounding the corner of a right angle: a quarter circle, tangent to both sides, at `r` from its center.
@(test)
fillet_of_a_right_angle :: proc(t: ^testing.T) {
	out := make([dynamic][2]f32, context.temp_allocator)
	pts := [3][2]f32{{0, 100}, {100, 100}, {100, 0}}
	radii := [3]f32{0, 20, 0}
	fillet_polyline(pts[:], radii[:], &out)
	testing.expect(t, len(out) >= 6)
	testing.expect_value(t, out[0], [2]f32{0, 100})
	testing.expect_value(t, out[len(out) - 1], [2]f32{100, 0})
	near(t, out[1].x, 80, 0.01, "the arc starts 20 before the corner")
	near(t, out[1].y, 100, 0.01, "... on the first side")
	near(t, out[len(out) - 2].x, 100, 0.01, "and ends on the second")
	near(t, out[len(out) - 2].y, 80, 0.01, "... 20 after it")
	for p in out[1:len(out) - 1] {
		d := math.sqrt((p.x - 80) * (p.x - 80) + (p.y - 80) * (p.y - 80))
		near(t, d, 20, 0.01, "on the circle")
	}
	// a radius too large for the sides is cut down to what they allow
	short := [3][2]f32{{0, 10}, {10, 10}, {10, 0}}
	clear(&out)
	r2 := [3]f32{0, 50, 0}
	fillet_polyline(short[:], r2[:], &out)
	near(t, out[1].x, 0, 0.01, "the arc reaches the end of a segment that ends the line")
}

// The outline of a tab, in its box: along the bar, up the left side, over the top, down, along the bar.
@(test)
tab_shape_geometry :: proc(t: ^testing.T) {
	m := metrics()
	shape: Tab_Shape
	defer tab_shape_destroy(&shape)
	tab_shape_build(&shape, m)
	d := shape.d
	line := shape.line[:]
	testing.expect(t, len(line) > 20)
	// it starts and ends where each foot's curve meets the bar's line (a strip out to the box's edge would end in a cut)
	near(t, line[0].x, d.ext - d.tangent, 0.01, "starts at the left foot's tangent point")
	near(t, line[0].y, m.h, 0.01, "starts on the bar's line")
	near(t, line[len(line) - 1].x, d.box_w - d.ext + d.tangent, 0.01, "ends at the right foot's tangent point")
	near(t, line[len(line) - 1].y, m.h, 0.01, "ends on the bar's line")
	top: f32 = 1e9
	for p in line {
		top = min(top, p.y)
		testing.expect(t, p.x >= 0 && p.x <= d.box_w && p.y >= 0 && p.y <= m.h, "inside the box")
	}
	near(t, top, 0, 0.01, "the shoulders' flat top is the box's top")
	// symmetric about the middle
	for p in line {
		found := false
		for q in line { if abs(q.x - (d.box_w - p.x)) < 0.01 && abs(q.y - p.y) < 0.01 { found = true; break } }
		testing.expectf(t, found, "no mirror of %v", p)
	}
	// halfway up the side the outline has leaned half way (the curves have ended before: their radius is small)
	for i in 1 ..< len(line) {
		a, b := line[i - 1], line[i]
		if (a.y - m.h * 0.5) * (b.y - m.h * 0.5) <= 0 && a.x < d.box_w * 0.5 {
			x := a.x + (b.x - a.x) * (m.h * 0.5 - a.y) / (b.y - a.y)
			near(t, x, d.ext + d.run * 0.5, 0.5, "the left side at mid-height")
			break
		}
	}
	// the feet are concave: the outline leaves the bar's line at `tangent` before the foot's corner
	for i in 1 ..< len(line) {
		if line[i].y < m.h - 0.01 {
			near(t, line[i - 1].x, d.ext - d.tangent, 0.01, "where the left foot leaves the bar's line")
			break
		}
	}
	// the three polygons are the region moved by a hairline each way: dark line out, light line, body in
	near(t, shape.outer[0].y, m.h - m.edge, 0.01, "outer, along the bar")
	near(t, shape.mid[0].y, m.h, 0.01, "mid, along the bar")
	near(t, shape.body[0].y, m.h + m.edge, 0.01, "body, along the bar")
	testing.expect_value(t, len(shape.outer), len(shape.line) + 2)
}

// The cache hands the same shape back for the same size (a frame that draws again builds none) and one shape per size.
@(test)
tab_shapes_are_cached :: proc(t: ^testing.T) {
	tab_shapes_destroy()
	defer tab_shapes_destroy()
	a := tab_shape_get(metrics(200))
	built := shape_cache.built
	b := tab_shape_get(metrics(200))
	testing.expect(t, a == b)
	testing.expect_value(t, shape_cache.built, built)
	c := tab_shape_get(metrics(120))
	testing.expect(t, c != a)
	testing.expect_value(t, shape_cache.built, built + 1)
	testing.expect(t, tab_shape_get(metrics(200)) == a, "the first size is still there")
	testing.expect_value(t, shape_cache.built, built + 1)
}

// Neighbours overlap: the next tab's foot covers this one's, their tops stay apart by the gap.
@(test)
tabs_overlap_but_their_tops_stay_apart :: proc(t: ^testing.T) {
	g := classic_geom(15, 1, 39, 22)
	testing.expect(t, g.overlap > 0, "the tabs overlap")
	testing.expect_value(t, g.margin, f32(3))
	testing.expect_value(t, g.h, f32(36))
	w: f32 = 150   // the pitch
	m := g.m
	m.w = w + g.overlap
	d := tab_dims(m)
	right_top_0 := d.box_w - d.ext - d.run             // tab 0's top ends here
	left_top_1 := w + d.ext + d.run                    // tab 1's top starts here
	near(t, left_top_1 - right_top_0, 3, 0.01, "the gap between two tops (0.2 em)")
	// their feet overlap by `overlap`
	near(t, (d.box_w - d.ext) - (w + d.ext), g.overlap, 0.01, "the feet overlap")
	// a flatter tab overlaps less
	flat := classic_geom(15, 1, 39, 12)
	testing.expect(t, flat.overlap < g.overlap)
}

// The hit shape is the trapezoid; where two tabs overlap, the one drawn above (built later) gets the click, and the
// current tab is built after the others.
@(test)
the_tab_on_top_gets_the_click :: proc(t: ^testing.T) {
	g := classic_geom(15, 1, 39, 22)
	w: f32 = 150
	m := g.m
	m.w = w + g.overlap
	d := tab_dims(m)
	slant := tab_slant(d)
	region :: proc(i: int, w: f32, d: Tab_Dims, h: f32, s: platform.Slant) -> platform.Slanted_Region {
		return {{f32(i) * w, 0}, {f32(i) * w + d.box_w, h}, s}
	}
	// the middle of a tab, its top corner's outside, the flare outside
	r0 := region(0, w, d, g.h, slant)
	testing.expect(t, platform.slanted_contains(r0, {d.box_w * 0.5, g.h * 0.5}))
	testing.expect(t, !platform.slanted_contains(r0, {d.ext + 1, 1}), "left of the top's corner")
	testing.expect(t, platform.slanted_contains(r0, {d.ext + 2, g.h - 1}), "the foot's corner is in")
	testing.expect(t, !platform.slanted_contains(r0, {d.ext - 2, g.h - 1}), "the flare is not the tab's")
	// a point of both feet (tab 0's right one, tab 1's left one)
	p := [2]f32{w + d.ext + 3, g.h - 2}
	r1 := region(1, w, d, g.h, slant)
	testing.expect(t, platform.slanted_contains(r0, p) && platform.slanted_contains(r1, p))
	boxes := [2]platform.Slanted_Region{r0, r1}
	top_at :: proc(order: []int, boxes: []platform.Slanted_Region, p: [2]f32) -> int {
		for k := len(order) - 1; k >= 0; k -= 1 { if platform.slanted_contains(boxes[order[k]], p) { return order[k] } }
		return -1
	}
	order := make([dynamic]int, context.temp_allocator)
	tab_stack_order(2, 1, -1, &order)   // tab 1 is current: it is on top
	testing.expect_value(t, top_at(order[:], boxes[:], p), 1)
	clear(&order)
	tab_stack_order(2, 0, -1, &order)   // tab 0 is current: it covers tab 1's foot
	testing.expect_value(t, top_at(order[:], boxes[:], p), 0)
	// the tops are apart: a point at tab 1's top belongs to tab 1 alone
	testing.expect_value(t, top_at(order[:], boxes[:], {w + d.ext + d.run + 5, 2}), 1)
}

@(test)
stack_order_puts_current_then_dragged_last :: proc(t: ^testing.T) {
	order := make([dynamic]int, context.temp_allocator)
	tab_stack_order(5, 2, -1, &order)
	testing.expect_value(t, len(order), 5)
	testing.expect_value(t, order[0], 0)
	testing.expect_value(t, order[3], 4)
	testing.expect_value(t, order[4], 2)
	clear(&order)
	tab_stack_order(5, 2, 3, &order)
	testing.expect_value(t, len(order), 5)
	testing.expect_value(t, order[3], 2)
	testing.expect_value(t, order[4], 3)
	clear(&order)
	tab_stack_order(5, 3, 3, &order)   // the current tab is the one dragged: once
	testing.expect_value(t, len(order), 5)
	testing.expect_value(t, order[4], 3)
	clear(&order)
	tab_stack_order(0, 0, -1, &order)
	testing.expect_value(t, len(order), 0)
}

// The classic colors follow any palette: the current tab is the lightest, then the other tabs, then the tab bar, in light
// and in dark palettes; the toolbar goes on from the current tab; a flat setting has no steps.
@(test)
classic_colors_compose_with_palettes :: proc(t: ^testing.T) {
	for np in ui.NAMED_PALETTES {
		base, border := draw.hex(np.palette.bg | 0xff), draw.hex(np.palette.border)
		c := classic_colors(base, border, 1, 1)
		testing.expectf(t, c.dark == np.palette.dark || np.name == "Aero" || np.name == "Bootstrap", "%s: dark = %v", np.name, c.dark)
		testing.expectf(t, luma(c.lit_top) > luma(c.idle_top), "%s: the current tab is lighter than the others", np.name)
		testing.expectf(t, luma(c.idle_top) > luma(c.strip_top), "%s: the others are lighter than the bar", np.name)
		testing.expectf(t, luma(c.idle_bot) > luma(c.strip_bot), "%s: ... at the bottom as well", np.name)
		testing.expectf(t, luma(c.lit_top) >= luma(c.lit_mid) && luma(c.lit_mid) >= luma(c.lit_bot) - 0.001, "%s: the current tab's gradient is monotonous into the toolbar", np.name)
		testing.expectf(t, luma(c.strip_top) >= luma(c.strip_bot), "%s: the bar is a little lighter at the top", np.name)
		testing.expectf(t, luma(c.hot_top) > luma(c.idle_top) && luma(c.hot_top) < luma(c.lit_top), "%s: hover is between", np.name)
		testing.expectf(t, abs(luma(c.field) - luma(c.lit_bot)) > 0.05, "%s: the address field stands out of the toolbar", np.name)
		flat := classic_colors(base, border, 0, 1)
		testing.expectf(t, flat.lit_top == flat.idle_top && flat.idle_top == flat.strip_top, "%s: gloss 0 is flat", np.name)
	}
	// white-ish field on a light palette, darker than the toolbar on a dark one
	light := classic_colors(draw.hex(ui.PALETTE_DAYLIGHT.bg | 0xff), draw.hex(ui.PALETTE_DAYLIGHT.border), 1, 1)
	testing.expect(t, luma(light.field) > 0.95, "white field")
	dark := classic_colors(draw.hex(ui.PALETTE_GRAPHITE.bg | 0xff), draw.hex(ui.PALETTE_GRAPHITE.border), 1, 1)
	testing.expect(t, luma(dark.field) < luma(dark.lit_bot), "sunken field")
}

// The classic look is the style chosen, wherever the tabs are (top, left, right); the modern one likewise.
@(test)
classic_on_follows_the_style_at_every_position :: proc(t: ^testing.T) {
	saved_style, saved_pos := chrome_cfg.style, favs.cfg.position
	defer { chrome_cfg.style, favs.cfg.position = saved_style, saved_pos }
	for style in Chrome_Style {
		for pos in Tabs_Position {
			chrome_cfg.style, favs.cfg.position = style, pos
			testing.expectf(t, classic_on() == (style == .Classic), "%v at %v", style, pos)
		}
	}
}

// The sidebar's current tab is a classic tab with upright sides lying across its row: its rounded shoulders on the outer
// side (left for a left sidebar, right for a right one), its outline open on the inner edge (it flows into the page there),
// its feet flaring `tangent` above and below the row along that edge, and nothing past the row's outer side.
@(test)
side_tab_lies_across_its_row :: proc(t: ^testing.T) {
	row := draw.Rect{{10, 100}, {210, 136}}
	across := row.max.x - row.min.x
	m := side_tab_metrics(15, 1, row.max.y - row.min.y, across)
	testing.expect_value(t, m.slope, f32(0))
	shape: Tab_Shape
	defer tab_shape_destroy(&shape)
	tab_shape_build(&shape, m)
	d := shape.d
	near(t, d.run, 0, 0.001, "upright sides")
	near(t, d.box_w, row.max.y - row.min.y + 2 * d.ext, 0.001, "the row and its feet's flare")
	origin := side_tab_origin(row, d)
	for pos in ([2]Tabs_Position{.Left, .Right}) {
		line := side_polygon(shape.line[:], pos, origin, across)
		outer := pos == .Left ? row.min.x : row.max.x
		inner := pos == .Left ? row.max.x : row.min.x
		// open on the inner edge, at the feet's tangents above and below the row
		near(t, line[0].x, inner, 0.01, "starts on the inner edge")
		near(t, line[len(line) - 1].x, inner, 0.01, "ends on the inner edge")
		near(t, line[0].y, row.min.y - d.tangent, 0.01, "the upper foot's flare")
		near(t, line[len(line) - 1].y, row.max.y + d.tangent, 0.01, "the lower foot's flare")
		reach := pos == .Left ? f32(1e9) : -1e9
		for p in line {
			testing.expectf(t, p.x >= row.min.x - 0.01 && p.x <= row.max.x + 0.01, "%v: %v inside the row's width", pos, p)
			testing.expectf(t, p.y >= row.min.y - d.tangent - 0.01 && p.y <= row.max.y + d.tangent + 0.01, "%v: %v within the flare", pos, p)
			reach = pos == .Left ? min(reach, p.x) : max(reach, p.x)
			// the shoulders are rounded: on the outer side only between the corners' arcs
			if abs(p.x - outer) < 0.01 {
				testing.expectf(t, p.y >= row.min.y + m.r_top - 0.01 && p.y <= row.max.y - m.r_top + 0.01, "%v: %v is a rounded corner", pos, p)
			}
		}
		near(t, reach, outer, 0.01, "reaches the outer side")
		// the body covers the inner edge's line between the feet (it interrupts it), and goes on past the edge
		body := side_polygon(shape.body[:], pos, origin, across)
		past := false
		for p in body { if pos == .Left ? p.x > inner : p.x < inner { past = true } }
		testing.expectf(t, past, "%v: the body goes on past the inner edge (the panel's clip ends it)", pos)
	}
	// left and right are mirrors of each other about the row's middle
	l := side_polygon(shape.line[:], .Left, origin, across)
	r := side_polygon(shape.line[:], .Right, origin, across)
	mid := (row.min.x + row.max.x) * 0.5
	for p, i in l {
		near(t, r[i].x, 2 * mid - p.x, 0.01, "mirrored")
		near(t, r[i].y, p.y, 0.01, "at the same height")
	}
}

// The sidebar's colors follow any palette: the current tab is lighter than a tab under the pointer, which is lighter
// than the bar; the inner edge's line is darker than the bar; the titles stand out of the bar.
@(test)
side_colors_compose_with_palettes :: proc(t: ^testing.T) {
	for np in ui.NAMED_PALETTES {
		base, border := draw.hex(np.palette.bg | 0xff), draw.hex(np.palette.border)
		c := classic_colors(base, border, 1, 1)
		top, bot := side_hover_colors(c)
		testing.expectf(t, luma(c.lit_top) > luma(top) && luma(c.lit_mid) > luma(bot), "%s: the current tab is lighter than one under the pointer", np.name)
		testing.expectf(t, luma(top) > luma(c.strip_top) && luma(bot) > luma(c.strip_bot), "%s: ... which is lighter than the bar", np.name)
		testing.expectf(t, luma(c.edge_dark) < luma(c.strip_bot), "%s: the inner edge's line shows on the bar", np.name)
		text, weak := draw.hex(np.palette.text), draw.hex(np.palette.weak)
		for lit in ([2]draw.Color{c.lit_top, c.lit_mid}) {
			testing.expectf(t, abs(luma(text) - luma(lit)) > 0.4, "%s: the current title stands out of its tab", np.name)
		}
		for bar in ([2]draw.Color{c.strip_top, c.strip_bot}) {
			testing.expectf(t, abs(luma(weak) - luma(bar)) > 0.18, "%s: the other titles stand out of the bar", np.name)
		}
		flat := classic_colors(base, border, 0, 1)
		ft, fb := side_hover_colors(flat)
		testing.expectf(t, abs(luma(ft) - luma(flat.strip_top)) < 0.002 && abs(luma(fb) - luma(flat.strip_bot)) < 0.002, "%s: gloss 0 is flat", np.name)
	}
}

// The style is a preference: modern by default, changeable at once, with bounded companions.
@(test)
chrome_style_preferences :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	s := chrome_settings_from_prefs(&p)
	testing.expect_value(t, s.style, Chrome_Style.Modern)
	testing.expect(t, s.slope_deg >= 8 && s.slope_deg <= 40)
	testing.expect_value(t, config.set_from_string(&p, "browser.ui.chrome_style", "classic", .User), config.Set_Error.None)
	testing.expect_value(t, chrome_settings_from_prefs(&p).style, Chrome_Style.Classic)
	testing.expect(t, config.set_from_string(&p, "browser.ui.chrome_style", "pill", .User) != config.Set_Error.None, "an unknown style is refused")
	testing.expect(t, config.set_from_string(&p, "browser.ui.classic_slope_deg", "80", .User) != config.Set_Error.None, "a slope out of range is refused")
}
