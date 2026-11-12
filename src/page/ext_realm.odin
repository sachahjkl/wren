package page

// A realm that is an extension context (docs/extensions.md, sections 3.7 and 3.9), and the host side of module ext
// (api/ext.widl). Two cases, one record (Page.ext):
//   * an extension page (popup, tab): a Page on the loop thread whose origin is a running extension's. Its calls go to
//     the router directly (ext_router.odin).
//   * an extension's background: a service worker's realm on a thread of its own (ext_background.odin). What it may
//     answer alone (its info, the manifest, the catalogue) it reads from the Image it holds; everything else travels to
//     the loop thread over its worker link (Sw_Reply .Ext), and comes back as Sw_Event .Ext (an event, or a call's answer).
// The host decides who calls: the record is made by the browser when the realm starts, never by the guest.

import "core:encoding/json"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:extensions"
import "wb:host"

Ext_Kind :: enum u8 { Background, Popup, Tab, Offscreen, Content }
EXT_KIND_NAMES := [Ext_Kind]string{.Background = "background", .Popup = "popup", .Tab = "tab", .Offscreen = "offscreen", .Content = "content"}

// The limits a realm applies on its own thread (a copy: a worker cannot read the registry).
Ext_Limits :: struct {
	message_max: int,
	calls_max:   int,
	events_max:  int,
}

// The worker's messages to the loop thread (Sw_Reply .Ext: code2) and the loop's to the worker (Sw_Event .Ext: code2).
EXT_OP_CALL    :: 1   // id: the call, text: method, text2: arguments
EXT_OP_LISTEN  :: 2   // text: event, text2: "1" added / "0" removed
EXT_OP_RESPOND :: 3   // id: the reply, text: value, text2: "1" an answer / "0" none
EXT_OP_CONNECT :: 4   // id: the port, text: name
EXT_OP_POST    :: 5   // id: the port, text: message
EXT_OP_CLOSE   :: 6   // id: the port
EXT_TO_EVENT   :: 0   // text: the event's JSON
EXT_TO_ANSWER  :: 1   // id: the call, text: its answer

Ext_Realm :: struct {
	image:     ^extensions.Image,   // retained
	kind:      Ext_Kind,
	ctx_id:   u64,                 // the router's context (a page's; 0 in a background's realm, which the loop knows by its version)
	limits:    Ext_Limits,
	events:    [dynamic]string,     // JSON texts waiting for Ext_take (owned)
	calls:     map[u64]u64,         // a background's calls in flight: call id -> promise
	next_call: u64,
	owner:     u32,                 // the realm's instance (its promises)
	woken:     bool,                // a task that runs the pump is posted (pages)
}

ext_realm_free :: proc(x: ^Ext_Realm) {
	extensions.image_release(x.image)
	for e in x.events { delete(e) }
	delete(x.events)
	delete(x.calls)
	free(x)
}

// Right after a realm started (js_realm.odin): an extension context gets its record and chrome.* (wj_ext_install).
ext_realm_started :: proc(p: ^Page, r: ^Js_Realm) {
	x: ^Ext_Realm
	if g := p.worker; g != nil {
		if g.sw.ext == nil { return }
		x = new(Ext_Realm)
		x.image = extensions.image_retain(g.sw.ext)
		x.kind = .Background
		x.limits = g.sw.ext_limits
	} else {
		x = ext_page_context_open(p)   // ext_router.odin: nil when the page is not an extension's
		if x == nil { return }
	}
	x.owner = r.inst.index
	p.ext = x
	// the record goes with the page (the router forgets its context first: ext_router.odin)
	base.on_close(p.scope, proc(data: rawptr) {
		p := (^Page)(data)
		x := p.ext
		if x == nil { return }
		p.ext = nil
		if p.worker == nil { ext_page_context_close(x.ctx_id) }
		ext_realm_free(x)
	}, p)
	if js_call(p, r.inst, "wj_ext_install", nil) != .Ok { log(p, .Error, "the extension APIs could not be set up in this realm") }
	// events that came before the realm (the background's first ones wait in its queue; a page's in its record)
	if len(x.events) > 0 { ext_realm_wake(p) }
}

// Runs the realm's pump soon (not inside the caller's call: an event never runs JavaScript in the middle of a call).
ext_realm_wake :: proc(p: ^Page) {
	x := p.ext
	if x == nil || x.woken { return }
	x.woken = true
	if p.worker != nil {
		// the worker's thread: its inbox runs the pump right after this message (ext_worker_event)
		ext_realm_pump(p)
		return
	}
	id := page_id(p)
	host.post(p.loop, proc(data: rawptr) {
		if q := page_by_id(u64(uintptr(data))); q != nil && !q.closed { ext_realm_pump(q) }
	}, rawptr(uintptr(id)))
}

@(private)
ext_realm_pump :: proc(p: ^Page) {
	x := p.ext
	if x == nil { return }
	x.woken = false
	r := p.js
	if r == nil || r.failed || len(x.events) == 0 { return }
	js_call(p, r.inst, "wj_ext_event", nil)
	js_after_task(p, r, "extension event")
}

// Queues an event's JSON for the realm (`text` is copied). False when its queue is full (extensions.events.max_queued).
ext_realm_push :: proc(p: ^Page, text: string) -> bool {
	x := p.ext
	if x == nil { return false }
	if x.limits.events_max > 0 && len(x.events) >= x.limits.events_max { return false }
	append(&x.events, strings.clone(text))
	ext_realm_wake(p)
	return true
}

////////////////////////////////
// The worker's side (its thread)

