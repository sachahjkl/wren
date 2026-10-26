package page

// The drag-and-drop processing model (HTML §6.11.5) as the shell drives it, one drag per page at a time. The shell
// hit-tests and calls:
//   drag_start (a press that moved on a draggable element, a link, an image or a selection) or drag_external_begin
//   (another application's drag came over the page), then drag_update at every move, drag_leave_page when the pointer
//   leaves the page, drag_drop at the release (or drag_cancel), and drag_finish with the operation that happened.
// The events carry the client coordinates, the modifiers, the buttons and the session's DataTransfer.

import "core:os"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:forms"
import lay "wb:layout"

// What starts a drag in a page (drag_source_for).
Drag_Source_Kind :: enum u8 { None, Element, Link, Image, Selection }

// What a drag carries in and out of the browser, independent of the system (the shell converts the toolkit's).
Drag_Payload :: struct {
	files:  []string,   // paths
	text:   string,
	html:   string,
	url:    string,
	custom: []Drag_Payload_Entry,
}

Drag_Payload_Entry :: struct { mime, data: string }

Drag_Session :: struct {
	store:       u64,           // the DataTransfer of every event of the drag (owned by the session)
	source:      base.Handle,   // NIL: from outside the page
	kind:        Drag_Source_Kind,
	current:     base.Handle,   // HTML "current target element"
	immediate:   base.Handle,   // the element under the pointer at the last update
	op:          Drag_Op,       // HTML "current drag operation"
	zone:        bool,          // the last dragover at the current target was cancelled: the page takes the drop
	os_allowed:  Drag_Ops,      // a drag from outside: what the other application allows
	x, y:        f64,
	mods:        u32,
	// a selection dragged from editable text (drag_set_source_text): what a move deletes once the text is dropped
	src_field:   base.Handle,   // a text field and its selection (bytes)
	src_a, src_b: int,
	src_host:    base.Handle,   // an editing host (contenteditable) and the selected range
	src_range:   [2]lay.Text_Pos,
	// where a drop of text would go (drag_set_caret: the shell follows the pointer)
	caret:       Drop_Caret,
	has_caret:   bool,
	default_kind: Drop_Default,   // what the current target does with an uncancelled drop
}

// Where dropped text goes: an offset (bytes) in a text field's value, or a point of an editing host.
Drop_Caret :: struct {
	node:   base.Handle,   // the text field, or the editing host
	field:  bool,
	offset: int,           // field: byte offset in its edit text
	pos:    lay.Text_Pos,  // editing host: the DOM point
}

// The default action of a drop the page does not cancel (HTML §6.11.5: text controls and editing hosts insert the
// text, a file input takes the files).
Drop_Default :: enum u8 { None, Text_Field, Editable, File_Input }

// The result of a drop (drag_drop).
Drop_Result :: struct {
	op:      Drag_Op,
	handled: bool,   // the page cancelled drop, or was a drop zone (cancelled dragover): no default action
}

drag_session :: proc(p: ^Page) -> ^Drag_Session { return p.drag if p != nil else nil }

@(private)
drag_session_free :: proc(p: ^Page) {
	s := p.drag
	if s == nil { return }
	p.drag = nil
	if !p.closed { object_release(p, s.store) }
	free(s)
}

@(private)
drag_session_new :: proc(p: ^Page, source: base.Handle, kind: Drag_Source_Kind, mode: Drag_Mode) -> ^Drag_Session {
	drag_session_free(p)
	s := new(Drag_Session)
	s.source, s.kind = source, kind
	s.store = store_new(p, 0, mode)
	p.drag = s
	base.on_close(p.scope, proc(data: rawptr) {
		pg := (^Page)(data)
		if s := pg.drag; s != nil { pg.drag = nil; free(s) }   // (the store goes with the page's objects)
	}, p)
	return s
}

