package reftest

import "core:math"
import css_ "wb:css"
import lay "wb:layout"
import "wb:style"

// Boxes: backgrounds (colours, gradients, images), box shadows, borders of every style, outlines, replaced content. As
// src/browser/render.odin and paint_backgrounds.odin draw them.

// The factors of the light and dark sides of groove, ridge, inset and outset borders (as render.odin).
@(private = "file")
SHADE_DARK :: 0.55
@(private = "file")
SHADE_LIGHT_RIDGE :: 1.35
@(private = "file")
SHADE_LIGHT_OUTSET :: 1.2
// Dashes and gaps in border widths, and their smallest size in px (as render.odin).
@(private = "file")
DASH_LENGTH_WIDTHS :: 3
@(private = "file")
DASH_GAP_WIDTHS :: 2
@(private = "file")
DASH_MIN_PX :: 2
// A double border: outer, gap, inner.
@(private = "file")
DOUBLE_THIRD :: 1.0 / 3.0
@(private = "file")
GROOVE_HALF :: HALF
// A gaussian's reach, in standard deviations; a blur radius is two of them (CSS Backgrounds §7.2).
@(private = "file")
SHADOW_REACH_SIGMAS :: 3
@(private = "file")
BLUR_RADIUS_SIGMAS :: HALF
// Smallest tile of a gradient: below it nothing is drawn (as paint_backgrounds.odin).
@(private = "file")
MIN_TILE_PX :: HALF
// Abramowitz and Stegun 7.1.26: an error function good to 1.5e-7.
@(private = "file")
ERF_P :: 0.3275911
@(private = "file")
ERF_A := [5]f32{0.254829592, -0.284496736, 1.421413741, -1.453152027, 1.061405429}
// Side indices in widths, styles and colors.
@(private = "file")
SIDES := [4]style.Side{.Top, .Right, .Bottom, .Left}
@(private = "file")
TOP :: 0
@(private = "file")
RIGHT :: 1
@(private = "file")
BOTTOM :: 2
@(private = "file")
LEFT :: 3

////////////////////////////////
// Tiles

// How an image without bounds or with a size repeats: where a tile starts, its size, the space between tiles.
@(private)
Tile :: struct {
	origin, size, spacing: lay.Vec2,
	repeat: [2]bool,
}

// `q` as a position inside a tile; false: between tiles or past the only one.
@(private)
tile_position :: #force_inline proc(t: ^Tile, q: lay.Vec2) -> (u: lay.Vec2, ok: bool) {
	u = q - t.origin
	for axis in 0 ..< 2 {
		if t.repeat[axis] {
			period := t.size[axis] + t.spacing[axis]
			u[axis] -= math.floor(u[axis] / period) * period
		}
		if u[axis] < 0 || u[axis] >= t.size[axis] { return u, false }
	}
	return u, true
}

// CSS Backgrounds §3.9: the size of a tile of an image with natural size `natural` (0: none) in a w x h area. A size given
// with one dimension auto keeps the ratio. As images_paint_background_layer in src/browser/images_shell.odin.
@(private = "file")
tile_size :: proc(sz: style.Bg_Size, w, h, scale: f32, natural: [2]f32, c: ^Content) -> lay.Vec2 {
	nw, nh := natural[0] * scale, natural[1] * scale
	has_ratio := nw > 0 && nh > 0
	switch sz.kind {
	case .Auto:
		if !has_ratio { return {w, h} }
		// CSS Images 3 §5.2 default sizing: an SVG with a ratio and no size is contained in the area, one with neither fills it
		if c != nil && c.vector && c.ratio_only {
			k := min(w / nw, h / nh)
			return {nw * k, nh * k}
		}
		if c != nil && c.vector && !c.has_size[0] && !c.has_size[1] { return {w, h} }
		return {nw, nh}
	case .Cover, .Contain:
		if !has_ratio { return {w, h} }
		k := sz.kind == .Contain ? min(w / nw, h / nh) : max(w / nw, h / nh)
		return {nw * k, nh * k}
	case .Length:
		tw := sz.w.kind == .Auto ? -1 : style.resolve(sz.w, w / scale) * scale
		th := sz.h.kind == .Auto ? -1 : style.resolve(sz.h, h / scale) * scale
		if tw < 0 && th < 0 { return has_ratio ? lay.Vec2{nw, nh} : lay.Vec2{w, h} }
		if tw < 0 { tw = has_ratio ? th * nw / nh : w }
		if th < 0 { th = has_ratio ? tw * nh / nw : h }
		return {tw, th}
	}
	return {w, h}
}

