// web_webgl.odin: WebGL for a window or a worker (web_webgl.js, over the natives here), made the first time a script asks for a context or reads
// one of the interfaces. The rules a script sees are in the JavaScript and on the device's side (native/webgl); here, what carries
// the command buffers across. A page that never asks pays nothing.
package odin_glue

import "../odin/wj"

// A host context as a JavaScript object with nothing to see. It belongs to its canvas's backing: nothing to do when collected.
@(private = "file") ref_class: wj.Class_ID
@(private = "file") gl_ops: wj.JSValue
@(private = "file") gl_ops_ready: bool

@(private = "file")
ref_of :: proc "contextless" (v: wj.JSValue) -> u64 {
	h := (^u64)(wj.JS_GetOpaque(v, ref_class))
	return h != nil ? h^ : 0
}

@(private = "file")
ref_finalizer :: proc "c" (rt: ^wj.Runtime, val: wj.JSValue) {
	h := (^u64)(wj.JS_GetOpaque(val, ref_class))
	if h != nil { wj.libc_free(h) }
}

@(private = "file")
ref_new :: proc "contextless" (ctx: ^wj.Context, host: u64) -> wj.JSValue {
	if host == 0 { return wj.NULL }
	h := (^u64)(wj.libc_malloc(size_of(u64)))
	if h == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	h^ = host
	obj := wj.JS_NewObjectClass(ctx, ref_class)
	if wj.is_exception(obj) { wj.libc_free(h); return obj }
	wj.JS_SetOpaque(obj, h)
	return obj
}

// The realm's entry for what a context has to say.
@(export, link_name = "wj_cb_webgl")
wj_cb_webgl :: proc "c" (user, kind: i32) {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	if !gl_ops_ready { return }
	fn := wj.JS_GetPropertyStr(ctx, gl_ops, "notify")
	defer wj.JS_FreeValue(ctx, fn)
	args := [2]wj.JSValue{wj.new_int32(user), wj.new_int32(kind)}
	r := wj.JS_Call(ctx, fn, wj.UNDEFINED, 2, &args[0])
	if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
}

// (ref, arrayBuffer, words): the first words of a buffer, as bytes.
@(private = "file")
words_of :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, i: i32) -> (p: [^]u8, n: u32, ok: bool) {
	size: uint
	b := wj.JS_GetArrayBuffer(ctx, &size, wj.arg(argc, argv, i))
	if b == nil { return nil, 0, false }
	count: i32
	wj.JS_ToInt32(ctx, &count, wj.arg(argc, argv, i + 1))
	bytes := uint(max(count, 0)) * 4
	if bytes > size { return nil, 0, false }
	return b, u32(bytes), true
}

@(private = "file")
bytes_of :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, i: i32) -> (p: [^]u8, n: u32, ok: bool) {
	q: [^]u8
	m: uint
	if !wj.wj_to_buffer_source(ctx, wj.arg(argc, argv, i), &q, &m, wj.BS_ALLOW_SHARED, "WebGL") { return nil, 0, false }
	return m > 0 ? q : wj.empty_ptr(), u32(m), true
}

// (ref, buffer, words, drew)
@(private = "file")
native_submit :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	p, n, ok := words_of(ctx, argc, argv, 1)
	if !ok { return wj.UNDEFINED }
	wj.wr_WebGL_submit(ref_of(wj.arg(argc, argv, 0)), p, n, wj.empty_ptr(), 0, wj.to_bool(ctx, wj.arg(argc, argv, 3)) ? 1 : 0)
	return wj.UNDEFINED
}

// (ref, buffer, words, view): the view's bytes belong to the last command. The length word comes before them.
@(private = "file")
native_submit_data :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	p, n, ok := words_of(ctx, argc, argv, 1)
	if !ok { return wj.UNDEFINED }
	d, dn, dok := bytes_of(ctx, argc, argv, 3)
	if !dok { return wj.EXCEPTION }
	wj.wr_WebGL_submit(ref_of(wj.arg(argc, argv, 0)), p, n, d, dn, 0)
	return wj.UNDEFINED
}

// (ref, buffer, words, string): the words, then the string's length and bytes.
@(private = "file")
native_submit_text :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	p, n, ok := words_of(ctx, argc, argv, 1)
	if !ok { return wj.UNDEFINED }
	size: uint
	s := wj.to_cstring_len(ctx, &size, wj.arg(argc, argv, 3))
	if s == nil { return wj.EXCEPTION }
	defer wj.free_cstring(ctx, s)
	// (the length goes in the word after the command: the buffer has room)
	(^u32)(rawptr(&p[n]))^ = u32(size)
	wj.wr_WebGL_submit(ref_of(wj.arg(argc, argv, 0)), p, n + 4, ([^]u8)(rawptr(s)), u32(size), 0)
	return wj.UNDEFINED
}

