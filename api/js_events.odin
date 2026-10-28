// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=events order=40 partial
/// Events as JavaScript sees them: Event objects the script created (dispatched with their engine identifier, so the
/// listeners receive the very same object), the interface and state of the browser's own events, and EventTarget
/// objects with nothing behind them (new EventTarget()).
package api_js_events

/// target.dispatchEvent(event) for an Event the engine owns: like EventTarget_dispatchEvent, with the engine's
/// identifier of the object (Event_engineId gives it back to the listeners) and its timeStamp. Returns false when a
/// listener cancelled it. The event is not trusted (isTrusted is false).
//@wb fn raises
EventTarget_dispatchEngineEvent :: proc(target: EventTarget, type: string, init: EventInit, engine_id: i64, time_stamp: f64) -> bool

/// The engine's identifier given to EventTarget_dispatchEngineEvent (0 for an event the browser made).
//@wb fn
Event_engineId :: proc(event: Event) -> i64

/// The interface of the wrapper of an event the browser made (MouseEvent, KeyboardEvent...): an index into the
/// engine's interface table.
//@wb fn
Event_interface :: proc(event: Event) -> u32

/// Whether the event is still being dispatched (its handle is live).
//@wb fn
Event_isLive :: proc(event: u64) -> bool

/// event.bubbles
//@wb fn
Event_bubbles :: proc(event: Event) -> bool

/// event.cancelable
//@wb fn
Event_cancelable :: proc(event: Event) -> bool

/// event.composed: whether the event crosses shadow boundaries (the browser's UI events, fullscreenchange...).
//@wb fn
Event_composed :: proc(event: Event) -> bool

/// event.eventPhase: 0 none, 1 capturing, 2 at target, 3 bubbling.
//@wb fn
Event_eventPhase :: proc(event: Event) -> i32

/// event.timeStamp, on the performance.now() timeline of the page.
//@wb fn
Event_timeStamp :: proc(event: Event) -> f64

/// event.isTrusted
//@wb fn
Event_isTrusted :: proc(event: Event) -> bool

/// Whether stopPropagation was called.
//@wb fn
Event_propagationStopped :: proc(event: Event) -> bool

/// new EventTarget(): a host object with nothing but listeners.
//@wb fn
EventTarget_create :: proc() -> Object

