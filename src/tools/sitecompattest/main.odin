// End-to-end tests of what real sites do that the unit tests of one package do not see, each a reduced fixture of a site
// that rendered wrong (the first: clockin.sacha.house, an Angular + Tailwind application): stylesheet loading tricks
// (<link media=print onload="this.media='all'">), load / error events of <link>. Needs build\testserver.exe on
// the run's block of ports (src/tools/testenv; tools\test_all.ps1 starts it). From the repository root:
//   sitecompattest.exe
package sitecompattest

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:js"
import lay "wb:layout"
import "wb:net"
import "wb:page"
import "wb:tools/testenv"
import "wb:wasm"

failures: int
logs: [dynamic]string

logs_clear :: proc() {
	for l in logs { delete(l) }
	clear(&logs)
}

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

console :: proc(user: rawptr, level: page.Log_Level, message: string) {
	append(&logs, strings.clone(message))
	fmt.printf("  [%v] %s\n", level, message)
}

logged :: proc(text: string) -> bool {
	for l in logs { if l == text { return true } }
	return false
}

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings
process:  ^base.Scope

BASE :: "http://127.0.0.1:8765/sitecompat/test.html"
WAIT_FAIL_MS :: 60_000

wait_for :: proc(text: string) -> bool {
	start := time.tick_now()
	for !logged(text) {
		if time.duration_milliseconds(time.tick_since(start)) > WAIT_FAIL_MS { return false }
		host.loop_wait(&loop, 5)
	}
	return true
}

enc :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	hex := "0123456789ABCDEF"
	for c in transmute([]u8)s {
		switch {
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~':
			strings.write_byte(&sb, c)
		case:
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, hex[c >> 4])
			strings.write_byte(&sb, hex[c & 15])
		}
	}
	return strings.to_string(sb)
}

// A stylesheet served by the test server (after `ms`), with this text.
css_url :: proc(text: string, ms := 0, status := 0) -> string {
	return fmt.tprintf("/jsload/gen?ms=%d&type=text/css&status=%d&code=%s", ms, status, enc(text))
}

PRELUDE :: `<script>function log(s) { console.log(String(s)) }</script>`

load :: proc(source: string) -> ^page.Page {
	logs_clear()
	p := page.page_create(&loop, &loader, &settings, process, testenv.url(BASE), console)
	page.load_html(p, transmute([]byte)source)
	page.scripts_start(p)
	return p
}

main :: proc() {
	context = testenv.context_of_process()
	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	wasm.configure_from_args(os.args[1:])
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }
	js.cache_start({memory_bytes = 64 << 20, min_source_bytes = 0})
	process = base.scope_make("process")

	test_link_events()
	test_print_media_swap()
	test_scroll_events()

	base.scope_close(process)
	host.blocking_settle(&blocking)
	page.process_shutdown()
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	host.loop_destroy(&loop)
	page.settings_destroy(&settings)
	logs_clear()
	delete(logs)
	failures += testenv.mem_check("sitecompattest")
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures > 0 ? 1 : 0)
}

// The width of #t as styled now (the page's styles at a desktop viewport), through getComputedStyle.
probe_width :: proc(p: ^page.Page, tag: string) {
	page.styles(p, 1280, 720, 1)
	page.js_run(p, transmute([]byte)fmt.tprintf(`log("%s " + getComputedStyle(document.getElementById("t")).width)`, tag), "probe.js")
}

