// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=frames order=17 exposed=Window
/// Nested browsing contexts for JavaScript (src/page/frames.odin, frames_scripts.odin; native/js/runtime/frames.c and
/// prelude/frames.js). A window of another document is named by its navigable's id: each document runs in its own
/// engine instance, so another window is a WindowProxy of the calling realm that only reaches what HTML lets a
/// cross-origin window reach (postMessage, location as a setter, closed, frames, length, top, parent, opener, window,
/// self, close, focus, blur); documents never share objects, same origin or not.
package api_frames__frames

/// The navigable of the calling document.
//@wb fn
Frame_self :: proc() -> u64

/// The navigable of a frame element (<iframe>, <frame>) of the calling document; 0 when it has none (not
/// connected, frames off).
//@wb fn
Frame_ofElement :: proc(element: u64) -> u64

/// The parent navigable; 0 for a top-level one, or one that is gone.
//@wb fn
Frame_parent :: proc(navigable: u64) -> u64

/// The top-level navigable of its tab; 0 when it is gone.
//@wb fn
Frame_top :: proc(navigable: u64) -> u64

/// How many child navigables its document has (window.length).
//@wb fn
Frame_length :: proc(navigable: u64) -> u32

/// Its document's index-th child navigable in tree order of their containers (window[index]); 0 when none.
//@wb fn
Frame_child :: proc(navigable: u64, index: u32) -> u64

/// Its document's child navigable named `name` (window[name], reachable across origins); 0 when none.
//@wb fn
Frame_named :: proc(navigable: u64, name: string) -> u64

/// The names of its document's child navigables, NUL separated (the WindowProxy's own property names).
//@wb fn
Frame_childNames :: proc(navigable: u64) -> string

/// window.closed: the navigable is gone, or has no document.
//@wb fn
Frame_closed :: proc(navigable: u64) -> bool

/// Whether its document is same origin with the calling one.
//@wb fn
Frame_sameOrigin :: proc(navigable: u64) -> bool

/// otherWindow.postMessage(message, targetOrigin): `data` is the message's structured serialization
/// (runtime/clone.c); `target_origin` is "*", "/" or a URL. The message is delivered from a task of the target's,
/// if its document's origin then matches. Syntax for an invalid target origin, Data_Clone for a message over
/// frames.max_message_bytes.
//@wb fn raises
Frame_postMessage :: proc(navigable: u64, data: bytes, target_origin: usvstring)

/// otherWindow.location = url, location.href = url, location.replace(url): Security when the calling document may
/// not navigate it (HTML "allowed to navigate", the sandbox; the console says why), Syntax for an invalid URL.
//@wb fn raises
Frame_navigate :: proc(navigable: u64, url: usvstring, replace: bool)

/// window.open(url, target): a frame's name, _self, _parent or _top is navigated and its navigable returned; any
/// other target opens a new tab (when the embedder can) and gives 0 (no opener relationship, as noopener).
/// Not_Allowed in a sandboxed document without allow-popups, Syntax for an invalid URL.
//@wb fn raises
Frame_open :: proc(url: usvstring, target: string) -> u64

/// otherWindow.postMessage(message, targetOrigin, [ports]): the same, with the MessagePorts of the transfer list
/// shipped as port ends (Port_ship / Port_entangle): the receiver's MessageEvent.ports are bound to them.
//@wb fn raises
Frame_postMessagePorts :: proc(navigable: u64, data: bytes, target_origin: usvstring, ports: []u64)

/// window.name: its navigable's name.
//@wb fn
Window_get_name :: proc() -> string

/// window.name = value
//@wb fn
Window_set_name :: proc(value: string)

