package page

// The imports of module "frames" (api/frames.widl): what a realm needs to reach other windows by navigable id
// (frames.odin). The engine's side is native/js/runtime/frames.c and prelude/frames.js.

import "core:strings"
import "wb:dom"
import "wb:js"
import "wb:url"

Frame_self :: proc(c: ^Call) -> u64 {
	n := page_navigable(c.page)
	return n != nil ? n.id : 0
}

Frame_ofElement :: proc(c: ^Call, element: u64) -> u64 {
	p := c.page
	if p.worker != nil || dom.get(p.doc, H(element)) == nil { return 0 }
	frames_note_removed(p)   // (a container removed in this task has no navigable any more)
	n := frame_of_element(p, H(element))
	return n != nil && n.page != nil ? n.id : 0
}

Frame_parent :: proc(c: ^Call, navigable: u64) -> u64 {
	n := navigable_by_id(navigable)
	if n == nil || n.parent == nil { return 0 }
	pn := page_navigable(n.parent)
	return pn != nil ? pn.id : 0
}

Frame_top :: proc(c: ^Call, navigable: u64) -> u64 {
	n := navigable_by_id(navigable)
	if n == nil || n.page == nil { return 0 }
	tn := page_navigable(page_top(n.page))
	return tn != nil ? tn.id : 0
}

Frame_length :: proc(c: ^Call, navigable: u64) -> u32 {
	n := navigable_by_id(navigable)
	if n == nil || n.page == nil { return 0 }
	return u32(len(frames_children(n.page)))
}

Frame_child :: proc(c: ^Call, navigable: u64, index: u32) -> u64 {
	n := navigable_by_id(navigable)
	if n == nil || n.page == nil { return 0 }
	kids := frames_children(n.page)
	if int(index) >= len(kids) { return 0 }
	return kids[index].id
}

Frame_named :: proc(c: ^Call, navigable: u64, name: string) -> u64 {
	n := navigable_by_id(navigable)
	if n == nil || n.page == nil || name == "" { return 0 }
	for k in frames_children(n.page) { if k.name == name { return k.id } }
	return 0
}

Frame_childNames :: proc(c: ^Call, navigable: u64) -> string {
	n := navigable_by_id(navigable)
	if n == nil || n.page == nil { return "" }
	sb := strings.builder_make(context.temp_allocator)
	for k, i in frames_children(n.page) {
		if k.name == "" { continue }
		if i > 0 && strings.builder_len(sb) > 0 { strings.write_byte(&sb, 0) }
		strings.write_string(&sb, k.name)
	}
	return strings.to_string(sb)
}

Frame_closed :: proc(c: ^Call, navigable: u64) -> bool {
	n := navigable_by_id(navigable)
	return n == nil || n.page == nil || n.page.closed
}

Frame_sameOrigin :: proc(c: ^Call, navigable: u64) -> bool {
	n := navigable_by_id(navigable)
	if n == nil || n.page == nil { return false }
	return url.same_origin(c.page.env.origin, n.page.env.origin)
}

Frame_postMessage :: proc(c: ^Call, navigable: u64, data: []u8, target_origin: string) -> Api_Error {
	n := navigable_by_id(navigable)
	if n == nil { return .None }   // a closed window: nothing happens
	err, msg := frames_post_message(c.page, n, data, target_origin)
	if err != .None { return fail(c, err, msg) }
	return .None
}

Frame_postMessagePorts :: proc(c: ^Call, navigable: u64, data: []u8, target_origin: string, ports: []u64) -> Api_Error {
	n := navigable_by_id(navigable)
	if n == nil { for x in ports { port_close_end(x) }; return .None }
	err, msg := frames_post_message(c.page, n, data, target_origin, ports)
	if err != .None { return fail(c, err, msg) }
	return .None
}

Frame_navigate :: proc(c: ^Call, navigable: u64, u: string, replace: bool) -> Api_Error {
	n := navigable_by_id(navigable)
	if n == nil || n.page == nil { return .None }
	if _, ok := url.parse(u, &c.page.env.location, context.temp_allocator); !ok { return fail(c, .Syntax, "SyntaxError: invalid URL") }
	if why := frames_navigate_from(c.page, n, u, replace); why != "" {
		log(c.page, .Error, strings.concatenate({"Unsafe attempt to navigate another window: ", why}, context.temp_allocator))
		return fail(c, .Security, strings.concatenate({"SecurityError: ", why}, context.temp_allocator))
	}
	return .None
}

Frame_open :: proc(c: ^Call, u: string, target: string) -> (u64, Api_Error) {
	p := c.page
	href := "about:blank"
	if u != "" {
		r, ok := url.parse(u, &p.env.location, context.temp_allocator)
		if !ok { return 0, fail(c, .Syntax, "SyntaxError: Failed to execute 'open' on 'Window': Unable to open a window with invalid URL.") }
		href = r.href
	}
	if n := frames_find_target(p, target); n != nil {
		if why := frames_navigate_from(p, n, href, false); why != "" {
			log(p, .Error, strings.concatenate({"window.open: ", why}, context.temp_allocator))
			return 0, .None
		}
		return n.id, .None
	}
	// a new window
	sb := page_sandbox(p)
	if sb.active && .Popups not_in sb.allow {
		log(p, .Error, "Blocked opening a new window in a sandboxed frame without allow-popups.")
		return 0, .None
	}
	top := page_top(p)
	if open := top.web.embedder.open; open != nil {
		open(top.web.embedder.user, p, href)
	} else {
		log(p, .Warn, "window.open: this browser cannot open a new window here")
	}
	return 0, .None
}

Window_get_name :: proc(c: ^Call) -> string {
	n := page_navigable(c.page)
	return n != nil ? n.name : ""
}

Window_set_name :: proc(c: ^Call, value: string) {
	n := page_navigable(c.page)
	if n == nil { return }
	delete(n.name)
	n.name = strings.clone(value)
}

HTMLIFrameElement_srcdoc :: proc(c: ^Call, element: Api_Element) -> string {
	v, _ := dom.get_attribute(c.page.doc, H(element.handle), "srcdoc")
	return v
}

HTMLIFrameElement_set_srcdoc :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	return dom_error(dom.set_attribute(c.page.doc, H(element.handle), "srcdoc", value))
}

// Delivers a message posted by another document (frames_post_message) to this document's realm: the engine
// deserializes it and fires a trusted "message" MessageEvent at the window, whose source is the sender's WindowProxy.
js_frames_deliver :: proc(p: ^Page, data: []byte, origin: string, source: u64, ports: []u64 = nil) {
	r := p.js
	if r == nil || r.failed || r.inst == nil || r.inst.dead {   // no script ever ran: nobody listens
		for x in ports { port_close_end(x) }
		return
	}
	d := js.guest_copy(r.inst, data, false)
	if d == 0 && len(data) > 0 { return }
	defer js.guest_free(r.inst, d)
	o := js.guest_copy(r.inst, transmute([]byte)origin, false)
	defer js.guest_free(r.inst, o)
	pp := js.guest_copy(r.inst, ([^]byte)(raw_data(ports))[:len(ports) * 8], false)
	defer js.guest_free(r.inst, pp)
	argv := [8]u32{d, u32(len(data)), o, u32(len(origin)), u32(source), u32(source >> 32), pp, u32(len(ports))}
	js_call(p, r.inst, "wj_frames_message", argv[:])
	js_after_task(p, r, "message")
}
