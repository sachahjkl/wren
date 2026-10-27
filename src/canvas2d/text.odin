package canvas2d

import "core:math"
import "core:strings"

// Text goes through whoever owns the fonts (the shell: DirectWrite shaping, outlines of glyphs). The context asks it for
// a face, for the shaped glyphs of a string and for each glyph's outline, then draws the outlines as paths: so text
// takes the transform, the gradients, the shadows and the stroke styles like any other shape.

Placed_Glyph :: struct {
	face: u64,
	gid:  u16,
	x, y: f32,   // pen position from the text origin, CSS pixels, y down
}

Font_Metrics :: struct {
	ascent, descent: f32,   // positive, CSS pixels
	x_height:        f32,
	em_ascent, em_descent: f32,
}

// A color glyph (emoji, COLR / sbix / CBDT / SVG) as pixels: `px` is `w` x `h` straight-alpha sRGB RGBA, rows top to
// bottom, owned by the engine (valid until the next engine call); (ox, oy) is where the bitmap's top-left corner sits
// relative to the pen on the baseline, in pixels of the shaped size (y down). fillText draws it as an image, so it takes
// the transform, global alpha, shadow, filter and clip like any drawImage.
Color_Glyph :: struct {
	px:     []u8,
	w, h:   int,
	ox, oy: f32,
}

Text_Engine :: struct {
	user:    rawptr,
	// the font for a spec (0: none can be made)
	font:    proc(user: rawptr, spec: ^Font_Spec) -> u64,
	// shapes `text` at `size`; appends the glyphs and returns the advance width
	shape:   proc(user: rawptr, font: u64, size: f32, text: string, rtl: bool, letter_spacing, word_spacing: f32, glyphs: ^[dynamic]Placed_Glyph) -> f32,
	// the outline of a glyph in em units, y up, origin at the pen on the baseline; owned by the engine (nil: none)
	outline: proc(user: rawptr, face: u64, gid: u16) -> ^Path,
	metrics: proc(user: rawptr, font: u64, size: f32) -> Font_Metrics,
	// the color bitmap of a glyph at `size` px with text color `fg` (straight sRGB 0..1), ok = false when the glyph is
	// not drawn in color (draw its outline). nil: the engine draws no color glyphs (all glyphs go to `outline`).
	color_glyph: proc(user: rawptr, face: u64, gid: u16, size: f32, fg: [4]f32) -> (Color_Glyph, bool),
}

Text_Metrics :: struct {
	width:                f64,
	bbox_left, bbox_right: f64,
	bbox_ascent, bbox_descent: f64,
	font_ascent, font_descent: f64,
	em_ascent, em_descent: f64,
	hanging, alphabetic, ideographic: f64,
}

// HTML: ASCII whitespace in the text is replaced by spaces.
@(private)
normalize_text :: proc(s: string, allocator := context.temp_allocator) -> string {
	need := false
	for i in 0 ..< len(s) { if s[i] == '\t' || s[i] == '\n' || s[i] == '\r' || s[i] == '\f' { need = true; break } }
	if !need { return s }
	b := transmute([]u8)strings.clone(s, allocator)
	for &ch in b { if ch == '\t' || ch == '\n' || ch == '\r' || ch == '\f' { ch = ' ' } }
	return string(b)
}

@(private)
Laid_Out :: struct {
	glyphs:  [dynamic]Placed_Glyph,
	width:   f32,
	metrics: Font_Metrics,
	size:    f32,
}

@(private)
lay_out_text :: proc(c: ^Context, text: string) -> (lo: Laid_Out, ok: bool) {
	e := &c.text
	if e.font == nil || e.shape == nil || e.outline == nil { return }
	f := e.font(e.user, &c.state.font)
	if f == 0 { return }
	size := f32(min(c.state.font.size, 100_000))
	text := text
	if c.opts.text_bytes > 0 && len(text) > c.opts.text_bytes { text = text[:c.opts.text_bytes] }
	rtl := c.state.direction == .Rtl || (c.state.direction == .Inherit && c.inherit.rtl)
	lo.size = size
	lo.glyphs = make([dynamic]Placed_Glyph, context.temp_allocator)
	lo.width = e.shape(e.user, f, size, normalize_text(text), rtl, f32(c.state.letter_spacing), f32(c.state.word_spacing), &lo.glyphs)
	if e.metrics != nil { lo.metrics = e.metrics(e.user, f, size) }
	return lo, true
}

