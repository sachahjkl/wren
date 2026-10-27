package dom

import "core:testing"
import "wb:base"

@(test)
tree_ops_and_cycles :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	a := create_element(d, "DIV")
	b := create_element(d, "span")
	c := create_text(d, "hi")
	testing.expect_value(t, get(d, a).name, "div")
	testing.expect_value(t, append_child(d, d.root, a), Error.None)
	testing.expect_value(t, append_child(d, a, b), Error.None)
	testing.expect_value(t, append_child(d, b, c), Error.None)
	testing.expect_value(t, append_child(d, b, a), Error.Hierarchy)   // cycle
	testing.expect_value(t, append_child(d, c, b), Error.Hierarchy)   // text has no children
	testing.expect_value(t, append_child(d, d.root, d.root), Error.Hierarchy)
	testing.expect_value(t, text_content(d, a), "hi")

	// move keeps a single parent
	e := create_element(d, "p")
	append_child(d, d.root, e)
	testing.expect_value(t, append_child(d, e, b), Error.None)
	testing.expect_value(t, get(d, a).first_child, base.NIL_HANDLE)
	testing.expect_value(t, get(d, b).parent, e)

	// insert before
	x := create_element(d, "x")
	testing.expect_value(t, insert_before(d, d.root, x, a), Error.None)
	testing.expect_value(t, get(d, d.root).first_child, x)
	testing.expect_value(t, insert_before(d, d.root, x, c), Error.Not_Found)
}

@(test)
xml_element_attribute_case :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	h := create_element(d, "div")
	set_attribute(d, h, "dataFoo", "1")
	testing.expect_value(t, get(d, h).attrs[0].name, "datafoo")
	x := create_element(d, "item")
	get(d, x).xml = .Element
	set_attribute(d, x, "viewBox", "a")
	set_attribute(d, x, "viewbox", "b")
	testing.expect_value(t, len(get(d, x).attrs), 2)
	v, ok := get_attribute_exact(d, x, "viewBox")
	testing.expect(t, ok && v == "a")
	_, ok = get_attribute_exact(d, x, "VIEWBOX")
	testing.expect(t, !ok)
	v, ok = get_attribute(d, x, "VIEWBOX")   // the browser's readers ignore case
	testing.expect(t, ok)
	remove_attribute(d, x, "viewBox")
	testing.expect_value(t, len(get(d, x).attrs), 1)
	testing.expect_value(t, get(d, x).attrs[0].name, "viewbox")
	// document.open() erases every listener of the tree
	append_child(d, d.root, x)
	add_listener(d, x, "click", 1, 1, false, false, false)
	add_listener(d, d.root, "load", 1, 2, false, false, false)
	erase_listeners(d, d.root)
	testing.expect_value(t, len(get(d, x).listeners), 0)
	testing.expect_value(t, len(get(d, d.root).listeners), 0)
}

@(test)
release_invalidates_handles :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	a := create_element(d, "div")
	b := create_element(d, "b")
	append_child(d, a, b)
	testing.expect_value(t, release(d, d.root), Error.Attached)
	append_child(d, d.root, a)
	testing.expect_value(t, release(d, a), Error.Attached)
	remove_child(d, d.root, a)
	testing.expect_value(t, release(d, a), Error.None)
	testing.expect(t, get(d, a) == nil)
	testing.expect(t, get(d, b) == nil, "descendants die with the subtree")
	testing.expect_value(t, d.nodes.count, 1)   // only the Document node is left
}

@(test)
deep_tree_does_not_overflow_the_stack :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	cur := d.root
	for _ in 0 ..< 200_000 {
		n := create_element(d, "div")
		append_child(d, cur, n)
		cur = n
	}
	set_text_content(d, d.root, "")   // destroys 200k nested nodes iteratively
	testing.expect_value(t, d.nodes.count, 1)
}

@(test)
attributes_are_case_insensitive_and_owned :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	a := create_element(d, "div")
	set_attribute(d, a, "ID", "main")
	v, ok := get_attribute(d, a, "id")
	testing.expect(t, ok)
	testing.expect_value(t, v, "main")
	set_attribute(d, a, "id", "other")
	v, _ = get_attribute(d, a, "Id")
	testing.expect_value(t, v, "other")
	testing.expect_value(t, len(get(d, a).attrs), 1)
	append_child(d, d.root, a)
	testing.expect_value(t, find_by_id(d, "other"), a)
	remove_attribute(d, a, "id")
	testing.expect_value(t, find_by_id(d, "other"), base.NIL_HANDLE)
}

@(private = "file")
Trace :: struct { log: [dynamic]string, d: ^Document, dp: ^Dispatcher, on_a: proc(tr: ^Trace, ev: base.Handle) }

@(private = "file")
invoke :: proc(user: rawptr, l: Listener, eh: base.Handle) -> bool {
	tr := (^Trace)(user)
	e := base.pool_get(&tr.dp.events, eh)
	n := get(tr.d, e.current_target)
	label := n.name
	switch l.user {
	case 1: label = "capture:" 
	case 2: label = "bubble:"
	case 3: label = "stop:"
	case 4: label = "prevent:"
	}
	append(&tr.log, label)
	append(&tr.log, n.name)
	if l.user == 3 { e.stop = true }
	if l.user == 4 { e.default_prevented = true }
	return true
}

