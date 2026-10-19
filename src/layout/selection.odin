package layout

import "core:slice"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "wb:base"
import "wb:dom"
import "wb:style"

// Text selection queries: positions in the DOM (a text node and a byte offset, or an element and a child index, as
// DOM Range boundary points), their document order, the point of the page they are under (through the display list
// and measured glyphs, transforms and scroll offsets included), what of each display item a range covers (for the
// painter), word and paragraph boundaries, and the text of a range serialized the way innerText is (CSS white space
// processing and text-transform applied, line breaks between blocks, tabs between table cells, hidden content left
// out) with a map back to the DOM (for find in page).
//
// Text offsets are UTF-8 byte offsets into dom.Node.text, always on a character boundary. The Web API counts UTF-16
// code units: the bindings convert (see utf16_offset / utf8_offset).

Text_Pos :: struct {
	node:   base.Handle,   // a text node (offset: byte in its text) or an element / the document (offset: child index)
	offset: int,
}

////////////////////////////////
// Document order

@(private = "file")
child_index :: proc(d: ^dom.Document, h: base.Handle) -> int {
	n := dom.get(d, h)
	if n == nil || n.parent == base.NIL_HANDLE { return 0 }
	i := 0
	for c := n.prev; c != base.NIL_HANDLE; c = dom.get(d, c).prev { i += 1 }
	return i
}

child_count :: proc(d: ^dom.Document, h: base.Handle) -> int {
	n := dom.get(d, h)
	if n == nil { return 0 }
	i := 0
	for c := n.first_child; c != base.NIL_HANDLE; c = dom.get(d, c).next { i += 1 }
	return i
}

// Length of a node as a boundary container: bytes of a text node, children of an element.
node_length :: proc(d: ^dom.Document, h: base.Handle) -> int {
	n := dom.get(d, h)
	if n == nil { return 0 }
	if n.kind == .Text || n.kind == .Comment { return len(n.text) }
	return child_count(d, h)
}

// Is `h` in the tree of the document (not detached, not destroyed)?
in_document :: proc(d: ^dom.Document, h: base.Handle) -> bool {
	for cur := h; cur != base.NIL_HANDLE; {
		if cur == d.root { return true }
		n := dom.get(d, cur)
		if n == nil { return false }
		cur = n.parent
	}
	return false
}

// Tree order of two nodes of one tree: -1 a before b, 0 same, 1 after (ancestors come before their descendants).
node_compare :: proc(d: ^dom.Document, a, b: base.Handle) -> int {
	if a == b { return 0 }
	chain :: proc(d: ^dom.Document, h: base.Handle) -> [dynamic]base.Handle {
		out := make([dynamic]base.Handle, 0, 32, context.temp_allocator)
		for cur := h; cur != base.NIL_HANDLE; {
			append(&out, cur)
			n := dom.get(d, cur)
			if n == nil { break }
			cur = n.parent
		}
		slice.reverse(out[:])
		return out
	}
	ca, cb := chain(d, a), chain(d, b)
	i := 0
	for i < len(ca) && i < len(cb) && ca[i] == cb[i] { i += 1 }
	if i == len(ca) { return -1 }   // a is an ancestor of b
	if i == len(cb) { return 1 }
	if i == 0 { return 0 }          // different trees: no order
	// siblings under the common ancestor
	for c := ca[i]; c != base.NIL_HANDLE; c = dom.get(d, c).next { if c == cb[i] { return -1 } }
	return 1
}

// Boundary point order (DOM §5.2): -1 a before b, 0 equal, 1 after.
pos_compare :: proc(d: ^dom.Document, a, b: Text_Pos) -> int {
	if a.node == b.node { return a.offset < b.offset ? -1 : (a.offset > b.offset ? 1 : 0) }
	// b inside a's node: compare a's offset with the child of a.node that contains b
	in_node :: proc(d: ^dom.Document, outer: Text_Pos, inner: base.Handle) -> (int, bool) {
		child := inner
		for {
			n := dom.get(d, child)
			if n == nil { return 0, false }
			if n.parent == outer.node { break }
			if n.parent == base.NIL_HANDLE { return 0, false }
			child = n.parent
		}
		return child_index(d, child) < outer.offset ? 1 : -1, true   // 1: outer is after inner
	}
	if r, ok := in_node(d, a, b.node); ok { return r }
	if r, ok := in_node(d, b, a.node); ok { return -r }
	return node_compare(d, a.node, b.node)
}

