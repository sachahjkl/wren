package page

// Shadow trees for JavaScript (api/js_shadow.widl): attachShadow and ShadowRoot, slots (assignment, slotchange),
// declarative shadow roots in markup (getHTML, setHTMLUnsafe, parseHTMLUnsafe), the composed event path,
// ElementInternals with custom states, and constructable stylesheets with adoptedStyleSheets. The trees themselves
// are the DOM's (src/dom/shadow.odin); their styles the engine's (src/style/scope.odin).
//
// slotchange (HTML "signal a slot change"): the DOM reports each slot whose assigned nodes changed; the slots are
// kept, in order, until the microtask checkpoint, which fires `slotchange` at each once the mutation observers'
// notifications ran (DOM "notify mutation observers").

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:html"
import "wb:style"
import "wb:wasm"

Js_Shadow :: struct {
	signal:        [dynamic]base.Handle,   // slots to fire slotchange at (pinned while listed)
	disabled:      map[string]u8,          // custom element names whose definition disables: 1 shadow, 2 internals
	internals:     map[base.Handle]u64,    // elements that attached internals -> their ElementInternals
	last_target:   u64,                    // EventTarget_lastTarget
	next_related:  u64,                    // Event_setNextRelated: the next engine event's relatedTarget
	slot_deferred: bool,                   // the slotchange job went behind the observers' jobs once
	deferred:      [dynamic]base.Handle,   // ... with these slots (pinned)
}

@(private)
shadow_state :: proc(p: ^Page) -> ^Js_Shadow { return &js_dom_state(p).shadow }

@(private)
js_shadow_destroy :: proc(p: ^Page, s: ^Js_Shadow) {
	if !p.closed && p.doc != nil {
		for h in s.signal { dom.unpin(p.doc, h) }
		for h in s.deferred { dom.unpin(p.doc, h) }
	}
	delete(s.signal)
	delete(s.deferred)
	for k in s.disabled { delete(k) }
	delete(s.disabled)
	delete(s.internals)
	s^ = {}
}

// The page's document got its shadow-tree hook (a new document, an adopted one).
shadow_doc_attached :: proc(p: ^Page) {
	if p.doc == nil { return }
	p.doc.slot_user = p
	p.doc.slot_changed = proc(user: rawptr, d: ^dom.Document, slot: base.Handle) {
		p := (^Page)(user)
		if p.closed || p.worker != nil || p.js == nil { return }   // nobody could listen
		s := shadow_state(p)
		for x in s.signal { if x == slot { return } }
		if !dom.pin(d, slot) { return }
		append(&s.signal, slot)
		if len(s.signal) > 1 { return }   // the job is queued already
		// a job of the engine (in order with the promise reactions and mutation records queued around it), else the
		// microtask checkpoint
		if r := p.js; r != nil && !r.failed && r.inst != nil && !r.inst.dead {
			p.objects.depth += 1
			res := wasm.call_raw(r.inst, "wj_slot_queue", nil)
			p.objects.depth -= 1
			if res != .Ok { guest_failed(p, r.inst) }
		}
		if p.objects.depth == 0 { host_post_checkpoint(p) }   // a change outside script: a checkpoint comes with a task
	}
}

// The slotchange job. DOM fires slotchange in the mutation observers' microtask, after their callbacks: the jobs of
// observers queued after this one (records made after the slot was signalled) run first, the job going once more
// behind them.
Shadow_fireSlotChanges :: proc(c: ^Call) {
	p := c.page
	s := shadow_state(p)
	if !s.slot_deferred && p.jsdom != nil && len(s.signal) > 0 {
		for mo in p.jsdom.observers.list {
			if !mo.pending { continue }
			if r := p.js; r != nil && !r.failed && r.inst != nil && !r.inst.dead {
				// the slots signalled so far fire after those observers; a slot signalled by their callbacks again
				// is a new signal (another job, another slotchange)
				s.slot_deferred = true
				append(&s.deferred, ..s.signal[:])
				clear(&s.signal)
				p.objects.depth += 1
				res := wasm.call_raw(r.inst, "wj_slot_queue", nil)
				p.objects.depth -= 1
				if res != .Ok { guest_failed(p, r.inst) }
				return
			}
		}
	}
	if s.slot_deferred {
		s.slot_deferred = false
		fire_slot_changes(p, s.deferred[:])
		clear(&s.deferred)
		return
	}
	shadow_signal_slots(p)
}

