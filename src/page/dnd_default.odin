package page

// The browser's own part of a drop (HTML §6.11.5, "otherwise" branches of the drop step; Input Events): when the page
// does not cancel dragover / drop over
//   * a text field or a textarea, or an editing host (contenteditable): the dragged text is inserted where the drop
//     caret is (the shell follows the pointer with it: drag_set_caret), with beforeinput / input of inputType
//     "insertFromDrop" (cancelable: nothing is inserted then). A selection dragged out of editable text of the page is
//     moved (dropEffect "move": Ctrl copies): first "deleteByDrag" at the source, then the insertion; the dropped text
//     ends up selected and its field focused, as in other browsers;
//   * an <input type=file> that is not disabled: it takes the dropped files that fit its `accept` (all of them with
//     `multiple`, else the first), with input and change; a disabled one refuses the drop.

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:forms"
import lay "wb:layout"

// What `h` (the current target of a drag) would do with a drop nobody cancels, and the element that does it.
drop_default_of :: proc(p: ^Page, h: base.Handle) -> (Drop_Default, base.Handle) {
	if p == nil || p.doc == nil || h == base.NIL_HANDLE { return .None, base.NIL_HANDLE }
	if p.formctl != nil {
		f := page_forms(p)
		if forms.is_text_field(f, h) { return .Text_Field, h }
		if forms.kind(f, h) == .Input && forms.input_type(f, h) == .File { return .File_Input, h }
	}
	if host := editing_host_of(p, h); host != base.NIL_HANDLE { return .Editable, host }
	return .None, base.NIL_HANDLE
}

// The editing host `h` is in: the nearest ancestor (or itself) whose contenteditable is true / plaintext-only (an
// explicit false ends the search).
editing_host_of :: proc(p: ^Page, h: base.Handle) -> base.Handle {
	host := base.NIL_HANDLE
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(p.doc, cur)
		if n == nil { break }
		if n.kind == .Element {
			if v, ok := dom.get_attribute(p.doc, cur, "contenteditable"); ok {
				if v == "" || strings.equal_fold(v, "true") || strings.equal_fold(v, "plaintext-only") { host = cur } else { break }
			}
		}
		cur = n.parent
	}
	return host
}

// The text a drop inserts: text/plain, else the first URL of text/uri-list.
@(private)
drop_text_of :: proc(st: ^Drag_Store) -> (string, bool) {
	if s, ok := store_get_string(st, "text/plain"); ok { return s, true }
	for it in st.items { if !it.is_file && it.type == "text/uri-list" { return uri_list_first(it.data), true } }
	return "", false
}

// The operation and the default action at the current target (dragover not cancelled).
@(private)
drop_default_op :: proc(p: ^Page, s: ^Drag_Session, st: ^Drag_Store, allowed: Drag_Ops) -> (Drag_Op, Drop_Default) {
	kind, el := drop_default_of(p, s.current)
	switch kind {
	case .None:
	case .Text_Field:
		if !store_has_text(st) || !forms.is_mutable(page_forms(p), el) { return .None, .None }
		return text_drop_op(s, allowed), kind
	case .Editable:
		if !store_has_text(st) { return .None, .None }
		return text_drop_op(s, allowed), kind
	case .File_Input:
		f := page_forms(p)
		if file_count(st) == 0 || forms.is_disabled(f, el) { return .None, .None }
		return .Copy in allowed ? .Copy : .None, kind
	}
	return .None, .None
}

// Text moves when it is a selection of editable text of this page (Ctrl copies), else it is copied.
@(private)
text_drop_op :: proc(s: ^Drag_Session, allowed: Drag_Ops) -> Drag_Op {
	movable := s.src_field != base.NIL_HANDLE || s.src_host != base.NIL_HANDLE
	if movable && s.mods & dom.MOD_CTRL == 0 && .Move in allowed { return .Move }
	if .Copy in allowed { return .Copy }
	if .Move in allowed { return .Move }
	return .None
}

