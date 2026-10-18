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