// The element a press on `h` would drag, and why: the nearest ancestor with draggable="true", a link (<a href>), an
// image; draggable="false" on the way stops the search (HTML: links and images are draggable by default).
drag_source_for :: proc(p: ^Page, h: base.Handle) -> (base.Handle, Drag_Source_Kind) {
	if p == nil || p.doc == nil { return base.NIL_HANDLE, .None }
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(p.doc, cur)
		if n == nil { break }
		if n.kind == .Element {
			if v, ok := dom.get_attribute(p.doc, cur, "draggable"); ok {
				if strings.equal_fold(v, "true") { return cur, .Element }
				if strings.equal_fold(v, "false") { return base.NIL_HANDLE, .None }
			}
			switch n.name {
			case "img": return cur, .Image
			case "a", "area": if _, has := dom.get_attribute(p.doc, cur, "href"); has { return cur, .Link }
			case "input", "textarea", "select", "button": return base.NIL_HANDLE, .None
			}
		}
		cur = n.parent
	}
	return base.NIL_HANDLE, .None
}

// The data a link, an image or a selection carries before dragstart's listeners change it (HTML "drag data store
// item list" as browsers fill it).
@(private)
drag_defaults :: proc(p: ^Page, st: ^Drag_Store, source: base.Handle, kind: Drag_Source_Kind, selection_text: string) {
	resolve :: proc(p: ^Page, v: string) -> string {
		r, ok := resolve_url(p, v)
		return ok ? r : v
	}
	switch kind {
	case .Link:
		href, _ := dom.get_attribute(p.doc, source, "href")
		u := resolve(p, href)
		text := strings.trim_space(dom.text_content(p.doc, source, context.temp_allocator))
		store_set_string(st, "text/uri-list", u)
		store_set_string(st, "text/plain", u)
		store_set_string(st, "text/html", strings.concatenate({`<a href="`, html_attr_escape(u), `">`, html_text_escape(text != "" ? text : u), "</a>"}, context.temp_allocator))
		st.effect_allowed = "uninitialized"
	case .Image:
		src, _ := dom.get_attribute(p.doc, source, "src")
		u := resolve(p, src)
		store_set_string(st, "text/uri-list", u)
		store_set_string(st, "text/html", strings.concatenate({`<img src="`, html_attr_escape(u), `">`}, context.temp_allocator))
	case .Selection:
		store_set_string(st, "text/plain", selection_text)
	case .Element, .None:
	}
}

@(private)
html_attr_escape :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	r, _ = strings.replace_all(r, `"`, "&quot;", context.temp_allocator)
	return r
}

@(private)
html_text_escape :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	r, _ = strings.replace_all(r, "<", "&lt;", context.temp_allocator)
	return r
}

// The URL `v` resolved against the document's base URL.
@(private)
resolve_url :: proc(p: ^Page, v: string) -> (string, bool) {
	r, ok := resolve_against(v, document_base_url(p))
	if !ok { return "", false }
	out := strings.clone(r, context.temp_allocator)
	delete(r)
	return out, true
}

// Fires one drag event: the store in `mode` while it is dispatched, protected after.
@(private)
drag_fire :: proc(p: ^Page, s: ^Drag_Session, type: string, target: base.Handle, mode: Drag_Mode, buttons: u16 = 1) -> bool {
	if target == base.NIL_HANDLE || dom.get(p.doc, target) == nil { return true }
	if st := store_get(p, s.store); st != nil { st.mode = mode }
	cancelable := type != "dragleave" && type != "dragend"
	store := s.store
	ok := dispatch_event(p, target, dom.Event{type = type, bubbles = true, cancelable = cancelable, composed = true, x = s.x, y = s.y, mods = s.mods, buttons = buttons, object = store})
	if st := store_get(p, store); st != nil { st.mode = .Protected }
	return ok
}

