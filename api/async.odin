// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=async order=2 exposed=(Window,Worker)
/// Promises, microtasks, buffers and host objects: the asynchronous core every other module builds on.
///
/// A promise's value is an i64 (a number, or the handle of a buffer or another object) plus a string (an error message,
/// a text result). Reactions run as microtasks once it settles. There are no closures in Wasm, so `then` does not
/// create a chained promise: a reaction that passes a result on resolves a promise of its own.
///
/// A buffer is the ArrayBuffer of this platform: bytes owned by the browser, passed between APIs without copies into
/// the module's memory (fetch bodies, messages, socket frames), counted against page.max_fetch_bytes.
package api_async

//@wb handle parent=EventTarget host=Object lookup=lookup_Object
/// Any host object (not a node). Released with Object_release; freed with the page in any case.
Object :: distinct Handle

//@wb handle parent=Object host=Promise lookup=lookup_Promise
Promise :: distinct Handle

//@wb handle parent=Object host=Buffer lookup=lookup_Buffer
/// An ArrayBuffer.
Buffer :: distinct Handle

PromiseState :: enum i32 {
	Pending,
	Fulfilled,
	Rejected,
}

//@wb callback
MicrotaskCallback :: #type proc "contextless" (user: i32)

/// A reaction: read the result with Promise_value / Promise_text.
//@wb callback
PromiseReaction :: #type proc "contextless" (user: i32, promise: Promise, state: PromiseState)

/// queueMicrotask(callback)
//@wb fn
queueMicrotask :: proc(callback: MicrotaskCallback, user: i32 = 0)

/// A pending promise the module settles itself.
//@wb fn
Promise_create :: proc() -> Promise

/// Fulfils a pending promise. Invalid_Argument when it is settled already.
//@wb fn raises
Promise_resolve :: proc(promise: Promise, value: i64 = 0, text: string = "")

/// Rejects a pending promise with an Error code (or any value) and a message. Invalid_Argument when settled already.
//@wb fn raises
Promise_reject :: proc(promise: Promise, code: i64, message: string = "")

/// Adds a reaction; queued at once when the promise is settled already.
//@wb fn
Promise_then :: proc(promise: Promise, callback: PromiseReaction, user: i32 = 0)

//@wb fn
Promise_state :: proc(promise: Promise) -> PromiseState

/// The value (fulfilled) or the code (rejected).
//@wb fn
Promise_value :: proc(promise: Promise) -> i64

/// The text result (fulfilled) or the message (rejected).
//@wb fn
Promise_text :: proc(promise: Promise) -> string

/// Promise.all: fulfilled (value = the count) when every one is, rejected with the first rejection's value and text.
//@wb fn
Promise_all :: proc(promises: []Promise) -> Promise

/// Releases a host object of any kind.
//@wb fn raises
Object_release :: proc(object: Object)

/// The interface name of an object ("Promise", "ArrayBuffer"...).
//@wb fn
Object_kind :: proc(object: Object) -> string

/// A buffer holding a copy of `data`. Quota past the page's memory limit.
//@wb fn raises
Buffer_create :: proc(data: bytes) -> Buffer

/// A zero-filled buffer of `length` bytes. Quota past the page's memory limit, Range for a negative length.
//@wb fn raises
Buffer_alloc :: proc(length: i64) -> Buffer

/// byteLength (0 once detached by a transfer).
//@wb fn
Buffer_length :: proc(buffer: Buffer) -> i64

/// Copies bytes from `offset` into `destination`; returns how many.
//@wb fn out=destination
Buffer_read :: proc(buffer: Buffer, offset: i64, destination: bytes) -> i32

/// Copies `source` into the buffer at `offset` (what fits); returns how many bytes were written.
//@wb fn
Buffer_write :: proc(buffer: Buffer, offset: i64, source: bytes) -> i32

/// buffer.slice(start, end): a copy; negative positions count from the end. Quota past the page's memory limit.
//@wb fn raises
Buffer_slice :: proc(buffer: Buffer, start: i64, end: i64) -> Buffer

