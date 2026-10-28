// Dedicated workers whose script is JavaScript (api/js_load.widl: the engine's side of workers), and the port ends
// MessagePorts travel on between realms (api/ports.widl). Used by native/js/odin/workers.odin and web_message.odin.
package api_decl

import "../abi"

// A Worker object of the page (a handle of module workers).
Worker :: distinct abi.Handle

// The type of a worker's script (`new Worker(url, {type})`).
WorkerType :: enum i32 { Classic, Module }

// new Worker(url, {name, type}): Syntax for an invalid URL, Not_Supported for a type the browser does not run, any other
// error when the browser refuses (the console says why).
Worker_createScript :: #type proc(url: string, name: string, type: WorkerType) -> (Worker, abi.Api_Error)
// new Worker(blobURL): the same, with the script read from the realm's Blob.
Worker_createScriptBytes :: #type proc(url: string, name: string, type: WorkerType, script: abi.Bytes) -> (Worker, abi.Api_Error)
// worker.postMessage(message): the structured serialization bytes.
Worker_postSerialized :: #type proc(worker: Worker, data: abi.Bytes) -> abi.Api_Error
// worker.postMessage(message, transfer) with MessagePorts in the transfer list (their ends in `ports`).
Worker_postSerializedPorts :: #type proc(worker: Worker, data: abi.Bytes, ports: []u64) -> abi.Api_Error
// worker.terminate()
Worker_terminate :: #type proc(worker: Worker) -> abi.Api_Error
// postMessage(message) in a worker.
DedicatedWorkerGlobalScope_postSerialized :: #type proc(data: abi.Bytes) -> abi.Api_Error
// postMessage(message, transfer) in a worker, with MessagePorts.
DedicatedWorkerGlobalScope_postSerializedPorts :: #type proc(data: abi.Bytes, ports: []u64) -> abi.Api_Error
// importScripts(url), one URL, fetched synchronously: the final URL, a NUL, then the source.
WorkerGlobalScope_importScript :: #type proc(url: string) -> (string, abi.Api_Error)
// Whether the calling worker's script is a module.
WorkerGlobalScope_isModule :: #type proc() -> bool

// A new pair of entangled port ends: the first end (the second is that id + 1), owned by nobody yet.
Port_entangle :: #type proc() -> u64
// The calling realm owns this end from now on (Invalid_Argument for an end that is gone or owned).
Port_bind :: #type proc(end: u64) -> abi.Api_Error
// The calling realm gives this end up (it travels in a message).
Port_ship :: #type proc(end: u64)
// port.postMessage on an end, with the ends of the ports that go with it (Data_Clone over the size limit).
Port_post :: #type proc(end: u64, data: abi.Bytes, ports: []u64) -> abi.Api_Error
// port.close(): the pair is disentangled.
Port_close :: #type proc(end: u64)
