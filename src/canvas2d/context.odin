package canvas2d

import "core:math"
import "core:strings"

Text_Align :: enum u8 { Start, End, Left, Right, Center }
Text_Baseline :: enum u8 { Alphabetic, Top, Hanging, Middle, Ideographic, Bottom }
Text_Direction :: enum u8 { Inherit, Ltr, Rtl }
Smoothing_Quality :: enum u8 { Low, Medium, High }

// What a fill or stroke paints with: a color, a gradient or a pattern (the last two shared with the script's objects).
Style :: struct {
	kind:  Paint_Kind,   // Solid, Gradient or Pattern
	color: [4]f32,
	grad:  ^Gradient,
	pat:   ^Pattern,
}

Shadow :: struct {
	color:  [4]f32,   // straight; alpha 0 = no shadow
	blur:   f64,
	ox, oy: f64,
}

// The clipping region: a pixel rectangle and, when the region is not the whole rectangle, 8-bit coverage over it.
Clip :: struct {
	refs:           int,
	x0, y0, x1, y1: int,
	mask:           []u8,   // (x1 - x0) x (y1 - y0), nil = fully covered
}

// Everything save() keeps.
State :: struct {
	ctm:           Matrix,
	fill, stroke:  Style,
	line_width:    f64,
	miter_limit:   f64,
	cap:           Line_Cap,
	join:          Line_Join,
	dash:          []f64,
	dash_offset:   f64,
	alpha:         f64,
	op:            Composite_Op,
	shadow:        Shadow,
	smoothing:     bool,
	quality:       Smoothing_Quality,
	clip:          ^Clip,
	font:          Font_Spec,
	text_align:    Text_Align,
	baseline:      Text_Baseline,
	direction:     Text_Direction,
	letter_spacing: f64,   // CSS pixels
	word_spacing:  f64,
	font_kerning:  u8,     // 0 auto, 1 normal, 2 none (kept for the getter; the text engine always kerns)
	font_stretch:  u8,     // CanvasFontStretch index
	variant_caps:  u8,
	text_rendering: u8,
	lang:          string,
	filter:        []Filter_Op,   // the parsed `filter` (empty: none)
	filter_text:   string,
}

Options :: struct {
	samples:         int,    // sub-scanlines per pixel row (antialiasing quality)
	flatness:        f64,    // curve flattening tolerance, device pixels
	max_states:      int,    // save() depth
	max_dashes:      int,    // dash pieces of one subpath before the line is drawn solid
	max_layer_bytes: int,    // the temporary layer of a shadow or a source-in
	max_bytes:       int,    // any other temporary bitmap (patterns, getImageData...)
	smooth_default:  bool,   // imageSmoothingEnabled of a new context
	filters:         bool,   // the filter property does something
}

DEFAULT_OPTIONS :: Options{
	samples = 16, flatness = 0.05, max_states = 4096, max_dashes = 100_000,
	max_layer_bytes = 256 << 20, max_bytes = 256 << 20, smooth_default = true, filters = true,
}

Context :: struct {
	bmp:     ^Bitmap,
	state:   State,
	stack:   [dynamic]State,
	path:    Path,
	opts:    Options,
	text:    Text_Engine,
	host:    Host,
	inherit: Inherited,        // the canvas element's direction and font size
	r:       Raster,
	flat:    Flat,
	polys:   Polys,
}

// Services of the page the context needs: parsing a CSS color (drop-shadow() in a filter).
Host :: struct {
	user:  rawptr,
	color: proc(user: rawptr, s: string) -> ([4]f32, bool),
}

// What the context inherits from its canvas element (it changes with the page's styles).
Inherited :: struct {
	rtl:       bool,
	font_size: f64,    // em in `font` is relative to this; 10 when the element has none
	color:     [4]f32, // currentcolor
}

context_init :: proc(c: ^Context, bmp: ^Bitmap, opts: Options) {
	c.bmp = bmp
	c.opts = opts
	c.inherit = Inherited{font_size = 10, color = {0, 0, 0, 1}}
	c.state = state_default()
	c.state.smoothing = opts.smooth_default
}

context_destroy :: proc(c: ^Context) {
	state_destroy(&c.state)
	for &s in c.stack { state_destroy(&s) }
	delete(c.stack)
	path_destroy(&c.path)
	raster_destroy(&c.r)
	flat_destroy(&c.flat)
	polys_destroy(&c.polys)
	c^ = {}
}

state_default :: proc() -> State {
	s := State{
		ctm = IDENTITY, line_width = 1, miter_limit = 10, alpha = 1, op = .Source_Over, smoothing = true,
		font = font_spec_default(),
	}
	s.fill = Style{kind = .Solid, color = {0, 0, 0, 1}}
	s.stroke = s.fill
	return s
}

state_destroy :: proc(s: ^State) {
	style_clear(&s.fill)
	style_clear(&s.stroke)
	clip_release(s.clip)
	delete(s.dash)
	delete(s.filter)
	delete(s.filter_text)
	delete(s.lang)
	font_spec_destroy(&s.font)
	s^ = {}
}

