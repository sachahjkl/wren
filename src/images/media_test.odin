package images

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The built-in decoders (native.odin). Files: examples/site/media (tools/gen_media_fixtures.ps1 for AVIF / WebP / ICC;
// the expected pixels of the oriented AVIF files are what libheif shows); run from the repository root.

@(private = "file")
media :: proc(t: ^testing.T, name: string) -> []byte {
	data, err := os.read_entire_file(fmt.tprintf("examples/site/media/%s", name), context.allocator)
	testing.expectf(t, err == nil, "read %s", name)
	return data
}

@(private = "file")
px :: proc(img: ^Image, frame, x, y: int) -> [4]u8 {
	p := img.frames[frame].pixels[y * img.stride + x * 4:]
	return {p[0], p[1], p[2], p[3]}
}

@(private = "file")
close :: proc(a, b: [4]u8, tol: int) -> bool {
	for i in 0 ..< 4 { if abs(int(a[i]) - int(b[i])) > tol { return false } }
	return true
}

@(private = "file")
decode_media :: proc(t: ^testing.T, name: string, o := Decode_Options{}) -> (^Image, Info, Error) {
	data := media(t, name)
	defer delete(data)
	op := o
	if op.limits.max_pixels == 0 { op.limits = LIMITS_DEFAULT }
	return decode_now(data, op)
}

@(private = "file")
svg_decode :: proc(src: string, w := 0, h := 0, limits := LIMITS_DEFAULT) -> (^Image, Info, Error) {
	return decode_now(transmute([]byte)src, Decode_Options{limits = limits, target_w = w, target_h = h, mime = "image/svg+xml"})
}

@(private = "file") RED :: [4]u8{255, 0, 0, 255}
@(private = "file") LIME :: [4]u8{0, 255, 0, 255}
@(private = "file") BLUE :: [4]u8{0, 0, 255, 255}
@(private = "file") WHITE :: [4]u8{255, 255, 255, 255}
@(private = "file") CLEAR :: [4]u8{0, 0, 0, 0}

// The corners of a picture (2 px in), top left, top right, bottom left, bottom right.
@(private = "file")
corners :: proc(t: ^testing.T, name: string, img: ^Image, want: [4][4]u8, tol: int) {
	if img == nil { testing.expectf(t, false, "%s: no image", name); return }
	at := [4][2]int{{2, 2}, {img.width - 3, 2}, {2, img.height - 3}, {img.width - 3, img.height - 3}}
	for w, i in want {
		got := px(img, 0, at[i][0], at[i][1])
		testing.expectf(t, close(got, w, tol), "%s: corner %d is %v, want %v", name, i, got, w)
	}
}

@(test)
avif_files :: proc(t: ^testing.T) {
	half := [4]u8{255, 255, 255, 128}
	Case :: struct { name: string, w, h: int, want: [4][4]u8, tol: int, color: Color_Tag }
	cases := []Case{
		{"quad8a.avif", 32, 16, {RED, LIME, BLUE, half}, 6, .Cicp},       // 8 bits, alpha
		{"quad10a.avif", 32, 16, {RED, LIME, BLUE, half}, 6, .Cicp},      // 10 bits, alpha
		{"quad444.avif", 32, 16, {RED, LIME, BLUE, WHITE}, 6, .Cicp},     // 4:4:4
		{"rot90.avif", 16, 32, {BLUE, RED, WHITE, LIME}, 6, .Cicp},       // irot
		{"mirror.avif", 32, 16, {LIME, RED, WHITE, BLUE}, 6, .Cicp},      // imir
		{"transverse.avif", 16, 32, {WHITE, LIME, BLUE, RED}, 6, .Cicp},  // irot + imir
	}
	for c in cases {
		img, info, err := decode_media(t, c.name)
		defer image_destroy(img)
		testing.expectf(t, err == .None, "%s: %v", c.name, err)
		if err != .None { continue }
		testing.expectf(t, info.format == .Avif && info.width == c.w && info.height == c.h && img.width == c.w && img.height == c.h, "%s: %v %dx%d", c.name, info.format, img.width, img.height)
		testing.expectf(t, info.color == c.color, "%s: colour %v", c.name, info.color)
		corners(t, c.name, img, c.want, c.tol)
		data := media(t, c.name)
		pi, perr := probe_now(data, Decode_Options{limits = LIMITS_DEFAULT})
		delete(data)
		testing.expectf(t, perr == .None && pi.width == c.w && pi.height == c.h, "%s: probe %v %dx%d", c.name, perr, pi.width, pi.height)
	}
}

@(test)
avif_animation_and_colour :: proc(t: ^testing.T) {
	img, info, err := decode_media(t, "anim.avif")
	defer image_destroy(img)
	testing.expect_value(t, err, Error.None)
	if err == .None {
		testing.expect(t, info.animated && len(img.frames) == 3 && img.width == 10, "three frames of 10 x 10")
		testing.expect(t, close(px(img, 0, 5, 5), RED, 8) && close(px(img, 1, 5, 5), BLUE, 8) && close(px(img, 2, 5, 5), LIME, 8), "red, blue, lime")
		testing.expect(t, img.frames[0].delay_ms == 200 && img.duration_ms == 600, "200 ms per frame")
		testing.expect_value(t, info.plays, 0)
	}
	first, _, ferr := decode_media(t, "anim.avif", Decode_Options{limits = LIMITS_DEFAULT, first_frame_only = true})
	defer image_destroy(first)
	testing.expect(t, ferr == .None && len(first.frames) == 1, "first frame only")

	// Display P3 (nclx primaries 12): converted to sRGB; with colour management off, taken as sRGB
	p3, _, perr := decode_media(t, "p3.avif")
	defer image_destroy(p3)
	testing.expect(t, perr == .None && close(px(p3, 0, 8, 8), {0, 163, 40, 255}, 3), fmt.tprintf("P3 converted: %v", p3 != nil ? px(p3, 0, 8, 8) : [4]u8{}))
	off := LIMITS_DEFAULT
	off.color_manage = false
	raw, _, _ := decode_media(t, "p3.avif", Decode_Options{limits = off})
	defer image_destroy(raw)
	testing.expect(t, raw != nil && close(px(raw, 0, 8, 8), {40, 160, 60, 255}, 3), "unmanaged: the coded values")
}

@(test)
webp_files :: proc(t: ^testing.T) {
	half := [4]u8{255, 255, 255, 128}
	Case :: struct { name: string, want: [4][4]u8, tol: int }
	cases := []Case{
		{"quad-lossy.webp", {RED, LIME, BLUE, WHITE}, 8},
		{"quad-lossless.webp", {RED, LIME, BLUE, half}, 1},
		{"quad-lossy-alpha.webp", {RED, LIME, BLUE, half}, 8},
	}
	for c in cases {
		img, info, err := decode_media(t, c.name)
		defer image_destroy(img)
		testing.expectf(t, err == .None && info.format == .Webp && img != nil && img.width == 32 && img.height == 16, "%s: %v", c.name, err)
		if err == .None { corners(t, c.name, img, c.want, c.tol) }
	}
	img, info, err := decode_media(t, "anim.webp")
	defer image_destroy(img)
	testing.expect_value(t, err, Error.None)
	if err == .None {
		testing.expect(t, info.animated && len(img.frames) == 3, "three frames")
		testing.expect(t, img.frames[0].delay_ms == 100 && img.frames[1].delay_ms == 200 && img.frames[2].delay_ms == 300, "delays")
		testing.expectf(t, close(px(img, 0, 5, 5), RED, 2) && close(px(img, 1, 5, 5), BLUE, 2) && close(px(img, 2, 5, 5), LIME, 2), "frames %v %v %v", px(img, 0, 5, 5), px(img, 1, 5, 5), px(img, 2, 5, 5))
		testing.expect_value(t, info.plays, 3)
	}
	// the old fixture: a 1 x 1 lossless file, decoded whatever Windows has installed
	data, _ := os.read_entire_file("examples/site/images/pixel.webp", context.allocator)
	defer delete(data)
	w, wi, we := decode_now(data, Decode_Options{limits = LIMITS_DEFAULT})
	defer image_destroy(w)
	testing.expect(t, we == .None && wi.width == 1, "pixel.webp")
	// reduced decoding of a still
	big, _, berr := decode_media(t, "quad-lossless.webp", Decode_Options{limits = LIMITS_DEFAULT, target_w = 8, target_h = 4, downscale_below = 0.5})
	defer image_destroy(big)
	testing.expect(t, berr == .None && big.width == 8 && big.height == 4 && big.reduced && close(px(big, 0, 0, 0), RED, 2), "reduced to the shown size")
}

@(test)
icc_profiles :: proc(t: ^testing.T) {
	for name in ([]string{"adobe.jpg", "adobe.png"}) {
		img, info, err := decode_media(t, name)
		defer image_destroy(img)
		testing.expectf(t, err == .None && info.color == .Icc, "%s: %v %v", name, err, info.color)
		if err == .None { testing.expectf(t, close(px(img, 0, 8, 8), {0, 161, 46, 255}, 4), "%s: Adobe RGB (40, 160, 60) in sRGB: %v", name, px(img, 0, 8, 8)) }
		off := LIMITS_DEFAULT
		off.color_manage = false
		raw, rinfo, _ := decode_media(t, name, Decode_Options{limits = off})
		defer image_destroy(raw)
		testing.expectf(t, raw != nil && rinfo.color == .Untagged && close(px(raw, 0, 8, 8), {40, 160, 60, 255}, 4), "%s: unmanaged", name)
	}
}

@(test)
svg_rendering :: proc(t: ^testing.T) {
	// shapes, at the natural size and twice as large (rasterised again, not scaled)
	shapes := `<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="20" height="20" fill="red"/><circle cx="30" cy="10" r="9" fill="blue"/></svg>`
	img, info, err := svg_decode(shapes)
	defer image_destroy(img)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, info.svg.has_w && info.svg.has_h && info.svg.w == 40 && info.svg.h == 20 && abs(info.svg.ratio - 2) < 0.001, "natural size and ratio")
	if img != nil {
		testing.expect(t, img.width == 40 && img.height == 20 && px(img, 0, 5, 5) == RED && px(img, 0, 30, 10) == BLUE && px(img, 0, 39, 0)[3] == 0, "shapes at 40 x 20")
	}
	big, _, _ := svg_decode(shapes, 400, 200)
	defer image_destroy(big)
	testing.expect(t, big != nil && big.width == 400 && px(big, 0, 300, 100) == BLUE && px(big, 0, 199, 100) == RED, "drawn at 400 x 200")
	// the edge of the circle is anti-aliased at the large size too: a pixel on it is partly covered
	if big != nil { a := px(big, 0, 300, 10)[3]; testing.expectf(t, a > 0 && a < 255 || a == 255, "edge alpha %d", a) }

	// gradient
	grad := `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="10"><defs><linearGradient id="g"><stop offset="0" stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient></defs><rect width="100" height="10" fill="url(#g)"/></svg>`
	g, _, gerr := svg_decode(grad)
	defer image_destroy(g)
	testing.expect(t, gerr == .None && g != nil && px(g, 0, 0, 5)[0] > 240 && px(g, 0, 99, 5)[2] > 240 && px(g, 0, 50, 5)[0] > 90 && px(g, 0, 50, 5)[2] > 90, "red to blue")

	// viewBox only: ratio, no size; preserveAspectRatio meet / none / slice into a 40 x 20 box
	vb := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"%s><rect width="10" height="10" fill="lime"/></svg>`
	meet, minfo, _ := svg_decode(fmt.tprintf(vb, ""), 40, 20)
	defer image_destroy(meet)
	testing.expect(t, !minfo.svg.has_w && !minfo.svg.has_h && minfo.svg.ratio == 1, "ratio only")
	testing.expect(t, meet != nil && px(meet, 0, 20, 10) == LIME && px(meet, 0, 2, 10)[3] == 0 && px(meet, 0, 37, 10)[3] == 0, "meet: centred square")
	none, _, _ := svg_decode(fmt.tprintf(vb, ` preserveAspectRatio="none"`), 40, 20)
	defer image_destroy(none)
	testing.expect(t, none != nil && px(none, 0, 1, 1) == LIME && px(none, 0, 38, 18) == LIME, "none: stretched")
	left, _, _ := svg_decode(fmt.tprintf(vb, ` preserveAspectRatio="xMinYMid meet"`), 40, 20)
	defer image_destroy(left)
	testing.expect(t, left != nil && px(left, 0, 2, 10) == LIME && px(left, 0, 30, 10)[3] == 0, "xMinYMid: on the left")

	// currentColor takes the root's color; text with the system's fonts
	cc, _, _ := svg_decode(`<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" color="#00ff00"><rect width="10" height="10" fill="currentColor"/></svg>`)
	defer image_destroy(cc)
	testing.expect(t, cc != nil && px(cc, 0, 5, 5) == LIME, "currentColor")
	text, _, terr := svg_decode(`<svg xmlns="http://www.w3.org/2000/svg" width="60" height="30"><text x="2" y="25" font-family="Arial" font-size="28" fill="black">Wg</text></svg>`)
	defer image_destroy(text)
	testing.expect_value(t, terr, Error.None)
	if text != nil {
		inked := 0
		for i := 3; i < len(text.frames[0].pixels); i += 4 { if text.frames[0].pixels[i] > 128 { inked += 1 } }
		testing.expectf(t, inked > 60, "text drawn (%d pixels)", inked)
	}
	// no size and no viewBox: 300 x 150, CSS's default object size
	d, dinfo, _ := svg_decode(`<svg xmlns="http://www.w3.org/2000/svg"><rect width="5" height="5"/></svg>`)
	defer image_destroy(d)
	testing.expect(t, dinfo.width == 300 && dinfo.height == 150 && dinfo.svg.ratio == 0, "default size")
	// the file on disk
	file, _, ferr := decode_media(t, "shapes.svg")
	defer image_destroy(file)
	testing.expect(t, ferr == .None && file != nil, "shapes.svg")
}