@(private = "file")
fire_slot_changes :: proc(p: ^Page, slots: []base.Handle) {
	list := make([dynamic]base.Handle, 0, len(slots), context.temp_allocator)
	append(&list, ..slots)
	for slot in list {
		if dom.get(p.doc, slot) != nil { dispatch_event(p, slot, dom.Event{type = "slotchange", bubbles = true}) }
		dom.unpin(p.doc, slot)
	}
}

// Fires slotchange at the signalled slots (from the microtask checkpoint). Returns whether it fired any.
shadow_signal_slots :: proc(p: ^Page) -> bool {
	if p.jsdom == nil || p.closed { return false }
	s := &p.jsdom.shadow
	if len(s.signal) == 0 && len(s.deferred) == 0 { return false }
	list := make([dynamic]base.Handle, 0, len(s.deferred) + len(s.signal), context.temp_allocator)
	append(&list, ..s.deferred[:])
	append(&list, ..s.signal[:])
	clear(&s.deferred)
	clear(&s.signal)
	s.slot_deferred = false
	fire_slot_changes(p, list[:])
	return true
}

////////////////////////////////
// attachShadow, ShadowRoot

Element_attachShadowInit :: proc(c: ^Call, element: Api_Element, mode: u32, delegates_focus: bool, slot_assignment: u32, clonable: bool, serializable: bool) -> (u64, Api_Error) {
	p := c.page
	d := p.doc
	h := H(element.handle)
	n := element.data
	if n.ns == .HTML && dom.is_valid_custom_element_name(n.name) {
		if s := shadow_state(p); s.disabled[n.name] & 1 != 0 {
			return 0, fail(c, .Not_Supported, "Failed to execute 'attachShadow' on 'Element': attachShadow() is disabled by disabledFeatures static field.")
		}
	}
	init := dom.Shadow_Init{
		mode = mode == 1 ? .Closed : .Open, delegates_focus = delegates_focus,
		slot_assignment = slot_assignment == 1 ? .Manual : .Named, clonable = clonable, serializable = serializable,
	}
	root, err := dom.attach_shadow(d, h, init)
	if err != .None {
		if !dom.can_host_shadow(d, h) {
			return 0, fail(c, .Not_Supported, "Failed to execute 'attachShadow' on 'Element': This element does not support attachShadow")
		}
		return 0, fail(c, .Not_Supported, "Failed to execute 'attachShadow' on 'Element': Shadow root cannot be created on a host which already hosts a shadow tree.")
	}
	// DOM attachShadow: "available to element internals" for a custom element (or one that may become one)
	if info := dom.shadow_info(d, root); info != nil { info.available_to_internals = dom.is_valid_custom_element_name(n.name) }
	return u64(root), .None
}

CustomElements_disable :: proc(c: ^Call, name: string, shadow: bool, internals: bool) {
	s := shadow_state(c.page)
	bits := u8(0)
	if shadow { bits |= 1 }
	if internals { bits |= 2 }
	if name in s.disabled { s.disabled[name] = bits; return }
	if bits != 0 { s.disabled[strings.clone(name)] = bits }
}

@(private)
root_info :: proc(c: ^Call, root: Api_Node) -> ^dom.Shadow_Info {
	d := call_doc(c)
	if d == nil { return nil }
	return dom.shadow_info(d, H(root.handle))
}

ShadowRoot_mode :: proc(c: ^Call, root: Api_Node) -> string {
	info := root_info(c, root)
	return info != nil && info.mode == .Closed ? "closed" : "open"
}
ShadowRoot_delegatesFocus :: proc(c: ^Call, root: Api_Node) -> bool { info := root_info(c, root); return info != nil && info.delegates_focus }
ShadowRoot_clonable :: proc(c: ^Call, root: Api_Node) -> bool { info := root_info(c, root); return info != nil && info.clonable }
ShadowRoot_serializable :: proc(c: ^Call, root: Api_Node) -> bool { info := root_info(c, root); return info != nil && info.serializable }
ShadowRoot_slotAssignment :: proc(c: ^Call, root: Api_Node) -> string {
	info := root_info(c, root)
	return info != nil && info.slot_assignment == .Manual ? "manual" : "named"
}
ShadowRoot_host :: proc(c: ^Call, root: Api_Node) -> u64 {
	d := call_doc(c)
	if d == nil { return 0 }
	return u64(dom.host_of(d, H(root.handle)))
}

