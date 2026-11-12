package page

// Isolated worlds (docs/extensions.md, section 3.6). A page already runs several Wasm instances that share its DOM
// (Page.instances): every call knows its instance (Call.owner), listeners, timers, observers and promises record their
// owner instance and are called back in it, and a node has one wrapper per realm. So the isolated world of an extension
// is one more instance of the JavaScript engine on the same Page, with the same handle tag: no call is routed, no value
// is bridged. One world per extension per document; all content scripts of that extension share it. It is made when
// its first script runs and goes with the page's scope.
//
// What is split by world, and where:
//   * the global, the built-ins, the wrappers and their own properties, listeners, timers, promises, observers: free,
//     another instance (owner = its index);
//   * the microtask checkpoint drains every world's jobs (js_checkpoint, js_realm.odin);
//   * a trap or a slow script stops the world, the page lives on (world_trapped, js_call);
//   * the bytecode cache and the wrappers' pins answer a world's engine as the page's (from_engine, js_host.odin);
//   * a MutationObserver's records queue in the world that made it (mo_notify_later), a MessagePort's messages in the
//     world that bound it (ports.odin);
//   * a message posted to the window is fired once per world, each realm with its own copy of the data, and each of
//     those events reaches the listeners of its own realm only (worlds_deliver_message, world_listener_takes);
//   * customElements is null in a world (START_ISOLATED, native/js/odin/custom_elements.odin); event handler content
//     attributes, inserted <script> elements and javascript: URLs run in the page's realm (they use p.js);
//   * fetch and the storage APIs of a world are the page's: its origin, its CSP for requests, its cookies.
// Not split (known gaps): slotchange fires only through the page's realm; window.frames, parent and contentWindow
// give the other documents' page realms, not the same extension's world there; IndexedDB, Worker, WebAssembly, Web
// Audio, MediaSource and navigator.serviceWorker deliver their callbacks to the page's realm (they use p.js), so a
// content script must not use them yet.

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:extensions"
import "wb:js"
import "wb:wasm"

World :: struct {
	ext:   string,       // the extension's id (owned)
	realm: Js_Realm,     // its engine (the instance is one of the page's: the page's scope frees it)
	x:     ^Ext_Realm,   // its extension record (kind Content); nil once the world stopped
}

world_find :: proc(p: ^Page, ext: string) -> ^World {
	for w in p.worlds { if w.ext == ext { return w } }
	return nil
}

world_of_inst :: proc(p: ^Page, inst: ^wasm.Instance) -> ^World {
	if inst == nil { return nil }
	for w in p.worlds { if w.realm.inst == inst { return w } }
	return nil
}

// The JavaScript realm of `inst`: the page's, or a world's (nil: another module of the page).
js_realm_of :: proc(p: ^Page, inst: ^wasm.Instance) -> ^Js_Realm {
	if r := p.js; r != nil && r.inst != nil && r.inst == inst { return r }
	if w := world_of_inst(p, inst); w != nil { return &w.realm }
	return nil
}

// The same by instance index (a foreign owner's index, with FOREIGN_OWNER, names none).
js_realm_by_index :: proc(p: ^Page, index: u32) -> ^Js_Realm {
	if r := p.js; r != nil && r.inst != nil && r.inst.index == index { return r }
	for w in p.worlds { if w.realm.inst != nil && w.realm.inst.index == index { return &w.realm } }
	return nil
}

// What a MessagePort end records of the realm that bound it: a world's instance index + 1, 0 for any other.
world_tag_of :: proc(p: ^Page, inst: ^wasm.Instance) -> u32 {
	if w := world_of_inst(p, inst); w != nil { return inst.index + 1 }
	return 0
}

@(private)
world_alive :: proc(p: ^Page, w: ^World) -> bool {
	for x in p.worlds { if x == w { return !w.realm.failed && w.realm.inst != nil && !w.realm.inst.dead } }
	return false
}

// The world of extension `e` in `p`, made on first need (nil: no more worlds here, or the engine could not start).
world_open :: proc(p: ^Page, e: ^extensions.Extension) -> ^World {
	if w := world_find(p, e.id); w != nil { return world_alive(p, w) ? w : nil }
	if p.closed || p.worker != nil || p.doc == nil { return nil }
	reg := ext_registry()
	if reg.settings.worlds_max > 0 && len(p.worlds) >= reg.settings.worlds_max {
		log(p, .Warn, fmt.tprintf("the content scripts of %s do not run here: the document has extensions.worlds.max_per_document worlds already", e.id))
		return nil
	}
	opt := p.settings.wasm
	if slow := p.settings.js.slow_script_ms; slow > 0 {
		opt.soft_call_ms = slow
		if opt.max_call_ms > 0 && opt.max_call_ms < slow * 4 { opt.max_call_ms = slow * 4 }   // (as the page's realm: js_realm)
	}
	js_read_ahead_wait()
	opt.polled = js_polled()
	inst, err := wasm.instance_create(js_engine_image(), p, p.scope, opt, "javascript (content scripts)", nil, js_image_digest())
	if inst == nil {
		log(p, .Error, fmt.tprintf("the content scripts of %s could not start: %s", e.id, err))
		delete(err)
		return nil
	}
	inst.lenient = true
	inst.index = u32(len(p.instances))
	append(&p.instances, inst)
	w := new(World)
	w.ext = strings.clone(e.id)
	w.realm.inst = inst
	// the records go before the page's own cleanup (registered first, it runs last) and before the instances they name
	if len(p.worlds) == 0 { base.on_close(p.scope, worlds_close_all, p) }
	append(&p.worlds, w)
	ext_doc_of(p)   // (the message filter lives there: world_message_begin)

	seed: u64
	wasm.random_bytes(([^]u8)(&seed)[:8])
	start := js.Start_Options{
		kind = .Window, seed = seed, max_heap_bytes = p.settings.js.max_heap_bytes, gc_threshold = p.settings.js.gc_threshold_bytes,
		gc_growth_percent = p.settings.js.gc_heap_growth_percent, gc_min_growth = p.settings.js.gc_min_growth_bytes,
		no_touch_handlers = !p.settings.js.touch_handlers,
		frames = true,      // window.postMessage, window.parent and named access need the frames imports
		isolated = true,
	}
	if !js.realm_start(inst, start) {
		w.realm.failed = true
		log(p, .Error, fmt.tprintf("the content scripts of %s could not start: %s", e.id, inst.last_error))
		return nil
	}
	if p.settings.js.jit.enabled { js.jit_configure(inst, p.settings.js.jit) }
	if addr := js.interrupt_address(inst); addr != 0 {
		if b := wasm.guest_bytes(inst, u64(addr), 4); b != nil {
			w.realm.interrupt = (^i32)(raw_data(b))
			inst.soft_flag = w.realm.interrupt
		}
	}
	argv := [1]u32{}
	wasm.call_raw(inst, "wj_load_init", argv[:], 1)   // (rejections, dynamic import, eval policy: js_load_realm.odin)
	w.x = ext_content_context_open(p, e, inst.index)   // ext_router.odin
	if js_call(p, inst, "wj_ext_install", nil) != .Ok { log(p, .Error, "the extension APIs could not be set up in a content script's world") }
	if !world_alive(p, w) { return nil }
	return w
}

