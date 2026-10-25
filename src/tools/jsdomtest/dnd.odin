package jsdomtest

// examples/jsdom/dnd.html: drag and drop, pointer capture and touch events as the shell drives them (src/page/
// dnd_session.odin, pointer_input.odin). The page checks its DataTransfer, constructors and files; the tool plays the
// shell (a drag from a draggable element onto a drop zone, a drag of another application with a file of this computer
// onto the zone and onto a plain element, a captured mouse pointer, a finger) and checks the events the page saw.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:forms"
import "wb:host"
import "wb:page"

@(private = "file")
events_of :: proc(p: ^page.Page) -> string {
	from := len(logs)
	page.js_run(p, transmute([]byte)string("report()"), "probe.js")
	for l in logs[from:] { if strings.has_prefix(l, "EVENTS ") { return l[7:] } }
	return ""
}

@(private = "file")
wait_value :: proc(p: ^page.Page, expr: string, ms: f64 = 10000) -> string {
	from := len(logs)
	code := strings.concatenate({`Promise.resolve(`, expr, `).then((v) => console.log("VALUE " + v), (e) => console.log("VALUE error " + e))`}, context.temp_allocator)
	page.js_run(p, transmute([]byte)code, "probe.js")
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < ms {
		for l in logs[from:] { if strings.has_prefix(l, "VALUE ") { return l[6:] } }
		host.loop_wait(&loop, 2)
	}
	return "(no value)"
}

@(private = "file")
el :: proc(p: ^page.Page, sel: string) -> base.Handle {
	h, _ := page.query_first(p, sel)
	return h
}

