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

// What draws the text decoration of ::selection over `el`: the nearest element whose rule sets one, as for its colors. nil: none.
selection_decoration :: proc(s: ^Styled, d: ^dom.Document, el: base.Handle) -> ^Computed {
	for cur := el; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if n.kind == .Element {
			if c := style_of(s, cur); c != nil && c.selection != nil && c.selection.text_decoration != {} { return c.selection }
		}
		cur = n.parent
	}
	return nil
}

// The same for ::highlight(name).
highlight_decoration :: proc(s: ^Styled, d: ^dom.Document, el: base.Handle, name: string) -> ^Computed {
	for cur := el; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if n.kind == .Element {
			if c := style_of(s, cur); c != nil {
				for hs in c.highlights { if hs.name == name && hs.style.text_decoration != {} { return hs.style } }
			}
		}
		cur = n.parent
	}
	return nil
}

// The style of ::highlight(name) rules an element matched (Computed.highlights).
Highlight_Style :: struct {
	name:  string,
	style: ^Computed,
}

// ::highlight(name) (CSS Custom Highlight API §3): as ::selection, for the highlight of that name. A highlight has no colors of its own: `has_*` false, it paints nothing of them.
highlight_colors :: proc(s: ^Styled, d: ^dom.Document, el: base.Handle, name: string) -> (fg: css.Color, has_fg: bool, bg: css.Color, has_bg: bool) {
	for cur := el; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if n.kind == .Element {
			if c := style_of(s, cur); c != nil {
				for hs in c.highlights {
					if hs.name != name { continue }
					if !has_fg && !ps_has(hs.style.inherits, .Color) { fg, has_fg = hs.style.color, true }
					if !has_bg && hs.style.background_color.a > 0 { bg, has_bg = hs.style.background_color, true }
				}
				if has_fg && has_bg { return }
			}
		}
		cur = n.parent
	}
	return
}
