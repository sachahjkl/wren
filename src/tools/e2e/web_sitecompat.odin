#+build windows
#+private file
// What real sites do that the unit tests of one package do not see, each a reduced fixture of a site that rendered wrong (the first:
// clockin.sacha.house, an Angular + Tailwind application): stylesheet loading tricks (<link media=print onload="this.media='all'">),
// load / error events of <link>, the scroll events a virtual list renders its rows from (clockin's history: Angular CDK), the
// document's horizontal scroll as scripts see it. The fixtures say what they saw with wrenTest.note, through their log().
package e2e_scenarios

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:host"
import lay "wb:layout"
import "wb:page"
import "wb:tools/testenv"
import "wb:tools/testhost"

BASE :: "http://127.0.0.1:8765/sitecompat/test.html"
VIEW_W :: 800                 // the viewport of what is laid out
VIEW_H :: 600
DESKTOP_W :: 1280             // of what is only styled
DESKTOP_H :: 720
BAND_H :: 256
SHEET_MS :: 30                // a stylesheet that takes some time
IMPORT_MS :: 300              // an @import that takes more than what it is compared with
HEX := "0123456789ABCDEF"

noted :: proc(pr: ^Probe, text: string) -> bool { return testhost.noted(&pr.section, text) }

count_noted :: proc(pr: ^Probe, text: string) -> int {
	n := 0
	for l in pr.section.notes { if l == text { n += 1 } }
	return n
}

index_noted :: proc(pr: ^Probe, text: string) -> int {
	for l, i in pr.section.notes { if l == text { return i } }
	return -1
}

last_noted_with :: proc(pr: ^Probe, prefix: string) -> string {
	#reverse for l in pr.section.notes { if strings.has_prefix(l, prefix) { return l } }
	return ""
}

enc :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		switch {
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~':
			strings.write_byte(&sb, c)
		case:
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, HEX[c >> 4])
			strings.write_byte(&sb, HEX[c & 15])
		}
	}
	return strings.to_string(sb)
}

// A stylesheet served by the test server (after `ms`), with this text.
css_url :: proc(text: string, ms := 0, status := 0) -> string {
	return fmt.tprintf("/jsload/gen?ms=%d&type=text/css&status=%d&code=%s", ms, status, enc(text))
}

PRELUDE :: `<script>function log(s) { wrenTest.note(String(s)) }</script>`

load :: proc(t: ^testing.T, name, source: string) -> ^Probe { return open_page(t, name, source, testenv.url(BASE)) }

// The width of #t as styled now (the page's styles at a desktop viewport), through getComputedStyle.
probe_width :: proc(pr: ^Probe, tag: string) {
	page.styles(pr.p, DESKTOP_W, DESKTOP_H, 1)
	run(pr, fmt.tprintf(`log("%s " + getComputedStyle(document.getElementById("t")).width)`, tag))
}

@(test)
sitecompat_link_load_and_error_events :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	src := strings.concatenate({`<!doctype html><head>`, PRELUDE,
		`<link id=ok rel=stylesheet href="`, css_url("p { color: red }", SHEET_MS), `" onload="log('ok load ' + (event.target === this))" onerror="log('ok error')">`,
		`<link id=bad rel=stylesheet href="`, css_url("p {}", 0, 404), `" onload="log('bad load')" onerror="log('bad error')">`,
		`</head><body><script>
document.getElementById("ok").addEventListener("load", e => log("listener load " + e.bubbles + " " + e.cancelable));
window.addEventListener("load", () => log("window load"));
</script></body>`}, context.temp_allocator)
	pr := load(t, "link events", src)
	wait_note(pr, "window load")
	wait_note(pr, "bad error")
	check(pr, noted(pr, "ok load true"), "a loaded stylesheet fires load at its <link> (onload attribute, this = the element)")
	check(pr, noted(pr, "listener load false false"), "load does not bubble and cannot be cancelled")
	check(pr, noted(pr, "bad error") && !noted(pr, "bad load"), "an HTTP error fires error, not load")
	check(pr, !noted(pr, "ok error"), "a loaded stylesheet does not fire error")
	close_page(pr, min_checks = 4)
}