// The tile of a layer in its positioning area, with round and space applied. ok = false: nothing to draw.
@(private = "file")
layer_tile :: proc(layer: ^style.Bg_Layer, area: lay.Rect, scale: f32, natural: [2]f32, c: ^Content = nil) -> (t: Tile, ok: bool) {
	aw, ah := area.max.x - area.min.x, area.max.y - area.min.y
	if aw <= 0 || ah <= 0 { return }
	ts := tile_size(layer.size, aw, ah, scale, natural, c)
	rx, ry := layer.repeat[0], layer.repeat[1]
	if rx == .Round && ts.x > 0 { ts.x = aw / max(math.round(aw / ts.x), 1) }
	if ry == .Round && ts.y > 0 { ts.y = ah / max(math.round(ah / ts.y), 1) }
	if ts.x < MIN_TILE_PX || ts.y < MIN_TILE_PX { return }
	ox := area.min.x + style.resolve(layer.position[0], (aw - ts.x) / scale) * scale
	oy := area.min.y + style.resolve(layer.position[1], (ah - ts.y) / scale) * scale
	if rx == .Space {
		n := math.floor(aw / ts.x)
		if n >= 2 { t.spacing.x = (aw - n * ts.x) / (n - 1); ox = area.min.x } else { rx = .No_Repeat }
	}
	if ry == .Space {
		n := math.floor(ah / ts.y)
		if n >= 2 { t.spacing.y = (ah - n * ts.y) / (n - 1); oy = area.min.y } else { ry = .No_Repeat }
	}
	t.origin, t.size, t.repeat = {ox, oy}, ts, {rx != .No_Repeat, ry != .No_Repeat}
	return t, true
}

////////////////////////////////
// Gradients

@(private = "file")
Stop :: struct { pos: f32, color: Pixel, has_hint: bool, hint: f32 }

@(private)
Gradient_Paint :: struct {
	kind:      style.Gradient_Kind,
	repeating: bool,
	start, axis: lay.Vec2,   // linear: where it starts; along the line, divided by the line's squared length
	center:    lay.Vec2,
	radii:     lay.Vec2,
	angle:     f32,
	stops:     []Stop,
}

// The geometry of a gradient for a tile of `size` (as gradient_geometry in paint_backgrounds.odin); colors interpolate in
// premultiplied sRGB whatever the space the gradient asks for. In temp memory.
@(private = "file")
gradient_make :: proc(g: ^style.Gradient, size: lay.Vec2, scale: f32) -> ^Gradient_Paint {
	MIN_RADIUS :: 0.001
	w, h := size.x, size.y
	out := new(Gradient_Paint, context.temp_allocator)
	out.kind, out.repeating = g.kind, g.repeating
	line: f32
	switch g.kind {
	case .Linear:
		a := style.gradient_angle(g, w, h)
		length := style.gradient_line_length(a, w, h)
		dir := lay.Vec2{math.sin(a), -math.cos(a)}
		out.start = lay.Vec2{w, h} * HALF - dir * length * HALF
		out.axis = length > 0 ? dir / length : lay.Vec2{}
		line = length / scale
	case .Radial:
		c := lay.Vec2{style.resolve(g.position[0], w / scale) * scale, style.resolve(g.position[1], h / scale) * scale}
		out.center = c
		near := lay.Vec2{min(c.x, w - c.x), min(c.y, h - c.y)}
		far := lay.Vec2{max(c.x, w - c.x), max(c.y, h - c.y)}
		circle := g.shape == .Circle
		r: lay.Vec2
		switch g.extent {
		case .Closest_Side: r = circle ? min(near.x, near.y) : near
		case .Farthest_Side: r = circle ? max(far.x, far.y) : far
		case .Closest_Corner:
			r = circle ? math.sqrt(near.x * near.x + near.y * near.y) : near * math.SQRT_TWO
		case .Farthest_Corner:
			r = circle ? math.sqrt(far.x * far.x + far.y * far.y) : far * math.SQRT_TWO
		case .Explicit:
			if circle { r = style.resolve(g.radius[0], w / scale) * scale } else { r = {style.resolve(g.radius[0], w / scale) * scale, style.resolve(g.radius[1], h / scale) * scale} }
		}
		out.radii = {max(r.x, MIN_RADIUS), max(r.y, MIN_RADIUS)}
		line = out.radii.x / scale
	case .Conic:
		out.center = {style.resolve(g.position[0], w / scale) * scale, style.resolve(g.position[1], h / scale) * scale}
		out.angle = g.angle
		line = 1
	}
	if line <= 0 { line = MIN_RADIUS }
	rs := style.gradient_stops(g, line, context.temp_allocator)
	stops := make([dynamic]Stop, 0, len(rs), context.temp_allocator)
	for s, i in rs {
		if s.hint {
			if len(stops) == 0 || i + 1 >= len(rs) { continue }
			prev := &stops[len(stops) - 1]
			a, b := prev.pos * line, rs[i + 1].pos
			span := b - a
			prev.has_hint = true
			prev.hint = span > 0 ? clamp((s.pos - a) / span, 0, 1) : HALF
			continue
		}
		append(&stops, Stop{pos = s.pos / line, color = premultiply(s.color)})
	}
	out.stops = stops[:]
	return out
}

