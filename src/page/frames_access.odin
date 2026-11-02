package page

// A realm reaching the DOM of another document of its origin: iframe.contentDocument, frame.contentWindow.document,
// parent.document, top.document and all that is reached from them.
//
// Every document keeps its engine instance. A wrapper in a realm is a handle, and a handle says which document it belongs
// to (its tag, base.pool_insert_tagged): the same wrappers, bindings and imports serve a node of the realm's own document
// and a node of another one. On each import call, the generated trampoline hands every handle argument to api_route: a
// handle of another document moves the whole call there (Call.page), the implementations then act on that document as if
// it had called, with its styles, layout, hooks and scripts. What makes it safe:
//
//   * a handle resolves in its own document only: the tag is in the slot's generation, so a handle given to the wrong
//     document fails like a dead one, in any implementation, routed or not;
//   * the document is looked up on each call, among the documents of the caller's tab and of the windows of its browsing
//     context group (a popup and its opener, auxiliary.odin), and its origin compared with the
//     caller's (frames_may_reach): a frame gone, navigated to another origin or sandboxed without allow-same-origin leaves
//     handles that resolve to nothing. A cross-origin frame's nodes never get a handle in another realm in the first place;
//   * all documents of a tab live on one thread (they share the page's loop), and a worker has no route.
//
// Imports of Document that name no node act on the calling document: the glue names the document first (Frame_target, a
// one-shot read by the next import). A call that names nodes of two documents is refused by the lookups, but for the
// insertions, which adopt first (Frame_adoptNode). What a routed call creates that calls back (a listener, a promise)
// records its owner as a Foreign_Owner: the callback runs in the realm that asked (call_guest).
//
// A page in use cannot be freed under a running call: page_close leaves one with a call in it to be closed later
// (frames_close_later).

import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:js"
import "wb:url"
import "wb:wasm"

// The reply of the value bridge starts with its size, in the guest's memory.
BRIDGE_REPLY_HEADER :: 4

// In a listener's or a host object's `owner`: not an instance of this page (index into Page.foreign_owners).
FOREIGN_OWNER :: u32(1) << 31

Foreign_Owner :: struct {
	page:  u64,   // page_id: a realm whose document is gone resolves to nothing
	index: u32,   // the instance in that page
}

// May a realm of `from` touch the document of `to`? On every crossing: origins can change under a kept reference (a
// frame's next document), and an opaque origin (a sandbox without allow-same-origin, data:) equals only itself.
frames_may_reach :: proc(from, to: ^Page) -> bool {
	if from == to { return true }
	if from == nil || to == nil || from.closed || to.closed || from.worker != nil || to.worker != nil { return false }
	if to.close_pending { return false }
	return url.same_origin(from.env.origin, to.env.origin)
}

@(private = "file")
find_by_tag :: proc(p: ^Page, tag: u32) -> ^Page {
	if p.tag == tag { return p }
	if p.frames == nil { return nil }
	for n in p.frames.children {
		if n.page != nil { if r := find_by_tag(n.page, tag); r != nil { return r } }
	}
	return nil
}

// The document of `tag` (of page id `id`) among those of `from`'s browsing context group: its own tab first, then the
// windows related to it by openers (auxiliary.odin).
@(private = "file")
group_find_by_tag :: proc(from: ^Page, tag: u32) -> ^Page {
	if t := find_by_tag(page_top(from), tag); t != nil { return t }
	for top in group_tops(from)[1:] { if t := find_by_tag(top, tag); t != nil { return t } }
	return nil
}

@(private = "file")
group_find_by_id :: proc(from: ^Page, id: u64) -> ^Page {
	if t := find_by_id(page_top(from), id); t != nil { return t }
	for top in group_tops(from)[1:] { if t := find_by_id(top, id); t != nil { return t } }
	return nil
}

// The document of `tag` in the browsing context group of `from`, when `from` may reach it; nil otherwise.
frames_reach_tag :: proc(from: ^Page, tag: u32) -> ^Page {
	if from == nil || from.worker != nil || from.close_pending { return nil }
	t := group_find_by_tag(from, tag)
	if t == nil || !frames_may_reach(from, t) { return nil }
	return t
}

// A document that is an initial about:blank has no script machinery: nothing ran there, and nothing would have started
// it. Reached by another realm, it behaves as a document that finished loading: what is inserted there runs, in its own
// realm. One that is still loading gets it when its parser is done (scripts_start).
frames_make_live :: proc(p: ^Page) {
	if p == nil || p.closed || p.worker != nil { return }
	if p.frames == nil || !p.frames.complete { return }
	if !p.render.adopted { render_begin(p) }   // (it is shown from now on: nothing else would say its document is there)
	s := scripts_of(p)
	if s.started { return }
	s.started = true
	s.ready_state = .Complete
	scripts_install_hooks(p)
}

