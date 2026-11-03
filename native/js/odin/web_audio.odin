// web_audio.odin: the interfaces of the Web Audio API on the window, made the first time a script reads one of them
// (web_audio.js, over the natives here). The rules a script sees are in the JavaScript; the graph, its thread and its
// computations are in the browser (src/webaudio, src/page/bindings_webaudio.odin). A page that never asks pays nothing.
package odin_glue

import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

// A host object as a JavaScript object with nothing to see: a graph, a buffer. Released when collected.
@(private = "file") ref_class: wj.Class_ID

@(private = "file")
ref_finalizer :: proc "c" (rt: ^wj.Runtime, val: wj.JSValue) {
	h := (^u64)(wj.JS_GetOpaque(val, ref_class))
	if h == nil { return }
	wj.wr_Object_release(h^)
	wj.libc_free(h)
}

@(private = "file")
ref_of :: proc "contextless" (v: wj.JSValue) -> u64 {
	h := (^u64)(wj.JS_GetOpaque(v, ref_class))
	return h != nil ? h^ : 0
}

// `host` as an object (takes it); null for 0.
@(private = "file")
ref_new :: proc "contextless" (ctx: ^wj.Context, host: u64) -> wj.JSValue {
	if host == 0 { return wj.NULL }
	h := (^u64)(wj.libc_malloc(size_of(u64)))
	if h == nil { wj.wr_Object_release(host); return wj.JS_ThrowOutOfMemory(ctx) }
	h^ = host
	obj := wj.JS_NewObjectClass(ctx, ref_class)
	if wj.is_exception(obj) { wj.wr_Object_release(host); wj.libc_free(h); return obj }
	wj.JS_SetOpaque(obj, h)
	return obj
}

// A node's id as an object: when it is collected the node's object is gone (WebAudio_nodeRelease).
@(private = "file") node_class: wj.Class_ID

@(private = "file")
Node_Ref :: struct { graph: u64, id: i32 }

@(private = "file")
node_finalizer :: proc "c" (rt: ^wj.Runtime, val: wj.JSValue) {
	n := (^Node_Ref)(wj.JS_GetOpaque(val, node_class))
	if n == nil { return }
	wj.wr_WebAudio_nodeRelease(n.graph, n.id)
	wj.libc_free(n)
}

@(private = "file")
num :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, i: i32) -> f64 {
	d: f64
	wj.JS_ToFloat64(ctx, &d, wj.arg(argc, argv, i))
	return d
}

@(private = "file")
int_of :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, i: i32) -> i32 {
	v: i32
	wj.JS_ToInt32(ctx, &v, wj.arg(argc, argv, i))
	return v
}

@(private = "file")
bool_of :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, i: i32) -> i32 {
	return wj.to_bool(ctx, wj.arg(argc, argv, i)) ? 1 : 0
}

// The bytes of a typed array or buffer for a browser function (it reads or fills them before it returns).
@(private = "file")
Bytes :: struct { p: [^]u8, n: u32 }

@(private = "file")
bytes_of :: proc "contextless" (ctx: ^wj.Context, argc: i32, argv: [^]wj.JSValue, i: i32, out: ^Bytes) -> bool {
	p: [^]u8
	n: uint
	if !wj.wj_to_buffer_source(ctx, wj.arg(argc, argv, i), &p, &n, wj.BS_ALLOW_SHARED, "Web Audio") { return false }
	out^ = Bytes{n > 0 ? p : wj.empty_ptr(), u32(n)}
	return true
}

// ---- the realm's entry for the render thread's news ----

@(private = "file") audio_ops: wj.JSValue
@(private = "file") audio_ops_ready: bool

@(export, link_name = "wj_cb_webaudio")
wj_cb_webaudio :: proc "c" (user, kind, node, value: i32) {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	if !audio_ops_ready { return }
	fn := wj.JS_GetPropertyStr(ctx, audio_ops, "notify")
	defer wj.JS_FreeValue(ctx, fn)
	args := [4]wj.JSValue{wj.new_int32(user), wj.new_int32(kind), wj.new_int32(node), wj.new_int32(value)}
	r := wj.JS_Call(ctx, fn, wj.UNDEFINED, 4, &args[0])
	if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
}

// ---- natives ----

@(private = "file") N :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue

@(private = "file")
native_default_rate :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_float64(ctx, wj.wr_WebAudio_defaultRate())
}

