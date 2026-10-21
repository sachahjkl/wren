// Headless end-to-end test of images in pages: examples/site/images.html with the guest examples/imagestest (load /
// error events in order, naturalWidth / naturalHeight / complete / currentSrc, srcset with x and w descriptors,
// <picture> / <source>, loading=lazy, CSS background images resolved against their sheet, broken and hostile files,
// cross-origin no-cors / cors, an animated GIF, decode(), Image_decode), deduplication (the test server counts the
// requests), the shared cache and its partitioning by site, cancellation when a page closes, and 200 images of a
// megapixel decoded without blocking the UI thread. Needs build\testserver.exe running; from the repository root:
//   imagestest.exe build\imagestest.wasm
package imagestest

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:images"
import "wb:net"
import "wb:page"
import "wb:wasm"
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
cur:      ^page.Page          // the page `attr` and the pumps look at
longest_turn: f64             // longest single turn of the loop on this (UI) thread, ms

SITE :: "http://127.0.0.1:8765"   // on the run's block of ports through testenv.url

// One turn: what the shell does each frame (styles, images), then whatever the loop has ready.
turn :: proc() {
	host.loop_wait(&loop, 5)
	t := time.tick_now()
	host.run_ready(&loop)
	if cur != nil && !cur.closed {
		page.styles(cur, 1024, 768, 2)
		page.images_sync(cur)
	}
	longest_turn = max(longest_turn, time.duration_milliseconds(time.tick_since(t)))
	free_all(context.temp_allocator)
}

pump_until :: proc(what: string, cond: proc() -> bool, seconds := 10.0) -> bool {
	start := time.tick_now()
	for !cond() {
		if time.duration_seconds(time.tick_since(start)) > seconds { fmt.printf("  timeout waiting for %s\n", what); return false }
		turn()
	}
	return true
}

pump_for :: proc(ms: f64) {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < ms { turn() }
}

attr :: proc(name: string) -> string {
	v, _ := dom.get_attribute(cur.doc, dom.find_by_id(cur.doc, "r"), name)
	return v
}

node :: proc(id: string) -> base.Handle { return dom.find_by_id(cur.doc, id) }

call :: proc(inst: ^wasm.Instance, name: cstring, args: ..i32) -> i32 {
	argv: [4]u32
	for a, i in args { argv[i] = u32(a) }
	res := page.call_export(cur, inst, name, argv[:max(len(args), 1)])
	if res != .Ok { return min(i32) }
	return i32(argv[0])
}

IDS := [?]string{
	"simple", "sized", "dup1", "dup2", "jpeg", "ico", "tiff", "anim", "fit", "srcset", "wdesc", "pic",
	"broken", "missing", "empty", "bomb", "svg", "trunc", "nocors", "cors", "corsfail", "lazy", "late",
}
id_index :: proc(id: string) -> i32 {
	for x, i in IDS { if x == id { return i32(i) } }
	return -1
}

// A plain GET from the browser itself (no document): the test server's counters.
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

count :: proc(path: string) -> int {
	n, _ := strconv.parse_int(http_get(fmt.tprintf("%s/images/count?path=%s", testenv.url(SITE), path)))
	return n
}

open_page :: proc(address, body: string) -> ^page.Page {
	p := page.page_create(&loop, &loader, &settings, process, address, console)
	page.load_html(p, transmute([]byte)body)
	return p
}

event_count :: proc(events, id: string) -> (loads, errors: int) {
	all := fmt.tprintf(" %s", events)   // " nocors:load" must not count for "cors"
	loads = strings.count(all, fmt.tprintf(" %s:load ", id))
	errors = strings.count(all, fmt.tprintf(" %s:error ", id))
	return
}