// Inserted by a script into a page that is never styled (no window): loads, and fires its events, all the same.
@(test)
sitecompat_link_inserted_by_a_script :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	src := strings.concatenate({`<!doctype html><head>`, PRELUDE, `</head><body><script>
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
add("imp", "`, css_url(fmt.tprintf("@import '%s'; p {}", css_url("b { color: blue }", IMPORT_MS))), `");
add("impbad", "`, css_url(fmt.tprintf("@import '%s'; p {}", css_url("b {}", 0, 404))), `");
</script></body>`}, context.temp_allocator)
	pr := load(t, "links of a script", src)
	for name in ([]string{"dyn load", "404 error", "mime error", "scheme error", "imp load", "impbad error"}) { wait_note(pr, name) }
	check(pr, noted(pr, "dyn load") && !noted(pr, "dyn error"), "a <link> a script inserts loads without the page being styled")
	check(pr, noted(pr, "404 error"), "and an HTTP error fires error")
	check(pr, noted(pr, "mime error") && !noted(pr, "mime load"), "a stylesheet served as text/plain (standards mode) fires error")
	check(pr, noted(pr, "scheme error"), "a URL that cannot be fetched fires error")
	imp_at, dyn_at := index_noted(pr, "imp load"), index_noted(pr, "dyn load")
	check(pr, imp_at > dyn_at && dyn_at >= 0, "load waits for the sheet's @import")
	check(pr, noted(pr, "impbad error") && !noted(pr, "impbad load"), "a failed @import makes it error")
	close_page(pr, min_checks = 6)
}

// The non-blocking stylesheet pattern.
@(test)
sitecompat_print_media_swapped_on_load :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	src := strings.concatenate({`<!doctype html><head>`, PRELUDE,
		`<link rel=stylesheet href="`, css_url("#t { width: 123px }", SHEET_MS), `" media="print" onload="this.media='all'; log('swapped')">`,
		`</head><body><div id=t></div></body>`}, context.temp_allocator)
	pr := load(t, "print media swap", src)
	wait_note(pr, "swapped")
	probe_width(pr, "after swap")
	check(pr, wait_note(pr, "after swap 123px"), "a loaded print sheet applies once its media becomes all")
	run(pr, `document.querySelector("link").media = "print"`)
	probe_width(pr, "back to print")
	back := last_noted_with(pr, "back to print ")
	check(pr, back != "" && back != "back to print 123px", "and stops applying when the media becomes print again")
	close_page(pr, min_checks = 2)
}

// The media changes while the sheet is still loading (nothing of the loop has run since the page was made): the sheet comes with the new media.
@(test)
sitecompat_media_changed_while_the_sheet_loads :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	src := strings.concatenate({`<!doctype html><head>`, PRELUDE,
		`<link id=late rel=stylesheet href="`, css_url("#t { height: 7px }", SHEET_MS), `" media="print" onload="log('arrived')">`,
		`</head><body><div id=t></div></body>`}, context.temp_allocator)
	pr := load(t, "media changed while loading", src)
	run(pr, `document.getElementById("late").media = "all"`)
	wait_note(pr, "arrived")
	page.styles(pr.p, DESKTOP_W, DESKTOP_H, 1)
	run(pr, `log("late " + getComputedStyle(document.getElementById("t")).height)`)
	check(pr, noted(pr, "late 7px"), "a media changed while the sheet loads applies when it arrives")
	close_page(pr, min_checks = 1)
}

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
	lay.run(&lh.l, lay.Input{doc = p.doc, styled = st, settings = &lh.set, text = {font = fake_font, width = fake_width, metrics = fake_metrics}, viewport = {VIEW_W, VIEW_H}, scale = 1, band_h = BAND_H})
	return &lh.l
}