// Before / after a node, in its parent.
pos_before :: proc(d: ^dom.Document, h: base.Handle) -> Text_Pos {
	n := dom.get(d, h)
	if n == nil { return {} }
	return {n.parent, child_index(d, h)}
}

pos_after :: proc(d: ^dom.Document, h: base.Handle) -> Text_Pos {
	p := pos_before(d, h)
	p.offset += 1
	return p
}

// Is node `h` (all of it) inside [start, end]?
node_in_range :: proc(d: ^dom.Document, h: base.Handle, start, end: Text_Pos) -> bool {
	return pos_compare(d, pos_before(d, h), start) >= 0 && pos_compare(d, pos_after(d, h), end) <= 0
}

////////////////////////////////
// UTF-16 offsets (what the Web API counts)

utf16_offset :: proc(text: string, byte_offset: int) -> int {
	n := 0
	for r, i in text {
		if i >= byte_offset { break }
		n += r >= 0x10000 ? 2 : 1
	}
	return n
}

utf8_offset :: proc(text: string, u16_offset: int) -> int {
	n := 0
	for r, i in text {
		if n >= u16_offset { return i }
		n += r >= 0x10000 ? 2 : 1
	}
	return len(text)
}

////////////////////////////////
// Selectability

// user-select of an element, resolved through its ancestors (CSS UI 4 §6.2: `auto` is `none` inside `none`, `all`
// makes the element one unit).
@(private)
Select_Mode :: enum u8 { Text, None, All }

@(private)
select_mode :: proc(d: ^dom.Document, st: ^style.Styled, el: base.Handle, cache: ^map[base.Handle]Select_Mode) -> Select_Mode {
	if cache != nil { if m, ok := cache[el]; ok { return m } }
	mode := Select_Mode.Text
	for cur := el; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if n.kind == .Element {
			if cs := style.style_of(st, cur); cs != nil {
				#partial switch cs.user_select {
				case .None: mode = .None
				case .All: mode = .All
				case .Text: mode = .Text
				case: cur = n.parent; continue
				}
				break
			}
		}
		cur = n.parent
	}
	if cache != nil { cache[el] = mode }
	return mode
}

// The outermost `user-select: all` element at or above `el` (NIL: none).
select_all_root :: proc(d: ^dom.Document, st: ^style.Styled, el: base.Handle) -> base.Handle {
	found := base.NIL_HANDLE
	for cur := el; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if n.kind == .Element {
			if cs := style.style_of(st, cur); cs != nil {
				if cs.user_select == .All { found = cur } else if cs.user_select == .None || cs.user_select == .Text { break }
			}
		}
		cur = n.parent
	}
	return found
}

////////////////////////////////
// Display items and their text

// The DOM text an item shows: the text node, and the byte range of it. ok = false for generated text, markers, items of
// a layout that no longer matches the document (its strings may be gone: lay out first).
item_source :: proc(l: ^Layout, d: ^dom.Document, idx: int) -> (node: base.Handle, lo, hi: int, ok: bool) {
	if idx < 0 || idx >= len(l.items) || l.mutations != d.mutations { return }
	it := &l.items[idx]
	if it.kind != .Text || it.item < 0 || int(it.item) >= len(l.inline_items) { return }
	ii := &l.inline_items[it.item]
	if ii.source == base.NIL_HANDLE || ii.src != .Element { return }
	n := dom.get(d, ii.source)
	if n == nil || n.kind != .Text { return }
	base_off := int(uintptr(raw_data(it.text)) - uintptr(raw_data(ii.text)))
	if base_off < 0 || base_off + len(it.text) > len(ii.text) { return }
	lo = item_to_source(ii.text, n.text, base_off)
	hi = item_to_source(ii.text, n.text, base_off + len(it.text))
	return ii.source, lo, hi, true
}

// A byte offset in the text layout shows (text-transform may have changed byte lengths, never the rune count) to
// the same place in the DOM text.
@(private)
item_to_source :: proc(shown, source: string, off: int) -> int {
	if raw_data(shown) == raw_data(source) && len(shown) == len(source) { return clamp(off, 0, len(source)) }
	runes := utf8.rune_count_in_string(shown[:clamp(off, 0, len(shown))])
	i := 0
	for _, b in source {
		if i == runes { return b }
		i += 1
	}
	return len(source)
}

