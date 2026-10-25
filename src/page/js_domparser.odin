package page

// DOMParser (HTML §8.5.1) for JavaScript: native/js/runtime/dom_core.c (wjr_DOMParser_*), api/js_dom_tree.widl.

import "wb:dom"
import "wb:html"

// DOMParser's text/html: the whole markup parsed into a fragment that stands for a document (createHTMLDocument's
// kind), scripting disabled (a fragment's scripts never run) and without declarative shadow roots.
DOMParser_parseHTMLNode :: proc(c: ^Call, markup: string) -> (u64, Api_Error) {
	d := jd_doc(c)
	if d == nil { return 0, no_document(c) }
	f := dom.create_fragment(d)
	dom.get(d, f).as_document = true
	res := html.parse_into(d, f, transmute([]byte)markup, c.page.settings.dom.max_fragment_nodes, declarative_shadow = false)
	if !res.ok {
		dom.destroy_unpinned(d, f)
		return 0, fail(c, .Syntax, "the markup could not be parsed")
	}
	return u64(f), .None
}
