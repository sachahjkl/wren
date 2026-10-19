package page

// The JavaScript realm of a page (or of a worker): one instance of the engine module (native/js, embedded by package
// js_image, pre-initialized at build time) per realm, created on first use, living in the page's scope like any of its
// modules (its callbacks are routed by its instance index). The engine's imports are the web API itself (api/*.widl)
// plus module js (js_host.odin, js_events_host.odin).
//
//   * Scripts: js_run_classic / js_run_module compile and run with the bytecode cache (package js): a script seen
//     before (same URL, same source, same engine) runs from its bytecode without being parsed again.
//   * Microtasks: the engine keeps its own job queue (promise reactions, queueMicrotask). The page's microtask
//     checkpoint drains it after the browser's own microtasks, until both queues are empty (js_checkpoint).
//   * Interruption: a task running past javascript.slow_script_ms is stopped cleanly through the engine's interrupt
//     flag (wasm.Instance.soft_flag), the console says so; wasm.max_call_ms (or the engine's hard stop) still applies.
//   * The instance is lenient: a host function given a dead handle answers with its zero value instead of trapping
//     (a trap in the middle of the engine would leave its heap inconsistent).

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:config"
import "wb:dom"
import "wb:js"
import js_image "wb:js/image"
import "wb:wasm"

Js_Realm :: struct {
	inst:            ^wasm.Instance,
	failed:          bool,       // the engine could not start: scripts do not run on this page
	pending_key:     js.Key,     // the bytecode cache key of the script being compiled (Engine_storeBytecode)
	has_pending_key: bool,
	interrupt:       ^i32,       // the engine's interrupt flag, in its memory
	soft_fired:      int,        // slow-script interruptions already reported
}

@(private)
js_engine_version: string

// The engine version of cache keys (the image's digest), computed once.
js_version :: proc() -> string {
	if js_engine_version == "" { js_engine_version = js.image_version(js_image.IMAGE, context.allocator) }
	return js_engine_version
}

// Whether this page runs scripts (javascript.enabled, per site).
js_enabled :: proc(p: ^Page) -> bool {
	return js.enabled_for(&p.settings.js, p.env.location.host)
}

// The page's realm, created on first use; nil when scripts are off or the engine failed to start.
js_realm :: proc(p: ^Page) -> ^Js_Realm {
	if p.js != nil { return p.js.failed ? nil : p.js }
	if p.closed || !js_enabled(p) { return nil }
	r := new(Js_Realm)
	p.js = r
	base.on_close(p.scope, proc(data: rawptr) { free((^Js_Realm)(data)) }, r)

	opt := p.worker != nil ? p.settings.workers.wasm : p.settings.wasm
	slow := p.settings.js.slow_script_ms
	if slow > 0 {
		opt.soft_call_ms = slow
		// the hard stop comes after the engine had time to unwind (or never, when wasm.max_call_ms says so)
		if opt.max_call_ms > 0 && opt.max_call_ms < slow * 2 { opt.max_call_ms = slow * 2 }
	}
	inst, err := wasm.instance_create(js_image.IMAGE, p, p.scope, opt, "javascript", nil)
	if inst == nil {
		r.failed = true
		log(p, .Error, fmt.tprintf("JavaScript could not start: %s", err))
		delete(err)
		return nil
	}
	inst.lenient = true
	inst.index = u32(len(p.instances))
	append(&p.instances, inst)
	r.inst = inst

	seed: u64
	wasm.random_bytes(([^]u8)(&seed)[:8])
	kind := p.worker != nil ? js.Realm_Kind.Worker : js.Realm_Kind.Window
	if !js.realm_start(inst, {kind = kind, seed = seed, max_heap_bytes = p.settings.js.max_heap_bytes, gc_threshold = p.settings.js.gc_threshold_bytes}) {
		r.failed = true
		log(p, .Error, fmt.tprintf("JavaScript could not start: %s", inst.last_error))
		return nil
	}
	if addr := js.interrupt_address(inst); addr != 0 {
		if b := wasm.guest_bytes(inst, u64(addr), 4); b != nil {
			r.interrupt = (^i32)(raw_data(b))
			inst.soft_flag = r.interrupt
		}
	}
	js_load_realm_started(p, r)   // rejections, modules, eval policy (js_load_realm.odin)
	return r
}

@(private)
js_call :: proc(user: rawptr, inst: ^wasm.Instance, name: cstring, argv: []u32) -> wasm.Call_Result {
	p := (^Page)(user)
	res := call_export(p, inst, name, argv)
	if res == .Trapped { js_realm_lost(p) }
	return res
}

// A trap inside the engine (past the hard deadline, out of native stack, out of memory) may have left its heap
// inconsistent: the realm is not used again (the trap was logged by call_export).
js_realm_lost :: proc(p: ^Page) {
	r := p.js
	if r == nil || r.failed { return }
	r.failed = true
	log(p, .Error, "the JavaScript engine of this page was stopped in the middle of its work: scripts no longer run on this page (reload it)")
}

