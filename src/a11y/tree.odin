// Package a11y: the accessibility tree of a web page (HTML-AAM, WAI-ARIA 1.2, Accessible Name and Description
// Computation 1.2), written as an update of the toolkit's accessibility layer (platform.A11y_Update): the browser
// grafts it under its page area, and screen readers read it through the toolkit's adapter (AccessKit, UI Automation).
// The tree is made from the DOM, the computed styles (what is not rendered or hidden is left out), the layout (bounds)
// and the forms (values, checked, selected, focus). Node ids are the DOM handles. See docs/accessibility.md.
package a11y

import "core:strings"
import "core:unicode/utf8"
import "toolkit:platform"
import "wb:base"
import "wb:dom"
import "wb:forms"
import lay "wb:layout"

View :: struct {
	using src:  Source,
	layout:     ^lay.Layout,   // nil: no bounds
	viewport:   [2]f32,        // the page area's size (layout pixels)
	doc_scroll: f32,           // the document's scroll
	origin:     [2]f32,        // window pixels of the document's top-left corner at scroll 0
	focus:      base.Handle,   // the focused element (NIL: none)
	title, url: string,
	max_nodes:  int,           // 0: no limit (a huge document stops there: what follows is left out)
	// the tree of the document of a frame element (an iframe), grafted under its node; nil or false: the frame's node
	// has no subtree
	frame_tree: proc(user: rawptr, element: base.Handle) -> (platform.A11y_Tree_Id, bool),
	frame_user: rawptr,
}

@(private)
Walk :: struct {
	v:          ^View,
	u:          ^platform.A11y_Update,
	kids:       [dynamic]u64,
	focus_node: u64,
	lview:      lay.View,
	has_lview:  bool,
	nodes:      int,
	truncated:  bool,    // max_nodes was reached
	live:       ^Live,   // incremental.odin: every node written is recorded (nil: a plain build)
	reuse:      bool,    // ... a patch: nodes recorded and not changed are taken as they are
	text_items: map[base.Handle][dynamic]int,   // text node -> the display items showing it (made on first need)
	text_indexed: bool,
}

// The bounds of a text node: the union of the display items that show it (its lines); ok false: none.
@(private)
text_bounds :: proc(w: ^Walk, h: base.Handle) -> (r: [4]f32, ok: bool) {
	if !w.has_lview { return }
	l := w.v.layout
	if !w.text_indexed {
		w.text_indexed = true
		w.text_items = make(map[base.Handle][dynamic]int, 256, context.temp_allocator)
		for i in 0 ..< len(l.items) {
			n, _, _, iok := lay.item_source(l, w.v.doc, i)
			if !iok { continue }
			if lst, found := &w.text_items[n]; found {
				append(lst, i)
			} else {
				d := make([dynamic]int, 0, 2, context.temp_allocator)
				append(&d, i)
				w.text_items[n] = d
			}
		}
	}
	items, found := w.text_items[h]
	if !found { return }
	for i in items {
		b := lay.item_rect(l, &w.lview, &l.items[i])
		if b.max.x <= b.min.x && b.max.y <= b.min.y { continue }
		if !ok { r = {b.min.x, b.min.y, b.max.x, b.max.y}; ok = true; continue }
		r = {min(r[0], b.min.x), min(r[1], b.min.y), max(r[2], b.max.x), max(r[3], b.max.y)}
	}
	return
}

// The id of a document node's text run (an input's text), and back.
run_id :: proc(h: base.Handle) -> u64 { return u64(h) ~ 0xa11e_0000_0000_0001 }
run_owner :: proc(id: u64) -> u64 { return id ~ 0xa11e_0000_0000_0001 }

// The byte offset of character `index` of `s` (clamped to its length), and back.
char_to_byte :: proc(s: string, index: int) -> int {
	i := 0
	for _, off in s {
		if i == index { return off }
		i += 1
	}
	return len(s)
}
// The index of the character each word of `s` starts at (a word: what follows white space).
@(private)
word_starts :: proc(s: string) -> []u8 {
	out := make([dynamic]u8, 0, 16, context.temp_allocator)
	i := 0
	space := true
	for r in s {
		is_space := r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == 0xA0
		if !is_space && space && i < 256 { append(&out, u8(i)) }
		space = is_space
		i += 1
	}
	return out[:]
}

byte_to_char :: proc(s: string, off: int) -> int {
	i := 0
	for _, o in s {
		if o >= off { return i }
		i += 1
	}
	return i
}