state_clone :: proc(s: ^State) -> State {
	r := s^
	r.fill.grad = gradient_retain(s.fill.grad)
	r.fill.pat = pattern_retain(s.fill.pat)
	r.stroke.grad = gradient_retain(s.stroke.grad)
	r.stroke.pat = pattern_retain(s.stroke.pat)
	r.clip = clip_retain(s.clip)
	if s.dash != nil { r.dash = make([]f64, len(s.dash)); copy(r.dash, s.dash) }
	r.font = font_spec_clone(&s.font)
	if s.filter != nil { r.filter = make([]Filter_Op, len(s.filter)); copy(r.filter, s.filter) }
	r.filter_text = strings.clone(s.filter_text)
	r.lang = strings.clone(s.lang)
	return r
}

style_clear :: proc(s: ^Style) {
	gradient_release(s.grad)
	pattern_release(s.pat)
	s^ = {}
}

style_set_color :: proc(s: ^Style, c: [4]f32) {
	style_clear(s)
	s.kind, s.color = .Solid, c
}

style_set_gradient :: proc(s: ^Style, g: ^Gradient) {
	new_g := gradient_retain(g)
	style_clear(s)
	s.kind, s.grad = .Gradient, new_g
}

style_set_pattern :: proc(s: ^Style, p: ^Pattern) {
	new_p := pattern_retain(p)
	style_clear(s)
	s.kind, s.pat = .Pattern, new_p
}

clip_retain :: proc(c: ^Clip) -> ^Clip {
	if c != nil { c.refs += 1 }
	return c
}

clip_release :: proc(c: ^Clip) {
	if c == nil { return }
	c.refs -= 1
	if c.refs <= 0 {
		delete(c.mask)
		free(c)
	}
}

// save(): false when the stack is full (the call is ignored).
context_save :: proc(c: ^Context) -> bool {
	if len(c.stack) >= max(c.opts.max_states, 1) { return false }
	append(&c.stack, state_clone(&c.state))
	return true
}

context_restore :: proc(c: ^Context) {
	if len(c.stack) == 0 { return }
	state_destroy(&c.state)
	c.state = pop(&c.stack)
}

// reset(), and what a change of the canvas's size does: the bitmap is cleared, the stack and path dropped, every
// attribute back to its default.
context_reset :: proc(c: ^Context) {
	for &s in c.stack { state_destroy(&s) }
	clear(&c.stack)
	state_destroy(&c.state)
	c.state = state_default()
	c.state.smoothing = c.opts.smooth_default
	path_clear(&c.path)
	if c.bmp != nil && len(c.bmp.pix) > 0 { bitmap_reset_contents(c.bmp) }
}

////////////////////////////////
// Transformation

ctx_transform :: proc(c: ^Context, a, b, cc, d, e, f: f64) {
	if !all_finite(a, b, cc, d, e, f) { return }
	m := matrix_mul(c.state.ctm, Matrix{a, b, cc, d, e, f})
	if matrix_finite(m) { c.state.ctm = m }
}

ctx_set_transform :: proc(c: ^Context, a, b, cc, d, e, f: f64) {
	if !all_finite(a, b, cc, d, e, f) { return }
	c.state.ctm = Matrix{a, b, cc, d, e, f}
}

ctx_translate :: proc(c: ^Context, x, y: f64) { ctx_transform(c, 1, 0, 0, 1, x, y) }
ctx_scale :: proc(c: ^Context, x, y: f64) { ctx_transform(c, x, 0, 0, y, 0, 0) }
ctx_rotate :: proc(c: ^Context, angle: f64) {
	if !is_finite(angle) { return }
	m := matrix_rotate(angle)
	ctx_transform(c, m.a, m.b, m.c, m.d, 0, 0)
}

ctx_reset_transform :: proc(c: ^Context) { c.state.ctm = IDENTITY }

////////////////////////////////
// Painting machinery

@(private)
Job :: struct {
	target:  ^Bitmap,
	ox, oy:  int,         // canvas position of the target's top-left pixel
	paint:   ^Paint,
	op:      Composite_Op,
	alpha:   f32,
	clip:    ^Clip,       // nil: none
	touch:   [4]int,      // x0 y0 x1 y1 written (canvas coordinates)
}

@(private)
clip_coverage :: #force_inline proc "contextless" (cl: ^Clip, x, y: int) -> f32 {
	if x < cl.x0 || x >= cl.x1 || y < cl.y0 || y >= cl.y1 { return 0 }
	if cl.mask == nil { return 1 }
	return f32(cl.mask[(y - cl.y0) * (cl.x1 - cl.x0) + (x - cl.x0)]) * (1.0 / 255.0)
}

@(private)
load_px :: #force_inline proc "contextless" (b: ^Bitmap, x, y: int) -> [4]f32 {
	p := b.pix[(y * b.w + x) * 4:][:4]
	return {f32(p[0]), f32(p[1]), f32(p[2]), f32(p[3])} * (1.0 / 255.0)
}

@(private)
store_px :: #force_inline proc "contextless" (b: ^Bitmap, x, y: int, v: [4]f32) {
	p := b.pix[(y * b.w + x) * 4:][:4]
	a := b.opaque ? 1 : clamp(v.a, 0, 1)   // (an opaque canvas shows the color over black: the premultiplied color stays)
	p[3] = u8(a * 255 + 0.5)
	// premultiplied color cannot exceed alpha
	p[0] = u8(min(clamp(v.r, 0, 1), a) * 255 + 0.5)
	p[1] = u8(min(clamp(v.g, 0, 1), a) * 255 + 0.5)
	p[2] = u8(min(clamp(v.b, 0, 1), a) * 255 + 0.5)
}