// The drag carries a selection of a text field (bytes of its edit text): a move deletes it.
drag_set_source_field :: proc(p: ^Page, field: base.Handle, a, b: int) {
	if s := drag_session(p); s != nil { s.src_field, s.src_a, s.src_b = field, min(a, b), max(a, b) }
}

// The drag carries a selection inside an editing host: a move deletes the range.
drag_set_source_range :: proc(p: ^Page, host: base.Handle, a, b: lay.Text_Pos) {
	if s := drag_session(p); s != nil { s.src_host, s.src_range = host, {a, b} }
}

// Where text would be dropped now (nil: nowhere, the caret is hidden).
drag_set_caret :: proc(p: ^Page, caret: Maybe(Drop_Caret)) {
	s := drag_session(p)
	if s == nil { return }
	c, ok := caret.?
	s.caret, s.has_caret = c, ok
}

// The drop caret the shell paints while text is dragged over editable text.
drag_caret :: proc(p: ^Page) -> (Drop_Caret, bool) {
	s := drag_session(p)
	if s == nil || !s.has_caret || (s.default_kind != .Text_Field && s.default_kind != .Editable) { return {}, false }
	return s.caret, true
}

// The default action of the drop (the page let it through): returns the operation that happened (none when a
// listener cancelled the insertion).
@(private)
drop_default_run :: proc(p: ^Page, s: ^Drag_Session, op: Drag_Op) -> Drag_Op {
	st := store_get(p, s.store)
	if st == nil { return .None }
	kind, el := drop_default_of(p, s.current)
	switch kind {
	case .None: return .None
	case .File_Input: return drop_files_into(p, st, el) ? .Copy : .None
	case .Text_Field, .Editable:
	}
	text, has := drop_text_of(st)
	if !has || text == "" { return .None }
	text = strings.clone(text, context.temp_allocator)
	caret := s.caret
	if !s.has_caret || caret.node != el {
		// no caret from the shell (a drop without a move over the element): the end of the field / host
		caret = kind == .Text_Field ? Drop_Caret{node = el, field = true, offset = len(forms.edit_text(page_forms(p), el))} : Drop_Caret{node = el, pos = {el, lay.child_count(p.doc, el)}}
	}
	src_field, sa, sb := s.src_field, s.src_a, s.src_b
	src_host, src_range := s.src_host, s.src_range
	// dropped onto the selection it came from: nothing happens (browsers ignore it)
	if kind == .Text_Field && src_field == el && caret.offset >= sa && caret.offset <= sb { return .None }
	if kind == .Editable && src_host != base.NIL_HANDLE && lay.pos_compare(p.doc, src_range[0], caret.pos) <= 0 && lay.pos_compare(p.doc, caret.pos, src_range[1]) <= 0 { return .None }
	if op == .Move {
		if src_field != base.NIL_HANDLE && dom.get(p.doc, src_field) != nil {
			f := page_forms(p)
			forms.set_selection(f, src_field, sa, sb)
			if forms.edit(f, src_field, .Delete_By_Drag) && src_field == el && caret.offset > sb { caret.offset -= sb - sa }
		} else if src_host != base.NIL_HANDLE && dom.get(p.doc, src_host) != nil {
			caret = delete_dragged_range(p, src_host, src_range, caret)
		}
		if drag_session(p) != s { return op }
	}
	switch kind {
	case .Text_Field:
		if dom.get(p.doc, el) == nil { return .None }
		f := page_forms(p)
		at := min(caret.offset, len(forms.edit_text(f, el)))
		forms.focus(f, el)
		forms.set_selection(f, el, at, at)
		before := len(forms.edit_text(f, el))
		if !forms.edit(f, el, .Insert_From_Drop, text) { return .None }
		inserted := len(forms.edit_text(f, el)) - before
		forms.set_selection(f, el, at, at + inserted, .Forward)
	case .Editable:
		if !insert_dropped_text(p, el, caret.pos, text) { return .None }
	case .None, .File_Input:
	}
	return op
}