@(private)
source_to_item :: proc(shown, source: string, off: int) -> int {
	if raw_data(shown) == raw_data(source) && len(shown) == len(source) { return clamp(off, 0, len(shown)) }
	return item_to_source(source, shown, off)   // the same rune walk the other way
}

// Width of the first `n` bytes of a text item as the painter draws them (letter-spacing after every character,
// word-spacing and justification after every space).
item_prefix_width :: proc(l: ^Layout, it: ^Display_Item, n: int, api: Text_Api) -> f32 {
	fi := item_font(l, it)
	if fi == nil || it.cs == nil { return 0 }
	s := it.text[:clamp(n, 0, len(it.text))]
	w := api.width(api.user, fi.font, fi.size, s)
	ls := it.cs.letter_spacing * l.scale
	ws := it.cs.word_spacing * l.scale + it.extra
	if ls != 0 { w += ls * f32(utf8.rune_count_in_string(s)) }
	if ws != 0 { w += ws * f32(strings.count(s, " ")) }
	return w
}

// The character boundary of a text item nearest to `x` (relative to the item's left edge).
item_offset_at :: proc(l: ^Layout, it: ^Display_Item, x: f32, api: Text_Api) -> int {
	if x <= 0 || it.text == "" { return 0 }
	// boundaries, then a binary search on their (monotonic) widths
	bounds := make([dynamic]int, 0, len(it.text) + 1, context.temp_allocator)
	for _, i in it.text { append(&bounds, i) }
	append(&bounds, len(it.text))
	lo, hi := 0, len(bounds) - 1
	if x >= item_prefix_width(l, it, len(it.text), api) { return len(it.text) }
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if item_prefix_width(l, it, bounds[mid], api) <= x { lo = mid } else { hi = mid }
	}
	a := item_prefix_width(l, it, bounds[lo], api)
	b := item_prefix_width(l, it, bounds[hi], api)
	return x - a < b - x ? bounds[lo] : bounds[hi]
}

// The text position under (or nearest to) viewport point `p`: the nearest selectable text item, preferring those of
// the block the point is in (so the gutter of a column stays in that column), then the nearest character boundary in
// it. Items are found in their own space (scroll offsets, sticky shifts, transforms through their inverse).
position_at :: proc(l: ^Layout, d: ^dom.Document, st: ^style.Styled, p: Vec2, viewport: Vec2, doc_scroll: f32, api: Text_Api) -> (pos: Text_Pos, ok: bool) {
	if !l.valid || l.mutations != d.mutations || len(l.items) == 0 { return }
	v := view_make(l, viewport, doc_scroll, cull = false)
	h := hit_test(l, p, viewport, doc_scroll)
	scope := NONE
	if h.box != NONE {
		// the nearest block-level container of what was hit
		for b := h.box; b != NONE; b = l.boxes[b].parent {
			k := l.boxes[b].kind
			if k != .Inline && .Root not_in l.boxes[b].flags { scope = b; break }
		}
	}
	within :: proc(l: ^Layout, b, scope: i32) -> bool {
		for x := b; x != NONE; x = l.boxes[x].parent { if x == scope { return true } }
		return false
	}
	modes := make(map[base.Handle]Select_Mode, 64, context.temp_allocator)
	best, best_score := -1, max(f32)
	best_q: Vec2
	for i in 0 ..< len(l.items) {
		it := &l.items[i]
		if it.kind != .Text || it.item < 0 { continue }
		ii := &l.inline_items[it.item]
		if ii.source == base.NIL_HANDLE || ii.src != .Element { continue }
		q, qok := view_to_local(l, &v, it.space, p)
		if !qok { continue }
		r := it.rect
		dx := q.x < r.min.x ? r.min.x - q.x : (q.x > r.max.x ? q.x - r.max.x : 0)
		dy := q.y < r.min.y ? r.min.y - q.y : (q.y > r.max.y ? q.y - r.max.y : 0)
		score := dy * 64 + dx   // the line first, then along it
		if scope != NONE && !within(l, it.box, scope) { score += 1e7 }
		if score >= best_score { continue }
		if select_mode(d, st, ii.node, &modes) == .None { continue }
		best, best_score, best_q = i, score, q
	}
	if best < 0 { return }
	it := &l.items[best]
	node, _, _, sok := item_source(l, d, best)
	if !sok { return }
	ii := &l.inline_items[it.item]
	n := dom.get(d, node)
	off := item_offset_at(l, it, best_q.x - it.rect.min.x, api)
	base_off := int(uintptr(raw_data(it.text)) - uintptr(raw_data(ii.text)))
	src := item_to_source(ii.text, n.text, base_off + off)
	return Text_Pos{node, src}, true
}