test_link_events :: proc() {
	fmt.println("-- <link rel=stylesheet>: load and error events")
	src := strings.concatenate({`<!doctype html><head>`, PRELUDE,
		`<link id=ok rel=stylesheet href="`, css_url("p { color: red }", 30), `" onload="log('ok load ' + (event.target === this))" onerror="log('ok error')">`,
		`<link id=bad rel=stylesheet href="`, css_url("p {}", 0, 404), `" onload="log('bad load')" onerror="log('bad error')">`,
		`</head><body><script>
document.getElementById("ok").addEventListener("load", e => log("listener load " + e.bubbles + " " + e.cancelable));
window.addEventListener("load", () => log("window load"));
</script></body>`}, context.temp_allocator)
	p := load(src)
	wait_for("window load")
	wait_for("bad error")
	check(logged("ok load true"), "a loaded stylesheet fires load at its <link> (onload attribute, this = the element)")
	check(logged("listener load false false"), "load does not bubble and cannot be cancelled")
	check(logged("bad error") && !logged("bad load"), "an HTTP error fires error, not load")
	check(!logged("ok error"), "a loaded stylesheet does not fire error")
	page.page_close(p)

	// inserted by a script into a page that is never styled (no window): loads, and fires its events, all the same
	src2 := strings.concatenate({`<!doctype html><head>`, PRELUDE, `</head><body><script>
function add(name, href) {
  const l = document.createElement("link");
  l.rel = "stylesheet"; l.href = href;
  l.onload = () => log(name + " load"); l.onerror = () => log(name + " error");
  document.head.appendChild(l);
}
add("dyn", "`, css_url("p { color: red }"), `");
add("404", "`, css_url("p {}", 0, 404), `");
add("mime", "/jsload/gen?type=text/plain&code=p%7B%7D");
add("scheme", "nonexistent:stylesheet.css");
add("imp", "`, css_url(fmt.tprintf("@import '%s'; p {}", css_url("b { color: blue }", 300))), `");
add("impbad", "`, css_url(fmt.tprintf("@import '%s'; p {}", css_url("b {}", 0, 404))), `");
</script></body>`}, context.temp_allocator)
	p2 := load(src2)
	for name in ([]string{"dyn load", "404 error", "mime error", "scheme error", "imp load", "impbad error"}) { wait_for(name) }
	check(logged("dyn load") && !logged("dyn error"), "a <link> a script inserts loads without the page being styled")
	check(logged("404 error"), "and an HTTP error fires error")
	check(logged("mime error") && !logged("mime load"), "a stylesheet served as text/plain (standards mode) fires error")
	check(logged("scheme error"), "a URL that cannot be fetched fires error")
	imp_at, base_at := -1, -1
	for l, i in logs { if l == "imp load" { imp_at = i }; if l == "dyn load" { base_at = i } }
	check(imp_at > base_at && base_at >= 0, "load waits for the sheet's @import")
	check(logged("impbad error") && !logged("impbad load"), "a failed @import makes it error")
	page.page_close(p2)
}

test_print_media_swap :: proc() {
	fmt.println("-- <link media=print onload=\"this.media='all'\"> (the non-blocking stylesheet pattern)")
	src := strings.concatenate({`<!doctype html><head>`, PRELUDE,
		`<link rel=stylesheet href="`, css_url("#t { width: 123px }", 30), `" media="print" onload="this.media='all'; log('swapped')">`,
		`<link id=late rel=stylesheet href="`, css_url("#t { height: 7px }", 300), `" media="print">`,
		`</head><body><div id=t></div></body>`}, context.temp_allocator)
	p := load(src)
	wait_for("swapped")
	probe_width(p, "after swap")
	wait_for("after swap 123px")
	check(logged("after swap 123px"), "a loaded print sheet applies once its media becomes all")

	// the media changes while the sheet is still loading: the sheet comes with the new media
	page.js_run(p, transmute([]byte)string(`document.getElementById("late").media = "all"; log("late set")`), "probe.js")
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < 1000 { host.loop_wait(&loop, 5) }
	page.styles(p, 1280, 720, 1)
	page.js_run(p, transmute([]byte)string(`log("late " + getComputedStyle(document.getElementById("t")).height)`), "probe.js")
	check(logged("late 7px"), "a media changed while the sheet loads applies when it arrives")

	page.js_run(p, transmute([]byte)string(`document.querySelector("link").media = "print"`), "probe.js")
	probe_width(p, "back to print")
	back := ""
	for l in logs { if strings.has_prefix(l, "back to print ") { back = l } }
	check(back != "" && back != "back to print 123px", "and stops applying when the media becomes print again")
	page.page_close(p)
}

////////////////////////////////
// Scroll events (src/page/scroll_events.odin): a virtual list (clockin's history: Angular CDK) renders its rows from them

VIEW_W :: 800
VIEW_H :: 600

Layout_Host :: struct {
	l:      lay.Layout,
	set:    lay.Settings,
	scroll: [2]f64,
}

fake_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> lay.Font { return lay.Font(1) }
fake_width :: proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(strings.rune_count(text)) }
fake_metrics :: proc(user: rawptr, f: lay.Font, size: f32) -> lay.Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

