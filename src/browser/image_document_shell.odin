package browser

// The input of an image opened by itself (download.odin show_image_document) goes to its viewer (page/image_document.odin)
// before the page's routing sees it, as the canvas of about:history's tree takes its own (history_tree.odin):
//   * Ctrl+wheel over the page, and a touchpad's pinch (Windows sends it as one), zoom the image around the pointer, not
//     the page: in a viewer the image is what one zooms; Ctrl+Plus / Minus / 0 and the zoom controls still zoom the page;
//   * the wheel (Shift: across) and the arrows move the image, as they would scroll a page;
//   * a left press is the viewer's: a drag moves the image, a click toggles fit and 100 %, a double click resets;
//   * keys while the page has the keyboard: + / - zoom, 0 fits, R / Shift+R turn a quarter;
//   * the right button is left to the page's context menu (Rotate right / left: context_menu.odin).
// Pointer moves are not taken (the page still hovers); the press is, so the cursor follows the drag (grab, grabbing).

import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:page"

// Called by main.odin's frame with the events of the frame, before the page's routing; returns the others.
image_document_events :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	t := current_tab(app)
	if t == nil || t.kind != .Web || t.page == nil || !page.image_document_active(t.page) { return events }
	p := t.page
	wnd := active_window(app)
	scale := max(page_scale(app), 0.01)
	view := draw.rect_size(wnd.page_rect) / scale
	page.image_document_frame(p, view)
	out := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	for ev in events {
		at := (ev.pos - wnd.page_rect.min) / scale
		over := draw.rect_contains(wnd.page_rect, ev.pos) && !hud_captures(app, ev.pos) && !ui.ctx_menu_any_open() && ui.hot_key() == 0
		take := false
		#partial switch ev.kind {
		case .Scroll:
			take = over
			if !take { break }
			if .Ctrl in ev.mods { page.image_document_zoom(p, ev.delta.y, at) } else { page.image_document_pan(p, -wheel_axes(ev) * wheel_step(app, view)) }
		case .Mouse_Press:
			take = over && ev.button == .Left
			if !take { break }
			forms_view(app).page_focus = true   // (the page's keyboard, as a press on a page gives it)
			ui.set_focus(0)
			page.image_document_press(p, at)
		case .Mouse_Move:
			page.image_document_move(p, at)
		case .Mouse_Release:
			take = ev.button == .Left && page.image_document_pressed(p)
			if !take { break }
			double := app.page_settings.forms.double_click_ms > 0 ? f64(app.page_settings.forms.double_click_ms) : system_double_click_ms()
			page.image_document_release(p, at, double)
		case .Key_Press:
			take = page_has_keyboard(app) && image_document_key(app, p, ev)
		}
		if take { request_frames(app, 2) } else { append(&out, ev) }
	}
	return out[:]
}

// The viewer's keys (no Ctrl or Alt: those are the browser's).
@(private = "file")
image_document_key :: proc(app: ^App, p: ^page.Page, ev: platform.Event) -> bool {
	if .Ctrl in ev.mods || .Alt in ev.mods { return false }
	line := app.cfg.key_line_px
	#partial switch ev.key {
	case .Equal, .Num_Add:      page.image_document_zoom_step(p, 1)
	case .Minus, .Num_Subtract: page.image_document_zoom_step(p, -1)
	case .N0:                   page.image_document_fit(p)
	case .R:                    page.image_document_rotate(p, .Shift in ev.mods ? -1 : 1)
	case .Left:                 page.image_document_pan(p, {line, 0})
	case .Right:                page.image_document_pan(p, {-line, 0})
	case .Up:                   page.image_document_pan(p, {0, line})
	case .Down:                 page.image_document_pan(p, {0, -line})
	case: return false
	}
	return true
}
