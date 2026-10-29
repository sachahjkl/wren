// qjs_realm.odin: one JavaScript realm per module instance, on QuickJS-ng: the browser's entry points (ported from
// native/js/engine/qjs_realm.c, same exports). The realm's state and what the rest of the engine shares about it
// (interruption, the profiler, reporting, the stack budget) are wj/qjs_realm.odin.
//
// Life of a realm:
//   wj_preinit        (build time, by src/tools/jsengine snapshot) creates the runtime and the context, the platform
//                     classes and every interface object and prototype of the bindings. The memory image after it
//                     returns is what the browser instantiates for each realm: none of this runs again.
//   wj_realm_start    (once per realm) what differs per realm: random state, the global's interfaces for its kind
//                     (Window or Worker), limits.
//   wj_eval_* / callbacks / wj_run_jobs   the browser's tasks and microtask checkpoints.
//
// Interruption: the browser sets wj_interrupt (in this memory; its address is exported) when a task runs past
// javascript.slow_script_ms; QuickJS polls it through the interrupt handler and unwinds with an uncatchable error,
// leaving the engine consistent. Wasmtime's own deadline (wasm.max_call_ms, longer) remains the hard stop.
package odin_glue

import "base:runtime"
import "../odin/wj"

// tools/build_js.ps1 -Allocator mimalloc: the engine's heap through mimalloc, the C library's own through dlmalloc
WJ_MIMALLOC :: #config(WJ_MIMALLOC, false)

// ---- jobs (microtasks): run by the browser at each microtask checkpoint ----

@(export, link_name = "wj_run_jobs")
wj_run_jobs :: proc "c" () -> i32 {
	ctx := wj.wj_the_realm.ctx
	if ctx == nil { return 0 }
	rt := wj.JS_GetRuntime(ctx)
	ran: i32
	wj.wj_stack_enter(ctx)
	for wj.JS_IsJobPending(rt) {
		jctx: ^wj.Context
		if wj.JS_ExecutePendingJob(rt, &jctx) < 0 { wj.wj_report_pending(jctx) }
		ran += 1
		// the checkpoint itself ran past the time limit: what is left would start the same endless chain again at the
		// next checkpoint, and stall every task after it
		if wj.interrupted() { wj.JS_DropPendingJobs(rt); break }
	}
	return ran
}

// ---- evaluation ----

@(private = "file") EVAL_MODULE        :: 1 << 0
@(private = "file") EVAL_WANT_BYTECODE :: 1 << 1   // hand the compiled code to the browser (Engine_storeBytecode)
@(private = "file") EVAL_STRICT        :: 1 << 2
@(private = "file") EVAL_RESULT        :: 1 << 3   // print the completion value (the console's "run JavaScript")

// Runs a compiled script or module function (takes it). 0 ok, 1 threw (reported).
@(private = "file")
run_compiled :: proc "contextless" (ctx: ^wj.Context, fn: wj.JSValue, flags: i32) -> i32 {
	r := wj.JS_EvalFunction(ctx, fn)
	if wj.is_exception(r) {
		wj.wj_report_pending(ctx)
		return 1
	}
	if flags & EVAL_MODULE != 0 {
		// a module evaluates to a promise: its rejection is an uncaught error of the module
		if wj.JS_IsPromise(r) && wj.JS_PromiseState(ctx, r) == .Rejected {
			reason := wj.JS_PromiseResult(ctx, r)
			wj.JS_PromiseMarkAsHandled(ctx, r)
			wj.wj_report_exception(ctx, reason)
			wj.JS_FreeValue(ctx, r)
			return 1
		}
	}
	if flags & EVAL_RESULT != 0 { wj_console_inspect_result(ctx, r) }
	wj.JS_FreeValue(ctx, r)
	return 0
}

// A script's name (in this memory, `url_len` bytes) as a NUL-terminated copy in `name`.
@(private = "file")
copy_name :: proc "contextless" (name: []u8, url: u32, url_len: u32) -> cstring {
	n := min(int(url_len), len(name) - 1)
	if n > 0 { wj.memcpy(&name[0], rawptr(uintptr(url)), uint(n)) }
	name[n] = 0
	return cstring(&name[0])
}

