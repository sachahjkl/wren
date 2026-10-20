package page

// MutationObserver, Range and Selection for JavaScript (api/js_dom_observe.widl).
//
// MutationObserver (DOM §4.3). The document calls the page for every mutation as it happens (dom.Document.observer,
// the mutation hook of the journal) as long as some observer is registered. The hook finds the interested observers
// by walking from the target up through its ancestors (registrations with `subtree` apply to descendants), queues a
// record for each, and a microtask that runs the observer's `notify` in the engine, which takes the records and calls
// the script's callback. Journal entries of one DOM operation (dom.batch_begin) become one record, as the standard
// queues them. A removed node keeps the subtree registrations of its old ancestors as transient registrations until
// the next notification. Every node a queued record names is pinned (the script will get it), until the engine took
// the record.

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:dom"
import lay "wb:layout"
import "wb:wasm"

MO_CHILD_LIST :: 1
MO_ATTRIBUTES :: 2
MO_CHARACTER_DATA :: 4
MO_SUBTREE :: 8
MO_ATTRIBUTE_OLD_VALUE :: 16
MO_CHARACTER_DATA_OLD_VALUE :: 32
MO_ATTRIBUTE_FILTER :: 64

@(private)
Mo_Registration :: struct {
	node:      base.Handle,
	options:   u32,
	filter:    []string,       // owned
	transient: bool,           // a removed node's copy of an ancestor's registration (until the next notification)
}

@(private)
Mo_Record :: struct {
	kind:     u8,              // 0 attributes, 1 characterData, 2 childList
	target:   base.Handle,
	prev:     base.Handle,
	next:     base.Handle,
	added:    [dynamic]base.Handle,
	removed:  [dynamic]base.Handle,
	name:     string,          // owned
	old:      string,          // owned
	has_old:  bool,
	batch:    u32,
}

@(private)
Mutation_Observer :: struct {
	page:     ^Page,
	self:     u64,
	instance: u32,
	notify:   u32,
	user:     u32,
	regs:     [dynamic]Mo_Registration,
	queue:    [dynamic]Mo_Record,
	taken:    int,             // records the engine took (removed at release)
	pending:  bool,            // a notification microtask is queued
	warned:   bool,
}

Observers :: struct {
	list:    [dynamic]^Mutation_Observer,   // in creation order
	on_node: map[base.Handle]int,          // registrations per node, for the hook's ancestor walk
}

@(private)
mo_vt := Object_VTable{name = "MutationObserver", destroy = proc(p: ^Page, data: rawptr) {
	mo := (^Mutation_Observer)(data)
	mo_clear(p, mo)
	delete(mo.regs)
	delete(mo.queue)
	if p.jsdom != nil {
		obs := &p.jsdom.observers
		for x, i in obs.list { if x == mo { ordered_remove(&obs.list, i); break } }
		mo_hook_update(p)
	}
	free(mo)
}}

@(private)
observers_destroy :: proc(p: ^Page, obs: ^Observers) {
	// the observers themselves are host objects, freed with the others; only the shared tables go here
	delete(obs.list)
	delete(obs.on_node)
	obs^ = {}
	if p.doc != nil { p.doc.observer = nil }
}

@(private)
record_free :: proc(p: ^Page, r: ^Mo_Record, unpin: bool) {
	if unpin && !p.closed && p.doc != nil {
		d := p.doc
		for h in ([?]base.Handle{r.target, r.prev, r.next}) { if h != base.NIL_HANDLE { dom.unpin(d, h) } }
		for h in r.added { dom.unpin(d, h) }
		for h in r.removed { dom.unpin(d, h) }
	}
	delete(r.added); delete(r.removed); delete(r.name); delete(r.old)
}

