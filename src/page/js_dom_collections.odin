package page

// Collections and selectors for JavaScript (api/js_dom_collections.widl).
//
//   * Live collections (childNodes, children, getElementsBy*, document.forms...) are host objects of the page that
//     remember their nodes in a list rebuilt only when the document's tree (or, for those that look at attributes,
//     its attributes) changed since: walking one by index costs one tree walk, then constant time per item, as long as
//     nothing changes (dom.Document.tree_version / attr_version).
//   * Selectors go through the style engine's own parser and matcher (css.parse_selector_list, style.matches_list):
//     one implementation of Selectors 4 for the cascade and for scripts. Parsed lists are kept in a small cache
//     (javascript.dom.selector_cache_entries) so that a selector used in a loop is parsed once.
//   * DOMTokenList and DOMStringMap work directly on the content attribute.

import "core:mem/virtual"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:forms"
import "wb:style"

// The page's state of the DOM bindings (created on first use, freed with the page).
Js_Dom_State :: struct {
	selectors:   [dynamic]Selector_Entry,
	sel_clock:   u64,
	observers:   Observers,              // js_dom_observe.odin
	layout:      Js_Layout,              // js_dom_layout.odin
	style_names: []string,               // getComputedStyle's property list (built once)
	style_blocks: Decl_Cache,            // parsed style attributes (js_dom_style.odin)
	style_probes: Decl_Cache,            // validated setProperty values
	ce:           Custom_Elements,       // js_custom_elements.odin
	shadow:       Js_Shadow,             // js_shadow.odin
}

@(private)
Selector_Entry :: struct {
	text:  string,          // owned
	arena: virtual.Arena,
	list:  css.Selector_List,
	used:  u64,
}

js_dom_state :: proc(p: ^Page) -> ^Js_Dom_State {
	if p.jsdom != nil { return p.jsdom }
	s := new(Js_Dom_State)
	p.jsdom = s
	base.on_close(p.scope, proc(data: rawptr) {
		p := (^Page)(data)
		s := p.jsdom
		if s == nil { return }
		for &e in s.selectors { delete(e.text); virtual.arena_destroy(&e.arena) }
		delete(s.selectors)
		observers_destroy(p, &s.observers)
		delete(s.style_names)
		decl_cache_destroy(&s.style_blocks)
		decl_cache_destroy(&s.style_probes)
		ce_destroy(p, &s.ce)
		js_shadow_destroy(p, &s.shadow)
		free(s)
		p.jsdom = nil
	}, p)
	return s
}

////////////////////////////////
// Selectors

// The parsed selector list of `text` (cached); ok = false for an invalid list. Pseudo-elements never match an element:
// complex selectors with one are left out of the list (it stays valid).
@(private)
selector_list :: proc(p: ^Page, text: string) -> (list: css.Selector_List, ok: bool) {
	s := js_dom_state(p)
	s.sel_clock += 1
	for &e in s.selectors {
		if e.text == text { e.used = s.sel_clock; return e.list, true }   // only valid lists are kept
	}
	cap := p.settings.dom.selector_cache_entries
	parse :: proc(p: ^Page, text: string, a: css.Arena_Alloc) -> (css.Selector_List, bool) {
		opt := style.parse_options(&p.settings.style)
		vs := css.trim_values(css.parse_component_values(text, opt, a))
		if len(vs) == 0 { return nil, false }
		l, good := css.parse_selector_list(vs, a, nil)
		if !good { return nil, false }
		out := make([dynamic]css.Complex, 0, len(l), a)
		for cx in l { if cx.pseudo_element == .None { append(&out, cx) } }
		return out[:], true
	}
	if cap <= 0 { return parse(p, text, context.temp_allocator) }
	e := Selector_Entry{text = strings.clone(text), used = s.sel_clock}
	_ = virtual.arena_init_growing(&e.arena, 4096)
	l, good := parse(p, text, virtual.arena_allocator(&e.arena))
	if !good { delete(e.text); virtual.arena_destroy(&e.arena); return nil, false }
	e.list = l
	if len(s.selectors) >= cap {
		// the least recently used goes
		oldest := 0
		for x, i in s.selectors { if x.used < s.selectors[oldest].used { oldest = i } }
		delete(s.selectors[oldest].text)
		virtual.arena_destroy(&s.selectors[oldest].arena)
		s.selectors[oldest] = e
	} else {
		append(&s.selectors, e)
	}
	return l, true
}

