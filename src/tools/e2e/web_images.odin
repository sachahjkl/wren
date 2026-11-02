#+build windows
#+private file
// Images in pages: examples/site/images.html with the guest examples/imagestest (load / error events in order, naturalWidth /
// naturalHeight / complete / currentSrc, srcset with x and w descriptors, <picture> / <source>, loading=lazy, CSS background images
// resolved against their sheet, broken and hostile files, cross-origin no-cors / cors, an animated GIF, decode(), Image_decode),
// deduplication (the test server counts the requests), the shared cache and its partitioning by site, cancellation when a page closes,
// and, with -Perf, 200 images of a megapixel decoded without blocking the UI thread.
//
// The process's image cache would answer for what a test wants to see downloaded: each test starts and ends without it.
package e2e_scenarios

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:images"
import "wb:page"
import "wb:tools/testenv"
import "wb:wasm"

GUEST :: "build/imagestest.wasm"
FIXTURE :: "examples/site/images.html"
ORIGIN :: "http://127.0.0.1:8765"
OTHER_SITE :: "http://localhost:8765"

VIEW_W :: 1024
VIEW_H :: 768
DPPX :: 2                     // what the srcset tests choose for
FAR_PX :: 5000                // a lazy image this far stays where it is,
NEAR_PX :: 300                // and this near loads
SIMPLE :: i32(0)              // #simple in the guest's IDS
WANT_NONE :: min(i32)         // a guest's call that failed
EVENTS_OF_IDS :: 21           // those of IDS that fire an event by themselves: all but "lazy" and "late"

ANIM_SHOWN_PX :: 40           // #anim's width and height attributes
ANIM_FRAME_1_MS :: 150.0      // in frame 1 (the frames last 100, 200 and 300 ms)
ANIM_FRAME_2_MS :: 350.0      // in frame 2
ANIM_FRAME_0_NEXT_MS :: 100.0
ANIM_FRAME_2_NEXT_MS :: 600.0
ANIM_OVER_MS :: 5000.0        // after its three plays
NOISE_NATURAL :: 64
NOISE_SHOWN :: 16

MANY :: 200                   // 200 images of 1 megapixel
MANY_PX :: 1000
MANY_PER_FRAME :: 20
MANY_JOBS :: 2 * MANY         // a probe and a decode each
MANY_WAIT :: 60.0
CACHE_SLACK_BYTES :: 100 << 20

IDS := [?]string{
	"simple", "sized", "dup1", "dup2", "jpeg", "ico", "tiff", "anim", "fit", "srcset", "wdesc", "pic",
	"broken", "missing", "empty", "bomb", "svg", "trunc", "nocors", "cors", "corsfail", "lazy", "late",
}

id_index :: proc(id: string) -> i32 {
	for x, i in IDS { if x == id { return i32(i) } }
	return -1
}

// examples/site/images.html with its guest, every image in it having fired its event.
Site :: struct {
	pr:           ^Probe,
	inst:         ^wasm.Instance,
	module, html: []byte,
}

// What the shell does each frame (styles, images) for a page.
turn :: proc(pr: ^Probe) {
	page.styles(pr.p, VIEW_W, VIEW_H, DPPX)
	page.images_sync(pr.p)
}

Wait :: struct {
	pr:   ^Probe,
	cond: proc(pr: ^Probe) -> bool,
}

// Runs the loop and the page's frames until `cond`.
wait :: proc(pr: ^Probe, what: string, cond: proc(pr: ^Probe) -> bool, seconds := DEFAULT_WAIT, loc := #caller_location) -> bool {
	return wait_until(pr.t, what, Wait{pr, cond}, proc(w: Wait) -> bool {
		turn(w.pr)
		return w.cond(w.pr)
	}, seconds, loc)
}

node :: proc(pr: ^Probe, id: string) -> base.Handle { return dom.find_by_id(pr.p.doc, id) }

attr :: proc(pr: ^Probe, name: string) -> string {
	v, _ := dom.get_attribute(pr.p.doc, node(pr, "r"), name)
	return v
}

state :: proc(pr: ^Probe, id: string) -> page.Image_View { return page.image_view(pr.p, node(pr, id)) }

