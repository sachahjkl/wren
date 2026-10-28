package browser

// Drag and drop in the shell, on the toolkit's drop target and drag source (platform/dragdrop.odin) and the page's
// processing model (src/page/dnd_session.odin):
//   * a drag that starts in the page: a left press on a draggable element, a link, an image or inside the selection
//     (not cancelled by mousedown) becomes a drag past the system's threshold: dragstart, then dragenter / dragover /
//     dragleave at the elements under the pointer, drop at the release, dragend at the source. No mouse event reaches
//     the page meanwhile. Over the browser's interface a link is opened at the release (the tab strip or the toolbar: a
//     new tab; the address field: the current tab). When the pointer leaves the window the drag becomes the system's
//     (platform.drag_start) and can be dropped in another application;
//   * a drag of another application over the window (Drop_* events): the same events with the dropped files as Files;
//     a page that cancelled dragover (a drop zone) or drop keeps the drop, otherwise the browser does what it did
//     before (browser.drop.open_files opens files, browser.drop.open_links follows a dropped link); over the browser's
//     interface, the same as a link dragged from a page.
// An elevated browser keeps the old WM_DROPFILES path (local_paths.odin): drags from a normal desktop cannot reach an
// elevated OLE target.

import "core:strings"
import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:dom"
import "wb:fetch"
import "wb:forms"
import "toolkit:instance"
import lay "wb:layout"
import "wb:page"

DND_PREFS := [?]config.Def{
	{name = "browser.dnd.src_page_events", kind = .Bool, default = {b = true},
		description = "Pages get HTML drag and drop: dragstart from draggable elements, links, images and the selection, and dragenter / dragover / drop for what is dragged over them (files from other applications included)."},
	{name = "browser.drop.open_links", kind = .Bool, default = {b = true},
		description = "A link or an address dropped on a page that does not take the drop is opened in that tab (on the tab strip: in a new tab)."},
}

register_dnd_prefs :: proc(p: ^config.Prefs) {
	config.register(p, DND_PREFS[:])
	config.register(p, DND_IMAGE_PREFS[:])   // dnd_image.odin
	register_touch_prefs(p)                  // touch_shell.odin
}

@(private = "file")
Dnd_Shell :: struct {
	// a press that may become a drag
	candidate:   bool,
	cand_page:   ^page.Page,
	cand_source: base.Handle,
	cand_kind:   page.Drag_Source_Kind,
	cand_pos:    [2]f32,
	cand_local:  [2]f32,
	cand_text:   string,          // owned: the selection's text
	cand_field:  base.Handle,     // the selection is a text field's (bytes cand_a..cand_b)
	cand_a, cand_b: int,
	cand_host:   base.Handle,     // the selection is inside this editing host (range cand_range)
	cand_range:  [2]lay.Text_Pos,
	// a drag from the page
	active:      bool,
	src_page:    ^page.Page,
	// a drag of the system over the window
	external:    bool,
	ext_page:    ^page.Page,
	// both
	over_chrome: bool,
	op:          page.Drag_Op,
	ole:         bool,            // the window is an OLE drop target
	// the system's drag of a page's drag (hand_off): its tab, and whether it is back over the page
	sync_tab:    ^Tab,
	sync_over:   bool,
	// the pointer left the window while the picture is still being read back
	handoff_pending: bool,
	handoff_frames:  int,
}

@(private = "file") HANDOFF_WAIT_FRAMES :: 4

@(private = "file")
dnd: Dnd_Shell

dnd_page_events :: proc(app: ^App) -> bool { return config.bool_of(&app.prefs, "browser.dnd.src_page_events") }

// Start-up (local_paths.odin's drop_files_init): the window becomes a drop target, unless elevated.
dnd_init :: proc(app: ^App) {
	if instance.is_elevated() || active_window(app).win == nil { return }
	dnd.ole = platform.drop_target_enable(active_window(app).win, true)
}

