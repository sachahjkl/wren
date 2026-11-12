#+build windows
#+private file
// The DOM for JavaScript: every page of examples/jsdom is one test. Its checks go through `wrenTest`, and each page declares how many it
// makes at least: one that ends before them, or never says it is done, fails. The pages are laid out by a layout embedder of this file
// (page.set_layout_embedder) with fixed text metrics (every character 0.5 em wide), so geometry can be checked exactly. Then the checks
// that need the browser's side: nodes freed after a collection, the cost of layout readings, what the shell does (drag and drop, full
// screen, the light dismiss of popovers), and the micro-benchmarks (bench.html, measures). No server. A page alone:
//   build\e2e_test.exe -tests:jsdom_tree,jsdom_layout_page,zz_the_process_ends_with_nothing_left
package e2e_scenarios

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:forms"
import "wb:host"
import "wb:js"
import lay "wb:layout"
import "wb:page"
import "wb:style"
import "wb:tools/testhost"

PAGES_DIR :: "examples/jsdom"
ADDRESS :: "http://127.0.0.1:8765/jsdom/"
VIEW_W :: 800
VIEW_H :: 600
BAND_H :: 256
PAGE_LIMIT_MS :: int(DEFAULT_WAIT * 1000)   // the one limit of a wait: it only ends a page that fails
BENCH_LIMIT_MS :: 600_000
TOUCH_POINTS :: 5
TOUCH_PAGE_POINTS :: 10
LEFT_NODES_MAX :: 500         // what stays of leaks.html's detached nodes after a collection
LEFT_HOST_OBJECTS_MAX :: 50
LAYOUT_MUTATIONS :: 50        // layout_cost_checks's script
RESIZED_W :: 640
RESIZED_H :: 480
VIEW_EXTRA :: 100             // fullscreen_checks: how much the viewport widens
FRAME_MS :: 16
DND_CHECKS :: 98
TOUCH_CHECKS :: 6
DND_DIR :: "build/tmp"
DND_FILE :: DND_DIR + "/dnd_drop.txt"
DND_FOLDER :: DND_DIR + "/dnd_dir"
EVENTS_PREFIX :: "EVENTS "
VALUE_PREFIX :: "VALUE "

view_extra: f64   // a test widens the viewport script sees (fullscreen: the resize event)

// The layout embedder: the page's styles and a layout of the test viewport with fixed text metrics.
Layout_Host :: struct {
	l:        lay.Layout,
	set:      lay.Settings,
	scroll:   [2]f64,
	view:     [2]f64,   // the viewport the embedder reports (0: VIEW_W x VIEW_H): the resize steps' check changes it
}

layout_update :: proc(user: rawptr, p: ^page.Page) -> ^lay.Layout {
	lh := (^Layout_Host)(user)
	st := page.styles(p, VIEW_W, VIEW_H, 1)
	lay.run(&lh.l, lay.Input{doc = p.doc, styled = st, settings = &lh.set, text = FAKE_TEXT, viewport = {VIEW_W, VIEW_H}, scale = 1, band_h = BAND_H})
	return &lh.l
}

layout_viewport :: proc(user: rawptr, p: ^page.Page) -> page.Viewport {
	lh := (^Layout_Host)(user)
	w, h := lh.view[0] > 0 ? lh.view[0] : VIEW_W + view_extra, lh.view[1] > 0 ? lh.view[1] : VIEW_H
	return page.Viewport{width = w, height = h, scale = 1, scroll_x = lh.scroll[0], scroll_y = lh.scroll[1]}
}

layout_scroll :: proc(user: rawptr, p: ^page.Page, x, y: f64, smooth: bool) {
	lh := (^Layout_Host)(user)
	lo_y, hi_y := lay.doc_scroll_y_range(&lh.l, VIEW_H)
	lo, hi := lay.doc_scroll_x_range(&lh.l, lh.view[0] > 0 ? f32(lh.view[0]) : f32(VIEW_W + view_extra))
	lh.scroll = {clamp(x, f64(lo), f64(hi)), clamp(y, f64(lo_y), f64(hi_y))}
	lay.set_doc_scroll_x(&lh.l, f32(lh.scroll[0]))
}

layout_host_make :: proc() -> ^Layout_Host {
	lh := new(Layout_Host)
	lh.set = lay.settings_default()
	return lh
}

layout_host_destroy :: proc(lh: ^Layout_Host) {
	lay.destroy(&lh.l)
	free(lh)
}

// Loads a page with the harness and the layout embedder, runs its scripts, waits until it says it is done (the limit only ends a
// page that fails: nothing checked depends on the machine's speed).
open_doc :: proc(t: ^testing.T, source: string, lh: ^Layout_Host, name: string, timeout_ms := PAGE_LIMIT_MS) -> ^Probe {
	pr := page_make(t, name, strings.concatenate({ADDRESS, name}, context.temp_allocator))
	page.set_layout_embedder(pr.p, {user = lh, update = layout_update, viewport = layout_viewport, scroll_to = layout_scroll})
	page.load_html(pr.p, transmute([]byte)source, strings.has_suffix(name, ".xhtml") ? "application/xhtml+xml" : "")
	harness, err := os.read_entire_file(PAGES_DIR + "/harness.js", context.allocator)
	defer delete(harness)
	testing.expect(t, err == nil, "cannot read examples/jsdom/harness.js (run from the repository root)")
	page.js_run(pr.p, harness, "harness.js")
	page.scripts_start(pr.p)
	start := time.tick_now()
	for !pr.section.finished && time.duration_milliseconds(time.tick_since(start)) < f64(timeout_ms) {
		// rendering updates, as the shell runs them: animation frame callbacks, then intersection observations
		if page.wants_animation_frame(pr.p) { page.run_animation_frames(pr.p, now_ms()) }
		host.loop_wait(&loop, LOOP_LOOK_MS)
	}
	testhost.flush(&pr.section, t)
	return pr
}

now_ms :: proc() -> f64 { return f64(host.now_ns(&loop)) / 1e6 }

said :: proc(pr: ^Probe, text: string) -> bool { return testhost.noted(&pr.section, text) }

// Runs `probe` in the page: its checks go to the section; one that reports nothing is a failure.
probe_checks :: proc(pr: ^Probe, probe: string, what: string, loc := #caller_location) {
	before := pr.section.checks + len(pr.section.failures)
	page.js_run(pr.p, transmute([]byte)probe, "probe.js")
	reported := pr.section.checks + len(pr.section.failures) - before
	check(pr, reported > 0, fmt.tprintf("%s: the probe reported nothing", what), loc)
	testhost.flush(&pr.section, pr.t, loc)
}