@(private)
SYNTAX_SELECTOR :: "The provided selector is not a valid selector."

// A matching context for scripts: the page's state pseudo-classes (hover, focus...), `scope` for :scope. In a shadow
// tree (that of `in_tree`), the host is seen featureless: `:host` matches it, as the tree's own rules see it.
@(private)
script_match_ctx :: proc(p: ^Page, scope: base.Handle, in_tree: base.Handle) -> style.Match_Ctx {
	m: style.Match_Ctx
	style.match_ctx_init(&m, p.doc, p.style_state, context.temp_allocator)
	m.scope = scope
	if dom.has_shadow_trees(p.doc) {
		if r := dom.containing_shadow_root(p.doc, in_tree); r != base.NIL_HANDLE { m.featureless = dom.get(p.doc, r).shadow }
	}
	return m
}

// The elements of the subtree of `root` (itself excluded) that match, in tree order; stops at the first when `first`.
@(private)
select_in :: proc(p: ^Page, root: base.Handle, list: css.Selector_List, first: bool) -> [dynamic]base.Handle {
	d := p.doc
	out := make([dynamic]base.Handle, 0, first ? 1 : 16, context.temp_allocator)
	if len(list) == 0 { return out }
	scope := root
	if rn := dom.get(d, root); rn == nil || rn.kind != .Element { scope = base.NIL_HANDLE }
	m := script_match_ctx(p, scope, root)
	// the subject has an #id and the search is in the document's tree: the id index gives the candidates
	if id := subject_id(list); id != "" && dom.tree_root(d, root) == d.root {
		for cur in dom.ids_all(d, id) {
			if cur == root || !dom.is_ancestor_or_self(d, root, cur) { continue }
			if style.matches_list(&m, cur, list) {
				append(&out, cur)
				if first { break }
			}
		}
		return out
	}
	for cur := dom.next_in_tree(d, root, root); cur != base.NIL_HANDLE; cur = dom.next_in_tree(d, cur, root) {
		n := dom.get(d, cur)
		if n.kind != .Element { continue }
		if style.matches_list(&m, cur, list) {
			append(&out, cur)
			if first { break }
		}
	}
	return out
}

// The id every element a selector list matches must have ("" when not one): a single complex selector whose subject
// compound has an #id.
@(private)
subject_id :: proc(list: css.Selector_List) -> string {
	if len(list) != 1 { return "" }
	cx := list[0]
	if len(cx.compounds) == 0 { return "" }
	for s in cx.compounds[len(cx.compounds) - 1].simples { if s.kind == .Id { return s.name } }
	return ""
}

ParentNode_querySelector :: proc(c: ^Call, node: Api_Node, selectors: string) -> (u64, Api_Error) {
	list, ok := selector_list(c.page, selectors)
	if !ok { return 0, fail(c, .Syntax, SYNTAX_SELECTOR) }
	r := select_in(c.page, H(node.handle), list, true)
	return len(r) > 0 ? u64(r[0]) : 0, .None
}

ParentNode_querySelectorAllPacked :: proc(c: ^Call, node: Api_Node, selectors: string) -> ([]u8, Api_Error) {
	list, ok := selector_list(c.page, selectors)
	if !ok { return nil, fail(c, .Syntax, SYNTAX_SELECTOR) }
	r := select_in(c.page, H(node.handle), list, false)
	return pack_handles(r[:]), .None
}

// Handles as 8 little-endian bytes each (temp memory).
@(private)
pack_handles :: proc(hs: []base.Handle) -> []u8 {
	out := make([]u8, len(hs) * 8, context.temp_allocator)
	for h, i in hs {
		v := u64(h)
		for k in 0 ..< 8 { out[i * 8 + k] = u8(v >> (8 * uint(k))) }
	}
	return out
}

