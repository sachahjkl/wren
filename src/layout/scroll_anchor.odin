package layout

// CSS Scroll Anchoring, for the document's scroller in its block axis: what the reader looks at stays where it is when
// content above it changes size (an image that loads, a banner inserted or removed, a script's mutation). Before a pass the
// embedder selects the anchor in the layout it has (scroll_anchor_select), after it moves the scroll offset by as much as the
// anchor moved (scroll_anchor_shift). The anchor is chosen as the specification's selection algorithm does, among the boxes
// the document scrolls: the first child, in tree order, that is visible in the viewport; fully visible it is the anchor,
// partly visible its own children are looked at first. Not chosen: boxes absolutely positioned or fixed, those in another
// coordinate space (a scroll container's content, a transform), with overflow-anchor: none (and what is inside them),
// anonymous boxes (their children are looked at); none at the top of the document (a page still loading grows downwards),
// none when the root element has overflow-anchor: none. Not there: the suppression triggers, scroll containers' own
// anchors, the inline axis.

import "wb:base"
import "wb:style"

Scroll_Anchor :: struct {
	node: base.Handle,   // NIL: no anchor
	top:  f32,           // its border box's top, document coordinates (device px)
}

// The anchor of the document scrolled to `scroll_y` in a viewport `view_h` high (device px at `scale`), from the boxes of `l`
// (the layout before the pass) and the styles of the pass to come (`styled`: the boxes' own may be gone with the styles they
// were made of). None when `l` was laid out at another scale: its device pixels are not those of the pass (the window went to
// a monitor of another scale, the page was zoomed), whose offset the embedder keeps itself.
scroll_anchor_select :: proc(l: ^Layout, styled: ^style.Styled, scale, scroll_y, view_h: f32) -> Scroll_Anchor {
	if !l.valid || len(l.boxes) == 0 || scroll_y <= 0 || l.scale != scale { return {} }
	if root := l.boxes[0].first; root != NONE && !anchor_candidate(l, &l.boxes[root], styled) { return {} }   // (the scroller's own overflow-anchor)
	top, bottom := scroll_y, scroll_y + view_h
	found := NONE
	parent := i32(0)
	descend: for {
		partly := NONE
		for c := l.boxes[parent].first; c != NONE; c = l.boxes[c].next {
			b := &l.boxes[c]
			if !anchor_candidate(l, b, styled) { continue }
			r := border_rect(b)
			if r.max.y <= top || r.min.y >= bottom { continue }
			if r.min.y >= top && r.max.y <= bottom && b.node != base.NIL_HANDLE {
				found = c
				break descend
			}
			partly = c
			break
		}
		if partly == NONE { break }
		if l.boxes[partly].node != base.NIL_HANDLE { found = partly }
		parent = partly
	}
	if found == NONE { return {} }
	return Scroll_Anchor{node = l.boxes[found].node, top = border_rect(&l.boxes[found]).min.y}
}

// How far the anchor moved in `l`, laid out again since it was selected (device px): what the scroll offset follows. 0 when it
// is no longer a box the document scrolls.
scroll_anchor_shift :: proc(l: ^Layout, a: Scroll_Anchor) -> f32 {
	if a.node == base.NIL_HANDLE || !l.valid { return 0 }
	bi := box_index(l, a.node)
	if bi == NONE || !anchor_candidate(l, &l.boxes[bi], nil) { return 0 }
	return border_rect(&l.boxes[bi]).min.y - a.top
}

// `styled`: the styles to read overflow-anchor in (nil: the box's own).
@(private = "file")
anchor_candidate :: proc(l: ^Layout, b: ^Box, styled: ^style.Styled) -> bool {
	if .Abs in b.flags || b.space < 0 || int(b.space) >= len(l.spaces) || l.spaces[b.space].kind != .Document { return false }
	cs := b.cs
	if styled != nil { cs = b.node != base.NIL_HANDLE ? style.style_of(styled, b.node) : nil }
	return cs == nil || cs.overflow_anchor != .None
}