// Another window of the browser (windows.odin) is a drop target too, as the first one is.
dnd_window_attach :: proc(w: ^platform.Window) { if dnd.ole { platform.drop_target_enable(w, true) } }
dnd_window_detach :: proc(w: ^platform.Window) { if dnd.ole { platform.drop_target_enable(w, false) } }

dnd_destroy :: proc(app: ^App) {
	dnd_image_end(app)
	if dnd.ole && active_window(app).win != nil { platform.drop_target_enable(active_window(app).win, false) }
	delete(dnd.cand_text)
	dnd = {}
}

@(private = "file")
op_of :: proc(e: Maybe(platform.Drop_Effect)) -> page.Drag_Op {
	v, ok := e.?
	if !ok { return .None }
	switch v {
	case .Copy: return .Copy
	case .Move: return .Move
	case .Link: return .Link
	}
	return .None
}

@(private = "file")
effect_of :: proc(op: page.Drag_Op) -> Maybe(platform.Drop_Effect) {
	switch op {
	case .Copy: return .Copy
	case .Move: return .Move
	case .Link: return .Link
	case .None:
	}
	return nil
}

@(private = "file")
ops_of :: proc(e: platform.Drop_Effects) -> (out: page.Drag_Ops) {
	if .Copy in e { out += {.Copy} }
	if .Move in e { out += {.Move} }
	if .Link in e { out += {.Link} }
	return
}

@(private = "file")
effects_of :: proc(o: page.Drag_Ops) -> (out: platform.Drop_Effects) {
	if .Copy in o { out += {.Copy} }
	if .Move in o { out += {.Move} }
	if .Link in o { out += {.Link} }
	return
}

// The toolkit's drag data as the page's payload (temporary allocator, views into `d`).
@(private = "file")
payload_of :: proc(d: ^platform.Drag_Data) -> page.Drag_Payload {
	if d == nil { return {} }
	custom := make([]page.Drag_Payload_Entry, len(d.custom), context.temp_allocator)
	for e, i in d.custom { custom[i] = {e.mime, e.data} }
	return page.Drag_Payload{files = d.files[:], text = d.text, html = d.html, url = d.url, custom = custom}
}

// The address a drop carries for the browser's own default: the first file (as a file: URL), else the link.
@(private = "file")
dropped_address :: proc(d: ^platform.Drag_Data) -> (string, bool) {
	if d == nil { return "", false }
	if len(d.files) > 0 { return fetch.file_url_from_path(d.files[0], false, context.temp_allocator), true }
	if d.url != "" { return d.url, true }
	if s := strings.trim_space(d.text); s != "" && !strings.contains_any(s, " \n\t") && (strings.has_prefix(s, "http://") || strings.has_prefix(s, "https://")) { return s, true }
	return "", false
}

// Over the address field (the current tab loads it) or elsewhere in the browser's interface (a new tab).
@(private = "file")
over_address :: proc(app: ^App, pos: [2]f32) -> bool {
	b := ui.box_from_key(address_key(app))
	return b != nil && draw.rect_contains(b.rect, pos)
}

@(private = "file")
chrome_open :: proc(app: ^App, address: string, pos: [2]f32) {
	if address == "" { return }
	if over_address(app, pos) && current_tab(app) != nil {
		navigate(app, current_tab(app), address, origin = .User)
		ui.field_set(&active_window(app).address, current_tab(app).url)
	} else {
		tab_open(app, address, origin = .User)
	}
	request_frames(app, 3)
}

@(private = "file")
page_point :: proc(app: ^App, t: ^Tab, pos: [2]f32) -> (hit: base.Handle, cx, cy: f64) {
	wnd := active_window(app)
	scale := max(page_scale(app), 0.01)
	if t.layout.valid { hit = hit_test(&t.layout, pos - wnd.page_rect.min, draw.rect_size(wnd.page_rect), t.scroll) }
	if hit == base.NIL_HANDLE && t.page != nil { hit = t.page.body }
	return hit, f64((pos.x - wnd.page_rect.min.x) / scale), f64((pos.y - wnd.page_rect.min.y) / scale)
}