// Compiles and runs a classic script or a module. `src` and `url` are in this memory (the browser allocated them with
// wj_alloc and frees them). Returns 0, 1 when it threw (reported), 2 when it did not compile (reported).
@(export, link_name = "wj_eval_script")
wj_eval_script :: proc "c" (src: u32, src_len: u32, url: u32, url_len: u32, line: i32, flags: i32) -> i32 {
	ctx := wj.wj_the_realm.ctx
	wj.wj_stack_enter(ctx)
	name: [1024]u8
	opt := wj.Eval_Options{
		version    = wj.EVAL_OPTIONS_VERSION,
		eval_flags = (flags & EVAL_MODULE != 0 ? wj.EVAL_TYPE_MODULE : wj.EVAL_TYPE_GLOBAL) | wj.EVAL_FLAG_COMPILE_ONLY |
		             (flags & EVAL_STRICT != 0 ? wj.EVAL_FLAG_STRICT : 0),
		filename   = copy_name(name[:], url, url_len),
		line_num   = line > 0 ? line : 1,
	}
	// QuickJS wants a NUL after the source: the browser allocated src_len + 1 bytes
	fn := wj.JS_Eval2(ctx, ([^]u8)(uintptr(src)), uint(src_len), &opt)
	if wj.is_exception(fn) {
		wj.wj_report_pending(ctx)
		return 2
	}
	if flags & EVAL_WANT_BYTECODE != 0 {
		size: uint
		code := wj.JS_WriteObject(ctx, &size, fn, wj.WRITE_OBJ_BYTECODE)
		if code != nil {
			wj.wr_Engine_storeBytecode(code, u32(size))
			wj.js_free(ctx, code)
		} else if wj.JS_HasException(ctx) {
			wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
		}
	}
	if flags & EVAL_MODULE != 0 && wj.JS_ResolveModule(ctx, fn) < 0 {
		wj.JS_FreeValue(ctx, fn)
		wj.wj_report_pending(ctx)
		return 2
	}
	return run_compiled(ctx, fn, flags)
}

// Runs bytecode the browser had cached for a script (from Engine_storeBytecode of an earlier run). 3 when the bytecode
// cannot be read (the browser compiles the source instead).
@(export, link_name = "wj_eval_bytecode")
wj_eval_bytecode :: proc "c" (code: u32, code_len: u32, flags: i32) -> i32 {
	ctx := wj.wj_the_realm.ctx
	wj.wj_stack_enter(ctx)
	fn := wj.JS_ReadObject(ctx, ([^]u8)(uintptr(code)), uint(code_len), wj.READ_OBJ_BYTECODE)
	if wj.is_exception(fn) {
		wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
		return 3
	}
	if flags & EVAL_MODULE != 0 && wj.JS_ResolveModule(ctx, fn) < 0 {
		wj.JS_FreeValue(ctx, fn)
		wj.wj_report_pending(ctx)
		return 2
	}
	return run_compiled(ctx, fn, flags)
}

// Compiles only (a compilation worker filling the bytecode cache, off the page's thread). 0 ok (bytecode stored), 2
// syntax error (not reported: the page reports it when it runs the script).
@(export, link_name = "wj_compile")
wj_compile :: proc "c" (src: u32, src_len: u32, url: u32, url_len: u32, line: i32, flags: i32) -> i32 {
	ctx := wj.wj_the_realm.ctx
	wj.wj_stack_enter(ctx)
	name: [1024]u8
	opt := wj.Eval_Options{
		version    = wj.EVAL_OPTIONS_VERSION,
		eval_flags = (flags & EVAL_MODULE != 0 ? wj.EVAL_TYPE_MODULE : wj.EVAL_TYPE_GLOBAL) | wj.EVAL_FLAG_COMPILE_ONLY,
		filename   = copy_name(name[:], url, url_len),
		line_num   = line > 0 ? line : 1,
	}
	fn := wj.JS_Eval2(ctx, ([^]u8)(uintptr(src)), uint(src_len), &opt)
	if wj.is_exception(fn) {
		wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
		return 2
	}
	size: uint
	code := wj.JS_WriteObject(ctx, &size, fn, wj.WRITE_OBJ_BYTECODE)
	wj.JS_FreeValue(ctx, fn)
	if code == nil {
		if wj.JS_HasException(ctx) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)) }
		return 2
	}
	wj.wr_Engine_storeBytecode(code, u32(size))
	wj.js_free(ctx, code)
	return 0
}

// ---- memory ----

// Runs a full collection (the browser calls it when a page is idle or hidden).
@(export, link_name = "wj_gc")
wj_gc :: proc "c" () {
	if wj.wj_the_realm.ctx != nil { wj.JS_RunGC(wj.JS_GetRuntime(wj.wj_the_realm.ctx)) }
}

