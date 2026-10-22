package page

// What the browser's developer tools read of a page without going through JavaScript: the computed style of an
// element, as getComputedStyle serializes it (js_dom_style.odin).

import "wb:base"
import "wb:style"

@(private = "file")
computed_names := COMPUTED_PROPERTIES

// The properties getComputedStyle lists, in alphabetical order.
computed_property_names :: proc() -> []string { return computed_names[:] }

// The resolved value of property `name` of element `h` ("" when the element has no style or the property is not known).
// The strings live in the temporary allocator.
computed_property :: proc(p: ^Page, h: base.Handle, name: string) -> string {
	if p == nil || p.closed { return "" }
	st := js_dom_styled(p)
	if st == nil { return "" }
	cs := style.style_of(st, h)
	if cs == nil { return "" }
	return computed_value(cs, name, used_box(p, h))
}