dnd_checks :: proc(p: ^page.Page) {
	src, zone, plain, link := el(p, "#src"), el(p, "#zone"), el(p, "#plain"), el(p, "#link")
	check(src != base.NIL_HANDLE && zone != base.NIL_HANDLE, "the page's elements")

	s, k := page.drag_source_for(p, src)
	check(s == src && k == .Element, "draggable=\"true\" is a drag source")
	s, k = page.drag_source_for(p, link)
	check(s == link && k == .Link, "a link is a drag source by default")
	s, k = page.drag_source_for(p, plain)
	check(s == base.NIL_HANDLE && k == .None, "a plain element is not")

	// a drag from the page onto the zone
	check(page.drag_start(p, src, .Element, 10, 10, 0), "dragstart not cancelled: the drag starts")
	op, ok := page.drag_update(p, plain, 50, 60, 0)
	check(ok && op == .None, "over an element that does not take it: no operation")
	op, ok = page.drag_update(p, zone, 50, 120, 0)
	check(ok && op == .Copy, "over the zone (dragover cancelled, dropEffect copy): copy")
	pl, allowed := page.drag_session_payload(p)
	check(pl.text == "from src" && allowed == {.Copy}, "what would go to another application: the data dragstart set, effectAllowed copy")
	res := page.drag_drop(p, zone, 50, 120, 0)
	check(res.handled && res.op == .Copy, "drop cancelled by the zone: handled, copy")
	page.drag_finish(p, res.op)
	check(page.drag_session(p) == nil, "the session is over")
	ev := events_of(p)
	check(strings.contains(ev, "dragstart@src types= data="), "dragstart at the source (seen at capture, before its listener sets the data)")
	check(strings.contains(ev, "dragenter@plain types=text/plain data= files=0"), "dragenter: protected mode (types visible, data hidden)")
	check(strings.contains(ev, "dragleave@plain"), "dragleave at the element left")
	check(strings.contains(ev, "dragover@zone"), "dragover at the zone")
	check(strings.contains(ev, "drop@zone types=text/plain data=from src"), "drop: read-only mode, the data readable")
	check(strings.contains(ev, "dragend@src"), "dragend at the source")
	check(!strings.contains(ev, "drag@") || strings.index(ev, "drag@src") > strings.index(ev, "dragstart@src"), "drag at the source after dragstart")
	if !strings.contains(ev, "dragend@src") { fmt.printf("  events: %s\n", ev) }

	// another application's drag with a file of this computer
	dir := "build/tmp"
	_ = os.make_directory_all(dir)
	path := strings.concatenate({dir, "/dnd_drop.txt"}, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]byte)string("hello file"))
	abs, _ := os.get_absolute_path(path, context.temp_allocator)
	page.drag_external_begin(p, page.Drag_Payload{files = []string{abs}, text = "outside"}, {.Copy, .Link})
	op, ok = page.drag_update(p, zone, 50, 120, 0)
	check(ok && op == .Copy, "an outside drag over the zone: copy")
	res = page.drag_drop(p, zone, 50, 120, 0)
	page.drag_finish(p, res.op)
	check(res.handled, "the zone took the outside drop: the browser does not open the file")
	check(wait_value(p, "window.dropped") == "hello file|ell|dnd_drop.txt|text/plain|10", "the dropped File: its text, a slice read alone, name, type, size")
	ev = events_of(p)
	check(strings.contains(ev, "dragenter@zone types=text/plain|Files data= files=0"), "outside drag: protected mode, Files in types, no file yet")
	check(strings.contains(ev, "drop@zone types=text/plain|Files data=outside files=1"), "outside drop: the text and the file")

	page.drag_external_begin(p, page.Drag_Payload{files = []string{abs}}, {.Copy})
	op, _ = page.drag_update(p, plain, 50, 60, 0)
	res = page.drag_drop(p, plain, 50, 60, 0)
	page.drag_finish(p, res.op)
	check(op == .None && !res.handled, "dropped where nothing takes it: not handled (the browser opens the file)")
	events_of(p)

	// pointer capture of the mouse
	page.pointer_mouse_held(p, true)
	proto := dom.Event{type = "pointerdown", bubbles = true, cancelable = true, composed = true, x = 5, y = 70, buttons = 1}
	page.pointer_capture_process(p, page.MOUSE_POINTER_ID, proto)
	page.dispatch_event(p, plain, proto)   // its listener calls setPointerCapture
	check(page.pointer_target(p, page.MOUSE_POINTER_ID, zone) == zone, "the capture waits for the pointer's next event")
	mv := proto
	mv.type = "pointermove"
	page.pointer_capture_process(p, page.MOUSE_POINTER_ID, mv)
	check(page.pointer_target(p, page.MOUSE_POINTER_ID, zone) == plain, "then the pointer's events go to the capturing element")
	up := proto
	up.type, up.buttons = "pointerup", 0
	page.dispatch_event(p, page.pointer_target(p, page.MOUSE_POINTER_ID, zone), up)
	page.pointer_up(p, page.MOUSE_POINTER_ID, up)
	page.pointer_mouse_held(p, false)
	check(page.pointer_target(p, page.MOUSE_POINTER_ID, zone) == zone, "released after pointerup")
	ev = events_of(p)
	check(strings.contains(ev, "gotpointercapture@plain id=1 type=mouse"), "gotpointercapture at the element")
	check(strings.contains(ev, "pointerup@plain"), "pointerup retargeted to it")
	check(strings.contains(ev, "lostpointercapture@plain"), "lostpointercapture after the release")

	// a finger
	t1 := page.Touch_Point{id = 9, target = zone, x = 30, y = 110}
	check(page.touch_dispatch(p, .Start, t1, 0, {}), "touchstart not cancelled")
	t1.x = 40
	page.touch_dispatch(p, .Move, t1, 0, {})
	page.touch_dispatch(p, .End, t1, 0, {})
	ev = events_of(p)
	check(strings.contains(ev, "touchstart@zone touches=1 changed=1 id=9 x=30"), "touchstart with the finger in touches and changedTouches")
	check(strings.contains(ev, "touchmove@zone touches=1 changed=1 id=9 x=40"), "touchmove at the element the touch began on")
	check(strings.contains(ev, "touchend@zone touches=0 changed=1 id=9"), "touchend: the finger only in changedTouches")

	dnd_default_checks(p, abs)
	dnd_entries_checks(p)
	dnd_image_checks(p)
}

@(private = "file")
field_value :: proc(p: ^page.Page, h: base.Handle) -> string { return forms.edit_text(page.page_forms(p), h) }