// Bytes the engine's heap holds (malloc'd by QuickJS).
@(export, link_name = "wj_heap_bytes")
wj_heap_bytes :: proc "c" () -> f64 {
	if wj.wj_the_realm.ctx == nil { return 0 }
	u: wj.Memory_Usage
	wj.JS_ComputeMemoryUsage(wj.JS_GetRuntime(wj.wj_the_realm.ctx), &u)
	return f64(u.malloc_size)
}

// Counter `index` of the Odin engine's heap census (jsrt memprof.odin; jsengine mem prints it), -1 past the end.
when wj.WJ_JSRT {
	@(export, link_name = "wj_heap_profile")
	wj_heap_profile :: proc "c" (index: i32) -> f64 {
		if wj.wj_the_realm.ctx == nil { return -1 }
		return f64(wj.heap_profile_field(wj.JS_GetRuntime(wj.wj_the_realm.ctx), index))
	}
}

// ---- life cycle ----

when WJ_MIMALLOC {
	@(default_calling_convention = "c")
	foreign {
		mi_calloc       :: proc(n: uint, s: uint) -> rawptr ---
		mi_malloc       :: proc(s: uint) -> rawptr ---
		mi_free         :: proc(p: rawptr) ---
		mi_realloc      :: proc(p: rawptr, s: uint) -> rawptr ---
		mi_usable_size  :: proc(p: rawptr) -> uint ---
	}
	@(private = "file") mi_functions: wj.Malloc_Functions
	@(private = "file")
	new_runtime :: proc "contextless" () -> ^wj.Runtime {
		mi_functions = wj.Malloc_Functions{
			js_calloc = proc "c" (o: rawptr, n: uint, s: uint) -> rawptr { return mi_calloc(n, s) },
			js_malloc = proc "c" (o: rawptr, s: uint) -> rawptr { return mi_malloc(s) },
			js_free = proc "c" (o: rawptr, p: rawptr) { mi_free(p) },
			js_realloc = proc "c" (o: rawptr, p: rawptr, s: uint) -> rawptr { return mi_realloc(p, s) },
			js_malloc_usable_size = proc "c" (p: rawptr) -> uint { return mi_usable_size(p) },
		}
		return wj.JS_NewRuntime2(&mi_functions, nil)
	}
} else {
	@(private = "file")
	new_runtime :: #force_inline proc "contextless" () -> ^wj.Runtime { return wj.JS_NewRuntime() }
}

@(private = "file") _runtime_used :: runtime.Context

// Build time: everything that does not depend on the realm. 0 ok.
// The WASI reactor's entry, which the host calls first (src/wasm, src/tools/jsengine). With no C library in the module
// there is nothing to initialize: the engine starts in wj_preinit.
@(export, link_name = "_initialize")
wj_initialize :: proc "c" () {}

@(export, link_name = "wj_preinit")
wj_preinit :: proc "c" () -> i32 {
	if wj.wj_the_realm.ctx != nil { return 0 }
	// This module is built without the Odin runtime's start-up (-no-entry-point): the initialisation of every package-level
	// variable that is not a constant (tables with strings and nil, maps, @(init) procedures: the front-end's keyword tables,
	// the engine's atoms) has not run. Run it once, here; the image made after pre-initialization keeps the result.
	context = wj.heap_context()
	when wj.WJ_JSRT { runtime._startup_runtime() }
	wj_install_bindings()
	wj.error_event_hook = wj_fire_error_event
	rt := new_runtime()
	if rt == nil { return -1 }
	// well below the C stack the module reserves (build_js.ps1: -z stack-size, 1 MiB): 256 KiB stay for what runs past
	// the bound before the engine unwinds (an uncaught RangeError's report, deep in a recursion through the browser)
	wj.JS_SetMaxStackSize(rt, wj.STACK_BUDGET)
	wj.JS_SetInterruptHandler(rt, wj.interrupt_handler, nil)
	ctx := wj.JS_NewContext(rt)
	if ctx == nil { return -2 }
	wj.wj_the_realm.ctx = ctx
	wj.wj_the_realm.global = wj.JS_GetGlobalObject(ctx)
	// QuickJS-ng's own `performance` (JS_AddPerformance) took its timeOrigin from the clock of the machine that made
	// the image (pre-initialization runs at build time): after a reboot its now() went negative. Every realm gets the
	// browser's Performance (WindowOrWorkerGlobalScope.performance), on the page's clock.
	performance := wj.JS_NewAtom(ctx, "performance")
	wj.JS_DeleteProperty(ctx, wj.wj_the_realm.global, performance, 0)
	wj.JS_FreeAtom(ctx, performance)
	if wj.wj_platform_preinit(ctx) != 0 || wj_runtime_preinit(ctx) != 0 { return -3 }
	// what the snapshot keeps should not include garbage
	wj.JS_RunGC(rt)
	return 0
}