layout_update :: proc(user: rawptr, p: ^page.Page) -> ^lay.Layout {
	lh := (^Layout_Host)(user)
	st := page.styles(p, VIEW_W, VIEW_H, 1)
	lay.run(&lh.l, lay.Input{doc = p.doc, styled = st, settings = &lh.set, text = {font = fake_font, width = fake_width, metrics = fake_metrics}, viewport = {VIEW_W, VIEW_H}, scale = 1, band_h = 256})
	return &lh.l
}

layout_viewport :: proc(user: rawptr, p: ^page.Page) -> page.Viewport {
	lh := (^Layout_Host)(user)
	return page.Viewport{width = VIEW_W, height = VIEW_H, scale = 1, scroll_x = lh.scroll[0], scroll_y = lh.scroll[1]}
}

layout_scroll :: proc(user: rawptr, p: ^page.Page, x, y: f64, smooth: bool) {
	lh := (^Layout_Host)(user)
	lh.scroll = {0, clamp(y, 0, max(0, f64(lh.l.height) - VIEW_H))}
}

// One rendering update, as the shell runs one for each frame it paints.
frame :: proc(p: ^page.Page) {
	page.run_animation_frames(p, f64(host.now_ns(&loop)) / 1e6)
	for _ in 0 ..< 20 { host.loop_wait(&loop, 1) }
}

count_logged :: proc(text: string) -> int {
	n := 0
	for l in logs { if l == text { n += 1 } }
	return n
}

test_scroll_events :: proc() {
	fmt.println("-- scroll events: per frame, whatever scrolled (script, wheel, keys), elements and the document")
	lh := new(Layout_Host)
	defer { lay.destroy(&lh.l); free(lh) }
	lh.set = lay.settings_default()
	logs_clear()
	p := page.page_create(&loop, &loader, &settings, process, testenv.url(BASE), console)
	page.set_page_visible(p, true)
	page.set_layout_embedder(p, {user = lh, update = layout_update, viewport = layout_viewport, scroll_to = layout_scroll})
	page.load_html(p, transmute([]byte)string(`<!doctype html><body style="margin:0"><script>function log(s) { console.log(String(s)) }</script>
<div id=vp style="height:100px;overflow:auto"><div style="height:5000px">x</div></div><div style="height:3000px"></div>
<script>
const vp = document.getElementById("vp");
vp.addEventListener("scroll", e => log("vp scroll " + vp.scrollTop + " " + e.bubbles + " " + e.cancelable));
document.body.addEventListener("scroll", () => log("body saw it"));
document.addEventListener("scroll", e => log("document scroll " + e.bubbles + " " + (e.target === document)));
window.addEventListener("scroll", () => log("window scroll " + Math.round(scrollY)));
log("ready");
</script></body>`))
	page.scripts_start(p)
	wait_for("ready")
	frame(p)
	check(count_logged("vp scroll 0 false false") == 0 && !logged("document scroll true true"), "no event before anything scrolled")

	page.js_run(p, transmute([]byte)string(`vp.scrollTop = 150; vp.scrollTop = 300; log("set " + vp.scrollTop)`), "probe.js")
	check(logged("set 300") && count_logged("vp scroll 300 false false") == 0, "setting scrollTop fires nothing synchronously")
	check(page.wants_animation_frame(p), "the page wants a frame for it")
	frame(p)
	check(count_logged("vp scroll 300 false false") == 1, "the next frame fires one scroll event at the element (not bubbling, not cancelable)")
	check(!logged("body saw it"), "an element's scroll event does not bubble")
	frame(p)
	check(count_logged("vp scroll 300 false false") == 1, "nothing more while it stays put")

	// the user scrolls the container (the shell moves the layout's offset: wheel, keys, scroll bar)
	lay.set_scroll(&lh.l, dom.find_by_id(p.doc, "vp"), {0, 1200})
	frame(p)
	check(logged("vp scroll 1200 false false"), "a scroll by the user fires it too")

	// and the page itself
	page.js_run(p, transmute([]byte)string(`window.scrollTo(0, 500)`), "probe.js")
	frame(p)
	check(logged("document scroll true true") && logged("window scroll 500"), "the document's scroll event bubbles to the window")
	lh.scroll = {0, 900}
	frame(p)
	check(logged("window scroll 900"), "the user scrolling the page fires it")
	page.page_close(p)
}