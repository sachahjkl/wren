package images

import "core:testing"

@(private = "file")
roundtrip_opts :: proc() -> Decode_Options { return Decode_Options{limits = LIMITS_DEFAULT} }

@(test)
png_roundtrip_keeps_straight_alpha :: proc(t: ^testing.T) {
	// 2 x 2: opaque red, half-transparent green (premultiplied 0, 64, 0, 128), transparent, opaque white
	px := []u8{255, 0, 0, 255, 0, 64, 0, 128, 0, 0, 0, 0, 255, 255, 255, 255}
	bytes, ok := encode_rgba(px, 2, 2, .Png, 1, true)
	testing.expect(t, ok, "encoded")
	if !ok { return }
	defer delete(bytes)
	testing.expect_value(t, string(bytes[1:4]), "PNG")
	img, info, err := decode_now(bytes, roundtrip_opts())
	testing.expect_value(t, err, Error.None)
	if img == nil { return }
	defer image_destroy(img)
	testing.expect_value(t, info.format, Format.Png)
	testing.expect_value(t, img.width, 2)
	p := img.frames[0].pixels
	testing.expect_value(t, [4]u8{p[0], p[1], p[2], p[3]}, [4]u8{255, 0, 0, 255})
	testing.expect_value(t, [4]u8{p[4], p[5], p[6], p[7]}, [4]u8{0, 128, 0, 128})   // 64 / 128 * 255 = 127.5 -> 128
	testing.expect_value(t, p[11], 0)
	testing.expect_value(t, [4]u8{p[12], p[13], p[14], p[15]}, [4]u8{255, 255, 255, 255})
}

@(test)
jpeg_is_close_and_transparent_becomes_black :: proc(t: ^testing.T) {
	w, h := 16, 16
	px := make([]u8, w * h * 4)
	defer delete(px)
	for i in 0 ..< w * h {
		if i % w < 8 { px[i * 4], px[i * 4 + 3] = 200, 255 } else { px[i * 4 + 3] = 0 }   // left half red, right half transparent
	}
	bytes, ok := encode_rgba(px, w, h, .Jpeg, 0.95, true)
	testing.expect(t, ok, "encoded")
	if !ok { return }
	defer delete(bytes)
	testing.expect(t, bytes[0] == 0xff && bytes[1] == 0xd8, "a JPEG")
	img, _, err := decode_now(bytes, roundtrip_opts())
	testing.expect_value(t, err, Error.None)
	if img == nil { return }
	defer image_destroy(img)
	p := img.frames[0].pixels
	left, right := p[(8 * w + 2) * 4:][:4], p[(8 * w + 13) * 4:][:4]
	testing.expect(t, left[0] > 180 && left[0] < 220 && left[1] < 30 && left[3] == 255, "the red half")
	testing.expect(t, right[0] < 20 && right[1] < 20 && right[2] < 20, "transparent became black")
}

@(test)
encode_refuses_bad_input :: proc(t: ^testing.T) {
	_, ok := encode_rgba(nil, 0, 0, .Png, 1, true)
	testing.expect(t, !ok, "empty image")
	_, ok = encode_rgba(make([]u8, 4, context.temp_allocator), 2, 2, .Png, 1, true)
	testing.expect(t, !ok, "pixels too short")
}