// The test's cache is the test's own.
no_cache_yet :: proc() { page.images_shutdown() }

// Every page closed: nothing of the cache stays, and the threads that fed it stop (the process's: the harness is the only embedder).
no_cache_left :: proc(t: ^testing.T, loc := #caller_location) {
	page.images_shutdown()
	images.decoder_stop()
	testing.expect(t, !images.decoder_running(), "decoding threads stopped", loc = loc)
}

open :: proc(t: ^testing.T, s: ^Site) {
	no_cache_yet()
	module, merr := os.read_entire_file(GUEST, context.allocator)
	testing.expect(t, merr == nil, "the guest is built: " + GUEST)
	html, herr := os.read_entire_file(FIXTURE, context.allocator)
	testing.expect(t, herr == nil, "the page is there: " + FIXTURE)
	s.module, s.html = module, html
	s.pr = page_make(t, "images", testenv.url(ORIGIN + "/site/images.html"))
	page_load(s.pr, testenv.url(string(s.html)))
	inst, ok, why := page.load_module(s.pr.p, s.module, "imagestest")
	check(s.pr, ok, fmt.tprintf("guest runs %s", why))
	s.inst = inst
	wait(s.pr, "load and error events", proc(pr: ^Probe) -> bool {
		ev := attr(pr, "data-events")
		for id in IDS[:EVENTS_OF_IDS] { if !strings.contains(ev, fmt.tprintf("%s:", id)) { return false } }
		return true
	})
	wait(s.pr, "the end of the page's requests", proc(pr: ^Probe) -> bool { return fetch.in_flight(&loader) == 0 })
	drain()
}

shut :: proc(s: ^Site, min_checks: int, loc := #caller_location) {
	t := s.pr.t
	close_page(s.pr, min_checks = min_checks, loc = loc)
	delete(s.module)
	delete(s.html)
	no_cache_left(t, loc)
}

call :: proc(s: ^Site, name: cstring, args: ..i32) -> i32 {
	argv: [4]u32
	for a, i in args { argv[i] = u32(a) }
	if page.call_export(s.pr.p, s.inst, name, argv[:max(len(args), 1)]) != .Ok { return WANT_NONE }
	return i32(argv[0])
}

current_src :: proc(s: ^Site, id: string) -> string {
	call(s, "current_src", id_index(id))
	return attr(s.pr, "data-src")
}

Get :: struct { done: bool, body: string }

// A plain GET from the browser itself (no document): the test server's counters.
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

count :: proc(t: ^testing.T, path: string) -> int {
	n, _ := strconv.parse_int(http_get(t, fmt.tprintf("%s/images/count?path=%s", testenv.url(ORIGIN), path)))
	return n
}

event_count :: proc(events, id: string) -> (loads, errors: int) {
	all := fmt.tprintf(" %s", events)   // " nocors:load" must not count for "cors"
	loads = strings.count(all, fmt.tprintf(" %s:load ", id))
	errors = strings.count(all, fmt.tprintf(" %s:error ", id))
	return
}

Size :: struct { id: string, w, h: i32 }

@(test)
images_load_and_error_events :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	s: Site
	open(t, &s)
	events := attr(s.pr, "data-events")
	for id in ([]string{"simple", "sized", "dup1", "dup2", "jpeg", "ico", "tiff", "anim", "fit", "srcset", "wdesc", "pic", "nocors", "cors", "svg"}) {
		l, e := event_count(events, id)
		check(s.pr, l == 1 && e == 0, fmt.tprintf("#%s: one load event (%d load, %d error)", id, l, e))
	}
	for id in ([]string{"broken", "missing", "empty", "bomb", "trunc", "corsfail"}) {
		l, e := event_count(events, id)
		check(s.pr, l == 0 && e == 1, fmt.tprintf("#%s: one error event (%d load, %d error)", id, l, e))
	}
	check(s.pr, !strings.contains(events, "lazy:"), "the lazy image far below did not load")
	shut(&s, min_checks = 23)
}

