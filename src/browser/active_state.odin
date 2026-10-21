package browser

import "wb:base"
import "wb:page"

// :active (Selectors 4): the element the left button went down on, and its ancestors, until the button comes up
// (route_page_input). The restyle is the partial one of the other input states (style.restyle_state).
page_set_active :: proc(p: ^page.Page, el: base.Handle) {
	if p == nil || p.style_state.active == el { return }
	st := p.style_state
	st.active = el
	page.set_style_state(p, st)
}
