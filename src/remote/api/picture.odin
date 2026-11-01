package api

// Pictures read back: a PNG of a capture as pixels, a pixel of it, two of them compared.

import "core:bytes"
import "core:image"
import "core:image/png"
import "core:os"

Image :: struct {
	rgba:          []u8,   // width * height * 4, in the thread's temporary memory
	width, height: int,
}

// A PNG file as RGBA pixels. false: it cannot be read, or is no PNG (last_failure).
load_image :: proc(path: string) -> (p: Image, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { set_failure("cannot read the picture"); return }
	return decode_png(data)
}

// A PNG in memory as RGBA pixels.
decode_png :: proc(data: []byte) -> (p: Image, ok: bool) {
	img, ierr := png.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	if ierr != nil || img == nil { set_failure("not a PNG picture"); return }
	defer image.destroy(img, context.temp_allocator)
	w, h := img.width, img.height
	buf := bytes.buffer_to_bytes(&img.pixels)
	rgba := make([]u8, w * h * 4, context.temp_allocator)
	switch img.channels {
	case 4: copy(rgba, buf)
	case 3: for i in 0 ..< w * h { rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3] = buf[i * 3], buf[i * 3 + 1], buf[i * 3 + 2], 255 }
	case 2: for i in 0 ..< w * h { g := buf[i * 2]; rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3] = g, g, g, buf[i * 2 + 1] }
	case 1: for i in 0 ..< w * h { g := buf[i]; rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3] = g, g, g, 255 }
	case: set_failure("an unsupported pixel format"); return
	}
	return {rgba, w, h}, true
}

// A pixel: c.r, c.g, c.b, c.a.
Color :: [4]u8

// One pixel of a picture (a point outside it: all 0).
pixel :: proc(p: Image, x, y: int) -> Color {
	if x < 0 || y < 0 || x >= p.width || y >= p.height { return {} }
	at := (y * p.width + x) * 4
	return {p.rgba[at], p.rgba[at + 1], p.rgba[at + 2], p.rgba[at + 3]}
}

// Compares two RGBA pictures of one size. Returns how many pixels differ, the largest channel difference, and the picture of
// the differences (the second one at a quarter of its strength, a differing pixel in red).
diff_pictures :: proc(a, b: []u8, w, h: int, tolerance: int, allocator := context.temp_allocator) -> (count, max_delta: int, out: []u8) {
	out = make([]u8, w * h * 4, allocator)
	for i in 0 ..< w * h {
		worst := 0
		for k in 0 ..< 4 { worst = max(worst, abs(int(a[i * 4 + k]) - int(b[i * 4 + k]))) }
		max_delta = max(max_delta, worst)
		if worst > tolerance {
			count += 1
			out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = 255, 0, 0, 255
		} else {
			for k in 0 ..< 3 { out[i * 4 + k] = u8(255 - (255 - int(b[i * 4 + k])) / 4) }
			out[i * 4 + 3] = 255
		}
	}
	return
}