// A call into the realm trapped. When the trap happened in a nested call (the engine called the browser, which called
// back into the engine), the outer call must not go on with the engine's state as the trap left it: it traps too when
// the browser function returns. The instance takes no further calls (instance_by_index skips dead instances).
@(private)
js_trapped :: proc(p: ^Page, inst: ^wasm.Instance) {
	js_realm_lost(p)
	if inst.depth > 0 { wasm.trap(inst, "the JavaScript engine stopped in a nested call") }
	inst.dead = true
}

// After a task of the realm: the slow-script message when the engine had to be interrupted.
@(private)
js_after_task :: proc(p: ^Page, r: ^Js_Realm, what: string) {
	if r.inst.soft_fired > r.soft_fired {
		r.soft_fired = r.inst.soft_fired
		log(p, .Warn, fmt.tprintf("a script took longer than javascript.slow_script_ms (%d ms) and was stopped: %s", p.settings.js.slow_script_ms, what))
	}
}

// Runs a classic script (or a module when `module`). `url` names it in stack traces and in the cache key.
js_run :: proc(p: ^Page, source: []byte, url: string, line: i32 = 1, module := false, print_result := false) -> js.Eval_Status {
	r := js_realm(p)
	if r == nil { return .Trapped }
	flags: js.Eval_Flags
	if module { flags += {.Module} }
	if print_result { flags += {.Print_Result} }
	defer js_after_task(p, r, url)
	if !print_result && js.cacheable(len(source)) {
		key := js.key_of(js_version(), transmute(i32)flags, url, source)
		if code := js.lookup(key, context.temp_allocator); code != nil {
			st := js.eval_bytecode(r.inst, code, flags, js_call, p)
			if st != .Bad_Bytecode { return st }
		}
		r.pending_key = key
		r.has_pending_key = true
		st := js.eval_script(r.inst, source, url, line, flags + {.Want_Bytecode}, js_call, p)
		r.has_pending_key = false
		return st
	}
	return js.eval_script(r.inst, source, url, line, flags, js_call, p)
}

// The engine's part of a microtask checkpoint: its jobs (promise reactions, queueMicrotask). True when some ran.
js_checkpoint :: proc(p: ^Page) -> bool {
	r := p.js
	if r == nil || r.failed || r.inst == nil || r.inst.dead { return false }
	p.objects.depth += 1
	ran := js.run_jobs(r.inst, proc(user: rawptr, inst: ^wasm.Instance, name: cstring, argv: []u32) -> wasm.Call_Result {
		res := wasm.call_raw(inst, name, argv)
		if res != .Ok { guest_failed((^Page)(user), inst) }
		return res
	}, p)
	p.objects.depth -= 1
	return ran > 0
}

// The wrapper interface of a node (index into the engine's table, js_interfaces_generated.odin).
js_node_interface :: proc(p: ^Page, n: ^dom.Node) -> u32 {
	switch n.kind {
	case .Text: return JS_IFACE_Text
	case .Comment: return JS_IFACE_Comment
	case .Document: return JS_IFACE_Document
	case .Element:
	}
	// SVG and MathML elements: the parser keeps no namespace; an element under <svg> (outside <foreignObject>) is SVG
	name := n.name
	if name == "svg" { return JS_IFACE_SVGSVGElement }
	if name == "math" { return JS_IFACE_MathMLElement }
	for cur := n.parent; cur != base.NIL_HANDLE; {
		a := dom.get(p.doc, cur)
		if a == nil || a.kind != .Element { break }
		if a.name == "foreignobject" { break }
		if a.name == "svg" { return js_svg_interface(name) }
		if a.name == "math" { return JS_IFACE_MathMLElement }
		cur = a.parent
	}
	return js_html_interface(name)
}

// Process start: the bytecode cache shared by every realm (memory, and the profile's js-cache folder unless
// `profile_dir` is ""). Process end: js_shutdown (after every page is closed).
js_startup :: proc(prefs: ^config.Prefs, profile_dir: string) {
	s := js.settings_from_prefs(prefs, profile_dir)
	defer js.settings_destroy(&s)
	js.cache_start(s.cache)
}

js_shutdown :: proc() {
	compile_shutdown()   // the compile threads first: they store into the cache (js_load_compile.odin)
	js.cache_stop()
	delete(js_engine_version)
	js_engine_version = ""
}

// Shows the completion value of `source` in the console ("run JavaScript" from the tab's console).
js_console_eval :: proc(p: ^Page, source: string) -> bool {
	if !p.settings.js.console_eval { log(p, .Warn, "javascript.console_eval is off"); return false }
	if js_realm(p) == nil { log(p, .Warn, "JavaScript is off for this page"); return false }
	st := js_run(p, transmute([]byte)source, "console", 1, print_result = true)
	return st == .Ok
}

_ :: strings
