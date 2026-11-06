package browser

import "core:math"
import "core:slice"
import "core:unicode"
import "core:unicode/utf8"
import "toolkit:draw"
import "toolkit:font"
import lay "wb:layout"
import "wb:style"

// What is drawn on and around the glyphs of a text item: the lines of text decoration (CSS Text Decoration 3 and 4), of each box that decorates it and of what highlights add,
// emphasis marks, and the stroke of the glyphs. One stroke for all lines: a style, a thickness and a place, along a row or, in vertical text, a column, with the gaps
// it leaves. In paint order (§2.6): shadows, underlines, overlines, text, emphasis marks, line-throughs (paint_text, render.odin).

// Thickness of a line where the page says none, in font sizes.
DECO_AUTO_THICKNESS :: 1.0 / 15
// The place of an underline where the page says none, in descents; at least a pixel.
DECO_AUTO_UNDER :: 0.35
// In thicknesses: the gap of a double line, a dot and its gap, a dash and its gap, the length of a wave and how far it goes each way.
DECO_DOUBLE_GAP :: 1
DECO_DOT :: 1
DECO_DOT_GAP :: 1
DECO_DASH :: 3
DECO_DASH_GAP :: 2
DECO_WAVE_LENGTH :: 5
DECO_WAVE_HEIGHT :: 1
// Points of a wave's polyline, a length of it.
DECO_WAVE_POINTS :: 10
// A skipping line stops this far from ink, in thicknesses, and at most this many pixels (Blink's gap).
DECO_SKIP_GAP :: 1
DECO_SKIP_GAP_MAX :: 13
// A piece of a skipping line shorter than this many pixels is left out.
DECO_PIECE_MIN :: 1
// `text-decoration-inset: auto`, in font sizes.
DECO_INSET_AUTO :: 1.0 / 16
// Emphasis marks: their size, in font sizes.
EMPHASIS_SCALE :: 0.5
// The lines of ::spelling-error and ::grammar-error's text-decoration values: what no other property changes.
DECO_SPELLING_COLOR :: draw.Color{1, 0, 0, 1}
DECO_GRAMMAR_COLOR :: draw.Color{0, 0.6, 0, 1}

// How a text item is drawn: fill and stroke.
Text_Ink :: struct {
	fill, stroke: draw.Color,
	width:        f32,
}

text_ink_of :: proc(cs: ^style.Computed, scale: f32) -> Text_Ink {
	return {to_draw(style.text_fill(cs)), to_draw(style.stroke_color(cs)), cs.text_stroke_width * scale}
}

// A text item being painted.
Text_Paint :: struct {
	l:        ^Layout,
	dc:       ^draw.Context,
	it:       ^lay.Display_Item,
	cs:       ^style.Computed,
	fi:       ^lay.Font_Info,
	r:        draw.Rect,
	off:      draw.Vec2,
	baseline: f32,      // its y, in window pixels (vertical: its x)
	vertical: bool,
	ccw:      bool,     // read upwards: the over side is on the left
	opts:     font.Shape_Options,
}

text_paint_make :: proc(l: ^Layout, dc: ^draw.Context, it: ^lay.Display_Item, fi: ^lay.Font_Info, r: draw.Rect, off: draw.Vec2) -> Text_Paint {
	cs := it.cs
	vertical := .Vertical in it.flags
	return {l, dc, it, cs, fi, r, off, it.baseline + (vertical ? off.x : off.y), vertical, cs.writing_mode == .Sideways_Lr, text_shape_options(l, cs, it.level, it.extra)}
}

// The glyphs, moved by `shift`.
text_ink_draw :: proc(tp: ^Text_Paint, shift: draw.Vec2, ink: Text_Ink) {
	if tp.vertical {
		draw_vertical_text(tp.l, tp.dc, tp.it, tp.fi, tp.baseline + shift.x, tp.r.min.y + shift.y, tp.r.max.y + shift.y, ink, tp.opts)
		return
	}
	sh := font.shape(tp.dc.fonts, font.Font_Id(tp.fi.font), tp.fi.size, tp.it.text, tp.opts, context.temp_allocator)
	pos := draw.Vec2{tp.r.min.x + shift.x, tp.baseline + shift.y}
	if ink.fill.a > 0 { draw.glyph_run(tp.dc, tp.fi.size, pos, ink.fill, sh.glyphs) }
	if ink.width > 0 && ink.stroke.a > 0 { draw.glyph_run_stroke(tp.dc, tp.fi.size, pos, ink.stroke, sh.glyphs, ink.width) }
}

