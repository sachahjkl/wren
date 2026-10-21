package page

// HTML's "persisted user state" of a session history entry: what the document showed when it was left, restored when
// the entry is shown again by a new document (a traversal back or forward, a reload). A document kept alive in the
// back/forward cache needs none of it: it is still there.
//   * scroll positions: the document's, and every scroll container's that was moved, by element (CSS pixels);
//   * the page zoom;
//   * form controls the user changed (dirty value, checkedness, selectedness), by element. Never password or file
//     inputs, hidden ones, nor controls (or forms) with autocomplete=off, as other browsers.
// Elements are named by a path that survives a new parse of the same document: its id when it is unique, else the
// indexes of the element children from the document down to it. A restored control must still be the same kind of
// control (tag, type, name); anything else is skipped.

import "core:fmt"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:forms"

Persisted_Scroll :: struct {
	path: string,   // owned
	pos:  [2]f32,   // CSS px
}

Persisted_Control :: struct {
	path:    string,   // owned
	key:     string,   // owned: "tag type name", checked again at restore
	what:    Persisted_What,
	value:   string,   // owned (.Value)
	on:      bool,     // .Checked, .Selected
}

Persisted_What :: enum u8 { Value, Checked, Selected }

Persisted_State :: struct {
	saved:      bool,
	scroll:     [2]f32,                   // the document's, CSS px
	zoom:       f32,                      // 0: unknown
	containers: [dynamic]Persisted_Scroll,
	controls:   [dynamic]Persisted_Control,
}

persisted_destroy :: proc(ps: ^Persisted_State) {
	persisted_clear(ps)
	delete(ps.containers)
	delete(ps.controls)
	ps^ = {}
}

persisted_clear :: proc(ps: ^Persisted_State) {
	for c in ps.containers { delete(c.path) }
	clear(&ps.containers)
	for c in ps.controls { delete(c.path); delete(c.key); delete(c.value) }
	clear(&ps.controls)
	ps.saved, ps.scroll, ps.zoom = false, {}, 0
}

persisted_add_container :: proc(ps: ^Persisted_State, path: string, pos: [2]f32) {
	append(&ps.containers, Persisted_Scroll{path = strings.clone(path), pos = pos})
}

////////////////////////////////
// Element paths

// "#id" when the element's id finds it, else "/i/j/k": indexes among element children from the document down.
element_path :: proc(d: ^dom.Document, h: base.Handle, allocator := context.temp_allocator) -> string {
	n := dom.get(d, h)
	if n == nil || n.kind != .Element { return "" }
	if id, ok := dom.get_attribute(d, h, "id"); ok && id != "" && dom.find_by_id(d, id) == h {
		return strings.concatenate({"#", id}, allocator)
	}
	idx := make([dynamic]int, 0, 16, context.temp_allocator)
	for cur := h; cur != base.NIL_HANDLE && cur != d.root; {
		cn := dom.get(d, cur)
		if cn == nil { return "" }
		i := 0
		if cn.parent == base.NIL_HANDLE { return "" }   // not in the document
		for s := cn.prev; s != base.NIL_HANDLE; s = dom.get(d, s).prev {
			if sn := dom.get(d, s); sn != nil && sn.kind == .Element { i += 1 }
		}
		append(&idx, i)
		cur = cn.parent
	}
	sb := strings.builder_make(allocator)
	for k := len(idx) - 1; k >= 0; k -= 1 { fmt.sbprintf(&sb, "/%d", idx[k]) }
	return strings.to_string(sb)
}

// The element a path names in `d` now, NIL when there is none.
element_from_path :: proc(d: ^dom.Document, path: string) -> base.Handle {
	if strings.has_prefix(path, "#") { return dom.find_by_id(d, path[1:]) }
	if !strings.has_prefix(path, "/") { return base.NIL_HANDLE }
	cur := d.root
	rest := path[1:]
	for part in strings.split_iterator(&rest, "/") {
		want, ok := strconv.parse_int(part)
		if !ok || want < 0 { return base.NIL_HANDLE }
		n := dom.get(d, cur)
		if n == nil { return base.NIL_HANDLE }
		found := base.NIL_HANDLE
		i := 0
		for c := n.first_child; c != base.NIL_HANDLE; c = dom.get(d, c).next {
			cn := dom.get(d, c)
			if cn == nil || cn.kind != .Element { continue }
			if i == want { found = c; break }
			i += 1
		}
		if found == base.NIL_HANDLE { return base.NIL_HANDLE }
		cur = found
	}
	return cur if cur != d.root else base.NIL_HANDLE
}

