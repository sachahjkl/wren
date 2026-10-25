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
}
