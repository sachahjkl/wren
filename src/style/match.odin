package style

import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"

// Selector matching (Selectors Level 4) against the DOM, right to left. The input state (hover, focus...) comes from the
// shell; everything else is read from the tree.

State :: struct {
	hover, active, focus: base.Handle,
	// where the focus is for :focus-within only (the element and its flat ancestors match): normally the same as `focus`, but the
	// developer tools can force :focus-within on an element without forcing :focus / :focus-visible on it (Chrome's :hov panel).
	focus_within:         base.Handle,
	visited:              base.Handle,   // an element the developer tools force to :visited (no history is kept: nothing else is)
	focus_visible:        bool,         // the focus should be visible (:focus-visible): it came from the keyboard, or is in a text field
	target_id:            string,       // the fragment of the document URL, for :target
	fullscreen:           base.Handle,  // the element in full screen (Fullscreen API), for :fullscreen
	controls:             Control_Provider,
}

// Form control state (checkedness, validity, what is typed...) lives outside the DOM attributes; the page plugs in the
// forms model here. `known = false` (or no provider) falls back to the attributes.
Control_Query :: enum u8 {
	Checked, Indeterminate, Default, Disabled, Read_Write, Placeholder_Shown,
	Valid, Invalid, User_Valid, User_Invalid, In_Range, Out_Of_Range,
	Popover_Open,   // the element is a popover that is showing (not a form control: the page's popover state)
}

Control_Provider :: struct {
	query: proc(user: rawptr, el: base.Handle, q: Control_Query) -> (answer: bool, known: bool),
	user:  rawptr,
}

@(private)
control_query :: proc(m: ^Match_Ctx, el: base.Handle, q: Control_Query) -> (answer: bool, known: bool) {
	if m.state.controls.query == nil { return false, false }
	return m.state.controls.query(m.state.controls.user, el, q)
}

Sib_Info :: struct { index, index_last, type_index, type_index_last: int }   // 1-based

Match_Ctx :: struct {
	doc:    ^dom.Document,
	state:  State,
	scope:  base.Handle,                 // :scope and a top-level `&` (the root element when nil)
	sibs:   map[base.Handle]Sib_Info,    // filled one parent at a time, cleared with the style pass
	filled: map[base.Handle]bool,
	max_depth: int,
	ignore_state: bool,                  // state pseudo-classes count as matching: "could this element match?"
	// matching the rules of a shadow tree: its host, which they see featureless (only :host, :host(), :host-context()
	// match it), reached as the parent of the tree's top elements (CSS Scoping §3.2); NIL for the document's rules
	featureless: base.Handle,
	// :has() answered in this pass: (anchor, argument list) -> matched. A rule such as `:not(:has(.x)) > .item .by` asks it of the
	// same ancestor for every element under it, each time scanning the ancestor's whole subtree.
	has_memo: map[Has_Key]bool,
}

@(private)
Has_Key :: struct { anchor: base.Handle, list: rawptr }

match_ctx_init :: proc(m: ^Match_Ctx, d: ^dom.Document, state: State, allocator := context.allocator) {
	m.doc, m.state = d, state
	m.sibs = make(map[base.Handle]Sib_Info, allocator)
	m.filled = make(map[base.Handle]bool, allocator)
	m.has_memo = make(map[Has_Key]bool, allocator)
}

match_ctx_destroy :: proc(m: ^Match_Ctx) {
	delete(m.sibs)
	delete(m.filled)
	delete(m.has_memo)
}

@(private)
node_of :: #force_inline proc(m: ^Match_Ctx, h: base.Handle) -> ^dom.Node { return dom.get(m.doc, h) }

@(private)
is_element :: proc(m: ^Match_Ctx, h: base.Handle) -> bool {
	n := node_of(m, h)
	return n != nil && n.kind == .Element
}

@(private)
parent_element :: proc(m: ^Match_Ctx, h: base.Handle) -> base.Handle {
	n := node_of(m, h)
	if n == nil { return base.NIL_HANDLE }
	p := node_of(m, n.parent)
	if p == nil || p.kind != .Element { return base.NIL_HANDLE }
	return n.parent
}