@(test)
images_sizes_and_sources :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	s: Site
	open(t, &s)
	sizes := []Size{
		{"simple", 8, 6}, {"sized", 8, 6}, {"dup1", 5, 3}, {"jpeg", 10, 20}, {"ico", 32, 32}, {"tiff", 3, 2}, {"anim", 10, 10},
		{"srcset", 20, 10}, {"wdesc", 20, 10}, {"pic", 32, 32}, {"nocors", 16, 8}, {"cors", 4, 4}, {"broken", 0, 0}, {"empty", 0, 0}, {"svg", 10, 10},
	}
	for x in sizes {
		i := id_index(x.id)
		w, h := call(&s, "natural_width", i), call(&s, "natural_height", i)
		check(s.pr, w == x.w && h == x.h, fmt.tprintf("#%s natural size %dx%d (want %dx%d)", x.id, w, h, x.w, x.h))
	}
	check(s.pr, current_src(&s, "simple") == testenv.url(ORIGIN + "/images/f/red.png"), "currentSrc is the absolute URL")
	check(s.pr, current_src(&s, "srcset") == testenv.url(ORIGIN + "/images/f/blue-2x.png"), fmt.tprintf("srcset: the 2x candidate at 2 dppx (%s)", current_src(&s, "srcset")))
	check(s.pr, current_src(&s, "wdesc") == testenv.url(ORIGIN + "/images/f/blue-2x.png"), fmt.tprintf("srcset with w descriptors and sizes (%s)", current_src(&s, "wdesc")))
	check(s.pr, current_src(&s, "pic") == testenv.url(ORIGIN + "/images/f/icon.ico"), fmt.tprintf("<picture>: unknown type and unmatched media skipped (%s)", current_src(&s, "pic")))
	check(s.pr, current_src(&s, "empty") == "", "no currentSrc for src=\"\"")
	check(s.pr, call(&s, "complete", id_index("simple")) == 1 && call(&s, "complete", id_index("broken")) == 1, "complete: loaded and broken images")
	check(s.pr, call(&s, "complete", id_index("lazy")) == 0, "complete: a lazy image that has not loaded")
	w, h, ok := page.image_intrinsic(s.pr.p, node(s.pr, "jpeg"))
	check(s.pr, ok && w == 10 && h == 20, "layout gets the natural size (EXIF orientation applied)")
	_, _, ok = page.image_intrinsic(s.pr.p, node(s.pr, "broken"))
	check(s.pr, !ok, "no natural size for a broken image (layout keeps its placeholder)")
	shut(&s, min_checks = 25)
}

@(test)
images_deduplication_and_css_images :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	s: Site
	open(t, &s)
	wait(s.pr, "the CSS images", proc(pr: ^Probe) -> bool {
		return page.css_image_view(pr.p, "/images/f/still.gif").state == .Ready && page.css_image_view(pr.p, "anim.gif").state == .Ready
	})
	red := count(t, "/images/f/red.png")
	check(s.pr, red == 1, fmt.tprintf("two <img> with one URL: one request (%d)", red))
	check(s.pr, count(t, "/images/f/blue.bmp") == 1, "#dup1 and #dup2: one request")
	check(s.pr, count(t, "/images/f/icon.ico") == 1, "#ico and the <source> of #pic: one request")
	check(s.pr, count(t, "/images/f/anim.gif") == 1, "#anim and the background of #bg2: one request")
	check(s.pr, count(t, "/images/f/noise.png") == 0, "nothing requested for the lazy image")
	bg := page.css_image_view(s.pr.p, "/images/f/still.gif")
	check(s.pr, bg.state == .Ready && bg.natural == {4, 4}, fmt.tprintf("background-image: url() of an inline style sheet (%v)", bg.state))
	bg2 := page.css_image_view(s.pr.p, "anim.gif")
	check(s.pr, bg2.state == .Ready && bg2.natural == {10, 10}, fmt.tprintf("url(anim.gif) resolved against its sheet /images/f/sheet.css (%v)", bg2.state))
	shut(&s, min_checks = 8)
}

// Brings the lazy image in.
near_the_viewport :: proc(s: ^Site) {
	page.images_set_distance(s.pr.p, node(s.pr, "lazy"), NEAR_PX)
	wait(s.pr, "lazy load", proc(pr: ^Probe) -> bool { return strings.contains(attr(pr, "data-events"), "lazy:load") })
}

