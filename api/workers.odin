// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=workers order=75 exposed=(Window,Worker)
/// Dedicated workers (HTML). A message event carries the text in Event_data, the number of transferred buffers in
/// Event_code and the first one in Event_object; the buffers belong to the receiver. Invalid_Argument for a handle that
/// is not a transferable buffer or appears twice, a message over workers.max_message_bytes, a receiver with too much
/// waiting, or a function of the other side (a page calling a worker function or the reverse).
package api_workers

//@wb handle parent=Object
/// A Worker object (EventTarget: message, messageerror, error).
Worker :: distinct Handle

//@wb handle parent=Object
/// The global scope of a worker (EventTarget: message, messageerror).
WorkerGlobalScope :: distinct Handle

/// new Worker(url, {name}). Not_Allowed when the browser refuses it (the console says why).
//@wb fn raises
Worker_create :: proc(url: string, name: string = "") -> Worker

/// worker.postMessage(message, transfer)
//@wb fn raises
Worker_postMessage :: proc(worker: Worker, message: string, transfer: []Buffer)

/// worker.terminate()
//@wb fn raises
Worker_terminate :: proc(worker: Worker)

/// self, in a worker (null in a page).
//@wb fn
DedicatedWorkerGlobalScope_self :: proc() -> WorkerGlobalScope

/// postMessage(message, transfer), in a worker.
//@wb fn raises
DedicatedWorkerGlobalScope_postMessage :: proc(message: string, transfer: []Buffer)

/// close(), in a worker.
//@wb fn raises
DedicatedWorkerGlobalScope_close :: proc()

/// self.name, in a worker.
//@wb fn raises
DedicatedWorkerGlobalScope_name :: proc() -> string

/// close(), in a shared worker: no connect event any more; the worker stops after the current task.
//@wb fn raises
SharedWorkerGlobalScope_close :: proc()

/// self.name, in a shared worker.
//@wb fn raises
SharedWorkerGlobalScope_name :: proc() -> string

/// location.href, in a worker: the script's URL.
//@wb fn raises
WorkerGlobalScope_location :: proc() -> string

/// The index-th buffer that came with a message event (null when none).
//@wb fn
MessageEvent_transfer :: proc(event: Event, index: i32) -> Buffer

