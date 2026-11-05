package page

// Custom elements (HTML §4.13), the browser's half. The registry, the definitions and the reactions' callbacks live in
// the engine (native/js/prelude/customelements.js, runtime/custom_elements.c); here the browser keeps what the DOM must
// know: the local names that have a definition, each element's custom element state, and the queue of reactions the
// DOM's mutations cause:
//   * upgrade: an element with a defined name and no state yet was created by createElement, or inserted (by the
//     parser, innerHTML, a script);
//   * connected / disconnected: a custom element entered / left the document;
//   * attribute changed: an attribute of a custom element changed (the engine keeps those its definition observes);
//   * a form-associated custom element's form owner changed, it became disabled or enabled, its form was reset (package
//     forms tells them: forms_face_callback).
// The queue is drained by the engine (`wj_ce_process`) at the end of the browser call that filled it ([CEReactions]:
// api_end, in every generated host function), at each microtask checkpoint, and after the parser inserted nodes.
// Nothing of this runs before a page defines its first custom element: the mutation hook is off until then.

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:forms"

CE_UPGRADE      :: u8(1)
CE_CONNECTED    :: u8(2)
CE_DISCONNECTED :: u8(3)
CE_ATTRIBUTE    :: u8(4)
CE_ADOPTED      :: u8(5)
CE_FORM_ASSOCIATED :: u8(6)
CE_FORM_DISABLED   :: u8(7)
CE_FORM_RESET      :: u8(8)

// Element states (HTML "custom element state"): no entry = "undefined" (or not a custom element at all).
CE_STATE_CUSTOM :: u8(1)
CE_STATE_FAILED :: u8(2)

@(private) CE_MAX_DEPTH :: 64   // nested drains (reactions making reactions); deeper ones wait for the outer drain

Custom_Elements :: struct {
	defined: map[string]bool,           // owned keys; true: the definition is form-associated
	state:   map[base.Handle]u8,
	queue:   [dynamic]Ce_Reaction,
	depth:   int,                       // nested drains: a reaction's own DOM calls run what they queue before they return
	moved_in: map[base.Handle]u64,      // custom elements moved here from another document: the page whose realm defined them
}

@(private)
Ce_Reaction :: struct {
	kind:             u8,
	element:          base.Handle,   // pinned while queued
	name, old, value: string,        // attribute changes: owned
	has_old, has_new: bool,
	old_doc, new_doc: base.Handle,   // adoption (frames_access.odin)
	form:             base.Handle,   // form associated: the new form owner (pinned while queued), NIL for none
	disabled:         bool,          // form disabled: the new disabledness
}

// The document of a reaction's element: a queue may hold an element moved to another document (its definition stays in this realm).
@(private)
ce_doc_of :: proc(p: ^Page, h: base.Handle) -> ^dom.Document {
	if p.closed { return nil }
	if base.handle_tag(u64(h)) == p.tag { return p.doc }
	t := frames_reach_tag(p, base.handle_tag(u64(h)))
	return t != nil ? t.doc : nil
}

// The page whose realm reacts for an element of `p`: `p`, or the one that defined it, when it was moved here.
@(private)
ce_reacting_page :: proc(p: ^Page, ce: ^Custom_Elements, h: base.Handle) -> ^Page {
	if owner, moved := ce.moved_in[h]; moved { return frames_page_by_id(p, owner) }
	return p
}

@(private)
ce_of :: proc(p: ^Page) -> ^Custom_Elements { return p.jsdom != nil ? &p.jsdom.ce : nil }

@(private)
ce_destroy :: proc(p: ^Page, ce: ^Custom_Elements) {
	for k in ce.defined { delete(k) }
	delete(ce.defined)
	delete(ce.state)
	delete(ce.moved_in)
	for &r in ce.queue { ce_reaction_free(p, &r) }
	delete(ce.queue)
	ce^ = {}
}