// Starts a drag of `source` (drag_source_for, or the selection's element): dragstart, whose listeners may set the data,
// the allowed effects and the image. False when a listener cancelled it (no drag).
drag_start :: proc(p: ^Page, source: base.Handle, kind: Drag_Source_Kind, x, y: f64, mods: u32, selection_text := "") -> bool {
	if p == nil || p.closed || p.worker != nil { return false }
	s := drag_session_new(p, source, kind, .Read_Write)
	s.x, s.y, s.mods = x, y, mods
	if st := store_get(p, s.store); st != nil { drag_defaults(p, st, source, kind, selection_text) }
	if !drag_fire(p, s, "dragstart", source, .Read_Write) {
		drag_session_free(p)
		return false
	}
	return drag_session(p) == s
}

// Another application's drag came over the page: a session with no source, its data as a store in protected mode.
drag_external_begin :: proc(p: ^Page, payload: Drag_Payload, allowed: Drag_Ops) {
	if p == nil || p.closed || p.worker != nil { return }
	s := drag_session_new(p, base.NIL_HANDLE, .None, .Protected)
	s.os_allowed = allowed
	st := store_get(p, s.store)
	if st == nil { return }
	for e in payload.custom { store_set_string(st, e.mime, e.data) }
	if payload.text != "" { store_set_string(st, "text/plain", payload.text) }
	if payload.url != "" { store_set_string(st, "text/uri-list", payload.url) }
	if payload.html != "" { store_set_string(st, "text/html", payload.html) }
	for path in payload.files {
		if f, ok := local_file_from_path(path); ok {
			store_add_file(st, f)
			forms.file_destroy(&f)
		} else if os.is_dir(path) {
			store_add_dir(st, path)
		}
	}
	st.effect_allowed = effect_allowed_of(allowed)
}

@(private)
effect_allowed_of :: proc(ops: Drag_Ops) -> string {
	switch ops - {.None} {
	case {}: return "none"
	case {.Copy}: return "copy"
	case {.Link}: return "link"
	case {.Move}: return "move"
	case {.Copy, .Link}: return "copyLink"
	case {.Copy, .Move}: return "copyMove"
	case {.Link, .Move}: return "linkMove"
	}
	return "all"
}

// The operations effectAllowed lets through.
allowed_ops :: proc(effect_allowed: string) -> Drag_Ops {
	switch effect_allowed {
	case "none": return {}
	case "copy": return {.Copy}
	case "copyLink": return {.Copy, .Link}
	case "copyMove": return {.Copy, .Move}
	case "link": return {.Link}
	case "linkMove": return {.Link, .Move}
	case "move": return {.Move}
	}
	return {.Copy, .Link, .Move}   // all, uninitialized
}

// dropEffect before a dragenter / dragover (HTML's table): from effectAllowed, the source and the modifiers.
@(private)
initial_drop_effect :: proc(s: ^Drag_Session, effect_allowed: string) -> Drag_Op {
	switch effect_allowed {
	case "none": return .None
	case "copy": return .Copy
	case "link": return .Link
	case "move": return .Move
	case "copyLink": return s.mods & dom.MOD_ALT != 0 ? .Link : .Copy
	case "copyMove": return s.mods & dom.MOD_SHIFT != 0 ? .Move : .Copy
	case "linkMove": return s.mods & dom.MOD_SHIFT != 0 ? .Move : .Link
	case "all": return s.mods & dom.MOD_SHIFT != 0 ? .Move : .Copy
	}
	// uninitialized
	switch s.kind {
	case .Selection: return .Move
	case .Link: return .Link
	case .Element, .Image, .None:
	}
	return .Copy
}