// leaks.html made many detached nodes, observers, lists and wrappers and dropped them: after a collection the
// browser's side must be back near where it started.
leak_checks :: proc(pr: ^Probe) {
	p := pr.p
	js.collect(p.js.inst)
	js.collect(p.js.inst)
	// (collections also run while the page makes them: what there was before says nothing)
	nodes := p.doc.nodes.count
	check(pr, nodes < LEFT_NODES_MAX, fmt.tprintf("detached nodes, records and lists are freed once their wrappers are collected (%d left)", nodes))
	objects := p.objects.pool.count
	check(pr, objects < LEFT_HOST_OBJECTS_MAX, fmt.tprintf("live collections and observers release their host objects with their wrappers (%d left)", objects))
	run(pr, `wrenTest.note("kept " + window.keep.childNodes.length + " " + window.keepList.length)`)
	check(pr, said(pr, "kept 3 2"), "what JavaScript still references stays whole")
}

// Events the browser dispatches (as the shell does from the mouse and the keyboard): trusted, with their details,
// readable after the dispatch, through the Window.
browser_event_checks :: proc(pr: ^Probe) {
	p := pr.p
	b := dom.find_by_id(p.doc, "b")
	page.dispatch_event(p, b, dom.Event{type = "click", bubbles = true, cancelable = true, x = 15, y = 30, button = 0, mods = dom.MOD_CTRL})
	page.dispatch_event(p, p.body, dom.Event{type = "keydown", bubbles = true, cancelable = true, key = 65, text = "A", mods = dom.MOD_SHIFT})
	probe_checks(pr, `
const b = document.getElementById("b"), r = b.getBoundingClientRect();
const offx = 15 - r.left - b.clientLeft, offy = 30 - r.top - b.clientTop;
eq("a browser click: trusted MouseEvent with its details", window.seen.click, ["true,true,15,30,15", offx, offy, "0,0,true,1,true"].join(","));
eq("its details stay readable after the dispatch", window.seen.clickEvent.clientX + "," + window.seen.clickEvent.target.id, "15,b");
eq("a browser keydown reaches the window: key, code, keyCode", window.seen.key, "true,A,KeyA,65,65,true");
`, "browser events")
}

// The dialogs' light dismiss and close requests as the browser's input brings them (dialog_modal.odin): a trusted press
// and release outside an open dialog whose closedby is any close it, in it they do not, closedby none keeps it open; a
// dialog opened by its open attribute is an open dialog too; Escape asks the dialog on top to close.
dialog_dismiss_checks :: proc(pr: ^Probe) {
	p := pr.p
	click_on :: proc(p: ^page.Page, h: base.Handle) {
		page.dispatch_event(p, h, dom.Event{type = "pointerdown", bubbles = true, cancelable = true, composed = true})
		page.dispatch_event(p, h, dom.Event{type = "pointerup", bubbles = true, cancelable = true, composed = true})
	}
	state :: proc(pr: ^Probe, step: string) -> bool {
		run(pr, fmt.tprintf(`wrenTest.note("%s " + document.getElementById("dlg").open)`, step))
		return said(pr, fmt.tprintf("%s true", step))
	}
	dlg := dom.find_by_id(p.doc, "dlg")
	inside := dom.get(p.doc, dlg).first_child
	outside := dom.find_by_id(p.doc, "tbl")
	run(pr, `{ const d = document.getElementById("dlg"); d.setAttribute("closedby", "any"); d.show(); }`)
	click_on(p, inside)
	check(pr, state(pr, "IN"), "a press and release in an open dialog leave it open")
	click_on(p, outside)
	check(pr, !state(pr, "OUT"), "a press and release outside a dialog of closedby any close it")
	run(pr, `document.getElementById("dlg").setAttribute("closedby", "none"); document.getElementById("dlg").show();`)
	click_on(p, outside)
	check(pr, state(pr, "NONE"), "closedby none: it stays open")
	run(pr, `{ const d = document.getElementById("dlg"); d.close(); d.setAttribute("closedby", "any"); d.open = true; }`)
	click_on(p, outside)
	check(pr, !state(pr, "ATTR"), "a dialog its open attribute opened is light dismissed too")
	run(pr, `{ const d = document.getElementById("dlg"); d.setAttribute("closedby", "closerequest"); d.show(); }`)
	forms.key_down(page.page_forms(p), .Escape, {})
	check(pr, !state(pr, "ESC"), "Escape closes the dialog on top")
}
// Repeated readings of layout without mutations in between must not lay the page out again.
layout_cost_checks :: proc(pr: ^Probe) {
	p := pr.p
	n0 := page.layout_updates(p)
	page.js_run(p, transmute([]byte)string(`
const el = document.getElementById("box");
let s = 0;
for (let i = 0; i < 2000; i++) { s += el.offsetWidth + el.getBoundingClientRect().height; }`), "probe.js")
	n1 := page.layout_updates(p)
	check(pr, n1 - n0 <= 1, fmt.tprintf("readings without mutation reuse the layout (%d updates)", n1 - n0))
	page.js_run(p, transmute([]byte)string(`
const e2 = document.getElementById("box");
for (let i = 0; i < 50; i++) { e2.style.width = (100 + i) + "px"; void e2.offsetWidth; }`), "probe.js")
	n2 := page.layout_updates(p)
	check(pr, n2 - n1 == LAYOUT_MUTATIONS, fmt.tprintf("a reading after a mutation brings the layout up to date (%d updates)", n2 - n1))
	page.js_run(p, transmute([]byte)string(`window.scrollTo(0, 0); void document.getElementById("box").offsetWidth;`), "probe.js")
	n3 := page.layout_updates(p)
	page.js_run(p, transmute([]byte)string(`
const e3 = document.getElementById("box");
for (let i = 0; i < 50; i++) { e3.style.width = (200 + i) + "px"; void window.scrollY; void window.pageXOffset; }`), "probe.js")
	check(pr, page.layout_updates(p) == n3, "the scroll offsets at the origin ask for no layout")
}

// How many times the page said this.
said_times :: proc(pr: ^Probe, text: string, from := 0) -> int {
	n := 0
	for l in pr.section.notes[from:] { if l == text { n += 1 } }
	return n
}

// CSSOM View's resize steps (page/scroll_events.odin): a rendering update after the viewport changed size fires one
// resize at the window; the same size again fires nothing.
resize_checks :: proc(pr: ^Probe, lh: ^Layout_Host) {
	p := pr.p
	run(pr, `addEventListener("resize", () => wrenTest.note("resize " + innerWidth + "x" + innerHeight))`)
	page.run_animation_frames(p, now_ms())
	check(pr, !said(pr, "resize 800x600"), "no resize while the viewport keeps its size")
	lh.view = {RESIZED_W, RESIZED_H}
	page.run_animation_frames(p, now_ms())
	page.run_animation_frames(p, now_ms())
	n := said_times(pr, "resize 640x480")
	check(pr, n == 1, fmt.tprintf("a new viewport size fires resize once, innerWidth and innerHeight already the new ones (%d)", n))
	lh.view = {}
}

