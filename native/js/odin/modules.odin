// modules.odin: ECMAScript modules as HTML loads them ("fetch a module script graph", "resolve a module specifier",
// import(), import.meta), ported from native/js/runtime/modules.c with the same exports.
//
// QuickJS loads the modules a module imports synchronously, while it links it; a browser fetches them over the network.
// So the browser fetches the whole graph first (src/page/js_load_modules.odin):
//   1. each module's source, once it arrived, is compiled here without being run (wj_module_prepare), which registers
//      it with the engine under its URL and tells the browser what it imports (Module_request: the browser resolves the
//      specifier, import maps included, and fetches what it does not have yet);
//   2. once every module of the graph is there, the root is linked and evaluated (wj_module_run): the engine finds the
//      imports among the modules it compiled (normalize = the browser's resolution); a module the engine let go of
//      meanwhile (a failed link frees every unlinked module) is compiled again from the browser's copy (the loader).
// import() goes through the browser the same way (the dynamic import hook): it starts the graph, and calls
// wj_module_import_done in a task of its own when the graph is complete or failed.
//
// Module names are absolute URLs; an inline <script type=module> is named after its document with a
// "#inline-module-<n>" fragment (relative specifiers resolve against the document, import.meta.url is the document's
// URL). JSON modules (import ... with {type: "json"}) are synthetic modules whose default export is the parsed value.
package odin_glue

import "../odin/wj"

@(private = "file") MODULE_JS   :: 0
@(private = "file") MODULE_JSON :: 1

@(private = "file") INLINE_MARK :: "#inline-module-"

// ---- strings from the browser ----

// A NUL-terminated copy (js_malloc) of `n` bytes at `p`, or nil.
@(private = "file")
js_cstr :: proc "contextless" (ctx: ^wj.Context, p: [^]u8, n: int) -> cstring {
	m := max(n, 0)
	s := ([^]u8)(wj.js_malloc(ctx, uint(m) + 1))
	if s == nil { return nil }
	if m > 0 { wj.memcpy(s, p, uint(m)) }
	s[m] = 0
	return cstring(s)
}

// The error message the browser recorded for its last failed call (web.Exception_message), into `buf`.
@(private = "file")
browser_message :: proc "contextless" (buf: []u8, fallback: cstring) {
	n := wj.fetch_string(wj.wr_Exception_message)
	if n <= 0 { wj.snprintf(&buf[0], len(buf), "%s", fallback); return }
	size := min(int(n), len(buf) - 1)
	wj.memcpy(&buf[0], wj.wj_scratch.data, uint(size))
	buf[size] = 0
}

@(private = "file")
throw_resolve_failure :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	msg: [512]u8
	browser_message(msg[:], "Failed to resolve module specifier")
	return wj.JS_ThrowTypeError(ctx, "%s", cstring(&msg[0]))
}

// Module_resolve(spec, base) into the scratch buffer: the length or a negative Error.
@(private = "file")
resolve :: proc "contextless" (spec: [^]u8, spec_len: uint, base: [^]u8, base_len: uint) -> i32 {
	n := wj.wr_Module_resolve(spec, u32(spec_len), base, u32(base_len), wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap {
		if !wj.wj_scratch_grow(u32(n)) { return -13 }
		n = wj.wr_Module_resolve(spec, u32(spec_len), base, u32(base_len), wj.wj_scratch.data, wj.wj_scratch.cap)
	}
	return n
}

// ---- import.meta ----

@(private = "file")
meta_resolve :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	if argc < 1 { return wj.wj_throw_arity(ctx, "import.meta.resolve", 1, argc) }
	spec, base: wj.Str
	if !wj.wj_to_str(ctx, argv[0], &spec, 0, "") { return wj.EXCEPTION }
	if !wj.wj_to_str(ctx, data[0], &base, 0, "") { wj.wj_str_free(ctx, &spec); return wj.EXCEPTION }
	n := resolve(wj.cstr_bytes(spec.ptr), spec.len, wj.cstr_bytes(base.ptr), base.len)
	wj.wj_str_free(ctx, &spec)
	wj.wj_str_free(ctx, &base)
	if n < 0 { return throw_resolve_failure(ctx) }
	return wj.scratch_string(ctx, n)
}

