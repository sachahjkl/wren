package wpt

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "wb:base"
import "wb:dom"
import "wb:forms"
import lay "wb:layout"
import "wb:page"
import "wb:style"
import "wb:tools/headless"

// test_driver's input actions (wpt/testdriver-vendor.js): the page asks with a console message "WPTDRIVER " + JSON
// {sources: [WebDriver input sources]}, the child performs the actions once its pump returns (never inside the page's own
// call), tick after tick as WebDriver's "dispatch actions" does, through the browser's input path as src/browser drives it
// (page_input.odin, forms_shell.odin): a hit test of the page's layout (a test with test_driver has one), pointer events
// then their compatibility mouse events, the focus on a press, the click with its activation behaviour (forms.click, a
// trusted one: light dismiss), keydown then the default action (Tab's focus navigation, forms.key_down: Escape's close
// request, typing into a field), keyup. It answers each in turn with __wrenTestdriverDone(error) (null: done).

// What the console message starts with; the answer of a request done.
DRIVER_PREFIX :: "WPTDRIVER "
DRIVER_DONE :: "__wrenTestdriverDone(null);"

// WebDriver's codes of the keys that are no character (U+E000 ...).
@(private = "file") WD_KEY_FIRST :: 0xE000
@(private = "file") WD_KEY_LAST :: 0xE05D

// Keyboard scrolling as the shell's defaults have it (browser.scroll.key_line_px, browser.scroll.key_page_fraction):
// an arrow moves a line, a page key this much of what shows.
@(private = "file") KEY_LINE_PX :: 40
@(private = "file") KEY_PAGE_FRACTION :: 0.875

// MouseEvent.buttons of a MouseEvent.button: primary 1, auxiliary 4, secondary 2.
@(private = "file") BUTTON_BITS :: [3]u16{1, 4, 2}

// The input state of a test's page (WebDriver's input state of its window): where the mouse is, what it is over, where
// its primary button went down, the buttons and modifiers held, and the requests not yet performed (their JSON, owned).
Driver :: struct {
	requests: [dynamic]string,
	pointer:  [2]f64,
	over:     base.Handle,
	press:    base.Handle,
	scroll_from: base.Handle,   // the last element pressed: what the keys scroll when nothing has the focus
	buttons:  u16,
	mods:     u32,
}

driver_destroy :: proc(dr: ^Driver) {
	for r in dr.requests { delete(r) }
	delete(dr.requests)
}

// Performs the requests the page made, each answered when done; those an answer makes (a page that asks again at once)
// wait for the next turn of the child's loop, which checks the test's time.
driver_run :: proc(d: ^headless.Doc, dr: ^Driver) {
	for _ in 0 ..< len(dr.requests) {
		req := dr.requests[0]
		ordered_remove(&dr.requests, 0)
		why := driver_perform(d, dr, req)
		delete(req)
		if d.page == nil || d.page.closed { continue }
		answer := why == "" ? DRIVER_DONE : fmt.tprintf("__wrenTestdriverDone(%q);", why)
		page.js_run(d.page, transmute([]byte)answer, "wpt-testdriver.js")
	}
}

// One request: why it failed ("": done).
@(private = "file")
driver_perform :: proc(d: ^headless.Doc, dr: ^Driver, text: string) -> (why: string) {
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil { return "the request is not JSON" }
	obj, _ := v.(json.Object)
	sources, _ := obj["sources"].(json.Array)
	ticks := 0
	for s in sources {
		so, _ := s.(json.Object)
		if acts, ok := so["actions"].(json.Array); ok { ticks = max(ticks, len(acts)) }
	}
	for tick in 0 ..< ticks {
		pause := 0
		for s in sources {
			so, _ := s.(json.Object)
			acts, _ := so["actions"].(json.Array)
			if tick >= len(acts) { continue }
			a, _ := acts[tick].(json.Object)
			if d.page == nil || d.page.closed { return "" }   // a click that navigated: nothing left to act on
			kind := json_str(a["type"])
			switch kind {
			case "pause": pause = max(pause, json_int(a["duration"]))
			case "pointerMove":
				x, y := json_f64(a["x"]), json_f64(a["y"])
				if json_str(a["origin"]) == "pointer" { x += dr.pointer.x; y += dr.pointer.y }
				pointer_move(d.page, dr, x, y)
			case "pointerDown": pointer_button(d.page, dr, i32(json_int(a["button"])), true)
			case "pointerUp": pointer_button(d.page, dr, i32(json_int(a["button"])), false)
			case "keyDown": key(d.page, dr, json_str(a["value"]), true)
			case "keyUp": key(d.page, dr, json_str(a["value"]), false)
			case "scroll": wheel(d.page, dr, json_f64(a["x"]), json_f64(a["y"]), json_f64(a["deltaX"]), json_f64(a["deltaY"]))
			case: return fmt.tprintf("the action %q is not implemented by Wren's runner", kind)
			}
		}
		// (a tick lasts as long as its longest pause: the page's timers and tasks run meanwhile)
		if pause > 0 { headless.pump(d, f64(pause), nil) }
	}
	return ""
}

