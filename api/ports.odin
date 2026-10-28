// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=ports order=61 exposed=(Window,Worker)
/// MessagePorts between realms (src/page/ports.odin; native/js/runtime/web_message.c, workers.c): a port whose other
/// side is in another realm (another document, a worker) talks through a pair of port ends the browser routes. An end
/// belongs to one realm at a time; while it travels in a message it belongs to none, and what is posted to it waits
/// for its next owner.
package api_ports

/// A new pair of entangled port ends: the first end's id (the second is that id + 1), owned by nobody yet.
//@wb fn
Port_entangle :: proc() -> u64

/// The calling realm owns this end from now on: what was posted to it meanwhile is delivered (each message from a
/// task: the engine's wj_port_message). Invalid_Argument for an end that is gone or owned.
//@wb fn raises
Port_bind :: proc(end: u64)

/// The calling realm gives this end up (it is in a message being sent).
//@wb fn
Port_ship :: proc(end: u64)

/// port.postMessage(message, [ports]) on an end: delivered to the other end's owner (queued while it has none).
/// Data_Clone for a message over frames.max_message_bytes.
//@wb fn raises
Port_post :: proc(end: u64, data: bytes, ports: []u64)

/// port.close(): the pair is disentangled; nothing more is delivered to either end.
//@wb fn
Port_close :: proc(end: u64)

/// worker.postMessage(message, transfer) with MessagePorts in the transfer list (shipped as `ports`).
//@wb fn raises
Worker_postSerializedPorts :: proc(worker: u64, data: bytes, ports: []u64)

/// postMessage(message, transfer) in a worker, with MessagePorts.
//@wb fn raises
DedicatedWorkerGlobalScope_postSerializedPorts :: proc(data: bytes, ports: []u64)

/// new BroadcastChannel(name): a port end of the channel (the realm's origin and the name), owned by the calling
/// realm; 0 for an opaque origin (the object sends and receives nothing). Port_close closes it.
//@wb fn
Broadcast_open :: proc(name: string) -> u64

/// broadcastChannel.postMessage: the serialized message to every other end of the channel, in every realm.
/// Data_Clone for a message over frames.max_message_bytes.
//@wb fn raises
Broadcast_post :: proc(end: u64, data: bytes)

/// The port ends that came with a worker's message event (8 bytes each), given once: the caller binds them.
//@wb fn
MessageEvent_portEnds :: proc(event: Event) -> bytes