// (ref, buffer, words, reply): the length of the answer, -1 when there is none
@(private = "file")
native_query :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	p, n, ok := words_of(ctx, argc, argv, 1)
	if !ok { return wj.new_int32(-1) }
	size: uint
	out := wj.JS_GetArrayBuffer(ctx, &size, wj.arg(argc, argv, 3))
	if out == nil { return wj.new_int32(-1) }
	return wj.new_float64(ctx, wj.wr_WebGL_query(ref_of(wj.arg(argc, argv, 0)), p, n, out, u32(size)))
}

// (ref, buffer, words, string, reply)
@(private = "file")
native_query_text :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	p, n, ok := words_of(ctx, argc, argv, 1)
	if !ok { return wj.new_int32(-1) }
	size: uint
	s := wj.to_cstring_len(ctx, &size, wj.arg(argc, argv, 3))
	if s == nil { return wj.EXCEPTION }
	defer wj.free_cstring(ctx, s)
	out_size: uint
	out := wj.JS_GetArrayBuffer(ctx, &out_size, wj.arg(argc, argv, 4))
	if out == nil { return wj.new_int32(-1) }
	return wj.new_float64(ctx, wj.wr_WebGL_queryText(ref_of(wj.arg(argc, argv, 0)), p, n, ([^]u8)(rawptr(s)), u32(size), out, u32(out_size)))
}

// (ref, buffer, words, view): an answer of pixels or bytes, into the view
@(private = "file")
native_query_into :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	p, n, ok := words_of(ctx, argc, argv, 1)
	if !ok { return wj.new_int32(-1) }
	d, dn, dok := bytes_of(ctx, argc, argv, 3)
	if !dok { return wj.EXCEPTION }
	return wj.new_float64(ctx, wj.wr_WebGL_query(ref_of(wj.arg(argc, argv, 0)), p, n, d, dn))
}

// (ref, buffer, words, source): a node or an object of the browser. 1: nothing to read yet.
@(private = "file")
native_upload :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	p, n, ok := words_of(ctx, argc, argv, 1)
	if !ok { return wj.new_int32(1) }
	src := wj.arg(argc, argv, 3)
	if !wj.is_object(src) { return wj.JS_ThrowTypeError(ctx, "texImage2D: the source is not an image") }
	h := wj.obj_handle(src)
	if h == 0 { return wj.JS_ThrowTypeError(ctx, "texImage2D: the source is not an image") }
	out: i32
	st := wj.wr_WebGL_upload(ref_of(wj.arg(argc, argv, 0)), p, n, h, &out)
	if st != 0 { return wj.wj_throw_status(ctx, st, "texImage2D") }
	return wj.new_int32(out)
}

// (canvas, isOffscreen, webgl2, alpha, depth, stencil, antialias, premultipliedAlpha, preserveDrawingBuffer, failIfMajorPerformanceCaveat, user, info)
@(private = "file")
native_create :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	flags: u32
	for i in i32(2) ..< 10 {
		if wj.to_bool(ctx, wj.arg(argc, argv, i)) { flags |= 1 << u32(i - 2) }
	}
	user: i32
	wj.JS_ToInt32(ctx, &user, wj.arg(argc, argv, 10))
	info, n, ok := bytes_of(ctx, argc, argv, 11)
	if !ok { return wj.EXCEPTION }
	canvas := wj.obj_handle(wj.arg(argc, argv, 0))
	cb := wj.table_index(rawptr(wj_cb_webgl))
	h: u64
	if wj.to_bool(ctx, wj.arg(argc, argv, 1)) {
		h = wj.wr_WebGL_createOffscreen(canvas, flags, cb, user, info, n)
	} else {
		h = wj.wr_WebGL_create(canvas, flags, cb, user, info, n)
	}
	return ref_new(ctx, h)
}

@(private = "file")
native_create_error :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	n := wj.fetch_string(wj.wr_WebGL_createError)
	if n <= 0 { return wj.new_string(ctx, "") }
	return wj.JS_NewStringLen(ctx, wj.wj_scratch.data, uint(n))
}

@(private = "file")
native_width :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_int32(i32(wj.wr_WebGL_width(ref_of(wj.arg(argc, argv, 0)))))
}

@(private = "file")
native_height :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_int32(i32(wj.wr_WebGL_height(ref_of(wj.arg(argc, argv, 0)))))
}

@(private = "file")
native_snapshot :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebGL_snapshot(ref_of(wj.arg(argc, argv, 0)))
	return wj.UNDEFINED
}

@(private = "file")
native_commit :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebGL_commit(ref_of(wj.arg(argc, argv, 0)))
	return wj.UNDEFINED
}

@(private = "file")
native_is_lost :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_bool(wj.wr_WebGL_isLost(ref_of(wj.arg(argc, argv, 0))) != 0)
}

