package browser

import "core:math"
import "core:strings"
import "toolkit:font"

////////////////////////////////
// The text of the licence card, RAISED: instead of white HTML text over the foil, the name, the e-mail, the date and the order number stand
// out of the metal like the embossed lettering of a bank card. They are rasterized here, natively, from the glyphs' outlines (font.glyph_outline
// filled by the toolkit's software rasterizer, font.colr_cover: the same shapes on every system; the glyph atlas has no bitmaps of plain text
// off Windows, where Slug draws the outlines), into a coverage field the size of the card at 3 texels per CSS pixel; a short blur of that field is the height of the lettering, and its gradient the normals of a real bevel (the same helpers
// raise the word and the tick of the seal: about_card_seal.odin). card-foil (shaders/card_foil.wgsl) lights it with the same lights as the
// rest of the card and makes the letters silver.
//
// The texture is RGBA8 (data), ENGRAVE_W x ENGRAVE_H over the whole card, so it follows the card when it is narrower than its 440 px:
//     R, G   the normal of the bevel (x, y, y down), 128 = flat: the top of a letter is flat, its flanks slope outwards
//     B      the coverage of the letters (255 inside)
//     A      the blurred coverage, the height of the letters: 255 on the top of a wide stroke, less towards its edge
// It depends on the licence, so it is made when the card is first painted and again when the text changes (shaders.odin keeps a hash of the
// text); nothing of it stays on the CPU.

ENGRAVE_W :: 1320
ENGRAVE_H :: 832
@(private) ENGRAVE_SCALE :: 3.0    // texels per CSS pixel of the 440 px design
BEVEL_R :: 2            // the box blur (radius, two passes) that makes the bevel: about 1.3 CSS px wide at 3 texels to a pixel
BEVEL_K :: 5.0          // how steep the flanks are made (the steepest slope of a blurred edge is 1 / (2 * BEVEL_R) a texel)

// The attribute of the card's box the text comes from: six fields, one per line (see card_engrave_fields).
ENGRAVE_ATTR :: "data-engrave"

@(private = "file") ENGRAVE_FLATNESS_PX :: 0.05   // how far a glyph's curves may stray from their outline, texels
@(private = "file") ENGRAVE_SAMPLES :: 4          // coverage samples per texel row (font.colr_cover: across a row it is exact)

// A glyph placed on the field: its face and index, its size in texels to the em, its pen on the baseline in texels.
@(private)
Glyph_Place :: struct {
	face:   font.Font_Id,
	gid:    u16,
	size:   f32,
	x, y:   f32,
}

@(private = "file") @(thread_local) engr_cache: struct { state: ^font.State, renderer: u64, id: [2]font.Font_Id, ok: [2]bool }

@(private)
engrave_font :: proc(fs: ^font.State, renderer: u64, bold: bool) -> (font.Font_Id, bool) {
	k := bold ? 1 : 0
	if engr_cache.state != fs || engr_cache.renderer != renderer { engr_cache = {state = fs, renderer = renderer} }
	if engr_cache.ok[k] { return engr_cache.id[k], true }
	id, ok := font.load_system(fs, "Segoe UI", bold ? 600 : 400)
	if !ok { id, ok = font.load_embedded(fs, font.FALLBACK_UI_DATA) }
	engr_cache.id[k], engr_cache.ok[k] = id, ok
	return id, ok
}

// One line of text shaped and placed, in texels: `x` is its left (or right, when `right`) edge and `baseline` its baseline, in CSS px of the
// design, `scale` texels to a CSS px. The glyphs are collected, placed, for engrave_coverage.
@(private)
engrave_line :: proc(fs: ^font.State, id: font.Font_Id, glyphs: ^[dynamic]Glyph_Place, scale: f32, text: string, x, baseline, size_css, track_em: f32, right: bool) {
	if text == "" { return }
	size := size_css * scale
	sh := font.shape(fs, id, size, text, {letter_spacing = track_em * size}, context.temp_allocator)
	x0 := x * scale - (right ? sh.width - track_em * size : 0)
	y0 := math.round(baseline * scale)
	for g in sh.glyphs { append(glyphs, Glyph_Place{face = g.face, gid = g.id, size = size, x = x0 + g.x, y = y0 + g.y}) }
}

@(private)
engrave_width :: proc(fs: ^font.State, id: font.Font_Id, text: string, size_css, track_em: f32) -> f32 {
	if text == "" { return 0 }
	return font.measure(fs, id, size_css, text, {letter_spacing = track_em * size_css})
}

// The coverage (0 .. 1) of W x H texels from the outlines of `glyphs`, in `allocator`.
@(private)
engrave_coverage :: proc(fs: ^font.State, glyphs: []Glyph_Place, W, H: int, allocator := context.allocator) -> []f32 {
	cov := make([]f32, W * H, allocator)
	o: font.Outline
	defer font.outline_destroy(&o)
	for g in glyphs {
		clear(&o.quads)
		clear(&o.ends)
		if g.size <= 0 || !font.glyph_outline(fs, g.face, g.gid, ENGRAVE_FLATNESS_PX / g.size, &o) { continue }
		// em units, y up, to texels, y down, the pen at (x, y)
		m := font.Mat{g.size, 0, 0, -g.size, g.x, g.y}
		rect, part, ok := font.colr_cover(&o, m, {0, 0, W, H}, ENGRAVE_SAMPLES, context.temp_allocator)
		if !ok { continue }
		w := rect[2] - rect[0]
		for y in rect[1] ..< rect[3] {
			for x in rect[0] ..< rect[2] {
				cov[y * W + x] = max(cov[y * W + x], part[(y - rect[1]) * w + (x - rect[0])])
			}
		}
	}
	return cov
}