// browser.touch.expose: without a touch screen 'ontouchstart' in window (Modernizr's touch test) is false everywhere a
// page looks, the Touch* constructors are absent and maxTouchPoints is 0; with one, they are there (other handlers stay).
touch_page :: proc(t: ^testing.T, all: ^testhost.Section, on: bool) {
	probe :: `<!doctype html><body><script>wrenTest.note(["ontouchstart" in window, "ontouchend" in document, "ontouchmove" in document.body, "ontouchcancel" in document.createElementNS("http://www.w3.org/2000/svg", "svg"), "onclick" in window, "Touch" in window, "TouchEvent" in window, "TouchList" in window, navigator.maxTouchPoints, matchMedia("(any-pointer: coarse)").matches, matchMedia("(pointer: fine)").matches, matchMedia("(hover: hover)").matches].join(" ")); wrenTest.done()</script>`
	settings.js.touch_handlers, settings.js.touch_points = on, on ? TOUCH_PAGE_POINTS : 0
	caps := style.get_pointer_caps()
	if on { style.set_pointer_caps({fine = true, hover = true, any_fine = true, any_coarse = true, any_hover = true}) }
	lh := layout_host_make()
	pr := open_doc(t, probe, lh, "touch.html")
	style.set_pointer_caps(caps)
	want := on ? "true true true true true true true true 10 true true true" : "false false false false true false false false 0 false true true"
	testhost.expect(all, t, said(pr, want), fmt.tprintf("touch handlers %v: %s (%v)", on, want, pr.section.notes[:]))
	page.page_close(pr.p)
	pr.p = nil
	layout_host_destroy(lh)
	close_page(pr, script_ends = true)
}

// examples/jsdom/dnd.html: drag and drop, pointer capture and touch events as the shell drives them (src/page/
// dnd_session.odin, pointer_input.odin). The page checks its DataTransfer, constructors and files; the tool plays the
// shell (a drag from a draggable element onto a drop zone, a drag of another application with a file of this computer
// onto the zone and onto a plain element, a captured mouse pointer, a finger) and checks the events the page saw.

events_of :: proc(pr: ^Probe) -> string {
	from := len(pr.section.notes)
	run(pr, "report()")
	for l in pr.section.notes[from:] { if strings.has_prefix(l, EVENTS_PREFIX) { return l[len(EVENTS_PREFIX):] } }
	return ""
}

Value_Wait :: struct { pr: ^Probe, from: int, value: string }

wait_value :: proc(pr: ^Probe, expr: string) -> string {
	w := Value_Wait{pr = pr, from = len(pr.section.notes), value = "(no value)"}
	run(pr, strings.concatenate({`Promise.resolve(`, expr, `).then((v) => wrenTest.note("VALUE " + v), (e) => wrenTest.note("VALUE error " + e))`}, context.temp_allocator))
	wait_until(pr.t, expr, &w, proc(w: ^Value_Wait) -> bool {
		for l in w.pr.section.notes[w.from:] { if strings.has_prefix(l, VALUE_PREFIX) { w.value = l[len(VALUE_PREFIX):]; return true } }
		return false
	})
	return w.value
}

el :: proc(p: ^page.Page, sel: string) -> base.Handle {
	h, _ := page.query_first(p, sel)
	return h
}

dnd_checks :: proc(pr: ^Probe) {
	p := pr.p
	src, zone, plain, link := el(p, "#src"), el(p, "#zone"), el(p, "#plain"), el(p, "#link")
	check(pr, src != base.NIL_HANDLE && zone != base.NIL_HANDLE, "the page's elements")

	s, k := page.drag_source_for(p, src)
	check(pr, s == src && k == .Element, "draggable=\"true\" is a drag source")
	s, k = page.drag_source_for(p, link)
	check(pr, s == link && k == .Link, "a link is a drag source by default")
	s, k = page.drag_source_for(p, plain)
	check(pr, s == base.NIL_HANDLE && k == .None, "a plain element is not")

	// a drag from the page onto the zone
	check(pr, page.drag_start(p, src, .Element, 10, 10, 0), "dragstart not cancelled: the drag starts")
	op, ok := page.drag_update(p, plain, 50, 60, 0)
	check(pr, ok && op == .None, "over an element that does not take it: no operation")
	op, ok = page.drag_update(p, zone, 50, 120, 0)
	check(pr, ok && op == .Copy, "over the zone (dragover cancelled, dropEffect copy): copy")
	pl, allowed := page.drag_session_payload(p)
	check(pr, pl.text == "from src" && allowed == {.Copy}, "what would go to another application: the data dragstart set, effectAllowed copy")
	res := page.drag_drop(p, zone, 50, 120, 0)
	check(pr, res.handled && res.op == .Copy, "drop cancelled by the zone: handled, copy")
	page.drag_finish(p, res.op)
	check(pr, page.drag_session(p) == nil, "the session is over")
	ev := events_of(pr)
	check(pr, strings.contains(ev, "dragstart@src types= data="), "dragstart at the source (seen at capture, before its listener sets the data)")
	check(pr, strings.contains(ev, "dragenter@plain types=text/plain data= files=0"), "dragenter: protected mode (types visible, data hidden)")
	check(pr, strings.contains(ev, "dragleave@plain"), "dragleave at the element left")
	check(pr, strings.contains(ev, "dragover@zone"), "dragover at the zone")
	check(pr, strings.contains(ev, "drop@zone types=text/plain data=from src"), "drop: read-only mode, the data readable")
	check(pr, strings.contains(ev, "dragend@src"), "dragend at the source")
	check(pr, !strings.contains(ev, "drag@") || strings.index(ev, "drag@src") > strings.index(ev, "dragstart@src"), "drag at the source after dragstart")

	// another application's drag with a file of this computer
	_ = os.make_directory_all(DND_DIR)
	_ = os.write_entire_file(DND_FILE, transmute([]byte)string("hello file"))
	abs, _ := os.get_absolute_path(DND_FILE, context.temp_allocator)
	page.drag_external_begin(p, page.Drag_Payload{files = []string{abs}, text = "outside"}, {.Copy, .Link})
	op, ok = page.drag_update(p, zone, 50, 120, 0)
	check(pr, ok && op == .Copy, "an outside drag over the zone: copy")
	res = page.drag_drop(p, zone, 50, 120, 0)
	page.drag_finish(p, res.op)
	check(pr, res.handled, "the zone took the outside drop: the browser does not open the file")
	check(pr, wait_value(pr, "window.dropped") == "hello file|ell|dnd_drop.txt|text/plain|10", "the dropped File: its text, a slice read alone, name, type, size")
	ev = events_of(pr)
	check(pr, strings.contains(ev, "dragenter@zone types=text/plain|Files data= files=0"), "outside drag: protected mode, Files in types, no file yet")
	check(pr, strings.contains(ev, "drop@zone types=text/plain|Files data=outside files=1"), "outside drop: the text and the file")

	page.drag_external_begin(p, page.Drag_Payload{files = []string{abs}}, {.Copy})
	op, _ = page.drag_update(p, plain, 50, 60, 0)
	res = page.drag_drop(p, plain, 50, 60, 0)
	page.drag_finish(p, res.op)
	check(pr, op == .None && !res.handled, "dropped where nothing takes it: not handled (the browser opens the file)")
	events_of(pr)

	// pointer capture of the mouse
	page.pointer_mouse_held(p, true)
	proto := dom.Event{type = "pointerdown", bubbles = true, cancelable = true, composed = true, x = 5, y = 70, buttons = 1}
	page.pointer_capture_process(p, page.MOUSE_POINTER_ID, proto)
	page.dispatch_event(p, plain, proto)   // its listener calls setPointerCapture
	check(pr, page.pointer_target(p, page.MOUSE_POINTER_ID, zone) == zone, "the capture waits for the pointer's next event")
	mv := proto
	mv.type = "pointermove"
	page.pointer_capture_process(p, page.MOUSE_POINTER_ID, mv)
	check(pr, page.pointer_target(p, page.MOUSE_POINTER_ID, zone) == plain, "then the pointer's events go to the capturing element")
	up := proto
	up.type, up.buttons = "pointerup", 0
	page.dispatch_event(p, page.pointer_target(p, page.MOUSE_POINTER_ID, zone), up)
	page.pointer_up(p, page.MOUSE_POINTER_ID, up)
	page.pointer_mouse_held(p, false)
	check(pr, page.pointer_target(p, page.MOUSE_POINTER_ID, zone) == zone, "released after pointerup")
	ev = events_of(pr)
	check(pr, strings.contains(ev, "gotpointercapture@plain id=1 type=mouse"), "gotpointercapture at the element")
	check(pr, strings.contains(ev, "pointerup@plain"), "pointerup retargeted to it")
	check(pr, strings.contains(ev, "lostpointercapture@plain"), "lostpointercapture after the release")

	// a finger
	t1 := page.Touch_Point{id = 9, target = zone, x = 30, y = 110}
	check(pr, page.touch_dispatch(p, .Start, t1, 0, {}), "touchstart not cancelled")
	t1.x = 40
	page.touch_dispatch(p, .Move, t1, 0, {})
	page.touch_dispatch(p, .End, t1, 0, {})
	ev = events_of(pr)
	check(pr, strings.contains(ev, "touchstart@zone touches=1 changed=1 id=9 x=30"), "touchstart with the finger in touches and changedTouches")
	check(pr, strings.contains(ev, "touchmove@zone touches=1 changed=1 id=9 x=40"), "touchmove at the element the touch began on")
	check(pr, strings.contains(ev, "touchend@zone touches=0 changed=1 id=9"), "touchend: the finger only in changedTouches")

	dnd_default_checks(pr, abs)
	dnd_entries_checks(pr)
	dnd_image_checks(pr)
}

