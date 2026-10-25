package browser

import "core:math"
import "toolkit:font"

////////////////////////////////
// The certification seal of the licence card, in relief: a medal of 88 CSS px that card-seal (shaders/card_foil.wgsl, seal_shade) lights with the
// card's own lights. Both of its textures are made here, natively, SEAL_TEX x SEAL_TEX texels (4 to a CSS px):
//
//  - the relief (seal_normal_map): a height field turned into normals, like the card's (about_card_relief.odin). From the edge in:
//        the reeded edge   r 37.6 .. 44    SEAL_FLUTES flutes round it, rounded off at the outer rim; gold
//        the lip           r 34.4 .. 37.6  a smooth rounded ring above the edge's valleys; gold
//        the rib           r 30.2 .. 32.2  a thin ring standing on the face; gold
//        the face          r < 34.4        a dome, with fine concentric rings (a groove every 2 px) that fade in towards the middle; green
//    R G the normal (x, y, y down), B how open the point is (255 in the open, less in a groove: the shader darkens it), A how gold it is.
//  - the lettering (seal_engraving): the word and the tick, raised like the card's text (about_card_engrave.odin has the channels).
//
// The medal is a disc: the texture is the square that holds it, the shader sees the box's own 0 .. 1.

SEAL_TEX     :: 352
SEAL_DESIGN  :: 88.0       // the medal's diameter, css px
SEAL_FLUTES  :: 45
@(private = "file") SEAL_SCALE :: f32(SEAL_TEX) / SEAL_DESIGN   // texels to a css px (4)

// The tick, in css px of the medal: a polyline stroked SEAL_TICK_W wide with round caps and joins (the CSS fallback draws the same one).
@(private = "file") SEAL_TICK := [3][2]f32{{31.75, 27.5}, {40.25, 36}, {56.25, 17}}
@(private = "file") SEAL_TICK_W :: 4.0
@(private = "file") SEAL_BEVEL_K :: 9.0   // steeper than the card's text: the word is small

// The word: its size, tracking and baseline, css px of the medal; it is centred.
@(private = "file") SEAL_WORD_SIZE :: 9.0
@(private = "file") SEAL_WORD_TRACK :: 0.08
@(private = "file") SEAL_WORD_BASELINE :: 56.5

@(private = "file")
smooth :: proc(a, b, x: f32) -> f32 {
	t := clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
}

// A rounded rib: cos² across `w` centred on `c`, `h` tall.
@(private = "file")
rib :: proc(r, c, w, h: f32) -> f32 {
	d := abs(r - c) / (w * 0.5)
	if d >= 1 { return 0 }
	k := math.cos(d * math.PI * 0.5)
	return h * k * k
}

// The height of the medal (css px) at `r` from its centre and `a` radians round it, and how gold the point is (0 .. 1).
@(private = "file")
seal_height :: proc(r, a: f32) -> (h, gold: f32) {
	if r >= 44 { return 0, 1 }
	// the reeded edge: flutes from 38 out, the outer rim falling away in the last px
	flute := 0.5 + 0.5 * math.cos(SEAL_FLUTES * a)
	edge := (1.3 + 0.55 * flute) * (1 - smooth(42.6, 44.0, r)) * smooth(37.0, 38.4, r)
	// the lip, standing above the edge's valleys
	lip := rib(r, 36.0, 3.4, 2.3)
	// the face: a dome that rises 3 px above its rim, and fine rings that fade in from the middle and out towards the rib
	dome := 0.4 + 11.0 * max(1 - (r / 34.4) * (r / 34.4), 0)
	fine := 0.14 * math.cos(2 * math.PI * r / 2.0) * smooth(2.0, 7.0, r) * (1 - smooth(27.5, 29.0, r))
	face := (dome + fine) * (1 - smooth(33.8, 34.8, r))
	h = max(max(edge, lip), face) + rib(r, 31.2, 2.0, 0.9)
	gold = max(max(smooth(37.0, 38.0, r), clamp(rib(r, 36.0, 3.4, 1) * 1.6, 0, 1)), clamp(rib(r, 31.2, 2.0, 1) * 1.7, 0, 1))
	return h, gold
}

