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
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:fetch"
import "wb:instance"
import lay "wb:layout"
import "wb:page"

DND_PREFS := [?]config.Def{
	{name = "browser.dnd.src_page_events", kind = .Bool, default = {b = true},
		description = "Pages get HTML drag and drop: dragstart from draggable elements, links, images and the selection, and dragenter / dragover / drop for what is dragged over them (files from other applications included)."},
	{name = "browser.drop.open_links", kind = .Bool, default = {b = true},
		description = "A link or an address dropped on a page that does not take the drop is opened in that tab (on the tab strip: in a new tab)."},
}

register_dnd_prefs :: proc(p: ^config.Prefs) { config.register(p, DND_PREFS[:]) }

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
}

@(private = "file")
dnd: Dnd_Shell

dnd_page_events :: proc(app: ^App) -> bool { return config.bool_of(&app.prefs, "browser.dnd.src_page_events") }

// Start-up (local_paths.odin's drop_files_init): the window becomes a drop target, unless elevated.
dnd_init :: proc(app: ^App) {
	if instance.is_elevated() || app.win == nil { return }
	dnd.ole = platform.drop_target_enable(app.win, true)
}

dnd_destroy :: proc(app: ^App) {
	if dnd.ole && app.win != nil { platform.drop_target_enable(app.win, false) }
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
over_address :: proc(pos: [2]f32) -> bool {
	b := ui.box_from_key(address_key)
	return b != nil && draw.rect_contains(b.rect, pos)
}

@(private = "file")
chrome_open :: proc(app: ^App, address: string, pos: [2]f32) {
	if address == "" { return }
	if over_address(pos) && current_tab(app) != nil {
		navigate(app, current_tab(app), address, origin = .User)
		ui.field_set(&app.address, current_tab(app).url)
	} else {
		tab_open(app, address, origin = .User)
	}
	app.frames_requested = max(app.frames_requested, 3)
}

@(private = "file")
page_point :: proc(app: ^App, t: ^Tab, pos: [2]f32) -> (hit: base.Handle, cx, cy: f64) {
	scale := max(page_scale(app), 0.01)
	if t.layout.valid { hit = hit_test(&t.layout, pos - app.page_rect.min, draw.rect_size(app.page_rect), t.scroll) }
	if hit == base.NIL_HANDLE && t.page != nil { hit = t.page.body }
	return hit, f64((pos.x - app.page_rect.min.x) / scale), f64((pos.y - app.page_rect.min.y) / scale)
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
	if kind == .None && page.selection_active(p) {
		if tp, ok := position_of(app, t, ev.pos); ok {
			a, b, _ := page.selection_range(p)
			if lay.pos_compare(p.doc, a, tp) <= 0 && lay.pos_compare(p.doc, tp, b) < 0 {
				kind, text = .Selection, page.selection_text(p)
				source = pressed != base.NIL_HANDLE ? pressed : p.body
			}
		}
	}
	if kind == .None { return false }
	dnd.candidate, dnd.cand_page, dnd.cand_source, dnd.cand_kind = true, p, source, kind
	dnd.cand_pos, dnd.cand_local = ev.pos, ev.pos - app.page_rect.min + {0, t.scroll}
	dnd.cand_text = strings.clone(text)
	return true
}

@(private = "file")
dnd_clear_candidate :: proc() {
	delete(dnd.cand_text)
	dnd.candidate, dnd.cand_text, dnd.cand_page = false, "", nil
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
	if p != nil { page.drag_finish(p, op) }
}

// The pointer left the window during a drag from the page: the system's drag takes over until the drop.
@(private = "file")
hand_off :: proc(app: ^App, t: ^Tab) {
	p := dnd.src_page
	page.drag_leave_page(p)
	if t.page != p { end_page_drag(.None); return }
	pl, allowed := page.drag_session_payload(p)
	data: platform.Drag_Data
	defer { delete(data.files); delete(data.custom) }
	for f in pl.files { append(&data.files, f) }
	data.text, data.html, data.url = pl.text, pl.html, pl.url
	if data.url != "" && data.text == "" { data.text = data.url }
	for e in pl.custom { append(&data.custom, platform.Drag_Entry{e.mime, e.data}) }
	if platform.drag_data_empty(data) || allowed == {} { end_page_drag(.None); return }
	effect, _ := platform.drag_start(app.win, data, effects_of(allowed))
	if t.page != p { dnd.src_page = nil }
	end_page_drag(op_of(effect))
	app.frames_requested = max(app.frames_requested, 2)
}

// The frame's events, while a press may become a drag or a drag from the page goes on (route_page_input, before any
// other handler). True when the event was the drag's.
dnd_route :: proc(app: ^App, t: ^Tab, ev: platform.Event) -> bool {
	if dnd.candidate && !dnd.active {
		#partial switch ev.kind {
		case .Mouse_Move:
			if .Left not_in ev.buttons || t.page != dnd.cand_page { dnd_clear_candidate(); return false }
			d := ev.pos - dnd.cand_pos
			th := platform.drag_threshold(app.win)
			if abs(d.x) < th.x && abs(d.y) < th.y { return true }
			p := t.page
			cx, cy := page_client_xy(t, dnd.cand_local, page_scale(app))
			source, kind, text := dnd.cand_source, dnd.cand_kind, strings.clone(dnd.cand_text, context.temp_allocator)
			dnd_clear_candidate()
			sshell.down = false   // the selection gesture, if any, is over
			if !page.drag_start(p, source, kind, cx, cy, dom_mods(ev.mods), text) || t.page != p { return true }
			dnd.active, dnd.src_page = true, p
			page_set_active(p, base.NIL_HANDLE)
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
		size := [2]f32{f32(app.win.size.x), f32(app.win.size.y)}
		if ev.pos.x < 0 || ev.pos.y < 0 || ev.pos.x >= size.x || ev.pos.y >= size.y { hand_off(app, t); return true }
		if draw.rect_contains(app.page_rect, ev.pos) {
			dnd.over_chrome = false
			hit, cx, cy := page_point(app, t, ev.pos)
			op, ok := page.drag_update(p, hit, cx, cy, dom_mods(ev.mods))
			if !ok { end_page_drag(.None); return true }
			dnd.op = op
		} else {
			if !dnd.over_chrome { page.drag_leave_page(p) }
			dnd.over_chrome = true
			pl, _ := page.drag_session_payload(p)
			dnd.op = pl.url != "" ? .Link : .None
		}
		app.frames_requested = max(app.frames_requested, 2)
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
		app.frames_requested = max(app.frames_requested, 2)
		return true
	case .Key_Press:
		if ev.key == .Escape {
			dnd.active, dnd.src_page, dnd.op = false, nil, .None
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
	for ev in events {
		#partial switch ev.kind {
		case .Drop_Enter, .Drop_Over, .Drop_Leave, .Drop:
			dnd_external(app, ev)
		}
	}
}

@(private = "file")
end_external :: proc() {
	if dnd.ext_page != nil { page.drag_finish(dnd.ext_page, .None) }
	dnd.external, dnd.ext_page, dnd.over_chrome = false, nil, false
}

@(private = "file")
dnd_external :: proc(app: ^App, ev: platform.Event) {
	data := platform.drop_data(app.win)
	t := web_tab(app)
	over_page := t != nil && draw.rect_contains(app.page_rect, ev.pos) && dnd_page_events(app)
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
			if !ok { end_external(); platform.drop_set_effect(app.win, nil); return }
			// a page that does not take the drop: the browser's default (open the file / follow the link) shows as a link
			if op == .None && (s == nil || !s.zone) {
				if _, has := dropped_address(data); has && default_drop_allowed(app, data) { op = .Link in ops_of(ev.drop_allowed) ? .Link : .Copy }
			}
			platform.drop_set_effect(app.win, effect_of(op))
		} else {
			if dnd.ext_page != nil && !dnd.over_chrome { page.drag_leave_page(dnd.ext_page) }
			dnd.over_chrome = true
			_, has := dropped_address(data)
			platform.drop_set_effect(app.win, has ? platform.drop_effect_for(ev.drop_allowed, ev.mods, .Link) : nil)
		}
	case .Drop_Leave:
		if dnd.ext_page != nil { page.drag_leave_page(dnd.ext_page) }
		end_external()
		platform.drop_set_effect(app.win, nil)
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
		platform.drop_data_release(app.win)
		app.frames_requested = max(app.frames_requested, 2)
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
		ui.field_set(&app.address, current_tab(app).url)
		app.frames_requested = max(app.frames_requested, 3)
	}
}