field_value :: proc(p: ^page.Page, h: base.Handle) -> string { return forms.edit_text(page.page_forms(p), h) }

// The browser's default of an uncancelled drop: text moved between fields (deleteByDrag, then insertFromDrop where the
// caret is), copied with Ctrl, refused by a cancelled beforeinput, inserted into contenteditable; files into a file input
// (its accept, not multiple), a disabled one refusing them.
dnd_default_checks :: proc(pr: ^Probe, file_path: string) {
	p := pr.p
	text, area, ce, file2, filedis := el(p, "#text"), el(p, "#area"), el(p, "#ce"), el(p, "#file2"), el(p, "#filedis")
	f := page.page_forms(p)
	forms.set_value(f, text, "hello world")
	forms.set_value(f, area, "[]")
	events_of(pr)

	// a selection of #text moved into #area, between the brackets
	check(pr, page.drag_start(p, text, .Selection, 5, 5, 0, "hello"), "a field's selection starts a drag")
	page.drag_set_source_field(p, text, 0, 5)
	op, ok := page.drag_update(p, area, 20, 20, 0)
	check(pr, ok && op == .Move, "selected text over another field: a move")
	page.drag_set_caret(p, page.Drop_Caret{node = area, field = true, offset = 1})
	c, has := page.drag_caret(p)
	check(pr, has && c.offset == 1, "the drop caret follows the pointer")
	res := page.drag_drop(p, area, 20, 20, 0)
	page.drag_finish(p, res.op)
	check(pr, res.handled && res.op == .Move, "the browser handled the drop: moved")
	check(pr, field_value(p, text) == " world", fmt.tprintf("deleted from the source field (%q)", field_value(p, text)))
	check(pr, field_value(p, area) == "[hello]", fmt.tprintf("inserted at the caret (%q)", field_value(p, area)))
	a, b, _ := forms.selection(f, area)
	check(pr, a == 1 && b == 6, "the dropped text is selected")
	ev := events_of(pr)
	order := []string{"drop@area", "beforeinput@text deleteByDrag", "input@text deleteByDrag", "beforeinput@area insertFromDrop data=hello", "input@area insertFromDrop data=hello", "dragend@text"}
	at := 0
	missing := ""
	for s in order {
		i := strings.index(ev[at:], s)
		if i < 0 { missing = s; break }
		at += i + len(s)
	}
	check(pr, missing == "", fmt.tprintf("drop, deleteByDrag at the source, insertFromDrop at the target, dragend last (missing %q in %s)", missing, ev))

	// Ctrl copies
	forms.set_value(f, text, "abc")
	forms.set_value(f, area, "")
	page.drag_start(p, text, .Selection, 5, 5, dom.MOD_CTRL, "abc")
	page.drag_set_source_field(p, text, 0, 3)
	op, _ = page.drag_update(p, area, 20, 20, dom.MOD_CTRL)
	check(pr, op == .Copy, "Ctrl: a copy")
	res = page.drag_drop(p, area, 20, 20, dom.MOD_CTRL)
	page.drag_finish(p, res.op)
	check(pr, field_value(p, text) == "abc" && field_value(p, area) == "abc", "copied: the source keeps its text")
	events_of(pr)

	// a cancelled beforeinput: nothing inserted
	page.js_run(p, transmute([]byte)string("blockInsert = true"), "probe.js")
	page.drag_external_begin(p, page.Drag_Payload{text = "zz"}, {.Copy})
	page.drag_update(p, area, 20, 20, 0)
	res = page.drag_drop(p, area, 20, 20, 0)
	page.drag_finish(p, res.op)
	check(pr, field_value(p, area) == "abc" && res.op == .None, "beforeinput insertFromDrop cancelled: the field keeps its text")
	page.js_run(p, transmute([]byte)string("blockInsert = false"), "probe.js")
	events_of(pr)

	// contenteditable: the text spliced in where the caret is
	tn := dom.get(p.doc, ce).first_child
	page.drag_external_begin(p, page.Drag_Payload{text = "XY"}, {.Copy, .Move})
	op, _ = page.drag_update(p, ce, 20, 20, 0)
	check(pr, op == .Copy, "text from another application over contenteditable: a copy")
	page.drag_set_caret(p, page.Drop_Caret{node = ce, pos = {tn, 2}})
	res = page.drag_drop(p, ce, 20, 20, 0)
	page.drag_finish(p, res.op)
	check(pr, dom.get(p.doc, tn).text == "abXYcd", fmt.tprintf("inserted into the editing host (%q)", dom.get(p.doc, tn).text))
	ev = events_of(pr)
	check(pr, strings.contains(ev, "beforeinput@ce insertFromDrop data=XY") && strings.contains(ev, "input@ce insertFromDrop"), "beforeinput / input insertFromDrop at the editing host")

	// files: a .txt and a .bin onto an input that takes .txt and images, one file
	bin := strings.concatenate({file_path[:len(file_path) - 4], ".bin"}, context.temp_allocator)
	_ = os.write_entire_file(bin, transmute([]byte)string("01"))
	page.drag_external_begin(p, page.Drag_Payload{files = []string{bin, file_path}}, {.Copy})
	op, _ = page.drag_update(p, file2, 20, 20, 0)
	check(pr, op == .Copy, "files over a file input: copy (the copy cursor)")
	res = page.drag_drop(p, file2, 20, 20, 0)
	page.drag_finish(p, res.op)
	list := forms.files(f, file2)
	check(pr, res.handled && len(list) == 1 && list[0].name == "dnd_drop.txt", "the input took the file its accept allows")
	ev = events_of(pr)
	check(pr, strings.contains(ev, "input@file2") && strings.contains(ev, "change@file2"), "input and change at the file input")
	page.drag_external_begin(p, page.Drag_Payload{files = []string{file_path}}, {.Copy})
	op, _ = page.drag_update(p, filedis, 20, 20, 0)
	res = page.drag_drop(p, filedis, 20, 20, 0)
	page.drag_finish(p, res.op)
	check(pr, op == .None && len(forms.files(f, filedis)) == 0, "a disabled file input refuses the drop")
	events_of(pr)
}