Element_matches :: proc(c: ^Call, element: Api_Element, selectors: string) -> (bool, Api_Error) {
	list, ok := selector_list(c.page, selectors)
	if !ok { return false, fail(c, .Syntax, SYNTAX_SELECTOR) }
	m := script_match_ctx(c.page, H(element.handle), H(element.handle))
	return style.matches_list(&m, H(element.handle), list), .None
}

Element_webkitMatchesSelector :: proc(c: ^Call, element: Api_Element, selectors: string) -> (bool, Api_Error) {
	return Element_matches(c, element, selectors)
}

Element_closest :: proc(c: ^Call, element: Api_Element, selectors: string) -> (u64, Api_Error) {
	list, ok := selector_list(c.page, selectors)
	if !ok { return 0, fail(c, .Syntax, SYNTAX_SELECTOR) }
	d := c.page.doc
	m := script_match_ctx(c.page, H(element.handle), H(element.handle))
	for cur := H(element.handle); cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil || n.kind != .Element { break }
		if style.matches_list(&m, cur, list) { return u64(cur), .None }
		cur = n.parent
	}
	return 0, .None
}

////////////////////////////////
// Live collections

Collection_Kind :: enum i32 {
	Child_Nodes, Children, Tag_Name, Class_Names, Name, Forms, Images, Links, Scripts, Embeds, Anchors, Tag_Name_NS,
	All, Options, Table_Rows, Row_Cells, Table_Bodies, Form_Elements, Selected_Options, Fieldset_Elements, Map_Areas, Labels,
}

@(private)
Dom_Collection :: struct {
	root:     base.Handle,
	kind:     Collection_Kind,
	arg:      string,         // owned: the name; Tag_Name_NS: the local name
	ns:       string,         // owned: Tag_Name_NS: the namespace ("*" any)
	classes:  []string,       // owned: Class_Names, the set
	tree_v:   u64,
	attr_v:   u64,
	valid:    bool,
	items:    [dynamic]base.Handle,
}

@(private)
collection_vt := Object_VTable{name = "DOMCollection", destroy = proc(p: ^Page, data: rawptr) {
	col := (^Dom_Collection)(data)
	delete(col.arg); delete(col.ns)
	for k in col.classes { delete(k) }
	delete(col.classes)
	delete(col.items)
	free(col)
}}

// Whether the collection's membership depends on attributes too (not only on the tree).
@(private)
uses_attributes :: proc(k: Collection_Kind) -> bool {
	#partial switch k {
	case .Class_Names, .Name, .Links, .Anchors, .Form_Elements, .Labels: return true
	}
	return false
}

@(private)
split_tokens :: proc(s: string, allocator := context.temp_allocator) -> [dynamic]string {
	out := make([dynamic]string, 0, 4, allocator)
	i := 0
	for i < len(s) {
		for i < len(s) && is_ascii_ws(s[i]) { i += 1 }
		j := i
		for j < len(s) && !is_ascii_ws(s[j]) { j += 1 }
		if j > i {
			t := s[i:j]
			dup := false
			for x in out { if x == t { dup = true; break } }
			if !dup { append(&out, t) }
		}
		i = j
	}
	return out
}

Collection_create :: proc(c: ^Call, root: Api_Node, kind: i32, arg: string) -> (u64, Api_Error) {
	if kind < 0 || kind > i32(max(Collection_Kind)) { return 0, fail(c, .Invalid_Argument, "unknown collection") }
	col := new(Dom_Collection)
	col.root = H(root.handle)
	col.kind = Collection_Kind(kind)
	#partial switch col.kind {
	case .Class_Names:
		toks := split_tokens(arg)
		col.classes = make([]string, len(toks))
		quirks := c.page.doc.mode == .Quirks
		for t, i in toks { col.classes[i] = quirks ? strings.to_lower(t) : strings.clone(t) }
	case .Tag_Name_NS:
		if sep := strings.index_byte(arg, 0); sep >= 0 {
			col.ns, col.arg = strings.clone(arg[:sep]), strings.clone(arg[sep + 1:])
		} else {
			col.ns, col.arg = strings.clone("*"), strings.clone(arg)
		}
	case:
		col.arg = strings.clone(arg)
	}
	return object_create(c.page, &collection_vt, col, c.owner), .None
}

