package page

// An extension's background service worker (docs/extensions.md, section 3.5). It reuses service_worker.odin's host (a
// page that shows nothing runs the worker; Sw_Version, worker links), with four differences:
//   1. the registration is made here when the extension starts: its scope is the extension origin, no script calls
//      register(), and it is not in the service workers' list (nor in service_workers.txt): extensions.txt is its source;
//   2. its script is the Image's (read with the package, off the loop thread): no update check, no waiting state;
//   3. no fetch event, no install or activate event: its replies come here (ext_bg_reply), not to sw_page_reply's
//      life cycle;
//   4. its realm gets the extension APIs (ext_realm.odin), its calls travel as Sw_Reply .Ext.
// It starts for an event (or when its extension starts), and stops after extensions.background.idle_ms with no call in
// flight, no answer owed and no port that carried a message within extensions.background.port_keepalive_ms. Its
// router context and the events it listens to stay while it is stopped: a later event with no listener does not start it.

import "core:fmt"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:extensions"
import "wb:fetch"
import "wb:host"

Ext_Background :: struct {
	ext:      string,              // the extension's id (owned)
	reg:      ^Sw_Registration,    // ours (extension = true)
	version:  ^Sw_Version,
	ctx_id:  u64,                 // its router context (kind Background)
	ever_ran: bool,                // its script ran once: the events it listens to are known
	calls:    int,                 // its API calls in flight
	idle:     base.Handle,
	port_at:  time.Tick,           // when a port of its extension carried a message last
	starts:   int,                 // how many times it started (about:extensions: one start a minute is a bug to look at)
	unran:    int,                 // starts in a row whose script has not run yet (extensions.background.failed_starts_max)
	saved:    bool,                // state.txt has its listeners (ext_bg_save_listeners)
}

ext_bg_by_version :: proc(version: u64) -> ^Ext_Background {
	for _, b in ext_router().backgrounds { if b.version != nil && b.version.id == version { return b } }
	return nil
}

@(private = "file")
ext_bg_by_context :: proc(id: u64) -> ^Ext_Background {
	for _, b in ext_router().backgrounds { if b.ctx_id == id { return b } }
	return nil
}

// The router learns the shell's loop and procedures (ext_shell.odin, at the App's start). A background can start before
// any page exists: the host pages of service workers are made like the App's pages (sw_note_page learns the same from
// the first page otherwise).
ext_router_init :: proc(loop: ^host.Loop, embedder: Ext_Embedder, loader: ^fetch.Loader, settings: ^Settings, storage: ^Storage_Manager) {
	r := ext_router()
	r.loop = loop
	r.embedder = embedder
	sr := &the_pages.sw_registry
	if sr.loader == nil { sr.loop, sr.loader, sr.settings = loop, loader, settings }
	if sr.storage == nil { sr.storage = storage }
}

// The extension runs (loaded, enabled): its background exists and starts. `startup`: the browser started (it gets
// runtime.onStartup); an install or a reload gets runtime.onInstalled when its script ran (ext_bg_reply).
ext_extension_start :: proc(e: ^extensions.Extension, startup: bool) {
	if e.image == nil || !e.image.ok || !e.enabled { return }
	im := e.image
	m := &im.manifest
	if m.background_worker == "" || ext_router().backgrounds[e.id] != nil { return }
	r := new(Sw_Registration)
	r.extension = true
	the_pages.sw_registry.next += 1
	r.id = the_pages.sw_registry.next
	r.origin = fmt.aprintf("%s://%s", extensions.SCHEME_CHROME, e.id)
	r.scope = strings.clone(im.base_url)
	r.script = strings.clone(extensions.image_url(im, m.background_worker))
	r.via_cache = strings.clone("imports")
	r.preload_header = strings.clone("true")
	v := sw_version_new(r, r.script, m.background_module)
	v.image = make([]byte, len(im.background_source))
	copy(v.image, im.background_source)
	append(&v.csp, strings.clone(im.page_csp))
	v.ext = extensions.image_retain(im)
	v.ext_limits = ext_limits(ext_registry())
	v.state = .Activated
	r.active = v
	b := new(Ext_Background)
	b.ext = strings.clone(e.id)
	b.reg, b.version = r, v
	c := ext_context_new(e.id, .Background, 0, r.script)
	b.ctx_id = c.id
	ext_router().backgrounds[b.ext] = b
	// the listeners its script added when it last ran (state.txt): at the browser's start the background is known
	// without running; an event starts it only when it listens to it (runtime.onStartup among them)
	known := startup && e.listeners_known
	if known {
		for l in e.listeners { if l not_in c.listening { c.listening[strings.clone(l)] = true } }
		b.ever_ran = true
		b.saved = true
	}
	if startup { ext_emit(e.id, "runtime.onStartup", "[]") }   // (queued until its script ran, when it starts)
	if !known { ext_bg_start(b) }
	if known && c.listening[EXT_IDLE_EVENT] { ext_idle_schedule() }
}