////////////////////////////////
// One line

// The lines of one box, or of a highlight, over a text item.
Deco_Line :: struct {
	lines:    style.Decorations,
	kind:     style.Text_Decoration_Style,
	color:    draw.Color,
	thick:    f32,
	offset:   f32,          // from where text-underline-position puts an underline
	placed:   bool,         // ... the page said
	position: style.Text_Underline_Position,
	skip:     style.Text_Decoration_Skip_Ink,
	fi:       ^lay.Font_Info,   // what places it
	baseline: f32,          // of the box that draws it, in window pixels
	lo, hi:   f32,          // where it goes along the text
}

// A length of a line's: a percentage is of 1em.
@(private = "file")
deco_length :: proc(v: style.Length, em: f32, scale: f32) -> f32 { return style.resolve(v, em) * scale }

@(private = "file")
deco_metrics :: proc(tp: ^Text_Paint, fi: ^lay.Font_Info) -> (m: font.Face_Metrics, em: f32) {
	m = font.face_metrics(tp.dc.fonts, font.Font_Id(fi.font))
	return m, m.upem > 0 ? fi.size / f32(m.upem) : 0
}

// `auto`, `from-font` or a length.
@(private = "file")
deco_thickness :: proc(tp: ^Text_Paint, v: style.Length, em: f32, fi: ^lay.Font_Info) -> f32 {
	t := fi.size * DECO_AUTO_THICKNESS
	#partial switch v.kind {
	case .Auto:
	case .Normal:
		if m, unit := deco_metrics(tp, fi); m.underline_thickness > 0 { t = f32(m.underline_thickness) * unit }
	case: t = deco_length(v, em, tp.l.scale)
	}
	return max(1, math.round(t))
}

@(private = "file")
deco_set_offset :: proc(d: ^Deco_Line, v: style.Length, em: f32, scale: f32) {
	if v.kind != .Auto { d.offset, d.placed = deco_length(v, em, scale), true }
}

// What the text of an error's line draws: only a wave.
@(private = "file")
deco_set_error :: proc(d: ^Deco_Line) {
	if .Spelling_Error not_in d.lines && .Grammar_Error not_in d.lines { return }
	d.color = .Spelling_Error in d.lines ? DECO_SPELLING_COLOR : DECO_GRAMMAR_COLOR
	d.lines = {.Underline}
	d.kind, d.position, d.placed, d.skip = .Wavy, {}, false, .None
}

// The ends of `box`'s line on this item: `text-decoration-inset` at the ends of what it decorates.
@(private = "file")
deco_inset :: proc(tp: ^Text_Paint, d: ^Deco_Line, box: i32, cs: ^style.Computed) {
	inset := cs.text_decoration_inset
	if inset[0].kind == .Px && inset[1].kind == .Px && inset[0].v == 0 && inset[1].v == 0 { return }
	first, last, length := lay.deco_fragments(tp.l, tp.it, box)
	amount :: proc(v: style.Length, length, size, scale: f32) -> f32 { return v.kind == .Auto ? size * DECO_INSET_AUTO : style.resolve(v, length / scale) * scale }
	start := first ? amount(inset[0], length, tp.fi.size, tp.l.scale) : 0
	end := last ? amount(inset[1], length, tp.fi.size, tp.l.scale) : 0
	if tp.it.level & 1 == 1 { start, end = end, start }
	d.lo += start
	d.hi -= end
}