@(private = "file")
call_move_to :: proc(c: ^Call, t: ^Page) {
	c.page = t
	c.tag = t.tag
	c.routed = true
	c.owner = foreign_owner_of(t, c.caller, c.inst.index)
	c.caller_ce_mark = c.ce_mark
	c.ce_mark = t.jsdom != nil ? len(t.jsdom.ce.queue) : 0
	t.route_busy += 1
}

api_route_cold :: proc "contextless" (c: ^Call, tag: u32) {
	if c.routed || c.own || c.caller == nil { return }
	context = base.process_context()
	if t := frames_reach_tag(c.caller, tag); t != nil { call_move_to(c, t) }
}

// The call the realm said acts on another document (Frame_target).
api_take_target :: proc "contextless" (c: ^Call) {
	context = base.process_context()
	tag := c.caller.route_next
	c.caller.route_next = 0
	if t := frames_reach_tag(c.caller, tag); t != nil { call_move_to(c, t) }
}

// Nothing runs here unless the call itself caused it: a call that only reads must not run a script in the middle of the
// caller's work, and one made by the caller's garbage collector (Node_unpin) must not run a script at all.
api_unroute :: proc(c: ^Call) {
	t := c.page
	t.route_busy -= 1
	if c.hold_reactions { return }
	// what the call made a custom element moved to that document do, in the caller's realm ([CEReactions])
	if q := c.caller.jsdom; q != nil && len(q.ce.queue) > c.caller_ce_mark { custom_elements_flush(c.caller) }
	frames_pay_checkpoint(t)
}

// The microtask checkpoint a call of another realm into this one held back (call_guest, call_export, queue_microtask).
frames_pay_checkpoint :: proc(t: ^Page) {
	if !t.checkpoint_owed || t.route_busy > 0 || t.objects.depth > 0 || t.closed { return }
	t.checkpoint_owed = false
	microtask_checkpoint(t)
}

// The number standing for `caller`'s instance `index` in `t` (a listener's or an object's owner).
@(private)
foreign_owner_of :: proc(t, caller: ^Page, index: u32) -> u32 {
	id := page_id(caller)
	for o, i in t.foreign_owners { if o.page == id && o.index == index { return FOREIGN_OWNER | u32(i) } }
	append(&t.foreign_owners, Foreign_Owner{page = id, index = index})
	return FOREIGN_OWNER | u32(len(t.foreign_owners) - 1)
}

@(private = "file")
find_by_id :: proc(p: ^Page, id: u64) -> ^Page {
	if page_id(p) == id { return p }
	if p.frames == nil { return nil }
	for n in p.frames.children {
		if n.page != nil { if r := find_by_id(n.page, id); r != nil { return r } }
	}
	return nil
}

// The instance a Foreign_Owner names, when its document is still in the tab and may still reach `p`; nil otherwise.
foreign_owner_instance :: proc(p: ^Page, owner: u32) -> ^wasm.Instance {
	i := int(owner &~ FOREIGN_OWNER)
	if i >= len(p.foreign_owners) { return nil }
	o := p.foreign_owners[i]
	q := group_find_by_id(p, o.page)
	if q == nil || !frames_may_reach(q, p) { return nil }
	return instance_by_index(q, o.index)
}

////////////////////////////////
// Adoption