// webkitGetAsEntry: a dropped folder walked from JavaScript (listed and read on the background pool).
dnd_entries_checks :: proc(pr: ^Probe) {
	p := pr.p
	_ = os.make_directory_all(DND_FOLDER + "/sub")
	_ = os.write_entire_file(DND_FOLDER + "/a.txt", transmute([]byte)string("A"))
	_ = os.write_entire_file(DND_FOLDER + "/sub/b.txt", transmute([]byte)string("B"))
	dir, _ := os.get_absolute_path(DND_FOLDER, context.temp_allocator)
	page.drag_external_begin(p, page.Drag_Payload{files = []string{dir}}, {.Copy})
	page.drag_update(p, el(p, "#zone"), 50, 120, 0)
	res := page.drag_drop(p, el(p, "#zone"), 50, 120, 0)
	page.drag_finish(p, res.op)
	got := wait_value(pr, "window.entries")
	want := "D /dnd_dir true | D /dnd_dir/sub true | F /dnd_dir/a.txt a.txt A | F /dnd_dir/sub/b.txt b.txt B"
	check(pr, got == want, fmt.tprintf("a dropped folder: entries, full paths, readEntries, file() (%s)", got))
	check(pr, wait_value(pr, "window.escape") == "SecurityError", "a path out of what was dropped is refused")
	check(pr, wait_value(pr, "window.creating") == "SecurityError", "nothing is created in what was dropped")
	check(pr, wait_value(pr, "window.sub") == "/dnd_dir/sub/b.txt true", "getDirectory then getFile")
	events_of(pr)
}

// The pixels of a canvas for a drag image (straight RGBA at its size), and setDragImage's element and offset.
dnd_image_checks :: proc(pr: ^Probe) {
	p := pr.p
	cv := el(p, "#cv")
	rgba, size, _, ok := page.drag_image_pixels(p, cv, context.temp_allocator)
	check(pr, ok && size == {8, 6} && len(rgba) == 8 * 6 * 4 && rgba[0] == 255 && rgba[1] == 0 && rgba[3] == 255, "a canvas's pixels for the drag image")
	_, _, _, ok2 := page.drag_image_pixels(p, el(p, "#plain"), context.temp_allocator)
	check(pr, !ok2, "a plain element has no pixels of its own (the shell reads it from the frame)")
	page.js_run(p, transmute([]byte)string(`document.getElementById("src").addEventListener("dragstart", (e) => e.dataTransfer.setDragImage(document.getElementById("cv"), 3, 2), { once: true })`), "probe.js")
	page.drag_start(p, el(p, "#src"), .Element, 10, 10, 0)
	h, off := page.drag_session_image(p)
	check(pr, h == cv && off == {3, 2}, "setDragImage: the element and the hot spot")
	page.drag_cancel(p)
	events_of(pr)
}

// examples/jsdom/popover.html: the Popover API. The page checks what scripts can do; here the shell's part: a trusted
// click outside an auto popover hides it (light dismiss), one inside or on its invoker does not, Escape hides the
// topmost one.
popover_checks :: proc(pr: ^Probe) {
	p := pr.p
	f := page.page_forms(p)
	click :: proc(f: ^forms.Forms, p: ^page.Page, id: string) { forms.click(f, dom.find_by_id(p.doc, id), forms.Click_Info{trusted = true}) }
	page.js_run(p, transmute([]byte)string(`document.getElementById("a").showPopover(); document.getElementById("nested").showPopover(); document.getElementById("m").showPopover()`), "probe.js")
	click(f, p, "nested")
	probe_checks(pr, `eq("a click inside the nested popover keeps both", ["a", "nested"].map((id) => document.getElementById(id).matches(":popover-open")).join(), "true,true")`, "light dismiss inside")
	forms.key_down(f, .Escape, {})
	probe_checks(pr, `eq("Escape hides the topmost auto popover", ["a", "nested"].map((id) => document.getElementById(id).matches(":popover-open")).join(), "true,false")`, "close request")
	click(f, p, "outside")
	probe_checks(pr, `eq("a click outside hides the auto popovers, not the manual one", ["a", "m"].map((id) => document.getElementById(id).matches(":popover-open")).join(), "false,true")`, "light dismiss outside")
	click(f, p, "btn")
	click(f, p, "btn")
	probe_checks(pr, `eq("a trusted click on the invoker toggles it off (not dismissed, then toggled)", document.getElementById("b").matches(":popover-open"), false)`, "invoker")
}

// examples/jsdom/fullscreen.html: the Fullscreen API. The page checks what needs no gesture; the test plays the shell
// (a window that records what it is asked, and the user's clicks), runs the page's phases, and checks the browser's
// side: the window is asked to fill the screen and to go back, nested documents, a refusing window, a document that
// closes in full screen.

Window_Record :: struct {
	is_on:   bool,
	asked:   int,       // requests to fill the screen
	left:    int,       // requests to go back
	refuse:  bool,
	nav:     page.Api_FullscreenNavigation,   // of the first request
	top:     ^page.Page,
}