// The bytes at the start and the end of the item that are spaces its lines leave out (text-decoration-skip-spaces, `all`: `deco_paint` leaves out the others).
@(private = "file")
deco_skip_spaces :: proc(tp: ^Text_Paint, d: ^Deco_Line) {
	skip := tp.cs.text_decoration_skip_spaces
	text := tp.it.text
	if skip == {} || len(text) == 0 { return }
	lead, trail := 0, len(text)
	for lead < len(text) {
		r, n := utf8.decode_rune_in_string(text[lead:])
		if !style.is_spacer(r) { break }
		lead += n
	}
	if lead < len(text) {
		for trail > lead {
			r, n := utf8.decode_last_rune_in_string(text[:trail])
			if !style.is_spacer(r) { break }
			trail -= n
		}
	}
	if lead == 0 && trail == len(text) { return }
	line, frag, ok := lay.item_line(tp.l, tp.it)
	if !ok { return }
	ln := &tp.l.lines[line]
	api := text_api(the_app)
	at := tp.vertical ? tp.r.min.y : tp.r.min.x
	// (at the start and the end of the line, or all of them)
	if lead > 0 && (.All in skip || (.Start in skip && frag == ln.frags[0])) {
		edge := at + lay.item_caret_x(tp.l, tp.it, lead, api)
		if tp.it.level & 1 == 1 { d.hi = min(d.hi, edge) } else { d.lo = max(d.lo, edge) }
	}
	if trail < len(text) && (.All in skip || (.End in skip && frag == ln.frags[1] - 1)) {
		edge := at + lay.item_caret_x(tp.l, tp.it, trail, api)
		if tp.it.level & 1 == 1 { d.lo = max(d.lo, edge) } else { d.hi = min(d.hi, edge) }
	}
}

// The line of decorating box `box` over the item.
deco_line_of_box :: proc(tp: ^Text_Paint, box: i32) -> Deco_Line {
	l := tp.l
	cs := l.boxes[box].cs
	fi := lay.deco_font(l, tp.it, box)
	d := Deco_Line{lines = cs.text_decoration, kind = cs.text_decoration_style, color = to_draw(cs.text_decoration_color), position = cs.text_underline_position,
		skip = tp.cs.text_decoration_skip_ink, fi = fi}
	// (the item's baseline, in window pixels, and how far the box's is from it)
	d.baseline = tp.baseline + lay.deco_baseline(l, tp.it, box) - tp.it.baseline
	d.thick = deco_thickness(tp, cs.text_decoration_thickness, cs.font_size, fi)
	deco_set_offset(&d, cs.text_underline_offset, cs.font_size, l.scale)
	deco_set_error(&d)
	d.lo, d.hi = tp.vertical ? tp.r.min.y : tp.r.min.x, tp.vertical ? tp.r.max.y : tp.r.max.x
	deco_skip_spaces(tp, &d)
	deco_inset(tp, &d, box, cs)
	return d
}

// The line of a highlight, from `lo` to `hi` over the item, in `color` where it says none.
deco_line_of_highlight :: proc(tp: ^Text_Paint, p: ^style.Highlight_Paint, lo, hi: f32, color: draw.Color) -> Deco_Line {
	d := Deco_Line{lines = p.lines, kind = p.line_style, color = p.has_line_color ? to_draw(p.line_color) : color, position = p.position, skip = p.skip_ink, fi = tp.fi,
		baseline = tp.baseline, lo = lo, hi = hi}
	d.thick = deco_thickness(tp, p.thickness, tp.cs.font_size, tp.fi)
	deco_set_offset(&d, p.offset, tp.cs.font_size, tp.l.scale)
	deco_set_error(&d)
	return d
}

@(private = "file")
deco_piece :: proc(dc: ^draw.Context, a0, a1, c0, c1: f32, column: bool, col: draw.Color) {
	draw.rect(dc, column ? draw.Rect{{c0, a0}, {c1, a1}} : draw.Rect{{a0, c0}, {a1, c1}}, col)
}

// Dashes from `lo` to `hi`, in step with `origin`.
@(private = "file")
deco_dashes :: proc(dc: ^draw.Context, lo, hi, origin, at, on, off, t: f32, column: bool, col: draw.Color) {
	step := on + off
	start := origin + math.floor((lo - origin) / step) * step
	for a := start; a < hi; a += step { deco_piece(dc, max(a, lo), min(a + on, hi), at, at + t, column, col) }
}

// Round dots, whole ones only, spread to fill the line from `lo` to `hi`, those in the piece `p0` to `p1` drawn.
@(private = "file")
deco_dots :: proc(dc: ^draw.Context, lo, hi, p0, p1, at, t: f32, column: bool, col: draw.Color) {
	count := max(int((hi - lo) / (t * (DECO_DOT + DECO_DOT_GAP))), 1)
	step := (hi - lo) / f32(count)
	for i in 0 ..< count {
		a := lo + step * f32(i)
		if a < p0 || a + t > p1 { continue }
		draw.rect(dc, column ? draw.Rect{{at, a}, {at + t, a + t}} : draw.Rect{{a, at}, {a + t, at + t}}, col, t * 0.5)
	}
}