layout_viewport :: proc(user: rawptr, p: ^page.Page) -> page.Viewport {
	lh := (^Layout_Host)(user)
	return page.Viewport{width = VIEW_W, height = VIEW_H, scale = 1, scroll_x = lh.scroll[0], scroll_y = lh.scroll[1]}
}

layout_scroll :: proc(user: rawptr, p: ^page.Page, x, y: f64, smooth: bool) {
	lh := (^Layout_Host)(user)
	lo, hi := lay.doc_scroll_x_range(&lh.l, VIEW_W)
	lo_y, hi_y := lay.doc_scroll_y_range(&lh.l, VIEW_H)
	lh.scroll = {clamp(x, f64(lo), f64(hi)), clamp(y, f64(lo_y), f64(hi_y))}
	lay.set_doc_scroll_x(&lh.l, f32(lh.scroll[0]))
}

// A page that is laid out, visible, as under a shell; ready.
open_laid_out :: proc(t: ^testing.T, lh: ^Layout_Host, name, source: string) -> ^Probe {
	lh.set = lay.settings_default()
	pr := page_make(t, name, testenv.url(BASE))
	page.set_page_visible(pr.p, true)
	page.set_layout_embedder(pr.p, {user = lh, update = layout_update, viewport = layout_viewport, scroll_to = layout_scroll})
	page_load(pr, source)
	wait_note(pr, "ready")
	frame(pr)
	return pr
}

// One rendering update, as the shell runs one for each frame it paints.
frame :: proc(pr: ^Probe) {
	page.run_animation_frames(pr.p, f64(host.now_ns(&loop)) / 1e6)
	drain()
}

SCROLLING :: `<!doctype html><body style="margin:0"><script>function log(s) { wrenTest.note(String(s)) }</script>
<div id=vp style="height:100px;overflow:auto"><div style="height:5000px">x</div></div><div style="height:3000px"></div>
<script>
const vp = document.getElementById("vp");
vp.addEventListener("scroll", e => log("vp scroll " + vp.scrollTop + " " + e.bubbles + " " + e.cancelable));
document.body.addEventListener("scroll", () => log("body saw it"));
document.addEventListener("scroll", e => log("document scroll " + e.bubbles + " " + (e.target === document)));
window.addEventListener("scroll", () => log("window scroll " + Math.round(scrollY)));
log("ready");
</script></body>`

// Per frame, whatever scrolled (script, wheel, keys), elements and the document (src/page/scroll_events.odin).
@(test)
sitecompat_scroll_events :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	lh := new(Layout_Host)
	defer { lay.destroy(&lh.l); free(lh) }
	pr := open_laid_out(t, lh, "scroll events", SCROLLING)
	check(pr, count_noted(pr, "vp scroll 0 false false") == 0 && !noted(pr, "document scroll true true"), "no event before anything scrolled")

	run(pr, `vp.scrollTop = 150; vp.scrollTop = 300; log("set " + vp.scrollTop)`)
	check(pr, noted(pr, "set 300") && count_noted(pr, "vp scroll 300 false false") == 0, "setting scrollTop fires nothing synchronously")
	check(pr, page.wants_animation_frame(pr.p), "the page wants a frame for it")
	frame(pr)
	check(pr, count_noted(pr, "vp scroll 300 false false") == 1, "the next frame fires one scroll event at the element (not bubbling, not cancelable)")
	check(pr, !noted(pr, "body saw it"), "an element's scroll event does not bubble")
	frame(pr)
	check(pr, count_noted(pr, "vp scroll 300 false false") == 1, "nothing more while it stays put")

	// the user scrolls the container (the shell moves the layout's offset: wheel, keys, scroll bar)
	lay.set_scroll(&lh.l, dom.find_by_id(pr.p.doc, "vp"), {0, 1200})
	frame(pr)
	check(pr, noted(pr, "vp scroll 1200 false false"), "a scroll by the user fires it too")

	// and the page itself
	run(pr, `window.scrollTo(0, 500)`)
	frame(pr)
	check(pr, noted(pr, "document scroll true true") && noted(pr, "window scroll 500"), "the document's scroll event bubbles to the window")
	lh.scroll = {0, 900}
	frame(pr)
	check(pr, noted(pr, "window scroll 900"), "the user scrolling the page fires it")
	close_page(pr, min_checks = 9)
}