// The events its background listens to are kept in state.txt, when they changed since the last write.
@(private = "file")
ext_bg_save_listeners :: proc(b: ^Ext_Background) {
	c := ext_context_by_id(b.ctx_id)
	reg := ext_registry()
	e := extensions.registry_find(reg, b.ext)
	if c == nil || e == nil { return }
	names := make([dynamic]string, 0, len(c.listening), context.temp_allocator)
	for k in c.listening { append(&names, k) }
	if b.saved && e.listeners_known && extensions.state_serialize(names[:]) == extensions.state_serialize(e.listeners[:]) { return }
	b.saved = true
	extensions.listeners_set(e, names[:])
	extensions.registry_save_state(reg, e)
}

// The extension stops (disabled, removed, reloaded): its background goes, with its context, ports and answers.
ext_extension_stop :: proc(id: string) {
	r := ext_router()
	ext_offscreen_close(id)   // ext_offscreen.odin: its offscreen document goes with it
	worlds_stop_extension(id)   // ext_worlds.odin: its content scripts stop in every document
	b, ok := r.backgrounds[id]
	if !ok { return }
	delete_key(&r.backgrounds, id)
	ext_bg_free(b)
}

ext_bg_free :: proc(b: ^Ext_Background) {
	r := ext_router()
	if b.idle != base.NIL_HANDLE && r.loop != nil { host.clear_timer(r.loop, b.idle); b.idle = base.NIL_HANDLE }
	ext_page_context_close(b.ctx_id)
	sw_reg_free(b.reg)   // (stops its worker, frees its version)
	delete(b.ext)
	free(b)
}

// Starts its worker (its events wait in the version's queue until its script ran). False when it cannot start (no
// loader yet: a test without storage, or the browser is ending).
ext_bg_start :: proc(b: ^Ext_Background) -> bool {
	v := b.version
	if v.worker != nil { return true }
	// (a script that fails before it runs would be started again by each event: a new worker and its realm each time, faster
	// than the last ones are let go, and the senders wait for an answer that never comes. Past the limit it stays stopped and
	// what it is sent fails at once, until the extension is reloaded: a new background.)
	if limit := ext_registry().settings.background_failed_starts_max; limit > 0 && b.unran >= limit { return false }
	if !sw_version_start(v) { return false }
	b.starts += 1
	b.unran += 1
	ext_bg_touch(b)
	return true
}

// Stops its worker; its context and what it listens to stay (idle, or the extension is disabled).
ext_bg_stop :: proc(b: ^Ext_Background) {
	if c := ext_context_by_id(b.ctx_id); c != nil { ext_context_detach(c) }
	b.calls = 0
	sw_version_stop(b.version)
	r := ext_router()
	if b.idle != base.NIL_HANDLE && r.loop != nil { host.clear_timer(r.loop, b.idle); b.idle = base.NIL_HANDLE }
}

@(private = "file")
ext_bg_send :: proc(b: ^Ext_Background, m: ^Worker_Msg) -> bool {
	v := b.version
	if v.worker == nil && !ext_bg_start(b) { msg_free(m); return false }
	ext_bg_touch(b)
	if !v.running {
		limit := ext_registry().settings.events_max_queued
		if limit > 0 && len(v.queue) >= limit { msg_free(m); return false }
		append(&v.queue, m)
		return true
	}
	link_send(v.worker.link, true, m)
	return true
}

// An event's JSON for its realm.
ext_bg_event :: proc(b: ^Ext_Background, text: string) -> bool {
	m := sw_event(.Ext)
	m.code2 = EXT_TO_EVENT
	m.text = strings.clone(text)
	return ext_bg_send(b, m)
}

// The answer of one of its calls (dropped when its worker stopped since: the realm that asked is gone).
ext_bg_answer :: proc(b: ^Ext_Background, call: u64, text: string) {
	b.calls = max(b.calls - 1, 0)
	v := b.version
	if v.worker == nil { return }
	m := sw_event(.Ext, call)
	m.code2 = EXT_TO_ANSWER
	m.text = strings.clone(text)
	link_send(v.worker.link, true, m)
	ext_bg_touch(b)
}