rec: Window_Record
ASKED_MIN :: 5
LEFT_MIN :: 4

fullscreen_prepare :: proc() {
	rec = {}
	page.the_pages.fullscreen_embedder = {set = proc(top: ^page.Page, on: bool, nav: page.Api_FullscreenNavigation) -> bool {
		if on {
			if rec.refuse { return false }
			if rec.asked == 0 { rec.nav = nav }
			rec.asked += 1
			rec.top = top
		} else {
			rec.left += 1
		}
		rec.is_on = on
		return true
	}}
}

// Runs `phase` of the page (an async function); its checks go to the section.
run_phase :: proc(pr: ^Probe, phase: string) {
	over := fmt.tprintf("%s is over", phase)
	code := strings.concatenate({`(async () => { await window.`, phase, `(); wrenTest.note("`, over, `"); })().catch((e) => { wrenTest.check(false, "`, phase,
		` threw " + (e && e.name) + ": " + (e && e.message) + " " + (e && e.stack)); wrenTest.note("`, over, `"); })`}, context.temp_allocator)
	page.js_run(pr.p, transmute([]byte)code, "probe.js")
	check(pr, wait_note(pr, over), fmt.tprintf("%s finished", phase))
	testhost.flush(&pr.section, pr.t)
}

// A click of the user in a document: it gets transient activation.
click :: proc(p: ^page.Page) {
	page.dispatch_event(p, p.body, dom.Event{type = "mousedown", bubbles = true, cancelable = true})
	page.dispatch_event(p, p.body, dom.Event{type = "mouseup", bubbles = true, cancelable = true})
	page.dispatch_event(p, p.body, dom.Event{type = "click", bubbles = true, cancelable = true})
}

said_prefix_from :: proc(pr: ^Probe, from: int, prefix: string) -> bool {
	for l in pr.section.notes[from:] { if strings.has_prefix(l, prefix) { return true } }
	return false
}

fullscreen_checks :: proc(pr: ^Probe) {
	p := pr.p
	check(pr, rec.asked == 0 && !page.fullscreen_active(p), "nothing asked the window while the page had no gesture")

	click(p)
	run_phase(pr, "phase2")
	check(pr, rec.asked >= ASKED_MIN && rec.left >= LEFT_MIN && !rec.is_on, "the window was asked to fill the screen and to go back, and ends as it was")
	check(pr, rec.nav == .Hide, "navigationUI: \"hide\" reaches the window")
	check(pr, !page.fullscreen_active(p), "no fullscreen element is left in the document")

	// two frames
	check(pr, wait_note(pr, "READY2"), "both frames loaded")
	kids := page.frames_children(p)
	check(pr, len(kids) == 2 && kids[0].page != nil && kids[1].page != nil, "two nested documents")
	if len(kids) == 2 && kids[0].page != nil && kids[1].page != nil {
		fa, fb := kids[0].page, kids[1].page
		click(fa)
		click(fb)
		run_phase(pr, "phase3")
		check(pr, page.fullscreen_active(p) && page.fullscreen_active(fa) && !page.fullscreen_active(fb), "the frame's document and its container are fullscreen, the refused frame is not")
		check(pr, rec.is_on && rec.top == p, "the window was asked for the tab's document")
		check(pr, page.fullscreen_exit(p), "the shell leaves full screen (Escape)")
		check(pr, !page.fullscreen_active(p) && !page.fullscreen_active(fa) && !rec.is_on, "... for the whole tree, the window comes back")
		check(pr, !page.fullscreen_exit(p), "... and again: nothing to leave")

		// the frame goes while it is fullscreen
		click(fa)
		check(pr, page.fullscreen_active(fa), "the frame is fullscreen again")
		page.js_run(p, transmute([]byte)string(`document.getElementById("fa").remove()`), "probe.js")
		check(pr, !page.fullscreen_active(p) && !rec.is_on, "removing the frame's container ends full screen and gives the window back")
	}

	// a window that refuses
	drain()   // (the events of the exit above)
	rec.refuse = true
	click(p)
	run_phase(pr, "phase4")
	rec.refuse = false
	check(pr, !page.fullscreen_active(p) && !rec.is_on, "a refusal leaves nothing behind")

	// a window that takes time (the shell): the events and the promise wait for fullscreen_settled
	page.the_pages.fullscreen_embedder.deferred = true
	click(p)
	run(pr, `document.addEventListener("fullscreenchange", () => wrenTest.note("CHG " + !!document.fullscreenElement));
		document.getElementById("b").requestFullscreen().then(() => wrenTest.note("PROMISE"))`)
	drain()   // (all the page's tasks ran: what is left waits for the shell)
	check(pr, page.fullscreen_waiting(p) && !said(pr, "CHG true") && !said(pr, "PROMISE"), "a deferred change: no event and no promise before the shell says the window is ready")
	check(pr, page.fullscreen_active(p), "... though the element is already the fullscreen element")
	page.fullscreen_settled(p)
	check(pr, wait_note(pr, "PROMISE") && said(pr, "CHG true") && !page.fullscreen_waiting(p), "fullscreen_settled: the event, then the promise")
	run(pr, `document.exitFullscreen().then(() => wrenTest.note("PROMISE2"))`)
	drain()
	check(pr, page.fullscreen_waiting(p) && !said(pr, "PROMISE2"), "leaving waits too")
	page.fullscreen_settled(p)
	check(pr, wait_note(pr, "PROMISE2") && said(pr, "CHG false"), "... and ends with the event and the promise")
	page.the_pages.fullscreen_embedder.deferred = false

	// the window's "resize": once per frame whose viewport differs from the last one
	from := len(pr.section.notes)
	run(pr, `window.addEventListener("resize", () => wrenTest.note("RESIZE " + innerWidth))`)
	now := now_ms()
	page.run_animation_frames(p, now)
	page.run_animation_frames(p, now + FRAME_MS)
	check(pr, !said_prefix_from(pr, from, "RESIZE "), "no resize event while the viewport keeps its size")
	view_extra = VIEW_EXTRA
	page.run_animation_frames(p, now + 2 * FRAME_MS)
	page.run_animation_frames(p, now + 3 * FRAME_MS)
	view_extra = 0
	check(pr, said_times(pr, "RESIZE 900", from) == 1, "a changed viewport fires one resize event (with the new size), not one per frame")

	// the document closes in full screen (the test closes it): the window is given back
	click(p)
	run(pr, `document.getElementById("b").requestFullscreen().then(() => wrenTest.note("FS_ON"))`)
	check(pr, wait_note(pr, "FS_ON") && rec.is_on, "full screen again before the page closes")
}