@(private = "file")
native_fully_active :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_bool(wj.wr_WebAudio_fullyActive() != 0)
}

@(private = "file")
native_max_buffer :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_float64(ctx, wj.wr_WebAudio_maxBufferBytes())
}

// create(rate, channels, offlineFrames, latency, user): the graph, null when refused
@(private = "file")
native_create :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h := wj.wr_WebAudio_create(num(ctx, argc, argv, 0), u32(int_of(ctx, argc, argv, 1)), u32(num(ctx, argc, argv, 2)), num(ctx, argc, argv, 3), wj.table_index(rawptr(wj_cb_webaudio)), int_of(ctx, argc, argv, 4))
	return ref_new(ctx, h)
}

@(private = "file")
native_resume :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebAudio_resume(ref_of(wj.arg(argc, argv, 0)))
	return wj.UNDEFINED
}

@(private = "file")
native_suspend :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_bool(wj.wr_WebAudio_suspend(ref_of(wj.arg(argc, argv, 0))) != 0)
}

@(private = "file")
native_close :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebAudio_close(ref_of(wj.arg(argc, argv, 0)))
	return wj.UNDEFINED
}

@(private = "file")
native_time :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_float64(ctx, wj.wr_WebAudio_time(ref_of(wj.arg(argc, argv, 0))))
}

@(private = "file")
native_queued :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_float64(ctx, wj.wr_WebAudio_queued(ref_of(wj.arg(argc, argv, 0))))
}

@(private = "file")
native_render :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_bool(wj.wr_WebAudio_render(ref_of(wj.arg(argc, argv, 0)), u32(num(ctx, argc, argv, 1))) != 0)
}

@(private = "file")
native_take_result :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return ref_new(ctx, wj.wr_WebAudio_takeResult(ref_of(wj.arg(argc, argv, 0))))
}

@(private = "file")
native_offline_suspend :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_bool(wj.wr_WebAudio_offlineSuspend(ref_of(wj.arg(argc, argv, 0)), num(ctx, argc, argv, 1)) != 0)
}

@(private = "file")
native_offline_resume :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebAudio_offlineResume(ref_of(wj.arg(argc, argv, 0)))
	return wj.UNDEFINED
}

// nodeCreate(graph, kind, a, b): the id, -1 when refused
@(private = "file")
native_node_create :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_int32(wj.wr_WebAudio_nodeCreate(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), num(ctx, argc, argv, 2), num(ctx, argc, argv, 3)))
}

// nodeRef(graph, id): what says to the browser when the node's object is gone
@(private = "file")
native_node_ref :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	n := (^Node_Ref)(wj.libc_malloc(size_of(Node_Ref)))
	if n == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	n^ = Node_Ref{ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1)}
	obj := wj.JS_NewObjectClass(ctx, node_class)
	if wj.is_exception(obj) { wj.libc_free(n); return obj }
	wj.JS_SetOpaque(obj, n)
	return obj
}

// connect(graph, from, output, to, input, param)
@(private = "file")
native_connect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_bool(wj.wr_WebAudio_connect(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), int_of(ctx, argc, argv, 2), int_of(ctx, argc, argv, 3), int_of(ctx, argc, argv, 4), bool_of(ctx, argc, argv, 5)) != 0)
}

@(private = "file")
native_disconnect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_int32(wj.wr_WebAudio_disconnect(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), int_of(ctx, argc, argv, 2), int_of(ctx, argc, argv, 3), int_of(ctx, argc, argv, 4), bool_of(ctx, argc, argv, 5)))
}

@(private = "file")
native_node_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebAudio_nodeSet(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), int_of(ctx, argc, argv, 2), num(ctx, argc, argv, 3))
	return wj.UNDEFINED
}

@(private = "file")
native_node_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_float64(ctx, wj.wr_WebAudio_nodeGet(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), int_of(ctx, argc, argv, 2)))
}

@(private = "file")
native_start :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebAudio_start(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), num(ctx, argc, argv, 2), num(ctx, argc, argv, 3), num(ctx, argc, argv, 4))
	return wj.UNDEFINED
}

@(private = "file")
native_stop :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebAudio_stop(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), num(ctx, argc, argv, 2))
	return wj.UNDEFINED
}

@(private = "file")
native_set_buffer :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebAudio_setBuffer(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), ref_of(wj.arg(argc, argv, 2)))
	return wj.UNDEFINED
}