// The byte range [a, b) of item `idx`'s text inside the range [start, end] (ok = false: none of it).
item_range :: proc(l: ^Layout, d: ^dom.Document, idx: int, start, end: Text_Pos) -> (a, b: int, ok: bool) {
	node, lo, hi, sok := item_source(l, d, idx)
	if !sok { return }
	if pos_compare(d, {node, hi}, start) <= 0 || pos_compare(d, {node, lo}, end) >= 0 { return }
	s, e := lo, hi
	if start.node == node { s = max(s, start.offset) } else if pos_compare(d, {node, lo}, start) < 0 { s = hi }
	if end.node == node { e = min(e, end.offset) } else if pos_compare(d, {node, hi}, end) > 0 { e = lo }
	if s >= e { return }
	it := &l.items[idx]
	ii := &l.inline_items[it.item]
	n := dom.get(d, node)
	base_off := int(uintptr(raw_data(it.text)) - uintptr(raw_data(ii.text)))
	a = source_to_item(ii.text, n.text, s) - base_off
	b = source_to_item(ii.text, n.text, e) - base_off
	a, b = clamp(a, 0, len(it.text)), clamp(b, 0, len(it.text))
	return a, b, a < b
}

// Display items of text node `node` that show [lo, hi) of it (indices into l.items), for scrolling a match into view.
items_of_text :: proc(l: ^Layout, d: ^dom.Document, node: base.Handle, lo, hi: int, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	for i in 0 ..< len(l.items) {
		n, a, b, ok := item_source(l, d, i)
		if ok && n == node && a < max(hi, lo + 1) && b > lo { append(&out, i) }
	}
	return out[:]
}

////////////////////////////////
// Rendered text of a range (innerText rules)

Flat_Run :: struct {
	out, out_len: int,     // bytes of the flat text
	node:         base.Handle,
	src, src_len: int,     // the DOM text they come from (src_len != out_len: collapsed white space, transformed text)
}

Flat_Text :: struct {
	text: string,
	runs: []Flat_Run,      // in output order (only text from the DOM; line breaks and tabs made up have none)
}

@(private = "file")
Flat_Builder :: struct {
	sb:       strings.Builder,
	runs:     [dynamic]Flat_Run,
	breaks:   int,          // required line breaks pending (HTML innerText "required line break count")
	space:    bool,         // a collapsible space is pending
	space_at: Flat_Run,     // where it came from
	started:  bool,         // something was written
	at_line_start: bool,
}

@(private = "file")
flush_breaks :: proc(fb: ^Flat_Builder) {
	if fb.breaks > 0 {
		if fb.started { for _ in 0 ..< fb.breaks { strings.write_byte(&fb.sb, '\n') } }
		fb.breaks = 0
		fb.space = false
		fb.at_line_start = true
	}
}

@(private = "file")
emit :: proc(fb: ^Flat_Builder, text: string, node: base.Handle, src, src_len: int) {
	if text == "" { return }
	flush_breaks(fb)
	if fb.space {
		if !fb.at_line_start {
			r := fb.space_at
			r.out, r.out_len = strings.builder_len(fb.sb), 1
			strings.write_byte(&fb.sb, ' ')
			if r.node != base.NIL_HANDLE { append(&fb.runs, r) }
		}
		fb.space = false
	}
	out := strings.builder_len(fb.sb)
	strings.write_string(&fb.sb, text)
	if node != base.NIL_HANDLE { append(&fb.runs, Flat_Run{out = out, out_len = len(text), node = node, src = src, src_len = src_len}) }
	fb.started = true
	fb.at_line_start = text[len(text) - 1] == '\n'
}