@(private = "file")
web_tab :: proc(app: ^App) -> ^Tab {
	t := current_tab(app)
	if t == nil || t.kind != .Web || t.page == nil { return nil }
	return t
}

////////////////////////////////
// Drags from the page

// A left press on the page that mousedown did not cancel: may it become a drag? True when the press must not start a
// text selection (it is on something draggable, or inside the selection).
dnd_press :: proc(app: ^App, t: ^Tab, ev: platform.Event, pressed: base.Handle) -> bool {
	dnd_clear_candidate()
	p := t.page
	if p == nil || ev.button != .Left || !dnd_page_events(app) { return false }
	source, kind := page.drag_source_for(p, pressed)
	text := ""
	// selected text of a field (the press kept the selection: forms_shell.odin)
	if kind == .None {
		if field, a, b, ftext, ok := forms_take_selection_press(app, p); ok && field == pressed {
			kind, text, source = .Selection, ftext, field
			dnd.cand_field, dnd.cand_a, dnd.cand_b = field, a, b
		}
	}
	if kind == .None && page.selection_active(p) {
		if tp, ok := position_of(app, t, ev.pos); ok {
			a, b, _ := page.selection_range(p)
			if lay.pos_compare(p.doc, a, tp) <= 0 && lay.pos_compare(p.doc, tp, b) < 0 {
				kind, text = .Selection, page.selection_text(p)
				source = pressed != base.NIL_HANDLE ? pressed : p.body
				// inside an editing host: a move takes the text out of it
				if host := page.editing_host_of(p, a.node); host != base.NIL_HANDLE && host == page.editing_host_of(p, b.node) {
					dnd.cand_host, dnd.cand_range = host, {a, b}
				}
			}
		}
	}
	if kind == .None { return false }
	dnd.candidate, dnd.cand_page, dnd.cand_source, dnd.cand_kind = true, p, source, kind
	dnd.cand_pos, dnd.cand_local = ev.pos, ev.pos - active_window(app).page_rect.min + {0, t.scroll}
	dnd.cand_text = strings.clone(text)
	return true
}

@(private = "file")
dnd_clear_candidate :: proc() {
	delete(dnd.cand_text)
	dnd.candidate, dnd.cand_text, dnd.cand_page = false, "", nil
	dnd.cand_field, dnd.cand_host = base.NIL_HANDLE, base.NIL_HANDLE
}

// Whether a drag (from the page, or of the system) is in progress: page input is the drag's.
dnd_active :: proc() -> bool { return dnd.active }

// The window's cursor while a drag from the page is in progress (the operation a drop would do here).
dnd_cursor :: proc() -> (platform.Cursor, bool) {
	if !dnd.active { return .Arrow, false }
	switch dnd.op {
	case .Copy: return .Copy, true
	case .Link: return .Alias, true
	case .Move: return .Arrow, true
	case .None: return .No_Drop, true
	}
	return .Arrow, true
}

@(private = "file")
end_page_drag :: proc(op: page.Drag_Op) {
	p := dnd.src_page
	dnd.active, dnd.src_page, dnd.op, dnd.over_chrome = false, nil, .None, false
	dnd.handoff_pending = false
	dnd_image_end(the_app)
	dnd_image_target(nil)
	if p != nil { page.drag_finish(p, op) }
}

