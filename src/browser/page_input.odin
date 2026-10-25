package browser

// Pointer Events and Touch Events for the page, on top of the mouse routing of route_page_input (main.odin) and
// forms_shell.odin:
//   * the mouse: pointerdown before mousedown (a cancelled pointerdown suppresses the compatibility mousedown, not the
//     default actions), pointerup before mouseup, both retargeted to the element that captured the pointer
//     (setPointerCapture, src/page/pointer_input.odin); a second button pressed while one is held is a pointermove
//     (chorded buttons), and so is the release of one of several;
//   * fingers and pens (the toolkit's Pointer_* events): pointerover / enter / down / move / up / cancel / out / leave
//     with their pressure, tilt and contact size, and for fingers touchstart / touchmove / touchend / touchcancel. A
//     cancelled touchstart drops the system's mouse emulation of that touch (the toolkit marks it `emulated`); the
//     emulation of a touch that was not cancelled goes on as mouse events, without a second set of pointer events;
//   * the client coordinates of every mouse event: `local` points have the document's scroll, events want the viewport's.

import "toolkit:draw"
import "toolkit:platform"
import "wb:base"
import "wb:dom"
import "wb:page"

// Client coordinates (CSS px) of a point in document device pixels (`local`: from the page area's corner, the page's
// scroll included).
page_client_xy :: proc(t: ^Tab, local: [2]f32, scale: f32) -> (f64, f64) {
	s := max(scale, 0.01)
	return f64(local.x / s), f64((local.y - t.scroll) / s)
}

// MouseEvent.buttons of the toolkit's held buttons: 1 primary, 2 secondary, 4 auxiliary.
dom_buttons :: proc(b: platform.Mouse_Buttons) -> u16 {
	out: u16
	if .Left in b { out |= 1 }
	if .Right in b { out |= 2 }
	if .Middle in b { out |= 4 }
	return out
}

@(private = "file")
button_bit :: proc(b: platform.Mouse_Button) -> platform.Mouse_Buttons { return {b} }

// The mouse's pointerdown / pointerup for a press / release on `target` (forms_shell.odin calls it before the mouse
// event). Returns false when a listener cancelled it: the compatibility mouse event is then not fired. The system's
// emulation of a finger already had its pointer events (route_device_pointer): nothing here.
page_pointer_button :: proc(app: ^App, t: ^Tab, type: string, target: base.Handle, ev: platform.Event, cx, cy: f64) -> bool {
	p := t.page
	if p == nil || ev.emulated || target == base.NIL_HANDLE { return true }
	kind := type
	// chorded buttons: only the first press and the last release are pointerdown / pointerup
	if type == "pointerdown" {
		page.pointer_mouse_held(p, true)
		if ev.buttons - button_bit(ev.button) != {} { kind = "pointermove" }
	} else if type == "pointerup" && ev.buttons != {} {
		kind = "pointermove"
	}
	proto := dom.Event{type = kind, bubbles = true, cancelable = true, composed = true, x = cx, y = cy, button = i32(ev.button), mods = dom_mods(ev.mods), buttons = dom_buttons(ev.buttons)}
	page.pointer_capture_process(p, page.MOUSE_POINTER_ID, proto)
	if t.page != p { return true }
	to := page.pointer_target(p, page.MOUSE_POINTER_ID, target)
	ok := page.dispatch_event(p, to, proto)
	if t.page != p { return ok }
	if kind == "pointerup" {
		page.pointer_up(p, page.MOUSE_POINTER_ID, proto)
		page.pointer_mouse_held(p, false)
	}
	return ok
}

// The element the mouse's events go to: the one that captured it, else `hit`.
page_pointer_target :: proc(t: ^Tab, hit: base.Handle) -> base.Handle {
	if t.page == nil { return hit }
	return page.pointer_target(t.page, page.MOUSE_POINTER_ID, hit)
}

@(private = "file")
Device_Input :: struct {
	over:          map[u32]base.Handle,   // what each finger / pen is over (for out / leave)
	drop_emulated: bool,                  // a cancelled touchstart: the system's mouse emulation of it is dropped
}

@(private = "file")
din: Device_Input

// The page's pointer id of a finger or a pen (the mouse is 1).
@(private = "file")
device_pointer_id :: proc(ev: platform.Event) -> i32 { return i32(ev.pointer.id % 0x3fff_ffff) + 2 }

@(private = "file")
device_details :: proc(ev: platform.Event, scale: f32) -> dom.Pointer_Details {
	pi := ev.pointer
	s := max(scale, 0.01)
	return dom.Pointer_Details{
		id = device_pointer_id(ev), kind = pi.kind == .Pen ? .Pen : .Touch, primary = pi.primary,
		pressure = pi.pressure, tilt = pi.tilt, twist = pi.twist, size = pi.contact / s,
	}
}

