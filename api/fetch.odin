// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=fetch order=14 exposed=Window
/// The promise side of the Fetch API, on the same records as the callback API of module net (a Response is a Fetch:
/// Fetch_status, Fetch_headers, Fetch_release... apply to it).
/// * Fetch_promise settles with the Response when the headers arrive; it is rejected on a network error (Network)
/// or an abort (the signal's reason).
/// * Response_text / Response_arrayBuffer settle when the whole body is there; a body is consumed once (bodyUsed).
/// * Response_body is a minimal ReadableStream: Stream_read settles with a buffer of what arrived since the last read,
/// or with 0 (text "done") at the end; Stream_cancel stops the download.
/// * An abort signal cancels the request and fails it with error kind Aborted.
package api_fetch

//@wb handle parent=Object host=Body_Stream lookup=lookup_ReadableStream
/// The body of a response being read in chunks.
ReadableStream :: distinct Handle

/// fetch(url, init): the body is `body`, or the bytes of `body_buffer` when given. Type when the signal is not an
/// AbortSignal or the buffer not a buffer.
//@wb fn raises optional=body,body_buffer,signal
Fetch_promise :: proc(url: string, method: string = "GET", headers: string = "", body: bytes, body_buffer: Buffer, signal: AbortSignal, options: FetchOptions = none) -> Promise(Response)

/// The callback API (Fetch_start) with an abort signal and an optional buffer body.
//@wb fn raises optional=body,body_buffer,signal
Fetch_startWithSignal :: proc(url: string, callback: FetchCallback, user: i32 = 0, method: string = "GET", headers: string = "", body: bytes, body_buffer: Buffer, signal: AbortSignal, options: FetchOptions = none) -> Fetch

/// A synchronous XMLHttpRequest of a worker: the request Fetch_startWithSignal would make, waited for on the worker's
/// thread; the finished record (read it with Fetch_status, Fetch_headers, Fetch_readBody..., then release it).
/// Not_Supported in a document (its thread is the page's), Timeout past `timeout_ms` (0: none), Network on a failure.
//@wb fn raises optional=body
Fetch_sync :: proc(url: string, method: string = "GET", headers: string = "", body: bytes, options: FetchOptions = none, timeout_ms: u32 = 0) -> Fetch

/// response.text(): settles with the text (decoded as UTF-8) in the promise's text, its length as value.
/// A callback fetch can be read once it is done (Invalid_State before).
//@wb fn
Response_text :: proc(response: Response) -> Promise(string)

/// response.arrayBuffer(): settles with a buffer.
//@wb fn
Response_arrayBuffer :: proc(response: Response) -> Promise(Buffer)

/// response.bytes(): the same as arrayBuffer on this platform.
//@wb fn
Response_bytes :: proc(response: Response) -> Promise(Buffer)

/// response.bodyUsed
//@wb fn
Response_bodyUsed :: proc(response: Response) -> bool

/// response.body: the body as a stream. Type when the body was used already.
//@wb fn raises
Response_body :: proc(response: Response) -> ReadableStream

/// reader.read(): settles with a buffer, or with 0 at the end.
//@wb fn
Stream_read :: proc(stream: ReadableStream) -> Promise(Buffer)

/// reader.cancel(): the download stops, waiting reads settle with "done".
//@wb fn
Stream_cancel :: proc(stream: ReadableStream)

