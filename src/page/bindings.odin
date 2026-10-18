package page

// The web platform as Wasm imports. No JavaScript, no glue, no marshalling of types:
//   * handles are i64 (generation << 32 | index): opaque to the guest, validated by the host on every call
//   * strings are (ptr, len) UTF-8 into the guest's linear memory; the runtime checks the range before we run
//   * a string returned to the guest is written into a (ptr, cap) buffer the guest provides; the result is the
//     length needed, so the guest can retry with a bigger buffer (no host allocation inside guest memory)
//   * callbacks are plain function pointers (table indices) plus an i32 user value
//   * errors: negative i32 (dom.Error); functions returning a handle return 0 on failure
//
// Import module names follow the specification area (dom, events, timers, net, console); member names follow
// "Interface_member" from Web IDL, so a generator can produce guest-side bindings for any language.

import "base:runtime"
import "wb:base"
import "wb:dom"
import "wb:wasm"

@(private)
ctx :: proc "contextless" () -> runtime.Context { return runtime.default_context() }

@(private)
page_of :: #force_inline proc "c" (env: wasm.Exec_Env) -> ^Page {
	return (^Page)(wasm.owner(env).user)
}

@(private)
inst_of :: #force_inline proc "c" (env: wasm.Exec_Env) -> ^wasm.Instance { return wasm.owner(env) }

@(private)
H :: #force_inline proc "contextless" (v: u64) -> base.Handle { return base.Handle(v) }

@(private)
str :: #force_inline proc "contextless" (p: [^]u8, n: i32) -> string { return string(p[:max(n, 0)]) }

// Copies `s` into the guest buffer, returns the full length.
@(private)
out_string :: proc "contextless" (s: string, buf: [^]u8, cap: i32) -> i32 {
	n := min(len(s), int(max(cap, 0)))
	if n > 0 { copy(buf[:n], s[:n]) }
	return i32(len(s))
}

////////////////////////////////
// dom

n_Document_documentElement :: proc "c" (env: wasm.Exec_Env) -> u64 { return u64(page_of(env).doc_el) }
n_Document_head :: proc "c" (env: wasm.Exec_Env) -> u64 { return u64(page_of(env).head) }
n_Document_body :: proc "c" (env: wasm.Exec_Env) -> u64 { return u64(page_of(env).body) }

n_Document_createElement :: proc "c" (env: wasm.Exec_Env, tag: [^]u8, n: i32) -> u64 {
	context = ctx()
	t := str(tag, n)
	if t == "" { return 0 }
	return u64(dom.create_element(page_of(env).doc, t))
}

n_Document_createTextNode :: proc "c" (env: wasm.Exec_Env, text: [^]u8, n: i32) -> u64 {
	context = ctx()
	return u64(dom.create_text(page_of(env).doc, str(text, n)))
}

n_Document_getElementById :: proc "c" (env: wasm.Exec_Env, id: [^]u8, n: i32) -> u64 {
	context = ctx()
	return u64(dom.find_by_id(page_of(env).doc, str(id, n)))
}

n_Node_appendChild :: proc "c" (env: wasm.Exec_Env, parent, child: u64) -> i32 {
	context = ctx()
	return i32(dom.append_child(page_of(env).doc, H(parent), H(child)))
}

n_Node_insertBefore :: proc "c" (env: wasm.Exec_Env, parent, child, ref: u64) -> i32 {
	context = ctx()
	return i32(dom.insert_before(page_of(env).doc, H(parent), H(child), H(ref)))
}

n_Node_removeChild :: proc "c" (env: wasm.Exec_Env, parent, child: u64) -> i32 {
	context = ctx()
	return i32(dom.remove_child(page_of(env).doc, H(parent), H(child)))
}

n_Node_release :: proc "c" (env: wasm.Exec_Env, node: u64) -> i32 {
	context = ctx()
	return i32(dom.release(page_of(env).doc, H(node)))
}

@(private)
relation :: proc "contextless" (env: wasm.Exec_Env, node: u64, which: int) -> u64 {
	context = ctx()
	d := page_of(env).doc
	n := dom.get(d, H(node))
	if n == nil { return 0 }
	switch which {
	case 0: return u64(n.parent)
	case 1: return u64(n.first_child)
	case 2: return u64(n.last_child)
	case 3: return u64(n.prev)
	case 4: return u64(n.next)
	}
	return 0
}

