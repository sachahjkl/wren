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

	// FormData / Headers (web.h). (Blob / File: web_blob_* / web_file_* are Odin, package odin_glue, web_blob.odin.)
	web_entry_wrap   :: proc(ctx: ^Context, entry: u64) -> JSValue ---

	// (web_formdata_* are Odin, package odin_glue, web_formdata.odin)

	// (Headers, extract a body: web_headers_*, web_extract_body, web_extracted_free are Odin, package odin_glue,
	// web_fetch.odin)

	// (streams: web_stream_* and web_writable_state are Odin, package odin_glue, web_stream.odin / web_writable.odin)

	// (abort signals: web_signal_* and web_controller_construct are Odin, package odin_glue, web_abort.odin)
}

// web_extracted (web.h): the bytes, Content-Type and a kept ReadableStream of "extract a body" (what the C callers of
// web_extract_body receive).
Extracted :: struct {
	data:   [^]u8,
	len:    uint,
	type:   cstring,
	stream: JSValue,
}