@(private)
has_class_token :: proc(v: string, k: string, quirks: bool) -> bool {
	i := 0
	for i < len(v) {
		for i < len(v) && is_ascii_ws(v[i]) { i += 1 }
		j := i
		for j < len(v) && !is_ascii_ws(v[j]) { j += 1 }
		if j > i {
			t := v[i:j]
			if quirks ? strings.equal_fold(t, k) : t == k { return true }
		}
		i = j
	}
	return false
}

@(private)
attr_of :: #force_inline proc(n: ^dom.Node, name: string) -> (string, bool) {
	for a in n.attrs { if a.name == name { return a.value, true } }
	return "", false
}

// Whether element `n` (`h`) belongs to the collection (the descendant kinds).
@(private)
collection_accepts :: proc(p: ^Page, col: ^Dom_Collection, h: base.Handle, n: ^dom.Node) -> bool {
	if n.kind != .Element { return false }
	html := n.ns == .HTML
	switch col.kind {
	case .Child_Nodes, .Children: return true
	case .All: return true
	case .Tag_Name:
		if col.arg == "*" { return true }
		if html { return n.name == dom.lower_name(col.arg) }
		return jd_qualified_name(p.doc, h, false) == col.arg || n.name == dom.lower_name(col.arg)
	case .Tag_Name_NS:
		if col.ns != "*" && dom.ns_uri(p.doc, h) != col.ns { return false }
		return col.arg == "*" || jd_local_name(n) == col.arg
	case .Class_Names:
		if len(col.classes) == 0 { return false }
		v, ok := attr_of(n, "class")
		if !ok { return false }
		quirks := p.doc.mode == .Quirks
		for k in col.classes { if !has_class_token(v, k, quirks) { return false } }
		return true
	case .Name:
		v, ok := attr_of(n, "name")
		return ok && v == col.arg && html
	case .Forms: return html && n.name == "form"
	case .Images: return html && n.name == "img"
	case .Links:
		if !html || (n.name != "a" && n.name != "area") { return false }
		_, ok := attr_of(n, "href")
		return ok
	case .Scripts: return html && n.name == "script"
	case .Embeds: return html && n.name == "embed"
	case .Anchors:
		if !html || n.name != "a" { return false }
		_, ok := attr_of(n, "name")
		return ok
	case .Options: return html && n.name == "option"
	case .Table_Rows: return html && n.name == "tr"
	case .Row_Cells: return html && (n.name == "td" || n.name == "th")
	case .Table_Bodies: return html && n.name == "tbody"
	case .Form_Elements:
		if !html { return false }
		switch n.name {
		case "button", "fieldset", "object", "output", "select", "textarea": return true
		case "input":
			t, _ := attr_of(n, "type")
			return !strings.equal_fold(t, "image")
		}
	case .Fieldset_Elements:
		if !html { return false }
		switch n.name {
		case "button", "fieldset", "input", "object", "output", "select", "textarea": return true
		}
	case .Map_Areas: return html && n.name == "area"
	case .Selected_Options, .Labels: return false   // collection_refresh
	}
	return false
}

