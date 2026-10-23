package client

// `wren ctl diff a.png b.png [--tolerance n] [--out diff.png] [--max-percent p]`: two pictures compared pixel by pixel.
// A pixel differs when any channel differs by more than the tolerance (0..255). It prints the share of pixels that differ and
// the largest difference, writes an image of the differences (the second picture faded, each difference in red) and exits 0
// when the share is within --max-percent (default 0), else 1. Pictures of different sizes differ (exit 1).

import "core:bytes"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:os"
import "wb:images"

@(private)
load_png :: proc(path: string) -> (rgba: []u8, w, h: int, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { errln(fmt.tprintf("wren ctl diff: cannot read %s", path)); return }
	img, ierr := png.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	if ierr != nil || img == nil { errln(fmt.tprintf("wren ctl diff: %s is not a PNG picture", path)); return }
	defer image.destroy(img, context.temp_allocator)
	w, h = img.width, img.height
	buf := bytes.buffer_to_bytes(&img.pixels)
	switch img.channels {
	case 4: rgba = make([]u8, w * h * 4, context.temp_allocator); copy(rgba, buf)
	case 3:
		rgba = make([]u8, w * h * 4, context.temp_allocator)
		for i in 0 ..< w * h { rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3] = buf[i * 3], buf[i * 3 + 1], buf[i * 3 + 2], 255 }
	case 2:
		rgba = make([]u8, w * h * 4, context.temp_allocator)
		for i in 0 ..< w * h { g := buf[i * 2]; rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3] = g, g, g, buf[i * 2 + 1] }
	case 1:
		rgba = make([]u8, w * h * 4, context.temp_allocator)
		for i in 0 ..< w * h { g := buf[i]; rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3] = g, g, g, 255 }
	case: errln(fmt.tprintf("wren ctl diff: %s has an unsupported pixel format", path)); return
	}
	return rgba, w, h, true
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

cmd_diff :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) != 2 { return usage("diff", "usage: diff <a.png> <b.png> [--tolerance n] [--out diff.png] [--max-percent p]") }
	a, aw, ah, ok1 := load_png(args[0])
	b, bw, bh, ok2 := load_png(args[1])
	if !ok1 || !ok2 { return EXIT_FAILED }
	if aw != bw || ah != bh {
		outln(fmt.tprintf("sizes differ: %dx%d against %dx%d", aw, ah, bw, bh))
		return EXIT_FAILED
	}
	count, worst, picture := diff_pictures(a, b, aw, ah, opt_int(&ctx.o, "tolerance", 0))
	percent := f64(count) * 100 / f64(aw * ah)
	if path := opt(&ctx.o, "out"); path != "" {
		png_bytes, ok := images.encode_rgba(picture, aw, ah, .Png, 0, false)
		if !ok || os.write_entire_file(abs_path(path), png_bytes) != nil { errln("wren ctl diff: cannot write the difference picture"); return EXIT_FAILED }
		delete(png_bytes)
	}
	outln(fmt.tprintf("%.4f %% of %d pixels differ (%d pixels, largest channel difference %d)", percent, aw * ah, count, worst))
	limit := 0.0
	if s := opt(&ctx.o, "max-percent"); s != "" { limit, _ = parse_float(s) }
	return percent <= limit ? EXIT_OK : EXIT_FAILED
}
