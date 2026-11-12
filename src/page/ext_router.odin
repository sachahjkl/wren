package page

// The router of extension contexts (docs/extensions.md, section 3.7). It lives on the loop thread and belongs to the
// App (Pages.ext_router). Every extension context registers with it: a page of the extension (popup, tab) when its
// realm starts, the background while its extension runs. The record is the host's (kind, page, URL): it is the
// MessageSender, and a context cannot forge it.
//   * API call: (method, JSON arguments) checked against the method table (kind and permission: ext_call_allowed, the
//     one gate), run here, answered to the caller's promise or its worker call id (Ext_Target).
//   * Event: ext_emit delivers to each context of the extension that listens to it; a stopped background starts first,
//     unless its script ran before and added no listener for that event.
//   * runtime.sendMessage: to every other page and the background of the extension; the first answer wins; no receiver
//     is the error "Could not establish connection. Receiving end does not exist.".
//   * Ports: an opener and the contexts that took its connect; order is the link's; the close of an end, of a page or
//     the stop of the background disconnects the others.
// Every limit is a preference (src/extensions/settings.odin); past one, the caller gets an error, nothing is dropped.
// Nothing here logs arguments, messages or stored values (rule 12).

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:extensions"
import "wb:host"

// Where an answer goes: a page realm's promise, or a background's call (its version and call id).
Ext_Target :: struct {
	ctx_id: u64,
	page:    u64,
	promise: u64,
	version: u64,
	call:    u64,
}

Ext_Context :: struct {
	id:        u64,
	ext:       string,              // the extension's id (owned)
	kind:      Ext_Kind,
	page:      u64,                 // the page (0: the background)
	url:       string,              // owned: the document's URL, or the background's script
	listening: map[string]bool,     // events with a listener (owned keys); the background keeps them while stopped
}

Ext_Port :: struct {
	id:     u64,
	ext:    string,                 // owned
	opener: u64,                    // its context
	others: [dynamic]u64,           // the contexts that took the connect
}

// A runtime.sendMessage waiting for its answer.
Ext_Reply :: struct {
	id:      u64,
	to:      Ext_Target,
	targets: [dynamic]u64,          // the contexts that may still answer
}

// One tab as the shell describes it (strings: temp allocator).
Ext_Tab_Info :: struct {
	id, window, index: i64,
	url, title:  string,
	active, pinned, loading: bool,
	page:        u64,               // its document (0: none)
}

Ext_Window_Info :: struct {
	id:                  i64,
	focused:             bool,
	left, top, width, height: int,
	state:               string,    // "normal", "maximized", "minimized", "fullscreen"
}

// What the router needs of the shell (src/browser/ext_shell.odin). nil procedures: no tab, no window.
Ext_Embedder :: struct {
	user:           rawptr,
	page_kind:      proc(user: rawptr, p: ^Page) -> Ext_Kind,                 // a popup's page, else a tab's
	tabs:           proc(user: rawptr, out: ^[dynamic]Ext_Tab_Info),
	windows:        proc(user: rawptr, out: ^[dynamic]Ext_Window_Info),
	focused_window: proc(user: rawptr) -> i64,
	changed:        proc(user: rawptr, ext: string),                          // the action's state changed: the toolbar draws again
}

Ext_Router :: struct {
	embedder:    Ext_Embedder,
	loop:        ^host.Loop,
	contexts:    map[u64]^Ext_Context,
	ports:       map[u64]^Ext_Port,
	replies:     map[u64]^Ext_Reply,
	backgrounds: map[string]^Ext_Background,   // ext_background.odin, by extension id
	next:        u64,
	alarm_timer: base.Handle,                 // ext_api.odin: the soonest alarm of every extension
	save_timer:  base.Handle,                 // ext_api.odin: the storage areas that changed are written when it fires
}

ext_router :: proc() -> ^Ext_Router { return &the_pages.ext_router }
ext_registry :: proc() -> ^extensions.Registry { return &the_pages.extensions }

@(private)
ext_next_id :: proc() -> u64 {
	r := ext_router()
	r.next += 1
	return r.next
}

ext_context_by_id :: proc(id: u64) -> ^Ext_Context {
	c, _ := ext_router().contexts[id]
	return c
}

