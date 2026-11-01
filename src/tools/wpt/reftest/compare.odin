package reftest

// Pictures and WPT's comparison of them (tools/wptrunner/wptrunner/executors/base.py, RefTestImplementation): the largest
// difference of a channel, how many pixels differ, the annotation's ranges.

CHANNELS :: 4
@(private = "file")
OPAQUE_BYTE :: 255
@(private = "file")
DIFF_BACKGROUND_DIM :: 4       // what is the same shows at a quarter of its brightness...
@(private = "file")
DIFF_BACKGROUND_LIGHT :: 192   // ... over this
@(private = "file")
DIFF_MARK := [3]u8{255, 0, 0}   // what differs is red

// RGBA8, straight alpha, top row first, no gap between rows.
Image :: struct {
	width, height: int,
	rgba:          []u8,
}

image_make :: proc(w, h: int, allocator := context.allocator) -> Image {
	return Image{w, h, make([]u8, w * h * CHANNELS, allocator)}
}

image_destroy :: proc(img: ^Image, allocator := context.allocator) {
	delete(img.rgba, allocator)
	img^ = {}
}

Difference :: struct {
	max_channel: int,   // the largest difference of one channel of one pixel, 0..255
	pixels:      int,   // pixels with a difference
}

// Pictures of different sizes differ everywhere.
compare :: proc(a, b: ^Image) -> Difference {
	d: Difference
	if a.width != b.width || a.height != b.height {
		return Difference{max_channel = OPAQUE_BYTE, pixels = max(a.width * a.height, b.width * b.height)}
	}
	for i := 0; i < len(a.rgba); i += CHANNELS {
		differs := false
		for c in 0 ..< CHANNELS {
			delta := abs(int(a.rgba[i + c]) - int(b.rgba[i + c]))
			if delta > 0 { differs = true; d.max_channel = max(d.max_channel, delta) }
		}
		if differs { d.pixels += 1 }
	}
	return d
}

// Equal for the purposes of a test: exactly without an annotation, else in its ranges as wptrunner's check_pass has it (a
// range starting at 0 also admits no difference at all).
considered_equal :: proc(d: Difference, f: Fuzzy, has_fuzzy: bool) -> bool {
	if !has_fuzzy || (f.max_difference == {} && f.total_pixels == {}) { return d.pixels == 0 }
	if d.pixels == 0 && f.total_pixels[0] == 0 { return true }
	if d.max_channel == 0 && f.max_difference[0] == 0 { return true }
	return f.max_difference[0] <= d.max_channel && d.max_channel <= f.max_difference[1] &&
	       f.total_pixels[0] <= d.pixels && d.pixels <= f.total_pixels[1]
}

// The picture of a comparison: `a` dimmed where the pictures agree, red where they do not.
difference_image :: proc(a, b: ^Image, allocator := context.allocator) -> Image {
	w, h := max(a.width, b.width), max(a.height, b.height)
	out := image_make(w, h, allocator)
	at :: proc(img: ^Image, x, y: int) -> []u8 {
		if x >= img.width || y >= img.height { return nil }
		return img.rgba[(y * img.width + x) * CHANNELS:][:CHANNELS]
	}
	for y in 0 ..< h {
		for x in 0 ..< w {
			pa, pb := at(a, x, y), at(b, x, y)
			o := out.rgba[(y * w + x) * CHANNELS:][:CHANNELS]
			same := pa != nil && pb != nil
			if same { for c in 0 ..< CHANNELS { if pa[c] != pb[c] { same = false } } }
			if same {
				for c in 0 ..< CHANNELS - 1 { o[c] = u8(DIFF_BACKGROUND_LIGHT + int(pa[c]) / DIFF_BACKGROUND_DIM) }
			} else {
				o[0], o[1], o[2] = DIFF_MARK[0], DIFF_MARK[1], DIFF_MARK[2]
			}
			o[CHANNELS - 1] = OPAQUE_BYTE
		}
	}
	return out
}