n_Node_parentNode :: proc "c" (env: wasm.Exec_Env, node: u64) -> u64 { return relation(env, node, 0) }
n_Node_firstChild :: proc "c" (env: wasm.Exec_Env, node: u64) -> u64 { return relation(env, node, 1) }
n_Node_lastChild :: proc "c" (env: wasm.Exec_Env, node: u64) -> u64 { return relation(env, node, 2) }
n_Node_previousSibling :: proc "c" (env: wasm.Exec_Env, node: u64) -> u64 { return relation(env, node, 3) }
n_Node_nextSibling :: proc "c" (env: wasm.Exec_Env, node: u64) -> u64 { return relation(env, node, 4) }

n_Node_nodeType :: proc "c" (env: wasm.Exec_Env, node: u64) -> i32 {
	context = ctx()
	n := dom.get(page_of(env).doc, H(node))
	if n == nil { return 0 }
	switch n.kind {
	case .Element: return 1
	case .Text: return 3
	case .Comment: return 8
	case .Document: return 9
	}
	return 0
}

n_Node_setTextContent :: proc "c" (env: wasm.Exec_Env, node: u64, text: [^]u8, n: i32) -> i32 {
	context = ctx()
	return i32(dom.set_text_content(page_of(env).doc, H(node), str(text, n)))
}

n_Node_getTextContent :: proc "c" (env: wasm.Exec_Env, node: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	d := page_of(env).doc
	if dom.get(d, H(node)) == nil { return i32(dom.Error.Invalid_Handle) }
	return out_string(dom.text_content(d, H(node)), buf, cap)
}

n_Element_tagName :: proc "c" (env: wasm.Exec_Env, node: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	n := dom.get(page_of(env).doc, H(node))
	if n == nil || n.kind != .Element { return i32(dom.Error.Invalid_Handle) }
	return out_string(n.name, buf, cap)
}

n_Element_setAttribute :: proc "c" (env: wasm.Exec_Env, node: u64, name: [^]u8, nl: i32, value: [^]u8, vl: i32) -> i32 {
	context = ctx()
	return i32(dom.set_attribute(page_of(env).doc, H(node), str(name, nl), str(value, vl)))
}

// Returns the value length, or a negative error (Not_Found = attribute absent).
n_Element_getAttribute :: proc "c" (env: wasm.Exec_Env, node: u64, name: [^]u8, nl: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	d := page_of(env).doc
	if dom.get(d, H(node)) == nil { return i32(dom.Error.Invalid_Handle) }
	v, ok := dom.get_attribute(d, H(node), str(name, nl))
	if !ok { return i32(dom.Error.Not_Found) }
	return out_string(v, buf, cap)
}

n_Element_removeAttribute :: proc "c" (env: wasm.Exec_Env, node: u64, name: [^]u8, nl: i32) -> i32 {
	context = ctx()
	return i32(dom.remove_attribute(page_of(env).doc, H(node), str(name, nl)))
}

dom_symbols := [?]wasm.Native_Symbol{
	{"Document_documentElement", rawptr(n_Document_documentElement), "()I", nil},
	{"Document_head", rawptr(n_Document_head), "()I", nil},
	{"Document_body", rawptr(n_Document_body), "()I", nil},
	{"Document_createElement", rawptr(n_Document_createElement), "(*~)I", nil},
	{"Document_createTextNode", rawptr(n_Document_createTextNode), "(*~)I", nil},
	{"Document_getElementById", rawptr(n_Document_getElementById), "(*~)I", nil},
	{"Node_appendChild", rawptr(n_Node_appendChild), "(II)i", nil},
	{"Node_insertBefore", rawptr(n_Node_insertBefore), "(III)i", nil},
	{"Node_removeChild", rawptr(n_Node_removeChild), "(II)i", nil},
	{"Node_release", rawptr(n_Node_release), "(I)i", nil},
	{"Node_parentNode", rawptr(n_Node_parentNode), "(I)I", nil},
	{"Node_firstChild", rawptr(n_Node_firstChild), "(I)I", nil},
	{"Node_lastChild", rawptr(n_Node_lastChild), "(I)I", nil},
	{"Node_previousSibling", rawptr(n_Node_previousSibling), "(I)I", nil},
	{"Node_nextSibling", rawptr(n_Node_nextSibling), "(I)I", nil},
	{"Node_nodeType", rawptr(n_Node_nodeType), "(I)i", nil},
	{"Node_setTextContent", rawptr(n_Node_setTextContent), "(I*~)i", nil},
	{"Node_getTextContent", rawptr(n_Node_getTextContent), "(I*~)i", nil},
	{"Element_tagName", rawptr(n_Element_tagName), "(I*~)i", nil},
	{"Element_setAttribute", rawptr(n_Element_setAttribute), "(I*~*~)i", nil},
	{"Element_getAttribute", rawptr(n_Element_getAttribute), "(I*~*~)i", nil},
	{"Element_removeAttribute", rawptr(n_Element_removeAttribute), "(I*~)i", nil},
}