@(test)
svg_hostile :: proc(t: ^testing.T) {
	// billion laughs: refused by roxmltree's reference limits or by the expansion bound
	lol := `<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;"><!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;"><!ENTITY e "&d;&d;&d;&d;&d;&d;&d;&d;&d;&d;"><!ENTITY f "&e;&e;&e;&e;&e;&e;&e;&e;&e;&e;"><!ENTITY g "&f;&f;&f;&f;&f;&f;&f;&f;&f;&f;"><!ENTITY h "&g;&g;&g;&g;&g;&g;&g;&g;&g;&g;">]><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><text>&h;&h;&h;&h;</text></svg>`
	_, _, e1 := svg_decode(lol)
	testing.expect_value(t, e1, Error.Too_Complex)
	// quadratic blow-up: one large entity referenced many times
	qb := strings.builder_make(context.temp_allocator)
	strings.write_string(&qb, `<!DOCTYPE svg [<!ENTITY x "`)
	for _ in 0 ..< 20_000 { strings.write_byte(&qb, 'x') }
	strings.write_string(&qb, `">]><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><desc>`)
	for _ in 0 ..< 5_000 { strings.write_string(&qb, "&x;") }
	strings.write_string(&qb, `</desc></svg>`)
	_, _, e2 := svg_decode(strings.to_string(qb))
	testing.expect_value(t, e2, Error.Too_Complex)
	// legitimate entities (Illustrator's namespaces) still work
	ai := `<!DOCTYPE svg [<!ENTITY ns_svg "http://www.w3.org/2000/svg">]><svg xmlns="&ns_svg;" width="4" height="4"><rect width="4" height="4" fill="red"/></svg>`
	aimg, _, e3 := svg_decode(ai)
	defer image_destroy(aimg)
	testing.expect(t, e3 == .None && aimg != nil && px(aimg, 0, 1, 1) == RED, "entities within bounds")
	// exponential <use>: 10 levels of 10 references = 10^10 shapes from a few hundred bytes
	ub := strings.builder_make(context.temp_allocator)
	strings.write_string(&ub, `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10"><defs><rect id="u0" width="1" height="1"/>`)
	for i in 1 ..= 10 {
		fmt.sbprintf(&ub, `<g id="u%d">`, i)
		for _ in 0 ..< 10 { fmt.sbprintf(&ub, `<use xlink:href="#u%d"/>`, i - 1) }
		strings.write_string(&ub, `</g>`)
	}
	strings.write_string(&ub, `</defs><use xlink:href="#u10"/></svg>`)
	// refused by counting (images.svg limits) before drawing: drawing 10^10 shapes would not return
	_, _, e4 := svg_decode(strings.to_string(ub))
	testing.expect_value(t, e4, Error.Too_Complex)
	// extreme depth: refused before any recursion
	db := strings.builder_make(context.temp_allocator)
	strings.write_string(&db, `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">`)
	for _ in 0 ..< 100_000 { strings.write_string(&db, "<g>") }
	for _ in 0 ..< 100_000 { strings.write_string(&db, "</g>") }
	strings.write_string(&db, `</svg>`)
	_, _, e5 := svg_decode(strings.to_string(db))
	testing.expect_value(t, e5, Error.Too_Complex)
	// external references are never loaded (and do not stop the rest from drawing); data: images are
	ext := `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10"><image href="file:///C:/Windows/win.ini" width="10" height="10"/><image xlink:href="http://127.0.0.1:1/x.png" width="10" height="10"/><rect width="5" height="5" fill="blue"/><image x="5" y="5" width="5" height="5" href="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="/></svg>`
	eimg, _, e6 := svg_decode(ext)
	defer image_destroy(eimg)
	testing.expect(t, e6 == .None && eimg != nil && px(eimg, 0, 2, 2) == BLUE && px(eimg, 0, 8, 2)[3] == 0, "external images skipped")
	testing.expect(t, eimg != nil && px(eimg, 0, 7, 7)[3] == 255, "data: image drawn")
	// a data: PNG bomb inside an SVG is refused from its header
	bomb_doc := `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><image width="10" height="10" href="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgABhqAAAYagCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="/><rect width="2" height="2" fill="red"/></svg>`
	bimg, _, e7 := svg_decode(bomb_doc)
	defer image_destroy(bimg)
	testing.expect(t, e7 == .None && bimg != nil && px(bimg, 0, 1, 1) == RED, "the bomb is skipped, the rest drawn")
	// truncated, not SVG, gzip without Content-Encoding, render cost over the limit
	_, _, e8 := svg_decode(`<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" heig`)
	testing.expect_value(t, e8, Error.Corrupt)
	_, _, e9 := svg_decode(`<svg width="10" height="10"><rect width="10" height="10"/></svg>`)   // no namespace: not an SVG document
	testing.expect_value(t, e9, Error.Corrupt)
	_, _, e10 := decode_now(transmute([]byte)string("\x1f\x8b\x08\x00\x00\x00\x00\x00"), Decode_Options{limits = LIMITS_DEFAULT, mime = "image/svg+xml"})
	testing.expect_value(t, e10, Error.Unsupported_Format)
	cheap := LIMITS_DEFAULT
	cheap.svg.max_render_cost = 1 << 20
	_, _, e11 := svg_decode(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><filter id="f"><feGaussianBlur stdDeviation="3"/></filter><rect width="10" height="10" filter="url(#f)"/></svg>`, 4000, 4000, cheap)
	testing.expect_value(t, e11, Error.Too_Complex)
	// too many nodes
	few := LIMITS_DEFAULT
	few.svg.max_nodes = 50
	nb := strings.builder_make(context.temp_allocator)
	strings.write_string(&nb, `<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">`)
	for _ in 0 ..< 100 { strings.write_string(&nb, `<rect width="1" height="1"/>`) }
	strings.write_string(&nb, `</svg>`)
	_, _, e12 := svg_decode(strings.to_string(nb), limits = few)
	testing.expect_value(t, e12, Error.Too_Complex)
	// SVG disabled
	off := LIMITS_DEFAULT
	off.svg.enabled = false
	_, _, e13 := svg_decode(`<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>`, limits = off)
	testing.expect_value(t, e13, Error.Unsupported_Format)
}

@(test)
raster_hostile :: proc(t: ^testing.T) {
	// truncated AVIF / WebP: an error, no crash
	for name in ([]string{"quad8a.avif", "anim.avif", "quad-lossy.webp", "anim.webp"}) {
		data := media(t, name)
		defer delete(data)
		for cut in ([]int{len(data) / 2, len(data) - 7, 40}) {
			img, _, err := decode_now(data[:cut], Decode_Options{limits = LIMITS_DEFAULT})
			image_destroy(img)
			testing.expectf(t, err != .None || img != nil, "%s cut at %d: %v", name, cut, err)
		}
		// garbage after the signature
		junk := make([]byte, len(data))
		defer delete(junk)
		copy(junk, data[:32])
		for i in 32 ..< len(junk) { junk[i] = u8(i * 7) }
		img, _, _ := decode_now(junk, Decode_Options{limits = LIMITS_DEFAULT})
		image_destroy(img)
	}
	// dimension bombs from the headers, before any allocation
	small := LIMITS_DEFAULT
	small.max_dimension = 16
	_, _, e1 := decode_media(t, "quad8a.avif", Decode_Options{limits = small})
	testing.expect_value(t, e1, Error.Too_Large_Dimension)
	_, _, e2 := decode_media(t, "quad-lossy.webp", Decode_Options{limits = small})
	testing.expect_value(t, e2, Error.Too_Large_Dimension)
	px_limit := LIMITS_DEFAULT
	px_limit.max_pixels = 100
	_, _, e3 := decode_media(t, "quad10a.avif", Decode_Options{limits = px_limit})
	testing.expect_value(t, e3, Error.Too_Many_Pixels)
	frames := LIMITS_DEFAULT
	frames.max_frames = 2
	_, _, e4 := decode_media(t, "anim.webp", Decode_Options{limits = frames})
	testing.expect_value(t, e4, Error.Too_Many_Frames)
	_, _, e5 := decode_media(t, "anim.avif", Decode_Options{limits = frames})
	testing.expect_value(t, e5, Error.Too_Many_Frames)
	// a VP8X header announcing 16384 x 16384: refused by the header check
	vp8x := []u8{'R', 'I', 'F', 'F', 30, 0, 0, 0, 'W', 'E', 'B', 'P', 'V', 'P', '8', 'X', 10, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0x3F, 0, 0xFF, 0x3F, 0}
	_, _, e6 := decode_now(vp8x, Decode_Options{limits = LIMITS_DEFAULT})
	testing.expect_value(t, e6, Error.Too_Many_Pixels)
}