@(private = "file")
native_set_convolver :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebAudio_setConvolver(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), ref_of(wj.arg(argc, argv, 2)), bool_of(ctx, argc, argv, 3))
	return wj.UNDEFINED
}

@(private = "file")
native_set_curve :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: Bytes
	if !wj.is_null(wj.arg(argc, argv, 2)) && !bytes_of(ctx, argc, argv, 2, &b) { return wj.EXCEPTION }
	wj.wr_WebAudio_setCurve(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), b.n > 0 ? b.p : wj.empty_ptr(), b.n)
	return wj.UNDEFINED
}

@(private = "file")
native_set_wave :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	real, imag: Bytes
	if !bytes_of(ctx, argc, argv, 2, &real) || !bytes_of(ctx, argc, argv, 3, &imag) { return wj.EXCEPTION }
	wj.wr_WebAudio_setWave(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), real.p, real.n, imag.p, imag.n, bool_of(ctx, argc, argv, 4))
	return wj.UNDEFINED
}

@(private = "file")
native_capture_element :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h := wj.obj_handle(wj.arg(argc, argv, 2))
	if h == 0 { return wj.JS_ThrowTypeError(ctx, "not a media element") }
	return wj.new_bool(wj.wr_WebAudio_captureElement(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), h) != 0)
}

@(private = "file")
native_param_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_float64(ctx, wj.wr_WebAudio_paramGet(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), int_of(ctx, argc, argv, 2)))
}

@(private = "file")
native_param_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_bool(wj.wr_WebAudio_paramSet(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), int_of(ctx, argc, argv, 2), num(ctx, argc, argv, 3)) != 0)
}

@(private = "file")
native_param_rate :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebAudio_paramRate(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), int_of(ctx, argc, argv, 2), bool_of(ctx, argc, argv, 3))
	return wj.UNDEFINED
}

// paramEvent(graph, node, index, kind, time, value, extra, curve)
@(private = "file")
native_param_event :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b := Bytes{wj.empty_ptr(), 0}
	if !wj.is_undefined(wj.arg(argc, argv, 7)) && !bytes_of(ctx, argc, argv, 7, &b) { return wj.EXCEPTION }
	return wj.new_bool(wj.wr_WebAudio_paramEvent(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), int_of(ctx, argc, argv, 2), int_of(ctx, argc, argv, 3), num(ctx, argc, argv, 4), num(ctx, argc, argv, 5), num(ctx, argc, argv, 6), b.p, b.n) != 0)
}

@(private = "file")
native_param_cancel :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebAudio_paramCancel(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), int_of(ctx, argc, argv, 2), num(ctx, argc, argv, 3), bool_of(ctx, argc, argv, 4))
	return wj.UNDEFINED
}

@(private = "file")
native_biquad_response :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	f, m, ph: Bytes
	if !bytes_of(ctx, argc, argv, 2, &f) || !bytes_of(ctx, argc, argv, 3, &m) || !bytes_of(ctx, argc, argv, 4, &ph) { return wj.EXCEPTION }
	wj.wr_WebAudio_biquadResponse(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), f.p, f.n, m.p, m.n, ph.p, ph.n)
	return wj.UNDEFINED
}

@(private = "file")
native_set_iir :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	f, b: Bytes
	if !bytes_of(ctx, argc, argv, 2, &f) || !bytes_of(ctx, argc, argv, 3, &b) { return wj.EXCEPTION }
	wj.wr_WebAudio_setIir(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), f.p, f.n, b.p, b.n)
	return wj.UNDEFINED
}

@(private = "file")
native_iir_response :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	f, m, ph: Bytes
	if !bytes_of(ctx, argc, argv, 2, &f) || !bytes_of(ctx, argc, argv, 3, &m) || !bytes_of(ctx, argc, argv, 4, &ph) { return wj.EXCEPTION }
	wj.wr_WebAudio_iirResponse(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), f.p, f.n, m.p, m.n, ph.p, ph.n)
	return wj.UNDEFINED
}

@(private = "file")
native_analyser_read :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: Bytes
	if !bytes_of(ctx, argc, argv, 3, &b) { return wj.EXCEPTION }
	return wj.new_int32(wj.wr_WebAudio_analyserRead(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), int_of(ctx, argc, argv, 2), b.p, b.n))
}

@(private = "file")
native_script_pull :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: Bytes
	if !bytes_of(ctx, argc, argv, 2, &b) { return wj.EXCEPTION }
	wj.wr_WebAudio_scriptPull(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), b.p, b.n)
	return wj.UNDEFINED
}