// The colour at a position in the tile.
@(private)
gradient_color :: proc(g: ^Gradient_Paint, u: lay.Vec2) -> Pixel {
	HINT_MID :: HALF
	TURN :: 2 * math.PI
	if len(g.stops) == 0 { return {} }
	t: f32
	switch g.kind {
	case .Linear: t = linalg_dot(u - g.start, g.axis)
	case .Radial:
		d := (u - g.center) / g.radii
		t = math.sqrt(d.x * d.x + d.y * d.y)
	case .Conic:
		d := u - g.center
		// from the top, clockwise
		t = (math.atan2(d.x, -d.y) - g.angle) / TURN
		t -= math.floor(t)
	}
	first, last := g.stops[0].pos, g.stops[len(g.stops) - 1].pos
	if g.repeating && last > first {
		span := last - first
		t = first + (t - first) - math.floor((t - first) / span) * span
	}
	if t <= first { return g.stops[0].color }
	if t >= last { return g.stops[len(g.stops) - 1].color }
	for i in 0 ..< len(g.stops) - 1 {
		a, b := &g.stops[i], &g.stops[i + 1]
		if t > b.pos { continue }
		if b.pos <= a.pos { return b.color }
		k := (t - a.pos) / (b.pos - a.pos)
		if a.has_hint {
			// CSS Images 4 §3.5.3: the curve that passes through (hint, 1/2)
			if a.hint <= 0 { k = 1 } else if a.hint >= 1 { k = 0 } else { k = math.pow(k, math.log(f32(HINT_MID), f32(math.E)) / math.log(a.hint, f32(math.E))) }
		}
		return a.color + (b.color - a.color) * k
	}
	return g.stops[len(g.stops) - 1].color
}

@(private = "file")
linalg_dot :: #force_inline proc(a, b: lay.Vec2) -> f32 { return a.x * b.x + a.y * b.y }

////////////////////////////////
// Images

// The pixel of a picture under a position in a tile, without smoothing.
@(private)
content_sample :: proc(c: ^Content, u, size: lay.Vec2) -> Pixel {
	BYTE_SCALE :: 1.0 / 255.0
	x := clamp(int(u.x / size.x * f32(c.width)), 0, c.width - 1)
	y := clamp(int(u.y / size.y * f32(c.height)), 0, c.height - 1)
	p := c.pixels[y * c.stride + x * CHANNELS:][:CHANNELS]
	out := Pixel{f32(p[0]), f32(p[1]), f32(p[2]), f32(p[3])} * BYTE_SCALE
	if !c.premultiplied { out.rgb *= out.a }
	return out
}

@(private = "file")
Box_Rects :: struct {
	border, padding, content: lay.Rect,
	border_radii, padding_radii, content_radii: Radii,
}

// `widths` and `pad`: top, right, bottom, left.
@(private = "file")
box_rects :: proc(border: lay.Rect, radii: Radii, widths, pad: [4]f32) -> Box_Rects {
	b := Box_Rects{border = border, border_radii = radii}
	b.padding = snap_rect(lay.Rect{border.min + {widths[LEFT], widths[TOP]}, border.max - {widths[RIGHT], widths[BOTTOM]}})
	b.content = snap_rect(lay.Rect{border.min + {widths[LEFT] + pad[LEFT], widths[TOP] + pad[TOP]}, border.max - {widths[RIGHT] + pad[RIGHT], widths[BOTTOM] + pad[BOTTOM]}})
	b.padding_radii = inner_radii(radii, widths)
	b.content_radii = inner_radii(b.padding_radii, pad)
	return b
}