@(private)
walk_make :: proc(v: ^View, u: ^platform.A11y_Update, live: ^Live = nil) -> Walk {
	w := Walk{v = v, u = u, live = live}
	w.kids = make([dynamic]u64, 0, 256, context.temp_allocator)
	if v.layout != nil && v.layout.valid {
		w.lview = lay.view_make(v.layout, v.viewport, 0, cull = false)
		w.has_lview = true
	}
	return w
}

// Writes the whole tree of the document into `u` (u.root, u.focus and the nodes; u.tree is the caller's). Returns how
// many nodes.
build :: proc(v: ^View, u: ^platform.A11y_Update) -> int {
	w := walk_make(v, u)
	return build_walk(&w)
}

@(private)
build_walk :: proc(w: ^Walk) -> int {
	v, u := w.v, w.u
	root := v.doc.root
	rn := dom.get(v.doc, root)
	if rn == nil { return 0 }
	for c := rn.first_child; c != base.NIL_HANDLE; {
		cn := dom.get(v.doc, c)
		if cn == nil { break }
		walk(w, c, cn, {}, base.NIL_HANDLE)
		c = cn.next
	}
	emit_root(w, w.kids[:])
	u.root = u64(root)
	u.focus = w.focus_node != 0 ? w.focus_node : u.root
	return w.nodes + 1
}

// The document's node.
@(private)
emit_root :: proc(w: ^Walk, kids: []u64) {
	v, u := w.v, w.u
	index := platform.a11y_node(u, u64(v.doc.root), .Document, {}, {.Scroll_Into_View})
	platform.a11y_bounds(u, 0, f64(v.doc_scroll), f64(v.viewport.x), f64(v.doc_scroll + v.viewport.y))
	platform.a11y_children(u, kids)
	platform.a11y_str(u, .Label, v.title)
	platform.a11y_str(u, .Url, v.url)
	// document coordinates -> the window: the scroll and the page area's place (one node changes when the page scrolls)
	platform.a11y_floats(u, .Transform, {1, 0, 0, 1, v.origin.x, v.origin.y - v.doc_scroll})
	if w.live != nil { live_record(w, u64(v.doc.root), Rec{el = v.doc.root, kind = .Root}, kids, index) }
}

@(private)
skipped_tag :: proc(name: string) -> bool {
	switch name {
	case "script", "style", "template", "head", "title", "meta", "link", "noscript", "base", "param", "source", "track", "col", "colgroup":
		return true
	}
	return false
}

@(private)
bounds_of :: proc(w: ^Walk, h: base.Handle) -> (r: [4]f32, ok: bool, fixed: bool) {
	if !w.has_lview || h == base.NIL_HANDLE { return }
	br, found := lay.box_of_view(w.v.layout, &w.lview, h)
	if !found { return }
	b := br.bounds
	if br.fixed { b.min.y += w.v.doc_scroll; b.max.y += w.v.doc_scroll }   // (fixed boxes move with the viewport)
	return {b.min.x, b.min.y, b.max.x, b.max.y}, true, br.fixed
}

// The role an element has in the tree (Unknown: none, its nodes hang under the nearest node above).
@(private)
element_role :: proc(src: ^Source, h: base.Handle, n: ^dom.Node, invisible: bool) -> Role {
	if invisible { return .Unknown }
	role := role_of(src, h, n)
	if role == .Unknown && (is_focusable(src, h, n) || has_own_name(src, h) || live_of(src, h, .Unknown) != .Off) { role = .Generic_Container }
	return role
}

