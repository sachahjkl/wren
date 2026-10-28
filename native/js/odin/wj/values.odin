// values.odin: the value-shaped web.h helpers a ported domain calls — buffer sources and typed arrays, host promises
// (as values and the WJ_HOST_* settle kinds), blobs / files / FormData / Headers, streams and abort signals, the clone
// serialiser. All real symbols of native/js/runtime (buffer.c, web_blob.c, web_stream.c, promise.c, web_clone.c...),
// one declaration per symbol.
package wj

// ---- host promises: how a browser promise's value becomes the JS value (wj.h WJ_HOST_*; promise.odin) ----
HOST_UNDEFINED   :: i32(Host_Kind.Undefined)
HOST_NUMBER      :: i32(Host_Kind.Number)
HOST_BOOL        :: i32(Host_Kind.Bool)
HOST_TEXT        :: i32(Host_Kind.Text)
HOST_ARRAYBUFFER :: i32(Host_Kind.Array_Buffer)
HOST_UINT8ARRAY  :: i32(Host_Kind.Uint8_Array)

// web.h BufferSource flags (buffer.odin).
BS_VIEW_ONLY    :: i32(1 << 0)
BS_ALLOW_SHARED :: i32(1 << 1)

// (The host promises — wj_promise_from_host, wj_host_promise_text — and the buffer helpers — wj_to_buffer_source,
// wj_is_*, wj_*_from_host, wj_*_take, wj_host_buffer — are implemented in Odin: promise.odin, buffer.odin.)

@(default_calling_convention = "c")
foreign {
	wj_promise_reject_pending :: proc(ctx: ^Context) -> JSValue ---

	// promises as values (web.h)
	web_promise_new            :: proc(ctx: ^Context, funcs: [^]JSValue) -> JSValue ---
	web_promise_resolved       :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	web_promise_take           :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	web_promise_rejected       :: proc(ctx: ^Context, reason: JSValue) -> JSValue ---
	web_promise_reject_pending :: proc(ctx: ^Context) -> JSValue ---
	web_settle                 :: proc(ctx: ^Context, func: JSValue, v: JSValue) ---
	web_then                   :: proc(ctx: ^Context, promise: JSValue, on_ok: rawptr, on_err: rawptr, n: i32, data: [^]JSValue) -> JSValue ---

	// errors as values (web.h)
	web_error_value   :: proc(ctx: ^Context, code: i32, msg: [^]u8, len: uint) -> JSValue ---

	// structured clone through the browser's serializer (web_clone.c)
	web_clone_serialize   :: proc(ctx: ^Context, v: JSValue, len: ^uint) -> [^]u8 ---
	web_clone_free        :: proc(ctx: ^Context, p: rawptr) ---
	web_clone_deserialize :: proc(ctx: ^Context, p: [^]u8, len: uint) -> JSValue ---

	// FormData / Headers (web.h). (Blob / File: web_blob_* / web_file_* are Odin, package odin_glue, web_blob.odin.)
	web_entry_wrap   :: proc(ctx: ^Context, entry: u64) -> JSValue ---

	// (web_formdata_* are Odin, package odin_glue, web_formdata.odin)

	web_headers_new             :: proc(ctx: ^Context, guard: i32) -> JSValue ---
	web_headers_fill_lines      :: proc(ctx: ^Context, headers: JSValue, text: cstring, n: uint) ---
	web_headers_get             :: proc(headers: JSValue, name: cstring, len: ^uint) -> [^]u8 ---
	web_headers_has             :: proc(headers: JSValue, name: cstring) -> bool ---
	web_headers_append_raw      :: proc(headers: JSValue, name: cstring, nlen: uint, value: cstring, vlen: uint) -> bool ---
	web_headers_append_checked  :: proc(ctx: ^Context, headers: JSValue, name: cstring, nlen: uint, value: cstring, vlen: uint) -> bool ---
	web_headers_sorted          :: proc(ctx: ^Context, headers: JSValue) -> JSValue ---
	web_forbidden_request_header :: proc(name: cstring, n: uint, value: cstring, vn: uint) -> bool ---

	// (streams: web_stream_* and web_writable_state are Odin, package odin_glue, web_stream.odin / web_writable.odin)

	// (abort signals: web_signal_* and web_controller_construct are Odin, package odin_glue, web_abort.odin)

	// extract a body (web.h)
	web_extract_body     :: proc(ctx: ^Context, v: JSValue, out: ^Extracted, what: cstring) -> bool ---
	web_extracted_free   :: proc(ctx: ^Context, e: ^Extracted) ---
}

// web_extracted (web.h): the bytes, Content-Type and a kept ReadableStream of "extract a body".
Extracted :: struct {
	data:   [^]u8,
	len:    uint,
	type:   cstring,
	stream: JSValue,
}