// Moves a node of `c.page` (the call was routed to it, or it is the caller's) to the document of `into_tag`, as lone nodes;
// the pairs of handles (old, new) of the subtree. A node has its handle in its document's pool: moving it means new nodes and
// new handles, with its listeners. The realm that asked moves its wrappers to them (wj_node_rekey); a wrapper another
// realm holds on the old node goes dead.
frames_adopt :: proc(c: ^Call, node: base.Handle, into_tag: u32) -> (out: []u8, ok: bool) {
	src := c.page
	c.hold_reactions = true   // the realm moves its wrappers when this returns: a reaction must find them moved
	if base.handle_tag(u64(node)) != c.tag { return nil, false }
	dst := into_tag == c.caller.tag ? c.caller : frames_reach_tag(c.caller, into_tag)
	if dst == nil || dst == src || dst.worker != nil { return nil, false }
	n := dom.get(src.doc, node)
	if n == nil || n.kind == .Document || n.is_shadow { return nil, false }
	// (an iframe going into its own document: leaving its tree ends that document, which is still written to below. In use, it is closed after the call.)
	dst.route_busy += 1
	defer dst.route_busy -= 1
	if n.parent != base.NIL_HANDLE { dom.detach(src.doc, node) }
	pairs := make([dynamic]u8, 0, 64, context.temp_allocator)
	put :: proc(b: ^[dynamic]u8, v: u64) {
		x := u64le(v)
		bytes := transmute([8]u8)x
		append(b, ..bytes[:])
	}
	Copy :: struct { from, parent: base.Handle }
	stack := make([dynamic]Copy, context.temp_allocator)
	moved := make([dynamic]Copy, context.temp_allocator)
	append(&stack, Copy{node, base.NIL_HANDLE})
	sd, dd := src.doc, dst.doc
	for len(stack) > 0 {
		cur := pop(&stack)
		s := dom.get(sd, cur.from)
		if s == nil { continue }
		h := dom.copy_across(sd, dd, cur.from)
		if h == base.NIL_HANDLE { continue }
		put(&pairs, u64(cur.from))
		put(&pairs, u64(h))
		move_listeners(src, dst, cur.from, h)
		append(&moved, Copy{cur.from, h})
		if ss := src.scripts; ss != nil && is_script_element(s) && .Already_Started in ss.flags[cur.from] {
			ds := scripts_of(dst)
			ds.flags[h] += {.Already_Started}
		}
		if cur.parent != base.NIL_HANDLE { dom.append_child(dd, cur.parent, h) }
		kids := make([dynamic]base.Handle, context.temp_allocator)
		for ch := s.first_child; ch != base.NIL_HANDLE; ch = dom.get(sd, ch).next { append(&kids, ch) }
		#reverse for k in kids { append(&stack, Copy{k, h}) }
	}
	for m in moved {
		dom.event_path_moved(&src.dp, m.from, m.parent)
		move_custom_element(src, dst, m.from, m.parent)
	}
	dom.destroy_unpinned(sd, node)   // (wrappers pin what they hold: the realm's moves release it, wj_node_rekey)
	return pairs[:], true
}

// dom.Dispatcher.other: where a node of an event's path is, when a listener moved it to another document of the tab.
frames_dispatcher_of :: proc(user: rawptr, node: base.Handle) -> (^dom.Document, ^dom.Dispatcher) {
	t := frames_reach_tag((^Page)(user), base.handle_tag(u64(node)))
	if t == nil { return nil, nil }
	return t.doc, &t.dp
}

// A custom element moved keeps its definition, which is its realm's: its reactions go on there, adoptedCallback first.
@(private = "file")
move_custom_element :: proc(src, dst: ^Page, from, to: base.Handle) {
	sc := ce_of(src)
	if sc == nil || sc.state[from] != CE_STATE_CUSTOM { return }
	owner := page_id(src)
	if id, moved := sc.moved_in[from]; moved { owner = id }
	// (what is queued for it, a disconnection, follows it)
	if op := frames_page_by_id(src, owner); op != nil && op.jsdom != nil {
		for &r in op.jsdom.ce.queue {
			if r.element == from && dom.pin(dst.doc, to) {
				r.element = to
				dom.unpin(src.doc, from)
			}
		}
	}
	delete_key(&sc.state, from)
	delete_key(&sc.moved_in, from)
	dc := &js_dom_state(dst).ce
	dc.state[to] = CE_STATE_CUSTOM
	if owner != page_id(dst) { dc.moved_in[to] = owner }
	dst.doc.ce_custom[to] = true
	mo_hook_update(dst)
	ce_queue(dst, dc, Ce_Reaction{kind = CE_ADOPTED, element = to, old_doc = src.doc.root, new_doc = dst.doc.root})
}

// The page numbered `id` in the tab of `p`, when `p` may reach it.
frames_page_by_id :: proc(p: ^Page, id: u64) -> ^Page {
	q := group_find_by_id(p, id)
	return q != nil && frames_may_reach(p, q) ? q : nil
}

// The listeners of a moved node keep calling the realm that added them: their owners, said in the new page's terms.
@(private = "file")
move_listeners :: proc(src, dst: ^Page, from, to: base.Handle) {
	n := dom.get(src.doc, from)
	if n == nil { return }
	for &l in n.listeners {
		if l.removed { continue }
		page := src
		index := l.owner
		if l.owner & FOREIGN_OWNER != 0 {
			i := int(l.owner &~ FOREIGN_OWNER)
			if i >= len(src.foreign_owners) { continue }
			o := src.foreign_owners[i]
			page = group_find_by_id(src, o.page)
			index = o.index
			if page == nil { continue }
		}
		dom.listener_copy(dst.doc, to, l, page == dst ? index : foreign_owner_of(dst, page, index))
	}
}