// Where a wave of thickness `t` stands, `along` the line.
@(private = "file")
deco_wave :: proc(along, t: f32) -> f32 { return t * DECO_WAVE_HEIGHT * math.sin(along * math.TAU / (t * DECO_WAVE_LENGTH)) }

// A piece `lo` to `hi` of a line that goes from `line_lo` to `line_hi`, its near edge at `at`, down a column or along a row. What repeats goes by `origin`: the pieces of a line,
// and the items of a box, are one wave.
@(private = "file")
deco_stroke :: proc(dc: ^draw.Context, lo, hi, line_lo, line_hi, origin, at: f32, column: bool, d: ^Deco_Line) {
	t := d.thick
	switch d.kind {
	case .Solid: deco_piece(dc, lo, hi, at, at + t, column, d.color)
	case .Double:
		deco_piece(dc, lo, hi, at, at + t, column, d.color)
		deco_piece(dc, lo, hi, at + t * (1 + DECO_DOUBLE_GAP), at + t * (2 + DECO_DOUBLE_GAP), column, d.color)
	case .Dotted: deco_dots(dc, line_lo, line_hi, lo, hi, at, t, column, d.color)
	case .Dashed: deco_dashes(dc, lo, hi, origin, at, t * DECO_DASH, t * DECO_DASH_GAP, t, column, d.color)
	case .Wavy:
		points := make([dynamic]draw.Vec2, 0, int((hi - lo) / (t * DECO_WAVE_LENGTH) * DECO_WAVE_POINTS) + 2, context.temp_allocator)
		step := t * DECO_WAVE_LENGTH / DECO_WAVE_POINTS
		for a := lo; ; a += step {
			along := min(a, hi)
			across := at + t * 0.5 + deco_wave(along - origin, t)
			append(&points, column ? draw.Vec2{across, along} : draw.Vec2{along, across})
			if a >= hi { break }
		}
		draw.polyline(dc, points[:], t, d.color)
	}
}

// How much a line of its style takes across: from the near edge, and on the near side of it.
@(private = "file")
deco_extent :: proc(d: ^Deco_Line) -> (after, before: f32) {
	#partial switch d.kind {
	case .Double: return d.thick * (2 + DECO_DOUBLE_GAP), 0
	case .Wavy: return d.thick * (1 + DECO_WAVE_HEIGHT), d.thick * DECO_WAVE_HEIGHT
	}
	return d.thick, 0
}

////////////////////////////////
// Where it goes

// The over side of a column is on the right, unless it is read upwards. Its underline is on this side.
@(private = "file")
deco_column_underline_right :: proc(tp: ^Text_Paint, d: ^Deco_Line) -> bool {
	switch d.position.side {
	case .Left: return false
	case .Right: return true
	case .Auto:
	}
	// (CSS Text Decoration 3 §2.1's sheet: over the line in Japanese and Korean, which Blink keeps to vertical text)
	if tp.fi.vmode == .Central {
		lang := tp.cs.content_language
		if len(lang) >= 2 && (lang[:2] == "ja" || lang[:2] == "ko") { return !tp.ccw }
	}
	return tp.ccw
}

// How far under the alphabetic baseline an underline's over edge is, by `text-underline-position` and `text-underline-offset`; `ok` false: at the edge of the text.
@(private = "file")
deco_under_distance :: proc(tp: ^Text_Paint, d: ^Deco_Line) -> f32 {
	#partial switch d.position.place {
	case .From_Font:
		if m, unit := deco_metrics(tp, d.fi); m.underline_thickness > 0 { return -f32(m.underline_position) * unit + d.offset }
	case .Under: return d.fi.descent + d.offset
	}
	// (a wave goes up by its height: it stays off the text as a line does)
	return d.placed ? d.offset : max(d.fi.descent * DECO_AUTO_UNDER, 1) + (d.kind == .Wavy ? d.thick * DECO_WAVE_HEIGHT : 0)
}

// The near edge of a line of a column, the lowest x it covers.
@(private = "file")
deco_column_at :: proc(tp: ^Text_Paint, d: ^Deco_Line, line: style.Decoration) -> f32 {
	// (a box's baseline in the coordinates of the item's rectangle)
	shift := d.baseline - tp.baseline
	left, right := tp.r.min.x + shift, tp.r.max.x + shift
	under_right := deco_column_underline_right(tp, d)
	#partial switch line {
	case .Underline:
		if d.position.place == .From_Font || (tp.fi.vmode != .Central && d.position.place == .Auto && d.position.side == .Auto) {
			// a distance from the alphabetic baseline, as in a row
			base := tp.fi.vmode == .Central ? d.baseline - (tp.fi.raw_ascent - tp.fi.raw_descent) * 0.5 : d.baseline
			return tp.ccw ? base + deco_under_distance(tp, d) : base - deco_under_distance(tp, d) - d.thick
		}
		return under_right ? right - d.thick + d.offset : left - d.offset
	case .Overline: return under_right ? left : right - d.thick
	}
	return (left + right) * 0.5 - d.thick * 0.5
}