@(private)
prev_element :: proc(m: ^Match_Ctx, h: base.Handle) -> base.Handle {
	n := node_of(m, h)
	if n == nil { return base.NIL_HANDLE }
	cur := n.prev
	for cur != base.NIL_HANDLE {
		if is_element(m, cur) { return cur }
		cur = node_of(m, cur).prev
	}
	return base.NIL_HANDLE
}

attr :: proc(n: ^dom.Node, name: string) -> (string, bool) {
	for a in n.attrs { if a.name == name { return a.value, true } }
	return "", false
}

@(private)
has_class :: proc(n: ^dom.Node, name: string) -> bool {
	v, ok := attr(n, "class")
	if !ok { return false }
	rest := v
	for len(rest) > 0 {
		for len(rest) > 0 && is_space(rest[0]) { rest = rest[1:] }
		end := 0
		for end < len(rest) && !is_space(rest[end]) { end += 1 }
		if end > 0 && rest[:end] == name { return true }
		rest = rest[end:]
	}
	return false
}

@(private)
is_space :: #force_inline proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }

@(private)
value_equals :: proc(a, b: string, ci: bool) -> bool { return ci ? strings.equal_fold(a, b) : a == b }

@(private)
attr_matches :: proc(n: ^dom.Node, s: css.Simple) -> bool {
	v, ok := attr(n, s.name)
	if !ok { return false }
	if s.op == .Exists { return true }
	want := s.value
	switch s.op {
	case .Exists: return true
	case .Equals: return value_equals(v, want, s.ci)
	case .Includes:
		if want == "" || strings.contains_any(want, " \t\n\r\f") { return false }
		rest := v
		for len(rest) > 0 {
			for len(rest) > 0 && is_space(rest[0]) { rest = rest[1:] }
			end := 0
			for end < len(rest) && !is_space(rest[end]) { end += 1 }
			if end > 0 && value_equals(rest[:end], want, s.ci) { return true }
			rest = rest[end:]
		}
		return false
	case .Dash_Match: return value_equals(v, want, s.ci) || (len(v) > len(want) && v[len(want)] == '-' && value_equals(v[:len(want)], want, s.ci))
	case .Prefix: return want != "" && len(v) >= len(want) && value_equals(v[:len(want)], want, s.ci)
	case .Suffix: return want != "" && len(v) >= len(want) && value_equals(v[len(v) - len(want):], want, s.ci)
	case .Substring:
		if want == "" { return false }
		if s.ci { return strings.contains(css.lower_temp(v), css.lower_temp(want)) }
		return strings.contains(v, want)
	}
	return false
}

@(private)
fill_siblings :: proc(m: ^Match_Ctx, parent: base.Handle) {
	if m.filled[parent] { return }
	m.filled[parent] = true
	pn := node_of(m, parent)
	if pn == nil { return }
	total := 0
	types := make(map[string]int, context.temp_allocator)
	cur := pn.first_child
	// first pass: indexes from the start
	for cur != base.NIL_HANDLE {
		n := node_of(m, cur)
		if n.kind == .Element {
			total += 1
			types[n.name] += 1
			m.sibs[cur] = Sib_Info{index = total, type_index = types[n.name]}
		}
		cur = n.next
	}
	// second pass: indexes from the end
	type_totals := types
	seen := make(map[string]int, context.temp_allocator)
	cur = pn.first_child
	for cur != base.NIL_HANDLE {
		n := node_of(m, cur)
		if n.kind == .Element {
			info := m.sibs[cur]
			seen[n.name] += 1
			info.index_last = total - info.index + 1
			info.type_index_last = type_totals[n.name] - info.type_index + 1
			m.sibs[cur] = info
		}
		cur = n.next
	}
}