// The pointer left the window during a drag from the page: the system's drag takes over until the drop, with the
// picture the shell drew. When it comes back over the window while the system's loop runs, the window's drop target
// asks the shell at once (dnd_sync): the page gets dragenter / dragover / drop from the same session, so `drop` comes
// before `dragend`, and dragend carries the effect of the drop, as the standard orders them.
@(private = "file")
hand_off :: proc(app: ^App, t: ^Tab) {
	wnd := active_window(app)
	p := dnd.src_page
	page.drag_leave_page(p)
	set_caret(app, p, nil)
	dnd_image_target(nil)
	if t.page != p { end_page_drag(.None); return }
	pl, allowed := page.drag_session_payload(p)
	data: platform.Drag_Data
	defer { delete(data.files); delete(data.custom) }
	for f in pl.files { append(&data.files, f) }
	data.text, data.html, data.url = pl.text, pl.html, pl.url
	if data.url != "" && data.text == "" { data.text = data.url }
	for e in pl.custom { append(&data.custom, platform.Drag_Entry{e.mime, e.data}) }
	if platform.drag_data_empty(data) || allowed == {} { end_page_drag(.None); return }
	// the remote control's drag goes on through the window's own drop target; a window nobody sees (driven by it)
	// never runs the system's drag, which would follow the real mouse of the person at the computer
	steps, scripted := remote_drag_steps(app)   // remote_methods.odin
	if scripted {
		platform.drag_script(wnd.win, steps)
	} else if !win.IsWindowVisible(wnd.win.hwnd) {
		end_page_drag(.None)
		return
	}
	platform.drop_sync_set(wnd.win, dnd_sync, app)
	defer platform.drop_sync_set(wnd.win, nil, nil)
	dnd.sync_tab, dnd.sync_over = t, false
	dnd_image_system_shows(true)
	effect, _ := platform.drag_start(wnd.win, data, effects_of(allowed), dnd_image_system())
	dnd.sync_tab = nil
	if t.page != p { dnd.src_page = nil }
	end_page_drag(op_of(effect))
	request_frames(app, 2)
}

// The window's drop target while the system's drag of a page's drag runs (hand_off): the drag came back over the
// window. The same steps as a drag inside the window, at once; the answer is the operation a drop would do.
@(private = "file")
dnd_sync :: proc(user: rawptr, w: ^platform.Window, ev: platform.Event) -> Maybe(platform.Drop_Effect) {
	app := (^App)(user)
	t := dnd.sync_tab
	p := dnd.src_page
	if t == nil || p == nil || t.page != p || page.drag_session(p) == nil { return nil }
	over_page := draw.rect_contains(active_window(app).page_rect, ev.pos)
	#partial switch ev.kind {
	case .Drop_Enter, .Drop_Over:
		if !over_page {
			if dnd.sync_over { page.drag_leave_page(p); set_caret(app, p, nil) }
			dnd.sync_over = false
			pl, _ := page.drag_session_payload(p)
			return pl.url != "" ? platform.drop_effect_for(ev.drop_allowed, ev.mods, .Link) : nil
		}
		dnd.sync_over = true
		hit, cx, cy := page_point(app, t, ev.pos)
		op, ok := page.drag_update(p, hit, cx, cy, dom_mods(ev.mods))
		if !ok { return nil }
		follow_caret(app, t, p, ev.pos)
		return effect_of(op)
	case .Drop_Leave:
		if dnd.sync_over { page.drag_leave_page(p); set_caret(app, p, nil) }
		dnd.sync_over = false
	case .Drop:
		dnd.sync_over = false
		if !over_page {
			pl, _ := page.drag_session_payload(p)
			if pl.url != "" { chrome_open(app, strings.clone(pl.url, context.temp_allocator), ev.pos); return .Link }
			return nil
		}
		hit, cx, cy := page_point(app, t, ev.pos)
		res := page.drag_drop(p, hit, cx, cy, dom_mods(ev.mods))
		return effect_of(res.op)
	}
	return nil
}

