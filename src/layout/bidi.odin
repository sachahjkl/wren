package layout

import "core:strings"
import "core:unicode/utf8"
import "wb:style"

// Bidirectional text (UAX #9 through Text_Api.bidi; CSS Writing Modes 4 §2): the embedding level of every character of
// an inline formatting context, then, line by line, the visual order of its fragments (L2).
//
// The paragraph handed to the bidi algorithm is the text of the context's items in order, with U+FFFC for each atomic
// inline (a neutral, as the spec says) and the controls CSS maps `direction` + `unicode-bidi` of inline boxes to
// (embed: LRE / RLE ... PDF, isolate: LRI / RLI ... PDI, bidi-override: LRO / RLO ... PDF, isolate-override: both,
// plaintext: FSI ... PDI). The paragraph direction is the context root's `direction` (from its first strong character
// when its unicode-bidi is plaintext). A context with only left-to-right text in a left-to-right root is not analyzed.
//
// Segments never span two levels (inline.odin), so every text fragment is one directional run; a line is reordered by
// moving its text and atomic fragments (each with the gap after it), inline box edges stay where they are.

Bidi_Para :: struct {
	levels:   []u8,     // per byte of the paragraph text
	item_off: []i32,    // per item of the context (from its first): where its text starts in the paragraph
	item0:    i32,
	base_rtl: bool,
}

// Level of byte `pos` of item `item`'s text.
@(private)
bidi_level :: #force_inline proc(p: ^Bidi_Para, item: i32, pos: int) -> u8 {
	o := int(p.item_off[item - p.item0]) + pos
	return o < len(p.levels) ? p.levels[o] : (p.base_rtl ? 1 : 0)
}

// Right-to-left letters or bidi controls (U+0590..U+08FF, U+FB1D..U+FDFF, U+FE70..U+FEFF, U+10800..U+10FFF,
// U+1E800..U+1EFFF, RLM, ALM, the embedding / override / isolate controls).
@(private)
has_rtl :: proc(text: string) -> bool {
	for i := 0; i < len(text); i += 1 {
		b := text[i]
		if b < 0xD6 || b & 0xC0 == 0x80 { continue }
		r, _ := utf8.decode_rune_in_string(text[i:])
		switch {
		case r >= 0x0590 && r <= 0x08FF, r >= 0xFB1D && r <= 0xFDFF, r >= 0xFE70 && r <= 0xFEFF, r >= 0x10800 && r <= 0x10FFF,
		     r >= 0x1E800 && r <= 0x1EFFF, r == 0x200F, r == 0x061C, r >= 0x202A && r <= 0x202E, r >= 0x2066 && r <= 0x2069:
			return true
		}
	}
	return false
}

// Scripts whose words are not separated by spaces and need a dictionary to break (Thai, Lao, Myanmar, Khmer, Tai Tham).
@(private)
needs_dictionary :: proc(text: string) -> bool {
	for i := 0; i < len(text); i += 1 {
		b := text[i]
		if b != 0xE0 && b != 0xE1 && b != 0xEA { continue }
		r, _ := utf8.decode_rune_in_string(text[i:])
		switch {
		case r >= 0x0E00 && r <= 0x0EFF, r >= 0x1000 && r <= 0x109F, r >= 0x1780 && r <= 0x17FF, r >= 0x1A20 && r <= 0x1AAF,
		     r >= 0xAA60 && r <= 0xAA7F:
			return true
		}
	}
	return false
}

@(private)
open_controls :: proc(cs: ^style.Computed) -> string {
	rtl := cs.direction == .Rtl
	switch cs.unicode_bidi {
	case .Normal: return ""
	case .Embed: return rtl ? "\u202B" : "\u202A"
	case .Isolate: return rtl ? "\u2067" : "\u2066"
	case .Bidi_Override: return rtl ? "\u202E" : "\u202D"
	case .Isolate_Override: return rtl ? "\u2067\u202E" : "\u2066\u202D"
	case .Plaintext: return "\u2068"
	}
	return ""
}

@(private)
close_controls :: proc(cs: ^style.Computed) -> string {
	switch cs.unicode_bidi {
	case .Normal: return ""
	case .Embed, .Bidi_Override: return "\u202C"
	case .Isolate, .Plaintext: return "\u2069"
	case .Isolate_Override: return "\u202C\u2069"
	}
	return ""
}

