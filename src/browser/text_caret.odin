package browser

import "toolkit:font"
import lay "wb:layout"

// Caret positions and hit testing inside text, for selection and editing (the interaction code). A Text display item
// is one fragment of a line: one directional run (its bidi level), shaped by the toolkit exactly as it is painted
// (same font, spacing and justification). Positions go through the shaped clusters: a ligature or a grapheme of several
// characters is one cluster, shared out evenly between its characters; in a right-to-left fragment the caret before
// the first character is at the right edge.
//
// Byte indices are into `it.text`; `text_item_offset` gives where that text starts in the text of its inline item
// (`l.inline_items[it.item].text`: the text node's content, after text-transform), so a DOM offset is
// item offset + index.

// Byte offset of a Text item's text in its inline item's text (0 when it has no inline item: an ellipsis).
text_item_offset :: proc(l: ^Layout, it: ^lay.Display_Item) -> int {
	if it.kind != .Text || it.item < 0 || int(it.item) >= len(l.inline_items) { return 0 }
	src := l.inline_items[it.item].text
	a, b := uintptr(raw_data(it.text)), uintptr(raw_data(src))
	if a < b || a > b + uintptr(len(src)) { return 0 }
	return int(a - b)
}

// The text of a Text item shaped as painted (temp allocator).
text_item_shaped :: proc(l: ^Layout, it: ^lay.Display_Item) -> (sh: font.Shaped, ok: bool) {
	fi := lay.item_font(l, it)
	if it.kind != .Text || fi == nil || it.cs == nil || page_render.fonts.state == nil { return {}, false }
	opts := text_shape_options(l, it.cs, it.level, it.extra)
	return font.shape(page_render.fonts.state, font.Font_Id(fi.font), fi.size, it.text, opts, context.temp_allocator), true
}

// Layout x of the caret before byte `index` of `it.text` (`len(it.text)`: after its last character, logically).
text_item_caret_x :: proc(l: ^Layout, it: ^lay.Display_Item, index: int) -> f32 {
	sh, ok := text_item_shaped(l, it)
	if !ok { return it.rect.min.x }
	return it.rect.min.x + font.caret_x(sh, it.text, index)
}

// Byte index of `it.text` whose caret position is nearest to layout x `x`.
text_item_hit :: proc(l: ^Layout, it: ^lay.Display_Item, x: f32) -> int {
	sh, ok := text_item_shaped(l, it)
	if !ok { return 0 }
	return font.hit_index(sh, it.text, x - it.rect.min.x)
}

// The clusters of a Text item (logical order; x relative to the layout), for drawing a selection run by run.
text_item_clusters :: proc(l: ^Layout, it: ^lay.Display_Item, allocator := context.temp_allocator) -> []font.Cluster {
	sh, ok := text_item_shaped(l, it)
	if !ok { return nil }
	out := make([]font.Cluster, len(sh.clusters), allocator)
	for c, i in sh.clusters {
		out[i] = c
		out[i].x0 += it.rect.min.x
		out[i].x1 += it.rect.min.x
	}
	return out
}
