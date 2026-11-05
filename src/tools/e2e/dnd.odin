package e2e_scenarios

// Drag and drop, pointer and mouse coordinates: a file of another application dropped on a drop zone (dragenter / dragover / drop with the
// File, read back, and the browser does not open it; dropped where nothing takes it, the browser opens it); a drag of a draggable element
// onto the zone (pointerdown, mousedown, dragstart, dragenter, dragover, drop with the data dragstart set, dragend, buttons = 1 while held);
// a click in a scrolled page (clientY in the viewport, pageY with the scroll). The drops go through the toolkit's drop target path
// (platform.drop_inject): the machine's mouse and Explorer are not used.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") DND_PAGE :: "examples/dnd/dnd.html"
@(private = "file") DROP_NAME :: "dnd_e2e_drop.txt"
@(private = "file") DROP_BYTES :: "dropped bytes"
@(private = "file") DND_SIZE :: [2]int{1000, 700}
// Where things are in the page (dnd.html's fixed layout), in its CSS pixels.
@(private = "file") DRAGGABLE :: e2e.Point{50, 30}
@(private = "file") ZONE :: e2e.Point{100, 150}
@(private = "file") PLAIN :: e2e.Point{100, 100}
@(private = "file") OUTSIDE :: e2e.Point{-300, 30}
@(private = "file") TEXT_START :: e2e.Point{360, 212}
@(private = "file") TEXT_OUTSIDE :: e2e.Point{-300, 212}
@(private = "file") FIELD_SELECTION :: e2e.Point{362, 112}
@(private = "file") SECOND_FIELD :: e2e.Point{450, 162}
@(private = "file") FILE_INPUT :: e2e.Point{450, 265}
@(private = "file") NOWHERE :: e2e.Point{100, 300}
@(private = "file") SCROLLED :: 200
// A pixel of rounding either way, in the system's drag picture.
@(private = "file") IMAGE_ROUNDING :: 1.0
// A selection's picture is at least this wide and high, CSS pixels.
@(private = "file") SELECTION_LEAST_W :: 100.0
@(private = "file") SELECTION_LEAST_H :: 18.0

// "WxH@x,y" of the system's drag picture against what is expected in CSS px times the device pixel ratio.
@(private = "file")
near_image :: proc(got: string, css: [4]f64, dpr: f64) -> bool {
	head := got
	if sp := strings.index_byte(head, ' '); sp >= 0 { head = head[:sp] }
	at := strings.index_byte(head, '@')
	x := strings.index_byte(head, 'x')
	comma := strings.index_byte(head, ',')
	if at < 0 || x < 0 || comma < 0 { return false }
	v: [4]f64
	ok: [4]bool
	v[0], ok[0] = strconv.parse_f64(head[:x])
	v[1], ok[1] = strconv.parse_f64(head[x + 1:at])
	v[2], ok[2] = strconv.parse_f64(head[at + 1:comma])
	v[3], ok[3] = strconv.parse_f64(head[comma + 1:])
	for i in 0 ..< 4 { if !ok[i] || math.abs(v[i] - css[i] * dpr) > IMAGE_ROUNDING { return false } }
	return true
}

@(private = "file") log_of :: proc(s: ^e2e.Session) -> string { return e2e.eval(s, "log.join(' | ')") }
@(private = "file") log_clear :: proc(s: ^e2e.Session) { e2e.eval(s, "log.length = 0; 'ok'") }

// The drag out of the window and back, over the zone (the system's drag goes through the window's own drop target, never the real mouse).
@(private = "file")
drag_out_and_back :: proc(s: ^e2e.Session, from, outside: e2e.Point) {
	e2e.drag(s, from, ZONE, {via = {outside}, steps = 8})
}

// `drop` brings a dragend (the page's log says it has come); nothing else tells when the system's drag is over.
@(private = "file")
wait_drag_end :: proc(s: ^e2e.Session) { e2e.wait_js(s, "log.some(l => l.startsWith('dragend@'))") }