// A mouse event of the system's emulation that must not reach the page (its touchstart was cancelled).
page_drop_emulated :: proc(ev: platform.Event) -> bool {
	if !ev.emulated || !din.drop_emulated { return false }
	if ev.kind == .Mouse_Release && ev.buttons == {} { din.drop_emulated = false }
	return ev.kind == .Mouse_Press || ev.kind == .Mouse_Release || ev.kind == .Mouse_Move
}

// A finger or a pen (Pointer_* events of the toolkit) over the page. True when the event was the page's.
route_device_pointer :: proc(app: ^App, t: ^Tab, ev: platform.Event) -> bool {
	#partial switch ev.kind {
	case .Pointer_Down, .Pointer_Move, .Pointer_Up, .Pointer_Cancel:
	case: return false
	}
	p := t.page
	if p == nil || !t.layout.valid { return true }
	scale := page_scale(app)
	inside := draw.rect_contains(app.page_rect, ev.pos)
	hit := inside ? hit_test(&t.layout, ev.pos - app.page_rect.min, draw.rect_size(app.page_rect), t.scroll) : base.NIL_HANDLE
	cx, cy := f64((ev.pos.x - app.page_rect.min.x) / max(scale, 0.01)), f64((ev.pos.y - app.page_rect.min.y) / max(scale, 0.01))
	pd := device_details(ev, scale)
	id := pd.id
	contact := ev.kind == .Pointer_Down || (ev.kind == .Pointer_Move && ev.pointer.pressure > 0)
	buttons := platform.pointer_buttons(ev.pointer, contact)
	proto := dom.Event{bubbles = true, cancelable = true, composed = true, x = cx, y = cy, mods = dom_mods(ev.mods), buttons = buttons, pointer = pd}
	fire :: proc(p: ^page.Page, proto: dom.Event, type: string, target: base.Handle, bubbles := true, cancelable := true) -> bool {
		if target == base.NIL_HANDLE { return true }
		e := proto
		e.type, e.bubbles, e.cancelable = type, bubbles, cancelable
		return page.dispatch_event(p, target, e)
	}
	// boundary events when what the pointer is over changes (pointer* only: the emulated mouse makes the mouse ones)
	was := din.over[ev.pointer.id]
	now := ev.kind == .Pointer_Up || ev.kind == .Pointer_Cancel ? base.NIL_HANDLE : page.pointer_target(p, id, hit)
	boundary :: proc(p: ^page.Page, proto: dom.Event, was, now: base.Handle) {
		for e in pointer_plan(p.doc, was, now) {
			if len(e.type) < 7 || e.type[:7] != "pointer" || e.type == "pointermove" { continue }
			ev := proto
			ev.type, ev.bubbles, ev.cancelable = e.type, e.bubbles, e.cancelable
			page.dispatch_event(p, e.target, ev)
		}
	}
	touch := ev.pointer.kind == .Touch
	tp := page.Touch_Point{id = id, target = hit, x = cx, y = cy, radius = {f64(pd.size.x) / 2, f64(pd.size.y) / 2}, force = f64(ev.pointer.pressure)}
	scroll := [2]f64{0, f64(t.scroll / max(scale, 0.01))}
	#partial switch ev.kind {
	case .Pointer_Down:
		if !inside { return false }
		page.pointer_set_down(p, id, true)
		if was != now { boundary(p, proto, was, now) }
		if t.page != p { return true }
		din.over[ev.pointer.id] = now
		page.pointer_capture_process(p, id, proto)
		fire(p, proto, "pointerdown", page.pointer_target(p, id, hit))
		if t.page != p { return true }
		if touch && !page.touch_dispatch(p, .Start, tp, proto.mods, scroll) && ev.pointer.primary { din.drop_emulated = true }
	case .Pointer_Move:
		if was != now { boundary(p, proto, was, now) }
		if t.page != p { return true }
		din.over[ev.pointer.id] = now
		page.pointer_capture_process(p, id, proto)
		fire(p, proto, "pointermove", page.pointer_target(p, id, hit))
		if t.page != p { return true }
		if touch { page.touch_dispatch(p, .Move, tp, proto.mods, scroll) }
	case .Pointer_Up, .Pointer_Cancel:
		cancel := ev.kind == .Pointer_Cancel
		page.pointer_capture_process(p, id, proto)
		target := page.pointer_target(p, id, hit)
		if target == base.NIL_HANDLE { target = was }
		fire(p, proto, cancel ? "pointercancel" : "pointerup", target, cancelable = !cancel)
		if t.page != p { return true }
		page.pointer_up(p, id, proto)
		boundary(p, proto, was, base.NIL_HANDLE)
		delete_key(&din.over, ev.pointer.id)
		if t.page != p { return true }
		if touch { page.touch_dispatch(p, cancel ? .Cancel : .End, tp, proto.mods, scroll) }
	}
	app.frames_requested = max(app.frames_requested, 2)
	return true
}

page_input_destroy :: proc() { delete(din.over); din = {} }
