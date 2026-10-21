// Headless end-to-end test of the built-in image decoders in pages (examples/site/media.html): AVIF and WebP in <img>
// (natural sizes, orientation, animation), <picture> choosing AVIF by its type, the Accept header of image requests and
// content negotiation on it, SVG as <img> (natural size, ratio only, rasters at each size shown), as a CSS background,
// and inline <svg> (currentColor, <use> into a sprite elsewhere in the page). Needs build\testserver.exe running; from
// the repository root:   mediatest.exe
package mediatest

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:images"
import "wb:net"
import "wb:page"
import "wb:tools/testenv"

failures: int

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

console :: proc(user: rawptr, level: page.Log_Level, message: string) {
	if level != .Log { fmt.printf("  [%v] %s\n", level, message) }
}

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings
process:  ^base.Scope
cur:      ^page.Page

SITE :: "http://127.0.0.1:8765"   // on the run's block of ports through testenv.url

turn :: proc() {
	host.loop_wait(&loop, 5)
	host.run_ready(&loop)
	if cur != nil && !cur.closed {
		page.styles(cur, 1024, 768, 1)
		page.images_sync(cur)
	}
	free_all(context.temp_allocator)
}

pump_until :: proc(what: string, cond: proc() -> bool, seconds := 15.0) -> bool {
	start := time.tick_now()
	for !cond() {
		if time.duration_seconds(time.tick_since(start)) > seconds { fmt.printf("  timeout waiting for %s\n", what); return false }
		turn()
	}
	return true
}

node :: proc(id: string) -> base.Handle { return dom.find_by_id(cur.doc, id) }

Get :: struct { done: bool, body: [dynamic]byte }
http_get :: proc(u: string) -> string {
	g := new(Get, context.temp_allocator)
	fetch.start(&loader, {
		request = {url = u, mode = .Cors, credentials = .Omit},
		on_event = proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
			g := (^Get)(user)
			#partial switch ev.kind {
			case .Done: append(&g.body, ..ev.data); g.done = true
			case .Failed: g.done = true
			}
		}, user = g, collect = true,
	})
	start := time.tick_now()
	for !g.done && time.duration_seconds(time.tick_since(start)) < 10 { host.loop_wait(&loop, 5) }
	s := strings.clone(string(g.body[:]), context.temp_allocator)
	delete(g.body)
	return s
}

// Pixels of entry `id` drawn w x h, waiting for the decoding threads.
pixels :: proc(id: u64, w, h: int) -> page.Frame_Pixels {
	fp: page.Frame_Pixels
	now := f64(host.now_ns(&loop)) / 1e6
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < 10 {
		page.images_paint_begin()
		fp = page.frame_pixels(id, now, w, h, 1000)
		if fp.ok && fp.width == w && fp.height == h { return fp }
		if fp.ok && w == 0 { return fp }
		turn()
	}
	return fp
}

px :: proc(fp: page.Frame_Pixels, x, y: int) -> [4]u8 {
	if !fp.ok || x >= fp.width || y >= fp.height { return {} }
	p := fp.pixels[y * fp.stride + x * 4:]
	return {p[0], p[1], p[2], p[3]}
}

near :: proc(a, b: [4]u8, tol: int) -> bool {
	for i in 0 ..< 4 { if abs(int(a[i]) - int(b[i])) > tol { return false } }
	return true
}

READY_IDS := [?]string{"avif8", "avif10", "avif444", "rot90", "mirror", "transverse", "p3", "avifanim", "webplossy", "webplossless",
	"webpalpha", "webpanim", "adobe", "pic", "neg", "svg1", "svg3", "svgratio"}