main :: proc() {
	context = testenv.context_of_process()
	if len(os.args) < 2 { fmt.eprintln("usage: imagestest imagestest.wasm"); os.exit(2) }
	image, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil { fmt.eprintln("cannot read the module"); os.exit(2) }
	html, herr := os.read_entire_file("examples/site/images.html", context.allocator)
	if herr != nil { fmt.eprintln("cannot read examples/site/images.html"); os.exit(2) }

	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }
	process = base.scope_make("process")
	check(http_get(testenv.url(SITE + "/images/reset")) == "ok", "test server counters reset")

	////////////////////////////////
	fmt.println("-- the page: events, sizes, sources")
	p := open_page(testenv.url(SITE + "/site/images.html"), testenv.url(string(html)))
	cur = p
	inst, ok, merr := page.load_module(p, image, "imagestest")
	check(ok, fmt.tprintf("guest runs %s", merr))
	expected_load := []string{"simple", "sized", "dup1", "dup2", "jpeg", "ico", "tiff", "anim", "fit", "srcset", "wdesc", "pic", "nocors", "cors", "svg"}
	expected_error := []string{"broken", "missing", "empty", "bomb", "trunc", "corsfail"}
	pump_until("load and error events", proc() -> bool {
		ev := attr("data-events")
		for id in IDS[:21] { if !strings.contains(ev, fmt.tprintf("%s:", id)) { return false } }
		return true
	})
	pump_for(100)
	events := strings.clone(attr("data-events"), context.allocator)
	fmt.printf("  events: %s\n", events)
	for id in expected_load {
		l, e := event_count(events, id)
		check(l == 1 && e == 0, fmt.tprintf("#%s: one load event (%d load, %d error)", id, l, e))
	}
	for id in expected_error {
		l, e := event_count(events, id)
		check(l == 0 && e == 1, fmt.tprintf("#%s: one error event (%d load, %d error)", id, l, e))
	}
	check(!strings.contains(events, "lazy:"), "the lazy image far below did not load")

	Size :: struct { id: string, w, h: i32 }
	sizes := []Size{
		{"simple", 8, 6}, {"sized", 8, 6}, {"dup1", 5, 3}, {"jpeg", 10, 20}, {"ico", 32, 32}, {"tiff", 3, 2}, {"anim", 10, 10},
		{"srcset", 20, 10}, {"wdesc", 20, 10}, {"pic", 32, 32}, {"nocors", 16, 8}, {"cors", 4, 4}, {"broken", 0, 0}, {"empty", 0, 0}, {"svg", 10, 10},
	}
	for s in sizes {
		i := id_index(s.id)
		w, h := call(inst, "natural_width", i), call(inst, "natural_height", i)
		check(w == s.w && h == s.h, fmt.tprintf("#%s natural size %dx%d (want %dx%d)", s.id, w, h, s.w, s.h))
	}
	src :: proc(inst: ^wasm.Instance, id: string) -> string { call(inst, "current_src", id_index(id)); return attr("data-src") }
	check(src(inst, "simple") == testenv.url(SITE + "/images/f/red.png"), "currentSrc is the absolute URL")
	check(src(inst, "srcset") == testenv.url(SITE + "/images/f/blue-2x.png"), fmt.tprintf("srcset: the 2x candidate at 2 dppx (%s)", src(inst, "srcset")))
	check(src(inst, "wdesc") == testenv.url(SITE + "/images/f/blue-2x.png"), fmt.tprintf("srcset with w descriptors and sizes (%s)", src(inst, "wdesc")))
	check(src(inst, "pic") == testenv.url(SITE + "/images/f/icon.ico"), fmt.tprintf("<picture>: unknown type and unmatched media skipped (%s)", src(inst, "pic")))
	check(src(inst, "empty") == "", "no currentSrc for src=\"\"")
	check(call(inst, "complete", id_index("simple")) == 1 && call(inst, "complete", id_index("broken")) == 1, "complete: loaded and broken images")
	check(call(inst, "complete", id_index("lazy")) == 0, "complete: a lazy image that has not loaded")
	w, h, iok := page.image_intrinsic(p, node("jpeg"))
	check(iok && w == 10 && h == 20, "layout gets the natural size (EXIF orientation applied)")
	_, _, iok = page.image_intrinsic(p, node("broken"))
	check(!iok, "no natural size for a broken image (layout keeps its placeholder)")

	fmt.println("-- deduplication, CSS images")
	check(count("/images/f/red.png") == 1, fmt.tprintf("two <img> with one URL: one request (%d)", count("/images/f/red.png")))
	check(count("/images/f/blue.bmp") == 1, "#dup1 and #dup2: one request")
	check(count("/images/f/icon.ico") == 1, "#ico and the <source> of #pic: one request")
	check(count("/images/f/anim.gif") == 1, "#anim and the background of #bg2: one request")
	check(count("/images/f/noise.png") == 0, "nothing requested for the lazy image")
	bg := page.css_image_view(p, "/images/f/still.gif")
	check(bg.state == .Ready && bg.natural == {4, 4}, fmt.tprintf("background-image: url() of an inline style sheet (%v)", bg.state))
	bg2 := page.css_image_view(p, "anim.gif")
	check(bg2.state == .Ready && bg2.natural == {10, 10}, fmt.tprintf("url(anim.gif) resolved against its sheet /images/f/sheet.css (%v)", bg2.state))

	fmt.println("-- lazy loading")
	watched := page.images_watched(p)
	lazy_watched := false
	for n in watched { if n == node("lazy") { lazy_watched = true } }
	check(lazy_watched, "the lazy image waits for the shell to report its distance")
	page.images_set_distance(p, node("lazy"), 5000)
	pump_for(200)
	check(count("/images/f/noise.png") == 0, "5000 px away: still not loaded")
	page.images_set_distance(p, node("lazy"), 300)
	pump_until("lazy load", proc() -> bool { return strings.contains(attr("data-events"), "lazy:load") })
	check(count("/images/f/noise.png") == 1 && call(inst, "natural_width", id_index("lazy")) == 64, "near the viewport: loaded")

	fmt.println("-- pixels for the painter")
	page.images_paint_begin()
	v := page.image_view(p, node("simple"))
	fp: page.Frame_Pixels
	now := f64(host.now_ns(&loop)) / 1e6
	start := time.tick_now()
	for !fp.ok && time.duration_seconds(time.tick_since(start)) < 5 { fp = page.frame_pixels(v.id, now, 8, 6); turn() }
	check(fp.ok && fp.width == 8 && fp.height == 6 && fp.stride == 32, "decoded on request")
	check(fp.ok && fp.pixels[0] == 255 && fp.pixels[1] == 0 && fp.pixels[2] == 0 && fp.pixels[3] == 255, "RGBA order, straight alpha")
	av := page.image_view(p, node("anim"))
	check(av.animated, "the GIF is animated")
	fa: page.Frame_Pixels
	start = time.tick_now()
	for !fa.ok && time.duration_seconds(time.tick_since(start)) < 5 { fa = page.frame_pixels(av.id, now, 40, 40); turn() }
	// the animation's clock starts when it is first shown (the first call that had pixels, at `now`)
	f1 := page.frame_pixels(av.id, now + 150, 40, 40)
	f2 := page.frame_pixels(av.id, now + 350, 40, 40)
	fend := page.frame_pixels(av.id, now + 5000, 40, 40)
	check(fa.ok && fa.frame == 0 && fa.next_ms == now + 100, fmt.tprintf("frame 0, next change 100 ms later (%v)", fa.next_ms - now))
	check(f1.frame == 1 && f2.frame == 2 && f2.next_ms == now + 600, "frames 1 and 2 at their times")
	check(fend.frame == 2 && fend.next_ms < 0, "after its three plays the animation rests on its last frame: nothing more to wake for")
	nv := page.image_view(p, node("lazy"))
	fr: page.Frame_Pixels
	start = time.tick_now()
	for !fr.ok && time.duration_seconds(time.tick_since(start)) < 5 { fr = page.frame_pixels(nv.id, now, 16, 16); turn() }
	check(fr.ok && fr.reduced && fr.width == 16, fmt.tprintf("a 64 px image shown at 16 px is decoded at 16 px (%d)", fr.width))
	start = time.tick_now()
	ff: page.Frame_Pixels
	for (!ff.ok || ff.reduced) && time.duration_seconds(time.tick_since(start)) < 5 { ff = page.frame_pixels(nv.id, now, 64, 64); turn() }
	check(ff.ok && !ff.reduced && ff.width == 64 && ff.generation != fr.generation, "shown larger: decoded again at the natural size")

	fmt.println("-- decode(), Image_decode")
	call(inst, "decode_probe")
	pump_until("decode()", proc() -> bool { return attr("data-decode-ok") != "" && attr("data-decode-broken") != "" })
	check(attr("data-decode-ok") == "fulfilled", "decode() of a loaded image is fulfilled")
	check(attr("data-decode-broken") == "rejected", "decode() of a broken image is rejected")
	call(inst, "image_decode_probe")
	pump_until("Image_decode", proc() -> bool { return attr("data-idecode") != "" && attr("data-idecode-bad") != "" })
	check(attr("data-idecode") == "8x6 192 255,0,0,255", fmt.tprintf("Image_decode: RGBA pixels in a buffer (%q)", attr("data-idecode")))
	check(attr("data-idecode-bad") == "rejected", "Image_decode of junk is rejected")

	fmt.println("-- changing the source")
	check(call(inst, "change_src", 0) == 0, "right after a new src: not complete")
	pump_until("second load", proc() -> bool { return strings.count(attr("data-events"), "simple:load") == 2 })
	check(src(inst, "simple") == testenv.url(SITE + "/images/f/blue.bmp?again") && call(inst, "natural_width", 0) == 5, "the new image is current")
	call(inst, "change_src", 1)
	pump_until("error after change", proc() -> bool { return strings.contains(attr("data-events"), "simple:error") })
	ev2 := attr("data-events")
	check(strings.index(ev2, "simple:load") < strings.last_index(ev2, "simple:load") && strings.last_index(ev2, "simple:load") < strings.index(ev2, "simple:error"), "events of #simple in order: load, load, error")
	check(call(inst, "natural_width", 0) == 0 && call(inst, "complete", 0) == 1, "a broken source: no size, complete")
	call(inst, "add_late")
	pump_until("late image", proc() -> bool { return strings.contains(attr("data-events"), "late:load") })
	check(strings.contains(attr("data-events"), "late:load"), "an <img> made by a script loads")
	held := page.images_stats(p)
	fmt.printf("  page 1: %d elements, %d requests, %d downloads\n", held.elements, held.requests, held.started)
	page.page_close(p)
	cur = nil
	pump_for(50)

	////////////////////////////////
	fmt.println("-- cancellation, shared cache")
	q := open_page(testenv.url(SITE + "/site/slow.html"), `<!doctype html><img id=slow src="/images/slow/noise.png">`)
	cur = q
	pump_until("slow request", proc() -> bool { return count("/images/slow/noise.png") == 1 })
	pump_for(300)
	page.page_close(q)
	cur = nil
	pump_until("cut", proc() -> bool { return count("slow-aborted") == 1 }, 5)
	check(count("slow-aborted") == 1, "closing the page cut the download")
	pump_until("idle", proc() -> bool { return fetch.in_flight(&loader) == 0 }, 5)
	check(fetch.in_flight(&loader) == 0, "no request left")

	s := open_page(testenv.url(SITE + "/site/again.html"), `<!doctype html><img id=again src="/images/f/red.png">`)
	cur = s
	pump_until("shared", proc() -> bool { return page.image_view(cur, node("again")).state == .Ready })
	check(page.image_view(s, node("again")).state == .Ready && count("/images/f/red.png") == 1, "another page of the site takes the cached image: no request")
	check(page.images_stats(s).shared == 1, "counted as shared")
	page.page_close(s)
	o := open_page(testenv.url("http://localhost:8765/site/other.html"), `<!doctype html><img id=again src="/images/f/red.png">`)
	cur = o
	pump_until("other site", proc() -> bool { return page.image_view(cur, node("again")).state == .Ready })
	check(count("/images/f/red.png") == 2, "another top-level site does not see the cache of the first: it downloads")
	csp := page.page_create(&loop, &loader, &settings, process, testenv.url(SITE + "/site/csp.html"), console)
	page.apply_response_headers(csp, {"img-src 'none'"}, nil, "")
	page.load_html(csp, transmute([]byte)string(`<!doctype html><img id=again src="/images/f/red.png">`))
	page.page_close(o)
	cur = csp
	pump_until("csp", proc() -> bool { return page.image_view(cur, node("again")).state == .Broken })
	check(page.image_view(csp, node("again")).state == .Broken && page.images_stats(csp).shared == 0, "img-src 'none': the cached image is not handed over, the request is blocked")
	page.page_close(csp)
	cur = nil

	////////////////////////////////
	fmt.println("-- 200 images of 1 megapixel")
	b := strings.builder_make()
	strings.write_string(&b, "<!doctype html><body>")
	for i in 0 ..< 200 { fmt.sbprintf(&b, `<img id=g%d src="/images/gen?w=1000&h=1000&seed=%d">`, i, i) }
	big := open_page(testenv.url(SITE + "/site/many.html"), strings.to_string(b))
	strings.builder_destroy(&b)
	cur = big
	longest_turn = 0
	before := images.decoder_stats()
	t_start := time.tick_now()
	pump_until("200 sizes", proc() -> bool {
		for i in 0 ..< 200 { if page.image_view(cur, node(fmt.tprintf("g%d", i))).state != .Ready { return false } }
		return true
	}, 60)
	loaded_ms := time.duration_milliseconds(time.tick_since(t_start))
	ids := make([]u64, 200)
	for i in 0 ..< 200 { ids[i] = page.image_view(big, node(fmt.tprintf("g%d", i))).id }
	// the painter scrolling down the page: each frame shows a few images at their natural size
	k := 0
	start = time.tick_now()
	for k < 200 && time.duration_seconds(time.tick_since(start)) < 60 {
		page.images_paint_begin()
		shown := true
		for id in ids[k:min(k + 20, 200)] { if !page.frame_pixels(id, now, 1000, 1000).ok { shown = false } }
		if shown { k += 20 }
		turn()
	}
	check(k >= 200, "every image was shown")
	decoded_ms := time.duration_milliseconds(time.tick_since(t_start))
	after := images.decoder_stats()
	st := page.images_stats(big)
	fmt.printf("  sizes known after %.0f ms, every image decoded once after %.0f ms (%d jobs, %.0f ms of decoding on %d threads, longest %.1f ms)\n",
		loaded_ms, decoded_ms, after.jobs - before.jobs, after.busy_ms - before.busy_ms, images.decoder_threads(), after.longest_ms)
	fmt.printf("  cache: %d entries, %d MiB of %d MiB; longest UI turn %.1f ms\n", st.entries, st.bytes >> 20, st.limit >> 20, longest_turn)
	check(after.decoded - before.decoded >= 400, "200 probes and 200 decodes, on the decoding threads")
	check(st.bytes <= st.limit + (100 << 20), "the cache stays near its limit: pixels of images no longer shown are dropped")
	// (the longest UI turn above is a measure, not a check: a slow or busy machine would fail it without a regression;
	// that decoding stays off the UI thread is what the decoder statistics check)
	delete(ids)
	page.page_close(big)
	cur = nil

	pump_for(50)
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
	delete(events)
	delete(html); delete(image)
	failures += testenv.mem_check("imagestest")
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures)
}