ShadowRoot_innerHTML :: proc(c: ^Call, root: Api_Node) -> string { return serialize_html(c.page.doc, H(root.handle), false) }

ShadowRoot_set_innerHTML :: proc(c: ^Call, root: Api_Node, value: string) -> Api_Error {
	d := c.page.doc
	r := H(root.handle)
	if !dom.is_shadow_root(d, r) { return fail(c, .Invalid_Handle, "not a shadow root") }
	frag, err := parse_fragment_for(c, dom.host_of(d, r), value)
	if err != .None { return err }
	replace_all(d, r, frag)
	dom.destroy_unpinned(d, frag)
	return .None
}

// DocumentOrShadowRoot.activeElement of a shadow root (HTML §6.6.2: the focused element retargeted against it).
ShadowRoot_activeElement :: proc(c: ^Call, root: Api_Node) -> u64 {
	p := c.page
	d := p.doc
	if p.formctl == nil { return 0 }
	f := page_forms(p).focus
	if f == base.NIL_HANDLE { return 0 }
	r := H(root.handle)
	t := dom.retarget(d, f, r)
	if dom.tree_root(d, t) != r { return 0 }
	return u64(t)
}

////////////////////////////////
// Markup

Node_getHTML :: proc(c: ^Call, node: Api_Node, serializable_roots: bool, roots: []u64) -> string {
	d := call_doc(c)
	if d == nil { return "" }
	rs := make([]base.Handle, len(roots), context.temp_allocator)
	for r, i in roots { rs[i] = H(r) }
	opts := Shadow_Serialize{serializable = serializable_roots, roots = rs}
	return serialize_html(d, H(node.handle), false, shadow = &opts)
}

Node_setHTMLUnsafe :: proc(c: ^Call, node: Api_Node, markup: string) -> Api_Error {
	d := c.page.doc
	h := H(node.handle)
	n := node.data
	ctx, target := h, h
	if n.is_shadow {
		ctx = dom.host_of(d, h)
	} else if n.kind == .Element && n.ns == .HTML && n.name == "template" {
		target = dom.template_content(d, h)
	} else if n.kind != .Element {
		return fail(c, .Invalid_Handle, "setHTMLUnsafe: not an element or a shadow root")
	}
	frag, err := parse_fragment_for(c, ctx, markup, declarative_shadow = true)
	if err != .None { return err }
	replace_all(d, target, frag)
	dom.destroy_unpinned(d, frag)
	return .None
}

// Document.parseHTMLUnsafe(html): the document is a fragment that stands for a document (as createHTMLDocument's):
// nothing of it loads or runs.
Document_parseHTMLUnsafeNode :: proc(c: ^Call, markup: string) -> (u64, Api_Error) {
	d := call_doc(c)
	if d == nil { return 0, fail(c, .Invalid_State, "no document") }
	f := dom.create_fragment(d)
	dom.get(d, f).as_document = true
	res := html.parse_into(d, f, transmute([]byte)markup, c.page.settings.dom.max_fragment_nodes)
	if !res.ok {
		dom.destroy_unpinned(d, f)
		return 0, fail(c, .Syntax, "the markup could not be parsed")
	}
	return u64(f), .None
}

Node_rootNodeComposed :: proc(c: ^Call, node: Api_Node, composed: bool) -> u64 {
	d := call_doc(c)
	if d == nil { return node.handle }
	return u64(dom.root_node(d, H(node.handle), composed))
}

////////////////////////////////
// Slots

// HTML "find a slot" with the open flag: a slot in a closed shadow root is not given away.
Slottable_assignedSlot :: proc(c: ^Call, node: Api_Node) -> u64 {
	d := call_doc(c)
	if d == nil { return 0 }
	s := dom.assigned_slot(d, H(node.handle))
	if s == base.NIL_HANDLE { return 0 }
	root := dom.containing_shadow_root(d, s)
	if info := dom.shadow_info(d, root); info == nil || info.mode == .Closed { return 0 }
	return u64(s)
}