@(private)
reg_free :: proc(p: ^Page, mo: ^Mutation_Observer, i: int) {
	r := mo.regs[i]
	for f in r.filter { delete(f) }
	delete(r.filter)
	if p.jsdom != nil {
		obs := &p.jsdom.observers
		if n, ok := obs.on_node[r.node]; ok {
			if n <= 1 { delete_key(&obs.on_node, r.node) } else { obs.on_node[r.node] = n - 1 }
		}
	}
	ordered_remove(&mo.regs, i)
}

// Every registration and record of an observer gone (disconnect, destruction).
@(private)
mo_clear :: proc(p: ^Page, mo: ^Mutation_Observer) {
	for len(mo.regs) > 0 { reg_free(p, mo, len(mo.regs) - 1) }
	for &r in mo.queue { record_free(p, &r, true) }
	clear(&mo.queue)
	mo.taken = 0
}

// The document's hook is on while some observer has registrations, or some custom element is defined.
@(private)
mo_hook_update :: proc(p: ^Page) {
	if p.doc == nil || p.jsdom == nil { return }
	on := len(p.jsdom.observers.on_node) > 0 || len(p.jsdom.ce.defined) > 0
	p.doc.observer = on ? page_mutation_hook : nil
	p.doc.observer_user = on ? p : nil
}

@(private)
page_mutation_hook :: proc(user: rawptr, d: ^dom.Document, e: ^dom.Journal_Entry) {
	p := (^Page)(user)
	if p.closed || p.jsdom == nil { return }
	if len(p.jsdom.observers.on_node) > 0 { mutation_hook(user, d, e) }
	if len(p.jsdom.ce.defined) > 0 { ce_mutation(p, d, e) }
}

@(private)
observer_of :: proc(c: ^Call, h: u64) -> ^Mutation_Observer {
	if call_doc(c) == nil { return nil }
	return (^Mutation_Observer)(object_data(c.page, h, &mo_vt))
}

MutationObserver_create :: proc(c: ^Call, notify: u32, user: i32) -> u64 {
	if call_doc(c) == nil { return 0 }
	mo := new(Mutation_Observer)
	mo.page, mo.instance, mo.notify, mo.user = c.page, c.owner, notify, u32(user)
	h := object_create(c.page, &mo_vt, mo, c.owner)
	mo.self = h
	append(&js_dom_state(c.page).observers.list, mo)
	return h
}

MutationObserver_observe :: proc(c: ^Call, observer: u64, target: Api_Node, options: u32, filter: string) -> Api_Error {
	mo := observer_of(c, observer)
	if mo == nil { return fail(c, .Invalid_Handle, "not a MutationObserver") }
	opts := options
	if opts & MO_ATTRIBUTE_FILTER != 0 || opts & MO_ATTRIBUTE_OLD_VALUE != 0 { opts |= MO_ATTRIBUTES }
	if opts & MO_CHARACTER_DATA_OLD_VALUE != 0 { opts |= MO_CHARACTER_DATA }
	if opts & (MO_CHILD_LIST | MO_ATTRIBUTES | MO_CHARACTER_DATA) == 0 {
		return fail(c, .Type, "The options object must set at least one of 'attributes', 'characterData', or 'childList' to true.")
	}
	names: []string
	if opts & MO_ATTRIBUTE_FILTER != 0 {
		parts := strings.split(filter, "\x00", context.temp_allocator)
		names = make([]string, len(parts))
		for s, i in parts { names[i] = strings.to_lower(s) }
	}
	h := H(target.handle)
	obs := &js_dom_state(c.page).observers
	// a registration of this observer on the node is replaced (its transient copies go)
	for i := len(mo.regs) - 1; i >= 0; i -= 1 {
		if mo.regs[i].transient || mo.regs[i].node == h { reg_free(c.page, mo, i) }
	}
	append(&mo.regs, Mo_Registration{node = h, options = opts, filter = names})
	obs.on_node[h] += 1
	mo_hook_update(c.page)
	return .None
}

MutationObserver_disconnect :: proc(c: ^Call, observer: u64) {
	mo := observer_of(c, observer)
	if mo == nil { return }
	mo_clear(c.page, mo)
	mo_hook_update(c.page)
}