// The browser's default of an uncancelled drop: text moved between fields (deleteByDrag, then insertFromDrop where the
// caret is), copied with Ctrl, refused by a cancelled beforeinput, inserted into contenteditable; files into a file input
// (its accept, not multiple), a disabled one refusing them.
@(private = "file")
dnd_default_checks :: proc(p: ^page.Page, file_path: string) {
	text, area, ce, file2, filedis := el(p, "#text"), el(p, "#area"), el(p, "#ce"), el(p, "#file2"), el(p, "#filedis")
	f := page.page_forms(p)
	forms.set_value(f, text, "hello world")
	forms.set_value(f, area, "[]")
	events_of(p)

	// a selection of #text moved into #area, between the brackets
	check(page.drag_start(p, text, .Selection, 5, 5, 0, "hello"), "a field's selection starts a drag")
	page.drag_set_source_field(p, text, 0, 5)
	op, ok := page.drag_update(p, area, 20, 20, 0)
	check(ok && op == .Move, "selected text over another field: a move")
	page.drag_set_caret(p, page.Drop_Caret{node = area, field = true, offset = 1})
	c, has := page.drag_caret(p)
	check(has && c.offset == 1, "the drop caret follows the pointer")
	res := page.drag_drop(p, area, 20, 20, 0)
	page.drag_finish(p, res.op)
	check(res.handled && res.op == .Move, "the browser handled the drop: moved")
	check(field_value(p, text) == " world", fmt.tprintf("deleted from the source field (%q)", field_value(p, text)))
	check(field_value(p, area) == "[hello]", fmt.tprintf("inserted at the caret (%q)", field_value(p, area)))
	a, b, _ := forms.selection(f, area)
	check(a == 1 && b == 6, "the dropped text is selected")
	ev := events_of(p)
	order := []string{"drop@area", "beforeinput@text deleteByDrag", "input@text deleteByDrag", "beforeinput@area insertFromDrop data=hello", "input@area insertFromDrop data=hello", "dragend@text"}
	at := 0
	in_order := true
	for s in order {
		i := strings.index(ev[at:], s)
		if i < 0 { in_order = false; fmt.printf("  missing %q in %s\n", s, ev); break }
		at += i + len(s)
	}
	check(in_order, "drop, deleteByDrag at the source, insertFromDrop at the target, dragend last")

	// Ctrl copies
	forms.set_value(f, text, "abc")
	forms.set_value(f, area, "")
	page.drag_start(p, text, .Selection, 5, 5, dom.MOD_CTRL, "abc")
	page.drag_set_source_field(p, text, 0, 3)
	op, _ = page.drag_update(p, area, 20, 20, dom.MOD_CTRL)
	check(op == .Copy, "Ctrl: a copy")
	res = page.drag_drop(p, area, 20, 20, dom.MOD_CTRL)
	page.drag_finish(p, res.op)
	check(field_value(p, text) == "abc" && field_value(p, area) == "abc", "copied: the source keeps its text")
	events_of(p)

	// a cancelled beforeinput: nothing inserted
	page.js_run(p, transmute([]byte)string("blockInsert = true"), "probe.js")
	page.drag_external_begin(p, page.Drag_Payload{text = "zz"}, {.Copy})
	page.drag_update(p, area, 20, 20, 0)
	res = page.drag_drop(p, area, 20, 20, 0)
	page.drag_finish(p, res.op)
	check(field_value(p, area) == "abc" && res.op == .None, "beforeinput insertFromDrop cancelled: the field keeps its text")
	page.js_run(p, transmute([]byte)string("blockInsert = false"), "probe.js")
	events_of(p)

	// contenteditable: the text spliced in where the caret is
	tn := dom.get(p.doc, ce).first_child
	page.drag_external_begin(p, page.Drag_Payload{text = "XY"}, {.Copy, .Move})
	op, _ = page.drag_update(p, ce, 20, 20, 0)
	check(op == .Copy, "text from another application over contenteditable: a copy")
	page.drag_set_caret(p, page.Drop_Caret{node = ce, pos = {tn, 2}})
	res = page.drag_drop(p, ce, 20, 20, 0)
	page.drag_finish(p, res.op)
	check(dom.get(p.doc, tn).text == "abXYcd", fmt.tprintf("inserted into the editing host (%q)", dom.get(p.doc, tn).text))
	ev = events_of(p)
	check(strings.contains(ev, "beforeinput@ce insertFromDrop data=XY") && strings.contains(ev, "input@ce insertFromDrop"), "beforeinput / input insertFromDrop at the editing host")

	// files: a .txt and a .bin onto an input that takes .txt and images, one file
	bin := strings.concatenate({file_path[:len(file_path) - 4], ".bin"}, context.temp_allocator)
	_ = os.write_entire_file(bin, transmute([]byte)string("01"))
	page.drag_external_begin(p, page.Drag_Payload{files = []string{bin, file_path}}, {.Copy})
	op, _ = page.drag_update(p, file2, 20, 20, 0)
	check(op == .Copy, "files over a file input: copy (the copy cursor)")
	res = page.drag_drop(p, file2, 20, 20, 0)
	page.drag_finish(p, res.op)
	list := forms.files(f, file2)
	check(res.handled && len(list) == 1 && list[0].name == "dnd_drop.txt", "the input took the file its accept allows")
	ev = events_of(p)
	check(strings.contains(ev, "input@file2") && strings.contains(ev, "change@file2"), "input and change at the file input")
	page.drag_external_begin(p, page.Drag_Payload{files = []string{file_path}}, {.Copy})
	op, _ = page.drag_update(p, filedis, 20, 20, 0)
	res = page.drag_drop(p, filedis, 20, 20, 0)
	page.drag_finish(p, res.op)
	check(op == .None && len(forms.files(f, filedis)) == 0, "a disabled file input refuses the drop")
	events_of(p)
}