main :: proc() {
	context = testenv.context_of_process()
	html, herr := os.read_entire_file("examples/site/media.html", context.allocator)
	if herr != nil { fmt.eprintln("cannot read examples/site/media.html"); os.exit(2) }
	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }
	process = base.scope_make("process")

	fmt.println("-- the page")
	p := page.page_create(&loop, &loader, &settings, process, testenv.url(SITE + "/site/media.html"), console)
	page.load_html(p, html)
	cur = p
	pump_until("every image", proc() -> bool {
		for id in READY_IDS { if page.image_view(cur, node(id)).state == .Loading || page.image_view(cur, node(id)).state == .None { return false } }
		return true
	})
	for id in READY_IDS {
		v := page.image_view(p, node(id))
		check(v.state == .Ready, fmt.tprintf("#%s ready (%v %s)", id, v.state, v.error))
	}

	fmt.println("-- AVIF, WebP")
	Size :: struct { id: string, w, h: f32 }
	sizes := []Size{{"avif8", 32, 16}, {"avif10", 32, 16}, {"rot90", 16, 32}, {"transverse", 16, 32}, {"mirror", 32, 16}, {"avifanim", 10, 10},
		{"webplossy", 32, 16}, {"webpanim", 10, 10}, {"pic", 32, 16}, {"neg", 32, 16}}
	for s in sizes {
		v := page.image_view(p, node(s.id))
		check(v.natural == {s.w, s.h}, fmt.tprintf("#%s natural size %v (want %vx%v)", s.id, v.natural, s.w, s.h))
	}
	check(page.image_view(p, node("avifanim")).animated && page.image_view(p, node("webpanim")).animated, "AVIF and WebP animations")
	r := pixels(page.image_view(p, node("rot90")).id, 16, 32)
	check(near(px(r, 2, 2), {0, 0, 255, 255}, 8) && near(px(r, 13, 29), {0, 255, 0, 255}, 8), "irot applied (blue top left, lime bottom right)")
	a := pixels(page.image_view(p, node("avif8")).id, 32, 16)
	check(near(px(a, 27, 12), {255, 255, 255, 128}, 8), fmt.tprintf("AVIF alpha (%v)", px(a, 27, 12)))
	accept := http_get(testenv.url(SITE + "/media/accept?name=quad8a.avif"))
	check(strings.has_prefix(accept, "image/avif,image/webp,image/svg+xml"), fmt.tprintf("Accept of image requests: %q", accept))
	check(page.image_view(p, node("neg")).natural == {32, 16}, "content negotiation on Accept: the server sent AVIF")
	check(page.image_view(p, node("pic")).natural == {32, 16}, "<picture>: the image/avif source is chosen")

	fmt.println("-- SVG images")
	v1 := page.image_view(p, node("svg1"))
	check(v1.svg && v1.natural == {120, 60} && v1.has_size == {true, true}, fmt.tprintf("shapes.svg: natural 120 x 60 (%v)", v1.natural))
	vr := page.image_view(p, node("svgratio"))
	check(vr.svg && vr.ratio_only && abs(vr.ratio - 4) < 0.001, fmt.tprintf("ratio.svg: a ratio (4) and no size (%v %v)", vr.ratio_only, vr.ratio))
	s1 := pixels(v1.id, 120, 60)
	s3 := pixels(v1.id, 360, 180)
	check(s1.ok && s3.ok && s1.texture != s3.texture, "rasterised at each size shown: two rasters, two textures")
	check(near(px(s3, 270, 30), {42, 170, 42, 255}, 30) || px(s3, 270, 6)[3] > 200, "the 3x raster is drawn at 360 x 180 (ring)")
	edge := px(s3, 270, 5)[3]   // a pixel on the ring's antialiased outer edge: partly covered at 3x, not a blurred 1x
	fmt.printf("  ring edge alpha at 3x: %d\n", edge)
	again := pixels(v1.id, 120, 60)
	check(again.texture == s1.texture, "the first size is still cached")
	bg := page.css_image_view(p, "/media/f/pattern.svg")
	check(bg.state == .Ready && bg.svg && bg.natural == {40, 40}, fmt.tprintf("SVG background image (%v %v)", bg.state, bg.natural))
	bgp := pixels(bg.id, 24, 24)
	check(bgp.ok && bgp.width == 24, "background tile rendered at its size")
	ext := page.css_image_view(p, "/media/f/external.svg")
	check(ext.state == .Ready && ext.ratio_only, fmt.tprintf("::after background external.svg (%v)", ext.state))

	fmt.println("-- inline <svg>")
	inline :: proc(id: string, w, h: f32) -> page.Frame_Pixels {
		v: page.Image_View
		start := time.tick_now()
		for time.duration_seconds(time.tick_since(start)) < 10 {
			v = page.inline_svg_view(cur, node(id), w, h)
			if v.state == .Ready { break }
			turn()
		}
		if v.state != .Ready { return {} }
		return pixels(v.id, int(w), int(h))
	}
	i5 := inline("inl5", 32, 32)
	check(i5.ok && px(i5, 16, 16) == {0, 255, 0, 255}, fmt.tprintf("currentColor from the element's color (%v)", px(i5, 16, 16)))
	// color="currentColor" or style="color:currentColor" on the <svg> itself: the parent's color (DuckDuckGo's icons), not black
	i6 := inline("inl6", 32, 32)
	check(i6.ok && px(i6, 16, 16) == {0, 0, 255, 255}, fmt.tprintf("<svg color=currentColor>: the parent's color (%v)", px(i6, 16, 16)))
	i7 := inline("inl7", 32, 32)
	check(i7.ok && px(i7, 16, 16) == {0, 0, 255, 255}, fmt.tprintf("<svg style=color:currentColor>: the parent's color (%v)", px(i7, 16, 16)))
	i8 := inline("inl8", 32, 32)
	check(i8.ok && px(i8, 16, 16) == {255, 0, 0, 255}, fmt.tprintf("<svg color=#ff0000>: its own color (%v)", px(i8, 16, 16)))
	i1 := inline("inl1", 32, 32)
	check(i1.ok && near(px(i1, 16, 14), {0x15, 0x65, 0xc0, 255}, 4), fmt.tprintf("<use href=#i-star> into a hidden sprite, currentColor from the parent (%v)", px(i1, 16, 14)))
	i2 := inline("inl2", 32, 32)
	check(i2.ok && near(px(i2, 16, 20), {0xc6, 0x28, 0x28, 255}, 4), fmt.tprintf("another symbol, another color (%v)", px(i2, 16, 20)))
	i3 := inline("inl3", 32, 32)
	check(i3.ok && near(px(i3, 16, 14), {0x2e, 0x7d, 0x32, 255}, 4), "xlink:href")
	i4 := inline("inl4", 140, 32)
	check(i4.ok && px(i4, 3, 16)[3] == 255 && px(i4, 3, 16)[0] > 200, "gradient, width / height attributes, no viewBox")
	w, h, ok := page.inline_svg_intrinsic(p, node("inl4"))
	check(ok && w == 140 && h == 32, "inline <svg> natural size from its attributes")
	_, _, rok := page.inline_svg_intrinsic(p, node("inl1"))
	check(!rok && page.inline_svg_ratio(p, node("inl1")) == 1, "viewBox only: a ratio for the layout")
	// a mutation changes the picture
	rect := dom.get(p.doc, node("inl5")).first_child
	dom.set_attribute(p.doc, rect, "fill", "#ff0000")
	dom.touch(p.doc)
	turn()
	i5b := inline("inl5", 32, 32)
	check(i5b.ok && px(i5b, 16, 16) == {255, 0, 0, 255}, fmt.tprintf("drawn again after a mutation (%v)", px(i5b, 16, 16)))
	st := page.images_stats(p)
	fmt.printf("  cache: %d entries, %d KiB; decoder: %d jobs, %.1f ms busy, longest %.1f ms\n", st.entries, st.bytes >> 10, st.decoder.jobs, st.decoder.busy_ms, st.decoder.longest_ms)

	page.page_close(p)
	cur = nil
	for _ in 0 ..< 10 { turn() }
	base.scope_close(process)
	page.images_shutdown()
	check(!images.decoder_running(), "decoding threads stopped")
	host.blocking_settle(&blocking)
	page.process_shutdown()
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	host.loop_destroy(&loop)
	page.settings_destroy(&settings)
	delete(html)
	failures += testenv.mem_check("mediatest")
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures)
}