@(private)
job_row :: proc(user: rawptr, y, x0: int, cov: []f32) {
	j := (^Job)(user)
	ty := y - j.oy
	if ty < 0 || ty >= j.target.h { return }
	// the part of the run inside the target
	i0, i1 := 0, len(cov)
	if x0 - j.ox < 0 { i0 = j.ox - x0 }
	if x0 + i1 - j.ox > j.target.w { i1 = j.target.w - (x0 - j.ox) }
	if i0 >= i1 { return }
	p := j.paint
	tw := j.target.w
	row := j.target.pix[ty * tw * 4:][:tw * 4]
	over8 := j.op == .Source_Over && !j.target.opaque   // the common case runs on 8-bit integers
	// a linear gradient is an affine function of x along a row: t is stepped, not computed from the matrix
	stepped := p.kind == .Gradient && p.grad.kind == .Linear && p.lut != nil
	t, dt := 0.0, 0.0
	if stepped {
		g := p.grad
		dx, dy := g.x1 - g.x0, g.y1 - g.y0
		len2 := dx * dx + dy * dy
		if len2 == 0 { return }   // (nothing is painted)
		q := matrix_apply(p.inv, {f64(x0 + i0) + 0.5, f64(y) + 0.5})
		t = ((q.x - g.x0) * dx + (q.y - g.y0) * dy) / len2
		dt = (p.inv.a * dx + p.inv.b * dy) / len2
	}
	for i in i0 ..< i1 {
		x := x0 + i
		a := cov[i] * j.alpha
		if j.clip != nil { a *= clip_coverage(j.clip, x, y) }
		ti := t
		t += dt
		if a <= 0 { continue }
		px := row[(x - j.ox) * 4:][:4]
		if over8 {
			s: [4]u32
			switch {
			case p.kind == .Solid: s = p.s8
			case stepped:
				e := p.lut[int(clamp(ti, 0, 1) * f64(LUT_SIZE - 1) + 0.5)]
				s = {u32(e[0]), u32(e[1]), u32(e[2]), u32(e[3])}
			case:
				f := paint_at(p, x, y)
				s = {u32(f.r * 255 + 0.5), u32(f.g * 255 + 0.5), u32(f.b * 255 + 0.5), u32(f.a * 255 + 0.5)}
			}
			if a < 0.998 {
				s[0], s[1], s[2], s[3] = u32(f32(s[0]) * a + 0.5), u32(f32(s[1]) * a + 0.5), u32(f32(s[2]) * a + 0.5), u32(f32(s[3]) * a + 0.5)
			}
			sa := s[3]
			if sa == 0 { continue }
			if sa >= 255 {
				px[0], px[1], px[2], px[3] = u8(s[0]), u8(s[1]), u8(s[2]), 255
			} else {
				inv := 255 - sa
				px[0] = u8(min(s[0] + (u32(px[0]) * inv + 127) / 255, 255))
				px[1] = u8(min(s[1] + (u32(px[1]) * inv + 127) / 255, 255))
				px[2] = u8(min(s[2] + (u32(px[2]) * inv + 127) / 255, 255))
				px[3] = u8(min(sa + (u32(px[3]) * inv + 127) / 255, 255))
			}
			continue
		}
		src := p.kind == .Solid ? p.premul : paint_at(p, x, y)
		src *= a
		d := load_px(j.target, x - j.ox, ty)
		out: [4]f32
		if j.op == .Source_Over {
			out = src + d * (1 - src.a)
		} else {
			out = blend(j.op, src, d)
		}
		store_px(j.target, x - j.ox, ty, out)
	}
	j.touch = {min(j.touch[0], x0), min(j.touch[1], y), max(j.touch[2], x0 + len(cov)), max(j.touch[3], y + 1)}
}

// A table of a gradient's premultiplied colors, for fills of many pixels: one lookup per pixel instead of a search of
// the stops. Built when the shape covers `area` pixels or more.
@(private)
paint_lut :: proc(p: ^Paint, area: int) {
	if p.kind != .Gradient || p.lut != nil || area < 4096 { return }
	p.lut = make([][4]u8, LUT_SIZE, context.temp_allocator)
	for k in 0 ..< LUT_SIZE {
		c := premultiply(gradient_color(p.grad, f64(k) / f64(LUT_SIZE - 1)))
		p.lut[k] = {u8(c.r * 255 + 0.5), u8(c.g * 255 + 0.5), u8(c.b * 255 + 0.5), u8(c.a * 255 + 0.5)}
	}
}
@(private)
shadow_active :: proc "contextless" (c: ^Context) -> bool {
	s := &c.state.shadow
	return s.color.a > 0 && (s.blur > 0 || s.ox != 0 || s.oy != 0)
}

// The pixel rectangle drawing may touch: the bitmap, and the clip's rectangle.
@(private)
draw_bounds :: proc "contextless" (c: ^Context) -> (x0, y0, x1, y1: int) {
	x0, y0, x1, y1 = 0, 0, c.bmp.w, c.bmp.h
	if cl := c.state.clip; cl != nil {
		x0, y0, x1, y1 = max(x0, cl.x0), max(y0, cl.y0), min(x1, cl.x1), min(y1, cl.y1)
	}
	return
}

