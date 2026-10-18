package forms

import "core:strings"
import "wb:base"
import "wb:dom"

// Element categories (HTML §4.10.2), form owners, disabled-ness, radio groups, labels.

kind_of :: proc(n: ^dom.Node) -> Kind {
	if n == nil || n.kind != .Element { return .None }
	switch n.name {
	case "input": return .Input
	case "textarea": return .Textarea
	case "select": return .Select
	case "button": return .Button
	case "option": return .Option
	case "optgroup": return .Optgroup
	case "fieldset": return .Fieldset
	case "legend": return .Legend
	case "output": return .Output
	case "form": return .Form
	case "label": return .Label
	case "object": return .Object
	case "datalist": return .Datalist
	case "dialog": return .Dialog
	}
	return .None
}

attr :: proc(n: ^dom.Node, name: string) -> (string, bool) {
	if n == nil { return "", false }
	for a in n.attrs { if a.name == name { return a.value, true } }
	return "", false
}

has_attr :: proc(n: ^dom.Node, name: string) -> bool {
	_, ok := attr(n, name)
	return ok
}

@(private)
element :: proc(f: ^Forms, h: base.Handle) -> ^dom.Node {
	n := dom.get(f.doc, h)
	if n == nil || n.kind != .Element { return nil }
	return n
}

kind :: proc(f: ^Forms, h: base.Handle) -> Kind { return kind_of(element(f, h)) }

input_type_of :: proc(n: ^dom.Node) -> Input_Type {
	t, ok := attr(n, "type")
	if !ok { return .Text }
	switch strings.to_lower(strings.trim_space(t), context.temp_allocator) {
	case "text": return .Text
	case "search": return .Search
	case "tel": return .Tel
	case "url": return .Url
	case "email": return .Email
	case "password": return .Password
	case "date": return .Date
	case "month": return .Month
	case "week": return .Week
	case "time": return .Time
	case "datetime-local": return .Datetime_Local
	case "number": return .Number
	case "range": return .Range
	case "color": return .Color
	case "checkbox": return .Checkbox
	case "radio": return .Radio
	case "file": return .File
	case "submit": return .Submit
	case "image": return .Image
	case "reset": return .Reset
	case "button": return .Button
	case "hidden": return .Hidden
	}
	return .Text
}

input_type :: proc(f: ^Forms, h: base.Handle) -> Input_Type { return input_type_of(element(f, h)) }

INPUT_TYPE_NAMES := [Input_Type]string{
	.Text = "text", .Search = "search", .Tel = "tel", .Url = "url", .Email = "email", .Password = "password",
	.Date = "date", .Month = "month", .Week = "week", .Time = "time", .Datetime_Local = "datetime-local",
	.Number = "number", .Range = "range", .Color = "color", .Checkbox = "checkbox", .Radio = "radio", .File = "file",
	.Submit = "submit", .Image = "image", .Reset = "reset", .Button = "button", .Hidden = "hidden",
}

// The `type` IDL attribute of any control ("select-one", "textarea", "submit"...).
type_name :: proc(f: ^Forms, h: base.Handle) -> string {
	n := element(f, h)
	switch kind_of(n) {
	case .Input: return INPUT_TYPE_NAMES[input_type_of(n)]
	case .Textarea: return "textarea"
	case .Select: return has_attr(n, "multiple") ? "select-multiple" : "select-one"
	case .Button: return button_type_name(n)
	case .Fieldset: return "fieldset"
	case .Output: return "output"
	case .None, .Option, .Optgroup, .Legend, .Form, .Label, .Object, .Datalist, .Dialog:
	}
	return ""
}

Button_Type :: enum u8 { Submit, Reset, Button }

button_type_of :: proc(n: ^dom.Node) -> Button_Type {
	t, _ := attr(n, "type")
	switch strings.to_lower(strings.trim_space(t), context.temp_allocator) {
	case "reset": return .Reset
	case "button": return .Button
	}
	return .Submit
}

@(private)
button_type_name :: proc(n: ^dom.Node) -> string {
	switch button_type_of(n) {
	case .Submit: return "submit"
	case .Reset: return "reset"
	case .Button: return "button"
	}
	return "submit"
}

