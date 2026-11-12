package dom

// Event types the browser knows, as small integers. A listener and an event of one of these types carry its atom:
// matching a listener is one integer compare, the type's properties are one table read, and the listener's `type` is
// the program's string (nothing to allocate or free). A type outside the table (a script's own "my-event") has atom
// None and keeps its own copy of the string.

Event_Atom :: enum u16 {
	None,
	// MouseEvent
	click, dblclick, auxclick, mousedown, mouseup, mousemove, mouseover, mouseout, mouseenter, mouseleave, contextmenu,
	// PointerEvent
	pointerdown, pointerup, pointermove, pointerover, pointerout, pointerenter, pointerleave, pointercancel,
	gotpointercapture, lostpointercapture,
	// DragEvent
	dragstart, drag, dragenter, dragleave, dragover, drop, dragend,
	// TouchEvent
	touchstart, touchmove, touchend, touchcancel,
	wheel,
	keydown, keyup, keypress,
	focus, blur, focusin, focusout,
	input, beforeinput,
	compositionstart, compositionupdate, compositionend,
	message, messageerror,
	hashchange, popstate, storage, submit, formdata, toggle, beforetoggle,
	transitionrun, transitionstart, transitionend, transitioncancel,
	animationstart, animationend, animationiteration, animationcancel,
	pageshow, pagehide, beforeunload,
	close, change, finish, cancel, remove,
	progress, loadstart, loadend, abort, timeout, error,
	select, selectstart, copy, cut, paste,
	load, unload, DOMContentLoaded, readystatechange, resize, scroll, scrollend, visibilitychange, slotchange, reset,
	invalid, open,
	// the prefixed names of DOM "invoke" (legacy_event_type)
	webkitAnimationEnd, webkitAnimationIteration, webkitAnimationStart, webkitTransitionEnd,
}

// The interface of the events the browser makes of a type. The last five depend on the target too (the page decides:
// a `close` at a WebSocket is a CloseEvent, at a dialog an Event).
Event_Class :: enum u8 {
	Event, Mouse, Pointer, Drag, Touch, Wheel, Keyboard, Focus, Input, Composition, Message, Hash_Change, Pop_State,
	Storage, Submit, Form_Data, Toggle, Transition, Animation, Page_Transition, Before_Unload,
	Close, Change, Playback, Progress, Error,
}

Event_Type_Info :: struct {
	name:     string,
	class:    Event_Class,
	composed: bool,   // the browser dispatches it composed (UI Events, Pointer Events, Input Events, HTML focus)
	pointer:  bool,   // it has a position (MouseEvent and its kinds): pageX, offsetX...
	legacy:   Event_Atom,   // DOM "invoke": the prefixed type its listeners may be registered under
}