////////////////////////////////
// events

n_EventTarget_addEventListener :: proc "c" (env: wasm.Exec_Env, target: u64, type: [^]u8, tl: i32, callback, user, flags: i32) -> i32 {
	context = ctx()
	if is_object(target) {
		oid, oerr := object_add_listener(page_of(env), target, str(type, tl), u32(callback), u32(user), flags & 2 != 0, inst_of(env).index)
		if oerr != .None { return i32(oerr) }
		return i32(oid)
	}
	id, err := dom.add_listener(page_of(env).doc, H(target), str(type, tl), u32(callback), u32(user),
		capture = flags & 1 != 0, once = flags & 2 != 0, passive = flags & 4 != 0, owner = inst_of(env).index)
	if err != .None { return i32(err) }
	return i32(id)
}

n_EventTarget_removeEventListener :: proc "c" (env: wasm.Exec_Env, target: u64, id: i32) -> i32 {
	context = ctx()
	if is_object(target) { return i32(object_remove_listener(page_of(env), target, dom.Listener_Id(id))) }
	return i32(dom.remove_listener(page_of(env).doc, H(target), dom.Listener_Id(id)))
}

n_EventTarget_dispatchEvent :: proc "c" (env: wasm.Exec_Env, target: u64, type: [^]u8, tl: i32, flags: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	if is_object(target) {
		if object_get(p, target) == nil { return i32(dom.Error.Invalid_Handle) }
		return object_dispatch(p, target, dom.Event{type = str(type, tl), cancelable = flags & 2 != 0}) ? 1 : 0
	}
	if dom.get(p.doc, H(target)) == nil { return i32(dom.Error.Invalid_Handle) }
	ok := dispatch_event(p, H(target), dom.Event{type = str(type, tl), bubbles = flags & 1 != 0, cancelable = flags & 2 != 0})
	return ok ? 1 : 0
}

@(private)
with_event :: proc(env: wasm.Exec_Env, ev: u64) -> ^dom.Event {
	return base.pool_get(&page_of(env).dp.events, H(ev))
}

n_Event_preventDefault :: proc "c" (env: wasm.Exec_Env, ev: u64) {
	context = ctx()
	if e := with_event(env, ev); e != nil && e.cancelable { e.default_prevented = true }
}
n_Event_stopPropagation :: proc "c" (env: wasm.Exec_Env, ev: u64) {
	context = ctx()
	if e := with_event(env, ev); e != nil { e.stop = true }
}
n_Event_stopImmediatePropagation :: proc "c" (env: wasm.Exec_Env, ev: u64) {
	context = ctx()
	if e := with_event(env, ev); e != nil { e.stop = true; e.stop_immediate = true }
}
n_Event_target :: proc "c" (env: wasm.Exec_Env, ev: u64) -> u64 {
	context = ctx()
	if e := with_event(env, ev); e != nil { return u64(e.target) }
	return 0
}
n_Event_currentTarget :: proc "c" (env: wasm.Exec_Env, ev: u64) -> u64 {
	context = ctx()
	if e := with_event(env, ev); e != nil { return u64(e.current_target) }
	return 0
}
n_Event_type :: proc "c" (env: wasm.Exec_Env, ev: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	e := with_event(env, ev)
	if e == nil { return i32(dom.Error.Invalid_Handle) }
	return out_string(e.type, buf, cap)
}
n_MouseEvent_clientX :: proc "c" (env: wasm.Exec_Env, ev: u64) -> f64 {
	context = ctx()
	if e := with_event(env, ev); e != nil { return e.x }
	return 0
}
n_MouseEvent_clientY :: proc "c" (env: wasm.Exec_Env, ev: u64) -> f64 {
	context = ctx()
	if e := with_event(env, ev); e != nil { return e.y }
	return 0
}
n_MouseEvent_button :: proc "c" (env: wasm.Exec_Env, ev: u64) -> i32 {
	context = ctx()
	if e := with_event(env, ev); e != nil { return e.button }
	return 0
}
// Payload of non-UI events (MessageEvent.data, CloseEvent.reason, ErrorEvent.message...): see dom.Event.
n_Event_data :: proc "c" (env: wasm.Exec_Env, ev: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	e := with_event(env, ev)
	if e == nil { return i32(dom.Error.Invalid_Handle) }
	return out_string(e.data, buf, cap)
}
n_Event_text :: proc "c" (env: wasm.Exec_Env, ev: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	e := with_event(env, ev)
	if e == nil { return i32(dom.Error.Invalid_Handle) }
	return out_string(e.text, buf, cap)
}
n_Event_code :: proc "c" (env: wasm.Exec_Env, ev: u64) -> i64 {
	context = ctx()
	if e := with_event(env, ev); e != nil { return e.code }
	return 0
}
n_Event_object :: proc "c" (env: wasm.Exec_Env, ev: u64) -> u64 {
	context = ctx()
	if e := with_event(env, ev); e != nil { return e.object }
	return 0
}
n_Event_defaultPrevented :: proc "c" (env: wasm.Exec_Env, ev: u64) -> i32 {
	context = ctx()
	if e := with_event(env, ev); e != nil { return e.default_prevented ? 1 : 0 }
	return 0
}