// The nodes of `h`'s subtree; the ids of the nodes directly under it go to w.kids. `parent_bounds`: for text and the
// elements without a box of their own, from the box of `pb_src`.
@(private)
walk :: proc(w: ^Walk, h: base.Handle, n: ^dom.Node, parent_bounds: [4]f32, pb_src: base.Handle) {
	v := w.v
	if v.max_nodes > 0 && w.nodes >= v.max_nodes { w.truncated = true; return }
	// a patch (incremental.odin): a node written already, or recorded and not changed, is taken as it is
	deep := false
	if w.reuse {
		l := w.live
		if l.emitted[u64(h)] { append(&w.kids, u64(h)); return }
		if r, ok := l.recs[u64(h)]; ok {
			forced, is_forced := l.force[u64(h)]
			if !is_forced {
				#partial switch r.kind {
				case .Text:
					if n.kind == .Text { append(&w.kids, u64(h)); return }
				case .Element:
					if same_role(v, h, n, r) { append(&w.kids, u64(h)); return }
				}
			}
			deep = forced
		} else {
			deep = l.force[u64(h)] or_else false
		}
	}
	#partial switch n.kind {
	case .Text:
		if emit_text(w, h, n, parent_bounds, pb_src) {
			append(&w.kids, u64(h))
			w.nodes += 1
		}
		return
	case .Element:
	case:
		return
	}
	if skipped_tag(n.name) { return }
	gone, invisible := hidden_self(&v.src, h, n)
	if gone { return }
	if w.live != nil { live_saw_element(w, h, n) }
	bounds, has_bounds, _ := bounds_of(w, h)
	if !has_bounds { bounds = parent_bounds }
	role := element_role(&v.src, h, n, invisible)

	// the children: the shadow tree's when it has one (slots: their assigned nodes)
	mark := len(w.kids)
	if role == .Unknown || !children_presentational(role) {
		// (below a node inserted or whose attributes changed, nothing is taken as it was)
		saved := w.reuse
		if deep { w.reuse = false }
		walk_children(w, h, n, bounds, has_bounds ? h : pb_src)
		w.reuse = saved
	}
	if role == .Unknown { return }   // (not a node: its nodes hang under the nearest node above)

	kids := make([]u64, len(w.kids) - mark, context.temp_allocator)
	copy(kids, w.kids[mark:])
	resize(&w.kids, mark)

	// the focus: this element, or the node nearest above the focused one (reached after the nodes below)
	if v.focus != base.NIL_HANDLE && w.focus_node == 0 {
		if h == v.focus || dom.contains(v.doc, h, v.focus) { w.focus_node = u64(h) }
	}
	emit_element(w, h, n, role, kids, bounds, has_bounds, pb_src)
	append(&w.kids, u64(h))
	w.nodes += 1
}

// A text node's node; false when it has none (only white space).
@(private)
emit_text :: proc(w: ^Walk, h: base.Handle, n: ^dom.Node, parent_bounds: [4]f32, pb_src: base.Handle) -> bool {
	t := collapse(n.text)
	if t == "" { return false }
	// its own lines' bounds, else its parent's
	bounds, own := text_bounds(w, h)
	if !own { bounds = parent_bounds }
	index := platform.a11y_node(w.u, u64(h), .Label)
	if bounds != {} { platform.a11y_bounds(w.u, f64(bounds[0]), f64(bounds[1]), f64(bounds[2]), f64(bounds[3])) }
	platform.a11y_children(w.u, nil)
	platform.a11y_str(w.u, .Value, t)
	if w.live != nil { live_record(w, u64(h), Rec{el = h, kind = .Text, role = .Label, own_box = own, pb_src = pb_src, bounds = bounds}, nil, index) }
	return true
}

