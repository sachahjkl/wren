package browser

import "core:math"
import "toolkit:draw"
import lay "wb:layout"
import "wb:style"

// The lines of text decoration (CSS Text Decoration 3): of a text item, and of what ::highlight() and ::selection add over a part of one. One stroke for all: a
// style, a thickness and an offset, along a row or, in vertical text, a column.

// Thickness of a line where the page says none, in font sizes.
DECO_AUTO_THICKNESS :: 1.0 / 15
// In thicknesses: the gap of a double line, a dot and its gap, a dash and its gap, the length of a wave and how far it goes each way.
DECO_DOUBLE_GAP :: 1
DECO_DOT :: 1
DECO_DOT_GAP :: 1
DECO_DASH :: 3
DECO_DASH_GAP :: 2
DECO_WAVE_LENGTH :: 5
DECO_WAVE_HEIGHT :: 1
// A wave is drawn in steps of this many pixels.
DECO_WAVE_STEP :: 1

Deco_Line :: struct {
	kind:   style.Text_Decoration_Style,
	color:  draw.Color,
	thick:  f32,
	offset: f32,    // of an underline, from the baseline
	placed: bool,   // ... the page said where
}

// The line of `cs` (the box that decorates, or a highlight's style) in `fallback`'s color when it names none, at font `fi`.
deco_line :: proc(cs: ^style.Computed, fallback: draw.Color, fi: ^lay.Font_Info, scale: f32) -> Deco_Line {
	d := Deco_Line{color = fallback, thick = max(1, math.round(fi.size * DECO_AUTO_THICKNESS))}
	if cs == nil { return d }
	d.kind = cs.text_decoration_style
	if cs.text_decoration_color.a > 0 { d.color = to_draw(cs.text_decoration_color) }
	if cs.text_decoration_thickness.kind == .Px { d.thick = max(1, math.round(cs.text_decoration_thickness.v * scale)) }
	if cs.text_underline_offset.kind == .Px { d.offset, d.placed = cs.text_underline_offset.v * scale, true }
	return d
}

@(private = "file")
deco_piece :: proc(dc: ^draw.Context, a0, a1, c0, c1: f32, column: bool, col: draw.Color) {
	draw.rect(dc, column ? draw.Rect{{c0, a0}, {c1, a1}} : draw.Rect{{a0, c0}, {a1, c1}}, col)
}

@(private = "file")
deco_dashes :: proc(dc: ^draw.Context, lo, hi, at, on, off, t: f32, column: bool, col: draw.Color) {
	for a := lo; a < hi; a += on + off { deco_piece(dc, a, min(a + on, hi), at, at + t, column, col) }
}

// Where a wave of thickness `t` stands, `along` the line.
@(private = "file")
deco_wave :: proc(along, t: f32) -> f32 { return t * DECO_WAVE_HEIGHT * math.sin(along * math.TAU / (t * DECO_WAVE_LENGTH)) }

// One line from `lo` to `hi`, its near edge at `at`, down a column or along a row.
@(private = "file")
deco_stroke :: proc(dc: ^draw.Context, lo, hi, at: f32, column: bool, d: Deco_Line) {
	t := d.thick
	switch d.kind {
	case .Solid: deco_piece(dc, lo, hi, at, at + t, column, d.color)
	case .Double:
		deco_piece(dc, lo, hi, at, at + t, column, d.color)
		deco_piece(dc, lo, hi, at + t * (1 + DECO_DOUBLE_GAP), at + t * (2 + DECO_DOUBLE_GAP), column, d.color)
	case .Dotted: deco_dashes(dc, lo, hi, at, t * DECO_DOT, t * DECO_DOT_GAP, t, column, d.color)
	case .Dashed: deco_dashes(dc, lo, hi, at, t * DECO_DASH, t * DECO_DASH_GAP, t, column, d.color)
	case .Wavy:
		for a := lo; a < hi; a += DECO_WAVE_STEP {
			y0, y1 := at + deco_wave(a - lo, t), at + deco_wave(a + DECO_WAVE_STEP - lo, t)
			deco_piece(dc, a, min(a + DECO_WAVE_STEP, hi), min(y0, y1), max(y0, y1) + t, column, d.color)
		}
	}
}

// The lines of a row of text with this baseline, from `x0` to `x1`.
deco_paint_row :: proc(dc: ^draw.Context, x0, x1, baseline: f32, fi: ^lay.Font_Info, lines: style.Decorations, d: Deco_Line) {
	if .Underline in lines {
		deco_stroke(dc, x0, x1, math.round(d.placed ? baseline + d.offset : baseline + max(fi.descent * 0.35, 1)), false, d)
	}
	if .Overline in lines { deco_stroke(dc, x0, x1, math.round(baseline - fi.ascent), false, d) }
	if .Line_Through in lines { deco_stroke(dc, x0, x1, math.round(baseline - fi.x_height * 0.5 - d.thick * 0.5), false, d) }
}

// The lines of a column of vertical text in `r`: over and under are on the sides of the line's ascent and descent, to the right and left, turned the other way when read upwards.
deco_paint_column :: proc(dc: ^draw.Context, r: draw.Rect, ccw: bool, lines: style.Decorations, d: Deco_Line) {
	under := ccw ? r.max.x - d.thick : r.min.x
	over := ccw ? r.min.x : r.max.x - d.thick
	if .Underline in lines { deco_stroke(dc, r.min.y, r.max.y, under, true, d) }
	if .Overline in lines { deco_stroke(dc, r.min.y, r.max.y, over, true, d) }
	if .Line_Through in lines { deco_stroke(dc, r.min.y, r.max.y, (r.min.x + r.max.x) * 0.5 - d.thick * 0.5, true, d) }
}

// The box whose text-decoration draws item `it`.
deco_source :: proc(l: ^Layout, it: ^lay.Display_Item) -> ^style.Computed {
	return it.deco_box >= 0 && int(it.deco_box) < len(l.boxes) ? l.boxes[it.deco_box].cs : nil
}