TEXT_LIKE :: bit_set[Input_Type]{.Text, .Search, .Tel, .Url, .Email, .Password}
DATE_LIKE :: bit_set[Input_Type]{.Date, .Month, .Week, .Time, .Datetime_Local}
// types the user edits as text in this browser (date-like ones are typed in their ISO form)
TYPED :: TEXT_LIKE | DATE_LIKE | bit_set[Input_Type]{.Number, .Color}
// fields that block implicit submission (§4.10.21.2)
BLOCKS_IMPLICIT :: TEXT_LIKE | DATE_LIKE | bit_set[Input_Type]{.Number}
READONLY_APPLIES :: TEXT_LIKE | DATE_LIKE | bit_set[Input_Type]{.Number}
REQUIRED_APPLIES :: TEXT_LIKE | DATE_LIKE | bit_set[Input_Type]{.Number, .Checkbox, .Radio, .File}
PLACEHOLDER_APPLIES :: TEXT_LIKE | bit_set[Input_Type]{.Number}
MINMAX_APPLIES :: DATE_LIKE | bit_set[Input_Type]{.Number, .Range}
LENGTH_APPLIES :: TEXT_LIKE
PATTERN_APPLIES :: TEXT_LIKE
SUBMIT_BUTTONS :: bit_set[Input_Type]{.Submit, .Image}

// listed: button, fieldset, input, object, output, select, textarea
is_listed :: proc(k: Kind) -> bool {
	#partial switch k { case .Button, .Fieldset, .Input, .Object, .Output, .Select, .Textarea: return true }
	return false
}

is_submittable :: proc(k: Kind) -> bool {
	#partial switch k { case .Button, .Input, .Select, .Textarea: return true }
	return false
}

is_resettable :: proc(k: Kind) -> bool {
	#partial switch k { case .Input, .Output, .Select, .Textarea: return true }
	return false
}

// labelable: button, input (not hidden), meter, output, progress, select, textarea
is_labelable :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	if n == nil { return false }
	switch n.name {
	case "button", "meter", "output", "progress", "select", "textarea": return true
	case "input": return input_type_of(n) != .Hidden
	}
	return false
}

// A submit button: <button type=submit> or <input type=submit|image>.
is_submit_button :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	switch kind_of(n) {
	case .Button: return button_type_of(n) == .Submit
	case .Input: return input_type_of(n) in SUBMIT_BUTTONS
	case .None, .Textarea, .Select, .Option, .Optgroup, .Fieldset, .Legend, .Output, .Form, .Label, .Object, .Datalist, .Dialog:
	}
	return false
}

parent_element :: proc(f: ^Forms, h: base.Handle) -> base.Handle {
	n := dom.get(f.doc, h)
	if n == nil { return base.NIL_HANDLE }
	p := element(f, n.parent)
	return p != nil ? n.parent : base.NIL_HANDLE
}

tree_root :: proc(f: ^Forms, h: base.Handle) -> base.Handle {
	cur := h
	for {
		n := dom.get(f.doc, cur)
		if n == nil || n.parent == base.NIL_HANDLE { return cur }
		cur = n.parent
	}
}

is_connected :: proc(f: ^Forms, h: base.Handle) -> bool { return dom.get(f.doc, h) != nil && tree_root(f, h) == f.doc.root }

// First element of `root`'s tree with that id (iterative, tree order).
@(private)
find_id_in_tree :: proc(f: ^Forms, root: base.Handle, id: string) -> base.Handle {
	if id == "" { return base.NIL_HANDLE }
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, root)
	for len(stack) > 0 {
		cur := pop(&stack)
		n := dom.get(f.doc, cur)
		if n == nil { continue }
		if n.kind == .Element { if v, ok := attr(n, "id"); ok && v == id { return cur } }
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(f.doc, ch).prev { append(&stack, ch) }
	}
	return base.NIL_HANDLE
}

