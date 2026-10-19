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
	scale := t.layout.scale > 0 ? t.layout.scale : 1
	line := app.cfg.key_line_px * scale
	vertical := k != .Line_Left && k != .Line_Right
	// distance along the axis for a scroller showing `port` px of it, at offset `cur` of `limit`
	amount :: proc(k: Key_Scroll, line, port, cur, limit, fraction: f32) -> f32 {
		switch k {
		case .Line_Up, .Line_Left:    return -line
		case .Line_Down, .Line_Right: return line
		case .Page_Up:                return -max(port * fraction, line)
		case .Page_Down:              return max(port * fraction, line)
		case .Top:                    return -cur
		case .Bottom:                 return limit - cur
		case .None:
		}
		return 0
	}
	// smooth_scroll.odin: animated, from where the scroller is already going (held keys add up)
	dur := k == .Line_Up || k == .Line_Down || k == .Line_Left || k == .Line_Right ? smooth_cfg.key_ms : smooth_cfg.page_ms
	d := t.page.doc
	viewport := draw_size(app)
	for n := start; n != base.NIL_HANDLE; {
		node := dom.get(d, n)
		if node == nil { break }
		if limit, ok := lay.scroll_max(&t.layout, n); ok {
			cur := smooth_pending(app, t, n)
			port: f32
			if r, rok := lay.box_of(&t.layout, n, viewport, t.scroll); rok {
				port = vertical ? r.padding.max.y - r.padding.min.y : r.padding.max.x - r.padding.min.x
			}
			next := cur
			if vertical { next.y = clamp(cur.y + amount(k, line, port, cur.y, limit.y, app.cfg.key_page_fraction), 0, limit.y) } else { next.x = clamp(cur.x + amount(k, line, port, cur.x, limit.x, app.cfg.key_page_fraction), 0, limit.x) }
			if abs(next.x - cur.x) >= 0.5 || abs(next.y - cur.y) >= 0.5 {
				smooth_scroll_to(app, t, n, next, dur)
				return true
			}
		}
		n = node.parent
	}
	// the document scrolls vertically only (page_draw clamps the offset)
	if vertical {
		cur := smooth_pending(app, t, base.NIL_HANDLE).y
		limit := max(t.layout.height - viewport.y, 0)
		smooth_scroll_to(app, t, base.NIL_HANDLE, {0, clamp(cur + amount(k, line, viewport.y, cur, limit, app.cfg.key_page_fraction), 0, limit)}, dur)
	}
	return true
}

@(private = "file")
draw_size :: proc(app: ^App) -> [2]f32 { return {app.page_rect.max.x - app.page_rect.min.x, app.page_rect.max.y - app.page_rect.min.y} }