// import.meta.url (the module's URL, the document's for an inline module) and import.meta.resolve.
@(private = "file")
set_meta :: proc "contextless" (ctx: ^wj.Context, m: ^wj.Module_Def, name: cstring) -> i32 {
	meta := wj.JS_GetImportMeta(ctx, m)
	if wj.is_exception(meta) { return -1 }
	p := ([^]u8)(rawptr(name))
	total := int(wj.strlen(name))
	mark := wj.index_of(p, total, INLINE_MARK)
	n := mark >= 0 ? mark : total
	wj.JS_DefinePropertyValueStr(ctx, meta, "url", wj.JS_NewStringLen(ctx, p, uint(n)), wj.PROP_C_W_E)
	base := wj.JS_NewString(ctx, name)
	fn := wj.JS_NewCFunctionData(ctx, meta_resolve, 1, 0, 1, &base)
	wj.JS_FreeValue(ctx, base)
	wj.JS_DefinePropertyValueStr(ctx, meta, "resolve", fn, wj.PROP_C_W_E)
	wj.JS_FreeValue(ctx, meta)
	return 0
}

// ---- compiling ----

@(private = "file")
json_module_init :: proc "c" (ctx: ^wj.Context, m: ^wj.Module_Def) -> i32 {
	v := wj.JS_GetModulePrivateValue(ctx, m)
	return wj.JS_SetModuleExport(ctx, m, "default", v)
}

// Compiles a module named `name` (registered with the engine, not run): its module, nil with an exception pending.
// `want_bytecode`: the compiled module goes to the browser's bytecode cache (Engine_storeBytecode) before anything else is done to it.
@(private = "file")
compile_module :: proc "contextless" (ctx: ^wj.Context, src: [^]u8, n: uint, name: cstring, type: i32, want_bytecode := false) -> ^wj.Module_Def {
	if type == MODULE_JSON {
		// JS_ParseJSON reads a NUL-terminated buffer: the host's source is not one
		buf := ([^]u8)(wj.malloc(n + 1))
		if buf == nil { return nil }
		defer wj.free(buf)
		wj.memcpy(buf, src, n)
		buf[n] = 0
		v := wj.JS_ParseJSON(ctx, buf, n, name)
		if wj.is_exception(v) { return nil }
		m := wj.JS_NewCModule(ctx, name, json_module_init)
		if m == nil { wj.JS_FreeValue(ctx, v); return nil }
		if wj.JS_AddModuleExport(ctx, m, "default") < 0 { wj.JS_FreeValue(ctx, v); return nil }
		wj.JS_SetModulePrivateValue(ctx, m, v)
		return m
	}
	opt := wj.Eval_Options{
		version    = wj.EVAL_OPTIONS_VERSION,
		eval_flags = wj.EVAL_TYPE_MODULE | wj.EVAL_FLAG_COMPILE_ONLY | wj.EVAL_FLAG_WREN_NO_RESOLVE,
		filename   = name,
		line_num   = 1,
	}
	fn := wj.JS_Eval2(ctx, src, n, &opt)
	if wj.is_exception(fn) { return nil }
	if want_bytecode {
		size: uint
		code := wj.JS_WriteObject(ctx, &size, fn, wj.WRITE_OBJ_BYTECODE)
		if code != nil {
			wj.wr_Engine_storeBytecode(code, u32(size))
			wj.js_free(ctx, code)
		} else if wj.JS_HasException(ctx) {
			wj.JS_FreeValue(ctx, wj.JS_GetException(ctx))
		}
	}
	m := (^wj.Module_Def)(wj.value_get_ptr(fn))
	if set_meta(ctx, m, name) < 0 { wj.JS_FreeValue(ctx, fn); return nil }
	wj.JS_FreeValue(ctx, fn)   // the engine keeps the module among its loaded ones
	return m
}

