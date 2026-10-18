package images

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "wb:host"

// The files come from `testserver -gen-images examples/site/images` (tools/testserver/images.go); run from the
// repository root.

@(private = "file")
read :: proc(t: ^testing.T, name: string) -> []byte {
	data, err := os.read_entire_file(fmt.tprintf("examples/site/images/%s", name), context.allocator)
	testing.expectf(t, err == nil, "read %s", name)
	return data
}

@(private = "file")
opts :: proc() -> Decode_Options { return Decode_Options{limits = LIMITS_DEFAULT, downscale_below = 0.5} }

@(private = "file")
pixel :: proc(img: ^Image, frame, x, y: int) -> [4]u8 {
	p := img.frames[frame].pixels[y * img.stride + x * 4:]
	return {p[0], p[1], p[2], p[3]}
}

@(private = "file")
near :: proc(a, b: [4]u8, tol: int) -> bool {
	for i in 0 ..< 4 { if abs(int(a[i]) - int(b[i])) > tol { return false } }
	return true
}

@(private = "file")
decode_file :: proc(t: ^testing.T, name: string, o := Decode_Options{}) -> (^Image, Info, Error) {
	data := read(t, name)
	defer delete(data)
	op := o
	if op.limits.max_pixels == 0 { op.limits = LIMITS_DEFAULT }
	return decode_now(data, op)
}

@(test)
sniffing :: proc(t: ^testing.T) {
	testing.expect_value(t, sniff_signature(transmute([]byte)string("\x89PNG\r\n\x1a\n....")), Format.Png)
	testing.expect_value(t, sniff_signature(transmute([]byte)string("\xff\xd8\xff\xe0")), Format.Jpeg)
	testing.expect_value(t, sniff_signature(transmute([]byte)string("GIF89a..")), Format.Gif)
	testing.expect_value(t, sniff_signature(transmute([]byte)string("BM......")), Format.Bmp)
	testing.expect_value(t, sniff_signature(transmute([]byte)string("\x00\x00\x01\x00..")), Format.Ico)
	testing.expect_value(t, sniff_signature(transmute([]byte)string("RIFF\x00\x00\x00\x00WEBPVP8 ")), Format.Webp)
	testing.expect_value(t, sniff_signature(transmute([]byte)string("\x00\x00\x00\x1cftypavif\x00\x00\x00\x00avifmif1")), Format.Avif)
	testing.expect_value(t, sniff_signature(transmute([]byte)string("\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic")), Format.Heif)
	testing.expect_value(t, sniff_signature(transmute([]byte)string("\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00isommp42")), Format.Unknown)
	testing.expect_value(t, sniff(transmute([]byte)string("<svg xmlns='x'/>")), Format.Svg)
	testing.expect_value(t, sniff(transmute([]byte)string("\x89PNG\r\n\x1a\n"), "image/svg+xml"), Format.Svg)
	// the content decides, not the label; nosniff refuses a type that is not an image
	testing.expect_value(t, sniff(transmute([]byte)string("\x89PNG\r\n\x1a\n"), "image/jpeg"), Format.Png)
	testing.expect_value(t, sniff(transmute([]byte)string("\x89PNG\r\n\x1a\n"), "text/plain"), Format.Png)
	testing.expect_value(t, sniff(transmute([]byte)string("\x89PNG\r\n\x1a\n"), "text/plain", true), Format.Unknown)
	testing.expect_value(t, sniff(transmute([]byte)string("\x89PNG\r\n\x1a\n"), "image/gif", true), Format.Png)
}

