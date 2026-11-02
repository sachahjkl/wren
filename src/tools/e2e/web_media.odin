#+private file
// The built-in image decoders in pages (examples/site/media.html): AVIF and WebP in <img> (natural sizes, orientation, animation),
// <picture> choosing AVIF by its type, the Accept header of image requests and content negotiation on it, SVG as <img> (natural size,
// ratio only, rasters at each size shown), as a CSS background, and inline <svg> (currentColor, <use> into a sprite elsewhere in the page).
//
// The process's image cache would answer for what a test wants to see downloaded: each test starts and ends without it.
package e2e_scenarios

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:images"
import "wb:page"
import "wb:tools/testenv"

FIXTURE :: "examples/site/media.html"
ORIGIN :: "http://127.0.0.1:8765"
VIEW_W :: 1024
VIEW_H :: 768
DECODE_PRIORITY :: 1000
COLOR_TOLERANCE :: 8
GRADIENT_TOLERANCE :: 4
RING_TOLERANCE :: 30
RATIO_TOLERANCE :: 0.001
ICON :: 32                     // the page's inline icons, in px
ICON_MIDDLE :: 16
GRADIENT_W :: 140

READY_IDS := [?]string{"avif8", "avif10", "avif444", "rot90", "mirror", "transverse", "p3", "avifanim", "webplossy", "webplossless",
	"webpalpha", "webpanim", "adobe", "pic", "neg", "svg1", "svg3", "svgratio"}

turn :: proc(pr: ^Probe) {
	page.styles(pr.p, VIEW_W, VIEW_H, 1)
	page.images_sync(pr.p)
}

node :: proc(pr: ^Probe, id: string) -> base.Handle { return dom.find_by_id(pr.p.doc, id) }

view :: proc(pr: ^Probe, id: string) -> page.Image_View { return page.image_view(pr.p, node(pr, id)) }

// The page, every image of it having arrived, well or not.
open :: proc(t: ^testing.T) -> ^Probe {
	page.images_shutdown()   // (what another test left is not what this one downloads)
	html, err := os.read_entire_file(FIXTURE, context.temp_allocator)
	testing.expect(t, err == nil, "the page is there: " + FIXTURE)
	pr := open_page(t, "media", string(html), testenv.url(ORIGIN + "/site/media.html"))
	wait_until(t, "every image", pr, proc(pr: ^Probe) -> bool {
		turn(pr)
		for id in READY_IDS {
			st := view(pr, id).state
			if st == .Loading || st == .None { return false }
		}
		return true
	})
	return pr
}

// Every page closed: nothing of the cache stays, and the threads that fed it stop.
shut :: proc(pr: ^Probe, min_checks: int, loc := #caller_location) {
	t := pr.t
	close_page(pr, min_checks = min_checks, loc = loc)
	page.images_shutdown()
	testing.expect(t, !images.decoder_running(), "decoding threads stopped", loc = loc)
}

Get :: struct { done: bool, body: string }

http_get :: proc(t: ^testing.T, u: string) -> string {
	g := new(Get, context.temp_allocator)
	fetch.start(&loader, {
		request = {url = u, mode = .Cors, credentials = .Omit},
		on_event = proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
			g := (^Get)(user)
			#partial switch ev.kind {
			case .Done:
				g.body = strings.clone(string(ev.data), base.process_context().temp_allocator)
				g.done = true
			case .Failed:
				g.done = true
			}
		}, user = g, collect = true,
	})
	wait_until(t, u, g, proc(g: ^Get) -> bool { return g.done })
	return g.body
}

Painted :: struct {
	pr:   ^Probe,
	id:   u64,
	now:  f64,
	w, h: int,
	fp:   page.Frame_Pixels,
}

// Pixels of entry `id` drawn w x h, waiting for the decoding threads.
pixels :: proc(pr: ^Probe, id: u64, w, h: int, loc := #caller_location) -> page.Frame_Pixels {
	w := Painted{pr = pr, id = id, now = f64(host.now_ns(&loop)) / 1e6, w = w, h = h}
	wait_until(pr.t, "the pixels", &w, proc(w: ^Painted) -> bool {
		page.images_paint_begin()
		w.fp = page.frame_pixels(w.id, w.now, w.w, w.h, DECODE_PRIORITY)
		turn(w.pr)
		return w.fp.ok && w.fp.width == w.w && w.fp.height == w.h
	}, loc = loc)
	return w.fp
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

Inline :: struct {
	pr:   ^Probe,
	node: base.Handle,
	w, h: f32,
	view: page.Image_View,
}

// An inline <svg> as the painter asks for it.
inline_svg :: proc(pr: ^Probe, id: string, w: f32 = ICON, h: f32 = ICON, loc := #caller_location) -> page.Frame_Pixels {
	v := Inline{pr = pr, node = node(pr, id), w = w, h = h}
	ok := wait_until(pr.t, id, &v, proc(v: ^Inline) -> bool {
		v.view = page.inline_svg_view(v.pr.p, v.node, v.w, v.h)
		turn(v.pr)
		return v.view.state == .Ready
	}, loc = loc)
	return ok ? pixels(pr, v.view.id, int(w), int(h), loc) : {}
}

@(test)
media_every_image_is_ready :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := open(t)
	for id in READY_IDS {
		v := view(pr, id)
		check(pr, v.state == .Ready, fmt.tprintf("#%s ready (%v %s)", id, v.state, v.error))
	}
	shut(pr, min_checks = len(READY_IDS))
}