// webkitGetAsEntry: a dropped folder walked from JavaScript (listed and read on the background pool).
@(private = "file")
dnd_entries_checks :: proc(p: ^page.Page) {
	root := "build/tmp/dnd_dir"
	_ = os.make_directory_all(strings.concatenate({root, "/sub"}, context.temp_allocator))
	_ = os.write_entire_file(strings.concatenate({root, "/a.txt"}, context.temp_allocator), transmute([]byte)string("A"))
	_ = os.write_entire_file(strings.concatenate({root, "/sub/b.txt"}, context.temp_allocator), transmute([]byte)string("B"))
	dir, _ := os.get_absolute_path(root, context.temp_allocator)
	page.drag_external_begin(p, page.Drag_Payload{files = []string{dir}}, {.Copy})
	page.drag_update(p, el(p, "#zone"), 50, 120, 0)
	res := page.drag_drop(p, el(p, "#zone"), 50, 120, 0)
	page.drag_finish(p, res.op)
	got := wait_value(p, "window.entries")
	want := "D /dnd_dir true | D /dnd_dir/sub true | F /dnd_dir/a.txt a.txt A | F /dnd_dir/sub/b.txt b.txt B"
	check(got == want, fmt.tprintf("a dropped folder: entries, full paths, readEntries, file() (%s)", got))
	check(wait_value(p, "window.escape") == "SecurityError", "a path out of what was dropped is refused")
	check(wait_value(p, "window.creating") == "SecurityError", "nothing is created in what was dropped")
	check(wait_value(p, "window.sub") == "/dnd_dir/sub/b.txt true", "getDirectory then getFile")
	events_of(p)
}

// The pixels of a canvas for a drag image (straight RGBA at its size), and setDragImage's element and offset.
@(private = "file")
dnd_image_checks :: proc(p: ^page.Page) {
	cv := el(p, "#cv")
	rgba, size, _, ok := page.drag_image_pixels(p, cv, context.temp_allocator)
	check(ok && size == {8, 6} && len(rgba) == 8 * 6 * 4 && rgba[0] == 255 && rgba[1] == 0 && rgba[3] == 255, "a canvas's pixels for the drag image")
	_, _, _, ok2 := page.drag_image_pixels(p, el(p, "#plain"), context.temp_allocator)
	check(!ok2, "a plain element has no pixels of its own (the shell reads it from the frame)")
	page.js_run(p, transmute([]byte)string(`document.getElementById("src").addEventListener("dragstart", (e) => e.dataTransfer.setDragImage(document.getElementById("cv"), 3, 2), { once: true })`), "probe.js")
	page.drag_start(p, el(p, "#src"), .Element, 10, 10, 0)
	h, off := page.drag_session_image(p)
	check(h == cv && off == {3, 2}, "setDragImage: the element and the hot spot")
	page.drag_cancel(p)
	events_of(p)
}