@(private = "file")
require_breaks :: proc(fb: ^Flat_Builder, n: int) {
	fb.breaks = max(fb.breaks, n)
	fb.space = false
}

@(private = "file")
is_block_level :: proc(dsp: style.Display) -> bool {
	#partial switch dsp {
	case .Block, .Flow_Root, .List_Item, .Flex, .Grid, .Table, .Table_Caption, .Table_Row_Group, .Table_Header_Group, .Table_Footer_Group:
		return true
	}
	return false
}

@(private = "file")
transform_rune :: proc(r: rune, t: style.Text_Transform, prev_letter: ^bool) -> rune {
	out := r
	switch t {
	case .None:
	case .Uppercase: out = unicode.to_upper(r)
	case .Lowercase: out = unicode.to_lower(r)
	case .Capitalize: if !prev_letter^ && unicode.is_letter(r) { out = unicode.to_title(r) }
	}
	prev_letter^ = unicode.is_letter(r) || unicode.is_digit(r) || r == '\''
	return out
}

// Text of node `node`'s bytes [lo, hi) with the white space processing of `cs`.
@(private = "file")
emit_text :: proc(fb: ^Flat_Builder, text: string, node: base.Handle, lo, hi: int, cs: ^style.Computed) {
	ws := cs.white_space
	collapse_spaces := ws == .Normal || ws == .Nowrap || ws == .Pre_Line
	keep_newlines := ws != .Normal && ws != .Nowrap
	// bytes the loop below treats specially: collapsible white space, preserved line breaks
	collapsible :: proc(c: u8, keep_newlines: bool) -> bool { return c == ' ' || c == '\t' || c == '\f' || ((c == '\n' || c == '\r') && !keep_newlines) }
	prev_letter := false
	i := lo
	for i < hi {
		r, n := utf8.decode_rune_in_string(text[i:])
		if r == '\r' && i + 1 < hi && text[i + 1] == '\n' { i += 1; continue }
		if collapse_spaces && collapsible(text[i], keep_newlines) {
			j := i
			for j < hi && collapsible(text[j], keep_newlines) { j += 1 }
			if !fb.space && fb.breaks == 0 { fb.space = true; fb.space_at = Flat_Run{node = node, src = i, src_len = j - i} }
			i = j
			continue
		}
		if (r == '\n' || r == '\r') && keep_newlines {
			fb.space = false   // (pre-line) spaces before a line break go away
			emit(fb, "\n", node, i, n)
			fb.at_line_start = true
			// pre-line: spaces after it too
			if collapse_spaces { for i + n < hi && (text[i + n] == ' ' || text[i + n] == '\t') { n += 1 } }
			i += n
			continue
		}
		// a run of characters written as they are (up to the next byte handled above)
		j := i
		for j < hi {
			c := text[j]
			if j > i && ((collapse_spaces && collapsible(c, keep_newlines)) || ((c == '\n' || c == '\r') && keep_newlines)) { break }
			_, m := utf8.decode_rune_in_string(text[j:])
			j += m
		}
		if cs.text_transform == .None {
			emit(fb, text[i:j], node, i, j - i)
		} else {
			for k := i; k < j; {
				rr, m := utf8.decode_rune_in_string(text[k:])
				buf, bn := utf8.encode_rune(transform_rune(rr, cs.text_transform, &prev_letter))
				emit(fb, strings.clone(string(buf[:bn]), context.temp_allocator), node, k, m)
				k += m
			}
		}
		i = j
	}
}