Size :: struct { id: string, w, h: f32 }

@(test)
media_avif_and_webp :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := open(t)
	sizes := []Size{{"avif8", 32, 16}, {"avif10", 32, 16}, {"rot90", 16, 32}, {"transverse", 16, 32}, {"mirror", 32, 16}, {"avifanim", 10, 10},
		{"webplossy", 32, 16}, {"webpanim", 10, 10}, {"pic", 32, 16}, {"neg", 32, 16}}
	for s in sizes {
		v := view(pr, s.id)
		check(pr, v.natural == {s.w, s.h}, fmt.tprintf("#%s natural size %v (want %vx%v)", s.id, v.natural, s.w, s.h))
	}
	check(pr, view(pr, "avifanim").animated && view(pr, "webpanim").animated, "AVIF and WebP animations")
	r := pixels(pr, view(pr, "rot90").id, 16, 32)
	check(pr, near(px(r, 2, 2), {0, 0, 255, 255}, COLOR_TOLERANCE) && near(px(r, 13, 29), {0, 255, 0, 255}, COLOR_TOLERANCE), "irot applied (blue top left, lime bottom right)")
	a := pixels(pr, view(pr, "avif8").id, 32, 16)
	check(pr, near(px(a, 27, 12), {255, 255, 255, 128}, COLOR_TOLERANCE), fmt.tprintf("AVIF alpha (%v)", px(a, 27, 12)))
	accept := http_get(t, testenv.url(ORIGIN + "/media/accept?name=quad8a.avif"))
	check(pr, strings.has_prefix(accept, "image/avif,image/webp,image/svg+xml"), fmt.tprintf("Accept of image requests: %q", accept))
	check(pr, view(pr, "neg").natural == {32, 16}, "content negotiation on Accept: the server sent AVIF")
	check(pr, view(pr, "pic").natural == {32, 16}, "<picture>: the image/avif source is chosen")
	shut(pr, min_checks = 16)
}

@(test)
media_svg_images :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := open(t)
	v1 := view(pr, "svg1")
	check(pr, v1.svg && v1.natural == {120, 60} && v1.has_size == {true, true}, fmt.tprintf("shapes.svg: natural 120 x 60 (%v)", v1.natural))
	vr := view(pr, "svgratio")
	check(pr, vr.svg && vr.ratio_only && abs(vr.ratio - 4) < RATIO_TOLERANCE, fmt.tprintf("ratio.svg: a ratio (4) and no size (%v %v)", vr.ratio_only, vr.ratio))
	s1 := pixels(pr, v1.id, 120, 60)
	s3 := pixels(pr, v1.id, 360, 180)
	check(pr, s1.ok && s3.ok && s1.texture != s3.texture, "rasterised at each size shown: two rasters, two textures")
	check(pr, near(px(s3, 270, 30), {42, 170, 42, 255}, RING_TOLERANCE) || px(s3, 270, 6)[3] > 200, "the 3x raster is drawn at 360 x 180 (ring)")
	again := pixels(pr, v1.id, 120, 60)
	check(pr, again.texture == s1.texture, "the first size is still cached")
	wait_until(t, "the CSS images", pr, proc(pr: ^Probe) -> bool {
		turn(pr)
		return page.css_image_view(pr.p, "/media/f/pattern.svg").state == .Ready && page.css_image_view(pr.p, "/media/f/external.svg").state == .Ready
	})
	bg := page.css_image_view(pr.p, "/media/f/pattern.svg")
	check(pr, bg.state == .Ready && bg.svg && bg.natural == {40, 40}, fmt.tprintf("SVG background image (%v %v)", bg.state, bg.natural))
	bgp := pixels(pr, bg.id, 24, 24)
	check(pr, bgp.ok && bgp.width == 24, "background tile rendered at its size")
	ext := page.css_image_view(pr.p, "/media/f/external.svg")
	check(pr, ext.state == .Ready && ext.ratio_only, fmt.tprintf("::after background external.svg (%v)", ext.state))
	shut(pr, min_checks = 8)
}