// Positions among element siblings. A small family is counted directly (no map: matching :nth-child over a page of
// rows used to spend more time filling and growing the maps than matching); a large one is indexed once per parent.
@(private)
sibling_info :: proc(m: ^Match_Ctx, h: base.Handle) -> Sib_Info {
	SMALL :: 32
	n := node_of(m, h)
	if !m.filled[n.parent] {
		info := Sib_Info{index = 1, type_index = 1, index_last = 1, type_index_last = 1}
		steps := 0
		for cur := n.prev; cur != base.NIL_HANDLE && steps < SMALL; steps += 1 {
			s := node_of(m, cur)
			if s.kind == .Element {
				info.index += 1
				if s.name == n.name { info.type_index += 1 }
			}
			cur = s.prev
			if cur == base.NIL_HANDLE { steps = -1; break }
		}
		if steps < 0 || n.prev == base.NIL_HANDLE {
			steps = 0
			for cur := n.next; cur != base.NIL_HANDLE && steps < SMALL; steps += 1 {
				s := node_of(m, cur)
				if s.kind == .Element {
					info.index_last += 1
					if s.name == n.name { info.type_index_last += 1 }
				}
				cur = s.next
				if cur == base.NIL_HANDLE { steps = -1; break }
			}
			if steps < 0 || n.next == base.NIL_HANDLE { return info }
		}
	}
	fill_siblings(m, n.parent)
	return m.sibs[h]
}

@(private)
nth_hit :: proc(a, b, idx: int) -> bool {
	if a == 0 { return idx == b }
	d := idx - b
	return d % a == 0 && d / a >= 0
}

@(private)
FORM_CONTROLS :: [?]string{"input", "button", "select", "textarea", "optgroup", "option", "fieldset"}

@(private)
is_form_control :: proc(n: ^dom.Node) -> bool {
	for f in FORM_CONTROLS { if n.name == f { return true } }
	return false
}

@(private)
is_disabled :: proc(m: ^Match_Ctx, h: base.Handle) -> bool {
	n := node_of(m, h)
	if !is_form_control(n) { return false }
	if _, ok := attr(n, "disabled"); ok { return true }
	if n.name == "option" || n.name == "optgroup" || n.name == "input" || n.name == "button" || n.name == "select" || n.name == "textarea" {
		for anc := parent_element(m, h); anc != base.NIL_HANDLE; anc = parent_element(m, anc) {
			an := node_of(m, anc)
			if an.name == "fieldset" { if _, ok := attr(an, "disabled"); ok { return true } }
		}
	}
	return false
}

@(private)
text_input_type :: proc(n: ^dom.Node) -> bool {
	t, _ := attr(n, "type")
	switch css.lower_temp(t) {
	case "", "text", "search", "url", "tel", "email", "password", "number", "date", "datetime-local", "month", "week", "time": return true
	}
	return false
}

@(private)
is_read_write :: proc(m: ^Match_Ctx, h: base.Handle) -> bool {
	n := node_of(m, h)
	if _, ro := attr(n, "readonly"); ro { return false }
	if is_disabled(m, h) { return false }
	if n.name == "textarea" { return true }
	if n.name == "input" { return text_input_type(n) }
	if ce, ok := attr(n, "contenteditable"); ok { return ce == "" || strings.equal_fold(ce, "true") || strings.equal_fold(ce, "plaintext-only") }
	return false
}

@(private)
lang_of :: proc(m: ^Match_Ctx, h: base.Handle) -> string {
	for cur := h; cur != base.NIL_HANDLE; cur = parent_element(m, cur) {
		n := node_of(m, cur)
		if v, ok := attr(n, "lang"); ok { return v }
		if v, ok := attr(n, "xml:lang"); ok { return v }
	}
	return ""
}

@(private)
dir_of :: proc(m: ^Match_Ctx, h: base.Handle) -> string {
	for cur := h; cur != base.NIL_HANDLE; cur = parent_element(m, cur) {
		n := node_of(m, cur)
		if v, ok := attr(n, "dir"); ok {
			l := css.lower_temp(v)
			if l == "ltr" || l == "rtl" { return l }
		}
	}
	return "ltr"
}

@(private)
is_empty_element :: proc(m: ^Match_Ctx, h: base.Handle) -> bool {
	cur := node_of(m, h).first_child
	for cur != base.NIL_HANDLE {
		n := node_of(m, cur)
		if n.kind == .Element { return false }
		if n.kind == .Text && len(n.text) > 0 { return false }
		cur = n.next
	}
	return true
}