// An element's node (and its text run), `kids` the nodes found under it. The same whether the tree is walked whole
// or one node is written again (incremental.odin).
@(private)
emit_element :: proc(w: ^Walk, h: base.Handle, n: ^dom.Node, role: Role, kids: []u64, bounds: [4]f32, has_bounds: bool, pb_src: base.Handle) {
	v := w.v
	id := u64(h)
	focusable := is_focusable(&v.src, h, n)

	// text fields: their text as a run (reading by character and word)
	text_field := is_text_field(role)
	value := ""
	if text_field || role == .Combo_Box || role == .Slider || role == .Spin_Button || role == .Color_Well || is_date(role) {
		value = control_value(&v.src, h, n)
	}
	password := role == .Password_Input
	run_kids := kids
	run_index := -1
	if text_field {
		run := run_id(h)
		shown := value
		if password { shown = strings.repeat("\u2022", strings.rune_count(value), context.temp_allocator) }
		lens := make([dynamic]u8, 0, len(shown), context.temp_allocator)
		for r in shown { append(&lens, u8(utf8.rune_size(r))) }
		run_index = platform.a11y_node(w.u, run, .Text_Run)
		if has_bounds { platform.a11y_bounds(w.u, f64(bounds[0]), f64(bounds[1]), f64(bounds[2]), f64(bounds[3])) }
		platform.a11y_children(w.u, nil)
		platform.a11y_str(w.u, .Value, shown, keep_empty = true)
		platform.a11y_bytes(w.u, .Character_Lengths, lens[:])
		platform.a11y_bytes(w.u, .Word_Starts, word_starts(shown))
		run_kids = make([]u64, 1, context.temp_allocator)
		run_kids[0] = run
	}

	// a frame's document: a tree of its own, grafted here (a graft node has no children)
	graft: platform.A11y_Tree_Id
	grafted := false
	if role == .Iframe && v.frame_tree != nil {
		graft, grafted = v.frame_tree(v.frame_user, h)
		if grafted { run_kids = nil }
	}

	flags: platform.A11y_Flags
	actions: platform.A11y_Actions = {.Scroll_Into_View}
	disabled := is_disabled(&v.src, h, n)
	if disabled { flags += {.Disabled} }
	if focusable && !disabled { actions += {.Focus} }
	if clickable(&v.src, h, n, role) && !disabled { actions += {.Click} }
	if text_field && !disabled && !has_attr(&v.src, h, "readonly") { actions += {.Set_Value, .Replace_Selected_Text} }
	// the caret and the selection of a text field, in characters of its run
	sel_ok := false
	sel: [2]int
	if text_field && v.forms != nil && forms.selection_applies(v.forms, h) && forms.control_peek(v.forms, h) != nil {
		a, b, dir := forms.selection(v.forms, h)
		if dir == .Backward { a, b = b, a }
		sel = {byte_to_char(value, a), byte_to_char(value, b)}
		sel_ok = true
		if !disabled { actions += {.Set_Text_Selection} }
	}
	if (role == .Slider || role == .Spin_Button) && !disabled { actions += {.Increment, .Decrement, .Set_Value} }
	if has_attr(&v.src, h, "required") || aria_true(&v.src, h, "aria-required") { flags += {.Required} }
	if has_attr(&v.src, h, "readonly") || aria_true(&v.src, h, "aria-readonly") { flags += {.Read_Only} }
	if n.name == "select" && has_attr(&v.src, h, "multiple") || aria_true(&v.src, h, "aria-multiselectable") { flags += {.Multiselectable} }
	if aria_true(&v.src, h, "aria-busy") { flags += {.Busy} }
	if aria_true(&v.src, h, "aria-atomic") { flags += {.Live_Atomic} }
	if role == .Dialog || role == .Alert_Dialog {
		if aria_true(&v.src, h, "aria-modal") { flags += {.Modal} }
	}
	if s, ok := selected_of(&v.src, h, n, role); ok { flags += {.Has_Selected}; if s { flags += {.Selected} } }
	if e, ok := expanded_of(&v.src, h, n, role); ok {
		flags += {.Has_Expanded}
		if e { flags += {.Expanded} }
		if !disabled { actions += {.Expand, .Collapse} }
	}
	if n.name == "a" && role == .Link {
		if _, visited := attr(&v.src, h, "data-visited"); visited { flags += {.Visited} }
	}

	index := platform.a11y_node(w.u, id, role, flags, actions)
	if has_bounds { platform.a11y_bounds(w.u, f64(bounds[0]), f64(bounds[1]), f64(bounds[2]), f64(bounds[3])) }
	platform.a11y_children(w.u, run_kids)
	if grafted { platform.a11y_graft(w.u, graft) }
	if sel_ok { platform.a11y_selection(w.u, run_id(h), sel[0], run_id(h), sel[1]) }

	name, from_title := name_of(&v.src, h, role)
	live := live_of(&v.src, h, role)
	if name == "" && live != .Off {
		// (a live region is announced when its name changes: its text is its name)
		t := collapse(dom.text_content(v.doc, h))
		name = len(t) > 1000 ? t[:1000] : t
	}
	if role == .Label && n.name != "label" {
		platform.a11y_str(w.u, .Value, name)
	} else {
		platform.a11y_str(w.u, .Label, name)
	}
	platform.a11y_str(w.u, .Description, description_of(&v.src, h, from_title))
	if text_field || role == .Combo_Box || role == .Color_Well || is_date(role) {
		platform.a11y_str(w.u, .Value, password ? "" : value)
	} else if vt, ok := attr(&v.src, h, "aria-valuetext"); ok {
		platform.a11y_str(w.u, .Value, vt)
	}
	if p, ok := attr(&v.src, h, "placeholder"); ok && text_field { platform.a11y_str(w.u, .Placeholder, collapse(p)) }
	if role == .Link {
		if href, ok := attr(&v.src, h, "href"); ok { platform.a11y_str(w.u, .Url, href) }
	}
	platform.a11y_str(w.u, .Html_Tag, n.name)
	if hid, ok := attr(&v.src, h, "id"); ok { platform.a11y_str(w.u, .Html_Id, hid) }
	if ks, ok := attr(&v.src, h, "aria-keyshortcuts"); ok { platform.a11y_str(w.u, .Keyboard_Shortcut, ks) }
	if rd, ok := attr(&v.src, h, "aria-roledescription"); ok { platform.a11y_str(w.u, .Role_Description, rd) }
	if lang, ok := attr(&v.src, h, "lang"); ok { platform.a11y_str(w.u, .Language, lang) }

	if t, ok := toggled_of(&v.src, h, n, role); ok { platform.a11y_int(w.u, .Toggled, u64(t)) }
	if lv := level_of(&v.src, h, n, role); lv > 0 { platform.a11y_int(w.u, .Level, u64(lv)) }
	if pos, size, ok := position_of(&v.src, h, n, role); ok {
		platform.a11y_int(w.u, .Position_In_Set, u64(pos))
		platform.a11y_int(w.u, .Size_Of_Set, u64(size))
	}
	numbers(w, h, n, role)
	if live != .Off { platform.a11y_int(w.u, .Live, u64(live)) }
	if hp, ok := popup_of(&v.src, h, role); ok { platform.a11y_int(w.u, .Has_Popup, u64(hp)) }
	if cur, ok := attr(&v.src, h, "aria-current"); ok {
		c: platform.A11y_Current
		switch strings.to_lower(cur, context.temp_allocator) {
		case "page": c = .Page
		case "step": c = .Step
		case "location": c = .Location
		case "date": c = .Date
		case "time": c = .Time
		case "false", "": c = .False
		case: c = .True
		}
		if c != .False { platform.a11y_int(w.u, .Aria_Current, u64(c)) }
	}
	if inv, ok := attr(&v.src, h, "aria-invalid"); ok && !strings.equal_fold(inv, "false") {
		platform.a11y_int(w.u, .Invalid, strings.equal_fold(inv, "grammar") ? 1 : strings.equal_fold(inv, "spelling") ? 2 : 0)
	}
	if o, ok := attr(&v.src, h, "aria-orientation"); ok {
		platform.a11y_int(w.u, .Orientation, strings.equal_fold(o, "vertical") ? 1 : 0)
	}
	refs(w, h, "aria-controls", .Controls)
	refs(w, h, "aria-details", .Details)
	refs(w, h, "aria-flowto", .Flow_To)
	refs(w, h, "aria-owns", .Owns)
	if ad, ok := attr(&v.src, h, "aria-activedescendant"); ok {
		if t := dom.find_by_id(v.doc, strings.trim_space(ad)); t != base.NIL_HANDLE { platform.a11y_int(w.u, .Active_Descendant, u64(t)) }
	}
	if em, ok := attr(&v.src, h, "aria-errormessage"); ok {
		if t := dom.find_by_id(v.doc, strings.trim_space(em)); t != base.NIL_HANDLE { platform.a11y_int(w.u, .Error_Message, u64(t)) }
	}
	table_props(w, h, n, role)

	if w.live != nil {
		fixed := false
		if has_bounds { _, _, fixed = bounds_of(w, h) }
		if text_field { live_record(w, run_id(h), Rec{el = h, kind = .Run, role = .Text_Run, own_box = has_bounds, fixed = fixed, pb_src = pb_src, bounds = bounds}, nil, run_index) }
		live_record(w, id, Rec{el = h, kind = .Element, role = role, own_box = has_bounds, fixed = fixed, pb_src = pb_src, bounds = bounds, click = .Click in actions, graft = grafted}, run_kids, index)
	}
}