@(test)
still_formats :: proc(t: ^testing.T) {
	Case :: struct { name: string, format: Format, w, h: int, color: [4]u8, tol: int }
	cases := []Case{
		{"red.png", .Png, 8, 6, {255, 0, 0, 255}, 0},
		{"alpha.png", .Png, 4, 4, {0, 0, 255, 128}, 0},       // straight alpha: the colour is not premultiplied
		{"green.jpg", .Jpeg, 16, 8, {0, 255, 0, 255}, 8},
		{"blue.bmp", .Bmp, 5, 3, {0, 0, 255, 255}, 0},
		{"still.gif", .Gif, 4, 4, {255, 255, 0, 255}, 0},
		{"magenta.tif", .Tiff, 3, 2, {255, 0, 255, 255}, 0},
	}
	for c in cases {
		img, info, err := decode_file(t, c.name)
		defer image_destroy(img)
		testing.expectf(t, err == .None, "%s: %v", c.name, err)
		if err != .None { continue }
		testing.expectf(t, info.format == c.format, "%s: format %v", c.name, info.format)
		testing.expectf(t, img.width == c.w && img.height == c.h && info.width == c.w && info.height == c.h, "%s: %dx%d", c.name, img.width, img.height)
		testing.expectf(t, img.stride == c.w * 4 && len(img.frames) == 1 && len(img.frames[0].pixels) == c.w * c.h * 4, "%s: layout", c.name)
		for y in 0 ..< c.h {
			for x in 0 ..< c.w {
				if !near(pixel(img, 0, x, y), c.color, c.tol) {
					testing.expectf(t, false, "%s: pixel %d,%d is %v, want %v", c.name, x, y, pixel(img, 0, x, y), c.color)
					break
				}
			}
		}
	}
}

@(test)
jpeg_orientation :: proc(t: ^testing.T) {
	img, info, err := decode_file(t, "orient6.jpg")
	defer image_destroy(img)
	testing.expect_value(t, err, Error.None)
	if err != .None { return }
	testing.expect_value(t, info.orientation, u8(6))
	testing.expect(t, info.width == 10 && info.height == 20, "natural size is upright (10 x 20)")
	testing.expect(t, img.width == 10 && img.height == 20, "pixels are upright")
	testing.expect(t, near(pixel(img, 0, 5, 2), {255, 0, 0, 255}, 40), "red on top after the 90 degree turn")
	testing.expect(t, near(pixel(img, 0, 5, 17), {0, 0, 255, 255}, 40), "blue at the bottom")
	data := read(t, "orient6.jpg")
	defer delete(data)
	pi, perr := probe_now(data, opts())
	testing.expect(t, perr == .None && pi.width == 10 && pi.height == 20, "the probe already knows the upright size")
}

@(test)
icon_sizes :: proc(t: ^testing.T) {
	img, info, err := decode_file(t, "icon.ico")
	defer image_destroy(img)
	testing.expect_value(t, err, Error.None)
	if err != .None { return }
	testing.expect_value(t, info.frames, 2)
	testing.expect(t, img.width == 32 && near(pixel(img, 0, 3, 3), {0, 0, 255, 255}, 0), "the largest icon by default")
	small, _, serr := decode_file(t, "icon.ico", Decode_Options{limits = LIMITS_DEFAULT, target_w = 16, target_h = 16})
	defer image_destroy(small)
	testing.expect(t, serr == .None && small.width == 16 && near(pixel(small, 0, 3, 3), {255, 0, 0, 255}, 0), "the size that fits a 16 px target")
}