// The near edge of a line of a row.
@(private = "file")
deco_row_at :: proc(d: ^Deco_Line, line: style.Decoration, tp: ^Text_Paint) -> f32 {
	#partial switch line {
	case .Underline: return math.round(d.baseline + deco_under_distance(tp, d))
	case .Overline: return math.round(d.baseline - d.fi.ascent)
	}
	return math.round(d.baseline - d.fi.x_height * 0.5 - d.thick * 0.5)
}

////////////////////////////////
// What it skips

// Is `r` of a CJK script, or a common character that goes with them: what `text-decoration-skip-ink: auto` does not skip.
@(private = "file")
is_cjk :: proc(r: rune) -> bool {
	switch r {
	case 0x1100 ..= 0x11FF, 0x2E80 ..= 0x2FDF, 0x3000 ..= 0x31FF, 0x3400 ..= 0x4DBF, 0x4E00 ..= 0x9FFF, 0xA960 ..= 0xA97F, 0xAC00 ..= 0xD7FF, 0xF900 ..= 0xFAFF, 0xFF00 ..= 0xFFEF,
	     0x20000 ..= 0x3FFFF:
		return true
	}
	return false
}

// The glyphs of a run that a line leaves a gap for.
@(private = "file")
deco_ink_glyphs :: proc(text: string, glyphs: []font.Glyph_Pos, skip: style.Text_Decoration_Skip_Ink) -> []font.Glyph_Pos {
	if skip == .All { return glyphs }
	ascii := true
	for i in 0 ..< len(text) { if text[i] >= 0x80 { ascii = false; break } }
	if ascii { return glyphs }
	out := make([dynamic]font.Glyph_Pos, 0, len(glyphs), context.temp_allocator)
	for g in glyphs {
		r, _ := utf8.decode_rune_in_string(text[min(int(g.cluster), len(text)):])
		if !is_cjk(r) { append(&out, g) }
	}
	return out[:]
}

// Where a line across `c0` to `c1` of a column meets ink, as spans of its length.
@(private = "file")
deco_column_spans :: proc(tp: ^Text_Paint, d: ^Deco_Line, c0, c1, gap: f32) -> [][2]f32 {
	out := make([dynamic][2]f32, 0, 8, context.temp_allocator)
	w := vertical_walk(tp.l, tp.dc, tp.it, tp.fi, tp.baseline, tp.r.min.y, tp.r.max.y, tp.opts)
	size := tp.fi.size
	for {
		p := vertical_next(&w) or_break
		glyphs := deco_ink_glyphs(p.text, p.sh.glyphs, d.skip)
		if p.upright {
			// a band of its width: where it is along the column
			for g in glyphs {
				x := p.x + g.x
				a, b, hit := font.glyph_ink_extent(tp.dc.fonts, g.face, g.id, (c0 - x) / size, (c1 - x) / size, true)
				if hit { append(&out, [2]f32{p.y - b * size - gap, p.y - a * size + gap}) }
			}
			continue
		}
		// turned a quarter: y down in the run is away from the right of the column, or to it when read upwards
		top, bottom := tp.ccw ? c0 - p.x : p.x - c1, tp.ccw ? c1 - p.x : p.x - c0
		for s in font.run_ink_spans(tp.dc.fonts, glyphs, size, top, bottom, gap) {
			append(&out, tp.ccw ? [2]f32{p.y - s[1], p.y - s[0]} : [2]f32{p.y + s[0], p.y + s[1]})
		}
	}
	slice.sort_by(out[:], proc(a, b: [2]f32) -> bool { return a[0] < b[0] })
	return out[:]
}