// The levels of the context rooted at `bi` (temp allocator), or nil when it is all left to right.
@(private)
bidi_paragraph :: proc(c: ^Ctx, bi: i32) -> ^Bidi_Para {
	if c.text.bidi == nil { return nil }
	b := &c.l.boxes[bi]
	if b.cs == nil { return nil }
	root_rtl := b.cs.direction == .Rtl
	needed := root_rtl
	if !needed {
		for i in b.items[0] ..< b.items[1] {
			it := &c.l.inline_items[i]
			#partial switch it.kind {
			case .Text: if has_rtl(it.text) { needed = true }
			case .Open: if ib := &c.l.boxes[it.box]; ib.cs != nil && (ib.cs.direction == .Rtl || ib.cs.unicode_bidi == .Bidi_Override || ib.cs.unicode_bidi == .Isolate_Override) { needed = true }
			}
			if needed { break }
		}
	}
	if !needed { return nil }
	n := int(b.items[1] - b.items[0])
	p := new(Bidi_Para, context.temp_allocator)
	p.item0 = b.items[0]
	p.item_off = make([]i32, n, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	for i in b.items[0] ..< b.items[1] {
		it := &c.l.inline_items[i]
		#partial switch it.kind {
		case .Open:
			if ib := &c.l.boxes[it.box]; ib.cs != nil { strings.write_string(&sb, open_controls(ib.cs)) }
		case .Close:
			if ib := &c.l.boxes[it.box]; ib.cs != nil { strings.write_string(&sb, close_controls(ib.cs)) }
		}
		p.item_off[i - p.item0] = i32(strings.builder_len(sb))
		#partial switch it.kind {
		case .Text: strings.write_string(&sb, it.text)
		case .Atomic: strings.write_string(&sb, "\uFFFC")
		case .Break: strings.write_string(&sb, "\u2028")
		}
	}
	text := strings.to_string(sb)
	rtl := root_rtl
	if b.cs.unicode_bidi == .Plaintext { rtl = first_strong_is_rtl(text) }
	p.base_rtl = rtl
	p.levels = make([]u8, len(text), context.temp_allocator)
	c.text.bidi(c.text.user, text, rtl, p.levels)
	return p
}

@(private)
first_strong_is_rtl :: proc(text: string) -> bool {
	for r in text {
		switch {
		case r >= 0x0590 && r <= 0x08FF, r >= 0xFB1D && r <= 0xFDFF, r >= 0xFE70 && r <= 0xFEFF, r >= 0x10800 && r <= 0x10FFF, r >= 0x1E800 && r <= 0x1EFFF:
			return true
		case (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= 0xC0 && r <= 0x24F) || (r >= 0x370 && r <= 0x58F):
			return false
		}
	}
	return false
}

// UAX #9 L2 on the text and atomic fragments of the line being finished: each takes its slot (its width plus the gap to
// the next one in logical order) in visual order, from where the first slot started. Inline box edges stay.
@(private)
bidi_reorder_line :: proc(lb: ^Line_Builder) {
	c := lb.c
	idx := make([dynamic]int, 0, len(lb.frags), context.temp_allocator)
	for f, i in lb.frags {
		if f.kind == .Text || f.kind == .Atomic { append(&idx, i) }
	}
	n := len(idx)
	if n < 2 { return }
	levels := make([]u8, n, context.temp_allocator)
	slot := make([]f32, n, context.temp_allocator)
	for k in 0 ..< n {
		f := &lb.frags[idx[k]]
		switch f.kind {
		case .Text: levels[k] = f.level
		case .Atomic:
			levels[k] = lb.bidi != nil ? bidi_level(lb.bidi, f.item, 0) : 0
			f.level = levels[k]
		case .Box, .Ellipsis:
		}
		lx := f.x - (f.kind == .Atomic ? c.l.boxes[f.box].margin[3] : 0)
		end := f.x + f.w + (f.kind == .Atomic ? c.l.boxes[f.box].margin[1] : 0)
		if k + 1 < n {
			nf := &lb.frags[idx[k + 1]]
			end = max(end, nf.x - (nf.kind == .Atomic ? c.l.boxes[nf.box].margin[3] : 0))
		}
		slot[k] = end - lx
	}
	// L2: reverse every maximal run at or above each level, from the highest down to the lowest odd one
	order := make([]int, n, context.temp_allocator)
	for k in 0 ..< n { order[k] = k }
	hi, lo := u8(0), u8(255)
	for l in levels {
		hi = max(hi, l)
		if l & 1 == 1 { lo = min(lo, l) }
	}
	if lo == 255 { return }
	for lvl := int(hi); lvl >= int(lo); lvl -= 1 {
		i := 0
		for i < n {
			if int(levels[order[i]]) < lvl { i += 1; continue }
			j := i
			for j < n && int(levels[order[j]]) >= lvl { j += 1 }
			for a, z := i, j - 1; a < z; a, z = a + 1, z - 1 { order[a], order[z] = order[z], order[a] }
			i = j
		}
	}
	f0 := &lb.frags[idx[0]]
	x := f0.x - (f0.kind == .Atomic ? c.l.boxes[f0.box].margin[3] : 0)
	for k in 0 ..< n {
		src := order[k]
		f := &lb.frags[idx[src]]
		ml := f.kind == .Atomic ? c.l.boxes[f.box].margin[3] : 0
		dx := x + ml - f.x
		f.x += dx
		if f.kind == .Atomic { c.l.boxes[f.box].pos.x += dx }
		x += slot[src]
	}
}