// The offsets that place a text of advance `width` at (x, y): the baseline's position and the left edge, after
// textAlign / textBaseline / direction.
@(private)
text_origin :: proc(c: ^Context, x, y: f64, width: f64, m: Font_Metrics) -> (ox, oy: f64) {
	st := &c.state
	rtl := st.direction == .Rtl || (st.direction == .Inherit && c.inherit.rtl)
	ox = x
	switch st.text_align {
	case .Left: ox = x
	case .Right: ox = x - width
	case .Center: ox = x - width * 0.5
	case .Start: ox = rtl ? x - width : x
	case .End: ox = rtl ? x : x - width
	}
	em_a, em_d := f64(m.em_ascent), f64(m.em_descent)
	if em_a == 0 && em_d == 0 { em_a, em_d = f64(m.ascent), f64(m.descent) }
	oy = y
	switch st.baseline {
	case .Alphabetic: oy = y
	case .Top: oy = y + em_a
	case .Hanging: oy = y + em_a * 0.8
	case .Middle: oy = y + (em_a - em_d) * 0.5
	case .Ideographic: oy = y - em_d
	case .Bottom: oy = y - em_d
	}
	return
}

// Builds the outline path (device space) of laid-out text with its origin at (ox, oy) of user space, squeezed
// horizontally by `k` (maxWidth).
@(private)
text_path :: proc(c: ^Context, lo: ^Laid_Out, ox, oy, k: f64, out: ^Path) {
	e := &c.text
	for g in lo.glyphs {
		o := e.outline(e.user, g.face, g.gid)
		if o == nil || path_is_empty(o) { continue }
		// em units (y up) to user space (y down), at the glyph's pen position
		gm := matrix_mul(c.state.ctm, matrix_mul(matrix_translate(ox + f64(g.x) * k, oy + f64(g.y)), matrix_scale(f64(lo.size) * k, -f64(lo.size))))
		path_append(out, o, gm)
	}
}

ctx_draw_text :: proc(c: ^Context, text: string, x, y: f64, max_width: f64, has_max: bool, stroke: bool) {
	if c.bmp == nil || c.bmp.w == 0 || !all_finite(x, y) { return }
	if has_max && (math.is_nan(max_width) || max_width <= 0) { return }
	lo, ok := lay_out_text(c, text)
	if !ok { return }
	k := 1.0
	w := f64(lo.width)
	if has_max && w > max_width && w > 0 { k = max_width / w; w = max_width }
	ox, oy := text_origin(c, x, y, w, lo.metrics)
	// Color glyphs (emoji, COLR / sbix / CBDT / SVG) are drawn as images, in color, whatever fill or stroke asks
	// (browsers draw the colored glyph regardless): they are taken out of the outline run first.
	draw_color_glyphs(c, &lo, ox, oy, k)
	if c.gpu != nil && !stroke {
		paint, pok := make_paint(c, &c.state.fill)
		if pok { gpu_fill_text(c, &lo, ox, oy, k, &paint) }
		return
	}
	p := Path{}
	defer path_destroy(&p)
	text_path(c, &lo, ox, oy, k, &p)
	if path_is_empty(&p) { return }
	if stroke {
		paint, pok := make_paint(c, &c.state.stroke)
		if !pok { return }
		style := current_stroke_style(c)
		flat_clear(&c.flat)
		path_flatten(&p, IDENTITY, c.opts.flatness, &c.flat)
		polys_clear(&c.polys)
		polys_stroke(&c.flat, c.state.ctm, &style, c.opts.flatness, &c.polys)
		if c.gpu != nil { gpu_fill_polys(c, &c.polys, &paint); return }
		raster_reset(&c.r)
		raster_add_polys(&c.r, &c.polys)
		paint_edges(c, .Nonzero, &paint)
	} else {
		paint, pok := make_paint(c, &c.state.fill)
		if !pok { return }
		fill_path_with(c, &p, IDENTITY, .Nonzero, &paint)
	}
}

