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
import "wb:css"
import "wb:dom"
import "wb:html"
import "wb:style"
import "wb:wasm"

Js_Shadow :: struct {
	signal:        [dynamic]base.Handle,   // slots to fire slotchange at (pinned while listed)
	disabled:      map[string]u8,          // custom element names whose definition disables: 1 shadow, 2 internals
	internals:     map[base.Handle]u64,    // elements that attached internals -> their ElementInternals
	last_target:   u64,                    // EventTarget_lastTarget
}

@(private)
shadow_state :: proc(p: ^Page) -> ^Js_Shadow { return &js_dom_state(p).shadow }

@(private)
js_shadow_destroy :: proc(p: ^Page, s: ^Js_Shadow) {
	if !p.closed && p.doc != nil { for h in s.signal { dom.unpin(p.doc, h) } }
	delete(s.signal)
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

Shadow_fireSlotChanges :: proc(c: ^Call) { shadow_signal_slots(c.page) }

// Fires slotchange at the signalled slots (from the microtask checkpoint). Returns whether it fired any.
shadow_signal_slots :: proc(p: ^Page) -> bool {
	if p.jsdom == nil || len(p.jsdom.shadow.signal) == 0 || p.closed { return false }
	s := &p.jsdom.shadow
	list := make([dynamic]base.Handle, 0, len(s.signal), context.temp_allocator)
	append(&list, ..s.signal[:])
	clear(&s.signal)
	for slot in list {
		if dom.get(p.doc, slot) != nil { dispatch_event(p, slot, dom.Event{type = "slotchange", bubbles = true}) }
		dom.unpin(p.doc, slot)
	}
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

////////////////////////////////
// Constructable stylesheets (CSSOM §6.1.2)

@(private)
Css_Sheet :: struct {
	id:    u64,                // the engine's sheet
	rules: [dynamic]string,    // the text of each top-level rule (cssRules)
	media: string,
}

@(private)
css_sheet_vt := Object_VTable{name = "CSSStyleSheet", destroy = proc(p: ^Page, data: rawptr) {
	s := (^Css_Sheet)(data)
	if !p.closed && p.engine != nil { style.engine_constructed_destroy(p.engine, s.id) }
	for r in s.rules { delete(r) }
	delete(s.rules)
	delete(s.media)
	free(s)
}}

@(private)
css_sheet_of :: proc(c: ^Call, h: u64) -> ^Css_Sheet {
	if c.page.engine == nil { return nil }
	return (^Css_Sheet)(object_data(c.page, h, &css_sheet_vt))
}

// The top-level rules of a stylesheet's text, as written (the source of each, trimmed): what cssRules lists.
// Strings, comments and nested blocks are skipped over; a rule ends at its block's closing brace, or at a semicolon
// for a statement at-rule.
@(private)
split_rules :: proc(text: string, allocator := context.temp_allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	depth, start := 0, 0
	i := 0
	for i < len(text) {
		ch := text[i]
		switch {
		case ch == '/' && i + 1 < len(text) && text[i + 1] == '*':
			end := strings.index(text[i + 2:], "*/")
			if start == i && depth == 0 { start = end < 0 ? len(text) : i + 2 + end + 2 }   // a comment before a rule
			i = end < 0 ? len(text) : i + 2 + end + 2
			continue
		case ch == '"' || ch == '\'':
			i += 1
			for i < len(text) && text[i] != ch {
				if text[i] == '\\' { i += 1 }
				i += 1
			}
		case ch == '{': depth += 1
		case ch == '}':
			depth -= 1
			if depth <= 0 {
				depth = 0
				if r := strings.trim_space(text[start:i + 1]); r != "" { append(&out, r) }
				start = i + 1
			}
		case ch == ';' && depth == 0:
			if r := strings.trim_space(text[start:i + 1]); r != "" { append(&out, r) }
			start = i + 1
		}
		i += 1
	}
	if r := strings.trim_space(text[min(start, len(text)):]); r != "" { append(&out, r) }
	return out
}

@(private)
is_import_rule :: proc(r: string) -> bool { return len(r) >= 7 && strings.equal_fold(r[:7], "@import") }

// The sheet's rules joined, given to the engine.
@(private)
css_sheet_commit :: proc(p: ^Page, s: ^Css_Sheet) {
	style.engine_constructed_replace(p.engine, s.id, strings.join(s.rules[:], "\n", context.temp_allocator))
}

CSSStyleSheet_create :: proc(c: ^Call, media: string, disabled: bool, base_url: string) -> u64 {
	p := c.page
	if p.engine == nil { return 0 }
	s := new(Css_Sheet)
	s.media = strings.clone(media)
	s.id = style.engine_constructed_create(p.engine, "", media, base_url != "" ? base_url : p.env.location.href)
	if disabled { style.engine_constructed_set_disabled(p.engine, s.id, true) }
	return object_create(p, &css_sheet_vt, s, c.owner)
}

CSSStyleSheet_replaceText :: proc(c: ^Call, sheet: u64, text: string) -> Api_Error {
	s := css_sheet_of(c, sheet)
	if s == nil { return fail(c, .Invalid_Handle, "not a constructed stylesheet") }
	for r in s.rules { delete(r) }
	clear(&s.rules)
	for r in split_rules(text) {
		if is_import_rule(r) { continue }   // replace() and replaceSync() ignore @import (CSSOM §6.1.2)
		append(&s.rules, strings.clone(r))
	}
	css_sheet_commit(c.page, s)
	return .None
}

CSSStyleSheet_ruleCount :: proc(c: ^Call, sheet: u64) -> u32 {
	s := css_sheet_of(c, sheet)
	return s != nil ? u32(len(s.rules)) : 0
}

CSSStyleSheet_ruleText :: proc(c: ^Call, sheet: u64, index: u32) -> (string, Api_Error) {
	s := css_sheet_of(c, sheet)
	if s == nil || int(index) >= len(s.rules) { return "", fail(c, .Index_Size, "The index is past the end of the rule list.") }
	return s.rules[index], .None
}

CSSStyleSheet_insertRuleAt :: proc(c: ^Call, sheet: u64, rule: string, index: u32) -> (u32, Api_Error) {
	s := css_sheet_of(c, sheet)
	if s == nil { return 0, fail(c, .Invalid_Handle, "not a constructed stylesheet") }
	if int(index) > len(s.rules) { return 0, fail(c, .Index_Size, "Failed to execute 'insertRule' on 'CSSStyleSheet': The index provided is larger than the maximum index.") }
	parts := split_rules(rule)
	if len(parts) != 1 { return 0, fail(c, .Syntax, "Failed to execute 'insertRule' on 'CSSStyleSheet': Failed to parse the rule.") }
	if is_import_rule(parts[0]) { return 0, fail(c, .Syntax, "Failed to execute 'insertRule' on 'CSSStyleSheet': Can't insert @import rules into a constructed stylesheet.") }
	parsed := css.parse_stylesheet(parts[0], style.parse_options(&c.page.engine.settings))
	defer { css.stylesheet_destroy(parsed); free(parsed) }
	if len(parsed.rules) != 1 { return 0, fail(c, .Syntax, "Failed to execute 'insertRule' on 'CSSStyleSheet': Failed to parse the rule.") }
	inject_at(&s.rules, int(index), strings.clone(parts[0]))
	css_sheet_commit(c.page, s)
	return index, .None
}

CSSStyleSheet_deleteRuleAt :: proc(c: ^Call, sheet: u64, index: u32) -> Api_Error {
	s := css_sheet_of(c, sheet)
	if s == nil { return fail(c, .Invalid_Handle, "not a constructed stylesheet") }
	if int(index) >= len(s.rules) { return fail(c, .Index_Size, "Failed to execute 'deleteRule' on 'CSSStyleSheet': The index provided is larger than the maximum index.") }
	delete(s.rules[index])
	ordered_remove(&s.rules, int(index))
	css_sheet_commit(c.page, s)
	return .None
}

CSSStyleSheet_isDisabled :: proc(c: ^Call, sheet: u64) -> bool {
	s := css_sheet_of(c, sheet)
	if s == nil { return false }
	sh := style.engine_find_sheet(c.page.engine, s.id)
	return sh != nil && sh.disabled
}

CSSStyleSheet_setDisabled :: proc(c: ^Call, sheet: u64, disabled: bool) {
	if s := css_sheet_of(c, sheet); s != nil { style.engine_constructed_set_disabled(c.page.engine, s.id, disabled) }
}

CSSStyleSheet_mediaText :: proc(c: ^Call, sheet: u64) -> string {
	s := css_sheet_of(c, sheet)
	return s != nil ? s.media : ""
}

CSSStyleSheet_setMediaText :: proc(c: ^Call, sheet: u64, media: string) {
	s := css_sheet_of(c, sheet)
	if s == nil { return }
	delete(s.media)
	s.media = strings.clone(media)
	style.engine_constructed_set_media(c.page.engine, s.id, media)
}

CSSStyleSheet_isConstructed :: proc(c: ^Call, sheet: u64) -> bool { return css_sheet_of(c, sheet) != nil }

DocumentOrShadowRoot_adopt :: proc(c: ^Call, root: Api_Node, sheets: []u64) -> Api_Error {
	p := c.page
	d := call_doc(c)
	if d == nil || p.engine == nil { return fail(c, .Invalid_State, "no document") }
	ids := make([]u64, len(sheets), context.temp_allocator)
	for h, i in sheets {
		s := css_sheet_of(c, h)
		if s == nil { return fail(c, .Not_Allowed, "Failed to set the 'adoptedStyleSheets' property: Can't adopt non-constructed stylesheets.") }
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