// The modules `m` imports, told to the browser (it resolves them and fetches what it does not have). 0 ok, 2 an import cannot be resolved
// (its error to rethrow is kept, not reported now).
@(private = "file")
report_requests :: proc "contextless" (ctx: ^wj.Context, m: ^wj.Module_Def, name: cstring, url_len: u32) -> i32 {
	n := wj.JS_GetModuleRequestCount(m)
	status: i32 = 0
	for i: i32 = 0; i < n && status == 0; i += 1 {
		attrs := wj.UNDEFINED
		a := wj.JS_GetModuleRequest(ctx, m, i, &attrs)
		if a == wj.ATOM_NULL { wj.JS_FreeValue(ctx, attrs); continue }
		t := import_type(ctx, attrs)
		wj.JS_FreeValue(ctx, attrs)
		sl: uint
		spec := wj.JS_AtomToCStringLen(ctx, &sl, a)
		wj.JS_FreeAtom(ctx, a)
		if t < 0 || spec == nil {
			if spec != nil { wj.JS_FreeCString(ctx, spec) }
			rethrow_keep(ctx, name, wj.JS_GetException(ctx))
			status = 2
			break
		}
		if wj.wr_Module_request(([^]u8)(rawptr(name)), url_len, ([^]u8)(rawptr(spec)), u32(sl), t) < 0 {
			throw_resolve_failure(ctx)
			rethrow_keep(ctx, name, wj.JS_GetException(ctx))
			status = 2
		}
		wj.JS_FreeCString(ctx, spec)
	}
	return status
}

// The type of an import from its attributes: MODULE_JS, MODULE_JSON, -1 (TypeError pending) for another.
@(private = "file")
import_type :: proc "contextless" (ctx: ^wj.Context, attributes: wj.JSValue) -> i32 {
	if !wj.is_object(attributes) { return MODULE_JS }
	t := wj.JS_GetPropertyStr(ctx, attributes, "type")
	if wj.is_exception(t) { return -1 }
	if wj.is_undefined(t) { return MODULE_JS }
	s := wj.JS_ToCStringLen2(ctx, nil, t, false)
	wj.JS_FreeValue(ctx, t)
	if s == nil { return -1 }
	r: i32 = wj.str_eq(s, "json") ? MODULE_JSON : -1
	if r < 0 { wj.JS_ThrowTypeError(ctx, "unsupported module type \"%s\"", s) }
	wj.JS_FreeCString(ctx, s)
	return r
}

// ---- errors to rethrow ----

// HTML keeps a module script's parse error (or an import it cannot resolve) as its "error to rethrow": reported when a
// <script type=module> of that graph runs, the rejection of an import() of it. Kept here by module name.
@(private = "file")
Rethrow :: struct { name: [^]u8, name_len: uint, error: wj.JSValue }

@(private = "file") rethrows: [^]Rethrow
@(private = "file") rethrow_n, rethrow_cap: u32

@(private = "file")
rethrow_find :: proc "contextless" (name: [^]u8, n: uint) -> ^Rethrow {
	for i: u32 = 0; i < rethrow_n; i += 1 {
		r := &rethrows[i]
		if r.name_len == n && (n == 0 || wj.memcmp(r.name, name, n) == 0) { return r }
	}
	return nil
}

// Keeps `error` (taken) as the error to rethrow of module `name`.
@(private = "file")
rethrow_keep :: proc "contextless" (ctx: ^wj.Context, name: cstring, error: wj.JSValue) {
	p := ([^]u8)(rawptr(name))
	n := wj.strlen(name)
	if r := rethrow_find(p, n); r != nil {
		wj.JS_FreeValue(ctx, r.error)
		r.error = error
		return
	}
	if rethrow_n == rethrow_cap {
		cap := rethrow_cap != 0 ? rethrow_cap * 2 : 8
		nr := ([^]Rethrow)(wj.libc_realloc(rethrows, uint(cap) * size_of(Rethrow)))
		if nr == nil { wj.JS_FreeValue(ctx, error); return }
		rethrows = nr
		rethrow_cap = cap
	}
	kept := wj.web_strndup(p, n)
	if kept == nil { wj.JS_FreeValue(ctx, error); return }
	rethrows[rethrow_n] = Rethrow{kept, n, error}
	rethrow_n += 1
}