// One step of the drag: the pointer is over `hit` (NIL: over nothing of the page) at client (x, y). A drag from the
// page first fires `drag` at its source (cancelled: the drag ends, returns ok = false). Then dragenter / dragleave as
// the current target changes, and dragover at it. Returns the operation a drop would do here.
drag_update :: proc(p: ^Page, hit: base.Handle, x, y: f64, mods: u32) -> (op: Drag_Op, ok: bool) {
	s := drag_session(p)
	if s == nil { return .None, false }
	s.x, s.y, s.mods = x, y, mods
	if s.source != base.NIL_HANDLE {
		if !drag_fire(p, s, "drag", s.source, .Protected) { return .None, false }
		if s = drag_session(p); s == nil { return .None, false }
	}
	st := store_get(p, s.store)
	if st == nil { return .None, false }
	if hit != s.immediate {
		s.immediate = hit
		prev := s.current
		if hit == base.NIL_HANDLE {
			s.current = base.NIL_HANDLE
		} else {
			// (the element under the pointer is the target whether or not dragenter was cancelled, as browsers do: the
			// standard's fallback to the body would hide the dragover most drop zones listen to)
			st.drop_effect = initial_drop_effect(s, st.effect_allowed)
			drag_fire(p, s, "dragenter", hit, .Protected)
			if s = drag_session(p); s == nil { return .None, false }
			s.current = hit
		}
		if prev != base.NIL_HANDLE && prev != s.current {
			drag_fire(p, s, "dragleave", prev, .Protected, 1)
			if s = drag_session(p); s == nil { return .None, false }
		}
	}
	s.op, s.zone = .None, false
	if s.current == base.NIL_HANDLE { return .None, true }
	if st = store_get(p, s.store); st == nil { return .None, false }
	st.drop_effect = initial_drop_effect(s, st.effect_allowed)
	cancelled := !drag_fire(p, s, "dragover", s.current, .Protected)
	if s = drag_session(p); s == nil { return .None, false }
	if st = store_get(p, s.store); st == nil { return .None, false }
	allowed := allowed_ops(st.effect_allowed)
	if s.source == base.NIL_HANDLE { allowed &= s.os_allowed }
	s.default_kind = .None
	if cancelled {
		s.zone = true
		s.op = st.drop_effect in allowed ? st.drop_effect : .None
	} else {
		s.op, s.default_kind = drop_default_op(p, s, st, allowed)   // dnd_default.odin
	}
	if s.default_kind != .Text_Field && s.default_kind != .Editable { s.has_caret = false }
	return s.op, true
}

@(private)
store_has_text :: proc(st: ^Drag_Store) -> bool {
	for it in st.items { if !it.is_file && (it.type == "text/plain" || it.type == "text/uri-list") { return true } }
	return false
}

// The pointer left the page (over the browser's own interface, or out of the window): dragleave at the current target.
drag_leave_page :: proc(p: ^Page) {
	s := drag_session(p)
	if s == nil { return }
	prev := s.current
	s.current, s.immediate, s.op, s.zone = base.NIL_HANDLE, base.NIL_HANDLE, .None, false
	if prev != base.NIL_HANDLE { drag_fire(p, s, "dragleave", prev, .Protected) }
}

// The user released the pointer over `hit`: a last update, then drop at the current target if the page accepted
// (read-only data), else dragleave ("drag failed").
drag_drop :: proc(p: ^Page, hit: base.Handle, x, y: f64, mods: u32) -> Drop_Result {
	s := drag_session(p)
	if s == nil { return {} }
	op, ok := drag_update(p, hit, x, y, mods)
	s = drag_session(p)
	if !ok || s == nil { return {} }
	zone := s.zone
	if s.current == base.NIL_HANDLE || op == .None {
		if s.current != base.NIL_HANDLE { drag_fire(p, s, "dragleave", s.current, .Protected, 0) }
		return {op = .None, handled = zone}
	}
	if st := store_get(p, s.store); st != nil { st.drop_effect = op }
	not_cancelled := drag_fire(p, s, "drop", s.current, .Read_Only, 0)
	s = drag_session(p)
	if s == nil { return {handled = true} }
	if !not_cancelled {
		if st := store_get(p, s.store); st != nil { op = st.drop_effect }
		s.op = op
		return {op = op, handled = true}
	}
	s.op = op
	if s.default_kind != .None {
		// the browser's default: the text goes into the field or the editing host, the files into the input
		op = drop_default_run(p, s, op)   // dnd_default.odin
		if s = drag_session(p); s != nil { s.op = op }
		return {op = op, handled = true}
	}
	return {op = op, handled = zone}
}

