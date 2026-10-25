package browser

import "core:math"
import "core:strings"
import "toolkit:font"

////////////////////////////////
// The text of the licence card, RAISED: instead of white HTML text over the foil, the name, the e-mail, the date and the order number stand
// out of the metal like the embossed lettering of a bank card. They are rasterized here, natively, with the toolkit's own glyph rasterizer
// (the same bitmaps the page's text uses, so the letters are as sharp as the page's), into a coverage field the size of the card at 3 texels
// per CSS pixel; a short blur of that field is the height of the lettering, and its gradient the normals of a real bevel (the same helpers
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

@(private)
Blit :: struct {
	page:   int,
	uv:     [4]f32,
	x, y:   int,
}

@(private = "file")
Pages :: struct { data: [dynamic][]u8, size: [dynamic]int }

@(private = "file")
page_upload :: proc(user: rawptr, page: int, kind: font.Page_Kind, x, y, w, h: int, pixels: []u8, stride: int) {
	p := (^Pages)(user)
	if kind != .Gray { return }
	for len(p.data) <= page { append(&p.data, nil); append(&p.size, 0) }
	size := stride   // a gray page: one byte a texel, stride is its width (the atlas is locked here: no calls back into it)
	if p.data[page] == nil { p.data[page] = make([]u8, size * size); p.size[page] = size }
	for row in 0 ..< h {
		copy(p.data[page][(y + row) * size + x:][:w], pixels[row * stride:][:w])
	}
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
// design, `scale` texels to a CSS px. The glyph bitmaps are collected as blits for engrave_coverage.
@(private)
engrave_line :: proc(fs: ^font.State, id: font.Font_Id, blits: ^[dynamic]Blit, scale: f32, text: string, x, baseline, size_css, track_em: f32, right: bool) {
	if text == "" { return }
	size := size_css * scale
	sh := font.shape(fs, id, size, text, {letter_spacing = track_em * size}, context.temp_allocator)
	x0 := x * scale - (right ? sh.width - track_em * size : 0)
	y0 := int(math.round(baseline * scale))
	for g in sh.glyphs {
		ix, sub := font.subpixel(fs, x0 + g.x)
		gi := font.glyph_image(fs, g.face, g.id, size, sub)
		if gi.page < 0 || gi.color { continue }
		append(blits, Blit{page = int(gi.page), uv = gi.uv, x = int(ix + gi.offset.x), y = y0 + int(math.round(g.y)) + int(gi.offset.y)})
	}
}

@(private)
engrave_width :: proc(fs: ^font.State, id: font.Font_Id, text: string, size_css, track_em: f32) -> f32 {
	if text == "" { return 0 }
	return font.measure(fs, id, size_css, text, {letter_spacing = track_em * size_css})
}

// The coverage (0 .. 1) of W x H texels from the glyph bitmaps in `blits`, in `allocator`.
@(private)
engrave_coverage :: proc(fs: ^font.State, blits: []Blit, W, H: int, allocator := context.allocator) -> []f32 {
	pages: Pages
	defer { for d in pages.data { delete(d) }; delete(pages.data); delete(pages.size) }
	for i in 0 ..< font.atlas_page_count(fs) { font.atlas_sync_page(fs, i, 0, &pages, page_upload) }
	cov := make([]f32, W * H, allocator)
	for b in blits {
		if b.page >= len(pages.data) || pages.data[b.page] == nil { continue }
		size := pages.size[b.page]
		x0, y0, x1, y1 := int(b.uv[0]), int(b.uv[1]), int(b.uv[2]), int(b.uv[3])
		for sy in y0 ..< y1 {
			for sx in x0 ..< x1 {
				dx, dy := b.x + (sx - x0), b.y + (sy - y0)
				if dx < 0 || dy < 0 || dx >= W || dy >= H { continue }
				v := f32(pages.data[b.page][sy * size + sx]) / 255
				cov[dy * W + dx] = max(cov[dy * W + dx], v)
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

	blits := make([dynamic]Blit, context.temp_allocator)
	line :: proc(fs: ^font.State, id: font.Font_Id, blits: ^[dynamic]Blit, text: string, x, baseline, size_css, track_em: f32, right: bool) {
		engrave_line(fs, id, blits, ENGRAVE_SCALE, text, x, baseline, size_css, track_em, right)
	}
	width :: engrave_width

	// the layout of the card's 440 x 277 px design (about_card.odin: padding 18 22, the logo, the middle block, the two meta blocks)
	line(fs, semibold, &blits, parts[0], 57, 38, 17, 0.02, false)
	line(fs, semibold, &blits, strings.to_upper(parts[1], context.temp_allocator), 418, 36, 11, 0.16, true)
	name_size: f32 = 24
	if w := width(fs, semibold, parts[2], 24, 0); w > 396 { name_size = max(24 * 396 / w, 13) }
	line(fs, semibold, &blits, parts[2], 22, 134, name_size, 0, false)
	line(fs, semibold, &blits, parts[3], 22, 152, 12, 0, false)
	x := f32(22)
	if parts[4] != "" {
		line(fs, semibold, &blits, "ISSUED", x, 233, 10, 0.14, false)
		line(fs, semibold, &blits, parts[4], x, 254, 13, 0, false)
		x += max(width(fs, regular_id, "ISSUED", 10, 0.14), width(fs, regular_id, parts[4], 13, 0)) + 26
	}
	if parts[5] != "" {
		line(fs, semibold, &blits, "ORDER", x, 233, 10, 0.14, false)
		line(fs, semibold, &blits, parts[5], x, 254, 13, 0, false)
	}

	cov := engrave_coverage(fs, blits[:], W, H)
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