// The drop caret (where dragged text would go) at the pointer, over a field or an editing host the drag is over.
@(private = "file")
follow_caret :: proc(app: ^App, t: ^Tab, p: ^page.Page, pos: [2]f32) {
	s := page.drag_session(p)
	if s == nil { return }
	dnd_image_target(nil)
	kind, el := page.drop_default_of(p, s.current)
	if s.default_kind == .None { kind = .None }
	switch kind {
	case .None: set_caret(app, p, nil)
	case .Text_Field:
		if p.formctl == nil { set_caret(app, p, nil); return }
		if at, ok := forms_field_offset_at(app, page.page_forms(p), el, pos); ok {
			set_caret(app, p, page.Drop_Caret{node = el, field = true, offset = at})
		} else {
			set_caret(app, p, nil)
		}
	case .Editable:
		if tp, ok := position_of(app, t, pos); ok && page.editing_host_of(p, tp.node) == el {
			set_caret(app, p, page.Drop_Caret{node = el, pos = tp})
		} else {
			set_caret(app, p, nil)
		}
	case .File_Input:
		set_caret(app, p, nil)
		if r, ok := element_window_rect(app, t, el); ok { dnd_image_target(r) }
	}
}

@(private = "file")
set_caret :: proc(app: ^App, p: ^page.Page, c: Maybe(page.Drop_Caret)) {
	if p == nil { return }
	old, had := page.drag_caret(p)
	page.drag_set_caret(p, c)
	now, has := page.drag_caret(p)
	if had == has && old == now { return }
	// a field's caret is painted with the field: it paints again
	if p.formctl != nil {
		f := page.page_forms(p)
		if had && old.field && dom.get(p.doc, old.node) != nil { forms.changed(f, old.node) }
		if has && now.field { forms.changed(f, now.node) }
	}
	request_frames(app, 2)
}

// The drop caret in text field `node` (forms_shell.odin paints it), when text is dragged over it.
dnd_field_caret :: proc(node: base.Handle) -> (int, bool) {
	for p in ([]^page.Page{dnd.src_page, dnd.ext_page}) {
		if p == nil { continue }
		if c, ok := page.drag_caret(p); ok && c.field && c.node == node { return c.offset, true }
	}
	return 0, false
}