// The form owner (§4.10.17.3): the element named by the `form` attribute when that is a <form> of the same tree,
// otherwise the nearest ancestor <form>. NIL for elements that are not form-associated.
form_owner :: proc(f: ^Forms, h: base.Handle) -> base.Handle {
	n := element(f, h)
	k := kind_of(n)
	if !is_listed(k) && k != .Label && k != .Legend && k != .Option { return base.NIL_HANDLE }
	if k == .Label {
		// label.form: the form owner of the labeled control
		if c := labeled_control(f, h); c != base.NIL_HANDLE { return form_owner(f, c) }
		return base.NIL_HANDLE
	}
	if k == .Legend {
		p := parent_element(f, h)
		if kind(f, p) == .Fieldset { return form_owner(f, p) }
		return base.NIL_HANDLE
	}
	if k == .Option {
		// option.form: the select's form owner
		for p := parent_element(f, h); p != base.NIL_HANDLE; p = parent_element(f, p) {
			pk := kind(f, p)
			if pk == .Select { return form_owner(f, p) }
			if pk != .Optgroup && pk != .Datalist { break }
		}
		return base.NIL_HANDLE
	}
	if id, ok := attr(n, "form"); ok {
		target := find_id_in_tree(f, tree_root(f, h), id)
		if kind(f, target) == .Form { return target }
		return base.NIL_HANDLE
	}
	for p := parent_element(f, h); p != base.NIL_HANDLE; p = parent_element(f, p) {
		if kind(f, p) == .Form { return p }
	}
	return base.NIL_HANDLE
}

// Disabled (§4.10.18.5): own attribute; a disabled fieldset ancestor unless inside that fieldset's first legend; for
// options, a disabled optgroup parent.
is_disabled :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	k := kind_of(n)
	#partial switch k {
	case .Option:
		if has_attr(n, "disabled") { return true }
		p := parent_element(f, h)
		pn := element(f, p)
		return kind_of(pn) == .Optgroup && has_attr(pn, "disabled")
	case .Optgroup:
		return has_attr(n, "disabled")
	case .Button, .Input, .Select, .Textarea, .Fieldset, .Output, .Object:
		if k != .Output && k != .Object && has_attr(n, "disabled") { return true }
		if k == .Output || k == .Object { return false }   // never disabled
		child := h
		for p := parent_element(f, h); p != base.NIL_HANDLE; p = parent_element(f, p) {
			pn := element(f, p)
			if kind_of(pn) == .Fieldset && has_attr(pn, "disabled") {
				// a descendant of the fieldset's first legend child is not disabled by it
				if kind(f, child) == .Legend && first_legend(f, p) == child { child = p; continue }
				return true
			}
			child = p
		}
	}
	return false
}

@(private)
first_legend :: proc(f: ^Forms, fieldset: base.Handle) -> base.Handle {
	n := dom.get(f.doc, fieldset)
	if n == nil { return base.NIL_HANDLE }
	for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(f.doc, ch).next {
		if kind(f, ch) == .Legend { return ch }
	}
	return base.NIL_HANDLE
}

is_readonly :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	#partial switch kind_of(n) {
	case .Input: return input_type_of(n) in READONLY_APPLIES && has_attr(n, "readonly")
	case .Textarea: return has_attr(n, "readonly")
	}
	return false
}

// Mutable: the user may change the value (not disabled, not read-only).
is_mutable :: proc(f: ^Forms, h: base.Handle) -> bool { return !is_disabled(f, h) && !is_readonly(f, h) }

@(private)
in_datalist :: proc(f: ^Forms, h: base.Handle) -> bool {
	for p := parent_element(f, h); p != base.NIL_HANDLE; p = parent_element(f, p) { if kind(f, p) == .Datalist { return true } }
	return false
}

// Barred from constraint validation (§4.10.20.1 and the per-type rules).
is_barred :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	k := kind_of(n)
	if !is_submittable(k) { return true }
	if is_disabled(f, h) || in_datalist(f, h) { return true }
	#partial switch k {
	case .Input:
		t := input_type_of(n)
		if t == .Hidden || t == .Reset || t == .Button { return true }
		if t in READONLY_APPLIES && has_attr(n, "readonly") { return true }
	case .Button:
		if button_type_of(n) != .Submit { return true }
	case .Textarea:
		if has_attr(n, "readonly") { return true }
	}
	return false
}

will_validate :: proc(f: ^Forms, h: base.Handle) -> bool { return !is_barred(f, h) }

// Elements in tree order under `root` (iterative).
@(private)
walk_elements :: proc(f: ^Forms, root: base.Handle, out: ^[dynamic]base.Handle) {
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, root)
	for len(stack) > 0 {
		cur := pop(&stack)
		n := dom.get(f.doc, cur)
		if n == nil { continue }
		if n.kind == .Element && cur != root { append(out, cur) }
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(f.doc, ch).prev { append(&stack, ch) }
	}
}

