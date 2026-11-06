package reftest

import "core:math"
import css_ "wb:css"
import lay "wb:layout"
import "wb:style"

// Text without a font engine, as the headless metrics of src/tools/wpt/layout_host.odin measure it: one cell per character.
// Ahem is drawn as the Ahem font is (fonts/Ahem.ttf: ascent 0.8 em, descent 0.2 em, the glyphs below). Any other font is
// half an em wide per character, each cell filled with a small pattern from the character's code point: different
// characters differ, a rotated run differs from an upright one (the cells are of another shape, the pattern asymmetric),
// and the same text at the same place gives the same pixels.
//
// Spacing is what layout measured: letter-spacing after each character, word-spacing and justification after each space.

AHEM_FONT :: lay.Font(2)
OTHER_FONT :: lay.Font(1)
OTHER_ADVANCE_EM :: 0.5
ASCENT_EM :: 0.8
DESCENT_EM :: 0.2

// Ahem's glyphs: 'p' is only what is below the baseline, 'É' only what is above it, whitespace is empty, every other glyph
// (x, X, ...) is the whole em box.
@(private = "file")
AHEM_DESCENT_ONLY :: 'p'
@(private = "file")
AHEM_ASCENT_ONLY :: rune(0x00C9)
// Two pairs are bars across the em box, from a fifth of it to two fifths (from Ahem.ttf's glyph table).
@(private = "file")
AHEM_VERTICAL_BAR_A :: rune(0x03A5)
@(private = "file")
AHEM_VERTICAL_BAR_B :: rune(0x7EB5)
@(private = "file")
AHEM_HORIZONTAL_BAR_A :: rune(0x03A7)
@(private = "file")
AHEM_HORIZONTAL_BAR_B :: rune(0x6A2A)
@(private = "file")
AHEM_BAR_START :: 0.2
@(private = "file")
AHEM_BAR_END :: 0.4
@(private = "file")
NBSP :: rune(0x00A0)
@(private = "file")
ZERO_WIDTH_FIRST :: rune(0x200B)
@(private = "file")
ZERO_WIDTH_LAST :: rune(0x200F)
@(private = "file")
BYTE_ORDER_MARK :: rune(0xFEFF)
@(private = "file")
IDEOGRAPHIC_SPACE :: rune(0x3000)
@(private = "file")
GENERAL_SPACE_FIRST :: rune(0x2000)
@(private = "file")
GENERAL_SPACE_LAST :: rune(0x200A)

// A cell of another font: this many columns and rows of squares, one bit of the character's pattern each (32 in all).
@(private = "file")
PATTERN_COLUMNS :: 4
@(private = "file")
PATTERN_ROWS :: 8
// The top-left square always set, the bottom-right never: no pattern looks the same turned around.
@(private = "file")
PATTERN_ALWAYS :: u32(1)
@(private = "file")
PATTERN_NEVER :: u32(1) << (PATTERN_COLUMNS * PATTERN_ROWS - 1)
// A bijection of 32 bits (MurmurHash3's finalizer): close code points get unrelated patterns.
@(private = "file")
MIX_SHIFT_A :: 16
@(private = "file")
MIX_SHIFT_B :: 13
@(private = "file")
MIX_FACTOR_A :: 0x85EBCA6B
@(private = "file")
MIX_FACTOR_B :: 0xC2B2AE35
// What a weight or a slant adds to a pattern: another face, other pixels.
@(private = "file")
BOLD_SEED :: 0x5BD1E995
@(private = "file")
ITALIC_SEED :: 0x1B873593
@(private = "file")
BOLD_WEIGHT :: 600
// Decorations (as render.odin): thickness a fifteenth of the font size, underline a third of the descent below.
@(private = "file")
DECO_THICKNESS_FRACTION :: 15.0
@(private = "file")
UNDERLINE_DESCENT_FRACTION :: 0.35
// A blurred text shadow is not blurred: fainter, as the painter's fast path (render.odin).
@(private = "file")
BLURRED_SHADOW_ALPHA :: 0.6
// Bullets (as render.odin): a circle's ring in fractions of its size, its roundness a half.
@(private = "file")
CIRCLE_RING_FRACTION :: 0.18
@(private = "file")
BULLET_ROUND :: HALF

@(private = "file")
is_blank :: #force_inline proc(r: rune) -> bool {
	return r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == NBSP || r == BYTE_ORDER_MARK || r == IDEOGRAPHIC_SPACE ||
	       (r >= GENERAL_SPACE_FIRST && r <= GENERAL_SPACE_LAST) || (r >= ZERO_WIDTH_FIRST && r <= ZERO_WIDTH_LAST)
}