// The error to rethrow of module `name` (a new reference), or undefined.
@(private = "file")
rethrow_get :: proc "contextless" (ctx: ^wj.Context, name: [^]u8, n: uint) -> wj.JSValue {
	r := rethrow_find(name, n)
	return r != nil ? wj.JS_DupValue(ctx, r.error) : wj.UNDEFINED
}

// A module script whose graph has a module with an error to rethrow runs: the error is reported (HTML "run a module
// script").
@(export, link_name = "wj_module_report")
wj_module_report :: proc "c" (url: u32, url_len: u32) {
	ctx := wj.wj_the_realm.ctx
	wj.wj_stack_enter(ctx)
	e := rethrow_get(ctx, ([^]u8)(uintptr(url)), uint(url_len))
	if !wj.is_undefined(e) { wj.wj_report_exception(ctx, e) }
}

// The browser has a module's source: compile it and tell the browser what it imports. 0 ok, 2 it does not compile or
// one of its imports cannot be resolved (its error to rethrow is kept, not reported now).
@(export, link_name = "wj_module_prepare")
wj_module_prepare :: proc "c" (src: u32, src_len: u32, url: u32, url_len: u32, type: i32) -> i32 {
	ctx := wj.wj_the_realm.ctx
	wj.wj_stack_enter(ctx)
	name := js_cstr(ctx, ([^]u8)(uintptr(url)), int(url_len))
	if name == nil { return 2 }
	defer wj.js_free(ctx, rawptr(name))
	// the type's bit 8: the compiled module goes to the browser's bytecode cache
	m := compile_module(ctx, ([^]u8)(uintptr(src)), uint(src_len), name, type & 0xff, type & PREPARE_WANT_BYTECODE != 0)
	if m == nil { rethrow_keep(ctx, name, wj.JS_GetException(ctx)); return 2 }
	return report_requests(ctx, m, name, url_len)
}

@(private = "file") PREPARE_WANT_BYTECODE :: 1 << 8

// The same from a module the browser compiled before (its bytecode, from the cache): read instead of parsed. 0 ok, 2 an import cannot be resolved,
// 3 the bytecode cannot be read (the browser compiles the source instead).
@(export, link_name = "wj_module_prepare_bytecode")
wj_module_prepare_bytecode :: proc "c" (code: u32, code_len: u32, url: u32, url_len: u32) -> i32 {
	ctx := wj.wj_the_realm.ctx
	wj.wj_stack_enter(ctx)
	name := js_cstr(ctx, ([^]u8)(uintptr(url)), int(url_len))
	if name == nil { return 3 }
	defer wj.js_free(ctx, rawptr(name))
	fn := wj.JS_ReadObject(ctx, ([^]u8)(uintptr(code)), uint(code_len), wj.READ_OBJ_BYTECODE)
	if wj.is_exception(fn) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return 3 }
	m := (^wj.Module_Def)(wj.value_get_ptr(fn))
	if set_meta(ctx, m, name) < 0 { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); wj.JS_FreeValue(ctx, fn); return 3 }
	wj.JS_FreeValue(ctx, fn)   // the engine keeps the module among its loaded ones
	return report_requests(ctx, m, name, url_len)
}

// ---- the engine's module loader: resolution and modules it does not have ----

@(private = "file")
module_normalize :: proc "c" (ctx: ^wj.Context, base: cstring, spec: cstring, opaque: rawptr) -> cstring {
	n := resolve(([^]u8)(rawptr(spec)), wj.strlen(spec), ([^]u8)(rawptr(base)), wj.strlen(base))
	if n < 0 { throw_resolve_failure(ctx); return nil }
	return js_cstr(ctx, wj.wj_scratch.data, int(n))
}