@(private)
ce_reaction_free :: proc(p: ^Page, r: ^Ce_Reaction) {
	if d := ce_doc_of(p, r.element); d != nil {
		dom.unpin(d, r.element)
		if r.form != base.NIL_HANDLE { dom.unpin(d, r.form) }
	}
	delete(r.name); delete(r.old); delete(r.value)
}

@(private)
ce_queue :: proc(p: ^Page, ce: ^Custom_Elements, r: Ce_Reaction) {
	if _, moved := ce.moved_in[r.element]; moved {
		// an element moved here reacts in the realm that defined it: its queue, its next checkpoint if it is not running
		owner := ce_reacting_page(p, ce, r.element)
		if owner == nil || owner.jsdom == nil || !dom.pin(p.doc, r.element) { return }
		if r.form != base.NIL_HANDLE { dom.pin(p.doc, r.form) }
		append(&owner.jsdom.ce.queue, r)
		if owner.objects.depth == 0 { host_post_checkpoint(owner) }
		return
	}
	d := ce_doc_of(p, r.element)
	if d == nil || !dom.pin(d, r.element) { return }
	if r.form != base.NIL_HANDLE { dom.pin(d, r.form) }
	append(&ce.queue, r)
}

// The reactions an insertion or a removal causes, for every element of the subtree.
@(private)
ce_walk :: proc(p: ^Page, ce: ^Custom_Elements, d: ^dom.Document, root: base.Handle, inserted, connected: bool, upgrade := true) {
	// shadow-including: the custom elements of shadow trees enter and leave the document with their hosts
	for h := root; h != base.NIL_HANDLE; h = dom.next_shadow_including(d, h, root) {
		n := dom.get(d, h)
		if n == nil || n.kind != .Element { continue }
		if _, moved := ce.moved_in[h]; !moved && !(n.name in ce.defined) { continue }
		st := ce.state[h]
		switch {
		case inserted && st == 0: if upgrade { ce_queue(p, ce, Ce_Reaction{kind = CE_UPGRADE, element = h}) }
		case inserted && st == CE_STATE_CUSTOM && connected: ce_queue(p, ce, Ce_Reaction{kind = CE_CONNECTED, element = h})
		case !inserted && st == CE_STATE_CUSTOM && connected: ce_queue(p, ce, Ce_Reaction{kind = CE_DISCONNECTED, element = h})
		}
	}
}

// The document's mutation hook, custom elements' part (js_dom_observe.odin installs it).
@(private)
ce_mutation :: proc(p: ^Page, d: ^dom.Document, e: ^dom.Journal_Entry) {
	ce := ce_of(p)
	if ce == nil || (len(ce.defined) == 0 && len(ce.moved_in) == 0) { return }
	#partial switch e.kind {
	case .Insert:
		root := dom.shadow_including_root(d, e.node)
		rn := dom.get(d, root)
		if rn == nil { return }
		// another document (the templates' inert one, createHTMLDocument's, new Document()): a node in it is connected, so
		// an element that is already custom gets its connectedCallback (its definition goes with it), but nothing is
		// upgraded there: such a document has no custom element registry (HTML "look up a custom element definition")
		if rn.as_document {
			ce_walk(p, ce, d, e.node, true, true, upgrade = false)
			return
		}
		// template contents belong to an inert document: no definition applies there
		if rn.kind == .Fragment && rn.held { return }
		// a script's insertion into a tree that is not the document's reacts to nothing (HTML "insert": only a connected
		// node is upgraded or connected); the parser's fragments are upgraded where they were made (innerHTML)
		if root != d.root && d.parser_inserting == 0 { return }
		ce_walk(p, ce, d, e.node, true, root == d.root)
	case .Remove:
		if e.parent == base.NIL_HANDLE { return }
		root := dom.shadow_including_root(d, e.parent)
		if rn := dom.get(d, root); root == d.root || (rn != nil && rn.as_document) { ce_walk(p, ce, d, e.node, false, true) }
	case .Attribute:
		if ce.state[e.node] == CE_STATE_CUSTOM {
			cur, has := dom.get_attribute(d, e.node, e.name)
			ce_queue(p, ce, Ce_Reaction{
				kind = CE_ATTRIBUTE, element = e.node, name = strings.clone(e.name),
				old = strings.clone(e.old), has_old = e.had_old, value = strings.clone(cur), has_new = has,
			})
		}
	}
}