@(private = "file")
area_of :: proc(b: ^Box_Rects, a: style.Box_Area) -> (lay.Rect, Radii) {
	switch a {
	case .Border_Box: return b.border, b.border_radii
	case .Padding_Box: return b.padding, b.padding_radii
	case .Content_Box, .Text: return b.content, b.content_radii   // (background-clip: text: the content box, not the glyphs)
	}
	return b.border, b.border_radii
}

// One image layer in its positioning area, cut to `clip`.
@(private = "file")
paint_image_layer :: proc(rc: ^Raster, layer: ^style.Bg_Layer, pos_area, clip: lay.Rect, radii: Radii) {
	shape := Shape{rect = clip, radii = radii}
	area := pos_area
	// background-attachment: fixed: positioned against the viewport (only without a transform: a transform makes it scroll)
	if layer.attachment == .Fixed && rc.plain { area = lay.rect_shift(lay.Rect{{}, {f32(rc.w), f32(rc.h)}}, -rc.offs) }
	#partial switch layer.image.kind {
	case .Gradient:
		g := layer.image.grad
		if g == nil || len(g.stops) == 0 { return }
		t, ok := layer_tile(layer, area, rc.l.scale, {})
		if !ok { return }
		p := Paint{kind = .Gradient, tile = t, gradient = gradient_make(g, t.size, rc.l.scale)}
		fill(rc, &shape, &p)
	case .Url:
		if rc.host == nil || rc.host.css_image == nil { return }
		c := rc.host.css_image(rc.host.user, layer.image.url, 0, 0)
		switch c.kind {
		case .Nothing:
		case .Pending: rc.pending += 1
		case .Stand_In:
			p := solid(stand_in_color(c.key))
			fill(rc, &shape, &p)
		case .Pixels:
			t, ok := layer_tile(layer, area, rc.l.scale, c.natural, &c)
			if !ok { return }
			c = rc.host.css_image(rc.host.user, layer.image.url, int(math.ceil(t.size.x)), int(math.ceil(t.size.y)))
			if c.kind == .Pending { rc.pending += 1; return }
			if c.kind != .Pixels || c.width <= 0 || c.height <= 0 { return }
			p := Paint{kind = .Image, tile = t, content = &c}
			fill(rc, &shape, &p)
		}
	}
}

// Background colour and image layers, bottom first; the colour is clipped like the bottom layer (§3.10).
@(private = "file")
paint_backgrounds :: proc(rc: ^Raster, cs: ^style.Computed, b: ^Box_Rects) {
	layers := style.background_layers(cs)
	if cs.background_color.a > 0 && len(layers) > 0 {
		clip, radii := area_of(b, layers[len(layers) - 1].clip)
		shape := Shape{rect = clip, radii = radii}
		p := solid(cs.background_color)
		fill(rc, &shape, &p)
	}
	for i := len(layers) - 1; i >= 0; i -= 1 {
		layer := &layers[i]
		pos_area, _ := area_of(b, layer.origin)
		clip, radii := area_of(b, layer.clip)
		paint_image_layer(rc, layer, pos_area, clip, radii)
	}
}

// The box whose background is the canvas's: as canvas_source_box in render.odin.
@(private = "file")
canvas_source_box :: proc(l: ^lay.Layout) -> i32 {
	paints :: proc(cs: ^style.Computed) -> bool {
		if cs == nil { return false }
		if cs.background_color.a > 0 { return true }
		for im in cs.background_images { if im.kind != .None { return true } }
		return false
	}
	for k in 0 ..< len(l.canvas_items) {
		i := l.canvas_items[k]
		if i < 0 || int(i) >= len(l.items) { continue }
		if paints(l.items[i].cs) { return l.items[i].box }
	}
	return lay.NONE
}

// The background images of the canvas source, positioned against the root element's box, over the whole viewport.
@(private)
paint_canvas_images :: proc(rc: ^Raster) {
	l := rc.l
	src := canvas_source_box(l)
	if src == lay.NONE { return }
	cs := l.boxes[src].cs
	has_image := false
	for im in cs.background_images { if im.kind != .None { has_image = true; break } }
	if !has_image { return }
	ri := l.canvas_items[0]
	if ri < 0 { ri = l.canvas_items[1] }
	if ri < 0 || int(ri) >= len(l.items) { return }
	root := &l.items[ri]
	rb := &l.boxes[root.box]
	boxes := box_rects(snap_rect(root.rect), {}, {rb.border[TOP], rb.border[RIGHT], rb.border[BOTTOM], rb.border[LEFT]}, rb.padding)
	viewport := lay.rect_shift(lay.Rect{{}, {f32(rc.w), f32(rc.h)}}, -rc.offs)
	layers := style.background_layers(cs)
	for i := len(layers) - 1; i >= 0; i -= 1 {
		layer := &layers[i]
		pos_area, _ := area_of(&boxes, layer.origin)
		paint_image_layer(rc, layer, pos_area, viewport, {})
	}
}