// The paint for a style under the current transform. false: nothing can be drawn (a singular transform).
@(private)
make_paint :: proc(c: ^Context, s: ^Style, alpha_only := false) -> (p: Paint, ok: bool) {
	switch s.kind {
	case .Solid, .Image:
		return paint_solid(s.color), true
	case .Gradient:
		inv, iok := matrix_invert(c.state.ctm)
		if !iok { return }
		return Paint{kind = .Gradient, grad = s.grad, inv = inv}, true
	case .Pattern:
		inv, iok := matrix_invert(matrix_mul(c.state.ctm, s.pat.transform))
		if !iok { return }
		return Paint{kind = .Pattern, pat = s.pat, inv = inv, img = Image_Source{smooth = c.state.smoothing}}, true
	}
	return
}

// Fills the edges in c.r under the current state (operator, alpha, clip, shadow) with `paint`.
@(private)
paint_edges :: proc(c: ^Context, rule: Fill_Rule, paint: ^Paint) {
	ex0, ey0, ex1, ey1, ok := raster_extent(&c.r)
	if !ok { return }
	paint_lut(paint, (ex1 - ex0) * (ey1 - ey0))
	st := &c.state
	op := st.op
	alpha := f32(clamp(st.alpha, 0, 1))
	bx0, by0, bx1, by1 := draw_bounds(c)
	shadow := shadow_active(c)
	filtered := filter_active(c)
	if !shadow && !filtered && !op_is_unbounded(op) {
		j := Job{target = c.bmp, paint = paint, op = op, alpha = alpha, clip = st.clip, touch = {max(int), max(int), min(int), min(int)}}
		raster_fill(&c.r, rule, max(bx0, ex0), max(by0, ey0), min(bx1, ex1), min(by1, ey1), c.opts.samples, job_row, &j)
		bitmap_touch(c.bmp, j.touch[0], j.touch[1], j.touch[2], j.touch[3])
		return
	}
	// A layer: the shape is drawn by itself (source-over onto transparent black), then filtered, shadowed and
	// composited. A shadow needs it to blur and offset the shape, a filter to work on the shape alone, an unbounded
	// operator to act on the pixels the shape leaves alone.
	lx0, ly0, lx1, ly1 := ex0, ey0, ex1, ey1
	reach := filtered ? filter_reach(c) : 0
	if reach > 0 { lx0, ly0, lx1, ly1 = lx0 - reach, ly0 - reach, lx1 + reach, ly1 + reach }
	if shadow {
		sreach := int(math.ceil(max(st.shadow.blur, 0) * 1.5)) + 1
		slack := sreach + reach
		lx0, ly0 = max(lx0, -slack - int(min(st.shadow.ox, 0))), max(ly0, -slack - int(min(st.shadow.oy, 0)))
		lx1, ly1 = min(lx1, c.bmp.w + slack + int(max(-st.shadow.ox, 0))), min(ly1, c.bmp.h + slack + int(max(-st.shadow.oy, 0)))
	} else if filtered {
		lx0, ly0, lx1, ly1 = max(lx0, bx0 - reach), max(ly0, by0 - reach), min(lx1, bx1 + reach), min(ly1, by1 + reach)
	} else {
		lx0, ly0, lx1, ly1 = max(lx0, bx0), max(ly0, by0), min(lx1, bx1), min(ly1, by1)
	}
	if lx0 >= lx1 || ly0 >= ly1 {
		if op_is_unbounded(op) { composite_layer(c, nil, 0, 0, op, true) }
		return
	}
	layer, lok := bitmap_create(lx1 - lx0, ly1 - ly0, c.opts.max_layer_bytes)
	if !lok { return }
	defer bitmap_destroy(&layer)
	j := Job{target = &layer, ox = lx0, oy = ly0, paint = paint, op = .Source_Over, alpha = alpha, touch = {max(int), max(int), min(int), min(int)}}
	raster_fill(&c.r, rule, lx0, ly0, lx1, ly1, c.opts.samples, job_row, &j)
	if filtered { filter_apply(c, &layer) }
	if shadow { composite_shadow(c, &layer, lx0, ly0) }
	composite_layer(c, &layer, lx0, ly0, op, op_is_unbounded(op))
}

// The layer's pixels onto the canvas with `op`, under the clip. `layer` nil: a transparent source. `unbounded`:
// the whole clip region takes part, not only the layer's rectangle.
@(private)
composite_layer :: proc(c: ^Context, layer: ^Bitmap, lx, ly: int, op: Composite_Op, unbounded: bool) {
	bx0, by0, bx1, by1 := draw_bounds(c)
	x0, y0, x1, y1 := bx0, by0, bx1, by1
	if !unbounded {
		if layer == nil { return }
		x0, y0, x1, y1 = max(x0, lx), max(y0, ly), min(x1, lx + layer.w), min(y1, ly + layer.h)
	}
	if x0 >= x1 || y0 >= y1 { return }
	cl := c.state.clip
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			s: [4]f32
			if layer != nil && x >= lx && x < lx + layer.w && y >= ly && y < ly + layer.h { s = load_px(layer, x - lx, y - ly) }
			m := cl != nil ? clip_coverage(cl, x, y) : 1
			if m <= 0 { continue }
			if s.a <= 0 && !unbounded { continue }
			d := load_px(c.bmp, x, y)
			out := blend(op, s * m, d)
			if m < 1 && unbounded { out = d + (out - d) * m }
			store_px(c.bmp, x, y, out)
		}
	}
	bitmap_touch(c.bmp, x0, y0, x1, y1)
}