@(private = "file")
is_word_space :: #force_inline proc(r: rune) -> bool { return r == ' ' || r == NBSP }

// The advance of a glyph of the font, as layout_host.odin measures it.
font_advance :: #force_inline proc(f: lay.Font, size: f32) -> f32 { return (f == AHEM_FONT ? 1 : OTHER_ADVANCE_EM) * size }

// Bidi controls and the like: nothing shows, nothing advances (as in every font).
is_invisible_format :: proc(r: rune) -> bool {
	return (r >= 0x200B && r <= 0x200F) || (r >= 0x202A && r <= 0x202E) || (r >= 0x2060 && r <= 0x2069) || r == 0xFEFF
}

// How a character's cell maps to the page: `Upright`: as written; `Rotated_Cw`: a quarter turn clockwise (what is at the
// glyph's top is at the right, its writing direction goes down).
@(private)
Cell_Frame :: enum u8 { Upright, Rotated_Cw, Rotated_Ccw }

@(private)
Cell :: struct {
	rect:  lay.Rect,   // on the page
	frame: Cell_Frame,
}

// A part of a cell given as fractions of the glyph's writing direction (u) and of its height from the top (v), snapped.
@(private)
cell_part :: proc(c: Cell, u0, v0, u1, v1: f32) -> lay.Rect {
	w, h := c.rect.max.x - c.rect.min.x, c.rect.max.y - c.rect.min.y
	switch c.frame {
	case .Upright:
		return snap_rect(lay.Rect{{c.rect.min.x + u0 * w, c.rect.min.y + v0 * h}, {c.rect.min.x + u1 * w, c.rect.min.y + v1 * h}})
	case .Rotated_Cw:
		return snap_rect(lay.Rect{{c.rect.max.x - v1 * w, c.rect.min.y + u0 * h}, {c.rect.max.x - v0 * w, c.rect.min.y + u1 * h}})
	case .Rotated_Ccw:
		// (the top of the character to the left, read upwards: sideways-lr)
		return snap_rect(lay.Rect{{c.rect.min.x + v0 * w, c.rect.max.y - u1 * h}, {c.rect.min.x + v1 * w, c.rect.max.y - u0 * h}})
	}
	return {}
}

// The pattern of a character: 32 bits, the top-left square set and the bottom-right not.
pattern_of :: proc(r: rune, bold, italic: bool) -> u32 {
	x := u32(r)
	if bold { x ~= BOLD_SEED }
	if italic { x ~= ITALIC_SEED }
	x ~= x >> MIX_SHIFT_A
	x *= MIX_FACTOR_A
	x ~= x >> MIX_SHIFT_B
	x *= MIX_FACTOR_B
	x ~= x >> MIX_SHIFT_A
	return (x | PATTERN_ALWAYS) & ~PATTERN_NEVER
}

// Draws one character in its cell. `ascent_share`: the share of the cell's height above the baseline.
@(private)
draw_glyph :: proc(rc: ^Raster, c: Cell, fi: ^lay.Font_Info, r: rune, ascent_share: f32, color: css_.Color) {
	if is_blank(r) { return }
	if fi.font == AHEM_FONT {
		u0, v0, u1, v1: f32 = 0, 0, 1, 1
		switch r {
		case AHEM_DESCENT_ONLY: v0 = ascent_share
		case AHEM_ASCENT_ONLY: v1 = ascent_share
		case AHEM_VERTICAL_BAR_A, AHEM_VERTICAL_BAR_B: u0, u1 = AHEM_BAR_START, AHEM_BAR_END
		case AHEM_HORIZONTAL_BAR_A, AHEM_HORIZONTAL_BAR_B: v0, v1 = AHEM_BAR_START, AHEM_BAR_END
		}
		fill_rect(rc, cell_part(c, u0, v0, u1, v1), color)
		return
	}
	bits := pattern_of(r, fi.weight >= BOLD_WEIGHT, fi.italic)
	for row in 0 ..< PATTERN_ROWS {
		for col in 0 ..< PATTERN_COLUMNS {
			if bits & (u32(1) << uint(row * PATTERN_COLUMNS + col)) == 0 { continue }
			fill_rect(rc, cell_part(c, f32(col) / PATTERN_COLUMNS, f32(row) / PATTERN_ROWS, f32(col + 1) / PATTERN_COLUMNS, f32(row + 1) / PATTERN_ROWS), color)
		}
	}
}