// The rendered text of [start, end] (innerText rules). `root`: where to walk from (an ancestor of both ends; NIL = the
// document). Hidden content (display: none, visibility: hidden, unstyled nodes) is left out; generated content and
// images contribute nothing. Allocated in `allocator` (temp by default).
range_text :: proc(d: ^dom.Document, st: ^style.Styled, start, end: Text_Pos, root := base.NIL_HANDLE, allocator := context.temp_allocator) -> Flat_Text {
	fb := Flat_Builder{sb = strings.builder_make(allocator), runs = make([dynamic]Flat_Run, allocator), at_line_start = true}
	if pos_compare(d, start, end) >= 0 { return {} }
	top := root
	if top == base.NIL_HANDLE { top = d.root }
	Step :: struct { h: base.Handle, exit: bool }
	stack := make([dynamic]Step, 0, 64, context.temp_allocator)
	append(&stack, Step{h = top})
	for len(stack) > 0 {
		s := pop(&stack)
		n := dom.get(d, s.h)
		if n == nil { continue }
		if s.exit {
			cs := style.style_of(st, s.h)
			if cs == nil { continue }
			// past the end: nothing more can be inside
			#partial switch cs.display {
			case .Table_Cell:
				// a tab between cells of a row (not after the last one)
				for nx := n.next; nx != base.NIL_HANDLE; nx = dom.get(d, nx).next {
					if ncs := style.style_of(st, nx); ncs != nil && ncs.display == .Table_Cell { emit(&fb, "\t", base.NIL_HANDLE, 0, 0); break }
				}
			case .Table_Row: require_breaks(&fb, 1)
			case:
				if n.name == "p" { require_breaks(&fb, 2) } else if is_block_level(cs.display) { require_breaks(&fb, 1) }
			}
			continue
		}
		switch n.kind {
		case .Document:
		case .Comment: continue
		case .Text:
			if pos_compare(d, {s.h, len(n.text)}, start) <= 0 { continue }
			if pos_compare(d, {s.h, 0}, end) >= 0 { clear(&stack); continue }   // past the end of the range
			pcs := style.style_of(st, n.parent)
			if pcs == nil || pcs.visibility != .Visible { continue }
			lo := start.node == s.h ? start.offset : 0
			hi := end.node == s.h ? end.offset : len(n.text)
			emit_text(&fb, n.text, s.h, clamp(lo, 0, len(n.text)), clamp(hi, 0, len(n.text)), pcs)
			continue
		case .Element:
			cs := style.style_of(st, s.h)
			if cs == nil || cs.display == .None { continue }
			// entirely before the range: skip it (its end is before start)
			if pos_compare(d, pos_after(d, s.h), start) <= 0 && s.h != top { continue }
			if pos_compare(d, pos_before(d, s.h), end) >= 0 && s.h != top { clear(&stack); continue }
			if n.name == "br" {
				if pos_compare(d, pos_before(d, s.h), start) >= 0 { emit(&fb, "\n", base.NIL_HANDLE, 0, 0) }
				continue
			}
			if s.h != top {
				if n.name == "p" { require_breaks(&fb, 2) } else if is_block_level(cs.display) || cs.display == .Table_Row { require_breaks(&fb, 1) }
				append(&stack, Step{h = s.h, exit = true})
			}
		}
		for c := n.last_child; c != base.NIL_HANDLE; c = dom.get(d, c).prev { append(&stack, Step{h = c}) }
	}
	return Flat_Text{text = strings.to_string(fb.sb), runs = fb.runs[:]}
}

// Where an offset of the flat text is in the DOM (`end`: an offset that ends something maps to the end of the text
// before it rather than the start of the text after it).
flat_to_pos :: proc(ft: Flat_Text, off: int, end := false) -> (Text_Pos, bool) {
	if len(ft.runs) == 0 { return {}, false }
	// last run starting at or before off
	lo, hi := 0, len(ft.runs)
	for lo < hi {
		mid := (lo + hi) / 2
		if ft.runs[mid].out <= off { lo = mid + 1 } else { hi = mid }
	}
	i := max(lo - 1, 0)
	r := ft.runs[i]
	if end && off == r.out && i > 0 { r = ft.runs[i - 1]; return {r.node, r.src + r.src_len}, true }
	if off >= r.out + r.out_len { return {r.node, r.src + r.src_len}, true }
	if off <= r.out { return {r.node, r.src}, true }
	if r.out_len == r.src_len { return {r.node, r.src + (off - r.out)}, true }
	return {r.node, end ? r.src + r.src_len : r.src}, true
}

// Where a DOM position is in the flat text (-1: not in it).
pos_to_flat :: proc(d: ^dom.Document, ft: Flat_Text, p: Text_Pos) -> int {
	for r in ft.runs {
		if r.node == p.node && p.offset >= r.src && p.offset <= r.src + r.src_len {
			if r.out_len == r.src_len { return r.out + (p.offset - r.src) }
			return p.offset >= r.src + r.src_len ? r.out + r.out_len : r.out
		}
	}
	// a position between texts: the first run after it
	for r in ft.runs { if pos_compare(d, {r.node, r.src}, p) >= 0 { return r.out } }
	return len(ft.text)
}