// The pieces of a line, its near edge at `at`, left by its gaps.
@(private = "file")
deco_pieces :: proc(tp: ^Text_Paint, d: ^Deco_Line, line: style.Decoration, at: f32) -> [][2]f32 {
	whole := make([dynamic][2]f32, 0, 8, context.temp_allocator)
	spans: [][2]f32
	if d.skip != .None && line != .Line_Through {
		gap := min(d.thick * DECO_SKIP_GAP, DECO_SKIP_GAP_MAX)
		after, before := deco_extent(d)
		if tp.vertical {
			spans = deco_column_spans(tp, d, at - before, at + after, gap)
		} else {
			sh := font.shape(tp.dc.fonts, font.Font_Id(tp.fi.font), tp.fi.size, tp.it.text, tp.opts, context.temp_allocator)
			spans = font.run_ink_spans(tp.dc.fonts, deco_ink_glyphs(tp.it.text, sh.glyphs, d.skip), tp.fi.size, at - before - tp.baseline, at + after - tp.baseline, gap)
			for &s in spans { s += tp.r.min.x }
		}
	}
	lo := d.lo
	for s in spans {
		if lo >= d.hi { break }
		if end := min(s[0], d.hi); end - lo >= DECO_PIECE_MIN { append(&whole, [2]f32{lo, end}) }
		lo = max(lo, s[1])
	}
	if d.hi - lo >= DECO_PIECE_MIN || len(spans) == 0 { append(&whole, [2]f32{lo, d.hi}) }
	return whole[:]
}

// With `text-decoration-skip-spaces: all`: the pieces without the spaces inside the item.
@(private = "file")
deco_without_spaces :: proc(tp: ^Text_Paint, pieces: [][2]f32) -> [][2]f32 {
	text := tp.it.text
	out := make([dynamic][2]f32, 0, len(pieces) + 4, context.temp_allocator)
	api := text_api(the_app)
	at := tp.vertical ? tp.r.min.y : tp.r.min.x
	gaps := make([dynamic][2]f32, 0, 4, context.temp_allocator)
	for i := 0; i < len(text); {
		r, n := utf8.decode_rune_in_string(text[i:])
		if style.is_spacer(r) {
			a, b := lay.item_caret_x(tp.l, tp.it, i, api), lay.item_caret_x(tp.l, tp.it, i + n, api)
			append(&gaps, [2]f32{at + min(a, b), at + max(a, b)})
		}
		i += n
	}
	if len(gaps) == 0 { return pieces }
	slice.sort_by(gaps[:], proc(a, b: [2]f32) -> bool { return a[0] < b[0] })
	for p in pieces {
		lo := p[0]
		for g in gaps {
			if g[1] <= lo || g[0] >= p[1] { continue }
			if g[0] > lo { append(&out, [2]f32{lo, g[0]}) }
			lo = max(lo, g[1])
		}
		if lo < p[1] { append(&out, [2]f32{lo, p[1]}) }
	}
	return out[:]
}

////////////////////////////////
// Painting

// One kind of line of `d`, moved by `shift`, in `color` (a shadow's, a highlight's; nil: its own).
deco_paint :: proc(tp: ^Text_Paint, d: ^Deco_Line, line: style.Decoration, shift: draw.Vec2 = {}, color: ^draw.Color = nil) {
	if line not_in d.lines || d.hi <= d.lo { return }
	own := d.color
	defer d.color = own
	if color != nil { d.color = color^ }
	if d.color.a <= 0 { return }
	at := tp.vertical ? deco_column_at(tp, d, line) : deco_row_at(d, line, tp)
	pieces := deco_pieces(tp, d, line, at)
	if .All in tp.cs.text_decoration_skip_spaces { pieces = deco_without_spaces(tp, pieces) }
	along := tp.vertical ? shift.y : shift.x
	across := tp.vertical ? shift.x : shift.y
	origin := (tp.vertical ? tp.off.y : tp.off.x) + along
	for p in pieces { deco_stroke(tp.dc, p[0] + along, p[1] + along, d.lo + along, d.hi + along, origin, at + across, tp.vertical, d) }
}

// The lines of the boxes that decorate the item, the outermost first (each keeps its own line, style, color and thickness).
deco_lines_of :: proc(tp: ^Text_Paint) -> []Deco_Line {
	if tp.it.deco == {} { return nil }
	boxes := lay.item_deco_boxes(tp.l, tp.it)
	out := make([]Deco_Line, len(boxes), context.temp_allocator)
	for b, i in boxes { out[i] = deco_line_of_box(tp, b) }
	return out
}

