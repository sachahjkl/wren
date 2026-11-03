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

// A node inserted under a document of its own becomes its, shadow tree included; removed, it stays its; a clone keeps
// its original's; inserted in the page's document, it is the page's again.
@(test)
node_document_follows_insertion :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	own := create_fragment(d)
	get(d, own).as_document = true
	host := create_element(d, "div")
	inner := create_element(d, "span")
	append_child(d, host, inner)
	root, err := attach_shadow(d, host, {mode = .Open})
	testing.expect_value(t, err, Error.None)
	in_shadow := create_text(d, "x")
	append_child(d, root, in_shadow)

	testing.expect_value(t, append_child(d, own, host), Error.None)
	for h in ([]base.Handle{host, inner, root, in_shadow}) { testing.expect_value(t, get(d, h).doc, own) }
	remove_child(d, host, inner)
	testing.expect_value(t, get(d, inner).doc, own)
	testing.expect_value(t, get(d, clone_node(d, inner, false)).doc, own)
	append_child(d, d.root, inner)
	testing.expect_value(t, get(d, inner).doc, base.NIL_HANDLE)
}

@(test)
xml_element_attribute_case :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	h := create_element(d, "div")
	set_attribute(d, h, "dataFoo", "1")
	testing.expect_value(t, get(d, h).attrs[0].name, "datafoo")
	// an element of no HTML or SVG namespace: its attributes' names as given; setAttributeNS's too (exact)
	o := create_element_ns(d, "foo", .Other, "urn:x")
	set_attribute(d, o, "A", "1")
	set_attribute(d, h, "P:Abc", "2", exact = true)
	testing.expect_value(t, get(d, o).attrs[0].name, "A")
	v0, ok0 := get_attribute_exact(d, o, "A")
	testing.expect(t, ok0 && v0 == "1")
	testing.expect_value(t, get(d, h).attrs[1].name, "P:Abc")
	_, ok0 = get_attribute_exact(d, h, "p:abc")
	testing.expect(t, !ok0)
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

// The document lists the <img> and <input> elements it makes, created in any case or cloned, and no other; a list that
// fills up drops the freed ones before it grows.
@(test)
document_lists_its_image_elements :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	div := create_element(d, "div")
	img := create_element(d, "IMG")
	input := create_element(d, "input")
	append_child(d, div, img)
	copy := clone_node(d, div, true)
	testing.expect_value(t, len(d.images), 3)
	testing.expect(t, len(d.images) == 3 && d.images[0] == img && d.images[1] == input && get(d, d.images[2]).parent == copy)
	testing.expect_value(t, release(d, copy), Error.None)
	for len(d.images) < cap(d.images) { create_element(d, "img") }
	full := len(d.images)
	create_element(d, "input")
	testing.expect_value(t, len(d.images), full)   // (the freed clone's dropped, the new one appended)
	for h in d.images { testing.expect(t, get(d, h) != nil, "only live elements") }
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

// A listener moves the node to another document under a new handle (Frame_adoptNode): the event goes on through it there, with the
// listeners that went with it, invoked by that document's dispatcher.
@(private = "file") MOVED_TAG_FROM :: 1
@(private = "file") MOVED_TAG_TO :: 2
@(private = "file") MOVED_FIRST :: 1    // the listener that moves the node
@(private = "file") MOVED_SECOND :: 2

@(private = "file")
Moved_Trace :: struct {
	from, to:       ^Document,
	from_dp, to_dp: ^Dispatcher,
	node:           base.Handle,
	by_from, by_to: [dynamic]u32,   // the callbacks each dispatcher invoked
}