@(test)
animated_gif :: proc(t: ^testing.T) {
	img, info, err := decode_file(t, "anim.gif")
	defer image_destroy(img)
	testing.expect_value(t, err, Error.None)
	if err != .None { return }
	testing.expect(t, info.animated && info.frames == 3 && len(img.frames) == 3, "three frames")
	testing.expect(t, img.width == 10 && img.height == 10, "logical screen size")
	testing.expect_value(t, info.plays, 3)   // loop count 2: shown three times
	testing.expect(t, img.frames[0].delay_ms == 100 && img.frames[1].delay_ms == 200 && img.frames[2].delay_ms == 300, "delays")
	testing.expect_value(t, img.duration_ms, 600)
	RED :: [4]u8{255, 0, 0, 255}
	BLUE :: [4]u8{0, 0, 255, 255}
	GREEN :: [4]u8{0, 255, 0, 255}
	testing.expect(t, pixel(img, 0, 2, 2) == RED && pixel(img, 0, 8, 8) == RED, "frame 0: red")
	testing.expect(t, pixel(img, 1, 2, 2) == BLUE && pixel(img, 1, 8, 8) == RED, "frame 1: blue square over the kept red")
	testing.expect(t, pixel(img, 2, 2, 2)[3] == 0, "frame 2: the blue square was restored to the (transparent) background")
	testing.expect(t, pixel(img, 2, 8, 8) == GREEN && pixel(img, 2, 8, 2) == RED, "frame 2: green square, red elsewhere")

	// timing: frame at a time, next deadline, end after the last play
	i, next := animation_frame_at(img, 0)
	testing.expect(t, i == 0 && next == 100, "t=0")
	i, next = animation_frame_at(img, 150)
	testing.expect(t, i == 1 && next == 300, "t=150")
	i, next = animation_frame_at(img, 650)
	testing.expect(t, i == 0 && next == 700, "second play")
	i, next = animation_frame_at(img, 1800)
	testing.expect(t, i == 2 && next < 0, "after three plays: the last frame stays, nothing more to wake for")

	first, _, ferr := decode_file(t, "anim.gif", Decode_Options{limits = LIMITS_DEFAULT, first_frame_only = true})
	defer image_destroy(first)
	testing.expect(t, ferr == .None && len(first.frames) == 1 && !first.info.animated, "first frame only")
}

@(test)
disposal_previous :: proc(t: ^testing.T) {
	c: Composer
	composer_init(&c, 2, 1)
	defer composer_destroy(&c)
	red := []u8{255, 0, 0, 255, 255, 0, 0, 255}
	blue := []u8{0, 0, 255, 255}
	composer_add(&c, Raw_Frame{x = 0, y = 0, w = 2, h = 1, pixels = red, disposal = .Keep})
	composer_add(&c, Raw_Frame{x = 1, y = 0, w = 1, h = 1, pixels = blue, disposal = .Previous})
	testing.expect(t, c.canvas[4] == 0 && c.canvas[6] == 255, "blue drawn")
	composer_add(&c, Raw_Frame{x = 0, y = 0, w = 1, h = 1, pixels = []u8{0, 0, 0, 0}, disposal = .Keep})
	testing.expect(t, c.canvas[4] == 255 && c.canvas[6] == 0, "the frame under disposal 3 is undone")
	testing.expect(t, c.canvas[0] == 255, "transparent pixels leave the canvas as it is")
	plays, ok := plays_from_loop_extension([]u8{3, 1, 0, 0})
	testing.expect(t, ok && plays == 0, "loop count 0 = forever")
}

@(test)
hostile_files :: proc(t: ^testing.T) {
	_, _, e1 := decode_file(t, "bomb.png")
	testing.expect_value(t, e1, Error.Too_Large_Dimension)
	big := LIMITS_DEFAULT
	big.max_dimension = 1 << 20
	_, _, e2 := decode_file(t, "bomb.png", Decode_Options{limits = big})
	testing.expect_value(t, e2, Error.Too_Many_Pixels)   // 10 G pixels, refused from the header
	_, _, e3 := decode_file(t, "bomb.gif", Decode_Options{limits = big})
	testing.expect_value(t, e3, Error.Too_Many_Pixels)
	_, _, e4 := decode_file(t, "truncated.png")
	testing.expect_value(t, e4, Error.Corrupt)
	_, _, e5 := decode_file(t, "fake.png")
	testing.expect_value(t, e5, Error.Unknown_Format)
	_, _, e6 := decode_file(t, "text.png")
	testing.expect_value(t, e6, Error.Unknown_Format)
	_, _, e7 := decode_file(t, "drawing.svg")
	testing.expect_value(t, e7, Error.Unsupported_Format)
	small := LIMITS_DEFAULT
	small.max_encoded_bytes = 100
	_, _, e8 := decode_file(t, "noise.png", Decode_Options{limits = small})
	testing.expect_value(t, e8, Error.Too_Many_Bytes)
	frames := LIMITS_DEFAULT
	frames.max_frames = 2
	_, _, e9 := decode_file(t, "anim.gif", Decode_Options{limits = frames})
	testing.expect_value(t, e9, Error.Too_Many_Frames)
	mem := LIMITS_DEFAULT
	mem.max_image_bytes = 10 * 10 * 4 * 2
	_, _, e10 := decode_file(t, "anim.gif", Decode_Options{limits = mem})
	testing.expect_value(t, e10, Error.Too_Much_Memory)
	_, _, e11 := decode_now(nil, opts())
	testing.expect_value(t, e11, Error.Empty)
	// a WebP decodes where the Windows codec is installed, and fails cleanly where it is not
	wimg, winfo, we := decode_file(t, "pixel.webp")
	defer image_destroy(wimg)
	testing.expect(t, (we == .None && winfo.width == 1) || we == .Codec_Missing, "WebP: decoded, or Codec_Missing")
}