@(private = "file")
json_f64 :: proc(v: json.Value) -> f64 {
	#partial switch x in v {
	case json.Integer: return f64(x)
	case json.Float: return f64(x)
	}
	return 0
}

// The element at a point of the viewport (client coordinates), the root element over nothing; NIL outside the viewport
// or without a layout.
@(private = "file")
hit :: proc(p: ^page.Page, x, y: f64) -> base.Handle {
	l, vp := page.js_layout_now(p)
	if l == nil || !l.valid || x < 0 || y < 0 || x > vp.width || y > vp.height { return base.NIL_HANDLE }
	s := f32(vp.scale)
	cur := lay.hit_test(l, {f32(x) * s, f32(y) * s}, {f32(vp.width) * s, f32(vp.height) * s}, f32(vp.scroll_y) * s).node
	for cur != base.NIL_HANDLE {
		n := dom.get(p.doc, cur)
		if n == nil || n.kind == .Element { break }
		cur = dom.flat_parent(p.doc, cur)
	}
	if cur != base.NIL_HANDLE { return cur }
	for c := dom.get(p.doc, p.doc.root).first_child; c != base.NIL_HANDLE; c = dom.get(p.doc, c).next {
		if dom.get(p.doc, c).kind == .Element { return c }
	}
	return base.NIL_HANDLE
}

@(private = "file")
mouse_event :: proc(dr: ^Driver, type: string, button: i32 = 0, bubbles := true, cancelable := true, related := base.NIL_HANDLE) -> dom.Event {
	return dom.Event{type = type, bubbles = bubbles, cancelable = cancelable, composed = true, x = dr.pointer.x, y = dr.pointer.y, button = button, mods = dr.mods, buttons = dr.buttons, related = u64(related)}
}

@(private = "file")
pointer_move :: proc(p: ^page.Page, dr: ^Driver, x, y: f64) {
	dr.pointer = {x, y}
	now := page.pointer_target(p, page.MOUSE_POINTER_ID, hit(p, x, y))
	if now != dr.over {
		boundary(p, dr, dr.over, now)
		dr.over = now
	}
	if now == base.NIL_HANDLE { return }
	proto := mouse_event(dr, "pointermove")
	page.pointer_capture_process(p, page.MOUSE_POINTER_ID, proto)
	if page.dispatch_event(p, page.pointer_target(p, page.MOUSE_POINTER_ID, now), proto) && !p.closed {
		page.dispatch_event(p, now, mouse_event(dr, "mousemove"))
	}
}