// A page's test: `prepare` is what it needs of its settings, `after` what the test checks of it then (the browser's side), `closed` once it has closed.
page_test :: proc(t: ^testing.T, name: string, checks: int, prepare: proc() = nil, after: proc(pr: ^Probe, lh: ^Layout_Host) = nil, closed: proc(pr: ^Probe) = nil, timeout_ms := PAGE_LIMIT_MS, loc := #caller_location) {
	context.allocator = base.process_allocator()
	begin(t, .Pages, loc)
	defer end()
	if prepare != nil { prepare() }
	src, err := os.read_entire_file(strings.concatenate({PAGES_DIR, "/", name}, context.temp_allocator), context.allocator)
	defer delete(src)
	testing.expectf(t, err == nil, "cannot read %s", name, loc = loc)
	lh := layout_host_make()
	pr := open_doc(t, string(src), lh, name, timeout_ms)
	if after != nil { after(pr, lh) }
	if js.memprof_wanted() { js.print_profile(pr.p.js.inst, name) }
	page.page_close(pr.p)
	pr.p = nil
	if closed != nil { closed(pr) }
	layout_host_destroy(lh)
	close_page(pr, min_checks = checks, script_ends = true, loc = loc)
}

PAGES := [?]string{
	"animations.html", "bench.html", "compat.html", "css-animations.html", "cssom.html", "custom.html", "dnd.html", "domparser-xml.html",
	"elements.html", "events.html", "fullscreen.html", "highlight.html", "html.html", "intersection.html", "layout.html", "leaks.html", "navigation.html",
	"observer.html", "popover.html", "resize.html", "scripts.html", "shadow.html", "style.html", "template_stamp.html", "traversal.html",
	"tree.html", "videoquality.html", "xhtml.xhtml", "xml.html", "xmlserializer.html",
}

// A page added to the folder gets a test: nothing is left out by accident.
@(test)
jsdom_every_page_has_a_test :: proc(t: ^testing.T) {
	infos, err := os.read_all_directory_by_path(PAGES_DIR, context.allocator)
	testing.expect(t, err == nil, "cannot read " + PAGES_DIR)
	defer os.file_info_slice_delete(infos, context.allocator)
	for fi in infos {
		if !strings.has_suffix(fi.name, ".html") && !strings.has_suffix(fi.name, ".xhtml") { continue }
		found := false
		for p in PAGES { if p == fi.name { found = true } }
		testing.expectf(t, found, "%s has no test (jsdom.odin)", fi.name)
	}
}

@(test) jsdom_animations :: proc(t: ^testing.T) { page_test(t, "animations.html", checks = 81) }
@(test) jsdom_compat :: proc(t: ^testing.T) { page_test(t, "compat.html", checks = 39) }
@(test) jsdom_highlight :: proc(t: ^testing.T) { page_test(t, "highlight.html", checks = 35) }
@(test) jsdom_css_animations :: proc(t: ^testing.T) { page_test(t, "css-animations.html", checks = 28) }
@(test) jsdom_cssom :: proc(t: ^testing.T) { page_test(t, "cssom.html", checks = 94) }
@(test) jsdom_custom :: proc(t: ^testing.T) { page_test(t, "custom.html", checks = 43) }
@(test) jsdom_domparser_xml :: proc(t: ^testing.T) { page_test(t, "domparser-xml.html", checks = 46) }
@(test) jsdom_elements :: proc(t: ^testing.T) { page_test(t, "elements.html", checks = 193) }
@(test) jsdom_html :: proc(t: ^testing.T) { page_test(t, "html.html", checks = 183, after = proc(pr: ^Probe, _: ^Layout_Host) { dialog_dismiss_checks(pr) }) }
@(test) jsdom_intersection :: proc(t: ^testing.T) { page_test(t, "intersection.html", checks = 35) }
@(test) jsdom_navigation :: proc(t: ^testing.T) { page_test(t, "navigation.html", checks = 85) }
@(test) jsdom_observer :: proc(t: ^testing.T) { page_test(t, "observer.html", checks = 25) }
@(test) jsdom_resize :: proc(t: ^testing.T) { page_test(t, "resize.html", checks = 32) }
@(test) jsdom_scripts :: proc(t: ^testing.T) { page_test(t, "scripts.html", checks = 15) }
@(test) jsdom_shadow :: proc(t: ^testing.T) { page_test(t, "shadow.html", checks = 130) }
@(test) jsdom_styles :: proc(t: ^testing.T) { page_test(t, "style.html", checks = 62) }
@(test) jsdom_template_stamp :: proc(t: ^testing.T) { page_test(t, "template_stamp.html", checks = 30) }
@(test) jsdom_traversal :: proc(t: ^testing.T) { page_test(t, "traversal.html", checks = 50) }
@(test) jsdom_tree :: proc(t: ^testing.T) { page_test(t, "tree.html", checks = 169) }
@(test) jsdom_videoquality :: proc(t: ^testing.T) { page_test(t, "videoquality.html", checks = 9) }
@(test) jsdom_xhtml :: proc(t: ^testing.T) { page_test(t, "xhtml.xhtml", checks = 10) }
@(test) jsdom_xml :: proc(t: ^testing.T) { page_test(t, "xml.html", checks = 38) }
@(test) jsdom_xmlserializer :: proc(t: ^testing.T) { page_test(t, "xmlserializer.html", checks = 11) }
// Its many nodes are one long script: past the second of the hard stop on a machine at work, and what it measures is memory.
@(private = "file") LEAKS_SLOW_SCRIPT_MS :: 120_000

@(test)
jsdom_leaks :: proc(t: ^testing.T) {
	page_test(t, "leaks.html", checks = 4, prepare = proc() { settings.js.slow_script_ms = LEAKS_SLOW_SCRIPT_MS }, after = proc(pr: ^Probe, _: ^Layout_Host) { leak_checks(pr) })
}

@(test)
jsdom_layout_page :: proc(t: ^testing.T) { page_test(t, "layout.html", checks = 43, after = proc(pr: ^Probe, lh: ^Layout_Host) { layout_cost_checks(pr); resize_checks(pr, lh) }) }

@(test)
jsdom_events :: proc(t: ^testing.T) { page_test(t, "events.html", checks = 37, after = proc(pr: ^Probe, _: ^Layout_Host) { browser_event_checks(pr) }) }

@(test)
jsdom_fullscreen :: proc(t: ^testing.T) {
	page_test(t, "fullscreen.html", checks = 83, prepare = fullscreen_prepare, after = proc(pr: ^Probe, _: ^Layout_Host) { fullscreen_checks(pr) }, closed = proc(pr: ^Probe) {
		check(pr, !rec.is_on, "closing a document in full screen gives the window back")
		page.the_pages.fullscreen_embedder = {}
	})
}

@(test)
jsdom_popover :: proc(t: ^testing.T) { page_test(t, "popover.html", checks = 42, after = proc(pr: ^Probe, _: ^Layout_Host) { popover_checks(pr) }) }