MutationObserver_live :: proc(c: ^Call, observer: u64) -> bool {
	mo := observer_of(c, observer)
	if mo == nil { return false }
	if len(mo.queue) > 0 { return true }
	for r in mo.regs { if !r.transient && dom.get(c.page.doc, r.node) != nil { return true } }
	return false
}

@(private)
put_u8 :: proc(b: ^[dynamic]u8, v: u8) { append(b, v) }
@(private)
put_u32 :: proc(b: ^[dynamic]u8, v: u32) { for k in 0 ..< 4 { append(b, u8(v >> (8 * uint(k)))) } }
@(private)
put_u64 :: proc(b: ^[dynamic]u8, v: u64) { for k in 0 ..< 8 { append(b, u8(v >> (8 * uint(k)))) } }
@(private)
put_str :: proc(b: ^[dynamic]u8, s: string) { put_u32(b, u32(len(s))); append(b, ..transmute([]u8)s) }

// records_pack: per record, kind u8, target u64, previousSibling u64, nextSibling u64, added count u32, removed count
// u32, the added then the removed handles (u64 each), attributeName (u32 length + UTF-8), oldValue present u8, oldValue
// (u32 length + UTF-8). Little endian.
MutationObserver_takeRecords :: proc(c: ^Call, observer: u64) -> []u8 {
	mo := observer_of(c, observer)
	if mo == nil { return nil }
	b := make([dynamic]u8, 0, 64 * len(mo.queue), context.temp_allocator)
	for &r in mo.queue {
		put_u8(&b, r.kind)
		put_u64(&b, u64(r.target)); put_u64(&b, u64(r.prev)); put_u64(&b, u64(r.next))
		put_u32(&b, u32(len(r.added))); put_u32(&b, u32(len(r.removed)))
		for h in r.added { put_u64(&b, u64(h)) }
		for h in r.removed { put_u64(&b, u64(h)) }
		put_str(&b, r.name)
		put_u8(&b, r.has_old ? 1 : 0)
		put_str(&b, r.old)
	}
	mo.taken = len(mo.queue)
	return b[:]
}

MutationObserver_release :: proc(c: ^Call, observer: u64) {
	mo := observer_of(c, observer)
	if mo == nil { return }
	n := min(mo.taken, len(mo.queue))
	for i in 0 ..< n { record_free(c.page, &mo.queue[i], true) }
	remove_range(&mo.queue, 0, n)
	mo.taken = 0
	mo.pending = false
	for i := len(mo.regs) - 1; i >= 0; i -= 1 { if mo.regs[i].transient { reg_free(c.page, mo, i) } }
	mo_hook_update(c.page)
}