@(private)
walk_children :: proc(w: ^Walk, h: base.Handle, n: ^dom.Node, bounds: [4]f32, pb_src: base.Handle) {
	d := w.v.doc
	first := n.first_child
	if n.shadow != base.NIL_HANDLE {
		if sn := dom.get(d, n.shadow); sn != nil && sn.is_shadow { first = sn.first_child }
	}
	if n.name == "slot" {
		if assigned, ok := d.assigned[h]; ok && len(assigned) > 0 {
			for c in assigned {
				if cn := dom.get(d, c); cn != nil { walk(w, c, cn, bounds, pb_src) }
			}
			return
		}
	}
	for c := first; c != base.NIL_HANDLE; {
		cn := dom.get(d, c)
		if cn == nil { break }
		walk(w, c, cn, bounds, pb_src)
		c = cn.next
	}
}

@(private)
is_text_field :: proc(r: Role) -> bool {
	#partial switch r {
	case .Text_Input, .Multiline_Text_Input, .Search_Input, .Email_Input, .Url_Input, .Phone_Number_Input, .Password_Input, .Number_Input:
		return true
	}
	return false
}

@(private)
is_date :: proc(r: Role) -> bool {
	#partial switch r { case .Date_Input, .Date_Time_Input, .Month_Input, .Week_Input, .Time_Input: return true }
	return false
}

@(private)
has_attr :: proc(src: ^Source, h: base.Handle, name: string) -> bool { _, ok := attr(src, h, name); return ok }

