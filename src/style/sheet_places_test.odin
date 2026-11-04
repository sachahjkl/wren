package style

import "core:testing"
import "wb:base"
import "wb:dom"

// A rebuild places the author sheets by their owners in tree order, and stops looking at the last owner: the sheet latest in
// the document wins, whichever was registered first, and a sheet whose owner left the document comes before the others.
@(test)
sheets_follow_their_owners_in_tree_order :: proc(t: ^testing.T) {
	f := fixture_load(`<!doctype html><style id=one>p { color: rgb(1, 0, 0) }</style>
		<p id=p>x</p><style id=two>p { color: rgb(0, 0, 255) }</style><div></div>`)
	defer fixture_unload(f)
	testing.expect(t, style_of(f.st, dom.find_by_id(f.doc, "p")).color == {0, 0, 1, 1}, "the later sheet wins")
	one, two: ^Sheet
	for s in f.eng.sheets {
		if s.origin != .Author { continue }
		if s.owner == dom.find_by_id(f.doc, "one") { one = s }
		if s.owner == dom.find_by_id(f.doc, "two") { two = s }
	}
	testing.expect(t, one != nil && two != nil, "both sheets found")
	testing.expect(t, 0 < one.order && one.order < two.order, "their places are their owners'")

	// reversed by hand, a rebuild puts them back
	one.order, two.order = two.order, one.order
	engine_rebuild(f.eng, f.doc)
	testing.expect(t, one.order < two.order, "the rebuild orders them again")

	// an owner gone from the document: first of all
	one.owner = base.NIL_HANDLE
	engine_rebuild(f.eng, f.doc)
	testing.expect_value(t, one.order, 0)
	testing.expect(t, two.order > 0, "the other keeps its place")
}