@(test)
dnd_end_to_end :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	file := fmt.tprintf("%s/%s", dir, DROP_NAME)
	e2e.write_text(file, DROP_BYTES)
	s := e2e.start(t, {size = DND_SIZE, url = e2e.file_url(fmt.tprintf("%s/%s", e2e.repo_root(), DND_PAGE))})

	e2e.drop(s, ZONE, {files = {file}})
	e2e.wait_js(s, "log.some(l => l.includes('read='))")
	l := log_of(s)
	testing.expectf(t, strings.contains(l, "dragenter@zone") && strings.contains(l, "dragover@zone") && strings.contains(l, "drop@zone files=1"), "a dropped file reaches the drop zone with its File: %s", l)
	testing.expectf(t, strings.contains(l, "read=dropped bytes"), "... and the page reads it: %s", l)
	path := e2e.eval(s, "location.pathname")
	testing.expectf(t, strings.has_suffix(path, "dnd.html"), "the zone took the drop: the browser did not open the file: %s", path)

	log_clear(s)
	e2e.drag(s, DRAGGABLE, ZONE, {steps = 6})
	l = log_of(s)
	testing.expectf(t, strings.contains(l, "pointerdown@src cy=30 py=30 b=1 | mousedown@src"), "pointerdown before mousedown, buttons = 1: %s", l)
	testing.expectf(t, strings.contains(l, "dragstart@src") && strings.contains(l, "drop@zone files=0 text=payload") && strings.contains(l, "dragend@src"), "a drag from a draggable element: dragstart, drop with its data, dragend: %s", l)
	testing.expectf(t, !strings.contains(l, "mouseup"), "no mouseup after a drag: %s", l)

	e2e.eval(s, fmt.tprintf("log.length = 0; scrollTo(0, %d); 'ok'", SCROLLED))
	e2e.wait_js(s, fmt.tprintf("Math.round(scrollY) == %d", SCROLLED))
	e2e.wait_frames(s)   // (what is hit is what the last frame laid out)
	e2e.click_at(s, PLAIN)
	l = log_of(s)
	testing.expectf(t, strings.contains(l, "mousedown@plain cy=100 py=300"), "a click in a scrolled page: clientY in the viewport, pageY with the scroll: %s", l)
	testing.expectf(t, strings.contains(l, "pointerup@plain cy=100 py=300 b=0 | mouseup@plain"), "pointerup before mouseup, no button held: %s", l)

	e2e.eval(s, "scrollTo(0, 0); 'ok'")
	e2e.wait_js(s, "scrollY == 0")
	e2e.wait_frames(s)
	dpr := e2e.eval_f64(s, "devicePixelRatio")

	// out of the window and back onto the zone: drop to the page before dragend, which carries the drop's effect; the ghost of the element went with it
	log_clear(s)
	drag_out_and_back(s, DRAGGABLE, OUTSIDE)
	wait_drag_end(s)
	l = log_of(s)
	i_drop, i_end := strings.index(l, "drop@zone"), strings.index(l, "dragend@src")
	testing.expectf(t, i_drop >= 0 && i_end > i_drop, "out of the window and back: drop before dragend: %s", l)
	testing.expectf(t, strings.contains(l, "dragend@src effect=copy"), "... dragend with the effect of the drop: %s", l)
	st := e2e.stats(s)
	testing.expectf(t, near_image(st.drag_image, {100, 40, 40, 20}, dpr), "the ghost of the dragged element (100x40 grabbed at 40,20) went to the system's drag: %s", st.drag_image)

	// setDragImage with a canvas: its pixels, its hot spot
	e2e.eval(s, "log.length = 0; useImage = true; 'ok'")
	drag_out_and_back(s, DRAGGABLE, OUTSIDE)
	wait_drag_end(s)
	st = e2e.stats(s)
	testing.expectf(t, near_image(st.drag_image, {20, 10, 5, 4}, dpr), "setDragImage(canvas, 5, 4) is the system's picture: %s", st.drag_image)
	// a dragstart that changes the page, a class on what is dragged: the picture is of the layout that follows, not none
	e2e.eval(s, "log.length = 0; useImage = 'far'; window.marks = () => { document.body.className = 'dragging'; }; addEventListener('dragstart', marks); 'ok'")
	drag_out_and_back(s, DRAGGABLE, OUTSIDE)
	wait_drag_end(s)
	st = e2e.stats(s)
	testing.expectf(t, near_image(st.drag_image, {60, 30, 6, 3}, dpr), "setDragImage when dragstart changed the page: %s", st.drag_image)
	e2e.eval(s, "removeEventListener('dragstart', marks); document.body.className = ''; 'ok'")
	e2e.eval(s, "log.length = 0; useImage = 'canvas'; 'ok'")
	drag_out_and_back(s, DRAGGABLE, OUTSIDE)
	wait_drag_end(s)
	// setDragImage of an element 1000 px above the page: painted alone offscreen (its orange, opaque)
	e2e.eval(s, "log.length = 0; useImage = 'far'; 'ok'")
	drag_out_and_back(s, DRAGGABLE, OUTSIDE)
	wait_drag_end(s)
	st = e2e.stats(s)
	testing.expectf(t, near_image(st.drag_image, {60, 30, 6, 3}, dpr) && strings.has_suffix(st.drag_picture, "rgba=255,136,0,255"), "setDragImage of an element off the screen: painted alone: %s / %s", st.drag_image, st.drag_picture)
	e2e.eval(s, "useImage = false; 'ok'")

	// selected text of the document dragged: a picture of the selection (its lines highlighted), not the system's cursor
	e2e.eval(s, "log.length = 0; const r = document.createRange(); r.selectNodeContents(txt); getSelection().removeAllRanges(); getSelection().addRange(r); 'ok'")
	drag_out_and_back(s, TEXT_START, TEXT_OUTSIDE)
	wait_drag_end(s)
	st = e2e.stats(s)
	l = log_of(s)
	testing.expectf(t, selection_picture_ok(st.drag_picture, dpr) && st.drag_image != "", "a selection of the document dragged: a picture of its text for the system: %s / %s", st.drag_image, st.drag_picture)
	testing.expectf(t, strings.contains(l, "drop@zone files=0 text=select this text"), "... and its text dropped on the zone: %s", l)
	e2e.eval(s, "getSelection().removeAllRanges(); 'ok'")

	// selected text of a field dragged into another: moved (deleteByDrag, insertFromDrop), dragend with move
	e2e.eval(s, "log.length = 0; in1.focus(); in1.setSelectionRange(0, 5); 'ok'")
	e2e.wait_frames(s)
	e2e.drag(s, FIELD_SELECTION, SECOND_FIELD, {steps = 6})
	wait_drag_end(s)
	vals := e2e.eval(s, "in1.value + '|' + in2.value")
	l = log_of(s)
	testing.expectf(t, vals == " world|hello", "a field selection dragged to another field moves the text: %s / %s", vals, l)
	testing.expectf(t, strings.contains(l, "beforeinput@in1 deleteByDrag") && strings.contains(l, "input@in2 insertFromDrop") && strings.contains(l, "dragend@in1 effect=move"), "... with deleteByDrag, insertFromDrop and dragend move: %s", l)

	// a file dropped on a file input (no script): it takes it, input and change
	log_clear(s)
	e2e.drop(s, FILE_INPUT, {files = {file}})
	e2e.wait_js(s, "log.some(l => l.startsWith('change@fin'))")
	fin := e2e.eval(s, "fin.files.length + ' ' + (fin.files[0] && fin.files[0].name) + ' ' + location.pathname.endsWith('dnd.html')")
	l = log_of(s)
	testing.expect_value(t, fin, fmt.tprintf("1 %s true", DROP_NAME))
	testing.expectf(t, strings.contains(l, "input@fin") && strings.contains(l, "change@fin"), "... with input and change: %s", l)
	net0 := e2e.stats(s).prefs_net_applied
	e2e.pref_set(s, "browser.tabs.sidebar_width", "300")
	testing.expect_value(t, e2e.stats(s).prefs_net_applied, net0)   // writing browser.tabs.sidebar_width configures nothing of the network again

	e2e.drop(s, NOWHERE, {files = {file}})
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return strings.has_suffix(e2e.location(s), DROP_NAME) }, "a file dropped where nothing takes it opens")
}

// "WxH@x,y rgba=r,g,b,a": at least the size of the selection's text, not transparent.
@(private = "file")
selection_picture_ok :: proc(picture: string, dpr: f64) -> bool {
	x, at := strings.index_byte(picture, 'x'), strings.index_byte(picture, '@')
	if x < 0 || at < 0 { return false }
	w, ok1 := strconv.parse_f64(picture[:x])
	h, ok2 := strconv.parse_f64(picture[x + 1:at])
	return ok1 && ok2 && w >= SELECTION_LEAST_W * dpr && h >= SELECTION_LEAST_H * dpr && !strings.has_suffix(picture, ",0")
}