n_KeyboardEvent_keyCode :: proc "c" (env: wasm.Exec_Env, ev: u64) -> i32 {
	context = ctx()
	if e := with_event(env, ev); e != nil { return i32(e.key) }
	return 0
}

events_symbols := [?]wasm.Native_Symbol{
	{"EventTarget_addEventListener", rawptr(n_EventTarget_addEventListener), "(I*~iii)i", nil},
	{"EventTarget_removeEventListener", rawptr(n_EventTarget_removeEventListener), "(Ii)i", nil},
	{"EventTarget_dispatchEvent", rawptr(n_EventTarget_dispatchEvent), "(I*~i)i", nil},
	{"Event_preventDefault", rawptr(n_Event_preventDefault), "(I)", nil},
	{"Event_stopPropagation", rawptr(n_Event_stopPropagation), "(I)", nil},
	{"Event_stopImmediatePropagation", rawptr(n_Event_stopImmediatePropagation), "(I)", nil},
	{"Event_target", rawptr(n_Event_target), "(I)I", nil},
	{"Event_currentTarget", rawptr(n_Event_currentTarget), "(I)I", nil},
	{"Event_type", rawptr(n_Event_type), "(I*~)i", nil},
	{"MouseEvent_clientX", rawptr(n_MouseEvent_clientX), "(I)F", nil},
	{"MouseEvent_clientY", rawptr(n_MouseEvent_clientY), "(I)F", nil},
	{"MouseEvent_button", rawptr(n_MouseEvent_button), "(I)i", nil},
	{"KeyboardEvent_keyCode", rawptr(n_KeyboardEvent_keyCode), "(I)i", nil},
	{"Event_data", rawptr(n_Event_data), "(I*~)i", nil},
	{"Event_text", rawptr(n_Event_text), "(I*~)i", nil},
	{"Event_code", rawptr(n_Event_code), "(I)I", nil},
	{"Event_object", rawptr(n_Event_object), "(I)I", nil},
	{"Event_defaultPrevented", rawptr(n_Event_defaultPrevented), "(I)i", nil},
}

////////////////////////////////
////////////////////////////////
// console

@(private)
console_write :: proc(env: wasm.Exec_Env, level: Log_Level, p: [^]u8, n: i32) {
	pg := page_of(env)
	log(pg, level, str(p, n))
}
n_console_log :: proc "c" (env: wasm.Exec_Env, p: [^]u8, n: i32) { context = ctx(); console_write(env, .Log, p, n) }
n_console_warn :: proc "c" (env: wasm.Exec_Env, p: [^]u8, n: i32) { context = ctx(); console_write(env, .Warn, p, n) }
n_console_error :: proc "c" (env: wasm.Exec_Env, p: [^]u8, n: i32) { context = ctx(); console_write(env, .Error, p, n) }

console_symbols := [?]wasm.Native_Symbol{
	{"log", rawptr(n_console_log), "(*~)", nil},
	{"warn", rawptr(n_console_warn), "(*~)", nil},
	{"error", rawptr(n_console_error), "(*~)", nil},
}

////////////////////////////////

// Registers every import module. Call once, after wasm.runtime_init.
register_imports :: proc() -> bool {
	if !wasm.runtime_init() { return false }
	ok := true
	ok &&= wasm.register("dom", dom_symbols[:])
	ok &&= wasm.register("events", events_symbols[:])
	ok &&= wasm.register("timers", timers_symbols[:])
	ok &&= wasm.register("net", net_symbols[:])
	ok &&= wasm.register("document", document_symbols[:])
	ok &&= wasm.register("console", console_symbols[:])
	ok &&= wasm.register("async", async_symbols[:])
	ok &&= wasm.register("eventsource", eventsource_symbols[:])
	ok &&= wasm.register("websocket", websocket_symbols[:])
	return ok
}