@(test)
media_inline_svg :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := open(t)
	i5 := inline_svg(pr, "inl5")
	check(pr, i5.ok && px(i5, ICON_MIDDLE, ICON_MIDDLE) == {0, 255, 0, 255}, fmt.tprintf("currentColor from the element's color (%v)", px(i5, ICON_MIDDLE, ICON_MIDDLE)))
	// color="currentColor" or style="color:currentColor" on the <svg> itself: the parent's color (DuckDuckGo's icons), not black
	i6 := inline_svg(pr, "inl6")
	check(pr, i6.ok && px(i6, ICON_MIDDLE, ICON_MIDDLE) == {0, 0, 255, 255}, fmt.tprintf("<svg color=currentColor>: the parent's color (%v)", px(i6, ICON_MIDDLE, ICON_MIDDLE)))
	i7 := inline_svg(pr, "inl7")
	check(pr, i7.ok && px(i7, ICON_MIDDLE, ICON_MIDDLE) == {0, 0, 255, 255}, fmt.tprintf("<svg style=color:currentColor>: the parent's color (%v)", px(i7, ICON_MIDDLE, ICON_MIDDLE)))
	i8 := inline_svg(pr, "inl8")
	check(pr, i8.ok && px(i8, ICON_MIDDLE, ICON_MIDDLE) == {255, 0, 0, 255}, fmt.tprintf("<svg color=#ff0000>: its own color (%v)", px(i8, ICON_MIDDLE, ICON_MIDDLE)))
	// the page's CSS on the elements inside the <svg>: a class rule beats the fill attribute; light-dark() follows the scheme
	i9 := inline_svg(pr, "inl9")
	check(pr, i9.ok && px(i9, ICON_MIDDLE, 8) == {255, 128, 0, 255}, fmt.tprintf("a class rule sets the fill of an inner element (%v)", px(i9, ICON_MIDDLE, 8)))
	check(pr, i9.ok && px(i9, ICON_MIDDLE, 24) == {0, 255, 255, 255}, fmt.tprintf("light-dark() on an inner element's fill (%v)", px(i9, ICON_MIDDLE, 24)))
	i1 := inline_svg(pr, "inl1")
	check(pr, i1.ok && near(px(i1, ICON_MIDDLE, 14), {0x15, 0x65, 0xc0, 255}, GRADIENT_TOLERANCE), fmt.tprintf("<use href=#i-star> into a hidden sprite, currentColor from the parent (%v)", px(i1, ICON_MIDDLE, 14)))
	i2 := inline_svg(pr, "inl2")
	check(pr, i2.ok && near(px(i2, ICON_MIDDLE, 20), {0xc6, 0x28, 0x28, 255}, GRADIENT_TOLERANCE), fmt.tprintf("another symbol, another color (%v)", px(i2, ICON_MIDDLE, 20)))
	i3 := inline_svg(pr, "inl3")
	check(pr, i3.ok && near(px(i3, ICON_MIDDLE, 14), {0x2e, 0x7d, 0x32, 255}, GRADIENT_TOLERANCE), "xlink:href")
	i4 := inline_svg(pr, "inl4", GRADIENT_W, ICON)
	check(pr, i4.ok && px(i4, 3, ICON_MIDDLE)[3] == 255 && px(i4, 3, ICON_MIDDLE)[0] > 200, "gradient, width / height attributes, no viewBox")
	w, h, ok := page.inline_svg_intrinsic(pr.p, node(pr, "inl4"))
	check(pr, ok && w == GRADIENT_W && h == ICON, "inline <svg> natural size from its attributes")
	_, _, rok := page.inline_svg_intrinsic(pr.p, node(pr, "inl1"))
	check(pr, !rok && page.inline_svg_ratio(pr.p, node(pr, "inl1")) == 1, "viewBox only: a ratio for the layout")
	shut(pr, min_checks = 12)
}

@(test)
media_inline_svg_drawn_again_after_a_mutation :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := open(t)
	before := inline_svg(pr, "inl5")
	check(pr, before.ok && px(before, ICON_MIDDLE, ICON_MIDDLE) == {0, 255, 0, 255}, "the picture before")
	rect := dom.get(pr.p.doc, node(pr, "inl5")).first_child
	dom.set_attribute(pr.p.doc, rect, "fill", "#ff0000")
	dom.touch(pr.p.doc)
	turn(pr)
	after := inline_svg(pr, "inl5")
	check(pr, after.ok && px(after, ICON_MIDDLE, ICON_MIDDLE) == {255, 0, 0, 255}, fmt.tprintf("drawn again after a mutation (%v)", px(after, ICON_MIDDLE, ICON_MIDDLE)))
	shut(pr, min_checks = 2)
}