// The drag is over: dragend at the source (a drag from the page) with dropEffect = what happened, then the session goes.
drag_finish :: proc(p: ^Page, op: Drag_Op) {
	s := drag_session(p)
	if s == nil { return }
	if s.source != base.NIL_HANDLE {
		if st := store_get(p, s.store); st != nil { st.drop_effect = op }
		drag_fire(p, s, "dragend", s.source, .Protected, 0)
	}
	drag_session_free(p)
}

// Escape, or the pointer lost: dragleave at the current target, then dragend with "none".
drag_cancel :: proc(p: ^Page) {
	s := drag_session(p)
	if s == nil { return }
	if s.current != base.NIL_HANDLE { drag_fire(p, s, "dragleave", s.current, .Protected, 0) }
	drag_finish(p, .None)
}

// What a drag from the page carries to another application: the store's string items and its files (temporary
// allocator). The image, the allowed operations: drag_session_image, allowed_ops.
drag_session_payload :: proc(p: ^Page) -> (out: Drag_Payload, allowed: Drag_Ops) {
	s := drag_session(p)
	if s == nil { return }
	st := store_get(p, s.store)
	if st == nil { return }
	files := make([dynamic]string, context.temp_allocator)
	custom := make([dynamic]Drag_Payload_Entry, context.temp_allocator)
	for it in st.items {
		if it.is_file {
			if it.file.path != "" { append(&files, it.file.path) }
			continue
		}
		switch it.type {
		case "text/plain": out.text = it.data
		case "text/uri-list": out.url = uri_list_first(it.data)
		case "text/html": out.html = it.data
		case: append(&custom, Drag_Payload_Entry{it.type, it.data})
		}
	}
	out.files, out.custom = files[:], custom[:]
	return out, allowed_ops(st.effect_allowed)
}

// The pixels of an <img> or a <canvas> (in the document or not) for a drag image: straight RGBA (allocator), their size
// in pixels and the size the element shows them at (CSS px). ok = false for another element, or one with nothing to
// show yet.
drag_image_pixels :: proc(p: ^Page, h: base.Handle, allocator := context.allocator) -> (rgba: []u8, size: [2]int, css: [2]f64, ok: bool) {
	if p == nil || p.doc == nil { return }
	n := dom.get(p.doc, h)
	if n == nil || n.kind != .Element || (n.name != "img" && n.name != "canvas") { return }
	src := canvas_source(p, u64(h))
	if src.status != .Ok { return }
	bmp := canvas_source_bitmap(&src)
	if bmp == nil || bmp.w <= 0 || bmp.h <= 0 || len(bmp.pix) < bmp.w * bmp.h * 4 { return }
	rgba = make([]u8, bmp.w * bmp.h * 4, allocator)
	for i := 0; i < len(rgba); i += 4 {
		a := u32(bmp.pix[i + 3])
		rgba[i + 3] = u8(a)
		if a == 0 { continue }
		for k in 0 ..< 3 { rgba[i + k] = u8(min(u32(bmp.pix[i + k]) * 255 / a, 255)) }
	}
	return rgba, {bmp.w, bmp.h}, src.nat, true
}

// setDragImage's element and offset (NIL: the browser's own picture).
drag_session_image :: proc(p: ^Page) -> (base.Handle, [2]i32) {
	s := drag_session(p)
	if s == nil { return base.NIL_HANDLE, {} }
	st := store_get(p, s.store)
	if st == nil { return base.NIL_HANDLE, {} }
	return st.image, st.image_offset
}