@(private)
ext_context_new :: proc(ext: string, kind: Ext_Kind, page: u64, u: string) -> ^Ext_Context {
	c := new(Ext_Context)
	c^ = {id = ext_next_id(), ext = strings.clone(ext), kind = kind, page = page, url = strings.clone(u)}
	ext_router().contexts[c.id] = c
	return c
}

@(private)
ext_context_free :: proc(c: ^Ext_Context) {
	for k in c.listening { delete(k) }
	delete(c.listening)
	delete(c.ext); delete(c.url)
	free(c)
}

// The record of an extension page whose realm starts (nil: not an extension's page, or its extension does not run).
ext_page_context_open :: proc(p: ^Page) -> ^Ext_Realm {
	reg := ext_registry()
	o := p.env.origin
	if o.opaque { return nil }
	e := extensions.registry_running(reg, o.scheme, o.host)
	if e == nil { return nil }
	r := ext_router()
	if r.loop == nil { r.loop = p.loop }
	kind := Ext_Kind.Tab
	if em := &r.embedder; em.page_kind != nil { kind = em.page_kind(em.user, p) }
	c := ext_context_new(e.id, kind, page_id(p), p.env.location.href)
	x := new(Ext_Realm)
	x.image = extensions.image_retain(e.image)
	x.kind = kind
	x.ctx_id = c.id
	x.limits = ext_limits(reg)
	return x
}

ext_limits :: proc(reg: ^extensions.Registry) -> Ext_Limits {
	s := &reg.settings
	return Ext_Limits{message_max = s.message_max_bytes, calls_max = s.calls_max_pending, events_max = s.events_max_queued}
}

// A context ends (its page closed, its background stopped for good): its ports disconnect, the answers it owed are
// "none", the answers owed to it are dropped.
ext_page_context_close :: proc(id: u64) {
	r := ext_router()
	c, ok := r.contexts[id]
	if !ok { return }
	ext_context_detach(c)
	delete_key(&r.contexts, id)
	ext_context_free(c)
}

// What a context leaves when it goes or stops (the background's context stays registered while stopped).
@(private)
ext_context_detach :: proc(c: ^Ext_Context) {
	r := ext_router()
	// ports
	gone := make([dynamic]u64, 0, 4, context.temp_allocator)
	for id, port in r.ports {
		if port.opener == c.id { append(&gone, id); continue }
		for o in port.others { if o == c.id { append(&gone, id); break } }
	}
	for id in gone { ext_port_end_gone(id, c.id) }
	// replies
	done := make([dynamic]u64, 0, 4, context.temp_allocator)
	for id, rep in r.replies {
		if rep.to.ctx_id == c.id { append(&done, id); continue }
		for t, i in rep.targets {
			if t == c.id {
				unordered_remove(&rep.targets, i)
				if len(rep.targets) == 0 { ext_answer(rep.to, ""); append(&done, id) }
				break
			}
		}
	}
	for id in done { if rep, ok := r.replies[id]; ok { delete_key(&r.replies, id); delete(rep.targets); free(rep) } }
}

////////////////////////////////
// Answers and events

// Answers a call: a JSON value, "" (undefined) or "!" and an error's message.
ext_answer :: proc(to: Ext_Target, text: string) {
	if to.version != 0 {
		b := ext_bg_by_version(to.version)   // ext_background.odin
		if b == nil { return }
		ext_bg_answer(b, to.call, text)
		return
	}
	p := page_by_id(to.page)
	if p == nil || p.closed { return }
	promise_resolve(p, to.promise, 0, text)
}

// Whether `c` takes `event`: it listens, or it is a background whose script never ran (its listeners are not known yet).
@(private)
ext_listens :: proc(c: ^Ext_Context, event: string) -> bool {
	if c.listening[event] { return true }
	if c.kind == .Background {
		if b := ext_router().backgrounds[c.ext]; b != nil && !b.ever_ran { return true }
	}
	return false
}

// Gives the event's JSON to a context (a stopped background starts). False when it cannot take it.
ext_deliver :: proc(c: ^Ext_Context, text: string) -> bool {
	if c.kind == .Background {
		b := ext_router().backgrounds[c.ext]
		return b != nil && ext_bg_event(b, text)
	}
	p := page_by_id(c.page)
	if p == nil || p.closed || p.ext == nil { return false }
	return ext_realm_push(p, text)
}

