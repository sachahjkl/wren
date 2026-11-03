package page

import "core:testing"
import "wb:base"
import "wb:dom"

// The interface of a wrapper by its element's name (the lookup by first byte, then name), every way it can end.
@(test)
element_interface_by_name :: proc(t: ^testing.T) {
	testing.expect_value(t, js_html_interface("a"), JS_IFACE_HTMLAnchorElement)
	testing.expect_value(t, js_html_interface("li"), JS_IFACE_HTMLLIElement)
	testing.expect_value(t, js_html_interface("span"), JS_IFACE_HTMLSpanElement)
	testing.expect_value(t, js_html_interface("ul"), JS_IFACE_HTMLUListElement)
	testing.expect_value(t, js_html_interface("video"), JS_IFACE_HTMLVideoElement)
	testing.expect_value(t, js_html_interface("b"), JS_IFACE_HTMLElement)
	testing.expect_value(t, js_html_interface("my-element"), JS_IFACE_HTMLElement)   // a valid custom element name
	testing.expect_value(t, js_html_interface("lix"), JS_IFACE_HTMLUnknownElement)   // a known name's first byte, no name
	testing.expect_value(t, js_html_interface("quux"), JS_IFACE_HTMLUnknownElement)
	testing.expect_value(t, js_html_interface(""), JS_IFACE_HTMLUnknownElement)
	testing.expect_value(t, js_svg_interface("svg"), JS_IFACE_SVGSVGElement)
	testing.expect_value(t, js_svg_interface("circle"), JS_IFACE_SVGCircleElement)
	testing.expect_value(t, js_svg_interface("li"), JS_IFACE_SVGElement)
	testing.expect_value(t, js_svg_interface(""), JS_IFACE_SVGElement)
}

// What an inserted subtree holds for the insertion steps (one walk; the steps that look further run only for it).
@(test)
inserted_subtree_kinds :: proc(t: ^testing.T) {
	d := dom.document_create()
	defer dom.document_destroy(d)
	el :: proc(d: ^dom.Document, parent: base.Handle, name: string) -> base.Handle {
		h := dom.create_element(d, name)
		if parent != base.NIL_HANDLE { dom.append_child(d, parent, h) }
		return h
	}
	// a list as scripts build it: nothing for the steps
	li := el(d, base.NIL_HANDLE, "li")
	el(d, li, "span")
	el(d, li, "b")
	dom.append_child(d, li, dom.create_text(d, "item"))
	testing.expect_value(t, inserted_kinds(d, li), bit_set[Inserted_Kind]{})
	testing.expect_value(t, inserted_kinds(d, dom.create_text(d, "text")), bit_set[Inserted_Kind]{})
	// what each step looks for, deep in the subtree
	div := el(d, base.NIL_HANDLE, "div")
	inner := el(d, el(d, div, "section"), "p")
	el(d, inner, "script")
	el(d, inner, "link")
	el(d, div, "video")
	testing.expect_value(t, inserted_kinds(d, div), bit_set[Inserted_Kind]{.Script, .Link, .Media})
	testing.expect_value(t, inserted_kinds(d, el(d, base.NIL_HANDLE, "iframe")), bit_set[Inserted_Kind]{.Frame})
	testing.expect_value(t, inserted_kinds(d, el(d, base.NIL_HANDLE, "style")), bit_set[Inserted_Kind]{.Style})
	testing.expect_value(t, inserted_kinds(d, el(d, base.NIL_HANDLE, "source")), bit_set[Inserted_Kind]{.Media})
}
