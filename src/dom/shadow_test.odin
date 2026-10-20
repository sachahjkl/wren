package dom

import "core:testing"
import "wb:base"

@(private = "file")
el :: proc(d: ^Document, parent: base.Handle, tag: string, attrs: ..[2]string) -> base.Handle {
	h := create_element(d, tag)
	for a in attrs { set_attribute(d, h, a[0], a[1]) }
	append_child(d, parent, h)
	return h
}

@(private = "file")
flat_children :: proc(d: ^Document, h: base.Handle) -> []base.Handle {
	out := make([dynamic]base.Handle, context.temp_allocator)
	for c := flat_first_child(d, h); c != base.NIL_HANDLE; c = flat_next(d, c) { append(&out, c) }
	// the same list backwards
	k := len(out)
	for c := flat_last_child(d, h); c != base.NIL_HANDLE; c = flat_prev(d, c) { k -= 1; if k < 0 || out[k] != c { return nil } }
	return out[:]
}

@(test)
shadow_attach_and_hosts :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	body := el(d, d.root, "body")
	div := el(d, body, "div")
	img := el(d, body, "img")
	custom := el(d, body, "my-widget")
	bad := el(d, body, "font-face")
	_, e1 := attach_shadow(d, img, {})
	testing.expect_value(t, e1, Error.Not_Supported)
	_, e2 := attach_shadow(d, bad, {})
	testing.expect_value(t, e2, Error.Not_Supported)
	root, e3 := attach_shadow(d, div, {mode = .Open})
	testing.expect_value(t, e3, Error.None)
	testing.expect_value(t, shadow_root_of(d, div), root)
	testing.expect_value(t, host_of(d, root), div)
	_, e4 := attach_shadow(d, div, {mode = .Open})
	testing.expect_value(t, e4, Error.Not_Supported)
	_, e5 := attach_shadow(d, custom, {mode = .Closed})
	testing.expect_value(t, e5, Error.None)

	inner := el(d, root, "span")
	testing.expect(t, is_connected(d, inner))
	testing.expect_value(t, tree_root(d, inner), root)
	testing.expect_value(t, root_node(d, inner, true), d.root)
	testing.expect(t, !is_ancestor_or_self(d, div, inner))   // the shadow tree is not the host's subtree
	testing.expect(t, shadow_including_ancestor(d, div, inner))
	// a host may not go into its own shadow tree
	testing.expect_value(t, append_child(d, inner, div), Error.Hierarchy)
	// pins of the shadow tree hold the host
	pin(d, inner)
	detach(d, div)
	destroy_unpinned(d, div)
	testing.expect(t, get(d, div) != nil)
	testing.expect(t, !is_connected(d, inner))
	r := unpin(d, inner)
	testing.expect_value(t, r, div)
	testing.expect(t, get(d, div) == nil && get(d, root) == nil && get(d, inner) == nil)
	testing.expect_value(t, len(d.shadow_roots), 1)
}

@(test)
shadow_slots_named_and_flat_tree :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	host := el(d, d.root, "div")
	a := el(d, host, "p", {"slot", "a"})
	txt := create_text(d, "text")
	append_child(d, host, txt)
	b := el(d, host, "p")
	root, _ := attach_shadow(d, host, {mode = .Open})
	changed := make([dynamic]base.Handle, context.temp_allocator)
	d.slot_user = &changed
	d.slot_changed = proc(user: rawptr, d: ^Document, s: base.Handle) { append((^[dynamic]base.Handle)(user), s) }

	header := el(d, root, "header")
	sa := el(d, header, "slot", {"name", "a"})
	sd := el(d, root, "slot")
	fallback := el(d, sd, "i")
	testing.expect_value(t, len(assigned_nodes_raw(d, sa)), 1)
	testing.expect_value(t, assigned_slot(d, a), sa)
	dflt := assigned_nodes_raw(d, sd)
	testing.expect_value(t, len(dflt), 2)
	testing.expect(t, len(dflt) == 2 && dflt[0] == txt && dflt[1] == b)
	testing.expect(t, len(changed) >= 2)

	// the flat tree: host -> header, slot; slot -> its assigned nodes (fallback hidden)
	fc := flat_children(d, host)
	testing.expect(t, len(fc) == 2 && fc[0] == header && fc[1] == sd)
	sc := flat_children(d, sd)
	testing.expect(t, len(sc) == 2 && sc[0] == txt && sc[1] == b)
	testing.expect_value(t, flat_parent(d, b), sd)
	testing.expect_value(t, flat_parent(d, header), host)
	testing.expect_value(t, flat_parent(d, fallback), base.NIL_HANDLE)
	testing.expect(t, in_flat_tree(d, a))

	// renaming moves nodes between slots
	clear(&changed)
	set_attribute(d, a, "slot", "zzz")
	testing.expect_value(t, assigned_slot(d, a), base.NIL_HANDLE)
	testing.expect_value(t, len(assigned_nodes_raw(d, sa)), 0)
	testing.expect(t, !in_flat_tree(d, a))
	testing.expect_value(t, len(flat_children(d, sa)), 0)
	set_attribute(d, sd, "name", "zzz")
	testing.expect_value(t, assigned_slot(d, a), sd)
	testing.expect_value(t, assigned_slot(d, b), base.NIL_HANDLE)

	// removing a slot unassigns its nodes; inserting one earlier in tree order takes them
	detach(d, sd)
	testing.expect_value(t, assigned_slot(d, a), base.NIL_HANDLE)
	first := create_element(d, "slot")
	set_attribute(d, first, "name", "zzz")
	insert_before(d, root, first, header)
	testing.expect_value(t, assigned_slot(d, a), first)

	// flatten: a slot inside a nested shadow tree that gets an outer slot
	inner_host := el(d, root, "div")
	inner_root, _ := attach_shadow(d, inner_host, {mode = .Open})
	fwd := el(d, inner_host, "slot", {"name", "f"})   // light child of inner_host, a slot of root's tree
	set_attribute(d, a, "slot", "f")
	inner_slot := el(d, inner_root, "slot")
	testing.expect_value(t, assigned_slot(d, fwd), inner_slot)
	flat := assigned_nodes(d, inner_slot, true)
	testing.expect(t, len(flat) == 1 && flat[0] == a)
	journal_enable(d, 64)
	_ = journal_since
}