// The mutation hook of the document (dom.Mutation_Hook).
@(private)
mutation_hook :: proc(user: rawptr, d: ^dom.Document, e: ^dom.Journal_Entry) {
	p := (^Page)(user)
	if p.closed || p.jsdom == nil { return }
	obs := &p.jsdom.observers
	kind: u8
	target := e.node
	switch e.kind {
	case .Attribute: kind = 0
	case .Text: kind = 1
	case .Insert, .Remove: kind = 2; target = e.parent
	case .Reslot: return   // not a mutation of the node tree (dom.journal_record does not report it)
	}
	if target == base.NIL_HANDLE { return }
	// the interested observers (DOM "queue a mutation record"): registrations on the target, and with `subtree` on
	// its ancestors; one record per observer, with the old value when one of its registrations asks for it
	Interest :: struct { mo: ^Mutation_Observer, old: bool }
	interested := make([dynamic]Interest, 0, 4, context.temp_allocator)
	for cur := target; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if cur in obs.on_node {
			for mo in obs.list {
				for &r in mo.regs {
					if r.node != cur { continue }
					if cur != target && r.options & MO_SUBTREE == 0 { continue }
					if !registration_wants(&r, kind, e) { continue }
					want_old := (kind == 0 && r.options & MO_ATTRIBUTE_OLD_VALUE != 0) || (kind == 1 && r.options & MO_CHARACTER_DATA_OLD_VALUE != 0)
					found := false
					for &x in interested { if x.mo == mo { x.old = x.old || want_old; found = true; break } }
					if !found { append(&interested, Interest{mo, want_old}) }
				}
			}
		}
		cur = n.parent
	}
	for x in interested { mo_record(p, x.mo, kind, target, e, x.old) }
	// a removed node keeps the subtree registrations of its old ancestors until the next notification
	if e.kind == .Remove {
		for cur := e.parent; cur != base.NIL_HANDLE; {
			n := dom.get(d, cur)
			if n == nil { break }
			if cur in obs.on_node {
				for mo in obs.list {
					for i in 0 ..< len(mo.regs) {
						r := mo.regs[i]
						if r.node != cur || r.options & MO_SUBTREE == 0 { continue }
						f: []string
						if len(r.filter) > 0 {
							f = make([]string, len(r.filter))
							for s, k in r.filter { f[k] = strings.clone(s) }
						}
						append(&mo.regs, Mo_Registration{node = e.node, options = r.options, filter = f, transient = true})
						obs.on_node[e.node] += 1
					}
				}
			}
			cur = n.parent
		}
	}
}

@(private)
registration_wants :: proc(r: ^Mo_Registration, kind: u8, e: ^dom.Journal_Entry) -> bool {
	switch kind {
	case 0:
		if r.options & MO_ATTRIBUTES == 0 { return false }
		if r.options & MO_ATTRIBUTE_FILTER != 0 {
			for f in r.filter { if f == e.name { return true } }
			return false
		}
		return true
	case 1: return r.options & MO_CHARACTER_DATA != 0
	case 2: return r.options & MO_CHILD_LIST != 0
	}
	return false
}

// A record for an interested observer; childList entries of one DOM operation (same batch, same target) join the
// observer's last record instead.
@(private)
mo_record :: proc(p: ^Page, mo: ^Mutation_Observer, kind: u8, target: base.Handle, e: ^dom.Journal_Entry, want_old: bool) {
	d := p.doc
	if n := len(mo.queue); n > 0 && n > mo.taken {
		last := &mo.queue[n - 1]
		if kind == 2 && e.batch != 0 && last.kind == 2 && last.batch == e.batch && last.target == target {
			if e.kind == .Insert { append(&last.added, e.node) } else { append(&last.removed, e.node) }
			dom.pin(d, e.node)
			if last.next != base.NIL_HANDLE { dom.unpin(d, last.next) }
			last.next = e.next
			if e.next != base.NIL_HANDLE { dom.pin(d, e.next) }
			return
		}
	}
	if len(mo.queue) >= p.settings.dom.max_mutation_records {
		if !mo.warned {
			mo.warned = true
			log(p, .Warn, fmt.tprintf("a MutationObserver has more than javascript.dom.max_mutation_records (%d) records waiting: the oldest are dropped", p.settings.dom.max_mutation_records))
		}
		if mo.taken == 0 {
			record_free(p, &mo.queue[0], true)
			ordered_remove(&mo.queue, 0)
		} else {
			return
		}
	}
	rec := Mo_Record{kind = kind, target = target, batch = e.batch}
	dom.pin(d, target)
	if kind == 2 {
		rec.prev, rec.next = e.prev, e.next
		if rec.prev != base.NIL_HANDLE { dom.pin(d, rec.prev) }
		if rec.next != base.NIL_HANDLE { dom.pin(d, rec.next) }
		if e.kind == .Insert { append(&rec.added, e.node) } else { append(&rec.removed, e.node) }
		dom.pin(d, e.node)
	} else {
		if kind == 0 { rec.name = strings.clone(e.name) }
		if want_old && e.had_old { rec.old = strings.clone(e.old); rec.has_old = true }
	}
	append(&mo.queue, rec)
	if !mo.pending {
		mo.pending = true
		mo_notify_later(p, mo)
	}
}