@(private = "file")
native_script_push :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: Bytes
	if !bytes_of(ctx, argc, argv, 2, &b) { return wj.EXCEPTION }
	wj.wr_WebAudio_scriptPush(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), b.p, b.n)
	return wj.UNDEFINED
}

@(private = "file")
native_pcm_create :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return ref_new(ctx, wj.wr_WebAudio_pcmCreate(u32(int_of(ctx, argc, argv, 0)), u32(num(ctx, argc, argv, 1)), num(ctx, argc, argv, 2)))
}

@(private = "file")
native_pcm_write :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: Bytes
	if !bytes_of(ctx, argc, argv, 3, &b) { return wj.EXCEPTION }
	wj.wr_WebAudio_pcmWrite(ref_of(wj.arg(argc, argv, 0)), u32(int_of(ctx, argc, argv, 1)), u32(num(ctx, argc, argv, 2)), b.p, b.n)
	return wj.UNDEFINED
}

@(private = "file")
native_pcm_read :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: Bytes
	if !bytes_of(ctx, argc, argv, 3, &b) { return wj.EXCEPTION }
	wj.wr_WebAudio_pcmRead(ref_of(wj.arg(argc, argv, 0)), u32(int_of(ctx, argc, argv, 1)), u32(num(ctx, argc, argv, 2)), b.p, b.n)
	if b.n > 0 { wj.JS_ArrayBufferCommit(ctx, b.p, uint(b.n)) }   // (a WebAssembly memory: these bytes were a copy)
	return wj.UNDEFINED
}

@(private = "file")
native_pcm_info :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_float64(ctx, wj.wr_WebAudio_pcmInfo(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1)))
}

@(private = "file")
decode_settle :: proc "c" (ctx: ^wj.Context, state: i32, host: u64, value: i64, data: wj.JSValue, reject: ^bool) -> wj.JSValue {
	if reject^ { return wj.web_dom_exception(ctx, "EncodingError", "Unable to decode audio data") }
	return ref_new(ctx, u64(value))
}

// decode(bytes, rate): a promise of a buffer
@(private = "file")
native_decode :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: Bytes
	if !bytes_of(ctx, argc, argv, 0, &b) { return wj.EXCEPTION }
	return wj.wj_promise_from_host(ctx, wj.wr_WebAudio_decode(b.p, b.n, num(ctx, argc, argv, 1)), 0, decode_settle, wj.UNDEFINED)
}

// dom(name, message): a new DOMException
@(private = "file")
native_dom :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	name, message: wj.Str
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 0), &name, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	if !wj.wj_to_str(ctx, wj.arg(argc, argv, 1), &message, 0, "") { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &message)
	return wj.web_dom_exception(ctx, wj.cstr(name.ptr), wj.cstr(message.ptr))
}

// ---- AudioWorklet: the page's side ----

// workletStart(graph): the realm's Worker object (kept alive while it runs, as any Worker), null when refused
@(private = "file")
native_worklet_start :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	h := wj.wr_WebAudio_workletStart(ref_of(wj.arg(argc, argv, 0)))
	if h == 0 { return wj.NULL }
	obj := wj.wj_wrap_owned(ctx, h, jsb.iface_of(api_decl.Worker), wj.UNDEFINED)
	if !wj.is_exception(obj) { web_keep_worker(ctx, obj) }
	return obj
}

@(private = "file")
native_worklet_stop :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebAudio_workletStop(ref_of(wj.arg(argc, argv, 0)))
	return wj.UNDEFINED
}

// workletNode(graph, inputs, outputs, params, processor, outputChannels): the node, -1 when refused
@(private = "file")
native_worklet_node :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: Bytes
	if !bytes_of(ctx, argc, argv, 5, &b) { return wj.EXCEPTION }
	return wj.new_int32(wj.wr_WebAudio_workletNode(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), int_of(ctx, argc, argv, 2), int_of(ctx, argc, argv, 3), int_of(ctx, argc, argv, 4), b.p, b.n))
}

// workletParam(graph, node, index, default, min, max, aRate)
@(private = "file")
native_worklet_param :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_WebAudio_workletParam(ref_of(wj.arg(argc, argv, 0)), int_of(ctx, argc, argv, 1), int_of(ctx, argc, argv, 2), num(ctx, argc, argv, 3), num(ctx, argc, argv, 4), num(ctx, argc, argv, 5), bool_of(ctx, argc, argv, 6))
	return wj.UNDEFINED
}