// Runs a classic script in the world (the bytecode cache as the page's scripts). False: it threw or the world stopped.
world_run :: proc(p: ^Page, w: ^World, source: []byte, url: string) -> bool {
	if !world_alive(p, w) { return false }
	return js_run_in(p, &w.realm, source, url) == .Ok
}

// A trap inside a world's engine: the world stops for good, the page's scripts go on (guest_failed).
world_trapped :: proc(p: ^Page, inst: ^wasm.Instance) {
	w := world_of_inst(p, inst)
	if w == nil { return }
	world_lost(p, w, inst.last_error)
	if inst.depth > 0 { wasm.trap(inst, "the JavaScript engine stopped in a nested call") }
	inst.dead = true
}

world_lost :: proc(p: ^Page, w: ^World, why: string) {
	if w.realm.failed { return }
	w.realm.failed = true
	log(p, .Error, fmt.tprintf("the content scripts of extension %s were stopped in the middle of their work: they no longer run in this document. %s", w.ext, why))
	world_detach(w)
}

// The world's extension context goes: its ports disconnect, the answers it owed are "none".
@(private)
world_detach :: proc(w: ^World) {
	x := w.x
	if x == nil { return }
	w.x = nil
	ext_page_context_close(x.ctx_id)
	ext_realm_free(x)
}

@(private)
worlds_close_all :: proc(data: rawptr) {
	p := (^Page)(data)
	for w in p.worlds {
		world_detach(w)
		delete(w.ext)
		free(w)
	}
	delete(p.worlds)
	p.worlds = nil
}

// Every world of extension `ext` in every live document stops (the extension is disabled, reloaded or removed). The
// engines stay until their page goes: a world is not taken out of a running page.
worlds_stop_extension :: proc(ext: string) {
	for p in live_page_list() {
		for w in p.worlds {
			if w.ext != ext || w.realm.failed { continue }
			w.realm.failed = true
			world_detach(w)
			if w.realm.inst != nil { w.realm.inst.dead = true }
		}
	}
}

////////////////////////////////
// Messages posted to the window

// Each world gets its copy of a message posted to this document's window (js_frames_deliver): its engine deserializes
// it and fires its own MessageEvent. Ports stay with the page's realm. The source is null in a world.
worlds_deliver_message :: proc(p: ^Page, data: []byte, origin: string) {
	list := make([dynamic]^World, 0, len(p.worlds), context.temp_allocator)
	append(&list, ..p.worlds[:])
	for w in list {
		if p.closed { return }
		if !world_alive(p, w) { continue }
		r := &w.realm
		d := js.guest_copy(r.inst, data, false)
		if d == 0 && len(data) > 0 { continue }
		o := js.guest_copy(r.inst, transmute([]byte)origin, false)
		prev := world_message_begin(p, r.inst)
		argv := [8]u32{d, u32(len(data)), o, u32(len(origin)), 0, 0, 0, 0}
		js_call(p, r.inst, "wj_frames_message", argv[:])
		world_message_end(p, prev)
		if world_alive(p, w) {
			js.guest_free(r.inst, d)
			js.guest_free(r.inst, o)
			js_after_task(p, r, "message")
		}
	}
}

// While realm `inst` fires its message event at the window, only its own listeners take it. Returns what to restore.
world_message_begin :: proc(p: ^Page, inst: ^wasm.Instance) -> u32 {
	if p.ext_doc == nil || len(p.worlds) == 0 { return 0 }
	prev := p.ext_doc.message_owner
	p.ext_doc.message_owner = inst.index + 1
	return prev
}

world_message_end :: proc(p: ^Page, prev: u32) {
	if p.ext_doc != nil { p.ext_doc.message_owner = prev }
}

// Whether listener owner `owner` of object `h` takes event `eh` (run_object_listeners): a message event at the window
// goes to the realm that fired it; everything else to every listener.
world_listener_takes :: proc(p: ^Page, h: u64, eh: base.Handle, owner: u32) -> bool {
	if p.web == nil || h != u64(p.web.window) { return true }
	e := base.pool_get(&p.dp.events, eh)
	if e == nil || (e.type != "message" && e.type != "messageerror") { return true }
	return owner == p.ext_doc.message_owner - 1
}