// What layout puts after a character, besides its advance.
@(private = "file")
spacing_after :: proc(rc: ^Raster, cs: ^style.Computed, it: ^lay.Display_Item, r: rune) -> f32 {
	s := cs.letter_spacing * rc.l.scale
	if is_word_space(r) { s += cs.word_spacing * rc.l.scale + it.extra }
	return s
}

// A run written left to right or right to left on a horizontal line (it.level says which).
@(private)
draw_run_horizontal :: proc(rc: ^Raster, it: ^lay.Display_Item, cs: ^style.Computed, fi: ^lay.Font_Info, color: css_.Color, shift: lay.Vec2) {
	rtl := it.level & 1 == 1
	pen := (rtl ? it.rect.max.x : it.rect.min.x) + shift.x
	base := snap(it.baseline + shift.y)
	top, bottom := base - fi.ascent, base + fi.descent
	height := fi.ascent + fi.descent
	share := height > 0 ? fi.ascent / height : ASCENT_EM
	adv := font_advance(fi.font, fi.size)
	for r in it.text {
		if is_invisible_format(r) { continue }
		x0 := rtl ? pen - adv : pen
		draw_glyph(rc, Cell{lay.Rect{{x0, top}, {x0 + adv, bottom}}, .Upright}, fi, r, share, color)
		step := adv + spacing_after(rc, cs, it, r)
		pen += rtl ? -step : step
	}
}

// Whether a character of a vertical run stands upright instead of being turned (CSS Writing Modes 4 §5.1). A stub until
// style has text-orientation: `sideways` is always false here, `upright` always true, and `mixed` follows Unicode's
// Vertical_Orientation (UTR #50): the caller adapts this procedure when cs.text_orientation exists.
text_upright :: proc(cs: ^style.Computed, r: rune) -> bool {
	if cs.writing_mode == .Sideways_Rl || cs.writing_mode == .Sideways_Lr { return false }
	switch cs.text_orientation {
	case .Upright: return true
	case .Sideways: return false
	case .Mixed:
	}
	return lay.vertical_upright(r)
}

// A text item with Item_Flag.Vertical: the run goes from top to bottom (bottom to top when it.level is odd); `it.rect` is
// the physical rect, tall; `it.baseline` holds the x of the baseline. Each cell is turned a quarter turn clockwise, so that
// the ascent is to the right of the baseline and the descent to its left, except the upright characters (text_upright), as
// written and centred on the baseline's x.
@(private)
draw_run_vertical :: proc(rc: ^Raster, it: ^lay.Display_Item, cs: ^style.Computed, fi: ^lay.Font_Info, color: css_.Color, shift: lay.Vec2) {
	ccw := cs.writing_mode == .Sideways_Lr
	// a right-to-left run comes in visual order from its far end, as on a horizontal line
	reversed := ccw != (it.level & 1 == 1)
	pen := (reversed ? it.rect.max.y : it.rect.min.y) + shift.y
	base := snap(it.baseline + shift.x)
	raw_a, raw_d := fi.raw_ascent, fi.raw_descent
	height := raw_a + raw_d
	share := height > 0 ? raw_a / height : ASCENT_EM
	adv := font_advance(fi.font, fi.size)
	if cs.text_combine_upright == .All {
		// an em along the line, what it holds squeezed into it
		n := f32(max(rune_count(it.text), 1))
		w := min(adv * n, fi.size)
		i: f32
		for r in it.text {
			x0 := base - w * HALF + i * (w / n)
			y0 := pen + (fi.size - height) * HALF
			draw_glyph(rc, Cell{lay.Rect{{x0, y0}, {x0 + w / n, y0 + height}}, .Upright}, fi, r, share, color)
			i += 1
		}
		return
	}
	// sideways glyphs on a central baseline: the middle of their box on it (as render.odin draws them)
	turned := fi.vmode == .Central ? base - (raw_a - raw_d) * HALF : base
	for r in it.text {
		if is_invisible_format(r) { continue }
		cell: Cell
		step: f32
		if text_upright(cs, r) {
			step = lay.upright_advance(r, fi.size, height)
			y0 := reversed ? pen - step : pen
			half := adv * HALF
			cell = Cell{lay.Rect{{base - half, y0}, {base + half, y0 + step}}, .Upright}
		} else {
			step = adv
			y0 := reversed ? pen - step : pen
			if ccw {
				cell = Cell{lay.Rect{{turned - raw_a, y0}, {turned + raw_d, y0 + step}}, .Rotated_Ccw}
			} else {
				cell = Cell{lay.Rect{{turned - raw_d, y0}, {turned + raw_a, y0 + step}}, .Rotated_Cw}
			}
		}
		draw_glyph(rc, cell, fi, r, share, color)
		step += spacing_after(rc, cs, it, r)
		pen += reversed ? -step : step
	}
}