// How far past the item's rectangle what is drawn with it reaches.
deco_ink_reach :: proc(l: ^Layout, it: ^lay.Display_Item) -> (reach: f32) {
	cs := it.cs
	if cs.text_stroke_width > 0 { reach = cs.text_stroke_width * l.scale }
	fi := lay.item_font(l, it)
	if fi == nil { return }
	if cs.text_emphasis_style.shape != .None { reach += fi.size }
	if it.deco == {} { return }
	for b := it.deco_box; b != lay.NONE; b = l.boxes[b].deco_up {
		bc := l.boxes[b].cs
		size := bc.font_size * l.scale
		if bc.text_decoration_thickness.kind != .Auto && bc.text_decoration_thickness.kind != .Normal {
			reach = max(reach, deco_length(bc.text_decoration_thickness, bc.font_size, l.scale) * (2 + DECO_DOUBLE_GAP))
		}
		if bc.text_underline_offset.kind != .Auto { reach = max(reach, abs(deco_length(bc.text_underline_offset, bc.font_size, l.scale)) + size * DECO_AUTO_THICKNESS * 4) }
		if size != fi.size || bc.text_underline_position.place != .Auto { reach = max(reach, size) }   // (a box's font is not the item's)
	}
	return
}

////////////////////////////////
// Emphasis marks

// Is the grapheme at `text[a:]` one that gets no mark (CSS Text Decoration 4 §3.1)?
@(private = "file")
emphasis_skips :: proc(r: rune, skip: style.Emphasis_Skips) -> bool {
	switch r {
	// punctuation that is marked all the same
	case '#', '%', '&', '@', 0xA7, 0xB6, 0x2030, 0x2031, 0x60C, 0x66A: return false
	}
	if unicode.is_control(r) || r == 0xAD || (r >= 0x200B && r <= 0x200F) || (r >= 0x202A && r <= 0x202E) || (r >= 0x2060 && r <= 0x206F) { return true }
	if unicode.is_space(r) || r == 0x2028 || r == 0x2029 { return .Spaces in skip }
	if unicode.is_punct(r) { return .Punctuation in skip }
	if unicode.is_symbol(r) { return .Symbols in skip }
	if .Narrow in skip && r < 0x1100 { return true }
	return false
}

// The marks of bytes [lo, hi) of the item, moved by `shift`.
emphasis_paint :: proc(tp: ^Text_Paint, lo, hi: int, shift: draw.Vec2, col: draw.Color) {
	cs := tp.cs
	mark := style.emphasis_mark(cs.text_emphasis_style, tp.vertical)
	if mark == "" || col.a <= 0 { return }
	fid := font.Font_Id(tp.fi.font)
	size := tp.fi.size * EMPHASIS_SCALE
	sh := font.shape(tp.dc.fonts, fid, size, mark, {}, context.temp_allocator)
	ascent := tp.fi.raw_ascent > 0 ? tp.fi.raw_ascent : tp.fi.ascent
	descent := tp.fi.raw_descent > 0 ? tp.fi.raw_descent : tp.fi.descent
	mark_ascent, mark_descent := ascent * EMPHASIS_SCALE, descent * EMPHASIS_SCALE
	pos := cs.text_emphasis_position
	if pos.auto { pos.under = len(cs.content_language) >= 2 && cs.content_language[:2] == "zh" }
	api := text_api(the_app)
	text := tp.it.text
	for a := lo; a < hi; {
		b := min(font.grapheme_next(text, a), hi)
		defer a = b
		r, _ := utf8.decode_rune_in_string(text[a:b])
		if emphasis_skips(r, cs.text_emphasis_skip) { continue }
		ca, cb := lay.item_caret_x(tp.l, tp.it, a, api), lay.item_caret_x(tp.l, tp.it, b, api)
		middle := (ca + cb) * 0.5
		p: draw.Vec2
		if tp.vertical {
			x := pos.left ? tp.r.min.x - (mark_ascent + mark_descent) * 0.5 : tp.r.max.x + (mark_ascent + mark_descent) * 0.5
			p = {x - sh.width * 0.5, tp.r.min.y + middle + (mark_ascent - mark_descent) * 0.5}
		} else {
			y := pos.under ? tp.baseline + descent + mark_ascent : tp.baseline - ascent - mark_descent
			p = {tp.r.min.x + middle - sh.width * 0.5, y}
		}
		draw.glyph_run(tp.dc, size, p + shift, col, sh.glyphs)
	}
}