@(test)
shadow_manual_assignment :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	host := el(d, d.root, "div")
	a := el(d, host, "span")
	b := el(d, host, "span")
	root, _ := attach_shadow(d, host, {mode = .Open, slot_assignment = .Manual})
	s1 := el(d, root, "slot")
	s2 := el(d, root, "slot")
	testing.expect_value(t, len(assigned_nodes_raw(d, s1)), 0)   // manual: nothing until assign()
	slot_assign(d, s1, {b, a, b})
	l := assigned_nodes_raw(d, s1)
	testing.expect(t, len(l) == 2 && l[0] == b && l[1] == a)
	slot_assign(d, s2, {a})
	testing.expect_value(t, assigned_slot(d, a), s2)
	testing.expect_value(t, len(assigned_nodes_raw(d, s1)), 1)
	detach(d, b)
	testing.expect_value(t, len(assigned_nodes_raw(d, s1)), 0)
}

@(test)
shadow_event_path :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	host := el(d, d.root, "div")
	light := el(d, host, "b")
	root, _ := attach_shadow(d, host, {mode = .Closed})
	wrap := el(d, root, "span")
	slot := el(d, wrap, "slot")
	inner := el(d, root, "i")
	_ = slot

	Seen :: struct { node, target: base.Handle, phase: Phase, path_len: int }
	Ctx :: struct { d: ^Document, dp: ^Dispatcher, seen: [dynamic]Seen }
	ctx: Ctx
	ctx.d = d
	ctx.seen = make([dynamic]Seen, context.temp_allocator)
	dp := Dispatcher{user = &ctx}
	defer dispatcher_destroy(&dp)
	ctx.dp = &dp
	dp.invoke = proc(user: rawptr, l: Listener, eh: base.Handle) -> bool {
		c := (^Ctx)(user)
		e := base.pool_get(&c.dp.events, eh)
		append(&c.seen, Seen{e.current_target, e.target, e.phase, len(composed_path(c.dp, eh))})
		return true
	}
	for h in ([?]base.Handle{d.root, host, root, wrap, slot, inner, light}) { add_listener(d, h, "x", 1, 0, false, false, false) }

	// composed, from inside the closed tree: the document sees the host as target
	_, final := dispatch_ex(d, &dp, inner, Event{type = "x", bubbles = true, composed = true})
	testing.expect_value(t, final, host)
	testing.expect_value(t, len(ctx.seen), 4)   // inner, root, host, document
	if len(ctx.seen) == 4 {
		testing.expect(t, ctx.seen[0].node == inner && ctx.seen[0].target == inner && ctx.seen[0].phase == .At_Target)
		testing.expect(t, ctx.seen[1].node == root && ctx.seen[1].target == inner && ctx.seen[1].phase == .Bubbling)
		testing.expect(t, ctx.seen[2].node == host && ctx.seen[2].target == host && ctx.seen[2].phase == .At_Target)
		testing.expect(t, ctx.seen[3].node == d.root && ctx.seen[3].target == host)
		testing.expect_value(t, ctx.seen[0].path_len, 4)   // inside: the whole path
		testing.expect_value(t, ctx.seen[3].path_len, 2)   // outside a closed tree: host, document
	}
	// not composed: stops at the shadow root
	clear(&ctx.seen)
	dispatch_ex(d, &dp, inner, Event{type = "x", bubbles = true, untrusted = true})
	testing.expect_value(t, len(ctx.seen), 2)

	// a slotted node: its path goes through the slot
	clear(&ctx.seen)
	_, final = dispatch_ex(d, &dp, light, Event{type = "x", bubbles = true, untrusted = true})
	testing.expect_value(t, final, light)
	nodes := make([dynamic]base.Handle, context.temp_allocator)
	for s in ctx.seen { append(&nodes, s.node) }
	want := [?]base.Handle{light, slot, wrap, root, host, d.root}
	testing.expect_value(t, len(nodes), len(want))
	if len(nodes) == len(want) { for w, i in want { testing.expect_value(t, nodes[i], w) } }
}

@(test)
shadow_clone_and_shadow_including_order :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	host := el(d, d.root, "div")
	a := el(d, host, "a")
	root, _ := attach_shadow(d, host, {mode = .Open, clonable = true})
	s := el(d, root, "slot")
	order := make([dynamic]base.Handle, context.temp_allocator)
	for cur := d.root; cur != base.NIL_HANDLE; cur = next_shadow_including(d, cur, d.root) { append(&order, cur) }
	want := [?]base.Handle{d.root, host, root, s, a}
	testing.expect_value(t, len(order), len(want))
	if len(order) == len(want) { for w, i in want { testing.expect_value(t, order[i], w) } }

	copy := clone_node(d, host, true)
	croot := shadow_root_of(d, copy)
	testing.expect(t, croot != base.NIL_HANDLE)
	cs := get(d, croot).first_child
	testing.expect(t, cs != base.NIL_HANDLE && get(d, cs).name == "slot")
	testing.expect_value(t, len(assigned_nodes_raw(d, cs)), 1)
	release(d, copy)
	testing.expect(t, get(d, croot) == nil)
	testing.expect_value(t, len(d.shadow_roots), 1)
}