// Queues the notification of an observer. For the JavaScript realm it is a job of the engine (wj_mo_queue: it runs
// in order with the promise reactions queued around it, as the DOM's microtask would); only the job is queued here,
// in the middle of a mutation, nothing runs. Other modules get a microtask of the page calling `notify`.
@(private)
mo_notify_later :: proc(p: ^Page, mo: ^Mutation_Observer) {
	if r := p.js; r != nil && !r.failed && r.inst != nil && !r.inst.dead && mo.instance == r.inst.index {
		argv := [1]u32{mo.user}
		p.objects.depth += 1
		res := wasm.call_raw(r.inst, "wj_mo_queue", argv[:])
		p.objects.depth -= 1
		if res != .Ok { guest_failed(p, r.inst); return }
		// a mutation outside any script (the browser's own): the checkpoint that runs the job comes with a task
		if p.objects.depth == 0 { host_post_checkpoint(p) }
		return
	}
	queue_microtask(p, Microtask{instance = mo.instance, callback = mo.notify, user = mo.user})
}

////////////////////////////////
// Range

// DOM "position of a boundary point" of (a, ao) relative to (b, bo): -1 before, 0 equal, 1 after.
boundary_compare :: proc(d: ^dom.Document, a: base.Handle, ao: int, b: base.Handle, bo: int) -> int {
	if a == b { return ao < bo ? -1 : ao > bo ? 1 : 0 }
	if dom.tree_order_compare(d, a, b) > 0 { return -boundary_compare(d, b, bo, a, ao) }
	if dom.is_ancestor_or_self(d, a, b) {
		child := b
		for dom.get(d, child).parent != a { child = dom.get(d, child).parent }
		if dom.child_index(d, child) < ao { return 1 }
	}
	return -1
}

Range_comparePoints :: proc(c: ^Call, first: Api_Node, first_offset: u32, second: Api_Node, second_offset: u32) -> i32 {
	return i32(boundary_compare(c.page.doc, H(first.handle), int(first_offset), H(second.handle), int(second_offset)))
}

Range_text :: proc(c: ^Call, start: Api_Node, start_offset: u32, end: Api_Node, end_offset: u32) -> string {
	d := c.page.doc
	sc, ec := H(start.handle), H(end.handle)
	b := strings.builder_make(context.temp_allocator)
	if sc == ec && start.data.kind == .Text {
		t := start.data.text
		a, z := utf8_index(t, int(start_offset)), utf8_index(t, int(end_offset))
		return z > a ? t[a:z] : ""
	}
	if start.data.kind == .Text {
		strings.write_string(&b, start.data.text[utf8_index(start.data.text, int(start_offset)):])
	}
	// the Text nodes contained in the range, in tree order
	root := dom.tree_root(d, sc)
	first := dom.next_in_tree(d, sc, root)
	if start.data.kind != .Text && start.data.kind != .Comment {
		if ch := dom.child_at(d, sc, int(start_offset)); ch != base.NIL_HANDLE { first = ch } else { first = dom.next_skipping_children(d, sc, root) }
	}
	for cur := first; cur != base.NIL_HANDLE; cur = dom.next_in_tree(d, cur, root) {
		if cur == ec { break }
		// past the end boundary
		if boundary_compare(d, cur, 0, ec, int(end_offset)) >= 0 { break }
		if n := dom.get(d, cur); n.kind == .Text { strings.write_string(&b, n.text) }
	}
	if end.data.kind == .Text && ec != sc {
		strings.write_string(&b, end.data.text[:utf8_index(end.data.text, int(end_offset))])
	}
	return strings.to_string(b)
}

