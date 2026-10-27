package page

// The web platform as Wasm imports: implementations of modules "dom" and "events" (api/dom.widl, api/events.widl).
// Every import is described in api/*.widl; src/tools/bindgen generates its trampoline (api_generated.odin), which
// checks the guest's pointers, strings, handles and enums, and calls the implementation here with Odin values. The
// other modules live in bindings_<area>.odin. Conventions, beyond the generated ABI (docs/api/README.md):
//   * handles are generation << 32 | index: opaque to the guest, checked on every call; host objects carry OBJECT_TAG
//   * callbacks are function table indices plus a user value; they run through call_guest (microtask checkpoint)
//   * import names follow "Interface_member" from Web IDL

import "wb:dom"

////////////////////////////////
// dom

// From the tree as it is now (scripts may replace them), as the DOM defines them (js_dom_tree.odin).
Document_documentElement :: proc(c: ^Call) -> u64 { d := call_doc(c); return d == nil ? 0 : u64(jd_document_element(d)) }
Document_head :: proc(c: ^Call) -> u64 { d := call_doc(c); return d == nil ? 0 : u64(jd_head(d)) }
Document_body :: proc(c: ^Call) -> u64 { d := call_doc(c); return d == nil ? 0 : u64(jd_body(d)) }

Document_createElement :: proc(c: ^Call, tag: string) -> (u64, Api_Error) {
	d := call_doc(c)
	if d == nil { return 0, fail(c, .Invalid_Handle, "no document in a worker") }
	if tag == "" { return 0, fail(c, .Invalid_Argument, "createElement: empty tag name") }
	return u64(dom.create_element(d, tag)), .None
}

Document_createTextNode :: proc(c: ^Call, text: string) -> (u64, Api_Error) {
	d := call_doc(c)
	if d == nil { return 0, fail(c, .Invalid_Handle, "no document in a worker") }
	return u64(dom.create_text(d, text)), .None
}

Document_getElementById :: proc(c: ^Call, id: string) -> u64 {
	d := call_doc(c)
	if d == nil { return 0 }
	return u64(dom.find_by_id(d, id))
}

Node_appendChild :: proc(c: ^Call, parent, child: Api_Node) -> Api_Error {
	return dom_error(dom.append_child(c.page.doc, H(parent.handle), H(child.handle)))
}

Node_insertBefore :: proc(c: ^Call, parent, child, ref: Api_Node) -> Api_Error {
	return dom_error(dom.insert_before(c.page.doc, H(parent.handle), H(child.handle), H(ref.handle)))
}

Node_removeChild :: proc(c: ^Call, parent, child: Api_Node) -> Api_Error {
	return dom_error(dom.remove_child(c.page.doc, H(parent.handle), H(child.handle)))
}

Node_release :: proc(c: ^Call, node: Api_Node) -> Api_Error {
	return dom_error(dom.release(c.page.doc, H(node.handle)))
}

Node_parentNode :: proc(c: ^Call, node: Api_Node) -> u64 { return u64(node.data.parent) }
Node_firstChild :: proc(c: ^Call, node: Api_Node) -> u64 { return u64(node.data.first_child) }
Node_lastChild :: proc(c: ^Call, node: Api_Node) -> u64 { return u64(node.data.last_child) }
Node_previousSibling :: proc(c: ^Call, node: Api_Node) -> u64 { return u64(node.data.prev) }
Node_nextSibling :: proc(c: ^Call, node: Api_Node) -> u64 { return u64(node.data.next) }

Node_nodeType :: proc(c: ^Call, node: Api_Node) -> i32 {
	switch node.data.kind {
	case .Element: return 1
	case .Text: return node.data.xml == .CDATA ? 4 : 3
	case .Comment: return node.data.xml == .Processing_Instruction ? 7 : 8
	case .Document: return 9
	case .Doctype: return 10
	case .Fragment: return 11
	}
	return 0
}

Node_setTextContent :: proc(c: ^Call, node: Api_Node, text: string) -> Api_Error {
	return dom_error(dom.set_text_content(c.page.doc, H(node.handle), text))
}

Node_getTextContent :: proc(c: ^Call, node: Api_Node) -> string { return dom.text_content(c.page.doc, H(node.handle)) }