// form.elements: listed elements owned by `form`, tree order, image buttons excluded. Owned elements may live anywhere in
// the form's tree (the `form` attribute), so the whole tree is walked.
form_elements :: proc(f: ^Forms, form: base.Handle, allocator := context.temp_allocator) -> []base.Handle {
	out := make([dynamic]base.Handle, allocator)
	if kind(f, form) != .Form { return out[:] }
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, tree_root(f, form), &all)
	for h in all {
		n := element(f, h)
		k := kind_of(n)
		if !is_listed(k) { continue }
		if k == .Input && input_type_of(n) == .Image { continue }
		if form_owner(f, h) == form { append(&out, h) }
	}
	return out[:]
}

// Submittable elements owned by `form`, tree order, image buttons included (the form data set walks these).
@(private)
form_submittables :: proc(f: ^Forms, form: base.Handle) -> []base.Handle {
	out := make([dynamic]base.Handle, context.temp_allocator)
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, tree_root(f, form), &all)
	for h in all {
		if is_submittable(kind(f, h)) && form_owner(f, h) == form { append(&out, h) }
	}
	return out[:]
}

// Fieldset.elements: listed descendants.
fieldset_elements :: proc(f: ^Forms, fs: base.Handle, allocator := context.temp_allocator) -> []base.Handle {
	out := make([dynamic]base.Handle, allocator)
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, fs, &all)
	for h in all { if is_listed(kind(f, h)) { append(&out, h) } }
	return out[:]
}

// The default button of a form: its first submit button in tree order.
default_button :: proc(f: ^Forms, form: base.Handle) -> base.Handle {
	for h in form_submittables(f, form) { if is_submit_button(f, h) { return h } }
	return base.NIL_HANDLE
}

@(private)
radio_name :: proc(n: ^dom.Node) -> string {
	v, _ := attr(n, "name")
	return v
}

// The other radios of `h`'s group: same tree, same form owner, same non-empty name (§4.10.5.1.18). Includes h.
radio_group :: proc(f: ^Forms, h: base.Handle) -> []base.Handle {
	n := element(f, h)
	name := radio_name(n)
	if kind_of(n) != .Input || input_type_of(n) != .Radio || name == "" { return nil }
	if !f.radio_cache_valid || f.radio_cache_at != f.doc.mutations { build_radio_cache(f) }
	owner := form_owner(f, h)
	root := tree_root(f, h)
	if root == f.doc.root {
		if list, ok := f.radio_cache[Radio_Key{owner, name}]; ok { return list[:] }
		return nil
	}
	// detached subtree: not cached
	out := make([dynamic]base.Handle, context.temp_allocator)
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, root, &all)
	for o in all {
		on := element(f, o)
		if kind_of(on) == .Input && input_type_of(on) == .Radio && radio_name(on) == name && form_owner(f, o) == owner { append(&out, o) }
	}
	return out[:]
}

@(private)
build_radio_cache :: proc(f: ^Forms) {
	clear_radio_cache(f)
	f.radio_cache_valid = true
	f.radio_cache_at = f.doc.mutations
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, f.doc.root, &all)
	for h in all {
		n := element(f, h)
		if kind_of(n) != .Input || input_type_of(n) != .Radio { continue }
		name := radio_name(n)
		if name == "" { continue }
		key := Radio_Key{form_owner(f, h), name}
		if _, ok := f.radio_cache[key]; !ok {
			key.name = strings.clone(name)
			f.radio_cache[key] = make([dynamic]base.Handle)
		}
		append(&f.radio_cache[key], h)
	}
}

// The labeled control of a <label> (§4.10.4): the element named by `for` if labelable, else the first labelable
// descendant.
labeled_control :: proc(f: ^Forms, label: base.Handle) -> base.Handle {
	n := element(f, label)
	if kind_of(n) != .Label { return base.NIL_HANDLE }
	if id, ok := attr(n, "for"); ok {
		t := find_id_in_tree(f, tree_root(f, label), id)
		return is_labelable(f, t) ? t : base.NIL_HANDLE
	}
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, label, &all)
	for h in all { if is_labelable(f, h) { return h } }
	return base.NIL_HANDLE
}