// DOM "clone the contents" / "extract" / delete of a range (mode 0 / 1 / 2), recursively over the partially
// contained ancestors (depth bounded).
Range_contents :: proc(c: ^Call, start: Api_Node, start_offset: u32, end: Api_Node, end_offset: u32, mode: i32) -> (u64, Api_Error) {
	if mode < 0 || mode > 2 { return 0, fail(c, .Invalid_Argument, "unknown mode") }
	frag, err := range_contents(c, H(start.handle), int(start_offset), H(end.handle), int(end_offset), mode, 0)
	if err != .None { return 0, err }
	if mode == 2 {
		dom.destroy_unpinned(c.page.doc, frag)
		return 0, .None
	}
	return u64(frag), .None
}

@(private)
MAX_RANGE_DEPTH :: 1024

@(private)
range_contents :: proc(c: ^Call, sc: base.Handle, so: int, ec: base.Handle, eo: int, mode: i32, depth: int) -> (base.Handle, Api_Error) {
	d := c.page.doc
	frag := dom.create_fragment(d)
	if depth > MAX_RANGE_DEPTH { return frag, fail(c, .Not_Supported, "the range is too deep") }
	if boundary_compare(d, sc, so, ec, eo) >= 0 { return frag, .None }
	sn := dom.get(d, sc)
	is_cd :: proc(n: ^dom.Node) -> bool { return n != nil && (n.kind == .Text || n.kind == .Comment) }
	if sc == ec && is_cd(sn) {
		a, z := utf8_index(sn.text, so), utf8_index(sn.text, eo)
		if mode != 2 {
			cl := dom.clone_node(d, sc, false)
			dom.set_data(d, cl, sn.text[a:z])
			dom.append_child(d, frag, cl)
		}
		if mode != 0 { dom.set_data(d, sc, strings.concatenate({sn.text[:a], sn.text[z:]}, context.temp_allocator)) }
		return frag, .None
	}
	// the common ancestor, and the children of it that hold each end
	ca := sc
	for !dom.is_ancestor_or_self(d, ca, ec) { ca = dom.get(d, ca).parent }
	child_holding :: proc(d: ^dom.Document, ca, n: base.Handle) -> base.Handle {
		cur := n
		for cur != base.NIL_HANDLE && dom.get(d, cur).parent != ca { cur = dom.get(d, cur).parent }
		return cur
	}
	first_partial := dom.is_ancestor_or_self(d, sc, ec) ? base.NIL_HANDLE : child_holding(d, ca, sc)
	last_partial := dom.is_ancestor_or_self(d, ec, sc) ? base.NIL_HANDLE : child_holding(d, ca, ec)
	contained := make([dynamic]base.Handle, 0, 8, context.temp_allocator)
	for ch := dom.get(d, ca).first_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).next {
		if ch == first_partial || ch == last_partial { continue }
		// DOM "contained": (node, 0) after the start and (node, length) before the end
		if boundary_compare(d, ch, 0, sc, so) > 0 && boundary_compare(d, ch, node_length(d, ch), ec, eo) < 0 {
			if dom.get(d, ch).kind == .Doctype { return frag, fail(c, .Hierarchy, "The range contains a doctype.") }
			append(&contained, ch)
		}
	}
	if first_partial != base.NIL_HANDLE {
		fp := dom.get(d, first_partial)
		if is_cd(fp) {
			a := utf8_index(sn.text, so)
			if mode != 2 {
				cl := dom.clone_node(d, sc, false)
				dom.set_data(d, cl, sn.text[a:])
				dom.append_child(d, frag, cl)
			}
			if mode != 0 { dom.set_data(d, sc, strings.clone(sn.text[:a], context.temp_allocator)) }
		} else {
			sub, err := range_contents(c, sc, so, first_partial, node_length(d, first_partial), mode, depth + 1)
			if err != .None { dom.destroy_unpinned(d, sub); return frag, err }
			if mode != 2 {
				cl := dom.clone_node(d, first_partial, false)
				dom.append_child(d, frag, cl)
				insert_node(d, cl, sub, base.NIL_HANDLE)
			}
			dom.destroy_unpinned(d, sub)
		}
	}
	for ch in contained {
		switch mode {
		case 0: dom.append_child(d, frag, dom.clone_node(d, ch, true))
		case 1: insert_node(d, frag, ch, base.NIL_HANDLE)
		case 2: dom.detach(d, ch); dom.destroy_unpinned(d, ch)
		}
	}
	if last_partial != base.NIL_HANDLE {
		lp := dom.get(d, last_partial)
		en := dom.get(d, ec)
		if is_cd(lp) {
			z := utf8_index(en.text, eo)
			if mode != 2 {
				cl := dom.clone_node(d, ec, false)
				dom.set_data(d, cl, en.text[:z])
				dom.append_child(d, frag, cl)
			}
			if mode != 0 { dom.set_data(d, ec, strings.clone(en.text[z:], context.temp_allocator)) }
		} else {
			sub, err := range_contents(c, last_partial, 0, ec, eo, mode, depth + 1)
			if err != .None { dom.destroy_unpinned(d, sub); return frag, err }
			if mode != 2 {
				cl := dom.clone_node(d, last_partial, false)
				dom.append_child(d, frag, cl)
				insert_node(d, cl, sub, base.NIL_HANDLE)
			}
			dom.destroy_unpinned(d, sub)
		}
	}
	return frag, .None
}