matches_list :: proc(m: ^Match_Ctx, el: base.Handle, list: css.Selector_List) -> bool {
	for &c in list { if matches_complex(m, el, &c) { return true } }
	return false
}

matches_complex :: proc(m: ^Match_Ctx, el: base.Handle, c: ^css.Complex) -> bool {
	return match_chain(m, el, c, len(c.compounds) - 1, base.NIL_HANDLE, 0)
}

@(private)
match_chain :: proc(m: ^Match_Ctx, el: base.Handle, c: ^css.Complex, idx: int, anchor: base.Handle, depth: int) -> bool {
	if depth > 4096 { return false }   // a hard stop independent of any configured limit
	if !matches_compound(m, el, c.compounds[idx]) { return false }
	if idx == 0 {
		if !c.relative { return true }
		return relates_to_anchor(m, el, c.leading, anchor)
	}
	switch c.combinators[idx - 1] {
	case .Child:
		p := parent_for_match(m, el)
		return p != base.NIL_HANDLE && match_chain(m, p, c, idx - 1, anchor, depth + 1)
	case .Descendant:
		for p := parent_for_match(m, el); p != base.NIL_HANDLE; p = parent_for_match(m, p) {
			if match_chain(m, p, c, idx - 1, anchor, depth + 1) { return true }
		}
		return false
	case .Next_Sibling:
		if el == m.featureless { return false }   // the host has no siblings in the shadow tree
		p := prev_element(m, el)
		return p != base.NIL_HANDLE && match_chain(m, p, c, idx - 1, anchor, depth + 1)
	case .Subsequent_Sibling:
		if el == m.featureless { return false }
		for p := prev_element(m, el); p != base.NIL_HANDLE; p = prev_element(m, p) {
			if match_chain(m, p, c, idx - 1, anchor, depth + 1) { return true }
		}
		return false
	}
	return false
}

// How the leftmost compound of a relative selector must stand to the :has() anchor.
@(private)
relates_to_anchor :: proc(m: ^Match_Ctx, el: base.Handle, comb: css.Combinator, anchor: base.Handle) -> bool {
	switch comb {
	case .Child: return parent_element(m, el) == anchor
	case .Descendant:
		for p := parent_element(m, el); p != base.NIL_HANDLE; p = parent_element(m, p) { if p == anchor { return true } }
		return false
	case .Next_Sibling: return prev_element(m, el) == anchor
	case .Subsequent_Sibling:
		for p := prev_element(m, el); p != base.NIL_HANDLE; p = prev_element(m, p) { if p == anchor { return true } }
		return false
	}
	return false
}

@(private)
matches_compound :: proc(m: ^Match_Ctx, el: base.Handle, comp: css.Compound) -> bool {
	n := node_of(m, el)
	if n == nil || n.kind != .Element { return false }
	if el == m.featureless && !featureless_may_match(comp) { return false }
	for &s in comp.simples { if !matches_simple(m, el, n, s) { return false } }
	return true
}

// The host seen from its shadow tree: only a compound with :host / :host() / :host-context() (perhaps in :is()) can
// match it, and none with a type, id, class or attribute selector. (Out of matches_compound, which stays small.)
@(private)
featureless_may_match :: proc(comp: css.Compound) -> bool {
	host := false
	for s in comp.simples {
		#partial switch s.kind {
		case .Type, .Id, .Class, .Attribute: return false
		case .Pseudo_Class:
			#partial switch s.pseudo {
			case .Host, .Host_Context: host = true
			case .Is, .Where, .Not: if s.list != nil && list_has_host(s.list^, 0) { host = true }
			}
		}
	}
	return host
}

// The parent element `el` is matched against by a child or descendant combinator: its parent in its tree, or, at the
// top of a shadow tree whose rules are being matched, the featureless host. Nothing above the host.
@(private)
parent_for_match :: #force_inline proc(m: ^Match_Ctx, el: base.Handle) -> base.Handle {
	if m.featureless == base.NIL_HANDLE { return parent_element(m, el) }
	if el == m.featureless { return base.NIL_HANDLE }
	n := node_of(m, el)
	if n == nil { return base.NIL_HANDLE }
	p := node_of(m, n.parent)
	if p == nil { return base.NIL_HANDLE }
	if p.kind == .Element { return n.parent }
	if p.is_shadow && p.shadow == m.featureless { return m.featureless }
	return base.NIL_HANDLE
}