@(private = "file")
module_loader :: proc "c" (ctx: ^wj.Context, name: cstring, opaque: rawptr, attributes: wj.JSValue) -> ^wj.Module_Def {
	type := import_type(ctx, attributes)
	if type < 0 { return nil }
	nl := wj.strlen(name)
	n := wj.wr_Module_source(([^]u8)(rawptr(name)), u32(nl), wj.wj_scratch.data, wj.wj_scratch.cap)
	if n > 0 && u32(n) > wj.wj_scratch.cap {
		if !wj.wj_scratch_grow(u32(n)) { n = -13 } else { n = wj.wr_Module_source(([^]u8)(rawptr(name)), u32(nl), wj.wj_scratch.data, wj.wj_scratch.cap) }
	}
	if n < 0 {
		wj.JS_ThrowTypeError(ctx, "Failed to load module script: %s", name)
		return nil
	}
	// the scratch buffer may move while compiling (nested calls): a copy
	src := js_cstr(ctx, wj.wj_scratch.data, int(n))
	if src == nil { return nil }
	m := compile_module(ctx, ([^]u8)(rawptr(src)), uint(n), name, type)
	wj.js_free(ctx, rawptr(src))
	return m
}

@(private = "file")
module_check_attributes :: proc "c" (ctx: ^wj.Context, opaque: rawptr, attributes: wj.JSValue) -> i32 {
	tab: [^]wj.Property_Enum
	n: u32
	if wj.JS_GetOwnPropertyNames(ctx, &tab, &n, attributes, wj.GPN_STRING_MASK | wj.GPN_ENUM_ONLY) < 0 { return -1 }
	r: i32 = 0
	for i: u32 = 0; i < n && r == 0; i += 1 {
		k := wj.JS_AtomToCStringLen(ctx, nil, tab[i].atom)
		if k != nil && !wj.str_eq(k, "type") { wj.JS_ThrowSyntaxError(ctx, "unsupported import attribute \"%s\"", k); r = -1 }
		if k != nil { wj.JS_FreeCString(ctx, k) }
	}
	wj.JS_FreePropertyEnum(ctx, tab, n)
	return r
}

// ---- running a graph ----

@(private = "file")
evaluation_rejected :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	wj.wj_report_exception(ctx, wj.JS_DupValue(ctx, argc > 0 ? argv[0] : wj.UNDEFINED))
	return wj.UNDEFINED
}

// Links and evaluates the module graph whose root is `url` (every module of it prepared). 0 ok (or still evaluating:
// top-level await), 1 it threw (reported, now or when its evaluation settles).
@(export, link_name = "wj_module_run")
wj_module_run :: proc "c" (url: u32, url_len: u32) -> i32 {
	ctx := wj.wj_the_realm.ctx
	wj.wj_stack_enter(ctx)
	name := js_cstr(ctx, ([^]u8)(uintptr(url)), int(url_len))
	if name == nil { return 1 }
	promise := wj.JS_LoadModule(ctx, "", name)
	wj.js_free(ctx, rawptr(name))
	if wj.is_exception(promise) { wj.wj_report_pending(ctx); return 1 }
	status: i32 = 0
	#partial switch wj.JS_PromiseState(ctx, promise) {
	case .Rejected:
		reason := wj.JS_PromiseResult(ctx, promise)
		wj.JS_PromiseMarkAsHandled(ctx, promise)
		wj.wj_report_exception(ctx, reason)
		status = 1
	case .Pending:
		// top-level await: a later rejection is reported when it happens
		on_reject := wj.JS_NewCFunctionData(ctx, evaluation_rejected, 1, 0, 0, nil)
		// the engine's own then (Promise.prototype.then may be a script's by now)
		r := wj.JS_PromiseThen(ctx, promise, wj.UNDEFINED, on_reject)
		if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
		wj.JS_FreeValue(ctx, on_reject)
	}
	wj.JS_FreeValue(ctx, promise)
	return status
}

// ---- import() ----

@(private = "file")
Pending_Import :: struct {
	used:       bool,
	funcs:      [2]wj.JSValue,   // resolve, reject (counted)
	attributes: wj.JSValue,      // counted
}

@(private = "file") imports: [^]Pending_Import
@(private = "file") import_cap: u32