@(test)
event_follows_a_node_moved_to_another_document :: proc(t: ^testing.T) {
	from := document_create(nil, MOVED_TAG_FROM)
	defer document_destroy(from)
	to := document_create(nil, MOVED_TAG_TO)
	defer document_destroy(to)
	from_dp, to_dp: Dispatcher
	defer dispatcher_destroy(&from_dp)
	defer dispatcher_destroy(&to_dp)
	from_dp.tag, to_dp.tag = MOVED_TAG_FROM, MOVED_TAG_TO
	n := create_element(from, "n")
	append_child(from, from.root, n)
	tr := Moved_Trace{from = from, to = to, from_dp = &from_dp, to_dp = &to_dp, node = n}
	defer { delete(tr.by_from); delete(tr.by_to) }
	from_dp.user = &tr
	to_dp.user = &tr
	from_dp.other = proc(user: rawptr, node: base.Handle) -> (^Document, ^Dispatcher) {
		x := (^Moved_Trace)(user)
		return x.to, x.to_dp
	}
	to_dp.invoke = proc(user: rawptr, l: Listener, event: base.Handle) -> bool {
		append(&(^Moved_Trace)(user).by_to, l.callback)
		return true
	}
	from_dp.invoke = proc(user: rawptr, l: Listener, event: base.Handle) -> bool {
		x := (^Moved_Trace)(user)
		append(&x.by_from, l.callback)
		moved := create_element(x.to, "n")
		append_child(x.to, x.to.root, moved)
		for cur in get(x.from, x.node).listeners { if !cur.removed { listener_copy(x.to, moved, cur, cur.owner) } }
		event_path_moved(x.from_dp, x.node, moved)
		detach(x.from, x.node)
		destroy_unpinned(x.from, x.node)
		return true
	}
	add_listener(from, n, "go", MOVED_FIRST, 0, false, false, false)
	add_listener(from, n, "go", MOVED_SECOND, 0, false, false, false)
	dispatch(from, &from_dp, n, Event{type = "go"})
	testing.expect_value(t, len(tr.by_from), 1)
	testing.expect_value(t, len(tr.by_to), 1)
	if len(tr.by_to) == 1 { testing.expect_value(t, tr.by_to[0], u32(MOVED_SECOND)) }
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

// A known element name is the program's string (no copy to make or free), any other a copy of the element's own; the
// test runner's allocator reports a static name freed or a copied one leaked.
@(test)
element_names_static_or_copied :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	li := create_element(d, "LI")
	odd := create_element(d, "x-Item")
	long := create_element(d, "blockquotes")
	testing.expect_value(t, get(d, li).name, "li")
	testing.expect(t, get(d, li).name_static && raw_data(get(d, li).name) == raw_data(static_name("li")), "li is the program's string")
	testing.expect_value(t, get(d, odd).name, "x-item")
	testing.expect(t, !get(d, odd).name_static && !get(d, long).name_static, "other names are copies")
	append_child(d, li, odd)
	copy := clone_node(d, li, true)
	testing.expect(t, raw_data(get(d, copy).name) == raw_data(get(d, li).name), "a clone shares the static name")
	set_name(get(d, li), "Svg")   // (an XML element keeps its case: a copy)
	testing.expect(t, get(d, li).name == "Svg" && !get(d, li).name_static, "renamed to a copy")
	set_name(get(d, odd), "span")
	testing.expect(t, get(d, odd).name_static, "renamed to a static name")
	append_child(d, d.root, li)
	append_child(d, d.root, copy)
	append_child(d, d.root, long)
}

// An attribute of a namespace is not the browser's: one named style beside the plain style leaves the plain one what the
// browser reads and the hooks hear of, an id of a namespace is no id; setAttribute and getAttribute take the first of a
// qualified name whatever its namespace; the namespace URI is kept once per document.
@(test)
namespaced_attributes_beside_plain_ones :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	heard: [dynamic]string
	defer delete(heard)
	hooks_set(d, Hooks{user = &heard, attribute = proc(user: rawptr, d: ^Document, el: base.Handle, name: string) { append((^[dynamic]string)(user), name) }})
	el := create_element(d, "div")
	append_child(d, d.root, el)
	ns := attr_ns_of(d, "https://example.com/attributes")
	testing.expect_value(t, attr_ns_of(d, "https://example.com/attributes"), ns)
	testing.expect_value(t, attr_ns_of(d, NS_XLINK), ATTR_NS_XLINK)

	set_attribute_ns(d, el, ns, "style", "color: red")
	set_attribute(d, el, "id", "plain")
	set_attribute_ns(d, el, ns, "p:id", "namespaced")
	set_attribute_ns(d, el, ATTR_NS_NONE, "style", "color: green")
	set_attribute_ns(d, el, ns, "style", "color: blue")
	testing.expect_value(t, len(get(d, el).attrs), 4)
	v, _ := get_attribute(d, el, "style")
	testing.expect_value(t, v, "color: green")
	v, _ = get_attribute_ns(d, el, ns, "style")
	testing.expect_value(t, v, "color: blue")
	v, _ = get_attribute_exact(d, el, "style")   // getAttribute: the first of that name
	testing.expect_value(t, v, "color: blue")
	testing.expect_value(t, find_by_id(d, "plain"), el)
	testing.expect_value(t, find_by_id(d, "namespaced"), base.NIL_HANDLE)
	testing.expect_value(t, len(heard), 2)   // id and the plain style only
	testing.expect_value(t, heard[0], "id")
	testing.expect_value(t, heard[1], "style")

	remove_attribute_ns(d, el, ns, "style")
	v, _ = get_attribute_exact(d, el, "style")
	testing.expect_value(t, v, "color: green")
	testing.expect_value(t, len(heard), 2)
	testing.expect_value(t, attribute_index(get(d, el), "p:id"), 1)
	testing.expect_value(t, attr_local(get(d, el).attrs[1]), "id")
	testing.expect_value(t, attr_prefix(get(d, el).attrs[1]), "p")
}