// The shadow of a layer: its alpha blurred, offset and tinted, composited with the current operator.
@(private)
composite_shadow :: proc(c: ^Context, layer: ^Bitmap, lx, ly: int) {
	st := &c.state
	sigma := st.shadow.blur * 0.5
	pad := sigma > 0 ? int(math.ceil(sigma * 3)) : 0
	pw, ph := layer.w + 2 * pad, layer.h + 2 * pad
	if pw * ph * 4 > c.opts.max_layer_bytes { return }
	plane := make([]f32, pw * ph)
	defer delete(plane)
	for y in 0 ..< layer.h {
		for x in 0 ..< layer.w {
			plane[(y + pad) * pw + x + pad] = f32(layer.pix[(y * layer.w + x) * 4 + 3]) * (1.0 / 255.0)
		}
	}
	if sigma > 0 { gaussian_blur(plane, pw, ph, sigma) }
	// the offset is in device pixels, unaffected by the transform
	ox, oy := int(math.round(st.shadow.ox)), int(math.round(st.shadow.oy))
	col := premultiply(st.shadow.color)
	x0, y0 := lx - pad + ox, ly - pad + oy
	bx0, by0, bx1, by1 := draw_bounds(c)
	cl := st.clip
	op := st.op
	for y in max(y0, by0) ..< min(y0 + ph, by1) {
		for x in max(x0, bx0) ..< min(x0 + pw, bx1) {
			a := plane[(y - y0) * pw + (x - x0)]
			if a <= 0.0005 { continue }
			m := cl != nil ? clip_coverage(cl, x, y) : 1
			if m <= 0 { continue }
			s := col * (a * m)
			store_px(c.bmp, x, y, blend(op, s, load_px(c.bmp, x, y)))
		}
	}
	bitmap_touch(c.bmp, max(x0, bx0), max(y0, by0), min(x0 + pw, bx1), min(y0 + ph, by1))
}

////////////////////////////////
// Rectangles

ctx_fill_rect :: proc(c: ^Context, x, y, w, h: f64) {
	if !all_finite(x, y, w, h) || w == 0 || h == 0 || c.bmp == nil || c.bmp.w == 0 { return }
	paint, ok := make_paint(c, &c.state.fill)
	if !ok { return }
	fill_rect_with(c, x, y, w, h, &paint)
}

@(private)
fill_rect_with :: proc(c: ^Context, x, y, w, h: f64, paint: ^Paint) {
	m := c.state.ctm
	raster_reset(&c.r)
	if m.b == 0 && m.c == 0 && !shadow_active(c) && !filter_active(c) && !op_is_unbounded(c.state.op) {
		// no rotation or skew: exact box coverage
		p0, p1 := matrix_apply(m, {x, y}), matrix_apply(m, {x + w, y + h})
		bx0, by0, bx1, by1 := draw_bounds(c)
		paint_lut(paint, int(abs((p1.x - p0.x) * (p1.y - p0.y))))
		j := Job{target = c.bmp, paint = paint, op = c.state.op, alpha = f32(clamp(c.state.alpha, 0, 1)), clip = c.state.clip,
			touch = {max(int), max(int), min(int), min(int)}}
		raster_fill_rect(&c.r, min(p0.x, p1.x), min(p0.y, p1.y), max(p0.x, p1.x), max(p0.y, p1.y), bx0, by0, bx1, by1, job_row, &j)
		bitmap_touch(c.bmp, j.touch[0], j.touch[1], j.touch[2], j.touch[3])
		return
	}
	corners := [4][2]f64{
		clamp_pt(matrix_apply(m, {x, y})), clamp_pt(matrix_apply(m, {x + w, y})),
		clamp_pt(matrix_apply(m, {x + w, y + h})), clamp_pt(matrix_apply(m, {x, y + h})),
	}
	raster_add_polygon(&c.r, corners[:])
	paint_edges(c, .Nonzero, paint)
}

ctx_clear_rect :: proc(c: ^Context, x, y, w, h: f64) {
	if !all_finite(x, y, w, h) || w == 0 || h == 0 || c.bmp == nil || c.bmp.w == 0 { return }
	m := c.state.ctm
	corners := [4][2]f64{
		clamp_pt(matrix_apply(m, {x, y})), clamp_pt(matrix_apply(m, {x + w, y})),
		clamp_pt(matrix_apply(m, {x + w, y + h})), clamp_pt(matrix_apply(m, {x, y + h})),
	}
	raster_reset(&c.r)
	raster_add_polygon(&c.r, corners[:])
	bx0, by0, bx1, by1 := draw_bounds(c)
	ex0, ey0, ex1, ey1, ok := raster_extent(&c.r)
	if !ok { return }
	j := Job{target = c.bmp, clip = c.state.clip, touch = {max(int), max(int), min(int), min(int)}}
	raster_fill(&c.r, .Nonzero, max(bx0, ex0), max(by0, ey0), min(bx1, ex1), min(by1, ey1), c.opts.samples, clear_row, &j)
	bitmap_touch(c.bmp, j.touch[0], j.touch[1], j.touch[2], j.touch[3])
}

