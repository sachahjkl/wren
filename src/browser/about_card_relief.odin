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

// The work of card_normal_map, stage by stage, on bands of rows (each stage reads what the one before it wrote).
@(private = "file")
Stage :: enum u8 { Height, Blur_X, Blur_Y, Normals }

@(private = "file")
Maps :: struct {
	hf, tmp, blur: []f32,
	emboss:        []f32,   // the back of the card: the height of what is raised on it (about_card_back.odin), nil for the front
	out:           []u8,
	lo, hi:        f32,
	stage:         Stage,
	y0, y1:        int,
}

@(private = "file") BLUR_R :: 6   // the cavity's box: 13 x 13, in two passes

@(private = "file")
run_band :: proc(t: ^thread.Thread) {
	m := (^Maps)(t.data)
	W, H :: NORMAL_W, NORMAL_H
	for y in m.y0 ..< m.y1 {
		for x in 0 ..< W {
			switch m.stage {
			case .Height:
				h := height_at(x, y)
				if m.emboss != nil {
					// the other face of a struck piece: what stands out on the front is hollow here, and the guilloche is calmed where the raised
					// figure stands (BACK_RELIEF tall, its bevel the blur of the figure's mask)
					e := m.emboss[y * W + x]
					h = -h * (1 - clamp(2 * e, 0, 1)) + BACK_RELIEF * e
				}
				m.hf[y * W + x] = h + (hash2(x, y) - 0.5) * 0.10   // the grain
			case .Blur_X:
				s: f32
				for k in -BLUR_R ..= BLUR_R { s += m.hf[y * W + clamp(x + k, 0, W - 1)] }
				m.tmp[y * W + x] = s / (2 * BLUR_R + 1)
			case .Blur_Y:
				s: f32
				for k in -BLUR_R ..= BLUR_R { s += m.tmp[clamp(y + k, 0, H - 1) * W + x] }
				m.blur[y * W + x] = s / (2 * BLUR_R + 1)
			case .Normals:
				hf := m.hf
				xm, xp := max(x - 1, 0), min(x + 1, W - 1)
				ym, yp := max(y - 1, 0), min(y + 1, H - 1)
				// a 3 x 3 Sobel: the grain would make a one-texel difference too rough to light
				gx := (hf[ym * W + xp] + 2 * hf[y * W + xp] + hf[yp * W + xp] - hf[ym * W + xm] - 2 * hf[y * W + xm] - hf[yp * W + xm]) / (8 * f32(xp - xm) * 0.5)
				gy := (hf[yp * W + xm] + 2 * hf[yp * W + x] + hf[yp * W + xp] - hf[ym * W + xm] - 2 * hf[ym * W + x] - hf[ym * W + xp]) / (8 * f32(yp - ym) * 0.5)
				nx, ny, nz := -gx * SLOPE, -gy * SLOPE, f32(1)
				inv := 1 / math.sqrt(nx * nx + ny * ny + nz * nz)
				nx, ny = nx * inv, ny * inv
				i := (y * W + x) * 4
				m.out[i + 0] = u8(clamp(128 + nx * 127, 0, 255))
				m.out[i + 1] = u8(clamp(128 + ny * 127, 0, 255))
				m.out[i + 2] = u8(clamp((hf[y * W + x] - m.lo) / (m.hi - m.lo) * 255, 0, 255))
				m.out[i + 3] = u8(clamp((m.blur[y * W + x] - hf[y * W + x]) * 2.4 * 255, 0, 255))
			}
		}
	}
}

// Runs one stage over all the rows on `workers` threads (the same bytes whatever the number: a texel depends on the stage before, not on a band).
@(private = "file")
run_stage :: proc(m: ^Maps, stage: Stage, workers: int) {
	m.stage = stage
	bands := make([]Maps, workers)
	threads := make([]^thread.Thread, workers)
	defer { delete(bands); delete(threads) }
	for i in 0 ..< workers {
		bands[i] = m^
		bands[i].y0, bands[i].y1 = NORMAL_H * i / workers, NORMAL_H * (i + 1) / workers
		threads[i] = thread.create(run_band)
		threads[i].data = &bands[i]
		thread.start(threads[i])
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
}

// The normal map: NORMAL_W x NORMAL_H texels of RGBA8 (see above), in `allocator`. The same bytes every time. Made on a few threads (the
// card should not stall the page when it first shows).
card_normal_map :: proc(allocator := context.allocator) -> []u8 { return relief_map(nil, allocator) }

// The relief of the card, or of its back when `emboss` (NORMAL_W x NORMAL_H, 0 .. 1) holds the figure raised on it.
@(private)
relief_map :: proc(emboss: []f32, allocator := context.allocator) -> []u8 {
	W, H :: NORMAL_W, NORMAL_H
	m := Maps{hf = make([]f32, W * H, allocator), tmp = make([]f32, W * H, allocator), blur = make([]f32, W * H, allocator), emboss = emboss, out = make([]u8, W * H * 4, allocator)}
	defer { delete(m.hf); delete(m.tmp); delete(m.blur) }
	workers := clamp(host.processor_count(), 1, 8)
	run_stage(&m, .Height, workers)
	run_stage(&m, .Blur_X, workers)
	run_stage(&m, .Blur_Y, workers)
	m.lo, m.hi = 1e9, -1e9
	for h in m.hf { m.lo, m.hi = min(m.lo, h), max(m.hi, h) }
	run_stage(&m, .Normals, workers)
	return m.out
}