// Brings the list up to date (a walk only when the document changed in a way the collection depends on).
@(private)
collection_refresh :: proc(p: ^Page, col: ^Dom_Collection) {
	d := p.doc
	// the options' selectedness is the forms model's state, which the versions do not follow
	if col.valid && col.kind != .Selected_Options && col.tree_v == d.tree_version && (!uses_attributes(col.kind) || col.attr_v == d.attr_version) { return }
	clear(&col.items)
	col.valid, col.tree_v, col.attr_v = true, d.tree_version, d.attr_version
	root := dom.get(d, col.root)
	if root == nil { return }
	switch col.kind {
	case .Child_Nodes:
		for ch := root.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next { append(&col.items, ch) }
	case .Children, .Row_Cells, .Table_Bodies:
		for ch := root.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
			if collection_accepts(p, col, ch, dom.get(d, ch)) { append(&col.items, ch) }
		}
	case .Table_Rows:
		// the table's rows: in thead, then direct and in tbody children, then in tfoot (HTML §4.9.1)
		for pass in 0 ..< 3 {
			for ch := root.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
				cn := dom.get(d, ch)
				if cn.kind != .Element { continue }
				sect := cn.name
				want := pass == 0 ? sect == "thead" : pass == 2 ? sect == "tfoot" : sect == "tbody"
				if pass == 1 && sect == "tr" { append(&col.items, ch); continue }
				if !want { continue }
				for r := cn.first_child; r != base.NIL_HANDLE; r = dom.get(d, r).next {
					if rn := dom.get(d, r); rn.kind == .Element && rn.name == "tr" { append(&col.items, r) }
				}
			}
		}
		if root.name != "table" {   // a section's rows
			clear(&col.items)
			for ch := root.first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
				if rn := dom.get(d, ch); rn.kind == .Element && rn.name == "tr" { append(&col.items, ch) }
			}
		}
	case .Selected_Options:
		f := page_forms(p)
		for o in forms.select_options_synced(f, col.root) { if forms.option_selected(f, o) { append(&col.items, o) } }
	case .Labels:
		// the label elements of the control's tree whose labeled control it is
		f := page_forms(p)
		top := dom.tree_root(d, col.root)
		for cur := dom.next_in_tree(d, top, top); cur != base.NIL_HANDLE; cur = dom.next_in_tree(d, cur, top) {
			n := dom.get(d, cur)
			if n.kind == .Element && n.ns == .HTML && n.name == "label" && forms.labeled_control(f, cur) == col.root { append(&col.items, cur) }
		}
	case .Tag_Name, .Tag_Name_NS, .Class_Names, .Name, .Forms, .Images, .Links, .Scripts, .Embeds, .Anchors, .All, .Options, .Form_Elements, .Fieldset_Elements, .Map_Areas:
		for cur := dom.next_in_tree(d, col.root, col.root); cur != base.NIL_HANDLE; cur = dom.next_in_tree(d, cur, col.root) {
			if collection_accepts(p, col, cur, dom.get(d, cur)) { append(&col.items, cur) }
		}
	}
}

@(private)
collection_of :: proc(c: ^Call, h: u64) -> ^Dom_Collection {
	if call_doc(c) == nil { return nil }
	return (^Dom_Collection)(object_data(c.page, h, &collection_vt))
}

Collection_length :: proc(c: ^Call, collection: u64) -> u32 {
	col := collection_of(c, collection)
	if col == nil { return 0 }
	collection_refresh(c.page, col)
	return u32(len(col.items))
}

Collection_item :: proc(c: ^Call, collection: u64, index: u32) -> u64 {
	col := collection_of(c, collection)
	if col == nil { return 0 }
	collection_refresh(c.page, col)
	return int(index) < len(col.items) ? u64(col.items[index]) : 0
}

// Elements a name attribute names in an HTMLCollection (DOM §4.2.10.2): those of the HTML namespace.
@(private)
named_by_name :: #force_inline proc(n: ^dom.Node) -> bool { return n.ns == .HTML }

Collection_namedItem :: proc(c: ^Call, collection: u64, name: string) -> u64 {
	col := collection_of(c, collection)
	if col == nil || name == "" { return 0 }
	collection_refresh(c.page, col)
	d := c.page.doc
	for h in col.items {
		n := dom.get(d, h)
		if n == nil || n.kind != .Element { continue }
		if v, ok := attr_of(n, "id"); ok && v == name { return u64(h) }
		if named_by_name(n) { if v, ok := attr_of(n, "name"); ok && v == name { return u64(h) } }
	}
	return 0
}

HTMLFormElement_namedControl :: proc(c: ^Call, form: Api_Element, name: string) -> u64 {
	if name == "" || form.data.name != "form" { return 0 }
	d := c.page.doc
	col := Dom_Collection{kind = .Form_Elements}
	root := H(form.handle)
	for cur := dom.next_in_tree(d, root, root); cur != base.NIL_HANDLE; cur = dom.next_in_tree(d, cur, root) {
		n := dom.get(d, cur)
		if !collection_accepts(c.page, &col, cur, n) { continue }
		if v, ok := attr_of(n, "id"); ok && v == name { return u64(cur) }
		if v, ok := attr_of(n, "name"); ok && v == name { return u64(cur) }
	}
	return 0
}