@(test)
reduced_decode :: proc(t: ^testing.T) {
	img, info, err := decode_file(t, "noise.png", Decode_Options{limits = LIMITS_DEFAULT, target_w = 16, target_h = 16, downscale_below = 0.5})
	defer image_destroy(img)
	testing.expect_value(t, err, Error.None)
	if err != .None { return }
	testing.expect(t, info.width == 64 && img.width == 16 && img.height == 16 && img.reduced, "decoded at the shown size, natural size kept")
	full, _, _ := decode_file(t, "noise.png", Decode_Options{limits = LIMITS_DEFAULT, target_w = 48, target_h = 48, downscale_below = 0.5})
	defer image_destroy(full)
	testing.expect(t, full != nil && full.width == 64 && !full.reduced, "not reduced when close to the natural size")
	w, h, r := reduced_size(1000, 500, 100, 100, 0.5)
	testing.expect(t, r && w == 200 && h == 100, "aspect ratio kept, covering the target")
	turned, tw, th := apply_orientation([]u8{1, 0, 0, 0, 2, 0, 0, 0}, 2, 1, 8)
	defer delete(turned)
	testing.expect(t, tw == 1 && th == 2 && turned[0] == 2 && turned[4] == 1, "orientation 8: 90 degrees counter-clockwise")
}

@(private = "file")
Pool_Test :: struct { done: [dynamic]^Job, order: [dynamic]u64 }

@(test)
decoding_threads :: proc(t: ^testing.T) {
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	decoder_start(1)
	defer decoder_stop()
	st: Pool_Test
	defer { for j in st.done { job_free(j) }; delete(st.done); delete(st.order) }
	port := port_open(&loop, proc(user: rawptr, j: ^Job) {
		s := (^Pool_Test)(user)
		append(&s.done, j)
		append(&s.order, j.tag)
	}, &st)
	testing.expect(t, port != 0, "port")
	blob := blob_make(read(t, "anim.gif"))
	defer blob_release(blob)
	// one thread: the first job may already run; the rest go by priority
	for i in 0 ..< 6 { submit(port, job_make(.Decode, blob, opts(), priority = i32(i), tag = u64(i))) }
	cancelled := job_make(.Decode, blob, opts(), priority = -5, tag = 99)
	submit(port, cancelled)
	job_cancel(cancelled)
	start := time.tick_now()
	for len(st.done) < 6 && time.duration_seconds(time.tick_since(start)) < 10 { host.loop_wait(&loop, 20) }
	testing.expect_value(t, len(st.done), 6)
	for j in st.done { testing.expect(t, j.err == .None && j.image != nil && len(j.image.frames) == 3, "decoded on a thread") }
	if len(st.order) == 6 {
		testing.expect(t, st.order[1] == 5 && st.order[2] == 4 && st.order[5] == 1 || st.order[0] == 5, fmt.tprintf("highest priority first (%v)", st.order))
	}
	// a closed port gets nothing more, and its pending jobs are freed
	for i in 0 ..< 4 { submit(port, job_make(.Probe, blob, opts(), tag = u64(10 + i))) }
	port_close(port)
	n := len(st.done)
	for _ in 0 ..< 10 { host.loop_wait(&loop, 10) }
	testing.expect_value(t, len(st.done), n)
	testing.expect(t, !submit(port, job_make(.Probe, blob, opts())), "submitting to a closed port fails (and frees the job)")
}