@(private)
clear_row :: proc(user: rawptr, y, x0: int, cov: []f32) {
	j := (^Job)(user)
	for i in 0 ..< len(cov) {
		x := x0 + i
		a := cov[i]
		if j.clip != nil { a *= clip_coverage(j.clip, x, y) }
		if a <= 0 { continue }
		d := load_px(j.target, x, y)
		store_px(j.target, x, y, d * (1 - a))
	}
	j.touch = {min(j.touch[0], x0), min(j.touch[1], y), max(j.touch[2], x0 + len(cov)), max(j.touch[3], y + 1)}
}

ctx_stroke_rect :: proc(c: ^Context, x, y, w, h: f64) {
	if !all_finite(x, y, w, h) || (w == 0 && h == 0) || c.bmp == nil || c.bmp.w == 0 { return }
	var := Path{}
	defer path_destroy(&var)
	path_move_to(&var, IDENTITY, x, y)
	path_line_to(&var, IDENTITY, x + w, y)
	path_line_to(&var, IDENTITY, x + w, y + h)
	path_line_to(&var, IDENTITY, x, y + h)
	path_close(&var)
	stroke_path_with(c, &var, c.state.ctm)
}

////////////////////////////////
// Paths

// fill() of the current path, or of a Path2D (`path` non-nil, user space: the CTM applies).
ctx_fill :: proc(c: ^Context, rule: Fill_Rule, path: ^Path = nil) {
	if c.bmp == nil || c.bmp.w == 0 { return }
	paint, ok := make_paint(c, &c.state.fill)
	if !ok { return }
	fill_path_with(c, path != nil ? path : &c.path, path != nil ? c.state.ctm : IDENTITY, rule, &paint)
}

@(private)
fill_path_with :: proc(c: ^Context, p: ^Path, m: Matrix, rule: Fill_Rule, paint: ^Paint) {
	if path_is_empty(p) { return }
	flat_clear(&c.flat)
	path_flatten(p, m, c.opts.flatness, &c.flat)
	raster_reset(&c.r)
	raster_add_flat(&c.r, &c.flat)
	paint_edges(c, rule, paint)
}

ctx_stroke :: proc(c: ^Context, path: ^Path = nil) {
	if c.bmp == nil || c.bmp.w == 0 { return }
	if path != nil { stroke_path_with(c, path, c.state.ctm) } else { stroke_path_with(c, &c.path, IDENTITY) }
}

// Strokes `p` (points in the space `m` takes to device space) with the current stroke style.
@(private)
stroke_path_with :: proc(c: ^Context, p: ^Path, m: Matrix) {
	if path_is_empty(p) { return }
	paint, ok := make_paint(c, &c.state.stroke)
	if !ok { return }
	st := &c.state
	style := current_stroke_style(c)
	flat_clear(&c.flat)
	path_flatten(p, m, c.opts.flatness, &c.flat)
	polys_clear(&c.polys)
	polys_stroke(&c.flat, st.ctm, &style, c.opts.flatness, &c.polys)
	raster_reset(&c.r)
	raster_add_polys(&c.r, &c.polys)
	paint_edges(c, .Nonzero, &paint)
}

@(private)
current_stroke_style :: proc(c: ^Context) -> Stroke_Style {
	st := &c.state
	return Stroke_Style{
		width = st.line_width, cap = st.cap, join = st.join, miter_limit = st.miter_limit,
		dash = st.dash, dash_offset = st.dash_offset, max_dashes = c.opts.max_dashes,
	}
}

// clip(): the region becomes its intersection with the path's (antialiased).
ctx_clip :: proc(c: ^Context, rule: Fill_Rule, path: ^Path = nil) {
	if c.bmp == nil { return }
	p := path != nil ? path : &c.path
	m := path != nil ? c.state.ctm : IDENTITY
	flat_clear(&c.flat)
	path_flatten(p, m, c.opts.flatness, &c.flat)
	raster_reset(&c.r)
	raster_add_flat(&c.r, &c.flat)
	old := c.state.clip
	bx0, by0, bx1, by1 := draw_bounds(c)
	ex0, ey0, ex1, ey1, ok := raster_extent(&c.r)
	nx0, ny0, nx1, ny1 := 0, 0, 0, 0   // an empty path clips everything away
	if ok { nx0, ny0, nx1, ny1 = max(bx0, ex0), max(by0, ey0), min(bx1, ex1), min(by1, ey1) }
	cl := new(Clip)
	cl.refs = 1
	if nx0 < nx1 && ny0 < ny1 {
		cl.x0, cl.y0, cl.x1, cl.y1 = nx0, ny0, nx1, ny1
		cl.mask = make([]u8, (nx1 - nx0) * (ny1 - ny0))
		mj := Mask_Job{cl = cl, old = old}
		raster_fill(&c.r, rule, nx0, ny0, nx1, ny1, c.opts.samples, mask_row, &mj)
		// a region that is its whole rectangle needs no mask
		full := true
		for v in cl.mask { if v != 255 { full = false; break } }
		if full { delete(cl.mask); cl.mask = nil }
	}
	clip_release(old)
	c.state.clip = cl
}

@(private)
Mask_Job :: struct {
	cl:  ^Clip,
	old: ^Clip,
}

