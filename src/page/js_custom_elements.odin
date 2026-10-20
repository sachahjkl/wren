package page

// Custom elements (HTML §4.13), the browser's half. The registry, the definitions and the reactions' callbacks live in
// the engine (native/js/prelude/customelements.js, runtime/custom_elements.c); here the browser keeps what the DOM must
// know: the local names that have a definition, each element's custom element state, and the queue of reactions the
// DOM's mutations cause:
//   * upgrade: an element with a defined name and no state yet was created by createElement, or inserted (by the
//     parser, innerHTML, a script);
//   * connected / disconnected: a custom element entered / left the document;
//   * attribute changed: an attribute of a custom element changed (the engine keeps those its definition observes).
// The queue is drained by the engine (`wj_ce_process`) at the end of the browser call that filled it ([CEReactions]:
// api_end, in every generated host function), at each microtask checkpoint, and after the parser inserted nodes.
// Nothing of this runs before a page defines its first custom element: the mutation hook is off until then.

import "core:strings"
import "wb:base"
import "wb:dom"

CE_UPGRADE      :: u8(1)
CE_CONNECTED    :: u8(2)
CE_DISCONNECTED :: u8(3)
CE_ATTRIBUTE    :: u8(4)

// Element states (HTML "custom element state"): no entry = "undefined" (or not a custom element at all).
CE_STATE_CUSTOM :: u8(1)
CE_STATE_FAILED :: u8(2)

Custom_Elements :: struct {
	defined: map[string]bool,           // owned keys
	state:   map[base.Handle]u8,
	queue:   [dynamic]Ce_Reaction,
	flushing: bool,
}

@(private)
Ce_Reaction :: struct {
	kind:             u8,
	element:          base.Handle,   // pinned while queued
	name, old, value: string,        // attribute changes: owned
	has_old, has_new: bool,
}

@(private)
ce_of :: proc(p: ^Page) -> ^Custom_Elements { return p.jsdom != nil ? &p.jsdom.ce : nil }

@(private)
ce_destroy :: proc(p: ^Page, ce: ^Custom_Elements) {
	for k in ce.defined { delete(k) }
	delete(ce.defined)
	delete(ce.state)
	for &r in ce.queue { ce_reaction_free(p, &r) }
	delete(ce.queue)
	ce^ = {}
}

@(private)
ce_reaction_free :: proc(p: ^Page, r: ^Ce_Reaction) {
	if !p.closed && p.doc != nil { dom.unpin(p.doc, r.element) }
	delete(r.name); delete(r.old); delete(r.value)
}

@(private)
ce_queue :: proc(p: ^Page, ce: ^Custom_Elements, r: Ce_Reaction) {
	if !dom.pin(p.doc, r.element) { return }
	append(&ce.queue, r)
}

// The reactions an insertion or a removal causes, for every element of the subtree.
@(private)
ce_walk :: proc(p: ^Page, ce: ^Custom_Elements, d: ^dom.Document, root: base.Handle, inserted, connected: bool) {
	// shadow-including: the custom elements of shadow trees enter and leave the document with their hosts
	for h := root; h != base.NIL_HANDLE; h = dom.next_shadow_including(d, h, root) {
		n := dom.get(d, h)
		if n == nil || n.kind != .Element || !(n.name in ce.defined) { continue }
		st := ce.state[h]
		switch {
		case inserted && st == 0: ce_queue(p, ce, Ce_Reaction{kind = CE_UPGRADE, element = h})
		case inserted && st == CE_STATE_CUSTOM && connected: ce_queue(p, ce, Ce_Reaction{kind = CE_CONNECTED, element = h})
		case !inserted && st == CE_STATE_CUSTOM && connected: ce_queue(p, ce, Ce_Reaction{kind = CE_DISCONNECTED, element = h})
		}
	}
}

// The document's mutation hook, custom elements' part (js_dom_observe.odin installs it).
@(private)
ce_mutation :: proc(p: ^Page, d: ^dom.Document, e: ^dom.Journal_Entry) {
	ce := ce_of(p)
	if ce == nil || len(ce.defined) == 0 { return }
	#partial switch e.kind {
	case .Insert:
		// template contents belong to an inert document: no definition applies there
		root := dom.shadow_including_root(d, e.node)
		if rn := dom.get(d, root); rn != nil && rn.kind == .Fragment && rn.held { return }
		ce_walk(p, ce, d, e.node, true, root == d.root)
	case .Remove:
		if e.parent != base.NIL_HANDLE && dom.is_connected(d, e.parent) { ce_walk(p, ce, d, e.node, false, true) }
	case .Attribute:
		if ce.state[e.node] != CE_STATE_CUSTOM { return }
		cur, has := dom.get_attribute(d, e.node, e.name)
		ce_queue(p, ce, Ce_Reaction{
			kind = CE_ATTRIBUTE, element = e.node, name = strings.clone(e.name),
			old = strings.clone(e.old), has_old = e.had_old, value = strings.clone(cur), has_new = has,
		})
	}
}