// The document's mutation hook, form-associated custom elements' part: their form owners and disabledness after an
// insertion, a removal, a form, id or disabled attribute's change (not after a style attribute an animation writes).
@(private)
face_mutation :: proc(p: ^Page, d: ^dom.Document, e: ^dom.Journal_Entry) {
	if d != p.doc { return }
	#partial switch e.kind {
	case .Insert, .Remove:
	case .Attribute: if e.name != "form" && e.name != "id" && e.name != "disabled" { return }
	case: return
	}
	forms.face_sync(p.formctl.model)
}

// A form-associated custom element's callback is due (package forms): its reaction.
@(private)
forms_face_callback :: proc(user: rawptr, h: base.Handle, cb: forms.Face_Callback, form: base.Handle) {
	p := (^Page)(user)
	ce := ce_of(p)
	if ce == nil { return }
	switch cb {
	case .Associated: ce_queue(p, ce, Ce_Reaction{kind = CE_FORM_ASSOCIATED, element = h, form = form})
	case .Disabled:   ce_queue(p, ce, Ce_Reaction{kind = CE_FORM_DISABLED, element = h, disabled = true})
	case .Enabled:    ce_queue(p, ce, Ce_Reaction{kind = CE_FORM_DISABLED, element = h})
	case .Reset:      ce_queue(p, ce, Ce_Reaction{kind = CE_FORM_RESET, element = h})
	}
}

// The element became custom: a form-associated one is a control of the forms model from now on.
@(private)
ce_became_custom :: proc(p: ^Page, ce: ^Custom_Elements, h: base.Handle) {
	n := dom.get(p.doc, h)
	if n == nil || !ce.defined[n.name] || p.formctl == nil { return }
	forms.face_add(p.formctl.model, h)
}

// Runs the queued reactions in the engine ([CEReactions]: at the end of the browser call that queued them).
custom_elements_flush :: proc(p: ^Page) {
	ce := ce_of(p)
	if ce == nil || len(ce.queue) == 0 || ce.depth >= CE_MAX_DEPTH { return }
	r := p.js
	if r == nil || r.failed || r.inst == nil || r.inst.dead || p.closed {
		for &x in ce.queue { ce_reaction_free(p, &x) }
		clear(&ce.queue)
		return
	}
	// the engine takes the queue until it is empty. A reaction's own DOM calls (a connectedCallback appending a template's
	// content) are [CEReactions] calls too: what they queue runs when they return (a nested drain: the specification's stack
	// of element queues), so that the elements they made are upgraded before the callback goes on.
	ce.depth += 1
	defer ce.depth -= 1
	js_call(p, r.inst, "wj_ce_process", nil)
}

// At the end of every generated host function: the reactions a [CEReactions] operation queued run before it returns.
// Only those of this call: a call made while the engine cannot run script (its garbage collector unpinning nodes) never
// queues any, and reactions queued outside script (the parser, the user) wait for the microtask checkpoint.
api_end :: #force_inline proc(c: ^Call) {
	if c.page != nil && c.page.jsdom != nil && len(c.page.jsdom.ce.queue) > c.ce_mark && !c.hold_reactions { custom_elements_flush(c.page) }
}

CustomElements_define :: proc(c: ^Call, name: string, form_associated: bool) {
	ce := &js_dom_state(c.page).ce
	if !(name in ce.defined) { ce.defined[strings.clone(name)] = form_associated }
	mo_hook_update(c.page)
}