////////////////////////////////
// Shadows

@(private)
Shadow_Paint :: struct {
	rect:    lay.Rect,
	radii:   Radii,
	sigma:   f32,
	color:   Pixel,
	inset:   bool,   // what is outside the shape is in shadow
}

@(private = "file")
erf :: proc(x: f32) -> f32 {
	a := abs(x)
	t := 1 / (1 + ERF_P * a)
	poly := t * (ERF_A[0] + t * (ERF_A[1] + t * (ERF_A[2] + t * (ERF_A[3] + t * ERF_A[4]))))
	v := 1 - poly * math.exp(-a * a)
	return x < 0 ? -v : v
}

// How much of a gaussian around `q` falls in the shape: exact for a rectangle, by distance to the edge for a rounded one.
@(private)
shadow_coverage :: proc(s: ^Shadow_Paint, q: lay.Vec2) -> f32 {
	cov: f32
	if s.sigma <= 0 {
		cov = rounded_contains(s.rect, &s.radii, q) ? 1 : 0
	} else if radii_zero(&s.radii) {
		k := 1 / (s.sigma * math.SQRT_TWO)
		cx := HALF * (erf((q.x - s.rect.min.x) * k) - erf((q.x - s.rect.max.x) * k))
		cy := HALF * (erf((q.y - s.rect.min.y) * k) - erf((q.y - s.rect.max.y) * k))
		cov = cx * cy
	} else {
		cov = HALF * (1 - erf(rounded_distance(s.rect, &s.radii, q) / (s.sigma * math.SQRT_TWO)))
	}
	return s.inset ? 1 - cov : cov
}

// CSS Backgrounds §7.1: a radius grows with the spread, less for corners smaller than it; a negative spread shrinks it.
@(private = "file")
spread_radii :: proc(r: Radii, spread: f32) -> Radii {
	one :: proc(v, spread: f32) -> f32 {
		if spread < 0 { return max(v + spread, 0) }
		if v <= 0 { return 0 }
		if v >= spread { return v + spread }
		k := v / spread - 1
		return v + spread * (1 + k * k * k)
	}
	out: Radii
	for c, i in r { out[i] = {one(c.x, spread), one(c.y, spread)} }
	return out
}

// The outer (inset = false) or inset shadows of `cs`, bottom first; outer ones are cut out of the border box.
@(private = "file")
paint_box_shadows :: proc(rc: ^Raster, cs: ^style.Computed, b: ^Box_Rects, inset: bool) {
	scale := rc.l.scale
	for i := len(cs.box_shadow) - 1; i >= 0; i -= 1 {
		s := cs.box_shadow[i]
		if s.inset != inset || s.color.a <= 0 { continue }
		sigma := s.blur * BLUR_RADIUS_SIGMAS * scale
		spread := s.spread * scale
		off := lay.Vec2{s.x, s.y} * scale
		sh := Shadow_Paint{sigma = sigma, color = premultiply(s.color), inset = inset}
		shape: Shape
		if !inset {
			r := lay.rect_shift(b.border, off)
			r.min -= spread
			r.max += spread
			if lay.rect_empty(r) { continue }
			sh.rect = r
			sh.radii = spread_radii(b.border_radii, spread)
			reach := sigma * SHADOW_REACH_SIGMAS
			shape = Shape{rect = {r.min - reach, r.max + reach}, hole = b.border, hole_radii = b.border_radii, has_hole = true}
		} else {
			r := lay.rect_shift(b.padding, off)
			r.min += spread
			r.max -= spread
			r.max = {max(r.max.x, r.min.x), max(r.max.y, r.min.y)}
			sh.rect = r
			sh.radii = spread_radii(b.padding_radii, -spread)
			shape = Shape{rect = b.padding, radii = b.padding_radii}
		}
		p := Paint{kind = .Shadow, shadow = &sh, color = sh.color}
		fill(rc, &shape, &p)
	}
}