@(private = "file")
import_hook :: proc "c" (ctx: ^wj.Context, basename, specifier, attributes: wj.JSValue, resolving_funcs: [^]wj.JSValue, opaque: rawptr) -> i32 {
	type := import_type(ctx, attributes)
	if type < 0 { return -1 }
	id: u32 = 0
	for id < import_cap && imports[id].used { id += 1 }
	if id == import_cap {
		cap := import_cap != 0 ? import_cap * 2 : 16
		n := ([^]Pending_Import)(wj.libc_realloc(imports, uint(cap) * size_of(Pending_Import)))
		if n == nil { wj.JS_ThrowOutOfMemory(ctx); return -1 }
		wj.memset(&n[import_cap], 0, uint(cap - import_cap) * size_of(Pending_Import))
		imports = n
		import_cap = cap
	}
	spec, base: wj.Str
	if !wj.wj_to_str(ctx, specifier, &spec, 0, "") { return -1 }
	// code without a script (a function made by new Function in a handler...): the document is its base
	if wj.is_string(basename) && !wj.wj_to_str(ctx, basename, &base, 0, "") {
		wj.wj_str_free(ctx, &spec)
		return -1
	}
	pi := &imports[id]
	pi.used = true
	pi.funcs[0] = wj.JS_DupValue(ctx, resolving_funcs[0])
	pi.funcs[1] = wj.JS_DupValue(ctx, resolving_funcs[1])
	pi.attributes = wj.JS_DupValue(ctx, attributes)
	st := wj.wr_Module_import(i32(id), wj.cstr_bytes(spec.ptr), u32(spec.len), wj.cstr_bytes(base.ptr), u32(base.len), type)
	wj.wj_str_free(ctx, &spec)
	wj.wj_str_free(ctx, &base)
	if st < 0 {
		msg: [512]u8
		browser_message(msg[:], "Failed to resolve module specifier")
		wj.JS_FreeValue(ctx, pi.funcs[0])
		wj.JS_FreeValue(ctx, pi.funcs[1])
		wj.JS_FreeValue(ctx, pi.attributes)
		pi.used = false
		wj.JS_ThrowTypeError(ctx, "%s", cstring(&msg[0]))
		return -1
	}
	return 0
}

// The graph of an import() is complete (ok 1: link and evaluate it, settling the promise) or failed: 0, a TypeError
// with `msg`; 2, the error to rethrow of module `msg` (it does not compile).
@(export, link_name = "wj_module_import_done")
wj_module_import_done :: proc "c" (id: i32, url: u32, url_len: u32, ok: i32, msg: u32, msg_len: u32) {
	ctx := wj.wj_the_realm.ctx
	wj.wj_stack_enter(ctx)
	if id < 0 || u32(id) >= import_cap || !imports[id].used { return }
	pi := imports[id]
	imports[id].used = false
	kept := ok == 2 ? rethrow_get(ctx, ([^]u8)(uintptr(msg)), uint(msg_len)) : wj.UNDEFINED
	if ok == 2 && !wj.is_undefined(kept) {
		r := wj.JS_Call(ctx, pi.funcs[1], wj.UNDEFINED, 1, &kept)
		wj.JS_FreeValue(ctx, r)
		wj.JS_FreeValue(ctx, kept)
	} else if ok == 1 {
		name := js_cstr(ctx, ([^]u8)(uintptr(url)), int(url_len))
		if name != nil {
			wj.JS_LoadModuleWithFuncs(ctx, "", name, &pi.funcs[0], pi.attributes)
			wj.js_free(ctx, rawptr(name))
		}
	} else {
		wj.JS_ThrowTypeError(ctx, "%.*s", i32(msg_len), ([^]u8)(uintptr(msg)))
		err := wj.JS_GetException(ctx)
		r := wj.JS_Call(ctx, pi.funcs[1], wj.UNDEFINED, 1, &err)
		wj.JS_FreeValue(ctx, r)
		wj.JS_FreeValue(ctx, err)
	}
	wj.JS_FreeValue(ctx, pi.funcs[0])
	wj.JS_FreeValue(ctx, pi.funcs[1])
	wj.JS_FreeValue(ctx, pi.attributes)
}

// Realm start (load.odin).
modules_start :: proc "contextless" (ctx: ^wj.Context) {
	rt := wj.JS_GetRuntime(ctx)
	wj.JS_SetModuleLoaderFunc2(rt, module_normalize, module_loader, module_check_attributes, nil)
	wj.JS_SetDynamicImportHook(rt, import_hook, nil)
}