// What the mouse leaves and enters (UI Events §4.3.3, Pointer Events §4.1.3): out and leave on what it was over and its
// ancestors that do not contain what it is over now, then over and enter the other way; pointer events first.
@(private = "file")
boundary :: proc(p: ^page.Page, dr: ^Driver, was, now: base.Handle) {
	d := p.doc
	contains :: proc(d: ^dom.Document, a, b: base.Handle) -> bool { return a != base.NIL_HANDLE && b != base.NIL_HANDLE && dom.is_ancestor_or_self(d, a, b) }
	for prefix in ([]string{"pointer", "mouse"}) {
		if was != base.NIL_HANDLE && dom.get(d, was) != nil {
			page.dispatch_event(p, was, mouse_event(dr, strings.concatenate({prefix, "out"}, context.temp_allocator), related = now))
			for cur := was; cur != base.NIL_HANDLE && !contains(d, cur, now); cur = dom.parent_or_host(d, cur) {
				if n := dom.get(d, cur); n == nil || n.kind != .Element { break }
				page.dispatch_event(p, cur, mouse_event(dr, strings.concatenate({prefix, "leave"}, context.temp_allocator), bubbles = false, cancelable = false, related = now))
			}
		}
		if now != base.NIL_HANDLE && dom.get(d, now) != nil {
			page.dispatch_event(p, now, mouse_event(dr, strings.concatenate({prefix, "over"}, context.temp_allocator), related = was))
			entered := make([dynamic]base.Handle, context.temp_allocator)
			for cur := now; cur != base.NIL_HANDLE && !contains(d, cur, was); cur = dom.parent_or_host(d, cur) {
				if n := dom.get(d, cur); n == nil || n.kind != .Element { break }
				append(&entered, cur)
			}
			#reverse for h in entered {
				page.dispatch_event(p, h, mouse_event(dr, strings.concatenate({prefix, "enter"}, context.temp_allocator), bubbles = false, cancelable = false, related = was))
			}
		}
		if p.closed { return }
	}
}

// A press or a release of a mouse button where the mouse is (forms_pointer_down / forms_pointer_up / forms_click of the
// shell): pointerdown / pointerup (a pointermove when another button is held), the compatibility mousedown / mouseup
// unless it was cancelled; a press of the primary button focuses what it is in, unless mousedown was cancelled; a release
// clicks the nearest common ancestor of where the button went down and where it came up.
@(private = "file")
pointer_button :: proc(p: ^page.Page, dr: ^Driver, button: i32, down: bool) {
	bits := BUTTON_BITS
	bit := button >= 0 && int(button) < len(bits) ? bits[button] : 0
	target := hit(p, dr.pointer.x, dr.pointer.y)
	held_before := dr.buttons
	if down { dr.buttons |= bit } else { dr.buttons &~= bit }
	if target == base.NIL_HANDLE { return }
	kind := down ? "pointerdown" : "pointerup"
	if (down && held_before != 0) || (!down && dr.buttons != 0) { kind = "pointermove" }   // chorded buttons
	if down { page.pointer_mouse_held(p, true) }
	proto := mouse_event(dr, kind, button)
	page.pointer_capture_process(p, page.MOUSE_POINTER_ID, proto)
	to := page.pointer_target(p, page.MOUSE_POINTER_ID, target)
	pointer_ok := page.dispatch_event(p, to, proto)
	if p.closed { return }
	if kind == "pointerup" {
		page.pointer_up(p, page.MOUSE_POINTER_ID, proto)
		page.pointer_mouse_held(p, false)
	}
	mouse_ok := true
	if pointer_ok { mouse_ok = page.dispatch_event(p, to, mouse_event(dr, down ? "mousedown" : "mouseup", button)) }
	if p.closed || p.formctl == nil { return }
	f := page.page_forms(p)
	if down {
		if button != 0 { return }
		dr.press, dr.scroll_from = target, target
		if !mouse_ok { return }
		focus := base.NIL_HANDLE
		for cur := target; cur != base.NIL_HANDLE; cur = forms.parent_element(f, cur) {
			if forms.is_focusable(f, cur) { focus = cur; break }
		}
		if focus == base.NIL_HANDLE { forms.blur(f) } else if forms.kind(f, focus) != .Label { forms.focus(f, focus) }
		return
	}
	press := dr.press
	if button == 0 { dr.press = base.NIL_HANDLE }
	if button != 0 {
		page.dispatch_event(p, target, mouse_event(dr, "auxclick", button))
		return
	}
	for a := press; a != base.NIL_HANDLE; a = dom.parent_or_host(p.doc, a) {
		if dom.get(p.doc, a) == nil { break }
		if dom.is_ancestor_or_self(p.doc, a, target) {
			forms.click(f, a, forms.Click_Info{x = dr.pointer.x, y = dr.pointer.y, mods = dr.mods, trusted = true})
			return
		}
	}
}