////////////////////////////////
// Selection (the page's, selection.odin): offsets in UTF-16 code units for Text nodes

@(private)
to_utf16_offset :: proc(d: ^dom.Document, pos: lay.Text_Pos) -> u32 {
	n := dom.get(d, pos.node)
	if n != nil && (n.kind == .Text || n.kind == .Comment) { return u32(utf16_length(n.text[:min(pos.offset, len(n.text))])) }
	return u32(pos.offset)
}

@(private)
from_utf16_offset :: proc(d: ^dom.Document, h: base.Handle, off: u32) -> (lay.Text_Pos, bool) {
	n := dom.get(d, h)
	if n == nil { return {}, false }
	if n.kind == .Text || n.kind == .Comment {
		if int(off) > utf16_length(n.text) { return {}, false }
		return {h, utf8_index(n.text, int(off))}, true
	}
	if int(off) > node_length(d, h) { return {}, false }
	return {h, int(off)}, true
}

Selection_state :: proc(c: ^Call) -> Api_SelectionState {
	p := c.page
	if call_doc(c) == nil { return {} }
	s := selection_get(p)
	if !s.has { return {} }
	return Api_SelectionState{
		anchor = u64(s.anchor.node), anchor_offset = to_utf16_offset(p.doc, s.anchor),
		focus = u64(s.focus.node), focus_offset = to_utf16_offset(p.doc, s.focus),
		kind = s.anchor == s.focus ? 1 : 2,
	}
}

Selection_setRange :: proc(c: ^Call, anchor: Api_Node, anchor_offset: u32, focus: Api_Node, focus_offset: u32) -> Api_Error {
	p := c.page
	a, ok1 := from_utf16_offset(p.doc, H(anchor.handle), anchor_offset)
	f, ok2 := from_utf16_offset(p.doc, H(focus.handle), focus_offset)
	if !ok1 || !ok2 { return fail(c, .Index_Size, "The offset is larger than the node's length.") }
	if !dom.is_connected(p.doc, a.node) || !dom.is_connected(p.doc, f.node) { return .None }   // nodes of another tree: ignored
	selection_set(p, a, f)
	return .None
}

Selection_clear :: proc(c: ^Call) { if call_doc(c) != nil { selection_clear(c.page) } }

Selection_text :: proc(c: ^Call) -> string {
	if call_doc(c) == nil { return "" }
	if p := c.page; p.styled == nil { js_dom_styled(p) }
	return selection_text(c.page)
}