// The compound of :host(), :host-context() or ::slotted() matched against `el` as an ordinary element.
@(private)
matches_compound_plain :: proc(m: ^Match_Ctx, el: base.Handle, comp: css.Compound) -> bool {
	saved := m.featureless
	m.featureless = base.NIL_HANDLE
	ok := matches_compound(m, el, comp)
	m.featureless = saved
	return ok
}

// :focus (HTML "focused"): the focused element, and a shadow host whose shadow tree holds it.
@(private)
focus_matches :: proc(m: ^Match_Ctx, el: base.Handle, n: ^dom.Node) -> bool {
	f := m.state.focus
	if f == base.NIL_HANDLE { return false }
	if f == el { return true }
	return n.shadow != base.NIL_HANDLE && dom.shadow_including_ancestor(m.doc, n.shadow, f)
}

@(private)
matches_simple :: proc(m: ^Match_Ctx, el: base.Handle, n: ^dom.Node, s: css.Simple) -> bool {
	switch s.kind {
	case .Type: return n.name == s.name
	case .Universal: return true
	case .Id:
		v, ok := attr(n, "id")
		return ok && v == s.name
	case .Class: return has_class(n, s.name)
	case .Attribute: return attr_matches(n, s)
	case .Nesting:
		if s.list == nil { return is_scope(m, el) }
		if m.ignore_state { if k, h := list_state(s.list^); k != {} || h { return true } }
		return matches_list(m, el, s.list^)
	case .Pseudo_Class: return matches_pseudo(m, el, n, s)
	}
	return false
}

@(private)
is_scope :: proc(m: ^Match_Ctx, el: base.Handle) -> bool {
	if m.scope != base.NIL_HANDLE { return el == m.scope }
	p := node_of(m, node_of(m, el).parent)
	return p != nil && p.kind == .Document
}

