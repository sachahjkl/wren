package browser

import "core:testing"
import "wb:dom"
import "wb:page"
import "wb:style"

// A held frame is painted only while its records are those of the page: a pass of the old page's styles, with no change of the document, empties their arena.
@(test)
a_held_frame_goes_with_a_pass_of_its_pages_styles :: proc(t: ^testing.T) {
	doc := dom.Document{mutations = 3}
	styled := style.Styled{serial = 7}
	old_page := page.Page{doc = &doc, styled = &styled}
	h := Paint_Hold{active = true, page = &old_page}
	h.layout.valid, h.layout.mutations, h.layout.serial = true, 3, 7
	testing.expect(t, hold_exact(&h), "nothing changed: the frame stands")
	styled.serial = 8
	testing.expect(t, !hold_exact(&h), "the page's styles were computed again")
	styled.serial = 7
	doc.mutations = 4
	testing.expect(t, !hold_exact(&h), "the document changed")
}