// wj_realm_start flags
@(private = "file") START_EXPOSE_UNIMPLEMENTED :: 1
@(private = "file") START_UNIMPLEMENTED_THROW  :: 2
@(private = "file") START_NO_TOUCH_HANDLERS    :: 4
@(private = "file") START_SHARED_WORKER        :: 8    // (a worker realm of that kind)
@(private = "file") START_SERVICE_WORKER       :: 16
@(private = "file") START_FRAMES               :: 32

// browser.touch.expose off (or auto without a touch screen): the ontouch* event handler attributes and the Touch,
// TouchEvent and TouchList interfaces are not exposed, as in Firefox on such a computer; pages test 'ontouchstart' in
// window or 'TouchEvent' in window to pick a phone's layout and behaviour (Modernizr's touch class). The handlers live on
// the prototypes GlobalEventHandlers is mixed into, and on the global object for the Window's.
@(private = "file") touch_names := [?]cstring{"ontouchstart", "ontouchend", "ontouchmove", "ontouchcancel", "Touch", "TouchEvent", "TouchList"}
@(private = "file") touch_ifaces := [?]cstring{"Window", "Document", "HTMLElement", "SVGElement", "MathMLElement"}

@(private = "file")
remove_touch_handlers :: proc "contextless" (ctx: ^wj.Context) {
	for name in touch_names {
		a := wj.JS_NewAtom(ctx, name)
		for iname in touch_ifaces {
			i := wj.wj_interface_find(iname)
			if i < 0 { continue }
			proto := wj.wj_the_realm.protos[i]
			// (a prototype still lazy leaves these out itself, qjs_platform.odin's lazy_proto_members)
			if wj.is_object(proto) && !wj.JS_HasLazyMembers(proto) { wj.JS_DeleteProperty(ctx, proto, a, 0) }
		}
		wj.JS_DeleteProperty(ctx, wj.wj_the_realm.global, a, 0)
		wj.JS_FreeAtom(ctx, a)
	}
}

// Run time, once per realm: kind 1 = Window, 2 = Worker. `seed` reseeds Math.random. flags: START_*. 0 ok.
@(export, link_name = "wj_realm_start")
wj_realm_start :: proc "c" (kind: i32, seed: i64, memory_limit: f64, gc_threshold: f64, flags: i32) -> i32 {
	wj.wj_start_frames = flags & START_FRAMES != 0   // a page's realm: the frames.* imports exist (the engine run alone has none)
	wj.wj_start_expose_unimplemented = flags & START_EXPOSE_UNIMPLEMENTED != 0
	wj.wj_start_unimplemented_throw = flags & START_UNIMPLEMENTED_THROW != 0
	wj.wj_start_no_touch = flags & START_NO_TOUCH_HANDLERS != 0
	if wj.wj_the_realm.ctx == nil && wj_preinit() != 0 { return -1 }
	if wj.wj_the_realm.started { return 0 }
	ctx := wj.wj_the_realm.ctx
	rt := wj.JS_GetRuntime(ctx)
	wj.wj_stack_enter(ctx)
	wj.JS_SetRandomState(ctx, u64(seed))
	if memory_limit > 0 { wj.JS_SetMemoryLimit(rt, uint(memory_limit)) }
	if gc_threshold > 0 {
		wj.JS_SetGCThreshold(rt, uint(gc_threshold))
		wj.JS_SetGCThresholdFloor(rt, uint(gc_threshold))
	}
	wj.wj_the_realm.kind = kind
	scope := kind
	if kind == wj.EXPOSE_WORKER && flags & START_SHARED_WORKER != 0 { scope = wj.EXPOSE_SHARED_WORKER }
	if kind == wj.EXPOSE_WORKER && flags & START_SERVICE_WORKER != 0 { scope = wj.EXPOSE_SERVICE_WORKER }
	wj.wj_the_realm.scope = scope
	// the global's interfaces for its scope, then what the runtime adds (given window or worker)
	if wj.wj_platform_start(ctx, scope) != 0 || wj_runtime_start(ctx, scope == wj.EXPOSE_WINDOW ? wj.EXPOSE_WINDOW : wj.EXPOSE_WORKER) != 0 { return -2 }
	if flags & START_NO_TOUCH_HANDLERS != 0 { remove_touch_handlers(ctx) }
	wj.wj_the_realm.started = true
	return 0
}
