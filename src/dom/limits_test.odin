package dom

import "core:fmt"
import "core:testing"
import "wb:base"

// Each atom's name is its identifier, and looking the name up gives the atom back.
@(test)
event_atoms_name_their_types :: proc(t: ^testing.T) {
	for info, atom in EVENT_TYPES {
		if atom == .None { continue }
		testing.expect_value(t, info.name, fmt.tprint(atom))
		testing.expect_value(t, event_atom(info.name), atom)
	}
	testing.expect_value(t, event_atom("my-event"), Event_Atom.None)
	testing.expect_value(t, event_atom(""), Event_Atom.None)
	testing.expect(t, ui_composed("click") && ui_composed("paste") && !ui_composed("load") && !ui_composed("mouseenter"))
	testing.expect_value(t, legacy_event_type("transitionend"), "webkitTransitionEnd")
	testing.expect_value(t, legacy_event_type("click"), "")
}

@(private = "file")
Hook_Log :: struct {
	seen:    [dynamic]base.Handle,
	trigger: base.Handle,   // its insertion hook inserts `extra` under `parent` in a muted section of its own
	extra:   base.Handle,
	parent:  base.Handle,
	removed: int,           // removal calls for a node
	settled: int,           // calls at the end of a muted batch
}

// A batch of insertions is reported in order once unmuted; a hook that runs a muted operation of its own has it
// reported before the rest of the batch; removals in a batch ask for one check at its end.
@(test)
unmute_reports_a_batch_in_order :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	log: Hook_Log
	defer delete(log.seen)
	hooks_set(d, Hooks{
		user = &log,
		inserted = proc(user: rawptr, d: ^Document, node: base.Handle) {
			l := (^Hook_Log)(user)
			append(&l.seen, node)
			if node == l.trigger {
				hooks_mute(d)
				append_child(d, l.parent, l.extra)
				hooks_unmute(d)
			}
		},
		removed = proc(user: rawptr, d: ^Document, node, parent: base.Handle) {
			l := (^Hook_Log)(user)
			if node == base.NIL_HANDLE { l.settled += 1 } else { l.removed += 1 }
		},
	})
	N :: 5000
	log.parent = create_element(d, "div")
	append_child(d, d.root, log.parent)
	clear(&log.seen)
	kids := make([]base.Handle, N, context.temp_allocator)
	for i in 0 ..< N { kids[i] = create_element(d, "span") }
	log.trigger, log.extra = kids[0], create_element(d, "b")
	hooks_mute(d)
	for k in kids { append_child(d, log.parent, k) }
	testing.expect_value(t, len(log.seen), 0)
	hooks_unmute(d)
	testing.expect_value(t, len(log.seen), N + 1)
	if len(log.seen) == N + 1 {
		testing.expect_value(t, log.seen[0], kids[0])
		testing.expect_value(t, log.seen[1], log.extra)
		for i in 1 ..< N { testing.expect_value(t, log.seen[i + 1], kids[i]) }
	}

	hooks_mute(d)
	for i in 0 ..< 10 { remove_child(d, log.parent, kids[i]) }
	testing.expect_value(t, log.removed, 10)
	testing.expect_value(t, log.settled, 0)
	hooks_unmute(d)
	testing.expect_value(t, log.settled, 1)
	remove_child(d, log.parent, kids[10])   // not muted: no batch end
	testing.expect_value(t, log.removed, 11)
	testing.expect_value(t, log.settled, 1)
}

// What scripts build is refused past the document's limits, and a refused write changes nothing.
@(test)
limits_refuse_what_scripts_build :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	limits_set(d, Limits{max_nodes = 10, max_bytes = 100, max_listeners = 2})
	e := create_element(d, "div")
	testing.expect_value(t, set_attribute(d, e, "title", string(make([]u8, 200, context.temp_allocator))), Error.Quota)
	testing.expect_value(t, len(get(d, e).attrs), 0)
	testing.expect_value(t, set_attribute(d, e, "class", "abc"), Error.None)
	testing.expect(t, get(d, e).attrs[0].name_static)   // "class" is the program's string
	testing.expect_value(t, d.bytes, 3)
	tx := create_text(d, "hi")
	testing.expect_value(t, set_data(d, tx, string(make([]u8, 200, context.temp_allocator))), Error.Quota)
	testing.expect_value(t, get(d, tx).text, "hi")

	a, err := add_listener(d, e, "click", 1, 1, false, false, false)
	testing.expect_value(t, err, Error.None)
	_, err = add_listener(d, e, "my-event", 1, 1, false, false, false)
	testing.expect_value(t, err, Error.None)
	_, err = add_listener(d, e, "keydown", 1, 1, false, false, false)
	testing.expect_value(t, err, Error.Quota)
	again, err2 := add_listener(d, e, "click", 1, 1, false, false, false)   // the same listener: no new one
	testing.expect_value(t, err2, Error.None)
	testing.expect_value(t, again, a)

	testing.expect_value(t, append_child(d, d.root, e), Error.None)
	for _ in 0 ..< 10 { create_text(d, "") }
	x := create_element(d, "p")
	testing.expect_value(t, append_child(d, d.root, x), Error.Quota)
	testing.expect_value(t, insert_before(d, d.root, e, base.NIL_HANDLE), Error.None)   // a move is still allowed
}