// A turn of the wheel: the wheel event where the mouse is, then, unless it was cancelled, the scrolling (page_wheel and
// smooth_wheel of the shell, at once): the deepest scroll container under the mouse that can still move that way, else
// the document.
@(private = "file")
wheel :: proc(p: ^page.Page, dr: ^Driver, x, y, dx, dy: f64) {
	dr.pointer = {x, y}
	target := hit(p, x, y)
	if target == base.NIL_HANDLE { return }
	ev := mouse_event(dr, "wheel")
	ev.delta = {dx, dy, 0}
	if !page.dispatch_event(p, target, ev) || p.closed { return }
	l, vp := page.js_layout_now(p)
	if l == nil || !l.valid { return }
	s := f32(vp.scale)
	if lay.scroll_wheel(l, {f32(x), f32(y)} * s, {f32(dx), f32(dy)} * s, {f32(vp.width), f32(vp.height)} * s, f32(vp.scroll_y) * s) {
		page.scroll_events_mark(p)
		return
	}
	page.scroll_document_to(p, vp.scroll_x + dx, vp.scroll_y + dy)
}

// Keyboard scrolling (keyscroll.odin of the shell, at once): the nearest scroll container of `start` that can still move
// that way, else the document.
@(private = "file")
key_scroll :: proc(p: ^page.Page, start: base.Handle, k: forms.Key, shift: bool) {
	l, vp := page.js_layout_now(p)
	if l == nil || !l.valid { return }
	s := f32(vp.scale)
	vertical := k != .Left && k != .Right
	amount :: proc(k: forms.Key, shift: bool, port, cur, limit: f32) -> f32 {
		line := f32(KEY_LINE_PX)
		#partial switch k {
		case .Up, .Left:    return -line
		case .Down, .Right: return line
		case .Page_Up:      return -max(port * KEY_PAGE_FRACTION, line)
		case .Page_Down:    return max(port * KEY_PAGE_FRACTION, line)
		case .Space:        return (shift ? -1 : 1) * max(port * KEY_PAGE_FRACTION, line)
		case .Home:         return -cur
		case .End:          return limit - cur
		}
		return 0
	}
	view := [2]f32{f32(vp.width), f32(vp.height)} * s
	for n := start; n != base.NIL_HANDLE; n = dom.parent_or_host(p.doc, n) {
		if dom.get(p.doc, n) == nil { break }
		limit, ok := lay.scroll_max(l, n)
		if !ok { continue }
		cur, _ := lay.scroll_of(l, n)
		low := lay.scroll_min(l, n)
		port: f32
		if r, rok := lay.box_of(l, n, view, f32(vp.scroll_y) * s); rok { port = vertical ? r.padding.max.y - r.padding.min.y : r.padding.max.x - r.padding.min.x }
		next := cur
		if vertical { next.y = clamp(cur.y + amount(k, shift, port / s, cur.y / s, limit.y / s) * s, low.y, limit.y) } else { next.x = clamp(cur.x + amount(k, shift, port / s, cur.x / s, limit.x / s) * s, low.x, limit.x) }
		if abs(next.x - cur.x) >= 0.5 || abs(next.y - cur.y) >= 0.5 {
			lay.set_scroll(l, n, next)
			page.scroll_events_mark(p)
			return
		}
	}
	x, y := vp.scroll_x, vp.scroll_y
	if vertical {
		_, hi := lay.doc_scroll_y_range(l, view.y)
		y += f64(amount(k, shift, f32(vp.height), f32(y), hi / s))
	} else {
		_, hi := lay.doc_scroll_x_range(l, view.x)
		x += f64(amount(k, shift, f32(vp.width), f32(x), hi / s))
	}
	page.scroll_document_to(p, x, y)
}

// A key of WebDriver: KeyboardEvent.keyCode and .key, the forms' key, the modifier it is, the text it types.
@(private = "file")
Key_Info :: struct { code: u32, name: string, forms_key: forms.Key, mod: u32, text: string }