// The bytes CustomElements_take would write now.
CustomElements_pending :: proc(c: ^Call) -> u32 {
	ce := ce_of(c.page)
	if ce == nil { return 0 }
	n := 0
	for r in ce.queue {
		n += 9
		switch r.kind {
		case CE_ATTRIBUTE: n += 13 + len(r.name) + len(r.old) + len(r.value)
		case CE_ADOPTED: n += 16
		case CE_FORM_ASSOCIATED: n += 8
		case CE_FORM_DISABLED: n += 1
		}
	}
	return u32(n)
}

// The queued reactions, taken: per reaction u8 kind, u64 element, then for an attribute change u32 + bytes for the
// name, the old value and the new one, and a u8 of flags (1: there was an old value, 2: there is a new one); for an
// adoption the two Document nodes; for a form owner's change the form (0: none); for a disabledness change a u8 (1:
// disabled).
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
		if r.kind == CE_ADOPTED {
			put_u64(&b, u64(r.old_doc))
			put_u64(&b, u64(r.new_doc))
		}
		if r.kind == CE_FORM_ASSOCIATED { put_u64(&b, u64(r.form)) }
		if r.kind == CE_FORM_DISABLED { put_u8(&b, r.disabled ? 1 : 0) }
		// the engine wraps the element (and the form) before anything can free it: its wrapper pins it from then on
		if ed := ce_doc_of(c.page, r.element); ed != nil {
			dom.pin(ed, r.element)
			if r.form != base.NIL_HANDLE { dom.pin(ed, r.form) }
		}
		ce_reaction_free(c.page, &r)
	}
	clear(&ce.queue)
	return b[:]
}

// The engine wrapped the elements of the last take: the pins the take added for that time go.
CustomElements_release :: proc(c: ^Call, elements: []u64) {
	if call_doc(c) == nil { return }
	for h in elements { if d := ce_doc_of(c.page, H(h)); d != nil { dom.unpin(d, H(h)) } }
}

// A new element of a defined name made by a constructor (new MyElement()): already custom, no upgrade queued.
CustomElements_create :: proc(c: ^Call, name: string) -> (u64, Api_Error) {
	d := call_doc(c)
	if d == nil { return 0, fail(c, .Invalid_State, "no document") }
	h := dom.create_element_ns(d, name, .HTML)
	ce := &js_dom_state(c.page).ce
	ce.state[h] = CE_STATE_CUSTOM
	dom.custom_element_set_defined(d, h, true)
	ce_became_custom(c.page, ce, h)
	return u64(h), .None
}

Element_setCustomState :: proc(c: ^Call, element: Api_Element, state: u32) {
	ce := &js_dom_state(c.page).ce
	h := H(element.handle)
	if state == 0 { delete_key(&ce.state, h) } else { ce.state[h] = u8(state) }
	dom.custom_element_set_defined(c.page.doc, h, state == u32(CE_STATE_CUSTOM))
	if state == u32(CE_STATE_CUSTOM) { ce_became_custom(c.page, ce, h) }
}

// A clone made in the document's own realm (cloneNode of a node of the document, importNode): its elements of a defined
// name are upgraded before the call returns, in tree order, as Polymer's template stamping (importNode) expects.
custom_elements_cloned :: proc(p: ^Page, h: base.Handle) {
	ce := ce_of(p)
	if ce == nil || len(ce.defined) == 0 { return }
	ce_walk(p, ce, p.doc, h, true, false)
}

// document.createElement(name) of a defined name: the element is upgraded before createElement returns.
custom_elements_created :: proc(p: ^Page, h: base.Handle) {
	ce := ce_of(p)
	if ce == nil || len(ce.defined) == 0 { return }
	n := dom.get(p.doc, h)
	if n == nil || !(n.name in ce.defined) || ce.state[h] != 0 { return }
	ce_queue(p, ce, Ce_Reaction{kind = CE_UPGRADE, element = h})
}