// The byte account follows every string a node gets and gives back.
@(test)
byte_account_returns_to_zero :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	e := create_element(d, "custom-element-name")
	set_attribute(d, e, "data-x", "hello")
	set_attribute(d, e, "id", "z")
	tx := create_text(d, "abc")
	append_child(d, e, tx)
	set_data(d, tx, "abcdef")
	set_attribute(d, e, "data-x", "hi")
	set_attribute_ns(d, e, ATTR_NS_XLINK, "xlink:href", "#a")
	testing.expect_value(t, d.bytes, len("custom-element-name") + len("data-x") + len("hi") + len("z") + len("abcdef") + len("#a"))
	remove_attribute(d, e, "id")
	c := clone_node(d, e, true)
	testing.expect_value(t, release(d, c), Error.None)
	testing.expect_value(t, release(d, e), Error.None)
	testing.expect_value(t, d.bytes, 0)
}

// The document counts its listeners by type: `listens` follows additions, removals, erasure and freed nodes.
@(test)
listened_types_are_counted :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	a := create_element(d, "div")
	b := create_element(d, "div")
	append_child(d, d.root, a)
	id, _ := add_listener(d, a, "click", 1, 1, false, false, false)
	add_listener(d, a, "click", 2, 1, false, false, false)
	add_listener(d, b, "my-event", 1, 1, false, false, false)
	testing.expect(t, listens(d, "click") && listens(d, "my-event") && !listens(d, "keydown") && !listens(d, "other"))
	remove_listener(d, a, id)
	testing.expect(t, listens(d, "click"))
	erase_listeners(d, d.root)
	testing.expect(t, !listens(d, "click"))
	testing.expect_value(t, release(d, b), Error.None)
	testing.expect(t, !listens(d, "my-event"))
	testing.expect_value(t, len(d.listened_others), 0)
}

@(private = "file")
Path_Count :: struct { ran: int }

// The event path of a deep tree is built by carrying the roots along (it looked them up again at each ancestor); a
// composed event leaves a shadow tree, an event that is not stays in it.
@(test)
deep_and_shadow_event_paths :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	dp: Dispatcher
	defer dispatcher_destroy(&dp)
	count: Path_Count
	dp.user = &count
	dp.invoke = proc(user: rawptr, l: Listener, event: base.Handle) -> bool { (^Path_Count)(user).ran += 1; return true }
	N :: 20_000
	cur := d.root
	for _ in 0 ..< N {
		e := create_element(d, "div")
		append_child(d, cur, e)
		cur = e
	}
	add_listener(d, d.root, "go", 1, 1, true, false, false)
	add_listener(d, cur, "go", 1, 2, false, false, false)
	dispatch(d, &dp, cur, Event{type = "go", bubbles = true})
	testing.expect_value(t, count.ran, 2)

	host := create_element(d, "div")
	append_child(d, d.root, host)
	root, err := attach_shadow(d, host, {mode = .Open})
	testing.expect_value(t, err, Error.None)
	inner := create_element(d, "span")
	append_child(d, root, inner)
	add_listener(d, host, "tap", 1, 3, false, false, false)
	add_listener(d, d.root, "tap", 1, 4, false, false, false)
	count.ran = 0
	dispatch(d, &dp, inner, Event{type = "tap", bubbles = true, composed = true, untrusted = true})
	testing.expect_value(t, count.ran, 2)
	count.ran = 0
	dispatch(d, &dp, inner, Event{type = "tap", bubbles = true, untrusted = true})
	testing.expect_value(t, count.ran, 0)
}

// A watched parent's children and a watched attribute name have counters of their own: other changes leave them.
@(test)
child_and_attribute_watches :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	p := create_element(d, "ul")
	q := create_element(d, "ol")
	append_child(d, d.root, p)
	append_child(d, d.root, q)
	child_watch(d, p)
	attr_watch(d, "class")
	v, a := child_version(d, p), attr_name_version(d, "class")
	li := create_element(d, "li")
	append_child(d, q, li)
	set_attribute(d, q, "title", "x")
	testing.expect_value(t, child_version(d, p), v)
	testing.expect_value(t, attr_name_version(d, "class"), a)
	append_child(d, p, li)   // a move: out of q, into p
	testing.expect(t, child_version(d, p) != v)
	set_attribute(d, li, "class", "on")
	testing.expect(t, attr_name_version(d, "class") != a)
	child_unwatch(d, p)
	attr_unwatch(d, "class")
	testing.expect_value(t, len(d.child_versions), 0)
	testing.expect_value(t, len(d.attr_versions), 0)
}