// The nearest ancestor-or-self <label>.
enclosing_label :: proc(f: ^Forms, h: base.Handle) -> base.Handle {
	for cur := h; cur != base.NIL_HANDLE; cur = parent_element(f, cur) {
		if kind(f, cur) == .Label { return cur }
	}
	return base.NIL_HANDLE
}

// The <select> an option belongs to (parent, or grandparent through an optgroup).
option_select :: proc(f: ^Forms, opt: base.Handle) -> base.Handle {
	p := parent_element(f, opt)
	pk := kind(f, p)
	if pk == .Select { return p }
	if pk == .Optgroup {
		gp := parent_element(f, p)
		if kind(f, gp) == .Select { return gp }
	}
	return base.NIL_HANDLE
}

// The list of options of a select: option children, and option children of optgroup children, tree order.
select_options :: proc(f: ^Forms, sel: base.Handle, allocator := context.temp_allocator) -> []base.Handle {
	out := make([dynamic]base.Handle, allocator)
	n := dom.get(f.doc, sel)
	if n == nil { return out[:] }
	for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(f.doc, ch).next {
		k := kind(f, ch)
		if k == .Option { append(&out, ch) } else if k == .Optgroup {
			cn := dom.get(f.doc, ch)
			for g := cn.first_child; g != base.NIL_HANDLE; g = dom.get(f.doc, g).next {
				if kind(f, g) == .Option { append(&out, g) }
			}
		}
	}
	return out[:]
}

// Focusable areas (§6.6.2): form controls that are not disabled (hidden inputs excluded), links with href, elements
// with a tabindex, summary... Rendering (display: none) is the shell's business.
is_focusable :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	if n == nil { return false }
	switch n.name {
	case "input":
		if input_type_of(n) == .Hidden { return false }
		return !is_disabled(f, h)
	case "button", "select", "textarea": return !is_disabled(f, h)
	case "a", "area": if has_attr(n, "href") { return true }
	case "summary", "iframe": return true
	}
	if _, ok := tabindex(n); ok { return true }
	if ce, ok := attr(n, "contenteditable"); ok && (ce == "" || strings.equal_fold(ce, "true")) { return true }
	return false
}

tabindex :: proc(n: ^dom.Node) -> (int, bool) {
	v, ok := attr(n, "tabindex")
	if !ok { return 0, false }
	s := strings.trim_space(v)
	neg := false
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') { neg = s[0] == '-'; s = s[1:] }
	if len(s) == 0 { return 0, false }
	x := 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' { break }
		x = min(x * 10 + int(c - '0'), 1 << 30)
	}
	if s[0] < '0' || s[0] > '9' { return 0, false }
	return neg ? -x : x, true
}

// Sequential focus navigation order: positive tabindex ascending (tree order within a value), then tabindex 0 / implicit
// in tree order. Elements with a negative tabindex are focusable but not in the order.
// `visible` (optional) filters out what is not rendered.
tab_order :: proc(f: ^Forms, visible: proc(user: rawptr, h: base.Handle) -> bool = nil, user: rawptr = nil) -> []base.Handle {
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, f.doc.root, &all)
	Item :: struct { h: base.Handle, ti: int, order: int }
	items := make([dynamic]Item, context.temp_allocator)
	for h, i in all {
		if !is_focusable(f, h) { continue }
		if visible != nil && !visible(user, h) { continue }
		ti, has := tabindex(element(f, h))
		if !has { ti = 0 }
		if ti < 0 { continue }
		append(&items, Item{h, ti, i})
	}
	// stable: positive tabindex first by value, then the zeros in tree order
	for i in 1 ..< len(items) {
		x := items[i]
		j := i - 1
		less :: proc(a, b: Item) -> bool {
			ka := a.ti > 0 ? a.ti : max(int)
			kb := b.ti > 0 ? b.ti : max(int)
			if ka != kb { return ka < kb }
			return a.order < b.order
		}
		for j >= 0 && less(x, items[j]) { items[j + 1] = items[j]; j -= 1 }
		items[j + 1] = x
	}
	out := make([]base.Handle, len(items), context.temp_allocator)
	for it, i in items { out[i] = it.h }
	return out
}
