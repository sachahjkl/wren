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
//     is the error "Could not establish connection. Receiving end does not exist.". tabs.sendMessage: the same to the
//     extension's content scripts (isolated worlds, ext_worlds.odin) in one tab, in documents it has a host grant for.
//   * Ports: an opener and the contexts that took its connect; order is the link's; the close of an end, of a page or
//     the stop of the background disconnects the others.
// Every limit is a preference (src/extensions/settings.odin); past one, the caller gets an error, nothing is dropped.
// Nothing here logs arguments, messages or stored values (rule 12).

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:extensions"
import "wb:host"
import "wb:url"

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
	// a content script's (kind Content): its document in its tab
	origin:    string,              // owned: the document's origin, serialized
	frame:     i64,                 // its frame id (0: the tab's top document)
	top_page:  u64,                 // the tab's top document
	document:  string,              // owned: its documentId
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
	popup:               bool,      // a popout window an extension made (windows.create type "popup")
	left, top, width, height: int,
	state:               string,    // "normal", "maximized", "minimized", "fullscreen"
}

// What tabs.create and windows.create ask of the shell (strings: the caller's, valid during the call).
Ext_Tab_Spec :: struct {
	url:    string,     // absolute, checked by ext_open_url_ok
	window: i64,        // -1: the current one
	index:  i64,        // -1: at the end
	active: bool,
}

Ext_Window_Spec :: struct {
	urls:    []string,  // absolute, checked; none: the homepage
	popup:   bool,      // type "popup": one tab, no tab strip, no toolbar
	width, height: int, // logical px (0: the shell's choice)
	left, top: int,
	has_position: bool,
	focused: bool,
}

// What the router needs of the shell (src/browser/ext_shell.odin, ext_window_api.odin). nil procedures: no tab, no window.
// The procedures that change tabs and windows are called from a task of the loop of their own, never inside a call of
// a page (ext_task_post).
Ext_Embedder :: struct {
	user:           rawptr,
	page_kind:      proc(user: rawptr, p: ^Page) -> Ext_Kind,                 // a popup's page, an offscreen document, else a tab's
	tabs:           proc(user: rawptr, out: ^[dynamic]Ext_Tab_Info),
	windows:        proc(user: rawptr, out: ^[dynamic]Ext_Window_Info),
	focused_window: proc(user: rawptr) -> i64,
	changed:        proc(user: rawptr, ext: string),                          // the action's state changed: the toolbar draws again
	tab_create:     proc(user: rawptr, ext: string, spec: Ext_Tab_Spec) -> i64,              // the new tab's id (-1: none)
	tab_update:     proc(user: rawptr, tab: i64, url: string, activate: bool) -> bool,       // url "" : unchanged
	tab_remove:     proc(user: rawptr, tab: i64) -> bool,
	window_create:  proc(user: rawptr, ext: string, spec: Ext_Window_Spec) -> i64,           // the new window's id (-1: none)
	window_update:  proc(user: rawptr, window: i64, focus: bool, left, top: int, move: bool) -> bool,
	window_remove:  proc(user: rawptr, window: i64) -> bool,
	offscreen_open: proc(user: rawptr, ext, url: string) -> bool,            // a page that shows nothing (ext_offscreen.odin)
	offscreen_close: proc(user: rawptr, ext: string),
	idle_seconds:   proc(user: rawptr) -> f64,                                // since the last input in the browser's windows
	reload:         proc(user: rawptr, ext: string),                          // runtime.reload: the package is read again
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
	idle_timer:  base.Handle,                 // ext_idle.odin: the next time an idle state can change
	offscreen:   map[string]^Ext_Offscreen,   // ext_offscreen.odin: the offscreen document of each extension (one at most)
	execs:       map[u64]^Ext_Exec,           // ext_scripting.odin: the scripting calls that act on documents, by id
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
	delete(c.ext); delete(c.url); delete(c.origin); delete(c.document)
	free(c)
}

// The record of an isolated world whose engine starts in `p` for extension `e` (ext_worlds.odin): a context of kind
// Content, its tab and frame known by the host.
ext_content_context_open :: proc(p: ^Page, e: ^extensions.Extension, owner: u32) -> ^Ext_Realm {
	r := ext_router()
	if r.loop == nil { r.loop = p.loop }
	c := ext_context_new(e.id, .Content, page_id(p), p.env.location.href)
	c.origin = url.origin_serialize(p.env.origin)
	top := ext_top_page(p)
	c.top_page = page_id(top)
	c.frame = ext_frame_id(p)
	c.document = strings.clone(ext_document_id(p))   // ext_inject.odin
	x := new(Ext_Realm)
	x.image = extensions.image_retain(e.image)
	x.kind = .Content
	x.ctx_id = c.id
	x.owner = owner
	x.limits = ext_limits(ext_registry())
	return x
}