// Draws every color glyph of `lo` as an image at its placed position and drops it from `lo.glyphs`, so the outline run
// that follows leaves it out. The text color (currentColor of foreground layers) is the fill style's color when it is
// solid, else opaque black.
@(private)
draw_color_glyphs :: proc(c: ^Context, lo: ^Laid_Out, ox, oy, k: f64) {
	e := &c.text
	if e.color_glyph == nil { return }
	fg := c.state.fill.kind == .Solid ? c.state.fill.color : [4]f32{0, 0, 0, 1}
	kept := 0
	for g in lo.glyphs {
		cg, is_color := e.color_glyph(e.user, g.face, g.gid, lo.size, fg)
		if !is_color || cg.w <= 0 || cg.h <= 0 || len(cg.px) < cg.w * cg.h * 4 {
			lo.glyphs[kept] = g
			kept += 1
			continue
		}
		draw_color_glyph(c, &cg, ox + f64(g.x) * k, oy + f64(g.y))
	}
	for len(lo.glyphs) > kept { pop(&lo.glyphs) }
}

// One color glyph: a temporary premultiplied bitmap of its pixels drawn into the destination rectangle (its top-left
// at the pen plus the glyph's offset, its size the bitmap's), through the current transform, alpha, shadow and clip.
// The maxWidth squeeze `applies only to x`, as it does to the outline run.
@(private)
draw_color_glyph :: proc(c: ^Context, cg: ^Color_Glyph, pen_x, pen_y: f64) {
	tmp, tok := bitmap_create(cg.w, cg.h, max(int), context.temp_allocator)
	if !tok { return }
	bitmap_write_straight(&tmp, cg.px, cg.w, 0, 0, cg.w, cg.h, 0, 0)
	dx, dy := pen_x + f64(cg.ox), pen_y + f64(cg.oy)
	ctx_draw_image(c, &tmp, 0, 0, f64(cg.w), f64(cg.h), dx, dy, f64(cg.w), f64(cg.h))
}

// measureText. Positions are relative to the alignment point and baseline, positive to the right and upwards (the
// bounding box left is positive when the box extends to the left of the point).
ctx_measure_text :: proc(c: ^Context, text: string) -> (tm: Text_Metrics, ok: bool) {
	lo, lok := lay_out_text(c, text)
	if !lok { return }
	w := f64(lo.width)
	ox, oy := text_origin(c, 0, 0, w, lo.metrics)
	// the glyph boxes, from their outlines
	x0, y0, x1, y1 := math.INF_F64, math.INF_F64, -math.INF_F64, -math.INF_F64
	e := &c.text
	for g in lo.glyphs {
		// a color glyph (emoji) has no outline: its ink box is its bitmap's rectangle around the pen
		if e.color_glyph != nil {
			if cg, is_color := e.color_glyph(e.user, g.face, g.gid, lo.size, {0, 0, 0, 1}); is_color && cg.w > 0 && cg.h > 0 {
				gx, gy := ox + f64(g.x), oy + f64(g.y)
				bx0, by0 := gx + f64(cg.ox), gy + f64(cg.oy)
				x0, x1 = min(x0, bx0), max(x1, bx0 + f64(cg.w))
				y0, y1 = min(y0, by0), max(y1, by0 + f64(cg.h))
				continue
			}
		}
		o := e.outline(e.user, g.face, g.gid)
		if o == nil { continue }
		// the curves themselves (a quadratic's control point lies outside it): flattened to 1/500 em
		flat_clear(&c.flat)
		path_flatten(o, IDENTITY, 0.002, &c.flat)
		for p in c.flat.pts {
			px := ox + f64(g.x) + p.x * f64(lo.size)
			py := oy + f64(g.y) - p.y * f64(lo.size)
			x0, x1 = min(x0, px), max(x1, px)
			y0, y1 = min(y0, py), max(y1, py)
		}
	}
	m := lo.metrics
	em_a, em_d := f64(m.em_ascent), f64(m.em_descent)
	if em_a == 0 && em_d == 0 { em_a, em_d = f64(m.ascent), f64(m.descent) }
	tm.width = w
	if x0 <= x1 {
		tm.bbox_left, tm.bbox_right = -x0, x1
		tm.bbox_ascent, tm.bbox_descent = -y0, y1
	} else {
		tm.bbox_left, tm.bbox_right = -ox, w + ox
	}
	// the font's boxes relative to the chosen baseline (oy is where the alphabetic baseline lies)
	tm.font_ascent, tm.font_descent = f64(m.ascent) - oy, f64(m.descent) + oy
	tm.em_ascent, tm.em_descent = em_a - oy, em_d + oy
	tm.hanging = em_a * 0.8 - oy
	tm.alphabetic = -oy
	tm.ideographic = -em_d - oy
	if x0 <= x1 {
		tm.bbox_ascent, tm.bbox_descent = -y0 + 0, y1 - 0
	}
	return tm, true
}