Element_tagName :: proc(c: ^Call, element: Api_Element) -> string { return element.data.name }

Element_setAttribute :: proc(c: ^Call, element: Api_Element, name, value: string) -> Api_Error {
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), name, value))
}

Element_getAttribute :: proc(c: ^Call, element: Api_Element, name: string) -> (string, Api_Error) {
	v, ok := dom.get_attribute(c.page.doc, H(element.handle), name)
	if !ok { return "", .Not_Found }
	return v, .None
}

Element_removeAttribute :: proc(c: ^Call, element: Api_Element, name: string) -> Api_Error {
	return dom_error(dom.remove_attribute(c.page.doc, H(element.handle), name))
}

////////////////////////////////
// events

EventTarget_addEventListener :: proc(c: ^Call, target: u64, type: string, callback: u32, user: i32, options: Api_ListenerOptions) -> (i32, Api_Error) {
	if is_object(target) {
		id, err := object_add_listener(c.page, target, type, callback, u32(user), .Once in options, c.owner, capture = .Capture in options)
		if err != .None { return 0, dom_error(err) }
		return i32(id), .None
	}
	d := call_doc(c)
	if d == nil { return 0, fail(c, .Invalid_Handle, "no document in a worker") }
	id, err := dom.add_listener(d, H(target), type, callback, u32(user),
		capture = .Capture in options, once = .Once in options, passive = .Passive in options, owner = c.owner)
	if err != .None { return 0, dom_error(err) }
	return i32(id), .None
}

EventTarget_removeEventListener :: proc(c: ^Call, target: u64, id: i32) -> Api_Error {
	if is_object(target) { return dom_error(object_remove_listener(c.page, target, dom.Listener_Id(id))) }
	d := call_doc(c)
	if d == nil { return fail(c, .Invalid_Handle, "no document in a worker") }
	return dom_error(dom.remove_listener(d, H(target), dom.Listener_Id(id)))
}

EventTarget_dispatchEvent :: proc(c: ^Call, target: u64, type: string, init: Api_EventInit) -> (bool, Api_Error) {
	p := c.page
	if is_object(target) {
		if object_get(p, target) == nil { return false, .Invalid_Handle }
		return object_dispatch(p, target, dom.Event{type = type, cancelable = .Cancelable in init}), .None
	}
	if p.worker != nil || dom.get(p.doc, H(target)) == nil { return false, .Invalid_Handle }
	return dispatch_event(p, H(target), dom.Event{type = type, bubbles = .Bubbles in init, cancelable = .Cancelable in init}), .None
}

Event_preventDefault :: proc(c: ^Call, event: Api_Event) { if event.data.cancelable { event.data.default_prevented = true } }
Event_stopPropagation :: proc(c: ^Call, event: Api_Event) { event.data.stop = true }
Event_stopImmediatePropagation :: proc(c: ^Call, event: Api_Event) { event.data.stop = true; event.data.stop_immediate = true }
Event_target :: proc(c: ^Call, event: Api_Event) -> u64 { return u64(event.data.target) }
Event_currentTarget :: proc(c: ^Call, event: Api_Event) -> u64 { return u64(event.data.current_target) }
Event_type :: proc(c: ^Call, event: Api_Event) -> string { return event.data.type }
Event_defaultPrevented :: proc(c: ^Call, event: Api_Event) -> bool { return event.data.default_prevented }
// Payload of non-UI events (MessageEvent.data, CloseEvent.reason, ErrorEvent.message...): see dom.Event.
Event_data :: proc(c: ^Call, event: Api_Event) -> string { return event.data.data }
Event_text :: proc(c: ^Call, event: Api_Event) -> string { return event.data.text }
Event_code :: proc(c: ^Call, event: Api_Event) -> i64 { return event.data.code }
Event_object :: proc(c: ^Call, event: Api_Event) -> u64 { return event.data.object }
MouseEvent_clientX :: proc(c: ^Call, event: Api_Event) -> f64 { return event.data.x }
MouseEvent_clientY :: proc(c: ^Call, event: Api_Event) -> f64 { return event.data.y }
MouseEvent_button :: proc(c: ^Call, event: Api_Event) -> i32 { return event.data.button }
KeyboardEvent_keyCode :: proc(c: ^Call, event: Api_Event) -> i32 { return i32(event.data.key) }