Collection_names :: proc(c: ^Call, collection: u64) -> string {
	col := collection_of(c, collection)
	if col == nil { return "" }
	collection_refresh(c.page, col)
	d := c.page.doc
	seen := make(map[string]bool, 16, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	add :: proc(b: ^strings.Builder, seen: ^map[string]bool, s: string) {
		if s == "" || s in seen^ { return }
		seen[s] = true
		strings.write_string(b, s)
		strings.write_byte(b, 0)
	}
	for h in col.items {
		n := dom.get(d, h)
		if n == nil || n.kind != .Element { continue }
		if v, ok := attr_of(n, "id"); ok { add(&b, &seen, v) }
		if named_by_name(n) { if v, ok := attr_of(n, "name"); ok { add(&b, &seen, v) } }
	}
	return strings.to_string(b)
}

////////////////////////////////
// DOMTokenList

@(private)
token_set :: proc(c: ^Call, element: Api_Element, attr: string) -> [dynamic]string {
	v, _ := dom.get_attribute(c.page.doc, H(element.handle), attr)
	return split_tokens(v)
}

// DOMTokenList "update steps": the set serialized into the attribute (not created for an empty set without one).
@(private)
token_update :: proc(c: ^Call, element: Api_Element, attr: string, set: []string) -> Api_Error {
	d := c.page.doc
	h := H(element.handle)
	_, had := dom.get_attribute(d, h, attr)
	if !had && len(set) == 0 { return .None }
	return dom_error(dom.set_attribute(d, h, attr, strings.join(set, " ", context.temp_allocator)))
}

@(private)
check_token :: proc(c: ^Call, t: string) -> Api_Error {
	if t == "" { return fail(c, .Syntax, "The token provided must not be empty.") }
	for i in 0 ..< len(t) { if is_ascii_ws(t[i]) { return fail(c, .Invalid_Character, "The token provided contains HTML space characters, which are not valid in tokens.") } }
	return .None
}

TokenList_length :: proc(c: ^Call, element: Api_Element, attr: string) -> u32 { return u32(len(token_set(c, element, attr))) }

TokenList_item :: proc(c: ^Call, element: Api_Element, attr: string, index: u32) -> (string, Api_Error) {
	set := token_set(c, element, attr)
	if int(index) >= len(set) { return "", .Not_Found }
	return set[index], .None
}

TokenList_contains :: proc(c: ^Call, element: Api_Element, attr: string, token: string) -> bool {
	v, _ := dom.get_attribute(c.page.doc, H(element.handle), attr)
	return has_class_token(v, token, false)
}

TokenList_add :: proc(c: ^Call, element: Api_Element, attr: string, tokens: string) -> Api_Error {
	list := strings.split(tokens, "\x00", context.temp_allocator)
	for t in list { if err := check_token(c, t); err != .None { return err } }
	set := token_set(c, element, attr)
	changed := false
	for t in list {
		found := false
		for x in set { if x == t { found = true; break } }
		if !found { append(&set, t); changed = true }
	}
	_ = changed
	return token_update(c, element, attr, set[:])
}

TokenList_remove :: proc(c: ^Call, element: Api_Element, attr: string, tokens: string) -> Api_Error {
	list := strings.split(tokens, "\x00", context.temp_allocator)
	for t in list { if err := check_token(c, t); err != .None { return err } }
	set := token_set(c, element, attr)
	for t in list {
		for x, i in set { if x == t { ordered_remove(&set, i); break } }
	}
	return token_update(c, element, attr, set[:])
}

TokenList_toggle :: proc(c: ^Call, element: Api_Element, attr: string, token: string, force: i32) -> (bool, Api_Error) {
	if err := check_token(c, token); err != .None { return false, err }
	set := token_set(c, element, attr)
	for x, i in set {
		if x != token { continue }
		if force == 1 { return true, .None }
		ordered_remove(&set, i)
		return false, token_update(c, element, attr, set[:])
	}
	if force == 0 { return false, .None }
	append(&set, token)
	return true, token_update(c, element, attr, set[:])
}

TokenList_replace :: proc(c: ^Call, element: Api_Element, attr: string, token: string, new_token: string) -> (bool, Api_Error) {
	if err := check_token(c, token); err != .None { return false, err }
	if err := check_token(c, new_token); err != .None { return false, err }
	set := token_set(c, element, attr)
	at := -1
	for x, i in set { if x == token { at = i; break } }
	if at < 0 { return false, .None }
	// the new token takes the place of the first of the two; the other occurrence goes
	out := make([dynamic]string, 0, len(set), context.temp_allocator)
	placed := false
	for x in set {
		if x == token || x == new_token {
			if !placed { append(&out, new_token); placed = true }
			continue
		}
		append(&out, x)
	}
	return true, token_update(c, element, attr, out[:])
}

// Link types the browser knows (for relList.supports).
@(private)
SUPPORTED_REL :: [?]string{"alternate", "author", "bookmark", "external", "help", "icon", "license", "modulepreload", "next", "nofollow", "noopener", "noreferrer", "opener", "preconnect", "prefetch", "preload", "prev", "search", "stylesheet", "tag", "dns-prefetch", "manifest"}

TokenList_supports :: proc(c: ^Call, element: Api_Element, attr: string, token: string) -> (bool, Api_Error) {
	if attr == "sandbox" { return sandbox_token_supported(token), .None }   // iframe.sandbox (frames_policy.odin)
	if attr != "rel" { return false, fail(c, .Type, "DOMTokenList has no supported tokens.") }
	l := strings.to_lower(token, context.temp_allocator)
	for s in SUPPORTED_REL { if s == l { return true, .None } }
	return false, .None
}

////////////////////////////////
// DOMStringMap (dataset)

// data-* name of a camel-cased dataset name: "fooBar" -> "data-foo-bar".
@(private)
dataset_attr :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "data-")
	for i in 0 ..< len(name) {
		ch := name[i]
		if ch >= 'A' && ch <= 'Z' { strings.write_byte(&b, '-'); strings.write_byte(&b, ch + 32) } else { strings.write_byte(&b, ch) }
	}
	return strings.to_string(b)
}

