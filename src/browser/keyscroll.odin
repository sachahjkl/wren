package browser

// Keyboard scrolling: the default action of the arrows, Page Up / Page Down, Space / Shift+Space and Home / End when
// nothing in the page used the key (no listener cancelled the keydown, no form control took it). As in other browsers
// the key moves the nearest scroll container of the focused element (or, without one, of the last element pressed in
// the page) that can still move that way, else the document.

import "toolkit:platform"
import "wb:base"
import "wb:dom"
import lay "wb:layout"

Key_Scroll :: enum u8 { None, Line_Up, Line_Down, Line_Left, Line_Right, Page_Up, Page_Down, Top, Bottom }

key_scroll_of :: proc(ev: platform.Event) -> Key_Scroll {
	ctrl, shift, alt := .Ctrl in ev.mods, .Shift in ev.mods, .Alt in ev.mods
	if alt { return .None }   // Alt+arrows are history
	#partial switch ev.key {
	case .Up:        if !ctrl { return .Line_Up }
	case .Down:      if !ctrl { return .Line_Down }
	case .Left:      if !ctrl { return .Line_Left }
	case .Right:     if !ctrl { return .Line_Right }
	case .Page_Up:   if !ctrl { return .Page_Up }
	case .Page_Down: if !ctrl { return .Page_Down }
	case .Space:     if !ctrl { return shift ? .Page_Up : .Page_Down }
	case .Home:      return .Top
	case .End:       return .Bottom
	}
	return .None
}

// Scrolls for `k` starting from `start` (NIL: the document). True when the key is the page's (even at an end).
keyboard_scroll :: proc(app: ^App, t: ^Tab, start: base.Handle, k: Key_Scroll) -> bool {
	if k == .None || t.page == nil || !t.layout.valid { return false }
	// smooth_scroll.odin: animated, from where the scroller is already going (held keys add up)
	dur := k == .Line_Up || k == .Line_Down || k == .Line_Left || k == .Line_Right ? app.smooth_cfg.key_ms : app.smooth_cfg.page_ms
	if n, next, ok := key_scroll_container(app, t, start, k); ok {
		smooth_scroll_to(app, t, n, next, dur)
		return true
	}
	// the document (page_draw clamps the offsets)
	smooth_scroll_to(app, t, base.NIL_HANDLE, key_scroll_document(app, t, k, smooth_pending(app, t, base.NIL_HANDLE)), dur)
	return true
}

// The nearest scroll container from `start` up that can still move the way of `k`, and where it goes (ok = false: none, the
// document scrolls).
key_scroll_container :: proc(app: ^App, t: ^Tab, start: base.Handle, k: Key_Scroll) -> (node: base.Handle, next: [2]f32, ok: bool) {
	vertical := key_scroll_vertical(k)
	d := t.page.doc
	viewport := draw_size(app)
	for n := start; n != base.NIL_HANDLE; {
		dn := dom.get(d, n)
		if dn == nil { break }
		if limit, lok := lay.scroll_max(&t.layout, n); lok {
			cur := smooth_pending(app, t, n)
			port: f32
			if r, rok := lay.box_of(&t.layout, n, viewport, t.scroll); rok {
				port = vertical ? r.padding.max.y - r.padding.min.y : r.padding.max.x - r.padding.min.x
			}
			to := cur
			low := lay.scroll_min(&t.layout, n)
			if vertical { to.y = clamp(cur.y + key_amount(app, t, k, port, cur.y, limit.y), low.y, limit.y) } else { to.x = clamp(cur.x + key_amount(app, t, k, port, cur.x, limit.x), low.x, limit.x) }
			if abs(to.x - cur.x) >= 0.5 || abs(to.y - cur.y) >= 0.5 { return n, to, true }
		}
		n = dn.parent
	}
	return
}

// Where `k` takes the document's offsets from `cur`.
key_scroll_document :: proc(app: ^App, t: ^Tab, k: Key_Scroll, cur: [2]f32) -> [2]f32 {
	viewport := draw_size(app)
	next := cur
	if key_scroll_vertical(k) {
		lo, hi := lay.doc_scroll_y_range(&t.layout, viewport.y)
		next.y = clamp(cur.y + key_amount(app, t, k, viewport.y, cur.y, hi), lo, hi)
	} else {
		lo, hi := lay.doc_scroll_x_range(&t.layout, viewport.x)
		next.x = clamp(cur.x + key_amount(app, t, k, viewport.x, cur.x, hi), lo, hi)
	}
	return next
}

key_scroll_vertical :: proc(k: Key_Scroll) -> bool { return k != .Line_Left && k != .Line_Right }

// The distance along the axis for a scroller showing `port` px of it, at offset `cur` of `limit`.
@(private = "file")
key_amount :: proc(app: ^App, t: ^Tab, k: Key_Scroll, port, cur, limit: f32) -> f32 {
	line := app.cfg.key_line_px * (t.layout.scale > 0 ? t.layout.scale : 1)
	switch k {
	case .Line_Up, .Line_Left:    return -line
	case .Line_Down, .Line_Right: return line
	case .Page_Up:                return -max(port * app.cfg.key_page_fraction, line)
	case .Page_Down:              return max(port * app.cfg.key_page_fraction, line)
	case .Top:                    return -cur
	case .Bottom:                 return limit - cur
	case .None:
	}
	return 0
}

@(private = "file")
draw_size :: proc(app: ^App) -> [2]f32 { return {active_window(app).page_rect.max.x - active_window(app).page_rect.min.x, active_window(app).page_rect.max.y - active_window(app).page_rect.min.y} }