@(private = "file")
rune_count :: proc(s: string) -> int {
	n := 0
	for _ in s { n += 1 }
	return n
}

@(private = "file")
draw_run :: proc(rc: ^Raster, it: ^lay.Display_Item, cs: ^style.Computed, fi: ^lay.Font_Info, color: css_.Color, shift := lay.Vec2{}) {
	if color.a <= 0 { return }
	if .Vertical in it.flags {
		draw_run_vertical(rc, it, cs, fi, color, shift)
	} else {
		draw_run_horizontal(rc, it, cs, fi, color, shift)
	}
}

// Underline, overline and line-through: along the run, on the side of the glyphs' top and bottom in a vertical one.
@(private = "file")
draw_decorations :: proc(rc: ^Raster, it: ^lay.Display_Item, cs: ^style.Computed, fi: ^lay.Font_Info) {
	col := rc.l.boxes[it.deco_box].cs.text_decoration_color
	if col.a == 0 { col = cs.color }
	t := max(1, math.round(fi.size / DECO_THICKNESS_FRACTION))
	band :: proc(rc: ^Raster, it: ^lay.Display_Item, offset, t: f32, col: css_.Color) {
		// `offset`: from the baseline towards the glyphs' bottom
		if .Vertical in it.flags {
			x := snap(it.baseline - offset)
			fill_rect(rc, snap_rect(lay.Rect{{x - t, it.rect.min.y}, {x, it.rect.max.y}}), col)
		} else {
			y := snap(it.baseline + offset)
			fill_rect(rc, snap_rect(lay.Rect{{it.rect.min.x, y}, {it.rect.max.x, y + t}}), col)
		}
	}
	if .Underline in it.deco { band(rc, it, max(fi.descent * UNDERLINE_DESCENT_FRACTION, 1), t, col) }
	if .Overline in it.deco { band(rc, it, -fi.ascent, t, col) }
	if .Line_Through in it.deco { band(rc, it, -fi.x_height * HALF - t * HALF, t, col) }
}

@(private)
paint_text :: proc(rc: ^Raster, it: ^lay.Display_Item) {
	cs := it.cs
	fi := lay.item_font(rc.l, it)
	if cs == nil || fi == nil || it.text == "" { return }
	for i := len(cs.text_shadow) - 1; i >= 0; i -= 1 {
		s := cs.text_shadow[i]
		if s.color.a <= 0 { continue }
		col := s.color
		if s.blur > 0 { col.a *= BLURRED_SHADOW_ALPHA }
		draw_run(rc, it, cs, fi, col, lay.Vec2{s.x, s.y} * rc.l.scale)
	}
	draw_run(rc, it, cs, fi, style.text_fill(cs))
	if it.deco != {} { draw_decorations(rc, it, cs, fi) }
}

// A list marker: text, or a bullet shape on the line's x-height middle (as render.odin).
@(private)
paint_marker :: proc(rc: ^Raster, it: ^lay.Display_Item) {
	cs := it.cs
	fi := lay.item_font(rc.l, it)
	if cs == nil || fi == nil { return }
	if it.text != "" {
		draw_run(rc, it, cs, fi, cs.color)
		return
	}
	if .Vertical in it.flags {
		// a bullet: on the line's middle
		h := it.rect.max.y - it.rect.min.y
		sq := snap_rect(lay.Rect{{it.baseline - h * HALF, it.rect.min.y}, {it.baseline + h * HALF, it.rect.max.y}})
		fill_rect(rc, sq, cs.color)
		return
	}
	s := it.rect.max.x - it.rect.min.x
	cy := it.baseline - fi.x_height * HALF
	sq := snap_rect(lay.Rect{{it.rect.min.x, cy - s * HALF}, {it.rect.min.x + s, cy + s * HALF}})
	#partial switch cs.list_style_type {
	case .Disc, .Circle:
		rad := s * BULLET_ROUND
		shape := Shape{rect = sq, radii = {{rad, rad}, {rad, rad}, {rad, rad}, {rad, rad}}}
		if cs.list_style_type == .Circle {
			ring := max(1, s * CIRCLE_RING_FRACTION)
			hr := max(rad - ring, 0)
			shape.hole = snap_rect(lay.Rect{sq.min + ring, sq.max - ring})
			shape.hole_radii = {{hr, hr}, {hr, hr}, {hr, hr}, {hr, hr}}
			shape.has_hole = true
		}
		p := solid(cs.color)
		fill(rc, &shape, &p)
	case .Square: fill_rect(rc, sq, cs.color)
	}
}