// A message of the loop thread for a background's realm (sw_worker_event): an event, or the answer of a call.
ext_worker_event :: proc(p: ^Page, m: ^Worker_Msg) {
	defer msg_free(m)
	x := p.ext
	if x == nil { return }
	switch m.code2 {
	case EXT_TO_ANSWER:
		pr, ok := x.calls[m.id]
		if !ok { return }
		delete_key(&x.calls, m.id)
		promise_resolve(p, pr, 0, m.text)
	case:
		if x.limits.events_max > 0 && len(x.events) >= x.limits.events_max { return }
		append(&x.events, m.text)
		m.text = ""
		ext_realm_pump(p)
	}
}

@(private = "file")
ext_worker_send :: proc(p: ^Page, op: i64, id: u64, text := "", text2 := "") {
	m := new(Worker_Msg)
	m.kind, m.code, m.code2, m.id = .Sw_Reply, i64(Sw_Reply_Kind.Ext), op, id
	m.text, m.text2 = strings.clone(text), strings.clone(text2)
	link_send(p.worker.link, false, m)
}

////////////////////////////////
// Module ext (api/ext.widl)

// The calling realm's record (nil: not an extension context: every function answers nothing).
@(private = "file")
ext_of :: proc(c: ^Call) -> ^Ext_Realm {
	if c.caller != nil && c.caller != c.page { return nil }   // (a call routed to another document's realm: not its context)
	return c.page.ext
}

Ext_info :: proc(c: ^Call) -> string {
	x := ext_of(c)
	if x == nil { return "" }
	return ext_info_json(x.image, x.kind)   // ext_api.odin
}

Ext_manifest :: proc(c: ^Call) -> string {
	x := ext_of(c)
	if x == nil { return "" }
	return x.image.manifest.text
}

Ext_message :: proc(c: ^Call, name: string, subs: string) -> string {
	x := ext_of(c)
	if x == nil { return "" }
	list := ext_string_list(subs)
	msg, _ := extensions.catalogue_get(&x.image.catalogue, name, list, x.image.id)
	return msg
}

Ext_call :: proc(c: ^Call, method: string, args: string) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	x := ext_of(c)
	if x == nil { promise_resolve(p, pr, 0, "!not an extension context"); return pr }
	if x.limits.message_max > 0 && len(args) > x.limits.message_max {
		promise_resolve(p, pr, 0, "!the arguments are larger than extensions.message.max_bytes")
		return pr
	}
	if p.worker != nil {
		if x.limits.calls_max > 0 && len(x.calls) >= x.limits.calls_max {
			promise_resolve(p, pr, 0, "!too many calls in flight (extensions.calls.max_pending)")
			return pr
		}
		x.next_call += 1
		x.calls[x.next_call] = pr
		ext_worker_send(p, EXT_OP_CALL, x.next_call, method, args)
		return pr
	}
	ext_call_from_page(x.ctx_id, method, args, Ext_Target{page = page_id(p), promise = pr, ctx_id = x.ctx_id})   // ext_router.odin
	return pr
}

Ext_listen :: proc(c: ^Call, event: string, on: bool) {
	x := ext_of(c)
	if x == nil { return }
	if c.page.worker != nil { ext_worker_send(c.page, EXT_OP_LISTEN, 0, event, on ? "1" : "0"); return }
	ext_listen(x.ctx_id, event, on)
}

Ext_take :: proc(c: ^Call) -> string {
	x := ext_of(c)
	if x == nil || len(x.events) == 0 { return "" }
	t := x.events[0]
	ordered_remove(&x.events, 0)
	out := strings.clone(t, context.temp_allocator)
	delete(t)
	return out
}

Ext_respond :: proc(c: ^Call, reply: u64, value: string, has: bool) {
	x := ext_of(c)
	if x == nil { return }
	if c.page.worker != nil { ext_worker_send(c.page, EXT_OP_RESPOND, reply, value, has ? "1" : "0"); return }
	ext_respond(x.ctx_id, reply, value, has)
}

Ext_connect :: proc(c: ^Call, port: u64, name: string) {
	x := ext_of(c)
	if x == nil || port == 0 { return }
	if c.page.worker != nil { ext_worker_send(c.page, EXT_OP_CONNECT, port, name); return }
	ext_connect(x.ctx_id, port, name)
}

Ext_portPost :: proc(c: ^Call, port: u64, message: string) {
	x := ext_of(c)
	if x == nil { return }
	if x.limits.message_max > 0 && len(message) > x.limits.message_max {
		log(c.page, .Error, "Port.postMessage: the message is larger than extensions.message.max_bytes; it was not sent")
		return
	}
	if c.page.worker != nil { ext_worker_send(c.page, EXT_OP_POST, port, message); return }
	ext_port_post(x.ctx_id, port, message)
}

Ext_portClose :: proc(c: ^Call, port: u64) {
	x := ext_of(c)
	if x == nil { return }
	if c.page.worker != nil { ext_worker_send(c.page, EXT_OP_CLOSE, port); return }
	ext_port_close(x.ctx_id, port)
}

// A JSON list of strings (i18n substitutions) as strings (temp); anything else: none.
ext_string_list :: proc(text: string) -> []string {
	if text == "" || text == "[]" { return nil }
	out := make([dynamic]string, 0, 4, context.temp_allocator)
	v, err := json.parse_string(text, .JSON, false, context.temp_allocator)
	if err != .None { return nil }
	if arr, ok := v.(json.Array); ok {
		for e in arr { if s, sok := e.(json.String); sok { append(&out, s) } else { append(&out, extensions.json_text(e)) } }
	}
	return out[:]
}

// A decimal id ("" or junk: 0).
ext_parse_id :: proc(s: string) -> u64 {
	n, _ := strconv.parse_u64(s)
	return n
}