////////////////////////////////
// The value bridge (native/js/odin/frames_bridge.odin)

// Runs a request of `from`'s realm in the realm numbered `realm`, a nested call into its instance; its reply (owned), nil
// when that realm is gone, or may not be reached now. The origin is checked here, on each request. An instance with a call in
// progress takes this one on top: it is what a script calling another realm calling back is.
frames_bridge_call :: proc(from: ^Page, realm: u64, request: []u8) -> []u8 {
	if from == nil || from.worker != nil || from.close_pending { return nil }
	t := group_find_by_id(from, realm)
	if t == nil || t == from || !frames_may_reach(from, t) { return nil }
	r := js_realm(t)
	if r == nil || r.failed || r.inst == nil || r.inst.dead { return nil }
	d := js.guest_copy(r.inst, request, false)
	if d == 0 { return nil }
	defer js.guest_free(r.inst, d)
	t.route_busy += 1
	defer {
		t.route_busy -= 1
		frames_pay_checkpoint(t)
	}
	argv := [2]u32{d, u32(len(request))}
	if js_call(t, r.inst, "wj_bridge_dispatch", argv[:]) != .Ok { return nil }
	js_after_task(t, r, "bridge")
	at := argv[0]
	if at == 0 { return nil }
	defer js.guest_free(r.inst, at)
	head := wasm.guest_bytes(r.inst, u64(at), BRIDGE_REPLY_HEADER)
	if head == nil { return nil }
	size := u32(head[0]) | u32(head[1]) << 8 | u32(head[2]) << 16 | u32(head[3]) << 24
	if size < BRIDGE_REPLY_HEADER { return nil }
	body := wasm.guest_bytes(r.inst, u64(at) + BRIDGE_REPLY_HEADER, u64(size) - BRIDGE_REPLY_HEADER)
	out := make([]u8, len(body))
	copy(out, body)
	return out
}

////////////////////////////////
// Closing a document in use

frames_pending_closes: [dynamic]^Page
@(private = "file") pending_timer_armed: bool

@(private = "file")
page_in_use :: proc(p: ^Page) -> bool {
	if p.route_busy > 0 || p.objects.depth > 0 { return true }
	if p.js != nil && p.js.inst != nil && p.js.inst.depth > 0 { return true }
	if p.frames != nil {
		for n in p.frames.children { if n.page != nil && page_in_use(n.page) { return true } }
	}
	for q in frames_pending_closes {
		if q != p && q.frames_pending_parent == p && page_in_use(q) { return true }
	}
	return false
}

// A document with a running call in it (a frame's script removing its own frame through parent.document, a navigation of
// the frame it runs in) cannot be freed now: it leaves the tree at once, nothing reaches it any more, and it is closed
// once the call has returned. True when it was left for later.
frames_close_later :: proc(p: ^Page) -> bool {
	if p.worker != nil { return false }
	if p.close_pending { return true }
	if !page_in_use(p) { return false }
	p.close_pending = true
	p.console = nil
	if f := p.frames; f != nil && !f.owns_nav {
		if n := f.nav; n != nil {
			p.frames_pending_parent = n.parent
			if n.parent == nil && n.page == p { n.page = nil }   // (an embedder's navigable)
			f.nav = nil
		}
	}
	if p.web != nil {
		set_embedder(p, Embedder{})
		p.web.session = &p.web.own_session   // (the navigable's goes with it)
	}
	append(&frames_pending_closes, p)
	arm_pending(p)
	return true
}

@(private = "file")
arm_pending :: proc(p: ^Page) {
	if pending_timer_armed { return }
	pending_timer_armed = true
	host.set_timer(p.loop, 0, 0, proc(data: rawptr) {
		pending_timer_armed = false
		for i := len(frames_pending_closes) - 1; i >= 0; i -= 1 {
			if i >= len(frames_pending_closes) { continue }
			q := frames_pending_closes[i]
			if page_in_use(q) { continue }
			unordered_remove(&frames_pending_closes, i)
			q.close_pending = false
			base.scope_close(q.scope)
		}
		if len(frames_pending_closes) > 0 { arm_pending(frames_pending_closes[0]) }
	}, nil)
}

// A page is going: it is no longer waiting, and what was waiting under it no longer has a parent to ask about.
frames_closed :: proc(p: ^Page) {
	for i := len(frames_pending_closes) - 1; i >= 0; i -= 1 {
		q := frames_pending_closes[i]
		if q == p { unordered_remove(&frames_pending_closes, i); continue }
		if q.frames_pending_parent == p { q.frames_pending_parent = nil }
	}
}