Dataset_get :: proc(c: ^Call, element: Api_Element, name: string) -> (string, Api_Error) {
	v, ok := attr_of(element.data, dataset_attr(name))
	if !ok { return "", .Not_Found }
	return v, .None
}

Dataset_set :: proc(c: ^Call, element: Api_Element, name: string, value: string) -> Api_Error {
	for i in 0 ..< len(name) {
		if name[i] == '-' && i + 1 < len(name) && name[i + 1] >= 'a' && name[i + 1] <= 'z' {
			return fail(c, .Syntax, "'-' followed by a lower case letter is not allowed in a dataset name.")
		}
	}
	attr := dataset_attr(name)
	if !valid_attribute_name(attr) { return fail(c, .Invalid_Character, "The name is not a valid attribute name.") }
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), attr, value))
}

Dataset_delete :: proc(c: ^Call, element: Api_Element, name: string) -> bool {
	attr := dataset_attr(name)
	if _, ok := attr_of(element.data, attr); !ok { return false }
	dom.remove_attribute(c.page.doc, H(element.handle), attr)
	return true
}

Dataset_names :: proc(c: ^Call, element: Api_Element) -> string {
	b := strings.builder_make(context.temp_allocator)
	outer: for a in element.data.attrs {
		if !strings.has_prefix(a.name, "data-") { continue }
		rest := a.name[5:]
		for i in 0 ..< len(rest) { if rest[i] >= 'A' && rest[i] <= 'Z' { continue outer } }
		for i := 0; i < len(rest); i += 1 {
			if rest[i] == '-' && i + 1 < len(rest) && rest[i + 1] >= 'a' && rest[i + 1] <= 'z' {
				strings.write_byte(&b, rest[i + 1] - 32)
				i += 1
				continue
			}
			strings.write_byte(&b, rest[i])
		}
		strings.write_byte(&b, 0)
	}
	return strings.to_string(b)
}