HTMLSlotElement_assignedPacked :: proc(c: ^Call, slot: Api_Element, flatten: bool, elements: bool) -> []u8 {
	d := call_doc(c)
	if d == nil { return nil }
	list := dom.assigned_nodes(d, H(slot.handle), flatten)
	if elements {
		k := 0
		for x in list { if n := dom.get(d, x); n != nil && n.kind == .Element { list[k] = x; k += 1 } }
		list = list[:k]
	}
	return pack_handles(list)
}

HTMLSlotElement_assignNodes :: proc(c: ^Call, slot: Api_Element, nodes: []u64) -> Api_Error {
	d := call_doc(c)
	if d == nil { return fail(c, .Invalid_State, "no document") }
	hs := make([]base.Handle, len(nodes), context.temp_allocator)
	for x, i in nodes {
		n := dom.get(d, H(x))
		if n == nil || (n.kind != .Element && n.kind != .Text) { return fail(c, .Type, "Failed to execute 'assign' on 'HTMLSlotElement': parameter is not of type 'Element' or 'Text'.") }
		hs[i] = H(x)
	}
	if dom.slot_assign(d, H(slot.handle), hs) != .None { return fail(c, .Invalid_Handle, "not a slot") }
	return .None
}

Document_shadowIncludingByName :: proc(c: ^Call, name: string) -> []u8 {
	d := call_doc(c)
	if d == nil { return nil }
	out := make([dynamic]base.Handle, context.temp_allocator)
	for h := d.root; h != base.NIL_HANDLE; h = dom.next_shadow_including(d, h, d.root) {
		if n := dom.get(d, h); n.kind == .Element && n.name == name { append(&out, h) }
	}
	return pack_handles(out[:])
}

Node_shadowIncludingElements :: proc(c: ^Call, root: Api_Node) -> []u8 {
	d := call_doc(c)
	if d == nil { return nil }
	out := make([dynamic]base.Handle, context.temp_allocator)
	r := H(root.handle)
	for h := r; h != base.NIL_HANDLE; h = dom.next_shadow_including(d, h, r) {
		if n := dom.get(d, h); n.kind == .Element { append(&out, h) }
	}
	return pack_handles(out[:])
}

////////////////////////////////
// Events

Event_composedPathPacked :: proc(c: ^Call, event: Api_Event) -> []u8 {
	p := c.page
	path := dom.composed_path(&p.dp, H(event.handle))
	win := p.web != nil ? p.web.window : 0
	b := make([dynamic]u8, 0, 8 * len(path), context.temp_allocator)
	for h in path { put_u64(&b, h == base.NIL_HANDLE ? win : u64(h)) }
	return b[:]
}

EventTarget_lastTarget :: proc(c: ^Call) -> u64 {
	if c.page.jsdom == nil { return 0 }
	return c.page.jsdom.shadow.last_target
}

EventTarget_lastRelated :: proc(c: ^Call) -> u64 { return c.page.dp.last_related }

Event_setNextRelated :: proc(c: ^Call, related: u64) { shadow_state(c.page).next_related = related }

Event_relatedNow :: proc(c: ^Call, event: Api_Event) -> u64 { return event.data.related }

// (a plain handle: the events the engine makes itself, error events among them, are not the dispatcher's)
Event_inShadowTreeNow :: proc(c: ^Call, event: u64) -> bool {
	e := base.pool_get(&c.page.dp.events, base.Handle(event))
	if e == nil || e.phase == .None || e.path_index < 0 || e.path_index >= len(e.path) { return false }
	return e.path[e.path_index].in_shadow_tree
}

////////////////////////////////
// ElementInternals and custom states

@(private)
Internals :: struct {
	element: base.Handle,   // pinned while the object lives
}

@(private)
internals_vt := Object_VTable{name = "ElementInternals", destroy = proc(p: ^Page, data: rawptr) {
	it := (^Internals)(data)
	if !p.closed && p.doc != nil {
		if p.jsdom != nil { delete_key(&p.jsdom.shadow.internals, it.element) }
		dom.unpin(p.doc, it.element)
	}
	free(it)
}}

@(private)
internals_of :: proc(c: ^Call, h: u64) -> ^Internals {
	if call_doc(c) == nil { return nil }
	return (^Internals)(object_data(c.page, h, &internals_vt))
}