// The frame's events, while a press may become a drag or a drag from the page goes on (route_page_input, before any
// other handler). True when the event was the drag's.
dnd_route :: proc(app: ^App, t: ^Tab, ev: platform.Event) -> bool {
	wnd := active_window(app)
	if dnd.candidate && !dnd.active {
		#partial switch ev.kind {
		case .Mouse_Move:
			if .Left not_in ev.buttons || t.page != dnd.cand_page { dnd_clear_candidate(); return false }
			d := ev.pos - dnd.cand_pos
			th := platform.drag_threshold(wnd.win)
			if abs(d.x) < th.x && abs(d.y) < th.y { return true }
			p := t.page
			cx, cy := page_client_xy(t, dnd.cand_local, page_scale(app))
			source, kind, text := dnd.cand_source, dnd.cand_kind, strings.clone(dnd.cand_text, context.temp_allocator)
			field, fa, fb := dnd.cand_field, dnd.cand_a, dnd.cand_b
			host, hrange := dnd.cand_host, dnd.cand_range
			press := dnd.cand_pos
			dnd_clear_candidate()
			forms_drop_selection_press(app)   // (the release is the drag's, not a click in the field's selection)
			window_own(app).selection.down = false   // the selection gesture, if any, is over
			if !page.drag_start(p, source, kind, cx, cy, dom_mods(ev.mods), text) || t.page != p { return true }
			if field != base.NIL_HANDLE { page.drag_set_source_field(p, field, fa, fb) }
			if host != base.NIL_HANDLE { page.drag_set_source_range(p, host, hrange[0], hrange[1]) }
			dnd.active, dnd.src_page = true, p
			dnd.handoff_pending, dnd.handoff_frames = false, 0
			page_set_active(p, base.NIL_HANDLE)
			dnd_image_begin(app, t, p, press)   // dnd_image.odin: grabbed where the press was
			return dnd_route(app, t, ev)
		case .Mouse_Release:
			if ev.button == .Left {
				if dnd.cand_kind == .Selection && t.page == dnd.cand_page { page.selection_clear(t.page) }   // a click in the selection
				dnd_clear_candidate()
			}
		}
		return false
	}
	if !dnd.active { return false }
	p := dnd.src_page
	if t.page != p || p == nil { end_page_drag(.None); return false }
	#partial switch ev.kind {
	case .Mouse_Move:
		size := [2]f32{f32(wnd.win.size.x), f32(wnd.win.size.y)}
		if ev.pos.x < 0 || ev.pos.y < 0 || ev.pos.x >= size.x || ev.pos.y >= size.y {
			// the picture is read back from a frame or two after the drag started: the system's drag waits for it (a
			// few frames at most: dnd_events)
			if dnd_image_waiting() && dnd.handoff_frames < HANDOFF_WAIT_FRAMES {
				dnd.handoff_pending = true
				request_frames(app, 2)
				return true
			}
			dnd.handoff_pending = false
			hand_off(app, t)
			return true
		}
		dnd.handoff_pending = false
		dnd_image_move(ev.pos)
		if draw.rect_contains(wnd.page_rect, ev.pos) {
			dnd.over_chrome = false
			hit, cx, cy := page_point(app, t, ev.pos)
			op, ok := page.drag_update(p, hit, cx, cy, dom_mods(ev.mods))
			if !ok { end_page_drag(.None); return true }
			dnd.op = op
			follow_caret(app, t, p, ev.pos)
		} else {
			if !dnd.over_chrome { page.drag_leave_page(p); set_caret(app, p, nil); dnd_image_target(nil) }
			dnd.over_chrome = true
			pl, _ := page.drag_session_payload(p)
			dnd.op = pl.url != "" ? .Link : .None
		}
		request_frames(app, 2)
		return true
	case .Mouse_Leave:
		hand_off(app, t)
		return true
	case .Mouse_Release:
		if ev.button != .Left { return true }
		op := page.Drag_Op.None
		if dnd.over_chrome {
			pl, _ := page.drag_session_payload(p)
			if pl.url != "" { chrome_open(app, strings.clone(pl.url, context.temp_allocator), ev.pos); op = .Link }
		} else {
			hit, cx, cy := page_point(app, t, ev.pos)
			op = page.drag_drop(p, hit, cx, cy, dom_mods(ev.mods)).op
		}
		if t.page != p { dnd.src_page = nil }
		end_page_drag(op)
		request_frames(app, 2)
		return true
	case .Key_Press:
		if ev.key == .Escape {
			dnd.active, dnd.src_page, dnd.op = false, nil, .None
			dnd_image_end(app)
			dnd_image_target(nil)
			page.drag_cancel(p)
			return true
		}
	case .Mouse_Press:
		return true
	}
	return false
}

////////////////////////////////
// Drags of the system over the window

// Every event of the frame (main.odin, before the page's routing): the Drop_* events of the toolkit.
dnd_events :: proc(app: ^App, events: []platform.Event) {
	touch_frame(app)   // touch_shell.odin: a finger held still (the long press), every frame while one is down
	if dnd.handoff_pending {
		dnd.handoff_frames += 1
		if t := current_tab(app); t != nil && dnd.active && t.page == dnd.src_page {
			if !dnd_image_waiting() || dnd.handoff_frames >= HANDOFF_WAIT_FRAMES { dnd.handoff_pending = false; hand_off(app, t) }
			else { request_frames(app, 2) }
		} else {
			dnd.handoff_pending = false
		}
	}
	for ev in events {
		#partial switch ev.kind {
		case .Drop_Enter, .Drop_Over, .Drop_Leave, .Drop:
			dnd_external(app, ev)
		}
	}
}

@(private = "file")
end_external :: proc() {
	dnd_image_target(nil)
	if dnd.ext_page != nil { page.drag_finish(dnd.ext_page, .None) }
	dnd.external, dnd.ext_page, dnd.over_chrome = false, nil, false
}

