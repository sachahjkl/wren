package browser

import "core:math"
import "core:thread"
import "wb:host"

////////////////////////////////
// The relief of the licence card: a height field engraved like a banknote (about:wren, shader card-foil, shaders.odin), turned into a
// NORMAL MAP the shader lights. Made here, natively, when the card is first painted; it lives in a texture of the renderer (no picture
// in the page, nothing kept on the CPU: made again after a device loss).
//
// What is engraved (u in [0, 1.586], v in [0, 1], the card's units, 1 = its height):
//  - a guilloche: two rosettes of wavy concentric rings (the pattern of the notes' backgrounds), fading into each other;
//  - a frame: a rounded lip that rises to the edge, with a bevel, and a groove running inside it;
//  - micro-lettering: "WREN" repeated in the frame along the top and the bottom edges, 7 texels tall, cut into the lip as the
//    microprint of a note is (a 5 x 7 face, two texels to a dot: only a magnifier or a tilt that raking light finds it);
//  - a grain: fine hash noise on everything, the tooth of the foil (the shader's glitter does not need it, the highlights do).
//
// The texture is RGBA8, 2x the size the card shows at 100 % (880 x 556 for 440 x 278 px), and the channels are the data the shader
// reads, not a color:
//     R, G   the normal's x and y (tangent space, y down like the card), 128 = 0; z is rebuilt by the shader
//     B      the height, 0 (deepest) to 255 (the top of the lip)
//     A      the cavity: how much the point lies below its surroundings (ambient occlusion of the engraving: the lines are dark)

NORMAL_W :: 880
NORMAL_H :: 556
CARD_ASPECT :: 1.586

// How steep the engraving is made (the height field has no unit: this scales its slopes into normals).
@(private = "file") SLOPE :: 2.0

@(private = "file") GLYPHS := [4][7]string{
	{"X...X", "X...X", "X...X", "X.X.X", "X.X.X", "XX.XX", "X...X"},   // W
	{"XXXX.", "X...X", "X...X", "XXXX.", "X.X..", "X..X.", "X...X"},   // R
	{"XXXXX", "X....", "X....", "XXXX.", "X....", "X....", "XXXXX"},   // E
	{"X...X", "XX..X", "XX..X", "X.X.X", "X..XX", "X..XX", "X...X"},   // N
}

// Dots of the micro-lettering: texels per dot, columns per letter (5 + a gap), the word: 4 letters and a gap of 3 columns.
@(private = "file") DOT :: 2
@(private = "file") PITCH :: 6
@(private = "file") WORD :: 4 * PITCH + 3

// Whether texel (x, y) of a band of micro-lettering is a dot of the lettering. `x`: texels from the start of the line.
@(private = "file")
letter_dot :: proc(x, y: int) -> bool {
	if x < 0 || y < 0 || y >= 7 * DOT { return false }
	col := (x / DOT) % WORD
	if col >= 4 * PITCH { return false }
	c, within := col / PITCH, col % PITCH
	if within >= 5 { return false }
	return GLYPHS[c][y / DOT][within] == 'X'
}

@(private = "file")
hash2 :: proc(x, y: int) -> f32 {
	h := u32(x) * 374761393 + u32(y) * 668265263
	h = (h ~ (h >> 13)) * 1274126177
	h ~= h >> 16
	return f32(h & 0xffff) / 65535
}

// The height of the engraving at a texel (the pattern above, without the grain).
@(private = "file")
height_at :: proc(x, y: int) -> f32 {
	u := (f32(x) + 0.5) / NORMAL_H
	v := (f32(y) + 0.5) / NORMAL_H
	ring :: proc(u, v, cx, cy, rings, wobble, lobes, phase: f32) -> (h, w: f32) {
		dx, dy := u - cx, v - cy
		r := math.sqrt(dx * dx + dy * dy)
		a := math.atan2(dy, dx)
		h = math.sin(2 * math.PI * rings * r + wobble * math.sin(lobes * a + phase))
		w = math.exp(-r * r / 0.30)
		return
	}
	h1, w1 := ring(u, v, 0.46, 0.50, 58, 3.2, 9, 1.3)
	h2, w2 := ring(u, v, 1.22, 0.64, 46, 2.4, 7, 0.4)
	h := (h1 * w1 + h2 * w2) / (w1 + w2 + 0.05) * 0.30
	edge := min(min(u, CARD_ASPECT - u), min(v, 1 - v))
	// the lip: a rounded rise to the edge
	bevel := 1 - clamp(edge / 0.04, 0, 1)
	h += bevel * bevel * 1.8
	// the groove inside the lip
	g := (edge - 0.055) / 0.006
	h -= 0.55 * math.exp(-g * g)
	// the micro-lettering, cut into the lip along the top and the bottom edges (below 0.07 from a corner: the radius)
	if u > 0.075 && u < CARD_ASPECT - 0.075 {
		band :: 8     // texels from the edge to the first row of the lettering (0.0135 of the height)
		start :: 42   // and from the left edge to the first letter
		if letter_dot(x - start, y - band) || letter_dot(x - start + 3 * DOT, (NORMAL_H - 1 - y) - band) { h -= 0.7 }
	}
	return h
}