@(rodata)
EVENT_TYPES := #partial [Event_Atom]Event_Type_Info{
	.click = {"click", .Mouse, true, true, .None}, .dblclick = {"dblclick", .Mouse, true, true, .None},
	.auxclick = {"auxclick", .Mouse, true, true, .None}, .mousedown = {"mousedown", .Mouse, true, true, .None},
	.mouseup = {"mouseup", .Mouse, true, true, .None}, .mousemove = {"mousemove", .Mouse, true, true, .None},
	.mouseover = {"mouseover", .Mouse, true, true, .None}, .mouseout = {"mouseout", .Mouse, true, true, .None},
	.mouseenter = {"mouseenter", .Mouse, false, true, .None}, .mouseleave = {"mouseleave", .Mouse, false, true, .None},
	.contextmenu = {"contextmenu", .Mouse, true, true, .None},
	.pointerdown = {"pointerdown", .Pointer, true, true, .None}, .pointerup = {"pointerup", .Pointer, true, true, .None},
	.pointermove = {"pointermove", .Pointer, true, true, .None}, .pointerover = {"pointerover", .Pointer, true, true, .None},
	.pointerout = {"pointerout", .Pointer, true, true, .None}, .pointerenter = {"pointerenter", .Pointer, false, true, .None},
	.pointerleave = {"pointerleave", .Pointer, false, true, .None}, .pointercancel = {"pointercancel", .Pointer, true, true, .None},
	.gotpointercapture = {"gotpointercapture", .Pointer, true, true, .None},
	.lostpointercapture = {"lostpointercapture", .Pointer, true, true, .None},
	.dragstart = {"dragstart", .Drag, true, true, .None}, .drag = {"drag", .Drag, true, true, .None},
	.dragenter = {"dragenter", .Drag, true, true, .None}, .dragleave = {"dragleave", .Drag, true, true, .None},
	.dragover = {"dragover", .Drag, true, true, .None}, .drop = {"drop", .Drag, true, true, .None},
	.dragend = {"dragend", .Drag, true, true, .None},
	.touchstart = {"touchstart", .Touch, true, false, .None}, .touchmove = {"touchmove", .Touch, true, false, .None},
	.touchend = {"touchend", .Touch, true, false, .None}, .touchcancel = {"touchcancel", .Touch, true, false, .None},
	.wheel = {"wheel", .Wheel, true, true, .None},
	.keydown = {"keydown", .Keyboard, true, false, .None}, .keyup = {"keyup", .Keyboard, true, false, .None},
	.keypress = {"keypress", .Keyboard, true, false, .None},
	.focus = {"focus", .Focus, true, false, .None}, .blur = {"blur", .Focus, true, false, .None},
	.focusin = {"focusin", .Focus, true, false, .None}, .focusout = {"focusout", .Focus, true, false, .None},
	.input = {"input", .Input, true, false, .None}, .beforeinput = {"beforeinput", .Input, true, false, .None},
	.compositionstart = {"compositionstart", .Composition, true, false, .None},
	.compositionupdate = {"compositionupdate", .Composition, true, false, .None},
	.compositionend = {"compositionend", .Composition, true, false, .None},
	.message = {"message", .Message, false, false, .None}, .messageerror = {"messageerror", .Message, false, false, .None},
	.hashchange = {"hashchange", .Hash_Change, false, false, .None}, .popstate = {"popstate", .Pop_State, false, false, .None},
	.storage = {"storage", .Storage, false, false, .None}, .submit = {"submit", .Submit, false, false, .None},
	.formdata = {"formdata", .Form_Data, false, false, .None}, .toggle = {"toggle", .Toggle, false, false, .None},
	.beforetoggle = {"beforetoggle", .Toggle, false, false, .None},
	.transitionrun = {"transitionrun", .Transition, false, false, .None},
	.transitionstart = {"transitionstart", .Transition, false, false, .None},
	.transitionend = {"transitionend", .Transition, false, false, .webkitTransitionEnd},
	.transitioncancel = {"transitioncancel", .Transition, false, false, .None},
	.animationstart = {"animationstart", .Animation, false, false, .webkitAnimationStart},
	.animationend = {"animationend", .Animation, false, false, .webkitAnimationEnd},
	.animationiteration = {"animationiteration", .Animation, false, false, .webkitAnimationIteration},
	.animationcancel = {"animationcancel", .Animation, false, false, .None},
	.pageshow = {"pageshow", .Page_Transition, false, false, .None}, .pagehide = {"pagehide", .Page_Transition, false, false, .None},
	.beforeunload = {"beforeunload", .Before_Unload, false, false, .None},
	.close = {"close", .Close, false, false, .None}, .change = {"change", .Change, false, false, .None},
	.finish = {"finish", .Playback, false, false, .None}, .cancel = {"cancel", .Playback, false, false, .None},
	.remove = {"remove", .Playback, false, false, .None},
	.progress = {"progress", .Progress, false, false, .None}, .loadstart = {"loadstart", .Progress, false, false, .None},
	.loadend = {"loadend", .Progress, false, false, .None}, .abort = {"abort", .Progress, false, false, .None},
	.timeout = {"timeout", .Progress, false, false, .None}, .error = {"error", .Error, false, false, .None},
	.select = {"select", .Event, true, false, .None}, .selectstart = {"selectstart", .Event, true, false, .None},
	.copy = {"copy", .Event, true, false, .None}, .cut = {"cut", .Event, true, false, .None},
	.paste = {"paste", .Event, true, false, .None},
	.load = {"load", .Event, false, false, .None}, .unload = {"unload", .Event, false, false, .None},
	.DOMContentLoaded = {"DOMContentLoaded", .Event, false, false, .None},
	.readystatechange = {"readystatechange", .Event, false, false, .None},
	.resize = {"resize", .Event, false, false, .None}, .scroll = {"scroll", .Event, false, false, .None},
	.scrollend = {"scrollend", .Event, false, false, .None},
	.visibilitychange = {"visibilitychange", .Event, false, false, .None},
	.slotchange = {"slotchange", .Event, false, false, .None}, .reset = {"reset", .Event, false, false, .None},
	.invalid = {"invalid", .Event, false, false, .None}, .open = {"open", .Event, false, false, .None},
	.webkitAnimationEnd = {"webkitAnimationEnd", .Event, false, false, .None},
	.webkitAnimationIteration = {"webkitAnimationIteration", .Event, false, false, .None},
	.webkitAnimationStart = {"webkitAnimationStart", .Event, false, false, .None},
	.webkitTransitionEnd = {"webkitTransitionEnd", .Event, false, false, .None},
}

// The atom of an event type (case-sensitive, as event types are), None for a type the table does not have. A linear
// scan that compares lengths and first bytes before the strings: it runs once per listener added and per dispatch,
// never per listener compared.
event_atom :: proc "contextless" (type: string) -> Event_Atom {
	if len(type) == 0 { return .None }
	for info, atom in EVENT_TYPES {
		if len(info.name) == len(type) && info.name[0] == type[0] && info.name == type { return atom }
	}
	return .None
}

// The properties of an atom (the zero value for None).
event_info :: #force_inline proc "contextless" (atom: Event_Atom) -> Event_Type_Info { return EVENT_TYPES[atom] }

// The type's string kept by a listener or an event: the table's when it has an atom, else a copy (owned).
@(private)
event_type_string :: proc(atom: Event_Atom, type: string) -> string {
	if atom != .None { return EVENT_TYPES[atom].name }
	return heap_str(type)
}

// Frees a string event_type_string returned.
@(private)
event_type_free :: proc(atom: Event_Atom, type: string) {
	if atom == .None { delete(type) }
}

// Whether a listener of (`l_atom`, `l_type`) listens for an event of (`atom`, `type`).
@(private)
type_matches :: #force_inline proc "contextless" (l_atom: Event_Atom, l_type: string, atom: Event_Atom, type: string) -> bool {
	if atom != .None { return l_atom == atom }
	return l_atom == .None && l_type == type
}