@(private)
matches_pseudo :: proc(m: ^Match_Ctx, el: base.Handle, n: ^dom.Node, s: css.Simple) -> bool {
	if m.ignore_state {
		#partial switch s.pseudo {
		case .Hover, .Active, .Focus, .Focus_Visible, .Focus_Within, .Target, .Fullscreen: return true
		case .Not, .Is, .Where, .Has:
			if s.list != nil { if k, h := list_state(s.list^); k != {} || h { return true } }
		}
	}
	switch s.pseudo {
	case .None: return false
	case .Root:
		p := node_of(m, n.parent)
		return p != nil && p.kind == .Document
	case .Scope: return is_scope(m, el)
	case .Empty: return is_empty_element(m, el)
	case .First_Child: return sibling_info(m, el).index == 1
	case .Last_Child: return sibling_info(m, el).index_last == 1
	case .Only_Child: i := sibling_info(m, el); return i.index == 1 && i.index_last == 1
	case .First_Of_Type: return sibling_info(m, el).type_index == 1
	case .Last_Of_Type: return sibling_info(m, el).type_index_last == 1
	case .Only_Of_Type: i := sibling_info(m, el); return i.type_index == 1 && i.type_index_last == 1
	case .Nth_Child, .Nth_Last_Child:
		if s.list != nil { return nth_of_selector(m, el, s) }
		i := sibling_info(m, el)
		return nth_hit(s.nth_a, s.nth_b, s.pseudo == .Nth_Child ? i.index : i.index_last)
	case .Nth_Of_Type: return nth_hit(s.nth_a, s.nth_b, sibling_info(m, el).type_index)
	case .Nth_Last_Of_Type: return nth_hit(s.nth_a, s.nth_b, sibling_info(m, el).type_index_last)
	case .Not: return !matches_list(m, el, s.list^)
	case .Is, .Where: return matches_list(m, el, s.list^)
	case .Has: return matches_has(m, el, s.list^)
	case .Hover: return m.state.hover != base.NIL_HANDLE && dom.flat_ancestor_or_self(m.doc, el, m.state.hover)
	case .Active: return m.state.active != base.NIL_HANDLE && dom.flat_ancestor_or_self(m.doc, el, m.state.active)
	case .Focus: return focus_matches(m, el, n)
	case .Focus_Visible: return m.state.focus_visible && focus_matches(m, el, n)
	case .Focus_Within:
		// the element the focus (or a forced :focus-within, which `effective_state` puts here) is on; :focus-within matches it and
		// its flat ancestors. When nothing is forced, focus_within is the focused element, so the behaviour is unchanged.
		fw := m.state.focus_within != base.NIL_HANDLE ? m.state.focus_within : m.state.focus
		return fw != base.NIL_HANDLE && dom.flat_ancestor_or_self(m.doc, el, fw)
	case .Host:
		if el != m.featureless { return false }
		return s.list == nil || matches_compound_plain(m, el, s.list^[0].compounds[0])
	case .Host_Context:
		if el != m.featureless || s.list == nil { return false }
		for cur := el; cur != base.NIL_HANDLE; cur = dom.parent_or_host(m.doc, cur) {
			if is_element(m, cur) && matches_compound_plain(m, cur, s.list^[0].compounds[0]) { return true }
		}
		return false
	case .State: return dom.custom_state_has(m.doc, el, s.name)
	case .Has_Slotted:
		// flattened: a slot whose assigned slot is empty has nothing slotted
		if n.name != "slot" || len(dom.assigned_nodes_raw(m.doc, el)) == 0 { return false }
		return len(dom.assigned_nodes(m.doc, el, true)) > 0
	case .Link, .Any_Link:
		if n.name != "a" && n.name != "area" { return false }
		_, ok := attr(n, "href")
		return ok && !(m.state.visited != base.NIL_HANDLE && el == m.state.visited)
	case .Visited: return m.state.visited != base.NIL_HANDLE && el == m.state.visited
	case .Fullscreen: return m.state.fullscreen != base.NIL_HANDLE && m.state.fullscreen == el
	case .Target:
		v, ok := attr(n, "id")
		return ok && m.state.target_id != "" && v == m.state.target_id
	case .Checked:
		if a, known := control_query(m, el, .Checked); known { return a }
		if n.name == "option" { _, ok := attr(n, "selected"); return ok }
		if n.name == "input" {
			t, _ := attr(n, "type")
			if strings.equal_fold(t, "checkbox") || strings.equal_fold(t, "radio") { _, ok := attr(n, "checked"); return ok }
		}
		return false
	case .Disabled:
		if a, known := control_query(m, el, .Disabled); known { return a }
		return is_disabled(m, el)
	case .Enabled:
		if !is_form_control(n) { return false }
		if a, known := control_query(m, el, .Disabled); known { return !a }
		return !is_disabled(m, el)
	case .Required:
		if n.name != "input" && n.name != "select" && n.name != "textarea" { return false }
		_, ok := attr(n, "required")
		return ok
	case .Optional:
		if n.name != "input" && n.name != "select" && n.name != "textarea" { return false }
		_, ok := attr(n, "required")
		return !ok
	case .Read_Write:
		if a, known := control_query(m, el, .Read_Write); known { return a }
		return is_read_write(m, el)
	case .Read_Only:
		if a, known := control_query(m, el, .Read_Write); known { return !a }
		return !is_read_write(m, el)
	case .Valid, .Invalid, .User_Valid, .User_Invalid, .In_Range, .Out_Of_Range, .Indeterminate, .Default:
		q: Control_Query
		#partial switch s.pseudo {
		case .Valid: q = .Valid
		case .Invalid: q = .Invalid
		case .User_Valid: q = .User_Valid
		case .User_Invalid: q = .User_Invalid
		case .In_Range: q = .In_Range
		case .Out_Of_Range: q = .Out_Of_Range
		case .Indeterminate: q = .Indeterminate
		case .Default: q = .Default
		}
		a, _ := control_query(m, el, q)
		return a
	case .Autofill: return false
	case .Popover_Open:
		if _, ok := attr(n, "popover"); !ok { return false }
		a, _ := control_query(m, el, .Popover_Open)
		return a
	case .Placeholder_Shown:
		if a, known := control_query(m, el, .Placeholder_Shown); known { return a }
		if n.name != "input" && n.name != "textarea" { return false }
		ph, ok := attr(n, "placeholder")
		if !ok || ph == "" { return false }
		if n.name == "input" {
			if !text_input_type(n) { return false }
			v, _ := attr(n, "value")
			return v == ""
		}
		return is_empty_element(m, el)
	case .Lang:
		l := lang_of(m, el)
		if l == "" { return false }
		return strings.equal_fold(l, s.name) || (len(l) > len(s.name) && l[len(s.name)] == '-' && strings.equal_fold(l[:len(s.name)], s.name))
	case .Dir: return dir_of(m, el) == s.name
	case .Defined: return dom.element_is_defined(m.doc, el)
	case .Open:
		if n.name != "details" && n.name != "dialog" { return false }
		_, ok := attr(n, "open")
		return ok
	case .Never: return false
	case .Before, .After, .First_Line, .First_Letter, .Selection, .Placeholder, .Marker, .Backdrop, .Slotted, .Part, .Other_Element: return false
	}
	return false
}