////////////////////////////////
// Words and paragraphs

@(private = "file")
Word_Class :: enum u8 { Space, Word, Ideograph, Hiragana, Katakana, Punct, Newline }

// A reduced UAX #29: letters, digits, marks and connector punctuation make words (with ' . : between letters and
// , . between digits kept inside), each ideograph is a word of its own, runs of spaces and runs of other punctuation
// are units of their own.
@(private = "file")
word_class :: proc(r: rune) -> Word_Class {
	switch {
	case r == '\n' || r == '\r': return .Newline
	case r == ' ' || r == '\t' || r == 0xA0 || unicode.is_space(r): return .Space
	case r >= 0x3040 && r <= 0x309F: return .Hiragana   // runs of one kana script are words
	case (r >= 0x30A0 && r <= 0x30FF) || (r >= 0x31F0 && r <= 0x31FF) || (r >= 0xFF66 && r <= 0xFF9F): return .Katakana
	case (r >= 0x2E80 && r <= 0x2FFF) || (r >= 0x3400 && r <= 0x9FFF) || (r >= 0xF900 && r <= 0xFAFF) || (r >= 0x20000 && r <= 0x3FFFF): return .Ideograph
	case unicode.is_letter(r) || unicode.is_digit(r) || unicode.is_number(r) || r == '_' || unicode.is_nonspacing_mark(r) || unicode.is_spacing_mark(r) || unicode.is_enclosing_mark(r): return .Word
	}
	return .Punct
}

@(private = "file")
is_mid :: proc(r: rune) -> bool { return r == '\'' || r == 0x2019 || r == '.' || r == ':' || r == ',' || r == 0xB7 }

// The word around byte `off` of `text`: [a, b). `eat_space`: also the spaces after it (the Windows convention).
word_bounds :: proc(text: string, off: int, eat_space := false) -> (a, b: int) {
	if len(text) == 0 { return 0, 0 }
	o := clamp(off, 0, len(text))
	if o == len(text) && o > 0 { o -= 1; for o > 0 && text[o] & 0xC0 == 0x80 { o -= 1 } }
	for o > 0 && text[o] & 0xC0 == 0x80 { o -= 1 }
	r0, n0 := utf8.decode_rune_in_string(text[o:])
	cls := word_class(r0)
	if cls == .Ideograph || cls == .Newline { return o, o + n0 }
	a, b = o, o + n0
	// backwards
	for a > 0 {
		r, n := utf8.decode_last_rune_in_string(text[:a])
		c := word_class(r)
		if c == cls { a -= n; continue }
		if cls == .Word && is_mid(r) && a - n > 0 {
			r2, _ := utf8.decode_last_rune_in_string(text[:a - n])
			if word_class(r2) == .Word { a -= n; continue }
		}
		break
	}
	for b < len(text) {
		r, n := utf8.decode_rune_in_string(text[b:])
		c := word_class(r)
		if c == cls { b += n; continue }
		if cls == .Word && is_mid(r) && b + n < len(text) {
			r2, _ := utf8.decode_rune_in_string(text[b + n:])
			if word_class(r2) == .Word { b += n; continue }
		}
		break
	}
	if eat_space && cls == .Word {
		for b < len(text) {
			r, n := utf8.decode_rune_in_string(text[b:])
			if word_class(r) != .Space { break }
			b += n
		}
	}
	return a, b
}

// The block that contains `node` for words and paragraphs: the nearest element that is not inline-level.
block_of :: proc(d: ^dom.Document, st: ^style.Styled, node: base.Handle) -> base.Handle {
	for cur := node; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil { break }
		if n.kind == .Element {
			if cs := style.style_of(st, cur); cs != nil && (is_block_level(cs.display) || cs.display == .Table_Cell || cs.display == .Inline_Block || cs.display == .Table_Row) { return cur }
		}
		if n.kind == .Document { return cur }
		cur = n.parent
	}
	return d.root
}