////////////////////////////////
// Form controls

@(private = "file")
control_key :: proc(d: ^dom.Document, h: base.Handle) -> string {
	n := dom.get(d, h)
	if n == nil { return "" }
	t, _ := dom.get_attribute(d, h, "type")
	name, _ := dom.get_attribute(d, h, "name")
	return fmt.tprintf("%s %s %s", n.name, strings.to_lower(t, context.temp_allocator), name)
}

@(private = "file")
autocomplete_off :: proc(f: ^forms.Forms, h: base.Handle) -> bool {
	if v, ok := dom.get_attribute(f.doc, h, "autocomplete"); ok && strings.equal_fold(strings.trim_space(v), "off") { return true }
	if form := forms.form_owner(f, h); form != base.NIL_HANDLE {
		if v, ok := dom.get_attribute(f.doc, form, "autocomplete"); ok && strings.equal_fold(strings.trim_space(v), "off") { return true }
	}
	return false
}

// Records the controls the user (or a script) changed. Returns how many.
persisted_capture_controls :: proc(p: ^Page, ps: ^Persisted_State) -> int {
	if p == nil || p.closed || p.formctl == nil { return 0 }
	f := page_forms(p)
	d := p.doc
	count := 0
	for h, c in f.controls {
		n := dom.get(d, h)
		if n == nil || n.kind != .Element || !dom.is_connected(d, h) { continue }
		what: Persisted_What
		value := ""
		on := false
		#partial switch c.kind {
		case .Input:
			t := forms.input_type_of(n)
			#partial switch t {
			case .Password, .File, .Hidden, .Submit, .Image, .Reset, .Button: continue
			case .Checkbox, .Radio:
				if !c.dirty_checked { continue }
				what, on = .Checked, forms.checked(f, h)
			case:
				if !c.dirty_value { continue }
				what, value = .Value, forms.value(f, h)
			}
		case .Textarea:
			if !c.dirty_value { continue }
			what, value = .Value, forms.value(f, h)
		case .Option:
			if !c.dirty_selected { continue }
			sel := forms.option_select(f, h)
			if sel != base.NIL_HANDLE && autocomplete_off(f, sel) { continue }
			what, on = .Selected, forms.option_selected(f, h)
		case: continue
		}
		if c.kind != .Option && autocomplete_off(f, h) { continue }
		path := element_path(d, h)
		if path == "" { continue }
		append(&ps.controls, Persisted_Control{path = strings.clone(path), key = strings.clone(control_key(d, h)), what = what, value = strings.clone(value), on = on})
		count += 1
	}
	return count
}

// Puts the recorded controls back (no event fires, as in HTML). Returns how many were restored.
persisted_restore_controls :: proc(p: ^Page, ps: ^Persisted_State) -> int {
	if p == nil || p.closed || p.formctl == nil || len(ps.controls) == 0 { return 0 }
	f := page_forms(p)
	d := p.doc
	done := 0
	// options last: a select's own value change would undo them
	for pass in 0 ..< 2 {
		for &c in ps.controls {
			if (c.what == .Selected) != (pass == 1) { continue }
			h := element_from_path(d, c.path)
			if h == base.NIL_HANDLE || control_key(d, h) != c.key { continue }
			switch c.what {
			case .Value: if forms.set_value(f, h, c.value) == .None { done += 1 }
			case .Checked: if forms.set_checked(f, h, c.on) == .None { done += 1 }
			case .Selected: forms.set_option_selected(f, h, c.on); done += 1
			}
		}
	}
	return done
}
