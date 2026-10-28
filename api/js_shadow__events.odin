// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=events order=45 partial
package api_js_shadow__events

/// event.composedPath() of the event being dispatched: what a listener at the current target may see (closed
/// shadow trees it is not in are hidden); 8 bytes per handle, the Window's handle for the Window.
//@wb fn
Event_composedPathPacked :: proc(event: Event) -> bytes

/// The target of the last event dispatched by EventTarget_dispatchEngineEvent once its dispatch ended (0: null, it
/// was in a shadow tree).
//@wb fn
EventTarget_lastTarget :: proc() -> u64

/// ... and its relatedTarget (0: null or cleared).
//@wb fn
EventTarget_lastRelated :: proc() -> u64

/// The relatedTarget (a node) of the next EventTarget_dispatchEngineEvent: retargeted along its path.
//@wb fn
Event_setNextRelated :: proc(related: u64)

/// The relatedTarget of the event being dispatched as the current listener sees it (retargeted; 0: null).
//@wb fn
Event_relatedNow :: proc(event: Event) -> u64

/// Whether the current listener's node was in a shadow tree when the event's path was built (window.event is then
/// left as it was).
//@wb fn
Event_inShadowTreeNow :: proc(event: u64) -> bool

