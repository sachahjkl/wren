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

// (Promises as values — web_promise_*, web_settle, web_then, wj_promise_reject_pending — and web_error_value are
// web_core.odin's.)
@(default_calling_convention = "c")
foreign {
	// structured clone through the browser's serializer (web_clone.c)
	web_clone_serialize   :: proc(ctx: ^Context, v: JSValue, len: ^uint) -> [^]u8 ---
	web_clone_free        :: proc(ctx: ^Context, p: rawptr) ---
	web_clone_deserialize :: proc(ctx: ^Context, p: [^]u8, len: uint) -> JSValue ---

	// Blob / File / FormData / Headers (web.h)
	web_blob_bytes   :: proc(v: JSValue, ptr: ^[^]u8, len: ^uint) -> bool ---
	web_blob_type    :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	web_blob_new     :: proc(ctx: ^Context, p: [^]u8, n: uint, type: cstring, type_len: uint) -> JSValue ---
	web_file_new     :: proc(ctx: ^Context, p: [^]u8, n: uint, type: cstring, type_len: uint, name: cstring, name_len: uint, last_modified: f64) -> JSValue ---
	web_file_from_host :: proc(ctx: ^Context, local_file: u64) -> JSValue ---
	web_entry_wrap   :: proc(ctx: ^Context, entry: u64) -> JSValue ---
	web_file_host    :: proc(v: JSValue) -> u64 ---
	web_file_meta    :: proc(ctx: ^Context, v: JSValue, name: ^Str, type: ^Str, last_modified: ^f64) -> bool ---
	web_blob_url_lookup :: proc(ctx: ^Context, url: [^]u8, n: uint) -> JSValue ---

	web_formdata_is     :: proc(v: JSValue) -> bool ---
	web_formdata_handle :: proc(v: JSValue) -> u64 ---
	web_formdata_new    :: proc(ctx: ^Context) -> JSValue ---
	web_formdata_append :: proc(ctx: ^Context, fd: JSValue, name: JSValue, value: JSValue, filename: JSValue) -> bool ---
	web_formdata_parse  :: proc(ctx: ^Context, p: [^]u8, n: uint, content_type: cstring, ct_len: uint) -> JSValue ---

	web_headers_new             :: proc(ctx: ^Context, guard: i32) -> JSValue ---
	web_headers_fill_lines      :: proc(ctx: ^Context, headers: JSValue, text: cstring, n: uint) ---
	web_headers_get             :: proc(headers: JSValue, name: cstring, len: ^uint) -> [^]u8 ---
	web_headers_has             :: proc(headers: JSValue, name: cstring) -> bool ---
	web_headers_append_raw      :: proc(headers: JSValue, name: cstring, nlen: uint, value: cstring, vlen: uint) -> bool ---
	web_headers_append_checked  :: proc(ctx: ^Context, headers: JSValue, name: cstring, nlen: uint, value: cstring, vlen: uint) -> bool ---
	web_headers_sorted          :: proc(ctx: ^Context, headers: JSValue) -> JSValue ---
	web_forbidden_request_header :: proc(name: cstring, n: uint, value: cstring, vn: uint) -> bool ---

	// streams (web_stream.c)
	web_stream_is        :: proc(v: JSValue) -> bool ---
	web_stream_locked    :: proc(v: JSValue) -> bool ---
	web_stream_disturbed :: proc(v: JSValue) -> bool ---
	web_stream_from_host :: proc(ctx: ^Context, host_stream: u64, signal: JSValue, keep: JSValue) -> JSValue ---
	web_stream_from_bytes :: proc(ctx: ^Context, p: [^]u8, n: uint) -> JSValue ---
	web_stream_of        :: proc(ctx: ^Context, chunk: JSValue) -> JSValue ---
	web_stream_pending   :: proc(ctx: ^Context) -> JSValue ---
	web_stream_push      :: proc(ctx: ^Context, stream: JSValue, chunk: JSValue) ---
	web_stream_end       :: proc(ctx: ^Context, stream: JSValue) ---
	web_stream_fail      :: proc(ctx: ^Context, stream: JSValue, e: JSValue) ---
	web_stream_read_all  :: proc(ctx: ^Context, stream: JSValue) -> JSValue ---
	web_stream_tee       :: proc(ctx: ^Context, stream: JSValue, clone_second: bool) -> JSValue ---
	web_stream_cancel    :: proc(ctx: ^Context, stream: JSValue, reason: JSValue) -> JSValue ---
	web_stream_state     :: proc(ctx: ^Context, v: JSValue, error: ^JSValue) -> i32 ---
	web_writable_state   :: proc(ctx: ^Context, v: JSValue, error: ^JSValue) -> i32 ---

	// abort signals (web_abort.c)
	web_signal_handle    :: proc(v: JSValue) -> u64 ---
	web_signal_reason    :: proc(ctx: ^Context, v: JSValue) -> JSValue ---
	web_signal_aborted   :: proc(v: JSValue) -> bool ---
	web_signal_wrap_as   :: proc(ctx: ^Context, h: u64, iface: i32) -> JSValue ---
	web_controller_construct :: proc(ctx: ^Context, new_target: JSValue, controller_iface: i32, signal_iface: i32) -> JSValue ---
	web_signal_any       :: proc(ctx: ^Context, iterable: JSValue, result_iface: i32, who: cstring) -> JSValue ---

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
