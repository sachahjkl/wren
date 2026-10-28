// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=popover order=60 exposed=Window
/// The Popover API (src/page/popover.odin): the `popover` attribute, showPopover / hidePopover / togglePopover, the
/// popover target attributes of buttons, light dismiss and Escape. "beforetoggle" (cancelable when the popover opens)
/// and "toggle" are ToggleEvents: Event_data the newState, Event_text the oldState ("open" / "closed"), Event_object
/// the source (the invoker, 0 for none).
package api_popover

/// element.showPopover({source}): Not_Supported without a valid popover attribute, Invalid_State when it is not
/// connected or is the fullscreen element; nothing when it is showing already or a beforetoggle listener cancelled.
//@wb fn raises optional=source
Popover_show :: proc(element: Element, source: Element)

/// element.hidePopover(): the same errors.
//@wb fn raises
Popover_hide :: proc(element: Element)

/// element.togglePopover(force): force -1 none, 0 false (hide only), 1 true (show only). Whether it shows after.
//@wb fn raises optional=source
Popover_toggle :: proc(element: Element, force: i32, source: Element) -> bool

/// The popover attribute's state: 0 none, 1 auto, 2 manual, 3 hint.
//@wb fn
Popover_state :: proc(element: Element) -> i32

/// The popover a button's popovertarget names (0: none).
//@wb fn
Popover_targetOf :: proc(invoker: Element) -> Element