// ---- AudioWorklet: the realm's side (web_audio_worklet.js) ----

@(private = "file") worklet_ops: wj.JSValue
@(private = "file") worklet_ops_ready: bool

@(private = "file")
native_realm_layout :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: Bytes
	if !bytes_of(ctx, argc, argv, 0, &b) { return wj.EXCEPTION }
	n := wj.wr_AudioWorkletRealm_layout(b.p, b.n)
	if n > 0 && b.n > 0 { wj.JS_ArrayBufferCommit(ctx, b.p, uint(b.n)) }
	return wj.new_int32(n)
}

@(private = "file")
native_realm_frame :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_float64(ctx, wj.wr_AudioWorkletRealm_frame())
}

@(private = "file")
native_realm_read :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: Bytes
	if !bytes_of(ctx, argc, argv, 1, &b) { return wj.EXCEPTION }
	wj.wr_AudioWorkletRealm_read(int_of(ctx, argc, argv, 0), b.p, b.n)
	if b.n > 0 { wj.JS_ArrayBufferCommit(ctx, b.p, uint(b.n)) }
	return wj.UNDEFINED
}

@(private = "file")
native_realm_write :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	b: Bytes
	if !bytes_of(ctx, argc, argv, 1, &b) { return wj.EXCEPTION }
	wj.wr_AudioWorkletRealm_write(int_of(ctx, argc, argv, 0), b.p, b.n)
	return wj.UNDEFINED
}

@(private = "file")
native_realm_finish :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	wj.wr_AudioWorkletRealm_finish(int_of(ctx, argc, argv, 0))
	return wj.UNDEFINED
}

@(private = "file")
native_realm_dropped :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return wj.new_int32(wj.wr_AudioWorkletRealm_dropped())
}