@(private)
aria_true :: proc(src: ^Source, h: base.Handle, name: string) -> bool {
	v, ok := attr(src, h, name)
	return ok && strings.equal_fold(strings.trim_space(v), "true")
}

// Disabled: the disabled attribute of a control (or of a fieldset around it, its first legend apart), aria-disabled.
@(private)
is_disabled :: proc(src: ^Source, h: base.Handle, n: ^dom.Node) -> bool {
	if aria_true(src, h, "aria-disabled") { return true }
	switch n.name {
	case "button", "input", "select", "textarea", "optgroup", "option", "fieldset":
		if has_attr(src, h, "disabled") { return true }
		for p := n.parent; p != base.NIL_HANDLE; {
			pn := dom.get(src.doc, p)
			if pn == nil || pn.kind != .Element { break }
			if pn.name == "fieldset" && has_attr(src, p, "disabled") { return true }
			if pn.name == "select" && n.name == "option" && has_attr(src, p, "disabled") { return true }
			p = pn.parent
		}
	}
	return false
}

// What a click does something to: links, buttons, controls, summaries, options, ARIA widgets, and elements with a
// click listener.
@(private)
clickable :: proc(src: ^Source, h: base.Handle, n: ^dom.Node, role: Role) -> bool {
	#partial switch role {
	case .Link, .Button, .Check_Box, .Radio_Button, .Switch, .Tab, .Menu_Item, .Menu_Item_Check_Box, .Menu_Item_Radio,
	     .List_Box_Option, .Disclosure_Triangle, .Tree_Item, .Combo_Box, .Color_Well:
		return true
	}
	for l in n.listeners { if !l.removed && (l.type == "click" || l.type == "mousedown" || l.type == "pointerdown") { return true } }
	return false
}

@(private)
toggled_of :: proc(src: ^Source, h: base.Handle, n: ^dom.Node, role: Role) -> (platform.A11y_Toggled, bool) {
	#partial switch role {
	case .Check_Box, .Radio_Button, .Switch, .Menu_Item_Check_Box, .Menu_Item_Radio:
	case .Button:
		// a toggle button: aria-pressed
		if v, ok := attr(src, h, "aria-pressed"); ok {
			switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
			case "true": return .True, true
			case "mixed": return .Mixed, true
			case "false": return .False, true
			}
		}
		return .False, false
	case:
		return .False, false
	}
	if n.name == "input" {
		if src.forms != nil {
			if forms.indeterminate(src.forms, h) { return .Mixed, true }
			return forms.checked(src.forms, h) ? .True : .False, true
		}
		return has_attr(src, h, "checked") ? .True : .False, true
	}
	if v, ok := attr(src, h, "aria-checked"); ok {
		switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
		case "true": return .True, true
		case "mixed": return .Mixed, true
		}
	}
	return .False, true
}

@(private)
selected_of :: proc(src: ^Source, h: base.Handle, n: ^dom.Node, role: Role) -> (bool, bool) {
	if n.name == "option" {
		if src.forms != nil { return forms.option_selected(src.forms, h), true }
		return has_attr(src, h, "selected"), true
	}
	#partial switch role {
	case .Tab, .List_Box_Option, .Row, .Grid_Cell, .Tree_Item, .Cell, .Column_Header, .Row_Header:
		if v, ok := attr(src, h, "aria-selected"); ok { return strings.equal_fold(strings.trim_space(v), "true"), true }
		if role == .Tab || role == .List_Box_Option { return false, true }
	}
	return false, false
}

@(private)
expanded_of :: proc(src: ^Source, h: base.Handle, n: ^dom.Node, role: Role) -> (bool, bool) {
	if v, ok := attr(src, h, "aria-expanded"); ok {
		t := strings.to_lower(strings.trim_space(v), context.temp_allocator)
		if t == "true" { return true, true }
		if t == "false" { return false, true }
	}
	if n.name == "summary" {
		// the summary of a details says whether it is open
		if pn := dom.get(src.doc, n.parent); pn != nil && pn.kind == .Element && pn.name == "details" {
			return has_attr(src, n.parent, "open"), true
		}
	}
	if role == .Combo_Box && n.name == "select" { return false, true }
	return false, false
}

@(private)
level_of :: proc(src: ^Source, h: base.Handle, n: ^dom.Node, role: Role) -> int {
	if v, ok := attr(src, h, "aria-level"); ok {
		if l := parse_int(v, 0); l > 0 { return l }
	}
	if role == .Heading && len(n.name) == 2 && n.name[0] == 'h' && n.name[1] >= '1' && n.name[1] <= '6' { return int(n.name[1] - '0') }
	if role == .Heading { return 2 }   // (role=heading without a level: ARIA's default)
	return 0
}

