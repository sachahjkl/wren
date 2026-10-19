package style

import "wb:base"
import "wb:css"
import "wb:dom"

// ::selection (CSS Pseudo 4 §3.1): the colors a selection is painted with. Highlight pseudo-elements inherit from the
// parent element's highlight, so the nearest element (at or above `el`) whose ::selection sets a color decides it;
// `has_*` false: the user agent's colors apply.
selection_colors :: proc(s: ^Styled, d: ^dom.Document, el: base.Handle) -> (fg: css.Color, has_fg: bool, bg: css.Color, has_bg: bool) {
	for cur := el; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if n.kind == .Element {
			if c := style_of(s, cur); c != nil && c.selection != nil {
				sel := c.selection
				if !has_fg && !ps_has(sel.inherits, .Color) { fg, has_fg = sel.color, true }
				if !has_bg && sel.background_color.a > 0 { bg, has_bg = sel.background_color, true }
				if has_fg && has_bg { return }
			}
		}
		cur = n.parent
	}
	return
}
