package style

import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"

// Positions counted directly in small families equal those of the per-parent index, at every size around the limit,
// with text and comments between the elements and two element types.
@(test)
sibling_info_direct_matches_index :: proc(t: ^testing.T) {
	for size in ([]int{1, 2, 31, 32, 33, 34, 65, 100}) {
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, "<div id=p>")
		for i in 0 ..< size {
			strings.write_string(&sb, i % 3 == 0 ? "<b>x</b> " : "<i></i><!--c-->")
		}
		strings.write_string(&sb, "</div>")
		doc := dom.document_create(nil)
		defer dom.document_destroy(doc)
		html.parse_into(doc, doc.root, transmute([]byte)strings.to_string(sb), 2_000_000)
		parent := dom.find_by_id(doc, "p")
		direct, indexed: Match_Ctx
		match_ctx_init(&direct, doc, {}, context.temp_allocator)
		match_ctx_init(&indexed, doc, {}, context.temp_allocator)
		fill_siblings(&indexed, parent)
		for ch := dom.get(doc, parent).first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next {
			if dom.get(doc, ch).kind != .Element { continue }
			a, b := sibling_info(&direct, ch), sibling_info(&indexed, ch)
			testing.expectf(t, a == b, "family of %d: %v, indexed %v", size, a, b)
		}
	}
}