// "3 of 7": aria-posinset / setsize, else the place among the siblings of the same kind (list items, options,
// tabs, menu items, radio buttons of a group named alike).
@(private)
position_of :: proc(src: ^Source, h: base.Handle, n: ^dom.Node, role: Role) -> (pos, size: int, ok: bool) {
	if p, pok := attr(src, h, "aria-posinset"); pok {
		pos = parse_int(p, 0)
		if s, sok := attr(src, h, "aria-setsize"); sok { size = parse_int(s, 0) }
		if pos > 0 && size >= pos { return pos, size, true }
		if pos > 0 { return pos, pos, true }
	}
	#partial switch role {
	case .List_Item, .List_Box_Option, .Tab, .Menu_Item, .Menu_Item_Check_Box, .Menu_Item_Radio, .Tree_Item:
	case:
		return 0, 0, false
	}
	pn := dom.get(src.doc, n.parent)
	if pn == nil { return 0, 0, false }
	for c := pn.first_child; c != base.NIL_HANDLE; {
		cn := dom.get(src.doc, c)
		if cn == nil { break }
		if cn.kind == .Element && cn.name == n.name && role_of(src, c, cn) == role {
			if g, _ := hidden_self(src, c, cn); !g {
				size += 1
				if c == h { pos = size }
			}
		}
		c = cn.next
	}
	return pos, size, pos > 0
}

// Numeric value, minimum, maximum and step: range and number inputs, progress, meter, aria-value*.
@(private)
numbers :: proc(w: ^Walk, h: base.Handle, n: ^dom.Node, role: Role) {
	src := &w.v.src
	#partial switch role {
	case .Slider, .Spin_Button, .Progress_Indicator, .Meter, .Scroll_Bar, .Splitter:
	case:
		return
	}
	num :: proc(s: string) -> (f64, bool) {
		t := strings.trim_space(s)
		if t == "" { return 0, false }
		v: f64
		neg := false
		i := 0
		if t[0] == '-' { neg = true; i = 1 }
		int_part, frac, div := 0.0, 0.0, 1.0
		dot := false
		digits := 0
		for ; i < len(t); i += 1 {
			ch := t[i]
			if ch == '.' && !dot { dot = true; continue }
			if ch < '0' || ch > '9' { break }
			digits += 1
			if dot { div *= 10; frac += f64(ch - '0') / div } else { int_part = int_part * 10 + f64(ch - '0') }
		}
		if digits == 0 { return 0, false }
		v = int_part + frac
		return neg ? -v : v, true
	}
	get :: proc(src: ^Source, h: base.Handle, aria, html: string) -> (f64, bool) {
		if s, ok := attr(src, h, aria); ok { if v, vok := num(s); vok { return v, true } }
		if html != "" { if s, ok := attr(src, h, html); ok { if v, vok := num(s); vok { return v, true } } }
		return 0, false
	}
	html_value := n.name == "input" || n.name == "progress" || n.name == "meter"
	now, has_now := get(src, h, "aria-valuenow", "")
	if !has_now && html_value {
		if n.name == "input" { now, has_now = num(control_value(src, h, n)) } else { now, has_now = get(src, h, "", "value") }
	}
	lo, has_lo := get(src, h, "aria-valuemin", html_value ? "min" : "")
	hi, has_hi := get(src, h, "aria-valuemax", html_value ? "max" : "")
	if !has_lo && (role == .Slider || role == .Progress_Indicator || role == .Meter || role == .Scroll_Bar) { lo, has_lo = 0, true }
	if !has_hi {
		if role == .Slider || role == .Scroll_Bar || n.name == "meter" { hi, has_hi = 100, true }
		if n.name == "progress" { hi, has_hi = 1, true }
		if role == .Progress_Indicator && n.name != "progress" { hi, has_hi = 100, true }
	}
	if n.name == "input" && role == .Slider && !has_now { now, has_now = (lo + hi) / 2, true }
	if has_now { platform.a11y_num(w.u, .Numeric_Value, now) }
	if has_lo { platform.a11y_num(w.u, .Min_Numeric_Value, lo) }
	if has_hi { platform.a11y_num(w.u, .Max_Numeric_Value, hi) }
	if s, ok := get(src, h, "", n.name == "input" ? "step" : ""); ok && s > 0 { platform.a11y_num(w.u, .Numeric_Value_Step, s) }
}