// The top document of the tab `p` is in (itself for a tab's document).
ext_top_page :: proc(p: ^Page) -> ^Page {
	q := p
	for {
		n := frame_navigable_of(q)
		if n == nil || n.parent == nil { return q }
		q = n.parent
	}
}

// The frameId of a document (Chrome's: 0 for the tab's top document, else its navigable's id).
ext_frame_id :: proc(p: ^Page) -> i64 {
	n := frame_navigable_of(p)
	return n == nil ? 0 : i64(n.id)
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
	ext_exec_context_gone(c.id)   // ext_scripting.odin: the functions it was running answer null
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
	if p == nil || p.closed { return false }
	if c.kind == .Content {
		for w in p.worlds { if x := w.x; x != nil && x.ctx_id == c.id { return ext_realm_push(p, x, text) } }
		return false
	}
	if p.ext == nil { return false }
	return ext_realm_push(p, p.ext, text)
}

// Emits `event` with its arguments (a JSON list) to every context of the extension that listens to it.
ext_emit :: proc(ext: string, event: string, args_json: string) {
	r := ext_router()
	text := fmt.tprintf(`{{"t":"event","e":%s,"a":%s}}`, extensions.json_quote(event), args_json)
	targets := make([dynamic]^Ext_Context, 0, 4, context.temp_allocator)
	for _, c in r.contexts { if c.ext == ext && ext_listens(c, event) { append(&targets, c) } }
	for c in targets { ext_deliver(c, text) }
}