// The browser: this worker's realm is an AudioWorklet's. Its global scope is made here, once.
@(export, link_name = "wj_worklet_boot")
wj_worklet_boot :: proc "c" () {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	if worklet_ops_ready { return }
	entries := [?]Prelude_Native{
		{"layout", native_realm_layout, 1}, {"frame", native_realm_frame, 0}, {"read", native_realm_read, 2}, {"write", native_realm_write, 2},
		{"finish", native_realm_finish, 1}, {"dropped", native_realm_dropped, 0},
	}
	ops := prelude_call(ctx, "web_audio_worklet.js", #load("web_audio_worklet.js"), entries[:], wj.wj_the_realm.global, wj.new_float64(ctx, wj.wr_AudioWorkletRealm_sampleRate()))
	if wj.is_exception(ops) { if wj.JS_HasException(ctx) { wj.wj_report_pending(ctx) }; return }   // (a prelude that did not compile is reported already)
	worklet_ops, worklet_ops_ready = ops, true
}

// The browser: a request of the render thread waits.
@(export, link_name = "wj_worklet_quantum")
wj_worklet_quantum :: proc "c" () {
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	if !worklet_ops_ready { return }
	fn := wj.JS_GetPropertyStr(ctx, worklet_ops, "quantum")
	defer wj.JS_FreeValue(ctx, fn)
	r := wj.JS_Call(ctx, fn, wj.UNDEFINED, 0, nil)
	if wj.is_exception(r) { wj.wj_report_pending(ctx) } else { wj.JS_FreeValue(ctx, r) }
}

@(private = "file")
audio_ops_get :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	if audio_ops_ready { return audio_ops }
	if ref_class == 0 {
		rt := wj.JS_GetRuntime(ctx)
		wj.JS_NewClassID(rt, &ref_class)
		def := wj.Class_Def{class_name = "AudioHostRef", finalizer = ref_finalizer}
		if wj.JS_NewClass(rt, ref_class, &def) < 0 { ref_class = 0; return wj.JS_ThrowOutOfMemory(ctx) }
		wj.JS_NewClassID(rt, &node_class)
		def2 := wj.Class_Def{class_name = "AudioNodeRef", finalizer = node_finalizer}
		if wj.JS_NewClass(rt, node_class, &def2) < 0 { node_class = 0; return wj.JS_ThrowOutOfMemory(ctx) }
	}
	entries := [?]Prelude_Native{
		{"defaultRate", native_default_rate, 0}, {"maxBuffer", native_max_buffer, 0}, {"dom", native_dom, 2},
		{"fullyActive", native_fully_active, 0},
		{"create", native_create, 5}, {"resume", native_resume, 1}, {"suspend", native_suspend, 1}, {"close", native_close, 1},
		{"time", native_time, 1}, {"queued", native_queued, 1}, {"render", native_render, 2}, {"takeResult", native_take_result, 1},
		{"offlineSuspend", native_offline_suspend, 2}, {"offlineResume", native_offline_resume, 1},
		{"nodeCreate", native_node_create, 4}, {"nodeRef", native_node_ref, 2},
		{"connect", native_connect, 6}, {"disconnect", native_disconnect, 6},
		{"nodeSet", native_node_set, 4}, {"nodeGet", native_node_get, 3}, {"start", native_start, 5}, {"stop", native_stop, 3},
		{"setBuffer", native_set_buffer, 3}, {"setConvolver", native_set_convolver, 4}, {"setCurve", native_set_curve, 3}, {"setWave", native_set_wave, 5},
		{"captureElement", native_capture_element, 3},
		{"paramGet", native_param_get, 3}, {"paramSet", native_param_set, 4}, {"paramRate", native_param_rate, 4},
		{"paramEvent", native_param_event, 8}, {"paramCancel", native_param_cancel, 5},
		{"biquadResponse", native_biquad_response, 5}, {"analyserRead", native_analyser_read, 4},
		{"setIir", native_set_iir, 4}, {"iirResponse", native_iir_response, 5},
		{"scriptPull", native_script_pull, 3}, {"scriptPush", native_script_push, 3},
		{"pcmCreate", native_pcm_create, 3}, {"pcmWrite", native_pcm_write, 4}, {"pcmRead", native_pcm_read, 4}, {"pcmInfo", native_pcm_info, 2},
		{"decode", native_decode, 2},
		{"workletStart", native_worklet_start, 1}, {"workletStop", native_worklet_stop, 1}, {"workletNode", native_worklet_node, 6}, {"workletParam", native_worklet_param, 7},
	}
	ops := prelude_call(ctx, "web_audio.js", #load("web_audio.js"), entries[:], wj.wj_the_realm.global)
	if wj.is_exception(ops) { return ops }
	audio_ops, audio_ops_ready = ops, true
	return ops
}

@(private = "file")
audio_autoinit :: proc "c" (ctx: ^wj.Context, atom: wj.Atom) -> wj.JSValue {
	// (asked here and not when the realm starts: a realm of the engine's own tools has no such import, and reads none of this)
	if wj.wr_WebAudio_enabled() == 0 { return wj.UNDEFINED }
	ops := audio_ops_get(ctx)
	if wj.is_exception(ops) { return ops }
	return wj.JS_GetProperty(ctx, ops, atom)
}

@(private = "file")
AUDIO_NAMES := [?]cstring{
	"BaseAudioContext", "AudioContext", "OfflineAudioContext", "AudioBuffer", "AudioNode", "AudioParam", "AudioScheduledSourceNode",
	"AudioDestinationNode", "AudioListener", "AudioBufferSourceNode", "OscillatorNode", "PeriodicWave", "GainNode", "ConstantSourceNode",
	"BiquadFilterNode", "DelayNode", "StereoPannerNode", "PannerNode", "ChannelSplitterNode", "ChannelMergerNode",
	"DynamicsCompressorNode", "WaveShaperNode", "AnalyserNode", "ConvolverNode", "ScriptProcessorNode", "AudioProcessingEvent",
	"OfflineAudioCompletionEvent", "MediaElementAudioSourceNode", "IIRFilterNode",
	"Worklet", "AudioWorklet", "AudioWorkletNode", "AudioParamMap",
}

@(export, link_name = "web_audio_start")
web_audio_start :: proc "c" (ctx: ^wj.Context, kind: i32) -> i32 {
	// (test262's image has only what ECMAScript needs of the browser)
	when WREN_TEST262 { return 0 }
	if !wj.is_window() { return 0 }
	for name in AUDIO_NAMES {
		a := wj.JS_NewAtom(ctx, name)
		defer wj.JS_FreeAtom(ctx, a)
		wj.JS_DeleteProperty(ctx, wj.wj_the_realm.global, a, 0)
		if wj.JS_DefineHostAutoInitProperty(ctx, wj.wj_the_realm.global, a, audio_autoinit, wj.PROP_CONFIGURABLE | wj.PROP_WRITABLE) < 0 { return -1 }
	}
	return 0
}