@(private)
live_of :: proc(src: ^Source, h: base.Handle, role: Role) -> platform.A11y_Live {
	if v, ok := attr(src, h, "aria-live"); ok {
		switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
		case "assertive": return .Assertive
		case "polite": return .Polite
		case "off": return .Off
		}
	}
	#partial switch role {
	case .Alert: return .Assertive
	case .Status, .Log: return .Polite
	}
	return .Off
}

@(private)
popup_of :: proc(src: ^Source, h: base.Handle, role: Role) -> (platform.A11y_Popup, bool) {
	if v, ok := attr(src, h, "aria-haspopup"); ok {
		switch strings.to_lower(strings.trim_space(v), context.temp_allocator) {
		case "true", "menu": return .Menu, true
		case "listbox": return .Listbox, true
		case "tree": return .Tree, true
		case "grid": return .Grid, true
		case "dialog": return .Dialog, true
		}
	}
	if role == .Combo_Box { return .Listbox, true }
	return .Menu, false
}

@(private)
refs :: proc(w: ^Walk, h: base.Handle, name: string, kind: platform.A11y_Prop_Kind) {
	v, ok := attr(&w.v.src, h, name)
	if !ok { return }
	ids := make([dynamic]u64, 0, 4, context.temp_allocator)
	for id in strings.fields(v, context.temp_allocator) {
		if t := dom.find_by_id(w.v.doc, id); t != base.NIL_HANDLE { append(&ids, u64(t)) }
	}
	platform.a11y_ids(w.u, kind, ids[:])
}

// Tables: rows and columns counted, each row's and cell's index (the rows of a table, its row groups apart).
@(private)
table_props :: proc(w: ^Walk, h: base.Handle, n: ^dom.Node, role: Role) {
	d := w.v.doc
	#partial switch role {
	case .Table, .Grid, .Tree_Grid:
		rows, cols := 0, 0
		count_rows :: proc(d: ^dom.Document, h: base.Handle, rows, cols: ^int) {
			n := dom.get(d, h)
			for c := n.first_child; c != base.NIL_HANDLE; {
				cn := dom.get(d, c)
				if cn == nil { break }
				if cn.kind == .Element {
					switch cn.name {
					case "thead", "tbody", "tfoot": count_rows(d, c, rows, cols)
					case "tr":
						rows^ += 1
						k := 0
						for x := cn.first_child; x != base.NIL_HANDLE; {
							xn := dom.get(d, x)
							if xn == nil { break }
							if xn.kind == .Element && (xn.name == "td" || xn.name == "th") { k += max(parse_int(attr_of(d, x, "colspan"), 1), 1) }
							x = xn.next
						}
						cols^ = max(cols^, k)
					}
				}
				c = cn.next
			}
		}
		count_rows(d, h, &rows, &cols)
		if rows > 0 { platform.a11y_int(w.u, .Row_Count, u64(rows)) }
		if cols > 0 { platform.a11y_int(w.u, .Column_Count, u64(cols)) }
	case .Cell, .Grid_Cell, .Column_Header, .Row_Header:
		if n.name != "td" && n.name != "th" { return }
		col := 0
		pn := dom.get(d, n.parent)
		if pn == nil { return }
		for x := pn.first_child; x != base.NIL_HANDLE && x != h; {
			xn := dom.get(d, x)
			if xn == nil { break }
			if xn.kind == .Element && (xn.name == "td" || xn.name == "th") { col += max(parse_int(attr_of(d, x, "colspan"), 1), 1) }
			x = xn.next
		}
		platform.a11y_int(w.u, .Column_Index, u64(col))
		if cs := parse_int(attr_of(d, h, "colspan"), 1); cs > 1 { platform.a11y_int(w.u, .Column_Span, u64(cs)) }
		if rs := parse_int(attr_of(d, h, "rowspan"), 1); rs > 1 { platform.a11y_int(w.u, .Row_Span, u64(rs)) }
	case .Row:
		if n.name != "tr" { return }
		// the index among the rows of the table (row groups in order)
		idx := 0
		table := n.parent
		if pn := dom.get(d, table); pn != nil && pn.kind == .Element && pn.name != "table" { table = pn.parent }
		found := false
		for cur := dom.next_in_tree(d, table, table); cur != base.NIL_HANDLE; cur = dom.next_in_tree(d, cur, table) {
			cn := dom.get(d, cur)
			if cn == nil || cn.kind != .Element || cn.name != "tr" { continue }
			if cur == h { found = true; break }
			idx += 1
		}
		if found { platform.a11y_int(w.u, .Row_Index, u64(idx)) }
	}
}

@(private)
attr_of :: proc(d: ^dom.Document, h: base.Handle, name: string) -> string {
	v, _ := dom.get_attribute(d, h, name)
	return v
}