// Runs the queued reactions in the engine ([CEReactions]: at the end of the browser call that queued them).
custom_elements_flush :: proc(p: ^Page) {
	ce := ce_of(p)
	if ce == nil || len(ce.queue) == 0 || ce.flushing { return }
	r := p.js
	if r == nil || r.failed || r.inst == nil || r.inst.dead || p.closed {
		for &x in ce.queue { ce_reaction_free(p, &x) }
		clear(&ce.queue)
		return
	}
	// a reaction that queues more (a constructor appending children) is served by the same drain: the engine takes
	// the queue until it is empty
	ce.flushing = true
	defer ce.flushing = false
	js_call(p, r.inst, "wj_ce_process", nil)
}

// At the end of every generated host function: the reactions a [CEReactions] operation queued run before it returns.
// Only those of this call: a call made while the engine cannot run script (its garbage collector unpinning nodes) never
// queues any, and reactions queued outside script (the parser, the user) wait for the microtask checkpoint.
api_end :: #force_inline proc(c: ^Call) {
	if c.page != nil && c.page.jsdom != nil && len(c.page.jsdom.ce.queue) > c.ce_mark { custom_elements_flush(c.page) }
}

CustomElements_define :: proc(c: ^Call, name: string) {
	ce := &js_dom_state(c.page).ce
	if !(name in ce.defined) { ce.defined[strings.clone(name)] = true }
	mo_hook_update(c.page)
}

// The bytes CustomElements_take would write now.
CustomElements_pending :: proc(c: ^Call) -> u32 {
	ce := ce_of(c.page)
	if ce == nil { return 0 }
	n := 0
	for r in ce.queue { n += 9 + (r.kind == CE_ATTRIBUTE ? 13 + len(r.name) + len(r.old) + len(r.value) : 0) }
	return u32(n)
}

// The queued reactions, taken: per reaction u8 kind, u64 element, then for an attribute change u32 + bytes for the
// name, the old value and the new one, and a u8 of flags (1: there was an old value, 2: there is a new one).
CustomElements_take :: proc(c: ^Call) -> []u8 {
	ce := ce_of(c.page)
	if ce == nil || len(ce.queue) == 0 { return nil }
	b := make([dynamic]u8, 0, 16 * len(ce.queue), context.temp_allocator)
	d := c.page.doc
	for &r in ce.queue {
		// an element that ended in a template's contents (innerHTML parses into a fragment first) is in an inert
		// document: no definition applies there
		if r.kind == CE_UPGRADE {
			if rn := dom.get(d, dom.shadow_including_root(d, r.element)); rn == nil || (rn.kind == .Fragment && rn.held) {
				ce_reaction_free(c.page, &r)
				continue
			}
		}
		put_u8(&b, r.kind)
		put_u64(&b, u64(r.element))
		if r.kind == CE_ATTRIBUTE {
			put_str(&b, r.name); put_str(&b, r.old); put_str(&b, r.value)
			put_u8(&b, (r.has_old ? 1 : 0) | (r.has_new ? 2 : 0))
		}
		// the engine wraps the element before anything can free it: its wrapper pins it from then on
		dom.pin(c.page.doc, r.element)
		ce_reaction_free(c.page, &r)
	}
	clear(&ce.queue)
	return b[:]
}

// The engine wrapped the elements of the last take: the pins the take added for that time go.
CustomElements_release :: proc(c: ^Call, elements: []u64) {
	d := call_doc(c)
	if d == nil { return }
	for h in elements { dom.unpin(d, H(h)) }
}

// A new element of a defined name made by a constructor (new MyElement()): already custom, no upgrade queued.
CustomElements_create :: proc(c: ^Call, name: string) -> (u64, Api_Error) {
	d := call_doc(c)
	if d == nil { return 0, fail(c, .Invalid_State, "no document") }
	h := dom.create_element_ns(d, name, .HTML)
	js_dom_state(c.page).ce.state[h] = CE_STATE_CUSTOM
	dom.custom_element_set_defined(d, h, true)
	return u64(h), .None
}

Element_setCustomState :: proc(c: ^Call, element: Api_Element, state: u32) {
	ce := &js_dom_state(c.page).ce
	h := H(element.handle)
	if state == 0 { delete_key(&ce.state, h) } else { ce.state[h] = u8(state) }
	dom.custom_element_set_defined(c.page.doc, h, state == u32(CE_STATE_CUSTOM))
}

// document.createElement(name) of a defined name: the element is upgraded before createElement returns.
custom_elements_created :: proc(p: ^Page, h: base.Handle) {
	ce := ce_of(p)
	if ce == nil || len(ce.defined) == 0 { return }
	n := dom.get(p.doc, h)
	if n == nil || !(n.name in ce.defined) || ce.state[h] != 0 { return }
	ce_queue(p, ce, Ce_Reaction{kind = CE_UPGRADE, element = h})
}