// dnd.html builds Touch and TouchEvent: a page told about a touch screen (browser.touch.expose = on).
@(test)
jsdom_dnd :: proc(t: ^testing.T) {
	page_test(t, "dnd.html", checks = DND_CHECKS, prepare = proc() { settings.js.touch_handlers, settings.js.touch_points = true, TOUCH_POINTS }, after = proc(pr: ^Probe, _: ^Layout_Host) { dnd_checks(pr) })
}

// An animation far below the viewport ticks at style.animations.unseen_tick_ms for the screen (page/animations_seen.odin); a script reads it at
// the document's time all the same. On the virtual clock: a style pass as a frame makes it (the timeline asks who sees the element, from the
// layout a reading made), then two readings 100 ms apart, inside the unseen tick: getComputedStyle and the CSSAnimation's currentTime both moved.
UNSEEN_PAGE :: `<!doctype html><style>@keyframes spin { from { transform: rotate(0deg) } to { transform: rotate(360deg) } } body { margin: 0 } #s { width: 40px; height: 40px; animation: spin 1000ms linear infinite }</style><div style="height: 20000px"></div><div id=s></div>`
UNSEEN_READ_GAP :: 100 * time.Millisecond
UNSEEN_CHECKS :: 2

@(test)
jsdom_unseen_animation_reads_the_clock :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Pages)
	defer end()
	virtual_clock(t)
	lh := layout_host_make()
	defer layout_host_destroy(lh)
	pr := page_make(t, "unseen.html", strings.concatenate({ADDRESS, "unseen.html"}, context.temp_allocator))
	page.set_layout_embedder(pr.p, {user = lh, update = layout_update, viewport = layout_viewport, scroll_to = layout_scroll})
	page_load(pr, UNSEEN_PAGE)
	drain()
	run(pr, `getComputedStyle(document.getElementById("s")).transform`)   // (the layout the probe reads)
	_ = page.styles(pr.p, VIEW_W, VIEW_H, 1)   // a frame's style pass: nobody sees #s
	check(pr, page.animations_next_ms(pr.p) > 0 && !page.animations_active(pr.p), fmt.tprintf("the animation waits for its unseen tick: next in %v ms", page.animations_next_ms(pr.p)))
	run(pr, `window.s = document.getElementById("s"); window.a = getComputedStyle(s).transform; window.c = document.getAnimations()[0].currentTime`)
	host.clock_advance(&loop, UNSEEN_READ_GAP)
	run(pr, `wrenTest.check(getComputedStyle(s).transform != a, "getComputedStyle 100 ms later: " + a + " then " + getComputedStyle(s).transform)`)
	run(pr, `wrenTest.check(document.getAnimations()[0].currentTime > c, "currentTime 100 ms later: " + c + " then " + document.getAnimations()[0].currentTime)`)
	close_page(pr, min_checks = UNSEEN_CHECKS + 1)
}

// A frame's rendering update reads one instant, the frame's: with an animation nobody sees waiting for its tick, the first reading of the
// layout ticks it and lays out, and the callback's readings, the resize and the intersection observations after it find that layout as it is.
// The rendering update was on the live clock: each of them read a later time, ticked the animation again and laid the page out again (four
// layouts a frame, theverge.com's carousel at 60 frames a second: round 58 of docs/performance.md). Each layout here takes 1 ms of the virtual clock;
// the animation is one long step, so that its ticks change no style and the layout the probe reads stays the page as it is.
UNSEEN_FRAME_PAGE :: `<!doctype html><style>@keyframes spin { from { transform: rotate(0deg) } to { transform: rotate(360deg) } } body { margin: 0 } #s { width: 40px; height: 40px; animation: spin 1000s steps(1) infinite }</style><div style="height: 20000px"></div><div id=s></div>`
UNSEEN_FRAME_SCRIPT :: `document.body.offsetTop; new ResizeObserver(() => {}).observe(document.body); new IntersectionObserver(() => {}).observe(document.body); requestAnimationFrame(() => { document.body.offsetTop; document.getElementById("s").getBoundingClientRect() })`
UNSEEN_LAYOUT_TAKES :: time.Millisecond
UNSEEN_FRAME_CHECKS :: 3

@(test)
jsdom_a_frame_lays_out_once_for_an_unseen_animation :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Pages)
	defer end()
	virtual_clock(t)
	lh := layout_host_make()
	defer layout_host_destroy(lh)
	pr := page_make(t, "unseen_frame.html", strings.concatenate({ADDRESS, "unseen_frame.html"}, context.temp_allocator))
	slow_layout :: proc(user: rawptr, p: ^page.Page) -> ^lay.Layout {
		l := layout_update(user, p)
		host.clock_advance(&loop, UNSEEN_LAYOUT_TAKES)
		return l
	}
	page.set_layout_embedder(pr.p, {user = lh, update = slow_layout, viewport = layout_viewport, scroll_to = layout_scroll})
	page_load(pr, UNSEEN_FRAME_PAGE)
	drain()
	run(pr, UNSEEN_FRAME_SCRIPT)   // (its first reading lays the page out: the layout the probe reads)
	_ = layout_update(lh, pr.p)   // a frame's style pass and layout: nobody sees #s
	check(pr, page.animations_next_ms(pr.p) > 0, "the animation waits for its unseen tick")
	host.clock_advance(&loop, UNSEEN_READ_GAP)
	before := page.layout_updates(pr.p)
	check(pr, page.run_animation_frames(pr.p, now_ms()) == 1, "the frame runs the callback")
	laid := page.layout_updates(pr.p) - before
	check(pr, laid == 1, fmt.tprintf("one layout for the frame's readings, observations included: %d", laid))
	close_page(pr, min_checks = UNSEEN_FRAME_CHECKS)
}

// (the micro-benchmarks only measure: a performance run, test_all -Perf)
@(test)
jsdom_bench :: proc(t: ^testing.T) {
	if base.perf_skip("web tests, jsdom_bench: the micro-benchmarks of the DOM bindings (examples/jsdom/bench.html)") { return }
	page_test(t, "bench.html", checks = 0, timeout_ms = BENCH_LIMIT_MS)
}

@(test)
jsdom_touch_expose :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	all := testhost.Section{name = "browser.touch.expose", finished = true}
	// what the preference makes of the hardware
	pts, on := js.touch_exposure("auto", 0)
	testhost.expect(&all, t, pts == 0 && !on, "auto without a touch screen: nothing")
	pts, on = js.touch_exposure("auto", TOUCH_PAGE_POINTS)
	testhost.expect(&all, t, pts == TOUCH_PAGE_POINTS && on, "auto with a 10-point screen: 10, handlers")
	pts, on = js.touch_exposure("on", 0)
	testhost.expect(&all, t, pts == 1 && on, "on: at least one point")
	pts, on = js.touch_exposure("off", TOUCH_PAGE_POINTS)
	testhost.expect(&all, t, pts == 0 && !on, "off: none")
	touch_page(t, &all, false)
	touch_page(t, &all, true)
	testhost.finish(&all, t, min_checks = TOUCH_CHECKS)
}