@(private)
nth_of_selector :: proc(m: ^Match_Ctx, el: base.Handle, s: css.Simple) -> bool {
	if !matches_list(m, el, s.list^) { return false }
	pn := node_of(m, node_of(m, el).parent)
	if pn == nil { return false }
	// count matching siblings before (or after) el, el included
	idx := 0
	forward := s.pseudo == .Nth_Child
	cur := forward ? pn.first_child : pn.last_child
	for cur != base.NIL_HANDLE {
		cn := node_of(m, cur)
		if cn.kind == .Element && matches_list(m, cur, s.list^) { idx += 1 }
		if cur == el { break }
		cur = forward ? cn.next : cn.prev
	}
	return nth_hit(s.nth_a, s.nth_b, idx)
}

@(private)
matches_has :: proc(m: ^Match_Ctx, anchor: base.Handle, list: css.Selector_List) -> bool {
	// (not while answering "could it match" with the state ignored, nor for a shadow tree's host: other answers)
	memo := !m.ignore_state && m.featureless == base.NIL_HANDLE && m.has_memo.allocator.procedure != nil && len(list) > 0
	key := Has_Key{anchor, raw_data(list)}
	if memo { if r, ok := m.has_memo[key]; ok { return r } }
	r := matches_has_scan(m, anchor, list)
	if memo { m.has_memo[key] = r }
	return r
}

@(private)
matches_has_scan :: proc(m: ^Match_Ctx, anchor: base.Handle, list: css.Selector_List) -> bool {
	for &c in list {
		switch c.leading {
		case .Descendant, .Child:
			if has_in_subtree(m, anchor, anchor, &c) { return true }
		case .Next_Sibling, .Subsequent_Sibling:
			sib := node_of(m, anchor).next
			for sib != base.NIL_HANDLE {
				if is_element(m, sib) {
					if match_chain(m, sib, &c, len(c.compounds) - 1, anchor, 0) { return true }
					if has_in_subtree(m, anchor, sib, &c) { return true }
				}
				sib = node_of(m, sib).next
			}
		}
	}
	return false
}

// Tries every descendant of `root` (not root itself) as the subject of the relative selector.
@(private)
has_in_subtree :: proc(m: ^Match_Ctx, anchor, root: base.Handle, c: ^css.Complex) -> bool {
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, root)
	for len(stack) > 0 {
		cur := pop(&stack)
		cn := node_of(m, cur)
		child := cn.last_child
		for child != base.NIL_HANDLE {
			ch := node_of(m, child)
			if ch.kind == .Element {
				if match_chain(m, child, c, len(c.compounds) - 1, anchor, 0) { return true }
				append(&stack, child)
			}
			child = ch.prev
		}
	}
	return false
}

// Could `el` match this compound if the dynamic state were different? (Used to scope a restyle after a state change.)
compound_could_match :: proc(m: ^Match_Ctx, el: base.Handle, comp: css.Compound) -> bool {
	saved := m.ignore_state
	m.ignore_state = true
	ok := matches_compound(m, el, comp)
	m.ignore_state = saved
	return ok
}