// The word at `p` (a double click), across inline elements of its block.
word_range :: proc(d: ^dom.Document, st: ^style.Styled, p: Text_Pos, eat_space := false) -> (start, end: Text_Pos, ok: bool) {
	blk := block_of(d, st, p.node)
	ft := range_text(d, st, {blk, 0}, {blk, child_count(d, blk)}, blk)
	if ft.text == "" { return }
	o := pos_to_flat(d, ft, p)
	a, b := word_bounds(ft.text, o, eat_space)
	s, sok := flat_to_pos(ft, a)
	e, eok := flat_to_pos(ft, b, end = true)
	return s, e, sok && eok
}

// The paragraph at `p` (a triple click): all the text of its block.
paragraph_range :: proc(d: ^dom.Document, st: ^style.Styled, p: Text_Pos) -> (start, end: Text_Pos, ok: bool) {
	blk := block_of(d, st, p.node)
	ft := range_text(d, st, {blk, 0}, {blk, child_count(d, blk)}, blk)
	if len(ft.runs) == 0 { return }
	s, _ := flat_to_pos(ft, 0)
	e, _ := flat_to_pos(ft, len(ft.text), end = true)
	return s, e, true
}

////////////////////////////////
// HTML of a range (for the clipboard's HTML format)

@(private = "file")
escape_into :: proc(sb: ^strings.Builder, s: string, attr: bool) {
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c == '&': strings.write_string(sb, "&amp;")
		case c == '<': strings.write_string(sb, "&lt;")
		case c == '>': strings.write_string(sb, "&gt;")
		case c == '"' && attr: strings.write_string(sb, "&quot;")
		case: strings.write_byte(sb, c)
		}
	}
}

@(private = "file")
VOID_ELEMENTS := [?]string{"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}

// The markup of [start, end]: the nodes inside, with the elements that are only partly inside (from the common
// ancestor down) around them, as browsers put on the clipboard. Scripts and styles are left out.
range_html :: proc(d: ^dom.Document, start, end: Text_Pos, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	if pos_compare(d, start, end) >= 0 { return "" }
	// common ancestor container
	common := start.node
	for common != base.NIL_HANDLE && !dom.is_ancestor_or_self(d, common, end.node) { common = dom.get(d, common).parent }
	if common == base.NIL_HANDLE { return "" }
	if n := dom.get(d, common); n != nil && n.kind == .Text { common = n.parent }
	Step :: struct { h: base.Handle, exit: bool }
	stack := make([dynamic]Step, 0, 64, context.temp_allocator)
	cn := dom.get(d, common)
	for c := cn.last_child; c != base.NIL_HANDLE; c = dom.get(d, c).prev { append(&stack, Step{h = c}) }
	for len(stack) > 0 {
		s := pop(&stack)
		n := dom.get(d, s.h)
		if n == nil { continue }
		if s.exit { strings.write_string(&sb, "</"); strings.write_string(&sb, n.name); strings.write_byte(&sb, '>'); continue }
		if pos_compare(d, pos_after(d, s.h), start) <= 0 { continue }
		if pos_compare(d, pos_before(d, s.h), end) >= 0 { continue }
		switch n.kind {
		case .Document, .Comment:
		case .Text:
			lo := start.node == s.h ? start.offset : 0
			hi := end.node == s.h ? end.offset : len(n.text)
			escape_into(&sb, n.text[clamp(lo, 0, len(n.text)):clamp(hi, 0, len(n.text))], false)
		case .Element:
			if n.name == "script" || n.name == "style" || n.name == "template" { continue }
			strings.write_byte(&sb, '<')
			strings.write_string(&sb, n.name)
			for a in n.attrs {
				if strings.has_prefix(a.name, "on") { continue }
				strings.write_byte(&sb, ' ')
				strings.write_string(&sb, a.name)
				strings.write_string(&sb, "=\"")
				escape_into(&sb, a.value, true)
				strings.write_byte(&sb, '"')
			}
			strings.write_byte(&sb, '>')
			void := false
			for v in VOID_ELEMENTS { if v == n.name { void = true } }
			if void { continue }
			append(&stack, Step{h = s.h, exit = true})
			for c := n.last_child; c != base.NIL_HANDLE; c = dom.get(d, c).prev { append(&stack, Step{h = c}) }
		}
	}
	return strings.to_string(sb)
}