////////////////////////////////
// Borders

@(private)
Border_Paint :: struct {
	outer, inner: lay.Rect,
	radii, inner_radii: Radii,
	rounded: bool,
	widths:  [4]f32,
	styles:  [4]style.Border_Style,
	colors:  [4]css_.Color,
	has_gap: bool,
	gap:     [2]f32,   // the top border stops between these x (a fieldset's legend)
}

@(private = "file")
shade :: proc(c: css_.Color, f: f32) -> Pixel {
	if f < 1 { return premultiply(css_.Color{c.r * f, c.g * f, c.b * f, c.a}) }
	t := f - 1
	return premultiply(css_.Color{c.r + (1 - c.r) * t, c.g + (1 - c.g) * t, c.b + (1 - c.b) * t, c.a})
}

// The colour of a pixel of the border's ring. A pixel belongs to the side it is proportionally nearest to: sides meet on
// the lines from the outer corners to the inner ones (CSS Backgrounds §4.4), with whatever their radii.
@(private)
border_pixel :: proc(b: ^Border_Paint, q: lay.Vec2) -> Pixel {
	d := [4]f32{q.y - b.outer.min.y, b.outer.max.x - q.x, b.outer.max.y - q.y, q.x - b.outer.min.x}
	side := -1
	best: f32 = max(f32)
	for i in 0 ..< 4 {
		if b.widths[i] <= 0 { continue }
		v := d[i] / b.widths[i]
		if v < best { best, side = v, i }
	}
	if side < 0 { return {} }
	if side == TOP && b.has_gap && q.x >= b.gap[0] && q.x < b.gap[1] { return {} }
	st := b.styles[side]
	c := b.colors[side]
	// how far across the thickness, from the outer edge: 0..1
	f := best
	if b.rounded {
		if _, _, ok := corner_at(b.outer, &b.radii, q); ok {
			to_outer := -rounded_distance(b.outer, &b.radii, q)
			to_inner := rounded_distance(b.inner, &b.inner_radii, q)
			if to_outer + to_inner > 0 { f = to_outer / (to_outer + to_inner) }
		}
	}
	horizontal := side == TOP || side == BOTTOM
	outer_first := side == TOP || side == LEFT
	switch st {
	case .None, .Hidden: return {}
	case .Solid: return premultiply(c)
	case .Double: return f < DOUBLE_THIRD || f >= 1 - DOUBLE_THIRD ? premultiply(c) : Pixel{}
	case .Groove, .Ridge:
		dark, light := shade(c, SHADE_DARK), shade(c, SHADE_LIGHT_RIDGE)
		a, e := dark, light
		if st == .Ridge { a, e = light, dark }
		if !outer_first { a, e = e, a }
		// (the outer half comes first along the coordinate, for a top or left side)
		return (f < GROOVE_HALF) == outer_first ? a : e
	case .Inset, .Outset:
		return (st == .Inset) == outer_first ? shade(c, SHADE_DARK) : shade(c, SHADE_LIGHT_OUTSET)
	case .Dashed, .Dotted:
		bw := b.widths[side]
		dot := st == .Dotted
		seg := dot ? bw : max(bw * DASH_LENGTH_WIDTHS, DASH_MIN_PX)
		gap := dot ? bw : max(bw * DASH_GAP_WIDTHS, DASH_MIN_PX)
		length := horizontal ? b.outer.max.x - b.outer.min.x : b.outer.max.y - b.outer.min.y - b.widths[TOP] - b.widths[BOTTOM]
		along := horizontal ? q.x - b.outer.min.x : q.y - b.outer.min.y - b.widths[TOP]
		if length <= 0 || along < 0 || along >= length { return {} }
		n := max(int((length + gap) / (seg + gap)), 1)
		// the gaps stretch so that the pattern ends on a dash
		g := n > 1 ? (length - f32(n) * seg) / f32(n - 1) : 0
		period := seg + g
		k := int(along / period)
		into := along - f32(k) * period
		if into >= seg { return {} }
		if dot {
			across := (f - HALF) * bw
			mid := into - seg * HALF
			if mid * mid + across * across > bw * bw * HALF * HALF { return {} }
		}
		return premultiply(c)
	}
	return {}
}