// The MessageSender of a context (JSON). A content script's names its tab (as the receiver's extension may see it), its
// frame and its document.
ext_sender_json :: proc(c: ^Ext_Context) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"id":`)
	strings.write_string(&b, extensions.json_quote(c.ext))
	strings.write_string(&b, `,"url":`)
	strings.write_string(&b, extensions.json_quote(c.url))
	if c.kind != .Content {
		strings.write_string(&b, `,"origin":`)
		strings.write_string(&b, extensions.json_quote(strings.concatenate({extensions.SCHEME_CHROME, "://", c.ext}, context.temp_allocator)))
		strings.write_byte(&b, '}')
		return strings.to_string(b)
	}
	strings.write_string(&b, `,"origin":`)
	strings.write_string(&b, extensions.json_quote(c.origin))
	fmt.sbprintf(&b, `,"frameId":%d`, c.frame)
	strings.write_string(&b, `,"documentId":`)
	strings.write_string(&b, extensions.json_quote(c.document))
	reg := ext_registry()
	if e := extensions.registry_running(reg, extensions.SCHEME_CHROME, c.ext); e != nil {
		for t in ext_tabs_list() {
			if t.page != c.top_page { continue }
			strings.write_string(&b, `,"tab":`)
			ext_tab_json_of(&b, reg, e, t)
			break
		}
	}
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
	if event == EXT_IDLE_EVENT { ext_idle_schedule() }   // ext_idle.odin: the state is watched only while someone listens
}

// runtime.sendMessage from `from` (its message is the first of `args`, a JSON list).
ext_send_message :: proc(from: ^Ext_Context, message: string, to: Ext_Target) {
	r := ext_router()
	targets := make([dynamic]^Ext_Context, 0, 4, context.temp_allocator)
	for _, c in r.contexts {
		if c.ext != from.ext || c.id == from.id || c.kind == .Content { continue }
		if ext_listens(c, "runtime.onMessage") { append(&targets, c) }
	}
	ext_send_to(from, targets[:], message, to)
}

// Which content scripts of `from`'s extension a message or a port to tab `tab` reaches: the isolated worlds in its
// documents (one frame when `frame` >= 0, one document when `document` is not ""), each in a document the extension
// still has a host grant for (rule 4 of section 3.11). False: no such tab.
ext_tab_targets :: proc(from: ^Ext_Context, tab, frame: i64, document: string, event: string, out: ^[dynamic]^Ext_Context) -> bool {
	top := u64(0)
	for t in ext_tabs_list() { if t.id == tab { top = t.page; break } }
	if top == 0 { return false }
	reg := ext_registry()
	e := extensions.registry_running(reg, extensions.SCHEME_CHROME, from.ext)
	if e == nil { return true }
	for _, c in ext_router().contexts {
		if c.ext != from.ext || c.kind != .Content || c.top_page != top { continue }
		if frame >= 0 && c.frame != frame { continue }
		if document != "" && c.document != document { continue }
		// (a document without a URL of its own is granted through its origin, as its scripts were)
		href := extensions.url_needs_fallback(c.url) ? strings.concatenate({c.origin, "/"}, context.temp_allocator) : c.url
		if !extensions.extension_host_allowed(reg, e, href) { continue }
		if ext_listens(c, event) { append(out, c) }
	}
	return true
}

// tabs.sendMessage: to the content scripts of the extension in a tab (ext_tab_targets).
ext_send_to_tab :: proc(from: ^Ext_Context, tab, frame: i64, document: string, message: string, to: Ext_Target) {
	targets := make([dynamic]^Ext_Context, 0, 4, context.temp_allocator)
	if !ext_tab_targets(from, tab, frame, document, "runtime.onMessage", &targets) { ext_answer(to, fmt.tprintf("!No tab with id: %d.", tab)); return }
	ext_send_to(from, targets[:], message, to)
}

// Delivers a message to `targets`; the first answer goes to `to`.
@(private)
ext_send_to :: proc(from: ^Ext_Context, targets: []^Ext_Context, message: string, to: Ext_Target) {
	r := ext_router()
	if len(targets) == 0 { ext_answer(to, "!Could not establish connection. Receiving end does not exist."); return }
	rep := new(Ext_Reply)
	rep.id = ext_next_id()
	rep.to = to
	text := fmt.tprintf(`{{"t":"event","e":"runtime.onMessage","a":[%s,%s],"r":%d}}`, message, ext_sender_json(from), rep.id)
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
	if has && ext_exec_respond(context_id, reply, value) { return }   // (a scripting.executeScript function's value)
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
ext_port_disconnect_json :: proc(port: u64) -> string { return fmt.tprintf(`{{"t":"disconnect","p":%d}}`, port) }

// runtime.connect: a port from `context_id` to the contexts of its extension that listen to runtime.onConnect.
ext_connect :: proc(context_id: u64, port: u64, name: string) {
	from := ext_context_by_id(context_id)
	if from == nil { return }
	targets := make([dynamic]^Ext_Context, 0, 4, context.temp_allocator)
	for _, c in ext_router().contexts {
		if c.ext != from.ext || c.id == from.id || c.kind == .Content { continue }
		if ext_listens(c, "runtime.onConnect") { append(&targets, c) }
	}
	ext_connect_to(from, port, name, targets[:])
}

// tabs.connect: a port from `context_id` to the content scripts of its extension in a tab (ext_tab_targets). A tab
// with none disconnects the port at once, as Chrome does.
ext_connect_tab :: proc(context_id: u64, port: u64, name: string, tab, frame: i64) {
	from := ext_context_by_id(context_id)
	if from == nil { return }
	targets := make([dynamic]^Ext_Context, 0, 4, context.temp_allocator)
	ext_tab_targets(from, tab, frame, "", "runtime.onConnect", &targets)
	ext_connect_to(from, port, name, targets[:])
}

@(private)
ext_connect_to :: proc(from: ^Ext_Context, port: u64, name: string, targets: []^Ext_Context) {
	r := ext_router()
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
	text := fmt.tprintf(`{{"t":"connect","p":%d,"n":%s,"s":%s}}`, port, extensions.json_quote(name), ext_sender_json(from))
	for c in targets { if ext_deliver(c, text) { append(&pt.others, c.id) } }
	if len(pt.others) == 0 { ext_port_end_gone(port, 0) } else { ext_bg_port_touch(from.ext) }
}

ext_port_post :: proc(context_id: u64, port: u64, message: string) {
	r := ext_router()
	pt, ok := r.ports[port]
	if !ok { return }
	text := fmt.tprintf(`{{"t":"port","p":%d,"m":%s}}`, port, message)
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
	if r.idle_timer != base.NIL_HANDLE && r.loop != nil { host.clear_timer(r.loop, r.idle_timer) }
	ext_offscreen_destroy_all()   // ext_offscreen.odin (the shell closes the pages themselves with its tabs)
	ext_execs_destroy()           // ext_scripting.odin
	ext_storage_save_all()   // (what changed since the last write: the shell's writer flushes it at exit)
	r^ = {}
}