@(test)
images_lazy_loading :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	s: Site
	open(t, &s)
	check(s.pr, slice.contains(page.images_watched(s.pr.p), node(s.pr, "lazy")), "the lazy image waits for the shell to report its distance")
	page.images_set_distance(s.pr.p, node(s.pr, "lazy"), FAR_PX)
	turn(s.pr)
	drain()
	check(s.pr, fetch.in_flight(&loader) == 0 && count(t, "/images/f/noise.png") == 0, "5000 px away: still not loaded")
	near_the_viewport(&s)
	check(s.pr, count(t, "/images/f/noise.png") == 1 && call(&s, "natural_width", id_index("lazy")) == NOISE_NATURAL, "near the viewport: loaded")
	shut(&s, min_checks = 4)
}

Painted :: struct {
	pr:   ^Probe,
	id:   u64,
	now:  f64,
	w, h: int,
	full: bool,               // not a reduced decode
	fp:   page.Frame_Pixels,
}

// The pixels of an entry at this size, the decoding threads having done their part.
frame_at :: proc(pr: ^Probe, id: u64, now: f64, w, h: int, full := false, loc := #caller_location) -> page.Frame_Pixels {
	w := Painted{pr = pr, id = id, now = now, w = w, h = h, full = full}
	wait_until(pr.t, "the decoded pixels", &w, proc(w: ^Painted) -> bool {
		w.fp = page.frame_pixels(w.id, w.now, w.w, w.h)
		turn(w.pr)
		return w.fp.ok && (!w.full || !w.fp.reduced)
	}, loc = loc)
	return w.fp
}

@(test)
images_pixels_for_the_painter :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	s: Site
	open(t, &s)
	near_the_viewport(&s)
	page.images_paint_begin()
	now := f64(host.now_ns(&loop)) / 1e6
	fp := frame_at(s.pr, state(s.pr, "simple").id, now, 8, 6)
	check(s.pr, fp.ok && fp.width == 8 && fp.height == 6 && fp.stride == 32, "decoded on request")
	check(s.pr, fp.ok && fp.pixels[0] == 255 && fp.pixels[1] == 0 && fp.pixels[2] == 0 && fp.pixels[3] == 255, "RGBA order, straight alpha")
	av := state(s.pr, "anim")
	check(s.pr, av.animated, "the GIF is animated")
	fa := frame_at(s.pr, av.id, now, ANIM_SHOWN_PX, ANIM_SHOWN_PX)
	// the animation's clock starts when it is first shown (the first call that had pixels, at `now`)
	f1 := page.frame_pixels(av.id, now + ANIM_FRAME_1_MS, ANIM_SHOWN_PX, ANIM_SHOWN_PX)
	f2 := page.frame_pixels(av.id, now + ANIM_FRAME_2_MS, ANIM_SHOWN_PX, ANIM_SHOWN_PX)
	fend := page.frame_pixels(av.id, now + ANIM_OVER_MS, ANIM_SHOWN_PX, ANIM_SHOWN_PX)
	check(s.pr, fa.ok && fa.frame == 0 && fa.next_ms == now + ANIM_FRAME_0_NEXT_MS, fmt.tprintf("frame 0, next change 100 ms later (%v)", fa.next_ms - now))
	check(s.pr, f1.frame == 1 && f2.frame == 2 && f2.next_ms == now + ANIM_FRAME_2_NEXT_MS, "frames 1 and 2 at their times")
	check(s.pr, fend.frame == 2 && fend.next_ms < 0, "after its three plays the animation rests on its last frame: nothing more to wake for")
	noise := state(s.pr, "lazy").id
	fr := frame_at(s.pr, noise, now, NOISE_SHOWN, NOISE_SHOWN)
	check(s.pr, fr.ok && fr.reduced && fr.width == NOISE_SHOWN, fmt.tprintf("a 64 px image shown at 16 px is decoded at 16 px (%d)", fr.width))
	ff := frame_at(s.pr, noise, now, NOISE_NATURAL, NOISE_NATURAL, full = true)
	check(s.pr, ff.ok && !ff.reduced && ff.width == NOISE_NATURAL && ff.generation != fr.generation, "shown larger: decoded again at the natural size")
	shut(&s, min_checks = 9)
}