// Draws the border ring of `r`, snapped, as one paint: translucent sides are not drawn twice where they meet.
@(private = "file")
paint_borders :: proc(rc: ^Raster, r: lay.Rect, w: [4]f32, styles: [4]style.Border_Style, colors: [4]css_.Color, radii: Radii, has_gap := false, gap := [2]f32{}) {
	bp := Border_Paint{outer = r, radii = radii, widths = w, styles = styles, colors = colors, has_gap = has_gap, gap = gap}
	bp.inner = snap_rect(lay.Rect{r.min + {w[LEFT], w[TOP]}, r.max - {w[RIGHT], w[BOTTOM]}})
	bp.inner.max = {max(bp.inner.max.x, bp.inner.min.x), max(bp.inner.max.y, bp.inner.min.y)}
	bp.inner_radii = inner_radii(radii, w)
	r0 := radii
	bp.rounded = !radii_zero(&r0)
	shape := Shape{rect = r, radii = radii, hole = bp.inner, hole_radii = bp.inner_radii, has_hole = !lay.rect_empty(bp.inner)}
	p := Paint{kind = .Border, border = &bp}
	fill(rc, &shape, &p)
}

@(private = "file")
styles_of :: proc(cs: ^style.Computed) -> (styles: [4]style.Border_Style, colors: [4]css_.Color) {
	for s, i in SIDES { styles[i], colors[i] = cs.border_style[s], cs.border_color[s] }
	return
}

@(private)
paint_box :: proc(rc: ^Raster, it: ^lay.Display_Item) {
	cs := it.cs
	if cs == nil { return }
	l := rc.l
	b := &l.boxes[it.box]
	r := it.rect
	shift, gap, legend := lay.fieldset_border(l, it.box)
	if legend { r.min.y = min(r.min.y + shift, r.max.y) }
	r = snap_rect(r)
	radii := box_radii(cs, r.max.x - r.min.x, r.max.y - r.min.y, l.scale)
	widths := [4]f32{b.border[TOP], b.border[RIGHT], b.border[BOTTOM], b.border[LEFT]}
	boxes := box_rects(r, radii, widths, b.padding)
	if len(cs.box_shadow) > 0 { paint_box_shadows(rc, cs, &boxes, false) }
	if .No_Background not_in it.flags && it.box != canvas_source_box(l) { paint_backgrounds(rc, cs, &boxes) }
	if len(cs.box_shadow) > 0 { paint_box_shadows(rc, cs, &boxes, true) }
	if widths == {} { return }
	styles, colors := styles_of(cs)
	paint_borders(rc, r, widths, styles, colors, radii, legend && widths[TOP] > 0, gap)
}

// One line's piece of an inline box: rounded corners, borders and padding only where the box starts and ends.
@(private)
paint_inline_box :: proc(rc: ^Raster, it: ^lay.Display_Item) {
	cs := it.cs
	if cs == nil { return }
	l := rc.l
	b := &l.boxes[it.box]
	r := snap_rect(it.rect)
	radii := box_radii(cs, r.max.x - r.min.x, r.max.y - r.min.y, l.scale)
	left, right := .Left_Edge in it.flags, .Right_Edge in it.flags
	widths, pad: [4]f32
	if .Vertical in it.flags {
		// in a vertical line the start and the end are its top and bottom
		if !left { radii[0], radii[1] = {}, {} }
		if !right { radii[2], radii[3] = {}, {} }
		widths = {left ? b.border[TOP] : 0, b.border[RIGHT], right ? b.border[BOTTOM] : 0, b.border[LEFT]}
		pad = {left ? b.padding[TOP] : 0, b.padding[RIGHT], right ? b.padding[BOTTOM] : 0, b.padding[LEFT]}
	} else {
		if !left { radii[0], radii[3] = {}, {} }
		if !right { radii[1], radii[2] = {}, {} }
		widths = {b.border[TOP], right ? b.border[RIGHT] : 0, b.border[BOTTOM], left ? b.border[LEFT] : 0}
		pad = {b.padding[TOP], right ? b.padding[RIGHT] : 0, b.padding[BOTTOM], left ? b.padding[LEFT] : 0}
	}
	boxes := box_rects(r, radii, widths, pad)
	if len(cs.box_shadow) > 0 { paint_box_shadows(rc, cs, &boxes, false) }
	paint_backgrounds(rc, cs, &boxes)
	if len(cs.box_shadow) > 0 { paint_box_shadows(rc, cs, &boxes, true) }
	if widths == {} { return }
	styles, colors := styles_of(cs)
	paint_borders(rc, r, widths, styles, colors, radii)
}