@(private)
mask_row :: proc(user: rawptr, y, x0: int, cov: []f32) {
	j := (^Mask_Job)(user)
	cl := j.cl
	stride := cl.x1 - cl.x0
	for i in 0 ..< len(cov) {
		x := x0 + i
		if x < cl.x0 || x >= cl.x1 { continue }
		a := cov[i]
		if j.old != nil { a *= clip_coverage(j.old, x, y) }
		cl.mask[(y - cl.y0) * stride + (x - cl.x0)] = u8(clamp(a, 0, 1) * 255 + 0.5)
	}
}

// isPointInPath: the point is in canvas (device) space; a Path2D is first transformed by the CTM.
ctx_is_point_in_path :: proc(c: ^Context, x, y: f64, rule: Fill_Rule, path: ^Path = nil) -> bool {
	if !all_finite(x, y) { return false }
	p := path != nil ? path : &c.path
	m := path != nil ? c.state.ctm : IDENTITY
	flat_clear(&c.flat)
	path_flatten(p, m, c.opts.flatness, &c.flat)
	wind := 0
	for sp in c.flat.subs {
		pts := c.flat.pts[sp.start:sp.end]
		n := len(pts)
		for i in 0 ..< n {
			a, b := pts[i], pts[(i + 1) % n]
			wind += crossing_winding(a, b, {x, y})
		}
	}
	return rule == .Nonzero ? wind != 0 : wind & 1 != 0
}

// Winding contribution of the edge a -> b for a ray from `p` towards +x.
@(private)
crossing_winding :: proc "contextless" (a, b, p: [2]f64) -> int {
	if a.y <= p.y {
		if b.y > p.y && (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) > 0 { return 1 }
	} else if b.y <= p.y && (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) < 0 {
		return -1
	}
	return 0
}

ctx_is_point_in_stroke :: proc(c: ^Context, x, y: f64, path: ^Path = nil) -> bool {
	if !all_finite(x, y) { return false }
	p := path != nil ? path : &c.path
	m := path != nil ? c.state.ctm : IDENTITY
	style := current_stroke_style(c)
	flat_clear(&c.flat)
	path_flatten(p, m, c.opts.flatness, &c.flat)
	polys_clear(&c.polys)
	polys_stroke(&c.flat, c.state.ctm, &style, c.opts.flatness, &c.polys)
	wind := 0
	start := 0
	for e in c.polys.ends {
		pts := c.polys.pts[start:e]
		for i in 0 ..< len(pts) { wind += crossing_winding(pts[i], pts[(i + 1) % len(pts)], {x, y}) }
		start = e
	}
	return wind != 0
}

////////////////////////////////
// Images

// drawImage: texels [sx, sx + sw) x [sy, sy + sh) of `src` into the rectangle (dx, dy, dw, dh) of user space.
ctx_draw_image :: proc(c: ^Context, src: ^Bitmap, sx, sy, sw, sh, dx, dy, dw, dh: f64) {
	if c.bmp == nil || c.bmp.w == 0 || src == nil || src.w == 0 || src.h == 0 { return }
	if !all_finite(sx, sy, sw, sh, dx, dy, dw, dh) || sw == 0 || sh == 0 || dw == 0 || dh == 0 { return }
	sx, sy, sw, sh, dx, dy, dw, dh := sx, sy, sw, sh, dx, dy, dw, dh
	// negative sizes name the rectangle by its other corner
	if sw < 0 { sx += sw; sw = -sw }
	if sh < 0 { sy += sh; sh = -sh }
	if dw < 0 { dx += dw; dw = -dw }
	if dh < 0 { dy += dh; dh = -dh }
	// the part of the source rectangle outside the image is dropped, with the matching part of the destination
	kx, ky := dw / sw, dh / sh
	if sx < 0 { dx -= sx * kx; dw += sx * kx; sw += sx; sx = 0 }
	if sy < 0 { dy -= sy * ky; dh += sy * ky; sh += sy; sy = 0 }
	if sx + sw > f64(src.w) { over := sx + sw - f64(src.w); dw -= over * kx; sw -= over }
	if sy + sh > f64(src.h) { over := sy + sh - f64(src.h); dh -= over * ky; sh -= over }
	if !(sw > 0) || !(sh > 0) || !(dw > 0) || !(dh > 0) { return }

	// the image to user space to device space
	to_dev := matrix_mul(c.state.ctm, matrix_mul(matrix_translate(dx, dy), matrix_mul(matrix_scale(dw / sw, dh / sh), matrix_translate(-sx, -sy))))
	inv, ok := matrix_invert(to_dev)
	if !ok { return }
	// the source itself when it is the canvas being drawn on
	tmp: Bitmap
	use := src
	if src == c.bmp {
		cloned, cok := bitmap_clone(src, c.opts.max_bytes)
		if !cok { return }
		tmp, use = cloned, &tmp
	}
	defer if src == c.bmp { bitmap_destroy(&tmp) }

	paint := Paint{kind = .Image, inv = inv}
	paint.img = Image_Source{bmp = use, x0 = int(math.floor(sx)), y0 = int(math.floor(sy)),
		x1 = min(int(math.ceil(sx + sw)), src.w), y1 = min(int(math.ceil(sy + sh)), src.h),
		wrap_x = .Clamp, wrap_y = .Clamp, smooth = c.state.smoothing}
	// shrunk a lot: sample a box-filtered copy (mip level) instead of aliasing
	reduced: Bitmap
	big, small := matrix_scales(to_dev)
	if c.state.smoothing && big > 0 && big < 0.5 {
		f := clamp(int(1 / max(big, 1e-6)), 1, 64)
		_ = small
		rb, rok := bitmap_reduce(use, paint.img.x0, paint.img.y0, paint.img.x1, paint.img.y1, f, c.opts.max_bytes)
		if rok {
			reduced = rb
			ox, oy := f64(paint.img.x0), f64(paint.img.y0)
			// source texel (u, v) -> reduced texel ((u - ox) / f, (v - oy) / f)
			paint.inv = matrix_mul(matrix_mul(matrix_scale(1 / f64(f), 1 / f64(f)), matrix_translate(-ox, -oy)), inv)
			paint.img = Image_Source{bmp = &reduced, x0 = 0, y0 = 0, x1 = reduced.w, y1 = reduced.h, wrap_x = .Clamp, wrap_y = .Clamp, smooth = true}
		}
	}
	defer if reduced.pix != nil { bitmap_destroy(&reduced) }

	// the destination rectangle, with edges antialiased
	if c.state.ctm.b == 0 && c.state.ctm.c == 0 {
		fill_rect_with(c, dx, dy, dw, dh, &paint)
		return
	}
	m := c.state.ctm
	corners := [4][2]f64{
		clamp_pt(matrix_apply(m, {dx, dy})), clamp_pt(matrix_apply(m, {dx + dw, dy})),
		clamp_pt(matrix_apply(m, {dx + dw, dy + dh})), clamp_pt(matrix_apply(m, {dx, dy + dh})),
	}
	raster_reset(&c.r)
	raster_add_polygon(&c.r, corners[:])
	paint_edges(c, .Nonzero, &paint)
}

