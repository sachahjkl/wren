// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=events order=32 partial
/// UI Events for JavaScript (src/page/js_dom_events.odin): what MouseEvent, PointerEvent, WheelEvent, KeyboardEvent,
/// InputEvent and FocusEvent read from an event the browser dispatches. The engine copies them when it first wraps the
/// event, so they stay readable after the dispatch.
package api_js_dom_events

/// The numeric details of a UI event.
UiEventData :: struct {
	/// clientX / clientY (CSS px, viewport)
	client_x: f64,
	client_y: f64,
	/// screenX / screenY
	screen_x: f64,
	screen_y: f64,
	/// pageX / pageY (the document's scroll offsets added)
	page_x: f64,
	page_y: f64,
	/// offsetX / offsetY (from the target's padding edge)
	offset_x: f64,
	offset_y: f64,
	/// deltaX / deltaY / deltaZ (WheelEvent)
	delta_x: f64,
	delta_y: f64,
	delta_z: f64,
	/// relatedTarget (a node), 0 = null
	related: u64,
	/// modifier bits: 1 ctrl, 2 shift, 4 alt, 8 meta
	mods: u32,
	/// MouseEvent.button
	button: i32,
	/// MouseEvent.buttons
	buttons: u32,
	/// UIEvent.detail
	detail: i32,
	/// KeyboardEvent.keyCode (and which, charCode for keypress)
	key_code: u32,
	/// KeyboardEvent.location
	location: u32,
	/// KeyboardEvent.repeat
	repeat: u32,
	/// WheelEvent.deltaMode
	delta_mode: u32,
	/// PointerEvent.pointerId (1 for the mouse)
	pointer_id: i32,
	/// PointerEvent.pointerType: 0 mouse, 1 pen, 2 touch
	pointer_type: u32,
	/// PointerEvent.isPrimary
	is_primary: u32,
	/// PointerEvent.pressure, tangentialPressure
	pressure: f64,
	tangential_pressure: f64,
	/// PointerEvent.width / height (CSS px)
	width: f64,
	height: f64,
	/// PointerEvent.tiltX / tiltY / twist (degrees)
	tilt_x: f64,
	tilt_y: f64,
	twist: f64,
}

/// A Touch of a TouchEvent.
TouchPoint :: struct {
	identifier: i32,
	/// the element the touch started on
	target: u64,
	client_x: f64,
	client_y: f64,
	screen_x: f64,
	screen_y: f64,
	page_x: f64,
	page_y: f64,
	radius_x: f64,
	radius_y: f64,
	rotation_angle: f64,
	force: f64,
}

/// The lists of a TouchEvent.
TouchListKind :: enum i32 {
	Touches,
	Target_Touches,
	Changed_Touches,
}

/// The number of touches in a list of a TouchEvent the browser dispatches (0 for another event).
//@wb fn
TouchEvent_count :: proc(event: Event, list: TouchListKind) -> i32

/// A touch of that list (Invalid_Argument past its end).
//@wb fn raises
TouchEvent_touch :: proc(event: Event, list: TouchListKind, index: i32) -> TouchPoint

/// Element.setPointerCapture(pointerId): Not_Found for a pointer that is not active, Invalid_State for an element
/// that is not connected. The capture takes effect at the pointer's next event (gotpointercapture).
//@wb fn raises
PointerCapture_set :: proc(element: Element, pointer_id: i32)

/// Element.releasePointerCapture(pointerId): Not_Found for a pointer that is not active.
//@wb fn raises
PointerCapture_release :: proc(element: Element, pointer_id: i32)

/// Element.hasPointerCapture(pointerId)
//@wb fn
PointerCapture_has :: proc(element: Element, pointer_id: i32) -> bool

/// The details of a UI event being dispatched.
//@wb fn
Event_uiData :: proc(event: Event) -> UiEventData

/// KeyboardEvent.key ("Enter", "a"...): "Unidentified" when unknown.
//@wb fn
UiEvent_key :: proc(event: Event) -> string

/// KeyboardEvent.code ("KeyA", "Enter"...): "" when unknown.
//@wb fn
UiEvent_code :: proc(event: Event) -> string

