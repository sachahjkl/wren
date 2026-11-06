package layout

// Text decoration: each box whose `text-decoration-line` is not none is a decorating box, and draws its own lines over the text inside it (CSS Text Decoration 3 §2). An item
// knows the nearest one (Display_Item.deco_box), and each knows the next one out (Box.deco_up): that list is what paints an item, read when painted, so the paint-only values
// of a box are always the ones it has now.

// The decorating boxes of `it`, the outermost first.
item_deco_boxes :: proc(l: ^Layout, it: ^Display_Item, allocator := context.temp_allocator) -> []i32 {
	n := 0
	for b := it.deco_box; b != NONE; b = l.boxes[b].deco_up { n += 1 }
	out := make([]i32, n, allocator)
	for b := it.deco_box; b != NONE; b = l.boxes[b].deco_up {
		n -= 1
		out[n] = b
	}
	return out
}

// What a recording of `it` read of the boxes that decorate it: it is made again when this changes.
item_deco_key :: proc(l: ^Layout, it: ^Display_Item) -> (h: u64) {
	h = 0xcbf29ce484222325
	mix :: #force_inline proc(h: ^u64, v: u64) { h^ = (h^ ~ v) * 0x100000001b3 }
	for b := it.deco_box; b != NONE; b = l.boxes[b].deco_up {
		cs := l.boxes[b].cs
		if cs == nil { continue }
		c := cs.text_decoration_color
		mix(&h, u64(transmute(u32)c.r) | u64(transmute(u32)c.g) << 32)
		mix(&h, u64(transmute(u32)c.b) | u64(transmute(u32)c.a) << 32)
		mix(&h, u64(transmute(u8)cs.text_decoration) | u64(cs.text_decoration_style) << 8 | u64(cs.text_decoration_thickness.kind) << 16 | u64(cs.text_underline_offset.kind) << 24 |
			u64(transmute(u32)cs.text_decoration_thickness.v) << 32)
		mix(&h, u64(transmute(u32)cs.text_underline_offset.v) | u64(cs.text_underline_position.place) << 32 | u64(cs.text_underline_position.side) << 40)
		for side in cs.text_decoration_inset { mix(&h, u64(side.kind) | u64(transmute(u32)side.v) << 32) }
	}
	return
}

// The line of the formatting context of `it` it is on, and its fragment (`ok` false: none, the item is not of one).
item_line :: proc(l: ^Layout, it: ^Display_Item) -> (line: i32, frag: i32, ok: bool) {
	root := it.box
	if root < 0 { return }
	if b := &l.boxes[root]; .Ifc not_in b.flags { root = b.ifc_root }
	if root < 0 || .Ifc not_in l.boxes[root].flags { return }
	r := &l.boxes[root]
	for li in r.lines[0] ..< r.lines[1] {
		ln := &l.lines[li]
		for fi in ln.frags[0] ..< ln.frags[1] {
			f := &l.frags[fi]
			if f.kind == .Text && f.item == it.item && raw_data(f.text) == raw_data(it.text) { return li, fi, true }
		}
	}
	return
}

// Where the baseline of decorating box `box` is on the line of `it` (in the coordinate of the item's baseline): an underline stays with the box it belongs to, whatever
// vertical-align does to the text inside. A block's is the line's own.
deco_baseline :: proc(l: ^Layout, it: ^Display_Item, box: i32) -> f32 {
	if it.box == box { return it.baseline }
	moved := false
	for b := it.box; b != NONE && b != box && l.boxes[b].kind == .Inline; b = l.boxes[b].parent {
		if l.boxes[b].cs.vertical_align.kind != .Baseline { moved = true; break }
	}
	if !moved { return it.baseline }
	li, _, ok := item_line(l, it)
	if !ok { return it.baseline }
	ln := &l.lines[li]
	vertical := .Vertical in it.flags
	if l.boxes[box].kind == .Inline {
		for fi in ln.frags[0] ..< ln.frags[1] {
			if f := &l.frags[fi]; f.kind == .Box && f.box == box { return (vertical ? l.boxes[box].abs.x : l.boxes[box].abs.y) + f.baseline }
		}
		return it.baseline
	}
	if vertical { return it.baseline }
	root := l.boxes[it.box].ifc_root
	return root >= 0 ? l.boxes[root].abs.y + ln.y + ln.baseline : it.baseline
}

// The font that places the lines of `box` over `it`: its own, or for a block the one of the line's root inline box.
deco_font :: proc(l: ^Layout, it: ^Display_Item, box: i32) -> ^Font_Info {
	b := &l.boxes[box]
	fi := b.fi
	if b.kind != .Inline {
		root := it.box
		if .Ifc not_in l.boxes[root].flags { root = l.boxes[root].ifc_root }
		if root >= 0 { fi = l.boxes[root].fi }
	}
	return fi >= 0 && int(fi) < len(l.fonts) ? &l.fonts[fi] : item_font(l, it)
}

// Whether a fragment of `box`'s text comes before or after this item's, and how long all of them are: where `text-decoration-inset` applies.
deco_fragments :: proc(l: ^Layout, it: ^Display_Item, box: i32) -> (first, last: bool, length: f32) {
	li, frag, ok := item_line(l, it)
	if !ok { return true, true, it.rect.max.x - it.rect.min.x }
	root := it.box
	if .Ifc not_in l.boxes[root].flags { root = l.boxes[root].ifc_root }
	r := &l.boxes[root]
	inside :: proc(l: ^Layout, f: ^Frag, box, root: i32) -> bool {
		if box == root || l.boxes[box].kind != .Inline { return true }
		for b := f.box; b != NONE && b != root; b = l.boxes[b].parent { if b == box { return true } }
		return false
	}
	first_frag, last_frag: i32 = NONE, NONE
	for i in r.lines[0] ..< r.lines[1] {
		ln := &l.lines[i]
		for fi in ln.frags[0] ..< ln.frags[1] {
			f := &l.frags[fi]
			if f.kind != .Text || !inside(l, f, box, root) { continue }
			if first_frag == NONE { first_frag = fi }
			last_frag = fi
			length += .Vertical in f.flags ? f.h : f.w
		}
	}
	_ = li
	return frag == first_frag, frag == last_frag, length
}