// A port of the extension carried a message: its background stays up a while longer.
ext_bg_port_touch :: proc(ext: string) {
	if b := ext_router().backgrounds[ext]; b != nil { b.port_at = time.tick_now() }
}

@(private = "file")
ext_bg_touch :: proc(b: ^Ext_Background) {
	r := ext_router()
	loop := r.loop != nil ? r.loop : the_pages.sw_registry.loop
	if loop == nil { return }
	r.loop = loop
	if b.idle != base.NIL_HANDLE { host.clear_timer(loop, b.idle); b.idle = base.NIL_HANDLE }
	if b.version.worker == nil { return }
	ms := ext_registry().settings.background_idle_ms
	if ms <= 0 { return }
	b.idle = host.set_timer(loop, f64(ms), 0, ext_bg_idle_fire, rawptr(uintptr(b.ctx_id)))
}

@(private = "file")
ext_bg_idle_fire :: proc(data: rawptr) {
	b := ext_bg_by_context(u64(uintptr(data)))
	if b == nil { return }
	b.idle = base.NIL_HANDLE
	if ext_bg_busy(b) { ext_bg_touch(b); return }
	ext_bg_stop(b)
}

// Busy: a call in flight, an answer it owes, its script not run yet, or a port that carried a message recently.
@(private = "file")
ext_bg_busy :: proc(b: ^Ext_Background) -> bool {
	if b.calls > 0 || !b.version.running { return true }
	for _, rep in ext_router().replies { for t in rep.targets { if t == b.ctx_id { return true } } }
	if ext_has_open_port(b.ext) {
		keep := ext_registry().settings.port_keepalive_ms
		if time.duration_milliseconds(time.tick_since(b.port_at)) < f64(keep) { return true }
	}
	return false
}

// What its worker sent (sw_page_reply hands over every reply of an extension's registration).
ext_bg_reply :: proc(h: ^Worker_Host, v: ^Sw_Version, m: ^Worker_Msg) {
	b := ext_bg_by_version(v.id)
	if b == nil { return }
	#partial switch Sw_Reply_Kind(m.code) {
	case .Script_Ran:
		v.running = true
		b.ever_ran = true
		b.unran = 0
		for q in v.queue { link_send(h.link, true, q) }
		clear(&v.queue)
		info := sw_event(.Registration)
		info.text = strings.clone(sw_reg_info(v.reg))
		link_send(h.link, true, info)
		// its listeners are known: they are kept for the browser's next start
		ext_bg_save_listeners(b)
		// runtime.onInstalled once, now that its listeners are known
		if e := extensions.registry_find(ext_registry(), b.ext); e != nil && e.installed != "" {
			reason := e.installed
			e.installed = ""
			ext_emit(b.ext, "runtime.onInstalled", fmt.tprintf(`[{{"reason":%s}}]`, extensions.json_quote(reason)))
		}
	case .Ext:
		c := ext_context_by_id(b.ctx_id)
		if c == nil { return }
		switch m.code2 {
		case EXT_OP_CALL:
			b.calls += 1
			ext_dispatch(c, m.text, m.text2, Ext_Target{ctx_id = b.ctx_id, version = v.id, call = m.id})
		case EXT_OP_LISTEN:
			ext_listen(b.ctx_id, m.text, m.text2 == "1")
			if v.running { ext_bg_save_listeners(b) }   // (during its first run: saved once, when it ran)
		case EXT_OP_RESPOND: ext_respond(b.ctx_id, m.id, m.text, m.text2 == "1")
		case EXT_OP_CONNECT: ext_connect(b.ctx_id, m.id, m.text)
		case EXT_OP_CONNECT_TAB:
			tab, frame := ext_parse_tab_frame(m.text2)   // ext_realm.odin
			ext_connect_tab(b.ctx_id, m.id, m.text, tab, frame)
		case EXT_OP_POST:    ext_port_post(b.ctx_id, m.id, m.text)
		case EXT_OP_CLOSE:   ext_port_close(b.ctx_id, m.id)
		}
	case .Request:
		// clients.*, registration.update(): not an extension background's (its pages are not its clients)
		a := sw_event(.Answer, m.id)
		a.code2 = 1
		a.text = strings.clone("NotSupportedError: not in an extension's background")
		link_send(h.link, true, a)
	}
	ext_bg_touch(b)
}

// The state of the background as about:extensions shows it.
ext_bg_state :: proc(id: string) -> (exists, running: bool, starts: int) {
	b := ext_router().backgrounds[id]
	if b == nil { return false, false, 0 }
	return true, b.version.worker != nil, b.starts
}