@(test)
images_decode :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	s: Site
	open(t, &s)
	call(&s, "decode_probe")
	wait(s.pr, "decode()", proc(pr: ^Probe) -> bool { return attr(pr, "data-decode-ok") != "" && attr(pr, "data-decode-broken") != "" })
	check(s.pr, attr(s.pr, "data-decode-ok") == "fulfilled", "decode() of a loaded image is fulfilled")
	check(s.pr, attr(s.pr, "data-decode-broken") == "rejected", "decode() of a broken image is rejected")
	call(&s, "image_decode_probe")
	wait(s.pr, "Image_decode", proc(pr: ^Probe) -> bool { return attr(pr, "data-idecode") != "" && attr(pr, "data-idecode-bad") != "" })
	check(s.pr, attr(s.pr, "data-idecode") == "8x6 192 255,0,0,255", fmt.tprintf("Image_decode: RGBA pixels in a buffer (%q)", attr(s.pr, "data-idecode")))
	check(s.pr, attr(s.pr, "data-idecode-bad") == "rejected", "Image_decode of junk is rejected")
	shut(&s, min_checks = 5)
}

@(test)
images_changing_the_source :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	s: Site
	open(t, &s)
	check(s.pr, call(&s, "change_src", 0) == 0, "right after a new src: not complete")
	wait(s.pr, "second load", proc(pr: ^Probe) -> bool { return strings.count(attr(pr, "data-events"), "simple:load") == 2 })
	check(s.pr, current_src(&s, "simple") == testenv.url(ORIGIN + "/images/f/blue.bmp?again") && call(&s, "natural_width", SIMPLE) == 5, "the new image is current")
	call(&s, "change_src", 1)
	wait(s.pr, "error after change", proc(pr: ^Probe) -> bool { return strings.contains(attr(pr, "data-events"), "simple:error") })
	ev := attr(s.pr, "data-events")
	check(s.pr, strings.index(ev, "simple:load") < strings.last_index(ev, "simple:load") && strings.last_index(ev, "simple:load") < strings.index(ev, "simple:error"), "events of #simple in order: load, load, error")
	check(s.pr, call(&s, "natural_width", SIMPLE) == 0 && call(&s, "complete", SIMPLE) == 1, "a broken source: no size, complete")
	call(&s, "add_late")
	check(s.pr, wait(s.pr, "late image", proc(pr: ^Probe) -> bool { return strings.contains(attr(pr, "data-events"), "late:load") }), "an <img> made by a script loads")
	shut(&s, min_checks = 6)
}

@(test)
images_closing_a_page_cuts_its_download :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	no_cache_yet()
	pr := open_page(t, "images: a slow one", `<!doctype html><img id=slow src="/images/slow/noise.png">`, testenv.url(ORIGIN + "/site/slow.html"))
	wait(pr, "slow request", proc(pr: ^Probe) -> bool { return count(pr.t, "/images/slow/noise.png") == 1 })
	close_page(pr)
	cut := wait_until(t, "cut", t, proc(t: ^testing.T) -> bool { return count(t, "slow-aborted") == 1 })
	testing.expect(t, cut, "closing the page cut the download")
	idle := wait_until(t, "idle", 0, proc(_: int) -> bool { return fetch.in_flight(&loader) == 0 })
	testing.expect(t, idle, "no request left")
	no_cache_left(t)
}

ONE_RED :: `<!doctype html><img id=again src="/images/f/red.png">`

is_ready :: proc(pr: ^Probe) -> bool { return state(pr, "again").state == .Ready }