// The relief of the seal: SEAL_TEX x SEAL_TEX texels of RGBA8 (see the top of the file), in `allocator`. The same bytes every time.
seal_normal_map :: proc(allocator := context.allocator) -> []u8 {
	N :: SEAL_TEX
	hf := make([]f32, N * N)
	defer delete(hf)
	gold := make([]f32, N * N)
	defer delete(gold)
	for y in 0 ..< N {
		for x in 0 ..< N {
			px, py := (f32(x) + 0.5) / SEAL_SCALE - SEAL_DESIGN / 2, (f32(y) + 0.5) / SEAL_SCALE - SEAL_DESIGN / 2
			hf[y * N + x], gold[y * N + x] = seal_height(math.sqrt(px * px + py * py), math.atan2(py, px))
		}
	}
	// the cavity: how far the point lies below its surroundings (a box of 17 x 17 texels, twice)
	blur := make([]f32, N * N)
	defer delete(blur)
	tmp := make([]f32, N * N)
	defer delete(tmp)
	copy(blur, hf)
	R :: 4
	for _ in 0 ..< 2 {
		for y in 0 ..< N { for x in 0 ..< N {
			s: f32
			for k in -R ..= R { s += blur[y * N + clamp(x + k, 0, N - 1)] }
			tmp[y * N + x] = s / (2 * R + 1)
		} }
		for y in 0 ..< N { for x in 0 ..< N {
			s: f32
			for k in -R ..= R { s += tmp[clamp(y + k, 0, N - 1) * N + x] }
			blur[y * N + x] = s / (2 * R + 1)
		} }
	}
	out := make([]u8, N * N * 4, allocator)
	for y in 0 ..< N {
		for x in 0 ..< N {
			xm, xp := max(x - 1, 0), min(x + 1, N - 1)
			ym, yp := max(y - 1, 0), min(y + 1, N - 1)
			gx := (hf[ym * N + xp] + 2 * hf[y * N + xp] + hf[yp * N + xp] - hf[ym * N + xm] - 2 * hf[y * N + xm] - hf[yp * N + xm]) / (8 * f32(xp - xm) * 0.5) * SEAL_SCALE
			gy := (hf[yp * N + xm] + 2 * hf[yp * N + x] + hf[yp * N + xp] - hf[ym * N + xm] - 2 * hf[ym * N + x] - hf[ym * N + xp]) / (8 * f32(yp - ym) * 0.5) * SEAL_SCALE
			nx, ny := -gx, -gy
			inv := 1 / math.sqrt(nx * nx + ny * ny + 1)
			i := (y * N + x) * 4
			out[i + 0] = u8(clamp(128 + nx * inv * 127, 0, 255))
			out[i + 1] = u8(clamp(128 + ny * inv * 127, 0, 255))
			out[i + 2] = u8(clamp((1 - (blur[y * N + x] - hf[y * N + x]) * 0.7) * 255, 90, 255))
			out[i + 3] = u8(clamp(gold[y * N + x] * 255, 0, 255))
		}
	}
	return out
}

// The distance from (px, py) to the segment a-b.
@(private = "file")
segment_distance :: proc(px, py: f32, a, b: [2]f32) -> f32 {
	dx, dy := b.x - a.x, b.y - a.y
	t := clamp(((px - a.x) * dx + (py - a.y) * dy) / (dx * dx + dy * dy), 0, 1)
	ex, ey := px - (a.x + t * dx), py - (a.y + t * dy)
	return math.sqrt(ex * ex + ey * ey)
}

// The lettering texture of the seal: `word` centred, then the tick, raised (SEAL_TEX x SEAL_TEX RGBA8, the channels of the card's text). False
// when no font can be had. Call it from the thread that draws.
seal_engraving :: proc(fs: ^font.State, renderer: u64, word: string, allocator := context.allocator) -> (texels: []u8, ok: bool) {
	N :: SEAL_TEX
	semibold, found := engrave_font(fs, renderer, true)
	if !found { return nil, false }
	blits := make([dynamic]Blit, context.temp_allocator)
	w := engrave_width(fs, semibold, word, SEAL_WORD_SIZE, SEAL_WORD_TRACK) - SEAL_WORD_TRACK * SEAL_WORD_SIZE
	engrave_line(fs, semibold, &blits, SEAL_SCALE, word, SEAL_DESIGN / 2 - w / 2, SEAL_WORD_BASELINE, SEAL_WORD_SIZE, SEAL_WORD_TRACK, false)
	cov := engrave_coverage(fs, blits[:], N, N)
	defer delete(cov)
	// the tick: coverage from the distance to the polyline, one texel of antialiasing
	for y in 0 ..< N {
		for x in 0 ..< N {
			px, py := (f32(x) + 0.5) / SEAL_SCALE, (f32(y) + 0.5) / SEAL_SCALE
			d := min(segment_distance(px, py, SEAL_TICK[0], SEAL_TICK[1]), segment_distance(px, py, SEAL_TICK[1], SEAL_TICK[2]))
			c := clamp((SEAL_TICK_W * 0.5 - d) * SEAL_SCALE + 0.5, 0, 1)
			cov[y * N + x] = max(cov[y * N + x], c)
		}
	}
	return engrave_raise(cov, N, N, allocator, SEAL_BEVEL_K), true
}