WIDE :: `<!doctype html><body style="margin:0"><script>function log(s) { wrenTest.note(String(s)) }</script>
<div id=wide style="width:3000px;height:3000px;position:relative"><div id=box style="position:absolute;left:1000px;top:0;width:100px;height:100px"></div></div>
<div id=fix style="position:fixed;left:10px;top:10px;width:50px;height:50px"></div>
<script>
window.addEventListener("scroll", () => log("window scroll " + scrollX));
const se = document.scrollingElement, de = document.documentElement, box = document.getElementById("box"), fix = document.getElementById("fix");
function at(what) { log(what + " " + scrollX + " " + pageXOffset + " " + se.scrollLeft + " " + de.scrollLeft + " " + box.getBoundingClientRect().left + " " + fix.getBoundingClientRect().left + " " + box.getClientRects()[0].left + " " + box.offsetLeft) }
log("sw " + se.scrollWidth + " " + de.clientWidth);
log("ready");
</script></body>`

// window.scrollX and its relatives, the scrolling element, viewport-relative rectangles, scrollIntoView, the scroll event; a fixed box stays.
@(test)
sitecompat_document_horizontal_scroll :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	lh := new(Layout_Host)
	defer { lay.destroy(&lh.l); free(lh) }
	pr := open_laid_out(t, lh, "horizontal scroll", WIDE)
	check(pr, noted(pr, "sw 3000 800"), "scrollWidth is the document's, clientWidth the viewport's")

	run(pr, `scrollTo(300, 0); at("to")`)
	check(pr, noted(pr, "to 300 300 300 300 700 10 700 1000"), "window.scrollTo moves across: offsets, rectangles (a fixed box stays), offsetLeft does not")
	frame(pr)
	check(pr, noted(pr, "window scroll 300"), "the scroll event")

	run(pr, `scrollBy(100, 0); at("by")`)
	check(pr, noted(pr, "by 400 400 400 400 600 10 600 1000"), "window.scrollBy")
	run(pr, `scroll({left: 50}); at("dict")`)
	check(pr, noted(pr, "dict 50 50 50 50 950 10 950 1000"), "window.scroll with left only")
	run(pr, `se.scrollLeft = 123; at("sl")`)
	check(pr, noted(pr, "sl 123 123 123 123 877 10 877 1000"), "scrollingElement.scrollLeft")
	run(pr, `scrollTo(100000, 0); at("end")`)
	check(pr, noted(pr, "end 2200 2200 2200 2200 -1200 10 -1200 1000"), "clamped at the right end")
	run(pr, `scrollTo(-5, 0); at("start")`)
	check(pr, noted(pr, "start 0 0 0 0 1000 10 1000 1000"), "clamped at 0")

	run(pr, `box.scrollIntoView({inline: "start", block: "nearest"}); at("siv")`)
	check(pr, noted(pr, "siv 1000 1000 1000 1000 0 10 0 1000"), "scrollIntoView, inline start")
	run(pr, `scrollTo(0, 0); box.scrollIntoView({inline: "center", block: "nearest"}); at("sivc")`)
	check(pr, noted(pr, "sivc 650 650 650 650 350 10 350 1000"), "scrollIntoView, inline center")
	run(pr, `scrollTo(0, 0); box.scrollIntoView({inline: "nearest", block: "nearest"}); at("sivn")`)
	check(pr, noted(pr, "sivn 300 300 300 300 700 10 700 1000"), "scrollIntoView, inline nearest")
	run(pr, `log("efp " + document.elementFromPoint(box.getBoundingClientRect().left + 5, 5).id)`)
	check(pr, noted(pr, "efp box"), "elementFromPoint after the scroll")
	close_page(pr, min_checks = 12)
}