@(test)
dispatch_phases_stop_and_prevent :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	dp: Dispatcher
	defer dispatcher_destroy(&dp)
	tr := Trace{d = d, dp = &dp}
	defer delete(tr.log)
	dp.invoke = invoke
	dp.user = &tr

	outer := create_element(d, "outer")
	inner := create_element(d, "inner")
	append_child(d, d.root, outer)
	append_child(d, outer, inner)
	add_listener(d, outer, "click", 1, 1, true, false, false)    // capture on outer
	add_listener(d, outer, "click", 2, 2, false, false, false)   // bubble on outer
	add_listener(d, inner, "click", 2, 2, false, false, false)

	ok := dispatch(d, &dp, inner, Event{type = "click", bubbles = true, cancelable = true})
	testing.expect(t, ok)
	want := []string{"capture:", "outer", "bubble:", "inner", "bubble:", "outer"}
	testing.expect_value(t, len(tr.log), len(want))
	for w, i in want { if i < len(tr.log) { testing.expect_value(t, tr.log[i], w) } }
	testing.expect_value(t, dp.events.count, 0)   // the transient event is gone

	// stopPropagation at the target prevents the bubble phase
	clear(&tr.log)
	add_listener(d, inner, "tap", 3, 3, false, false, false)
	add_listener(d, outer, "tap", 2, 2, false, false, false)
	dispatch(d, &dp, inner, Event{type = "tap", bubbles = true})
	testing.expect_value(t, len(tr.log), 2)

	// preventDefault on a cancelable event
	add_listener(d, inner, "submit", 4, 4, false, false, false)
	testing.expect(t, !dispatch(d, &dp, inner, Event{type = "submit", bubbles = true, cancelable = true}))
	testing.expect(t, dispatch(d, &dp, inner, Event{type = "submit", bubbles = true, cancelable = false}))
}

@(test)
once_and_removal_during_dispatch :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	dp: Dispatcher
	defer dispatcher_destroy(&dp)
	tr := Trace{d = d, dp = &dp}
	defer delete(tr.log)
	dp.invoke = invoke
	dp.user = &tr
	n := create_element(d, "n")
	append_child(d, d.root, n)
	add_listener(d, n, "go", 2, 2, false, true, false)   // once
	dispatch(d, &dp, n, Event{type = "go"})
	dispatch(d, &dp, n, Event{type = "go"})
	testing.expect_value(t, len(tr.log), 2)   // ran a single time
	id, _ := add_listener(d, n, "go", 9, 2, false, false, false)
	testing.expect_value(t, remove_listener(d, n, id), Error.None)
	testing.expect_value(t, remove_listener(d, n, id), Error.Not_Found)
}

@(test)
document_scope_frees_everything :: proc(t: ^testing.T) {
	scope := base.scope_make("doc")
	d := document_create(scope)
	for _ in 0 ..< 1000 {
		e := create_element(d, "div")
		set_attribute(d, e, "class", "x")
		add_listener(d, e, "click", 1, 1, false, false, false)
		append_child(d, d.root, e)
	}
	base.scope_close(scope)   // the test allocator reports any leak
}

// Listeners added and removed in a loop on a node that never sees an event: the list stays small (its tombstones
// were only dropped at the end of a dispatch at the node).
@(test)
listener_churn_is_bounded :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	a := create_element(d, "div")
	keep, _ := add_listener(d, a, "click", 1, 0, false, false, false)
	_ = keep
	for i in 0 ..< 100_000 {
		id, err := add_listener(d, a, "click", 2, u32(i), false, false, false)
		testing.expect_value(t, err, Error.None)
		remove_listener(d, a, id)
	}
	testing.expectf(t, len(get(d, a).listeners) <= 4, "%d listener entries", len(get(d, a).listeners))
}
// Templates nested in templates' contents and clonable shadow hosts nested in shadow trees, as deep as a script makes
// them: cloning walks them with its own stack (it recursed once per level and overflowed the native stack).
@(test)
deep_clone_is_iterative :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	N :: 50_000
	top := create_element(d, "template")
	cur := top
	for _ in 0 ..< N {
		next := create_element(d, "template")
		append_child(d, template_content(d, cur), next)
		cur = next
	}
	copy := clone_node(d, top, true)
	depth := 0
	for x := copy; x != base.NIL_HANDLE; depth += 1 {
		c, ok := d.templates[x]
		if !ok { break }
		x = get(d, c).first_child
	}
	testing.expect_value(t, depth, N)
	host := create_element(d, "div")
	h := host
	for _ in 0 ..< N / 5 {
		r, err := attach_shadow(d, h, {mode = .Open, clonable = true})
		if err != .None { break }
		inner := create_element(d, "div")
		append_child(d, r, inner)
		h = inner
	}
	hc := clone_node(d, host, false)
	levels := 0
	for x := hc; x != base.NIL_HANDLE; levels += 1 {
		s := get(d, x).shadow
		if s == base.NIL_HANDLE { break }
		x = get(d, s).first_child
	}
	testing.expect_value(t, levels, N / 5)
}