// getImageData: straight RGBA of a w x h block at (x, y), written to `out` (w * h * 4 bytes).
ctx_get_image_data :: proc(c: ^Context, x, y, w, h: int, out: []u8) {
	if c.bmp == nil { for i in 0 ..< min(len(out), w * h * 4) { out[i] = 0 }; return }
	bitmap_read_straight(c.bmp, x, y, w, h, out)
}

// putImageData: the dirty rectangle (dirty_x, dirty_y, dirty_w, dirty_h) of straight RGBA `data` (data_w pixels wide)
// at (dx, dy); not subject to the transform, clip, alpha, shadow or operator.
ctx_put_image_data :: proc(c: ^Context, data: []u8, data_w, data_h: int, dx, dy, dirty_x, dirty_y, dirty_w, dirty_h: int) {
	if c.bmp == nil || data_w <= 0 || data_h <= 0 { return }
	x0, y0 := max(dirty_x, 0), max(dirty_y, 0)
	x1, y1 := min(dirty_x + dirty_w, data_w), min(dirty_y + dirty_h, data_h)
	if dirty_w < 0 { x0, x1 = max(dirty_x + dirty_w, 0), min(dirty_x, data_w) }
	if dirty_h < 0 { y0, y1 = max(dirty_y + dirty_h, 0), min(dirty_y, data_h) }
	if x0 >= x1 || y0 >= y1 { return }
	bitmap_write_straight(c.bmp, data, data_w, x0, y0, x1 - x0, y1 - y0, dx + x0, dy + y0)
}

////////////////////////////////
// Blur

// Gaussian blur of an alpha plane, as three box blurs per axis (the usual close approximation).
gaussian_blur :: proc(plane: []f32, w, h: int, sigma: f64) {
	if w <= 0 || h <= 0 || sigma <= 0 { return }
	boxes := boxes_for_gauss(sigma)
	tmp := make([]f32, max(w, h))
	defer delete(tmp)
	line := make([]f32, max(w, h))
	defer delete(line)
	for r in boxes {
		for y in 0 ..< h { box_blur_line(plane[y * w:][:w], tmp[:w], r) }
		for x in 0 ..< w {
			for y in 0 ..< h { line[y] = plane[y * w + x] }
			box_blur_line(line[:h], tmp[:h], r)
			for y in 0 ..< h { plane[y * w + x] = line[y] }
		}
	}
}

@(private)
boxes_for_gauss :: proc(sigma: f64) -> [3]int {
	n := 3.0
	ideal := math.sqrt(12 * sigma * sigma / n + 1)
	wl := int(math.floor(ideal))
	if wl % 2 == 0 { wl -= 1 }
	wu := wl + 2
	m := int(math.round((12 * sigma * sigma - n * f64(wl * wl) - 4 * n * f64(wl) - 3 * n) / (-4 * f64(wl) - 4)))
	out: [3]int
	for i in 0 ..< 3 { out[i] = ((i < m ? wl : wu) - 1) / 2 }
	return out
}

// Box blur of radius r of one line, in place (zero outside the line), through `tmp`.
@(private)
box_blur_line :: proc(line, tmp: []f32, r: int) {
	n := len(line)
	if r <= 0 || n == 0 { return }
	inv := 1 / f32(2 * r + 1)
	sum := f32(0)
	for i in 0 ..= min(r, n - 1) { sum += line[i] }
	for i in 0 ..< n {
		tmp[i] = sum * inv
		add, sub := i + r + 1, i - r
		if add < n { sum += line[add] }
		if sub >= 0 { sum -= line[sub] }
	}
	copy(line, tmp[:n])
}