@(private = "file")
key_info :: proc(value: string) -> Key_Info {
	r, _ := utf8.decode_rune_in_string(value)
	switch r {
	case 0xE003: return {code = 8, name = "Backspace", forms_key = .Backspace}
	case 0xE004: return {code = 9, name = "Tab", forms_key = .Tab}
	case 0xE006, 0xE007: return {code = 13, name = "Enter", forms_key = .Enter}
	case 0xE008, 0xE050: return {code = 16, name = "Shift", mod = dom.MOD_SHIFT}
	case 0xE009, 0xE051: return {code = 17, name = "Control", mod = dom.MOD_CTRL}
	case 0xE03D, 0xE053: return {code = 91, name = "Meta", mod = dom.MOD_META}
	case 0xE00A, 0xE052: return {code = 18, name = "Alt", mod = dom.MOD_ALT}
	case 0xE00C: return {code = 27, name = "Escape", forms_key = .Escape}
	case 0xE00D: return {code = 32, name = " ", forms_key = .Space, text = " "}
	case 0xE00E: return {code = 33, name = "PageUp", forms_key = .Page_Up}
	case 0xE00F: return {code = 34, name = "PageDown", forms_key = .Page_Down}
	case 0xE010: return {code = 35, name = "End", forms_key = .End}
	case 0xE011: return {code = 36, name = "Home", forms_key = .Home}
	case 0xE012: return {code = 37, name = "ArrowLeft", forms_key = .Left}
	case 0xE013: return {code = 38, name = "ArrowUp", forms_key = .Up}
	case 0xE014: return {code = 39, name = "ArrowRight", forms_key = .Right}
	case 0xE015: return {code = 40, name = "ArrowDown", forms_key = .Down}
	case 0xE017: return {code = 46, name = "Delete", forms_key = .Delete}
	case WD_KEY_FIRST ..= WD_KEY_LAST: return {name = "Unidentified"}
	}
	info := Key_Info{name = value, text = value}
	switch {
	case r >= 'a' && r <= 'z': info.code = u32(r - 'a' + 'A')
	case r >= 'A' && r <= 'Z', r >= '0' && r <= '9': info.code = u32(r)
	case r == ' ': info.code, info.forms_key = 32, .Space
	}
	return info
}

// A key going down or up (route_key / Key_Release of the shell) at the focused element, else the body; a key down that
// no listener cancelled does what the browser does with it.
@(private = "file")
key :: proc(p: ^page.Page, dr: ^Driver, value: string, down: bool) {
	k := key_info(value)
	if down { dr.mods |= k.mod } else { dr.mods &~= k.mod }
	f := p.formctl != nil ? page.page_forms(p) : nil
	target := f != nil && f.focus != base.NIL_HANDLE ? f.focus : p.body
	if target == base.NIL_HANDLE { return }
	ev := dom.Event{type = down ? "keydown" : "keyup", bubbles = true, cancelable = true, composed = true, key = k.code, text = k.name, mods = dr.mods}
	if !page.dispatch_event(p, target, ev) || !down || p.closed || f == nil { return }
	mods: forms.Mods
	if dr.mods & dom.MOD_CTRL != 0 { mods += {.Ctrl} }
	if dr.mods & dom.MOD_SHIFT != 0 { mods += {.Shift} }
	if dr.mods & dom.MOD_ALT != 0 { mods += {.Alt} }
	if k.forms_key == .Tab && .Ctrl not_in mods && .Alt not_in mods {
		forms.focus_next(f, .Shift in mods ? -1 : 1, rendered, p)
		return
	}
	if k.forms_key != .None && forms.key_down(f, k.forms_key, mods) { return }
	// keyboard scrolling, never while typing in a text field (route_key of the shell)
	text_field := f.focus != base.NIL_HANDLE && forms.is_text_field(f, f.focus)
	#partial switch k.forms_key {
	case .Up, .Down, .Left, .Right, .Page_Up, .Page_Down, .Space, .Home, .End:
		ctrl_ok := k.forms_key == .Home || k.forms_key == .End
		if !text_field && .Alt not_in mods && (ctrl_ok || .Ctrl not_in mods) {
			key_scroll(p, f.focus != base.NIL_HANDLE ? f.focus : dr.scroll_from, k.forms_key, .Shift in mods)
			return
		}
	}
	if k.text != "" && .Ctrl not_in mods { forms.type_text(f, k.text) }
}

// Whether an element shows (the shell's is_rendered): none of its ancestors is display: none, it is not hidden.
@(private = "file")
rendered :: proc(user: rawptr, h: base.Handle) -> bool {
	p := (^page.Page)(user)
	if p.styled == nil { return true }
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(p.doc, cur)
		if n == nil { return false }
		if n.kind == .Element {
			cs := style.style_of(p.styled, cur)
			if cs == nil || cs.display == .None { return false }
			if cur == h && cs.visibility != .Visible { return false }
		}
		cur = n.parent
	}
	return true
}