@(test)
images_the_shared_cache :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	no_cache_yet()
	first := open_page(t, "images: the first of the site", ONE_RED, testenv.url(ORIGIN + "/site/first.html"))
	wait(first, "the first page's image", is_ready)
	close_page(first)

	same := open_page(t, "images: another of the site", ONE_RED, testenv.url(ORIGIN + "/site/again.html"))
	wait(same, "shared", is_ready)
	check(same, is_ready(same) && count(t, "/images/f/red.png") == 1, "another page of the site takes the cached image: no request")
	check(same, page.images_stats(same.p).shared == 1, "counted as shared")
	close_page(same, min_checks = 2)

	other := open_page(t, "images: another site", ONE_RED, testenv.url(OTHER_SITE + "/site/other.html"))
	wait(other, "other site", is_ready)
	check(other, count(t, "/images/f/red.png") == 2, "another top-level site does not see the cache of the first: it downloads")

	csp := page_make(t, "images: CSP", testenv.url(ORIGIN + "/site/csp.html"))
	page.apply_response_headers(csp.p, {"img-src 'none'"}, nil, "")
	page_load(csp, ONE_RED)
	close_page(other, min_checks = 1)
	wait(csp, "csp", proc(pr: ^Probe) -> bool { return state(pr, "again").state == .Broken })
	check(csp, state(csp, "again").state == .Broken && page.images_stats(csp.p).shared == 0, "img-src 'none': the cached image is not handed over, the request is blocked")
	close_page(csp, min_checks = 1)
	no_cache_left(t)
}

Scrolling :: struct {
	pr:      ^Probe,
	ids:     []u64,
	now:     f64,
	shown:   int,
	longest: time.Duration,    // the longest turn of the loop on this (UI) thread
}

// (a measure of decoding time: 313 ms a job on a busy CI runner with two steps at once. The longest UI turn is a measure, not a check:
// a slow or busy machine would fail it without a regression; that decoding stays off the UI thread is what the decoder statistics check)
@(test)
images_200_of_a_megapixel :: proc(t: ^testing.T) {
	if base.perf_skip("200 images of 1 megapixel") { return }
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	no_cache_yet()
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<!doctype html><body>")
	for i in 0 ..< MANY { fmt.sbprintf(&b, `<img id=g%d src="/images/gen?w=%d&h=%d&seed=%d">`, i, MANY_PX, MANY_PX, i) }
	pr := open_page(t, "images: many", strings.to_string(b), testenv.url(ORIGIN + "/site/many.html"))
	before := images.decoder_stats()
	started := time.tick_now()
	wait(pr, "200 sizes", proc(pr: ^Probe) -> bool {
		for i in 0 ..< MANY { if state(pr, fmt.tprintf("g%d", i)).state != .Ready { return false } }
		return true
	}, MANY_WAIT)
	sizes_known := time.tick_since(started)
	ids: [MANY]u64
	for i in 0 ..< MANY { ids[i] = state(pr, fmt.tprintf("g%d", i)).id }

	// the painter scrolling down the page: each frame shows a few images at their natural size
	scroll := Scrolling{pr = pr, ids = ids[:], now = f64(host.now_ns(&loop)) / 1e6}
	shown := wait_until(t, "every image", &scroll, proc(s: ^Scrolling) -> bool {
		page.images_paint_begin()
		next := s.ids[s.shown:min(s.shown + MANY_PER_FRAME, MANY)]
		all := true
		for id in next { if !page.frame_pixels(id, s.now, MANY_PX, MANY_PX).ok { all = false } }
		if all { s.shown += len(next) }
		turn_started := time.tick_now()
		host.run_ready(&loop)
		turn(s.pr)
		s.longest = max(s.longest, time.tick_since(turn_started))
		return s.shown >= MANY
	}, MANY_WAIT)
	check(pr, shown, "every image was shown")
	decoded := time.tick_since(started)
	after := images.decoder_stats()
	st := page.images_stats(pr.p)
	log.infof("sizes known after %v, every image decoded once after %v (%d jobs, %.0f ms of decoding on %d threads, longest %.1f ms)",
		sizes_known, decoded, after.jobs - before.jobs, after.busy_ms - before.busy_ms, images.decoder_threads(), after.longest_ms)
	log.infof("cache: %d entries, %d MiB of %d MiB; longest UI turn %v", st.entries, st.bytes >> 20, st.limit >> 20, scroll.longest)
	check(pr, after.decoded - before.decoded >= MANY_JOBS, "200 probes and 200 decodes, on the decoding threads")
	check(pr, st.bytes <= st.limit + CACHE_SLACK_BYTES, "the cache stays near its limit: pixels of images no longer shown are dropped")
	close_page(pr, min_checks = 3)
	no_cache_left(t)
}