// Emits `event` with its arguments (a JSON list) to every context of the extension that listens to it.
ext_emit :: proc(ext: string, event: string, args_json: string) {
	r := ext_router()
	text := fmt.tprintf(`{"t":"event","e":%s,"a":%s}`, extensions.json_quote(event), args_json)
	targets := make([dynamic]^Ext_Context, 0, 4, context.temp_allocator)
	for _, c in r.contexts { if c.ext == ext && ext_listens(c, event) { append(&targets, c) } }
	for c in targets { ext_deliver(c, text) }
}

// The MessageSender of a context (JSON).
ext_sender_json :: proc(c: ^Ext_Context) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"id":`)
	strings.write_string(&b, extensions.json_quote(c.ext))
	strings.write_string(&b, `,"url":`)
	strings.write_string(&b, extensions.json_quote(c.url))
	fmt.sbprintf(&b, `,"origin":%s`, extensions.json_quote(fmt.tprintf("%s://%s", extensions.SCHEME_CHROME, c.ext)))
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

////////////////////////////////
// What contexts ask

// A call of a page realm (or, through ext_bg_reply, of the background).
ext_call_from_page :: proc(context_id: u64, method, args: string, to: Ext_Target) {
	c := ext_context_by_id(context_id)
	if c == nil { ext_answer(to, "!the context is gone"); return }
	ext_dispatch(c, method, args, to)   // ext_api.odin
}

ext_listen :: proc(context_id: u64, event: string, on: bool) {
	c := ext_context_by_id(context_id)
	if c == nil { return }
	if on {
		if event not_in c.listening { c.listening[strings.clone(event)] = true }
	} else if event in c.listening {
		k, _ := delete_key(&c.listening, event)
		delete(k)
	}
}

// runtime.sendMessage from `from` (its message is the first of `args`, a JSON list).
ext_send_message :: proc(from: ^Ext_Context, message: string, to: Ext_Target) {
	r := ext_router()
	targets := make([dynamic]^Ext_Context, 0, 4, context.temp_allocator)
	for _, c in r.contexts {
		if c.ext != from.ext || c.id == from.id || c.kind == .Content { continue }
		if ext_listens(c, "runtime.onMessage") { append(&targets, c) }
	}
	if len(targets) == 0 { ext_answer(to, "!Could not establish connection. Receiving end does not exist."); return }
	rep := new(Ext_Reply)
	rep.id = ext_next_id()
	rep.to = to
	text := fmt.tprintf(`{"t":"event","e":"runtime.onMessage","a":[%s,%s],"r":%d}`, message, ext_sender_json(from), rep.id)
	for c in targets { if ext_deliver(c, text) { append(&rep.targets, c.id) } }
	if len(rep.targets) == 0 {
		delete(rep.targets)
		free(rep)
		ext_answer(to, "!Could not establish connection. Receiving end does not exist.")
		return
	}
	r.replies[rep.id] = rep
}

// The answer of `context_id` to message `reply`: the first answer goes to the sender; when every receiver said it has
// none, the sender gets undefined.
ext_respond :: proc(context_id: u64, reply: u64, value: string, has: bool) {
	r := ext_router()
	rep, ok := r.replies[reply]
	if !ok { return }
	at := -1
	for t, i in rep.targets { if t == context_id { at = i; break } }
	if at < 0 { return }   // (not one of its receivers: a forged id answers nothing)
	if has {
		ext_answer(rep.to, value)
	} else {
		unordered_remove(&rep.targets, at)
		if len(rep.targets) > 0 { return }
		ext_answer(rep.to, "")
	}
	delete_key(&r.replies, reply)
	delete(rep.targets)
	free(rep)
}

@(private)
ext_port_disconnect_json :: proc(port: u64) -> string { return fmt.tprintf(`{"t":"disconnect","p":%d}`, port) }

// runtime.connect: a port from `context_id` to the contexts of its extension that listen to runtime.onConnect.
ext_connect :: proc(context_id: u64, port: u64, name: string) {
	r := ext_router()
	from := ext_context_by_id(context_id)
	if from == nil { return }
	count := 0
	for _, x in r.ports { if x.ext == from.ext { count += 1 } }
	limit := ext_registry().settings.ports_max
	if port in r.ports || (limit > 0 && count >= limit) {
		ext_deliver(from, ext_port_disconnect_json(port))
		return
	}
	pt := new(Ext_Port)
	pt.id, pt.ext, pt.opener = port, strings.clone(from.ext), from.id
	r.ports[port] = pt
	text := fmt.tprintf(`{"t":"connect","p":%d,"n":%s,"s":%s}`, port, extensions.json_quote(name), ext_sender_json(from))
	targets := make([dynamic]^Ext_Context, 0, 4, context.temp_allocator)
	for _, c in r.contexts {
		if c.ext != from.ext || c.id == from.id || c.kind == .Content { continue }
		if ext_listens(c, "runtime.onConnect") { append(&targets, c) }
	}
	for c in targets { if ext_deliver(c, text) { append(&pt.others, c.id) } }
	if len(pt.others) == 0 { ext_port_end_gone(port, 0) } else { ext_bg_port_touch(from.ext) }
}

ext_port_post :: proc(context_id: u64, port: u64, message: string) {
	r := ext_router()
	pt, ok := r.ports[port]
	if !ok { return }
	text := fmt.tprintf(`{"t":"port","p":%d,"m":%s}`, port, message)
	if pt.opener == context_id {
		for o in pt.others { if c := ext_context_by_id(o); c != nil { ext_deliver(c, text) } }
	} else {
		mine := false
		for o in pt.others { if o == context_id { mine = true; break } }
		if !mine { return }   // (not an end of the port)
		if c := ext_context_by_id(pt.opener); c != nil { ext_deliver(c, text) }
	}
	ext_bg_port_touch(pt.ext)
}

ext_port_close :: proc(context_id: u64, port: u64) {
	r := ext_router()
	pt, ok := r.ports[port]
	if !ok { return }
	if pt.opener != context_id {
		mine := false
		for o in pt.others { if o == context_id { mine = true; break } }
		if !mine { return }
	}
	ext_port_end_gone(port, context_id)
}

// The end `gone` of a port closed (0: none took it). The opener closing ends the port for every other end; an other end
// closing leaves the port to the rest, and ends it when it was the last.
@(private)
ext_port_end_gone :: proc(port: u64, gone: u64) {
	r := ext_router()
	pt, ok := r.ports[port]
	if !ok { return }
	text := ext_port_disconnect_json(port)
	if gone != 0 && gone != pt.opener {
		for o, i in pt.others { if o == gone { unordered_remove(&pt.others, i); break } }
		if len(pt.others) > 0 { return }
	}
	if gone != pt.opener { if c := ext_context_by_id(pt.opener); c != nil { ext_deliver(c, text) } }
	if gone == pt.opener { for o in pt.others { if c := ext_context_by_id(o); c != nil { ext_deliver(c, text) } } }
	delete_key(&r.ports, port)
	delete(pt.ext)
	delete(pt.others)
	free(pt)
}

// Whether a port of `ext` is open (the background stays up while one is: ext_background.odin).
ext_has_open_port :: proc(ext: string) -> bool {
	for _, pt in ext_router().ports { if pt.ext == ext { return true } }
	return false
}

// Everything of the router goes (the App ends).
ext_router_destroy :: proc() {
	r := ext_router()
	for _, b in r.backgrounds { ext_bg_free(b) }
	delete(r.backgrounds)
	for _, pt in r.ports { delete(pt.ext); delete(pt.others); free(pt) }
	delete(r.ports)
	for _, rep in r.replies { delete(rep.targets); free(rep) }
	delete(r.replies)
	for _, c in r.contexts { ext_context_free(c) }
	delete(r.contexts)
	if r.alarm_timer != base.NIL_HANDLE && r.loop != nil { host.clear_timer(r.loop, r.alarm_timer) }
	if r.save_timer != base.NIL_HANDLE && r.loop != nil { host.clear_timer(r.loop, r.save_timer) }
	ext_storage_save_all()   // (what changed since the last write: the shell's writer flushes it at exit)
	r^ = {}
}