// The files of the store into a file input: those its `accept` takes, one unless `multiple`; input and change fire
// when the selection changes. False when none fit (or the input went away).
@(private)
drop_files_into :: proc(p: ^Page, st: ^Drag_Store, input: base.Handle) -> bool {
	f := page_forms(p)
	n := dom.get(p.doc, input)
	if n == nil || forms.is_disabled(f, input) { return false }
	accept, _ := dom.get_attribute(p.doc, input, "accept")
	_, multiple := dom.get_attribute(p.doc, input, "multiple")
	list := make([dynamic]forms.File)
	for it in st.items {
		if !it.is_file || it.is_dir || !forms.accept_matches(accept, it.file.name, it.file.mime) { continue }
		append(&list, file_clone(it.file))
		if !multiple { break }
	}
	if len(list) == 0 { delete(list); return false }
	forms.set_files(f, input, list[:])   // (takes the files)
	delete(list)
	return true
}

// beforeinput (cancelable) / input around an edit of an editing host by the drag.
@(private)
host_input :: proc(p: ^Page, host: base.Handle, type, input_type, data: string) -> bool {
	return dispatch_event(p, host, dom.Event{type = type, bubbles = true, cancelable = type == "beforeinput", composed = true, data = data, text = input_type})
}

// The dragged range of an editing host removed ("deleteByDrag"); the drop caret moved along when it was after it in
// the same text node.
@(private)
delete_dragged_range :: proc(p: ^Page, host: base.Handle, r: [2]lay.Text_Pos, caret: Drop_Caret) -> Drop_Caret {
	out := caret
	if !host_input(p, host, "beforeinput", "deleteByDrag", "") { return out }
	d := p.doc
	a, b := r[0], r[1]
	if dom.get(d, a.node) == nil || dom.get(d, b.node) == nil { return out }
	to16 :: proc(d: ^dom.Document, pos: lay.Text_Pos) -> int {
		n := dom.get(d, pos.node)
		if n.kind == .Text || n.kind == .Comment { return lay.utf16_offset(n.text, pos.offset) }
		return pos.offset
	}
	if out.pos.node == b.node && out.pos.offset >= b.offset && a.node == b.node { out.pos.offset -= b.offset - a.offset }
	c := Call{page = p}
	frag, err := range_contents(&c, a.node, to16(d, a), b.node, to16(d, b), 2, 0)
	if frag != base.NIL_HANDLE { dom.destroy_unpinned(d, frag) }
	if err == .None { host_input(p, host, "input", "deleteByDrag", "") }
	return out
}

// Text dropped into an editing host at `pos`: beforeinput (cancelable), the text spliced into the text node (or a new
// one between children), input, and the dropped text selected.
@(private)
insert_dropped_text :: proc(p: ^Page, host: base.Handle, pos: lay.Text_Pos, text: string) -> bool {
	if !host_input(p, host, "beforeinput", "insertFromDrop", text) { return false }
	d := p.doc
	n := dom.get(d, pos.node)
	if n == nil { return false }
	start, end: lay.Text_Pos
	if n.kind == .Text {
		off := clamp(pos.offset, 0, len(n.text))
		dom.set_data(d, pos.node, strings.concatenate({n.text[:off], text, n.text[off:]}, context.temp_allocator))
		start, end = {pos.node, off}, {pos.node, off + len(text)}
	} else {
		t := dom.create_text(d, text)
		ref := n.first_child
		for i := 0; i < pos.offset && ref != base.NIL_HANDLE; i += 1 { ref = dom.get(d, ref).next }
		if dom.insert_before(d, pos.node, t, ref) != .None { return false }
		start, end = {t, 0}, {t, len(text)}
	}
	selection_set(p, start, end)
	host_input(p, host, "input", "insertFromDrop", text)
	return true
}