// The outline: whole pixels wide, outside the border box by its offset (as render.odin).
@(private)
paint_outline :: proc(rc: ^Raster, it: ^lay.Display_Item) {
	OUTLINE_WIDTH_EPSILON :: 0.001
	cs := it.cs
	if cs == nil || cs.outline_width <= 0 { return }
	st := cs.outline_style
	if st == .None || st == .Hidden { return }
	scale := rc.l.scale
	w := max(1, math.floor(cs.outline_width * scale + OUTLINE_WIDTH_EPSILON))
	r := snap_rect(it.rect)
	grow := cs.outline_offset * scale + w
	o := snap_rect(lay.Rect{r.min - grow, r.max + grow})
	if lay.rect_empty(o) { return }
	radii := box_radii(cs, r.max.x - r.min.x, r.max.y - r.min.y, scale)
	if !radii_zero(&radii) {
		for &c in radii { if c.x > 0 && c.y > 0 { c += grow } }
	}
	paint_borders(rc, o, {w, w, w, w}, {st, st, st, st}, {cs.outline_color, cs.outline_color, cs.outline_color, cs.outline_color}, radii)
}

////////////////////////////////
// Replaced content

// object-fit / object-position (CSS Images 3 §5.5): as fit_rect in images_shell.odin.
@(private = "file")
fit_rect :: proc(content: lay.Rect, natural: [2]f32, cs: ^style.Computed, scale: f32) -> lay.Rect {
	cw, ch := content.max.x - content.min.x, content.max.y - content.min.y
	nw, nh := natural[0] * scale, natural[1] * scale
	if nw <= 0 || nh <= 0 || cs == nil { return content }
	w, h := cw, ch
	switch cs.object_fit {
	case .Fill:
	case .Contain, .Cover:
		k := cs.object_fit == .Contain ? min(cw / nw, ch / nh) : max(cw / nw, ch / nh)
		w, h = nw * k, nh * k
	case .None: w, h = nw, nh
	case .Scale_Down:
		k := min(cw / nw, ch / nh, 1)
		w, h = nw * k, nh * k
	}
	x := content.min.x + style.resolve(cs.object_position[0], (cw - w) / scale) * scale
	y := content.min.y + style.resolve(cs.object_position[1], (ch - h) / scale) * scale
	return {{x, y}, {x + w, y + h}}
}

@(private)
paint_content :: proc(rc: ^Raster, it: ^lay.Display_Item) {
	if rc.host == nil || rc.host.replaced == nil { return }
	l := rc.l
	content := snap_rect(it.rect)
	if lay.rect_empty(content) { return }
	w, h := int(content.max.x - content.min.x), int(content.max.y - content.min.y)
	c := rc.host.replaced(rc.host.user, l, it, w, h)
	// border-radius rounds the picture with the content box
	radii: Radii
	if it.box != lay.NONE && it.cs != nil {
		b := &l.boxes[it.box]
		o := Radii{}
		o = box_radii(it.cs, b.size.x, b.size.y, l.scale)
		if !radii_zero(&o) {
			border := lay.Rect{b.abs, b.abs + b.size}
			radii = inner_radii(o, {content.min.y - border.min.y, border.max.x - content.max.x, border.max.y - content.max.y, content.min.x - border.min.x})
		}
	}
	shape := Shape{rect = content, radii = radii}
	switch c.kind {
	case .Nothing:
	case .Pending: rc.pending += 1
	case .Stand_In:
		p := solid(stand_in_color(c.key))
		fill(rc, &shape, &p)
	case .Pixels:
		if c.width <= 0 || c.height <= 0 { return }
		dst := snap_rect(fit_rect(content, c.natural, it.cs, l.scale))
		if lay.rect_empty(dst) { return }
		p := Paint{kind = .Image, tile = Tile{origin = dst.min, size = dst.max - dst.min}, content = &c}
		fill(rc, &shape, &p)
	}
}

// A rule between columns: a border that has only one side, across its rect.
@(private)
paint_column_rule :: proc(rc: ^Raster, it: ^lay.Display_Item) {
	cs := it.cs
	if cs == nil { return }
	st, c := cs.column_rule_style, cs.column_rule_color
	r := snap_rect(it.rect)
	w: [4]f32
	if .Vertical in it.flags { w[TOP] = r.max.y - r.min.y } else { w[LEFT] = r.max.x - r.min.x }
	paint_borders(rc, r, w, {st, st, st, st}, {c, c, c, c}, {})
}
