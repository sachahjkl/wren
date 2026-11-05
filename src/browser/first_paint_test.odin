package browser

import "core:testing"
import "wb:dom"
import "wb:page"
import "wb:style"

// A held frame goes with a change of the document (its items read the document's text). A pass of the old page's styles leaves it
// on screen: the layout reads its own pass (style.styled_read_begin; src\tools\e2e\held_styles.odin).
@(test)
a_held_frame_goes_with_a_change_of_its_document :: proc(t: ^testing.T) {
	doc := dom.Document{mutations = 3}
	styled := style.Styled{serial = 7}
	old_page := page.Page{doc = &doc, styled = &styled}
	h := Paint_Hold{active = true, page = &old_page}
	h.layout.valid, h.layout.mutations, h.layout.serial = true, 3, 7
	testing.expect(t, hold_exact(&h), "nothing changed: the frame stands")
	styled.serial = 8
	testing.expect(t, hold_exact(&h), "the page's styles were computed again")
	doc.mutations = 4
	testing.expect(t, !hold_exact(&h), "the document changed")
}