@(private = "file")
native_lose :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebGL_lose(ref_of(wj.arg(argc, argv, 0)))
	return wj.UNDEFINED
}

@(private = "file")
native_restore :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_bool(wj.wr_WebGL_restore(ref_of(wj.arg(argc, argv, 0))) != 0)
}

@(private = "file")
gl_ops_get :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	if gl_ops_ready { return gl_ops }
	if ref_class == 0 {
		rt := wj.JS_GetRuntime(ctx)
		wj.JS_NewClassID(rt, &ref_class)
		def := wj.Class_Def{class_name = "WebGLHostRef", finalizer = ref_finalizer}
		if wj.JS_NewClass(rt, ref_class, &def) < 0 { ref_class = 0; return wj.JS_ThrowOutOfMemory(ctx) }
	}
	fn := eval_prelude(ctx, "web_webgl.js", #load("web_webgl.js"))
	if wj.is_exception(fn) { return fn }
	defer wj.JS_FreeValue(ctx, fn)
	native := wj.JS_NewObject(ctx)
	defer wj.JS_FreeValue(ctx, native)
	Entry :: struct { name: cstring, fn: wj.Native, length: i32 }
	entries := [?]Entry{
		{"create", native_create, 12}, {"createError", native_create_error, 0}, {"submit", native_submit, 4}, {"submitData", native_submit_data, 4},
		{"submitText", native_submit_text, 4}, {"query", native_query, 4}, {"queryText", native_query_text, 5}, {"queryInto", native_query_into, 4},
		{"upload", native_upload, 4}, {"width", native_width, 1}, {"height", native_height, 1}, {"snapshot", native_snapshot, 1}, {"commit", native_commit, 1},
		{"isLost", native_is_lost, 1}, {"lose", native_lose, 1}, {"restore", native_restore, 1},
	}
	for &e in entries {
		wj.JS_DefinePropertyValueStr(ctx, native, e.name, wj.new_cfunction(ctx, e.fn, e.name, e.length), wj.PROP_C_W_E)
	}
	args := [2]wj.JSValue{native, wj.wj_the_realm.global}
	ops := wj.JS_Call(ctx, fn, wj.UNDEFINED, 2, &args[0])
	if wj.is_exception(ops) { return ops }
	gl_ops, gl_ops_ready = ops, true
	return ops
}

// getContext("webgl" | "experimental-webgl" | "webgl2", options) of a canvas (web_canvas.odin).
webgl_get_context :: proc "contextless" (ctx: ^wj.Context, canvas: wj.JSValue, kind: wj.JSValue, options: wj.JSValue) -> wj.JSValue {
	if wj.wr_WebGL_enabled(1) == 0 { return wj.NULL }
	ops := gl_ops_get(ctx)
	if wj.is_exception(ops) { return ops }
	fn := wj.JS_GetPropertyStr(ctx, ops, "getContext")
	defer wj.JS_FreeValue(ctx, fn)
	args := [3]wj.JSValue{canvas, kind, options}
	return wj.JS_Call(ctx, fn, wj.UNDEFINED, 3, &args[0])
}

@(private = "file")
gl_autoinit :: proc "c" (ctx: ^wj.Context, atom: wj.Atom) -> wj.JSValue {
	// (asked here and not when the realm starts: a realm of the engine's own tools has no such import, and reads none of this)
	if wj.wr_WebGL_enabled(1) == 0 { return wj.UNDEFINED }
	ops := gl_ops_get(ctx)
	if wj.is_exception(ops) { return ops }
	return wj.JS_GetProperty(ctx, ops, atom)
}

@(private = "file")
GL_NAMES := [?]cstring{
	"WebGLRenderingContext", "WebGL2RenderingContext", "WebGLContextEvent", "WebGLObject", "WebGLBuffer", "WebGLFramebuffer", "WebGLProgram", "WebGLRenderbuffer",
	"WebGLShader", "WebGLTexture", "WebGLUniformLocation", "WebGLActiveInfo", "WebGLShaderPrecisionFormat", "WebGLQuery", "WebGLSampler", "WebGLSync",
	"WebGLTransformFeedback", "WebGLVertexArrayObject",
}

@(export, link_name = "web_webgl_start")
web_webgl_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	// (test262's image has only what ECMAScript needs of the browser)
	when WREN_TEST262 { return 0 }
	for name in GL_NAMES {
		a := wj.JS_NewAtom(ctx, name)
		defer wj.JS_FreeAtom(ctx, a)
		wj.JS_DeleteProperty(ctx, wj.wj_the_realm.global, a, 0)
		if wj.JS_DefineHostAutoInitProperty(ctx, wj.wj_the_realm.global, a, gl_autoinit, wj.PROP_CONFIGURABLE | wj.PROP_WRITABLE) < 0 { return -1 }
	}
	return 0
}