@(private = "file")
dnd_external :: proc(app: ^App, ev: platform.Event) {
	wnd := active_window(app)
	data := platform.drop_data(wnd.win)
	t := web_tab(app)
	over_page := t != nil && draw.rect_contains(wnd.page_rect, ev.pos) && dnd_page_events(app)
	if t != nil && dnd.ext_page != nil && t.page != dnd.ext_page { end_external() }
	#partial switch ev.kind {
	case .Drop_Enter, .Drop_Over:
		if ev.kind == .Drop_Enter { end_external(); dnd.external = true }
		if over_page {
			if dnd.ext_page == nil {
				page.drag_external_begin(t.page, payload_of(data), ops_of(ev.drop_allowed))
				dnd.ext_page = t.page
			}
			dnd.over_chrome = false
			hit, cx, cy := page_point(app, t, ev.pos)
			op, ok := page.drag_update(t.page, hit, cx, cy, dom_mods(ev.mods))
			s := page.drag_session(t.page)
			if !ok { end_external(); platform.drop_set_effect(wnd.win, nil); return }
			follow_caret(app, t, t.page, ev.pos)
			// a page that does not take the drop: the browser's default (open the file / follow the link) shows as a link
			if op == .None && (s == nil || !s.zone) {
				if _, has := dropped_address(data); has && default_drop_allowed(app, data) { op = .Link in ops_of(ev.drop_allowed) ? .Link : .Copy }
			}
			platform.drop_set_effect(wnd.win, effect_of(op))
		} else {
			if dnd.ext_page != nil && !dnd.over_chrome { page.drag_leave_page(dnd.ext_page); set_caret(app, dnd.ext_page, nil); dnd_image_target(nil) }
			dnd.over_chrome = true
			_, has := dropped_address(data)
			platform.drop_set_effect(wnd.win, has ? platform.drop_effect_for(ev.drop_allowed, ev.mods, .Link) : nil)
		}
	case .Drop_Leave:
		if dnd.ext_page != nil { page.drag_leave_page(dnd.ext_page) }
		end_external()
		platform.drop_set_effect(wnd.win, nil)
	case .Drop:
		handled := false
		if over_page {
			if dnd.ext_page == nil {
				page.drag_external_begin(t.page, payload_of(data), ops_of(ev.drop_allowed))
				dnd.ext_page = t.page
			}
			hit, cx, cy := page_point(app, t, ev.pos)
			handled = page.drag_drop(t.page, hit, cx, cy, dom_mods(ev.mods)).handled
		}
		end_external()
		if !handled { default_drop(app, data, ev.pos, over_page) }
		platform.drop_data_release(wnd.win)
		request_frames(app, 2)
	}
}

@(private = "file")
default_drop_allowed :: proc(app: ^App, d: ^platform.Drag_Data) -> bool {
	if d == nil { return false }
	if len(d.files) > 0 { return config.bool_of(&app.prefs, "browser.drop.open_files") }
	return config.bool_of(&app.prefs, "browser.drop.open_links")
}

// What the browser does with a drop no page took: files open (the first here, the others in new tabs), a link loads.
@(private = "file")
default_drop :: proc(app: ^App, d: ^platform.Drag_Data, pos: [2]f32, over_page: bool) {
	if d == nil || !default_drop_allowed(app, d) { return }
	if !over_page {
		if a, ok := dropped_address(d); ok { chrome_open(app, a, pos) }
		for f in d.files[min(1, len(d.files)):] { tab_open(app, fetch.file_url_from_path(f, false, context.temp_allocator), origin = .User) }
		return
	}
	if len(d.files) > 0 {
		paths := make([]string, len(d.files), context.temp_allocator)
		copy(paths, d.files[:])
		open_dropped_paths(app, paths)
		return
	}
	if a, ok := dropped_address(d); ok && current_tab(app) != nil {
		navigate(app, current_tab(app), a, origin = .User)
		ui.field_set(&active_window(app).address, current_tab(app).url)
		request_frames(app, 3)
	}
}
