// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=events order=12 exposed=(Window,Worker)
/// Events (DOM Standard: EventTarget, Event; UI Events: MouseEvent, KeyboardEvent). Any node and any host object (a
/// promise, a socket, a worker, an abort signal...) is an EventTarget. An Event handle is valid while its listeners run.
package api_events

//@wb handle
/// A node or a host object: whatever can have listeners. Checked by the functions that take it.
EventTarget :: distinct Handle

//@wb handle host=dom.Event lookup=lookup_Event
/// The event being dispatched.
Event :: distinct Handle

/// addEventListener options.
//@wb flags base=u32
ListenerOptions :: enum u32 {
	/// Run in the capture phase.
	Capture,
	/// Remove the listener after its first call.
	Once,
	/// The listener will not call preventDefault.
	Passive,
}

/// What dispatchEvent creates.
//@wb flags base=u32
EventInit :: enum u32 {
	Bubbles,
	Cancelable,
	/// The event crosses shadow roots: its path goes on to the hosts (targets retargeted).
	Composed,
}

/// A listener: `user` is the value given to addEventListener.
//@wb callback
EventListener :: #type proc "contextless" (user: i32, event: Event)

/// target.addEventListener(type, listener, options). Returns the listener's id (for removeEventListener); adding the
/// same (type, callback, user) again returns the existing id.
//@wb fn raises
EventTarget_addEventListener :: proc(target: EventTarget, type: string, callback: EventListener, user: i32 = 0, options: ListenerOptions = none) -> i32

/// target.removeEventListener(id). Not_Found when there is no such listener.
//@wb fn raises
EventTarget_removeEventListener :: proc(target: EventTarget, id: i32)

/// target.dispatchEvent(new Event(type, init)): false when a listener cancelled it.
//@wb fn raises
EventTarget_dispatchEvent :: proc(target: EventTarget, type: string, init: EventInit = none) -> bool

/// event.preventDefault() (ignored when the event is not cancelable).
//@wb fn
Event_preventDefault :: proc(event: Event)

/// event.stopPropagation()
//@wb fn
Event_stopPropagation :: proc(event: Event)

/// event.stopImmediatePropagation()
//@wb fn
Event_stopImmediatePropagation :: proc(event: Event)

/// event.target
//@wb fn
Event_target :: proc(event: Event) -> EventTarget

/// event.currentTarget
//@wb fn
Event_currentTarget :: proc(event: Event) -> EventTarget

/// event.type
//@wb fn
Event_type :: proc(event: Event) -> string

/// event.defaultPrevented
//@wb fn
Event_defaultPrevented :: proc(event: Event) -> bool

/// The main string payload of a non-UI event: MessageEvent.data, InputEvent.data, ErrorEvent.message...
//@wb fn
Event_data :: proc(event: Event) -> string

/// The second string payload: CloseEvent.reason, InputEvent.inputType, MessageEvent.lastEventId, the reason of an abort...
//@wb fn
Event_text :: proc(event: Event) -> string

/// The numeric payload: CloseEvent.code, an abort reason's code, the number of buffers of a message...
//@wb fn
Event_code :: proc(event: Event) -> i64

/// The object payload: a buffer, SubmitEvent.submitter, FocusEvent.relatedTarget, FormDataEvent.formData...
//@wb fn
Event_object :: proc(event: Event) -> EventTarget

/// MouseEvent.clientX
//@wb fn
MouseEvent_clientX :: proc(event: Event) -> f64

/// MouseEvent.clientY
//@wb fn
MouseEvent_clientY :: proc(event: Event) -> f64

/// MouseEvent.button
//@wb fn
MouseEvent_button :: proc(event: Event) -> i32

/// KeyboardEvent.keyCode
//@wb fn
KeyboardEvent_keyCode :: proc(event: Event) -> i32