// HTML attachInternals(): a custom element (defined or about to be: the constructor of its definition) whose
// definition does not disable internals, once.
Element_attachInternals :: proc(c: ^Call, element: Api_Element) -> (u64, Api_Error) {
	p := c.page
	n := element.data
	if n.ns != .HTML || !dom.is_valid_custom_element_name(n.name) {
		return 0, fail(c, .Not_Supported, "Failed to execute 'attachInternals' on 'HTMLElement': Unable to attach ElementInternals to non-custom elements.")
	}
	s := shadow_state(p)
	if s.disabled[n.name] & 2 != 0 {
		return 0, fail(c, .Not_Supported, "Failed to execute 'attachInternals' on 'HTMLElement': ElementInternals is disabled by disabledFeature static field.")
	}
	h := H(element.handle)
	if h in s.internals {
		return 0, fail(c, .Not_Supported, "Failed to execute 'attachInternals' on 'HTMLElement': ElementInternals for the specified element was already attached.")
	}
	it := new(Internals)
	it.element = h
	dom.pin(p.doc, h)
	obj := object_create(p, &internals_vt, it, c.owner)
	s.internals[h] = obj
	return obj, .None
}

ElementInternals_shadowRootOf :: proc(c: ^Call, internals: u64) -> u64 {
	it := internals_of(c, internals)
	if it == nil { return 0 }
	root := dom.shadow_root_of(c.page.doc, it.element)
	if info := dom.shadow_info(c.page.doc, root); info == nil || !info.available_to_internals { return 0 }
	return u64(root)
}

ElementInternals_element :: proc(c: ^Call, internals: u64) -> u64 {
	it := internals_of(c, internals)
	return it != nil ? u64(it.element) : 0
}

CustomStates_add :: proc(c: ^Call, internals: u64, state: string) {
	if it := internals_of(c, internals); it != nil { dom.custom_state_set(c.page.doc, it.element, state, true) }
}

CustomStates_delete :: proc(c: ^Call, internals: u64, state: string) -> bool {
	it := internals_of(c, internals)
	return it != nil && dom.custom_state_set(c.page.doc, it.element, state, false)
}

CustomStates_has :: proc(c: ^Call, internals: u64, state: string) -> bool {
	it := internals_of(c, internals)
	return it != nil && dom.custom_state_has(c.page.doc, it.element, state)
}

CustomStates_clear :: proc(c: ^Call, internals: u64) {
	it := internals_of(c, internals)
	if it == nil { return }
	d := c.page.doc
	list := make([dynamic]string, context.temp_allocator)
	for s in dom.custom_states(d, it.element) { append(&list, strings.clone(s, context.temp_allocator)) }
	for s in list { dom.custom_state_set(d, it.element, s, false) }
}

CustomStates_list :: proc(c: ^Call, internals: u64) -> string {
	it := internals_of(c, internals)
	if it == nil { return "" }
	b := strings.builder_make(context.temp_allocator)
	for s in dom.custom_states(c.page.doc, it.element) { strings.write_string(&b, s); strings.write_byte(&b, 0) }
	return strings.to_string(b)
}

DocumentOrShadowRoot_adopt :: proc(c: ^Call, root: Api_Node, sheets: []u64) -> Api_Error {
	p := c.page
	d := call_doc(c)
	if d == nil || p.engine == nil { return fail(c, .Invalid_State, "no document") }
	ids := make([]u64, len(sheets), context.temp_allocator)
	for h, i in sheets {
		s := css_sheet_of(c, h)
		if s == nil || s.owner != base.NIL_HANDLE { return fail(c, .Not_Allowed, "Failed to set the 'adoptedStyleSheets' property: Can't adopt non-constructed stylesheets.") }
		ids[i] = s.id
	}
	r := H(root.handle)
	document := r == d.root
	if !document && !dom.is_shadow_root(d, r) { return fail(c, .Invalid_Handle, "not a document or a shadow root") }
	style.engine_set_adopted(p.engine, r, ids, document)
	return .None
}

Node_isLive :: proc(c: ^Call, node: u64) -> bool {
	d := call_doc(c)
	return d != nil && dom.get(d, H(node)) != nil
}