Fill_Rows :: struct {
	hf:     []f32,
	y0, y1: int,
}

@(private = "file")
fill_rows :: proc(t: ^thread.Thread) {
	job := (^Fill_Rows)(t.data)
	for y in job.y0 ..< job.y1 {
		for x in 0 ..< NORMAL_W {
			job.hf[y * NORMAL_W + x] = height_at(x, y) + (hash2(x, y) - 0.5) * 0.10   // the grain
		}
	}
}

// The normal map: NORMAL_W x NORMAL_H texels of RGBA8 (see above), in `allocator`. The same bytes every time.
card_normal_map :: proc(allocator := context.allocator) -> []u8 {
	W, H :: NORMAL_W, NORMAL_H
	hf := make([]f32, W * H, allocator)
	defer delete(hf)
	// the height field, in bands of rows on a few threads (about 100 ms on one: the card should not stall the page when it first shows)
	workers := clamp(host.processor_count(), 1, 8)
	jobs := make([]Fill_Rows, workers, allocator)
	defer delete(jobs)
	threads := make([]^thread.Thread, workers, allocator)
	defer delete(threads)
	for i in 0 ..< workers {
		jobs[i] = Fill_Rows{hf = hf, y0 = H * i / workers, y1 = H * (i + 1) / workers}
		threads[i] = thread.create(fill_rows)
		threads[i].data = &jobs[i]
		thread.start(threads[i])
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}

	// the cavity: the height field against its own blur (a box of 13 x 13, two passes)
	R :: 6
	tmp := make([]f32, W * H, allocator)
	defer delete(tmp)
	blur := make([]f32, W * H, allocator)
	defer delete(blur)
	for y in 0 ..< H {
		for x in 0 ..< W {
			s: f32
			for k in -R ..= R { s += hf[y * W + clamp(x + k, 0, W - 1)] }
			tmp[y * W + x] = s / (2 * R + 1)
		}
	}
	for y in 0 ..< H {
		for x in 0 ..< W {
			s: f32
			for k in -R ..= R { s += tmp[clamp(y + k, 0, H - 1) * W + x] }
			blur[y * W + x] = s / (2 * R + 1)
		}
	}
	lo, hi := f32(1e9), f32(-1e9)
	for h in hf { lo, hi = min(lo, h), max(hi, h) }

	out := make([]u8, W * H * 4, allocator)
	for y in 0 ..< H {
		for x in 0 ..< W {
			xm, xp := max(x - 1, 0), min(x + 1, W - 1)
			ym, yp := max(y - 1, 0), min(y + 1, H - 1)
			// a 3 x 3 Sobel: the grain would make a one-texel difference too rough to light
			gx := (hf[ym * W + xp] + 2 * hf[y * W + xp] + hf[yp * W + xp] - hf[ym * W + xm] - 2 * hf[y * W + xm] - hf[yp * W + xm]) / (8 * f32(xp - xm) * 0.5)
			gy := (hf[yp * W + xm] + 2 * hf[yp * W + x] + hf[yp * W + xp] - hf[ym * W + xm] - 2 * hf[ym * W + x] - hf[ym * W + xp]) / (8 * f32(yp - ym) * 0.5)
			nx, ny, nz := -gx * SLOPE, -gy * SLOPE, f32(1)
			inv := 1 / math.sqrt(nx * nx + ny * ny + nz * nz)
			nx, ny = nx * inv, ny * inv
			i := (y * W + x) * 4
			out[i + 0] = u8(clamp(128 + nx * 127, 0, 255))
			out[i + 1] = u8(clamp(128 + ny * 127, 0, 255))
			out[i + 2] = u8(clamp((hf[y * W + x] - lo) / (hi - lo) * 255, 0, 255))
			out[i + 3] = u8(clamp((blur[y * W + x] - hf[y * W + x]) * 2.4 * 255, 0, 255))
		}
	}
	return out
}