// The texture of raised lettering from a coverage field (see the top of the file for the channels): the height is the coverage blurred (a box
// of 2 * BEVEL_R + 1, twice, in both directions), its slopes the bevel. The surface is RAISED where the letters are: its normal is
// (-dh/dx, -dh/dy, 1), so a flank facing up-left tilts up-left. Does not keep `cov`.
@(private)
engrave_raise :: proc(cov: []f32, W, H: int, allocator := context.allocator, steep: f32 = BEVEL_K) -> []u8 {
	h := make([]f32, W * H)
	defer delete(h)
	tmp := make([]f32, W * H)
	defer delete(tmp)
	copy(h, cov)
	for _ in 0 ..< 2 {
		for y in 0 ..< H {
			for x in 0 ..< W {
				s: f32
				for k in -BEVEL_R ..= BEVEL_R { s += h[y * W + clamp(x + k, 0, W - 1)] }
				tmp[y * W + x] = s / (2 * BEVEL_R + 1)
			}
		}
		for y in 0 ..< H {
			for x in 0 ..< W {
				s: f32
				for k in -BEVEL_R ..= BEVEL_R { s += tmp[clamp(y + k, 0, H - 1) * W + x] }
				h[y * W + x] = s / (2 * BEVEL_R + 1)
			}
		}
	}
	out := make([]u8, W * H * 4, allocator)
	for y in 0 ..< H {
		for x in 0 ..< W {
			xm, xp := max(x - 1, 0), min(x + 1, W - 1)
			ym, yp := max(y - 1, 0), min(y + 1, H - 1)
			gx := (h[ym * W + xp] + 2 * h[y * W + xp] + h[yp * W + xp] - h[ym * W + xm] - 2 * h[y * W + xm] - h[yp * W + xm]) / (8 * f32(xp - xm) * 0.5)
			gy := (h[yp * W + xm] + 2 * h[yp * W + x] + h[yp * W + xp] - h[ym * W + xm] - 2 * h[ym * W + x] - h[ym * W + xp]) / (8 * f32(yp - ym) * 0.5)
			nx, ny := -gx * steep, -gy * steep
			inv := 1 / math.sqrt(nx * nx + ny * ny + 1)
			i := (y * W + x) * 4
			out[i + 0] = u8(clamp(128 + nx * inv * 127, 0, 255))
			out[i + 1] = u8(clamp(128 + ny * inv * 127, 0, 255))
			out[i + 2] = u8(clamp(cov[y * W + x] * 255, 0, 255))
			out[i + 3] = u8(clamp(h[y * W + x] * 255, 0, 255))
		}
	}
	return out
}

// The six fields of the card, in the order card_engraving reads them: the product, the edition, the name, the e-mail, the date, the order.
card_engrave_fields :: proc(product, edition, name, email, date, order: string) -> string {
	return strings.join({product, edition, name, email, date, order}, "\n", context.temp_allocator)
}

// The lettering texture of the card with these fields (ENGRAVE_W x ENGRAVE_H RGBA8), in `allocator`; false when no font can be had. Needs the
// draw context's font state: call it from the thread that draws.
card_engraving :: proc(fs: ^font.State, renderer: u64, fields: string, allocator := context.allocator) -> (texels: []u8, ok: bool) {
	W, H :: ENGRAVE_W, ENGRAVE_H
	parts := strings.split(fields, "\n", context.temp_allocator)
	for len(parts) < 6 { parts = append_str(parts, "") }
	semibold, ok1 := engrave_font(fs, renderer, true)
	regular_id, ok2 := engrave_font(fs, renderer, false)
	if !ok1 || !ok2 { return nil, false }

	glyphs := make([dynamic]Glyph_Place, context.temp_allocator)
	line :: proc(fs: ^font.State, id: font.Font_Id, glyphs: ^[dynamic]Glyph_Place, text: string, x, baseline, size_css, track_em: f32, right: bool) {
		engrave_line(fs, id, glyphs, ENGRAVE_SCALE, text, x, baseline, size_css, track_em, right)
	}
	width :: engrave_width

	// the layout of the card's 440 x 277 px design (about_card.odin: padding 18 22, the logo, the middle block, the two meta blocks)
	line(fs, semibold, &glyphs, parts[0], 57, 38, 17, 0.02, false)
	line(fs, semibold, &glyphs, strings.to_upper(parts[1], context.temp_allocator), 418, 36, 11, 0.16, true)
	name_size: f32 = 24
	if w := width(fs, semibold, parts[2], 24, 0); w > 396 { name_size = max(24 * 396 / w, 13) }
	line(fs, semibold, &glyphs, parts[2], 22, 134, name_size, 0, false)
	line(fs, semibold, &glyphs, parts[3], 22, 152, 12, 0, false)
	x := f32(22)
	if parts[4] != "" {
		line(fs, semibold, &glyphs, "ISSUED", x, 233, 10, 0.14, false)
		line(fs, semibold, &glyphs, parts[4], x, 254, 13, 0, false)
		x += max(width(fs, regular_id, "ISSUED", 10, 0.14), width(fs, regular_id, parts[4], 13, 0)) + 26
	}
	if parts[5] != "" {
		line(fs, semibold, &glyphs, "ORDER", x, 233, 10, 0.14, false)
		line(fs, semibold, &glyphs, parts[5], x, 254, 13, 0, false)
	}

	cov := engrave_coverage(fs, glyphs[:], W, H)
	defer delete(cov)
	return engrave_raise(cov, W, H, allocator), true
}

@(private = "file")
append_str :: proc(a: []string, s: string) -> []string {
	b := make([]string, len(a) + 1, context.temp_allocator)
	copy(b, a)
	b[len(a)] = s
	return b
}
