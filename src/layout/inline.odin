package layout

import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "wb:dom"
import "wb:style"

// Inline formatting (CSS 2.1 §9.4.2, §10.8; CSS Text 3: white space processing, line breaking, alignment, justification,
// text-indent, text-overflow). Content is a flat list of items; a segment iterator turns it into words, spaces, tabs,
// inline box edges and atomic inlines, with soft wrap opportunities between them. Lines are filled greedily with
// "units" (segments up to the next opportunity), lowered below floats when a unit cannot fit beside them, and broken
// inside a unit when overflow-wrap / word-break allow it.

@(private)
Seg_Kind :: enum u8 { Text, Space, Tab, Open, Close, Atomic, Float, Abs, Break, Block }

@(private)
Seg :: struct {
	kind:        Seg_Kind,
	item:        i32,
	start, end:  i32,
	w:           f32,
	brk:         bool,   // a soft wrap opportunity follows
	collapsible: bool,   // Space: removed at the start of a line
	hang:        bool,   // Space: hangs past the end of a line
	breakable:   bool,   // Text: may be broken anywhere when it cannot fit (overflow-wrap, word-break)
	level:       u8,     // Text, Space: bidi embedding level (a segment never spans two levels)
}

@(private)
Seg_Iter :: struct {
	c:          ^Ctx,
	idx, end:   i32,
	pos:        int,
	prev_space: bool,
	cw:         f32,      // percentage base of inline box edges
	bidi:       ^Bidi_Para,   // nil: every level is 0
}

@(private)
is_ws :: #force_inline proc(b: u8) -> bool { return b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\f' }

@(private)
is_cjk :: proc(r: rune) -> bool {
	return (r >= 0x2E80 && r <= 0x9FFF) || (r >= 0xF900 && r <= 0xFAFF) || (r >= 0xFF00 && r <= 0xFF60) ||
		(r >= 0xFFE0 && r <= 0xFFE6) || (r >= 0x20000 && r <= 0x3FFFF)
}

@(private)
wraps :: #force_inline proc(ws: style.White_Space) -> bool { return ws != .Nowrap && ws != .Pre }

// End of the word starting at `pos`, and whether a wrap opportunity follows it.
@(private)
word_end :: proc(text: string, pos: int, cs: ^style.Computed, wrap: bool) -> (int, bool) {
	i := pos
	for i < len(text) {
		b := text[i]
		if is_ws(b) { return i, false }
		if b < 0x80 && b != '-' && cs.word_break != .Break_All {
			i += 1
			continue
		}
		r, n := utf8.decode_rune_in_string(text[i:])
		if wrap {
			if cs.word_break == .Break_All { return i + n, true }
			if is_cjk(r) && cs.word_break != .Keep_All {
				if i > pos { return i, true }
				return i + n, true
			}
			if r == 0x200B { return i + n, true }
			if (r == '-' || r == 0x2010) && i > pos && i + n < len(text) && !is_ws(text[i + n]) { return i + n, true }
		}
		i += n
	}
	return i, false
}

@(private)
rune_count :: proc(s: string) -> int {
	n := 0
	for i in 0 ..< len(s) { if s[i] & 0xC0 != 0x80 { n += 1 } }
	return n
}

// Width of a piece of text with its letter spacing, and the word spacing of its no-break spaces (word-separator
// characters, CSS Text 3 §8.1; the spaces between words are segments of their own).
@(private)
text_width :: proc(c: ^Ctx, fi: i32, cs: ^style.Computed, s: string) -> f32 {
	w: f32
	if cs.letter_spacing != 0 && c.text.width_spaced != nil {
		// letter-spacing turns optional ligatures off: measured as it is drawn
		f := &c.l.fonts[fi]
		w = c.text.width_spaced(c.text.user, f.font, f.size, s, cs.letter_spacing * c.scale)
	} else {
		w = measure(c, fi, s)
		if cs.letter_spacing != 0 { w += cs.letter_spacing * c.scale * f32(rune_count(s)) }
	}
	if cs.word_spacing != 0 {
		for i := 0; i + 1 < len(s); i += 1 { if s[i] == 0xC2 && s[i + 1] == 0xA0 { w += cs.word_spacing * c.scale } }
	}
	return w
}

@(private)
next_seg :: proc(it: ^Seg_Iter) -> (Seg, bool) {
	c := it.c
	for it.idx < it.end {
		item := &c.l.inline_items[it.idx]
		idx := it.idx
		switch item.kind {
		case .Text:
			text := item.text
			if it.pos >= len(text) { it.idx += 1; it.pos = 0; continue }
			cs := item.cs
			ws := cs.white_space
			collapse := ws == .Normal || ws == .Nowrap || ws == .Pre_Line
			wrap := wraps(ws)
			keep_nl := ws != .Normal && ws != .Nowrap
			f := &c.l.fonts[item.fi]
			wsp := cs.word_spacing * c.scale
			b := text[it.pos]
			if keep_nl && (b == '\n' || (b == '\r' && (it.pos + 1 >= len(text) || text[it.pos + 1] != '\n'))) {
				it.pos += 1
				it.prev_space = false
				return Seg{kind = .Break, item = idx}, true
			}
			lv := it.bidi != nil ? bidi_level(it.bidi, idx, it.pos) : 0
			if is_ws(b) {
				if collapse {
					j := it.pos
					for j < len(text) && is_ws(text[j]) && !(keep_nl && (text[j] == '\n' || text[j] == '\r')) { j += 1 }
					s := it.pos
					it.pos = j
					if it.prev_space { continue }
					it.prev_space = true
					return Seg{kind = .Space, item = idx, start = i32(s), end = i32(j), w = f.space + wsp, brk = wrap, collapsible = true, hang = true, level = lv}, true
				}
				s := it.pos
				it.pos += 1
				it.prev_space = false
				if b == '\r' { continue }
				if b == '\t' { return Seg{kind = .Tab, item = idx, start = i32(s), end = i32(s + 1), brk = wrap, level = lv}, true }
				return Seg{kind = .Space, item = idx, start = i32(s), end = i32(s + 1), w = f.space + wsp, brk = wrap, hang = ws != .Break_Spaces, level = lv}, true
			}
			it.prev_space = false
			j, brk := word_end(text, it.pos, cs, wrap)
			s := it.pos
			if it.bidi != nil {
				// a segment is one directional run: it ends where the level changes
				for k := s + 1; k < j; k += 1 {
					if text[k] & 0xC0 == 0x80 { continue }
					if bidi_level(it.bidi, idx, k) != lv { j, brk = k, false; break }
				}
			}
			if wrap && c.text.line_break != nil && needs_dictionary(text[s:j]) {
				// scripts without spaces between words: the first opportunity the dictionary finds
				if bk := c.text.line_break(c.text.user, text[s:j]); bk > 0 && bk < j - s { j, brk = s + bk, true }
			}
			it.pos = j
			w := text_width(c, item.fi, cs, text[s:j])
			breakable := wrap && (cs.overflow_wrap != .Normal || cs.word_break == .Break_Word || cs.word_break == .Break_All)
			return Seg{kind = .Text, item = idx, start = i32(s), end = i32(j), w = w, brk = brk, breakable = breakable, level = lv}, true
		case .Open:
			it.idx += 1
			ib := &c.l.boxes[item.box]
			resolve_box_model(c, ib, it.cw)
			return Seg{kind = .Open, item = idx, w = ib.margin[3] + ib.border[3] + ib.padding[3]}, true
		case .Close:
			it.idx += 1
			ib := &c.l.boxes[item.box]
			return Seg{kind = .Close, item = idx, w = ib.margin[1] + ib.border[1] + ib.padding[1]}, true
		case .Atomic:
			it.idx += 1
			it.prev_space = false
			k := &c.l.boxes[item.box]
			pcs := c.l.boxes[k.parent].cs
			return Seg{kind = .Atomic, item = idx, brk = pcs != nil && wraps(pcs.white_space)}, true
		case .Float:
			it.idx += 1
			return Seg{kind = .Float, item = idx}, true
		case .Abs:
			it.idx += 1
			return Seg{kind = .Abs, item = idx}, true
		case .Break:
			it.idx += 1
			it.prev_space = false
			return Seg{kind = .Break, item = idx}, true
		case .Block:
			it.idx += 1
			it.prev_space = false
			return Seg{kind = .Block, item = idx}, true
		}
	}
	return {}, false
}

////////////////////////////////
// Line building

@(private)
Open_Box :: struct { box: i32, frag: i32 }

@(private)
Pending_Abs :: struct { box: i32, x: f32 }

@(private)
Align_Group :: struct { min, max: f32, top: bool }

@(private)
LB_Buffers :: struct {
	frags, out:     [dynamic]Frag,
	lines:          [dynamic]Line,
	open:           [dynamic]Open_Box,
	unit:           [dynamic]Seg,
	pending_floats: [dynamic]i32,
	pending_abs:    [dynamic]Pending_Abs,
	groups:         [dynamic]Align_Group,
	segs:           [dynamic]Seg,       // the segments measured, kept for later passes (keep_segs)
}

@(private)
Line_Builder :: struct {
	c:        ^Ctx,
	bi:       i32,
	cs:       ^style.Computed,
	cw:       f32,
	fc:       ^Flow_Ctx,
	cx, cy:   f32,
	root_fi:  i32,
	y:        f32,           // top of the current line, from the content top
	left, right: f32,        // band of the current line in content-box coordinates
	pen:      f32,           // from `left`
	empty:    bool,          // nothing placed on the line yet
	content:  bool,          // the line is not a phantom line
	at_break: bool,          // the line being finished ends with a <br> (text, for the line height quirk)
	can_break: bool,         // a wrap opportunity precedes the next unit
	spaces:   i32,
	trail_w:  f32,
	trail_n:  i32,
	first:    bool,
	any_line: bool,
	frags:    [dynamic]Frag,
	lines:    [dynamic]Line,
	out:      [dynamic]Frag,
	open:     [dynamic]Open_Box,
	unit:     [dynamic]Seg,
	pending_floats: [dynamic]i32,
	pending_abs:    [dynamic]Pending_Abs,
	groups:   [dynamic]Align_Group,
	strut_h:  f32,
	bidi:     ^Bidi_Para,    // nil: a left-to-right paragraph without right-to-left text
	bidi_line: bool,         // something on the current line is at a level other than 0
	// the last block-in-inline: its bottom margin and where it ended (nothing after: the margin collapses out of the
	// context, as an anonymous block's would)
	block_margin, block_end: f32,
	lines_at_block: int,     // lines made when it ended (more since: a line separates it from what comes next)
}

@(private)
lb_band :: proc(lb: ^Line_Builder) {
	fc := lb.fc
	if fc.bfc == nil || len(fc.bfc.floats) == 0 { lb.left, lb.right = 0, lb.cw; return }
	ty := content_top(fc) + lb.y
	l, r := bfc_band(fc.bfc, ty, ty + lb.strut_h, fc.x, fc.x + lb.cw)
	// a side no float narrows is exactly the content box's: lines that no float reaches do not depend on where the
	// context sits ((x + cw) - x is not always cw in floating point), as when no float is placed at all, so that a
	// cached result (block.odin) is the one a new layout would make
	lb.left = l == fc.x ? 0 : l - fc.x
	lb.right = r == fc.x + lb.cw ? lb.cw : r - fc.x
}

@(private)
start_line :: proc(lb: ^Line_Builder) {
	lb_band(lb)
	lb.pen = 0
	lb.empty, lb.content, lb.can_break = true, false, false
	lb.spaces, lb.trail_w, lb.trail_n = 0, 0, 0
	lb.bidi_line = false
	clear(&lb.frags)
	if lb.first {
		indent := px_of(lb.c, lb.cs.text_indent, lb.cw)
		lb.pen = indent
	}
	// inline boxes still open continue on this line, without their start edge
	for &o in lb.open {
		o.frag = i32(len(lb.frags))
		append(&lb.frags, Frag{kind = .Box, box = o.box, fi = lb.c.l.boxes[o.box].fi, x = lb.pen, item = -1})
	}
}

@(private)
emit_text :: proc(lb: ^Line_Builder, item: i32, start, end: i32, w: f32, nsp: i32, level: u8 = 0) {
	c := lb.c
	it := &c.l.inline_items[item]
	piece := it.text[start:end]
	if level != 0 { lb.bidi_line = true }
	if n := len(lb.frags); n > 0 {
		last := &lb.frags[n - 1]
		if last.kind == .Text && last.item == item && last.level == level && rawptr(uintptr(raw_data(last.text)) + uintptr(len(last.text))) == rawptr(raw_data(piece)) {
			off := int(uintptr(raw_data(last.text)) - uintptr(raw_data(it.text)))
			last.text = it.text[off:end]
			last.w += w
			last.nsp += nsp
			lb.pen += w
			return
		}
	}
	append(&lb.frags, Frag{kind = .Text, item = item, box = it.box, fi = it.fi, x = lb.pen, w = w, text = piece, spaces = lb.spaces, nsp = nsp, level = level})
	lb.pen += w
}

// Tab stop interval (CSS Text 3 §4.2): a number of advances of a space (letter-spacing included), or a length.
@(private)
tab_interval :: proc(c: ^Ctx, it: ^Inline_Item) -> f32 {
	f := &c.l.fonts[it.fi]
	t := it.cs.tab_size
	space := f.space + it.cs.letter_spacing * c.scale
	if t <= 0 { return 0 }   // tab-size: 0: tabs are not rendered
	if it.cs.tab_spaces { return space * t }
	return t * c.scale
}

@(private)
tab_width :: proc(lb: ^Line_Builder, s: Seg, at: f32) -> f32 {
	c := lb.c
	it := &c.l.inline_items[s.item]
	f := &c.l.fonts[it.fi]
	t := tab_interval(c, it)
	// no interval (tab-size: 0, font-size: 0, a letter-spacing that cancels the space): a tab has no width (mod by 0
	// was NaN, and every fragment after it on the line had a NaN position)
	if !(t > 0.001) { return 0 }
	w := t - math.mod(at, t)
	if w < f.space * 0.5 { w += t }
	return w
}

@(private)
place_seg :: proc(lb: ^Line_Builder, s: Seg) {
	c := lb.c
	switch s.kind {
	case .Text:
		emit_text(lb, s.item, s.start, s.end, s.w, 0, s.level)
		lb.empty, lb.content = false, true
		lb.trail_w, lb.trail_n = 0, 0
	case .Space:
		if lb.empty && s.collapsible { return }
		it := &c.l.inline_items[s.item]
		if s.end - s.start == 1 && it.text[s.start] == ' ' { emit_text(lb, s.item, s.start, s.end, s.w, 1, s.level) } else { lb.pen += s.w }
		lb.spaces += 1
		if s.hang { lb.trail_w += s.w; lb.trail_n += 1 } else { lb.trail_w, lb.trail_n = 0, 0 }
		if !s.collapsible { lb.content = true }
		lb.empty = false
	case .Tab:
		lb.pen += tab_width(lb, s, lb.pen)
		lb.empty, lb.content = false, true
		lb.trail_w, lb.trail_n = 0, 0
	case .Open:
		it := &c.l.inline_items[s.item]
		ib := &c.l.boxes[it.box]
		append(&lb.open, Open_Box{it.box, i32(len(lb.frags))})
		append(&lb.frags, Frag{kind = .Box, flags = {.Left_Edge}, box = it.box, fi = ib.fi, x = lb.pen + ib.margin[3], spaces = lb.spaces, item = -1})
		lb.pen += s.w
		if s.w != 0 || ib.border[0] + ib.border[2] + ib.padding[0] + ib.padding[2] > 0 { lb.content = true }
	case .Close:
		it := &c.l.inline_items[s.item]
		ib := &c.l.boxes[it.box]
		if n := len(lb.open); n > 0 && lb.open[n - 1].box == it.box {
			o := pop(&lb.open)
			f := &lb.frags[o.frag]
			f.w = lb.pen + ib.border[1] + ib.padding[1] - f.x
			f.flags += {.Right_Edge}
			f.nsp = lb.spaces
		}
		lb.pen += s.w
		if s.w != 0 { lb.content = true }
	case .Atomic:
		it := &c.l.inline_items[s.item]
		k := &c.l.boxes[it.box]
		append(&lb.frags, Frag{kind = .Atomic, box = it.box, x = lb.pen + k.margin[3], w = k.size.x, spaces = lb.spaces, item = s.item})
		lb.pen += s.w
		lb.empty, lb.content = false, true
		lb.trail_w, lb.trail_n = 0, 0
	case .Float, .Abs, .Break, .Block:
	}
}

@(private)
unit_width :: proc(lb: ^Line_Builder) -> (w, lead, tail: f32) {
	at := lb.pen
	leading := lb.empty
	for &s in lb.unit {
		sw := s.w
		if s.kind == .Tab { sw = tab_width(lb, s, at); s.w = sw }
		if leading {
			if s.kind == .Space && s.collapsible { lead += sw; continue }
			if s.kind != .Open && s.kind != .Close { leading = false }
		}
		w += sw
		at += sw
		if s.kind == .Space && s.hang { tail += sw } else if s.kind != .Close { tail = 0 }
	}
	w += lead
	return
}

// Moves an empty line down past floats until `need` fits beside them (or no float narrows the line any more).
@(private)
lower_line :: proc(lb: ^Line_Builder, need: f32) {
	fc := lb.fc
	if fc.bfc == nil { return }
	for tries := 0; tries <= len(fc.bfc.floats); tries += 1 {
		if lb.right - lb.left >= need - 0.01 { return }
		if lb.left <= 0.01 && lb.right >= lb.cw - 0.01 { return }
		nb := bfc_next_bottom(fc.bfc, content_top(fc) + lb.y)
		if nb == math.F32_MAX { return }
		lb.y = nb - content_top(fc)
		lb_band(lb)
	}
}

@(private)
commit_unit :: proc(lb: ^Line_Builder, brk_after: bool) {
	if len(lb.unit) == 0 { lb.can_break = lb.can_break || brk_after; return }
	w, lead, tail := unit_width(lb)
	need := w - lead - tail
	if !lb.empty && lb.can_break && lb.pen + need > lb.right - lb.left + 0.01 {
		finish_line(lb, false, false)
		w, lead, tail = unit_width(lb)
		need = w - lead - tail
	}
	if lb.empty && need > lb.right - lb.left + 0.01 {
		lower_line(lb, need)
		if need > lb.right - lb.left + 0.01 {
			any_breakable := false
			for &s in lb.unit { if s.kind == .Text && s.breakable { any_breakable = true } }
			if any_breakable {
				split_unit(lb)
				clear(&lb.unit)
				lb.can_break = brk_after
				return
			}
		}
	}
	for &s in lb.unit { place_seg(lb, s) }
	clear(&lb.unit)
	lb.can_break = brk_after
}

// Places a unit that cannot fit, breaking its text anywhere (overflow-wrap: anywhere / break-word, word-break).
@(private)
split_unit :: proc(lb: ^Line_Builder) {
	c := lb.c
	for &s in lb.unit {
		if s.kind != .Text || !s.breakable { place_seg(lb, s); continue }
		it := &c.l.inline_items[s.item]
		text := it.text
		i := int(s.start)
		for i < int(s.end) {
			_, n := utf8.decode_rune_in_string(text[i:])
			rw := text_width(c, it.fi, it.cs, text[i:i + n])
			if !lb.empty && lb.pen + rw > lb.right - lb.left + 0.01 { finish_line(lb, false, false) }
			emit_text(lb, s.item, i32(i), i32(i + n), rw, 0, s.level)
			lb.empty, lb.content = false, true
			lb.trail_w, lb.trail_n = 0, 0
			i += n
		}
	}
}

// The half-leading above and below the content area of a font (CSS Inline 3 §4.4: line-height minus ascent + descent,
// shared). With round_metrics the top half is floored to whole device pixels and the bottom takes the rest, as Blink
// does (CalculateLeadingSpace): a 32 px line around 31 px of text has 0 above and 1 below.
@(private)
half_leading :: #force_inline proc(c: ^Ctx, f: ^Font_Info) -> (top, bottom: f32) {
	l := f.line_h - (f.ascent + f.descent)
	top = c.set.round_metrics ? math.floor(l * 0.5) : l * 0.5
	return top, l - top
}

// A text fragment of line-height: normal also makes room for the faces its text falls back to (CSS Inline 3 §4.2:
// "normal" uses the metrics of all the fonts used; Blink's InlineBoxState::AccumulateUsedFonts): each face's ascent
// and descent with the half-leading of its own normal line height, around the fragment's baseline `shift`. An emoji
// in Arial text: Segoe UI Emoji's taller ascent raises the line. Whether an item falls back at all is found once per
// font (ASCII text is taken as covered by the first face).
@(private)
used_fonts_extent :: proc(c: ^Ctx, f: ^Frag, fi: ^Font_Info, shift: f32, top, bot: ^f32) {
	if c.text.fallback_metrics == nil || f.item < 0 { return }
	it := &c.l.inline_items[f.item]
	buf: [8]Font_Metrics
	if it.fb == .Unknown || it.fb_font != fi.font {
		it.fb, it.fb_font = .None, fi.font
		ascii := true
		for i in 0 ..< len(it.text) { if it.text[i] >= 0x80 { ascii = false; break } }
		if !ascii && c.text.fallback_metrics(c.text.user, fi.font, fi.size, it.text, buf[:]) > 0 { it.fb = .Some }
	}
	if it.fb != .Some { return }
	n := min(c.text.fallback_metrics(c.text.user, fi.font, fi.size, f.text, buf[:]), len(buf))
	for m in buf[:n] {
		a, d, lh := m.ascent, m.descent, m.line_height
		ht: f32
		if c.set.round_metrics {
			a, d = math.round(a), math.round(d)
			lh = a + d + math.round(m.line_gap)
			ht = math.floor((lh - (a + d)) * 0.5)
		} else {
			if lh <= 0 { lh = a + d + m.line_gap }
			ht = (lh - (a + d)) * 0.5
		}
		top^ = min(top^, shift - a - ht)
		bot^ = max(bot^, shift + d + (lh - (a + d) - ht))
	}
}

// Baseline shift of an inline box (positive down) from its parent's baseline `ps` (CSS 2.1 §10.8.1, as Blink's
// ComputeAlignmentBaselineShift: middle, text-top and text-bottom align the box's leading-inclusive extent).
@(private)
va_inline :: proc(c: ^Ctx, va: style.Vertical_Align, ps: f32, pf, f: ^Font_Info) -> f32 {
	ht, hb := half_leading(c, f)
	switch va.kind {
	case .Baseline, .Top, .Bottom: return ps
	case .Sub: return ps + c.set.sub_shift * pf.size + c.set.sub_super_extra
	case .Super: return ps - c.set.super_shift * pf.size - c.set.sub_super_extra
	case .Text_Top: return ps - pf.ascent + f.ascent + ht
	case .Text_Bottom: return ps + pf.descent - f.descent - hb
	case .Middle: return ps - pf.x_height * 0.5 - ((f.descent + hb) - (f.ascent + ht)) * 0.5
	case .Length: return ps - px_of(c, va.amount, f.line_h)
	}
	return ps
}

@(private)
va_atomic :: proc(c: ^Ctx, va: style.Vertical_Align, ps: f32, pf: ^Font_Info, mh, bl, own_lh: f32) -> f32 {
	switch va.kind {
	case .Baseline, .Top, .Bottom: return ps
	case .Sub: return ps + c.set.sub_shift * pf.size + c.set.sub_super_extra
	case .Super: return ps - c.set.super_shift * pf.size - c.set.sub_super_extra
	case .Text_Top: return ps - pf.ascent + bl
	case .Text_Bottom: return ps + pf.descent - (mh - bl)
	case .Middle: return ps - pf.x_height * 0.5 + bl - mh * 0.5
	case .Length: return ps - px_of(c, va.amount, own_lh)
	}
	return ps
}

// Baseline of an atomic inline from its top margin edge (CSS 2.1 §10.8.1: the last line box of an inline-block whose
// overflow is visible, else the bottom margin edge).
@(private)
atomic_baseline :: proc(c: ^Ctx, k: ^Box) -> f32 {
	mh := k.size.y + k.pre_h + mg_h(k)
	#partial switch k.kind {
	case .Block:
		if k.cs.overflow_x == .Visible && k.cs.overflow_y == .Visible && k.last_baseline >= 0 { return k.margin[0] + k.last_baseline }
	case .Flex, .Grid, .Table:
		if k.baseline >= 0 { return k.margin[0] + k.pre_h + k.baseline }
	case .Replaced:
		if .Control in k.flags {
			if bl, ok := control_baseline(c, k); ok { return k.margin[0] + bl }
		}
	}
	return mh
}

// Baseline of a replaced form control from its border-box top, as Blink places it: text fields, drop-down lists and
// input buttons have a line of their font centered in the content box (the inner editor, the button's label); check
// boxes and radio buttons sit on their bottom border edge (the bottom margin hangs below the baseline). Others (text
// areas, list boxes, sliders, color wells, image buttons): no baseline (the bottom margin edge).
@(private)
control_baseline :: proc(c: ^Ctx, k: ^Box) -> (f32, bool) {
	n := dom.get(c.d, k.node)
	if n == nil || k.fi < 0 { return 0, false }
	switch n.name {
	case "input":
		t, _ := dom.get_attribute(c.d, k.node, "type")
		t = strings.trim_space(t)
		switch {
		case strings.equal_fold(t, "checkbox"), strings.equal_fold(t, "radio"):
			return k.size.y, true
		case strings.equal_fold(t, "range"), strings.equal_fold(t, "color"), strings.equal_fold(t, "image"), strings.equal_fold(t, "hidden"):
			return 0, false
		}
	case "select":
		if _, multi := dom.get_attribute(c.d, k.node, "multiple"); multi { return 0, false }
		if attr_int(c, k.node, "size", 1) > 1 { return 0, false }
	case:
		return 0, false
	}
	fi := &c.l.fonts[k.fi]
	ht, _ := half_leading(c, fi)
	ch := k.size.y - pb_h(k)
	return k.border[0] + k.padding[0] + (ch - fi.line_h) * 0.5 + ht + fi.ascent, true
}

@(private)
finish_line :: proc(lb: ^Line_Builder, forced, last: bool) {
	c := lb.c
	for &o in lb.open {
		f := &lb.frags[o.frag]
		f.w = lb.pen - f.x
		f.nsp = lb.spaces
	}
	// trailing white space hangs: it neither counts for alignment nor offers justification
	if lb.trail_n > 0 {
		for i := len(lb.frags) - 1; i >= 0; i -= 1 {
			f := &lb.frags[i]
			if f.kind == .Box { continue }
			if f.kind == .Text && len(f.text) > 0 && f.text[len(f.text) - 1] == ' ' && f.nsp > 0 {
				it := &c.l.inline_items[f.item]
				if it.cs.white_space == .Normal || it.cs.white_space == .Nowrap || it.cs.white_space == .Pre_Line {
					sw := c.l.fonts[f.fi].space + it.cs.word_spacing * c.scale
					f.text = f.text[:len(f.text) - 1]
					f.w -= sw
					f.nsp -= 1
				}
			}
			break
		}
	}
	used := lb.pen - lb.trail_w
	opportunities := lb.spaces - lb.trail_n

	if !lb.content {
		// a phantom line (CSS 2.1 §9.4.2): no height, nothing drawn; still where floats and positioned boxes go
		for &p in lb.pending_abs {
			k := &c.l.boxes[p.box]
			k.static_ref = lb.bi
			k.static_pos = {lb.cx + lb.left + p.x, lb.cy + lb.y}
		}
		clear(&lb.pending_abs)
		place_pending_floats(lb)
		start_line(lb)
		return
	}

	// vertical alignment (§10.8)
	root := &c.l.fonts[lb.root_fi]
	rht, rhb := half_leading(c, root)
	min_top, max_bot := -root.ascent - rht, root.descent + rhb
	// the line height calculation quirk (Quirks Mode §3.3; Blink: the strut of an inline box only once text is
	// placed in it): in quirks and limited-quirks modes the root inline box and inline boxes without padding, border or margin count only
	// when text sits directly in them (their text fragments do), so an image alone in a table cell gets no strut
	quirks := c.st != nil && c.st.line_quirk
	if quirks && !lb.at_break {
		root_text := false
		for &f in lb.frags {
			if f.kind == .Text && f.box == NONE && len(f.text) > 0 { root_text = true; break }
		}
		if !root_text { min_top, max_bot = math.F32_MAX, -math.F32_MAX }
	}
	clear(&lb.groups)
	extend :: proc(lb: ^Line_Builder, g: i32, top, bot: f32, min_top, max_bot: ^f32) {
		if g >= 0 {
			gr := &lb.groups[g]
			gr.min, gr.max = min(gr.min, top), max(gr.max, bot)
		} else {
			min_top^, max_bot^ = min(min_top^, top), max(max_bot^, bot)
		}
	}
	for &f in lb.frags {
		switch f.kind {
		case .Box:
			ib := &c.l.boxes[f.box]
			ps: f32 = 0
			pfi := lb.root_fi
			pg := i32(-1)
			if p := ib.parent; p != NONE && c.l.boxes[p].kind == .Inline {
				ps, pfi, pg = c.l.boxes[p].tmp, c.l.boxes[p].fi, c.l.boxes[p].tmp_al
			}
			fi := &c.l.fonts[ib.fi]
			va := ib.cs.vertical_align
			g := pg
			if va.kind == .Top || va.kind == .Bottom {
				g = i32(len(lb.groups))
				append(&lb.groups, Align_Group{min = math.F32_MAX, max = -math.F32_MAX, top = va.kind == .Top})
				ps = 0
			}
			shift := va_inline(c, va, ps, &c.l.fonts[pfi], fi)
			ib.tmp, ib.tmp_al = shift, g
			f.baseline = shift
			ht, hb := half_leading(c, fi)
			if quirks && ib.padding[0] + ib.padding[2] + ib.border[0] + ib.border[2] == 0 &&
			   ib.padding[1] + ib.padding[3] + ib.border[1] + ib.border[3] + ib.margin[1] + ib.margin[3] == 0 {
				// (its own top / bottom group still needs a place)
				if g != pg { extend(lb, g, shift, shift, &min_top, &max_bot) }
				continue
			}
			extend(lb, g, shift - fi.ascent - ht, shift + fi.descent + hb, &min_top, &max_bot)
		case .Text, .Ellipsis:
			shift: f32 = 0
			g := i32(-1)
			if f.box != NONE { shift, g = c.l.boxes[f.box].tmp, c.l.boxes[f.box].tmp_al }
			fi := &c.l.fonts[f.fi]
			ht, hb := half_leading(c, fi)
			f.baseline = shift
			if quirks && f.kind == .Text && len(f.text) == 0 { continue }
			top, bot := shift - fi.ascent - ht, shift + fi.descent + hb
			if f.kind == .Text && fi.lh_normal { used_fonts_extent(c, &f, fi, shift, &top, &bot) }
			extend(lb, g, top, bot, &min_top, &max_bot)
		case .Atomic:
			k := &c.l.boxes[f.box]
			ps: f32 = 0
			pfi := lb.root_fi
			g := i32(-1)
			if p := k.parent; p != NONE && c.l.boxes[p].kind == .Inline {
				ps, pfi, g = c.l.boxes[p].tmp, c.l.boxes[p].fi, c.l.boxes[p].tmp_al
			}
			mh := k.size.y + k.pre_h + mg_h(k)
			bl := atomic_baseline(c, k)
			va := k.cs.vertical_align
			if va.kind == .Top || va.kind == .Bottom {
				g = i32(len(lb.groups))
				append(&lb.groups, Align_Group{min = math.F32_MAX, max = -math.F32_MAX, top = va.kind == .Top})
				ps = 0
			}
			own_lh := k.fi >= 0 ? c.l.fonts[k.fi].line_h : mh
			shift := va_atomic(c, va, ps, &c.l.fonts[pfi], mh, bl, own_lh)
			f.baseline = shift
			f.y = shift - bl
			f.h = mh
			f.nsp = g
			extend(lb, g, shift - bl, shift - bl + mh, &min_top, &max_bot)
		}
	}
	if min_top > max_bot { min_top, max_bot = 0, 0 }   // (quirks: nothing counted)
	line_h := max_bot - min_top
	base_y := -min_top
	for &g in lb.groups {
		gh := g.max - g.min
		if gh > line_h {
			if !g.top { base_y += gh - line_h }
			line_h = gh
		}
	}
	// group offsets: a top-aligned group's top meets the line top, a bottom-aligned group's bottom the line bottom
	group_delta :: proc(lb: ^Line_Builder, g: i32, base_y, line_h: f32) -> f32 {
		if g < 0 { return 0 }
		gr := &lb.groups[g]
		if gr.top { return -base_y - gr.min }
		return line_h - base_y - gr.max
	}

	// horizontal alignment and justification
	avail := lb.right - lb.left
	free := avail - used
	align := lb.cs.text_align
	rtl := is_rtl(lb.cs)
	justify := align == .Justify && !forced && !last && opportunities > 0 && free > 0
	shift: f32 = 0
	#partial switch align {
	case .Start, .Justify: if rtl { shift = free }
	case .End: if !rtl { shift = free }
	case .Right, .Legacy_Right: shift = free
	case .Center, .Legacy_Center: shift = free * 0.5
	}
	if free < 0 && !rtl { shift = 0 }
	extra: f32 = justify ? free / f32(opportunities) : 0
	if justify { shift = 0 }

	line_top := lb.cy + lb.y
	baseline := line_top + base_y
	ox := lb.cx + lb.left + shift
	for &f in lb.frags {
		sp := f32(f.spaces) * extra
		switch f.kind {
		case .Box:
			ib := &c.l.boxes[f.box]
			fi := &c.l.fonts[ib.fi]
			x0 := f.x + sp
			x1 := f.x + f.w + f32(f.nsp) * extra
			f.x = ox + x0
			f.w = x1 - x0
			bl := baseline + f.baseline + group_delta(lb, ib.tmp_al, base_y, line_h)
			f.baseline = bl
			f.y = bl - fi.ascent - ib.padding[0] - ib.border[0]
			f.h = fi.ascent + fi.descent + pb_h(ib)
		case .Text, .Ellipsis:
			g := f.box != NONE ? c.l.boxes[f.box].tmp_al : -1
			fi := &c.l.fonts[f.fi]
			f.x = ox + f.x + sp
			f.w += f32(f.nsp) * extra
			f.extra = extra
			f.baseline = baseline + f.baseline + group_delta(lb, g, base_y, line_h)
			f.y = f.baseline - fi.ascent
			f.h = fi.ascent + fi.descent
		case .Atomic:
			k := &c.l.boxes[f.box]
			d := group_delta(lb, f.nsp, base_y, line_h)
			f.nsp = 0
			f.x = ox + f.x + sp
			f.y = baseline + f.y + d
			f.baseline = baseline + f.baseline + d
			k.pos = {f.x, f.y + k.margin[0] + k.pre_h}
		}
	}

	// bidi: fragments to visual order (UAX #9 L2)
	if lb.bidi_line || (lb.bidi != nil && lb.bidi.base_rtl) { bidi_reorder_line(lb) }

	// text-overflow: ellipsis on a line that overflows a clipping box
	if lb.cs.text_ellipsis && .Clips in c.l.boxes[lb.bi].flags && used > avail + 0.5 {
		apply_ellipsis(lb, lb.cx + lb.left + avail, baseline)
	}

	first_frag := i32(len(lb.out))
	append(&lb.out, ..lb.frags[:])
	append(&lb.lines, Line{y = line_top, h = line_h, baseline = base_y, frags = {first_frag, i32(len(lb.out))}, left = lb.left, width = avail})
	for &p in lb.pending_abs {
		k := &c.l.boxes[p.box]
		k.static_ref = lb.bi
		k.static_pos = {ox + p.x, line_top}
	}
	clear(&lb.pending_abs)
	lb.y += line_h
	lb.first = false
	lb.any_line = true
	place_pending_floats(lb)
	start_line(lb)
}

@(private)
apply_ellipsis :: proc(lb: ^Line_Builder, right, baseline: f32) {
	c := lb.c
	efi := lb.root_fi
	ew := measure(c, efi, "\u2026")
	limit := right - ew
	cut_at := len(lb.frags)
	pen := limit
	for i := 0; i < len(lb.frags); i += 1 {
		f := &lb.frags[i]
		if f.kind == .Box {
			if f.x + f.w > limit { f.w = max(limit - f.x, 0); f.flags -= {.Right_Edge} }
			continue
		}
		if f.x + f.w <= limit { continue }
		if f.kind == .Text {
			it := &c.l.inline_items[f.item]
			x := f.x
			keep := 0
			for keep < len(f.text) {
				_, n := utf8.decode_rune_in_string(f.text[keep:])
				rw := text_width(c, f.fi, it.cs, f.text[keep:keep + n])
				if x + rw > limit { break }
				x += rw
				keep += n
			}
			f.text = f.text[:keep]
			f.w = x - f.x
			f.extra = 0
			pen = x
			cut_at = i + 1
		} else {
			pen = f.x - (f.kind == .Atomic ? c.l.boxes[f.box].margin[3] : 0)
			cut_at = i
		}
		break
	}
	// everything after the cut is dropped; inline boxes keep their fragment
	kept := make([dynamic]Frag, 0, len(lb.frags), context.temp_allocator)
	for f, i in lb.frags {
		if i < cut_at || f.kind == .Box { append(&kept, f) }
	}
	clear(&lb.frags)
	append(&lb.frags, ..kept[:])
	fi := &c.l.fonts[efi]
	append(&lb.frags, Frag{kind = .Ellipsis, box = NONE, item = -1, fi = efi, x = pen, w = ew, text = "\u2026", baseline = baseline, y = baseline - fi.ascent, h = fi.ascent + fi.descent})
}

@(private)
place_pending_floats :: proc(lb: ^Line_Builder) {
	if len(lb.pending_floats) == 0 { return }
	for k in lb.pending_floats { place_float(lb.c, k, lb.bi, lb.cw, lb.fc, content_top(lb.fc) + lb.y) }
	clear(&lb.pending_floats)
}

// A float met in the line: placed at the top of the current line when it fits beside what is already there, else
// after the line (§9.5.1 rule 8 / CSS 2.1 §9.5: "a float is placed as high as possible").
@(private)
line_float :: proc(lb: ^Line_Builder, k: i32) {
	c := lb.c
	pending_w: f32
	for &s in lb.unit { pending_w += s.w }
	if len(lb.pending_floats) == 0 {
		// lay it out to know its width (cached for the placement)
		resolve_box_model(c, &c.l.boxes[k], lb.cw)
		kb := &c.l.boxes[k]
		w: f32
		if kb.kind == .Replaced {
			w = replaced_size(c, k, lb.cw, -1).x
		} else if kb.kind == .Table {
			w = table_width(c, k, lb.cw, lb.cw - mg_w(kb))
		} else if spec, ok := to_border_w(c, kb, kb.cs.width, lb.cw); ok {
			w = clamp_w(c, kb, spec, lb.cw)
		} else {
			w = clamp_w(c, kb, shrink_to_fit(c, k, lb.cw - mg_w(kb)), lb.cw)
		}
		kb = &c.l.boxes[k]
		mw := w + mg_w(kb)
		if lb.pen + pending_w + mw <= lb.right - lb.left + 0.01 || (lb.empty && len(lb.unit) == 0) {
			place_float(c, k, lb.bi, lb.cw, lb.fc, content_top(lb.fc) + lb.y)
			lb_band(lb)
			return
		}
	}
	append(&lb.pending_floats, k)
}

// Width an atomic inline takes on the line (margin box) after laying it out.
@(private)
layout_atomic :: proc(c: ^Ctx, k: i32, cw: f32) -> f32 {
	resolve_box_model(c, &c.l.boxes[k], cw)
	kb := &c.l.boxes[k]
	if kb.auto_l { kb.margin[3] = 0 }
	if kb.auto_r { kb.margin[1] = 0 }
	if kb.auto_t { kb.margin[0] = 0 }
	if kb.auto_b { kb.margin[2] = 0 }
	w: f32
	if kb.kind == .Replaced {
		w = replaced_size(c, k, cw, -1).x
	} else if kb.kind == .Table {
		w = table_width(c, k, cw, cw - mg_w(kb))
	} else if spec, ok := to_border_w(c, kb, kb.cs.width, cw); ok {
		w = clamp_w(c, kb, spec, cw)
	} else {
		#partial switch kb.cs.width.kind {
		case .Min_Content: w = intrinsic(c, k)[0]
		case .Max_Content: w = intrinsic(c, k)[1]
		case: w = shrink_to_fit(c, k, cw - mg_w(kb))
		}
		kb = &c.l.boxes[k]
		w = clamp_w(c, kb, w, cw)
	}
	layout_contents(c, k, w, -1, -1, nil)
	kb = &c.l.boxes[k]
	return w + mg_w(kb)
}

// Lays out the inline formatting context rooted at `bi` (content width `cw`). Returns the content height, whether
// it is empty (no line boxes: margins collapse through it) and the bottom margin of a block-in-inline that ends it (not
// in the height).
@(private)
layout_ifc :: proc(c: ^Ctx, bi: i32, cw: f32, fc: ^Flow_Ctx) -> (f32, bool, f32) {
	b := &c.l.boxes[bi]
	// a re-layout replaces the previous result; when it was the last one made, its storage is reused
	if b.lines[1] > b.lines[0] {
		first_frag := c.l.lines[b.lines[0]].frags[0]
		last_frag := c.l.lines[b.lines[1] - 1].frags[1]
		if int(b.lines[1]) == len(c.l.lines) {
			if int(last_frag) == len(c.l.frags) { resize(&c.l.frags, int(first_frag)) } else { c.l.inc.dead_frags += int(last_frag - first_frag) }
			resize(&c.l.lines, int(b.lines[0]))
		} else {
			c.l.inc.dead_lines += int(b.lines[1] - b.lines[0])
			c.l.inc.dead_frags += int(last_frag - first_frag)
		}
	}
	b.lines = {}
	b.baseline, b.last_baseline = -1, -1
	if b.items[1] <= b.items[0] { return 0, true, 0 }
	if c.pre != nil {
		if h, empty, ok := pre_adopt(c, bi, cw, fc); ok { return h, empty, 0 }   // (simple contexts: no block inside)
	}
	out, lines, h, empty, trail := ifc_build(c, bi, cw, fc)
	ifc_publish(c, bi, out, lines)
	return h, empty, trail
}

// Line building of the inline formatting context `bi` at content width `cw`: its fragments (lines refer to them from 0)
// and lines, in buffers of the pass that stay valid until the next context of the same nesting level is built.
@(private)
// `trail`: the bottom margin of a block-in-inline that ends the context, left out of `h` (it collapses with what
// follows: layout_contents).
ifc_build :: proc(c: ^Ctx, bi: i32, cw: f32, fc: ^Flow_Ctx) -> (out: []Frag, lines: []Line, h: f32, empty: bool, trail: f32) {
	b := &c.l.boxes[bi]
	// working buffers, one set per nesting level of inline formatting contexts, reused for the whole pass
	if c.lb_depth >= len(c.lb_bufs) {
		nb := new(LB_Buffers, context.temp_allocator)
		nb^ = LB_Buffers{
			frags = make([dynamic]Frag, 0, 32, context.temp_allocator), lines = make([dynamic]Line, 0, 8, context.temp_allocator),
			out = make([dynamic]Frag, 0, 64, context.temp_allocator), open = make([dynamic]Open_Box, 0, 4, context.temp_allocator),
			unit = make([dynamic]Seg, 0, 8, context.temp_allocator), pending_floats = make([dynamic]i32, 0, 2, context.temp_allocator),
			pending_abs = make([dynamic]Pending_Abs, 0, 2, context.temp_allocator), groups = make([dynamic]Align_Group, 0, 2, context.temp_allocator),
			segs = make([dynamic]Seg, 0, 64, context.temp_allocator),
		}
		append(&c.lb_bufs, nb)
	}
	bufs := c.lb_bufs[c.lb_depth]
	c.lb_depth += 1
	defer c.lb_depth -= 1
	clear(&bufs.frags); clear(&bufs.lines); clear(&bufs.out); clear(&bufs.open); clear(&bufs.unit)
	clear(&bufs.pending_floats); clear(&bufs.pending_abs); clear(&bufs.groups)
	lb := Line_Builder{
		c = c, bi = bi, cs = b.cs, cw = cw, fc = fc, cx = content_x(b), cy = content_y(b), root_fi = b.fi, first = true,
		frags = bufs.frags, lines = bufs.lines, out = bufs.out, open = bufs.open, unit = bufs.unit,
		pending_floats = bufs.pending_floats, pending_abs = bufs.pending_abs, groups = bufs.groups,
	}
	// the buffers may have grown: keep them for the next context at this level
	defer {
		bufs.frags, bufs.lines, bufs.out, bufs.open, bufs.unit = lb.frags, lb.lines, lb.out, lb.open, lb.unit
		bufs.pending_floats, bufs.pending_abs, bufs.groups = lb.pending_floats, lb.pending_abs, lb.groups
	}
	if lb.root_fi < 0 { lb.root_fi = font_info(c, b.cs); c.l.boxes[bi].fi = lb.root_fi }
	lb.strut_h = c.l.fonts[lb.root_fi].line_h
	lb.bidi = bidi_paragraph(c, bi)
	start_line(&lb)
	blocks := false
	it := Seg_Iter{c = c, idx = b.items[0], end = b.items[1], cw = cw, bidi = lb.bidi}
	// the segments of an unchanged context measured by an earlier pass (a resize lays every paragraph out again at a
	// new width: its words keep their widths); else measured now and kept
	cached := cached_segs(c, bi)   // a range of Inc_State.segs: read by index (nested contexts may append to it)
	ci := cached[0]
	measuring := cached[1] <= cached[0]
	recording := measuring && c.inc != nil   // incremental passes only: a full pass (a page load) does not pay for it
	clear(&bufs.segs)
	for {
		s: Seg
		ok: bool
		if !measuring {
			if ci >= cached[1] { break }
			s, ok = c.l.inc.segs[ci], true
			ci += 1
			if s.kind == .Open {
				// edges of inline boxes resolve against the width: as next_seg does
				ib := &c.l.boxes[c.l.inline_items[s.item].box]
				resolve_box_model(c, ib, cw)
				s.w = ib.margin[3] + ib.border[3] + ib.padding[3]
			} else if s.kind == .Close {
				ib := &c.l.boxes[c.l.inline_items[s.item].box]
				s.w = ib.margin[1] + ib.border[1] + ib.padding[1]
			}
		} else {
			s, ok = next_seg(&it)
			if !ok { break }
			if recording { append(&bufs.segs, s) }
		}
		switch s.kind {
		case .Text, .Space, .Tab, .Open, .Close:
			append(&lb.unit, s)
			if s.brk { commit_unit(&lb, true) }
		case .Atomic:
			if s.brk { commit_unit(&lb, true) }
			k := c.l.inline_items[s.item].box
			s2 := s
			s2.w = layout_atomic(c, k, cw)
			append(&lb.unit, s2)
			if s.brk { commit_unit(&lb, true) }
		case .Float:
			line_float(&lb, c.l.inline_items[s.item].box)
		case .Abs:
			pw: f32
			for &u in lb.unit { pw += u.w }
			append(&lb.pending_abs, Pending_Abs{c.l.inline_items[s.item].box, lb.pen + pw})
		case .Break:
			commit_unit(&lb, false)
			lb.content = true
			lb.at_break = true
			finish_line(&lb, true, false)
			lb.at_break = false
		case .Block:
			commit_unit(&lb, false)
			if !lb.empty || lb.content { finish_line(&lb, true, false) }
			block_in_inline(&lb, c.l.inline_items[s.item].box)
			blocks = true
		}
	}
	commit_unit(&lb, false)
	if !lb.empty || lb.content || len(lb.pending_abs) > 0 || len(lb.pending_floats) > 0 { finish_line(&lb, true, true) }
	if recording {
		// a layout thread hands them back: kept by the UI thread if the result is taken (pre_adopt)
		if c.segs_out != nil { append(c.segs_out, ..bufs.segs[:]) } else { keep_segs(c, bi, bufs.segs[:]) }
	}
	h = lb.y
	if blocks && lb.block_margin != 0 && lb.block_end == lb.y && len(lb.lines) == lb.lines_at_block {
		h -= lb.block_margin
		trail = lb.block_margin
	}
	return lb.out[:], lb.lines[:], h, !lb.any_line && !blocks, trail
}

// The lines and fragments of context `bi` join the layout's (contiguous); its inline boxes take the union of their
// fragments. `out` and `lines` are left as they are (a pre-built context may be published again).
@(private)
ifc_publish :: proc(c: ^Ctx, bi: i32, out: []Frag, lines: []Line) {
	base := i32(len(c.l.frags))
	append(&c.l.frags, ..out)
	l0 := i32(len(c.l.lines))
	for ln in lines {
		ln2 := ln
		ln2.frags += base
		append(&c.l.lines, ln2)
	}
	ifc_settle(c, bi, {l0, i32(len(c.l.lines))})
}

// Context `bi` takes the lines `lines` of Layout.lines (their fragments are contiguous): baselines, and the union of
// the fragments of each of its inline boxes.
@(private)
ifc_settle :: proc(c: ^Ctx, bi: i32, lines: [2]i32) {
	b := &c.l.boxes[bi]
	b.lines = lines
	if b.lines[1] <= b.lines[0] { return }
	fl := &c.l.lines[b.lines[0]]
	ll := &c.l.lines[b.lines[1] - 1]
	b.baseline = fl.y + fl.baseline
	b.last_baseline = ll.y + ll.baseline
	f0, f1 := fl.frags[0], ll.frags[1]
	// inline boxes: the union of their fragments (positioning, queries)
	for i in f0 ..< f1 {
		f := &c.l.frags[i]
		if f.kind != .Box { continue }
		ib := &c.l.boxes[f.box]
		r := Rect{{f.x, f.y}, {f.x + f.w, f.y + f.h}}
		if ib.tmp_al != -2 {
			ib.pos, ib.size = r.min, r.max - r.min
			ib.tmp_al = -2
		} else {
			u := rect_union(Rect{ib.pos, ib.pos + ib.size}, r)
			ib.pos, ib.size = u.min, u.max - u.min
		}
	}
	for i in f0 ..< f1 {
		f := &c.l.frags[i]
		if f.kind == .Box { c.l.boxes[f.box].tmp_al = -1 }
	}
}

// A block-level box inside an inline box (CSS 2.1 §9.2.1.1): it takes a line of its own, the full width.
@(private)
block_in_inline :: proc(lb: ^Line_Builder, k: i32) {
	c := lb.c
	resolve_box_model(c, &c.l.boxes[k], lb.cw)
	kb := &c.l.boxes[k]
	if kb.auto_t { kb.margin[0] = 0 }
	if kb.auto_b { kb.margin[2] = 0 }
	block_width(c, k, lb.cw, lb.cw)
	kb = &c.l.boxes[k]
	w := kb.size.x
	top := lb.y + kb.margin[0]
	// first in its context: it sits in an anonymous block whose top collapses with the context's, so its top margin
	// joins the margins still open above (CSS 2.1 §9.2.1.1, §8.3.1)
	leading := lb.y == 0 && !lb.any_line && len(lb.lines) == 0 && lb.fc != nil && lb.fc.open != nil
	if leading {
		strut_add(lb.fc.open, kb.margin[0])
		top = 0
	} else if lb.block_end == lb.y && lb.any_line && len(lb.lines) == lb.lines_at_block {
		// right after another block-in-inline (no line between): the two margins collapse
		s: Strut
		strut_add(&s, lb.block_margin)
		strut_add(&s, kb.margin[0])
		top = lb.y - lb.block_margin + strut_value(s)
	}
	res: Result
	if .Bfc in kb.flags {
		res = layout_contents(c, k, w, -1, -1, nil)
	} else {
		cfc := Flow_Ctx{bfc = lb.fc.bfc, x = lb.fc.x + kb.margin[3] + content_x(kb), y = content_top(lb.fc) + top + content_y(kb)}
		// ... and its own first child's margins too, when nothing separates them
		if leading && collapses_top(kb) { cfc.y, cfc.open = lb.fc.y, lb.fc.open }
		res = layout_contents(c, k, w, -1, -1, &cfc)
	}
	kb = &c.l.boxes[k]
	kb.pos = {lb.cx + kb.margin[3], lb.cy + top + kb.pre_h}
	// its bottom margin with its last child's (when they collapse, layout_contents leaves the child's out of res.h)
	bottom := res.end
	strut_add(&bottom, kb.margin[2])
	lb.y = top + kb.pre_h + res.h + strut_value(bottom)
	lb.block_margin, lb.block_end, lb.lines_at_block = strut_value(bottom), lb.y, len(lb.lines)
	lb.first = false
	lb.any_line = true
	start_line(lb)
}

// Absolutely positioned boxes whose containing block is an inline box of this context: laid out once its fragments
// are known.
@(private)
layout_inline_abs :: proc(c: ^Ctx, bi: i32) {
	b := &c.l.boxes[bi]
	for i in b.items[0] ..< b.items[1] {
		it := &c.l.inline_items[i]
		if it.kind == .Open && c.l.boxes[it.box].abs_first != NONE { layout_abs_list(c, it.box) }
	}
}

////////////////////////////////
// Intrinsic widths of an inline formatting context

@(private)
ifc_intrinsic :: proc(c: ^Ctx, bi: i32) -> [2]f32 {
	b := &c.l.boxes[bi]
	mn, mx: f32
	unit, line, tail: f32
	if b.cs.text_indent.kind == .Px { line = b.cs.text_indent.v * c.scale; unit = line }
	it := Seg_Iter{c = c, idx = b.items[0], end = b.items[1], cw = 0}
	end_unit :: proc(mn, unit: ^f32) { mn^ = max(mn^, unit^); unit^ = 0 }
	for {
		s, ok := next_seg(&it)
		if !ok { break }
		switch s.kind {
		case .Text, .Open, .Close:
			unit += s.w
			line += s.w
			if s.kind == .Text { tail = 0 }
			if s.kind == .Text && s.breakable {
				// may break anywhere: its widest character is what cannot be broken
				itm := &c.l.inline_items[s.item]
				widest: f32
				for i := int(s.start); i < int(s.end); {
					_, n := utf8.decode_rune_in_string(itm.text[i:])
					widest = max(widest, text_width(c, itm.fi, itm.cs, itm.text[i:i + n]))
					i += n
				}
				unit = unit - s.w + widest
				end_unit(&mn, &unit)
			}
			if s.brk { end_unit(&mn, &unit) }
		case .Space:
			line += s.w
			if s.hang { tail += s.w } else { tail = 0 }
			if s.brk { unit = max(unit, 0); end_unit(&mn, &unit) } else { unit += s.w }
		case .Tab:
			tw := tab_interval(c, &c.l.inline_items[s.item])
			line += tw
			unit += tw
			tail = 0
			if s.brk { end_unit(&mn, &unit) }
		case .Atomic, .Float:
			k := c.l.inline_items[s.item].box
			in2 := intrinsic(c, k)
			m := intrinsic_margins(c, k)
			if s.kind == .Atomic && !s.brk {
				unit += in2[0] + m
			} else {
				end_unit(&mn, &unit)
				mn = max(mn, in2[0] + m)
			}
			line += in2[1] + m
			tail = 0
		case .Abs:
		case .Break:
			end_unit(&mn, &unit)
			mx = max(mx, line - tail)
			line, tail = 0, 0
		case .Block:
			end_unit(&mn, &unit)
			mx = max(mx, line - tail)
			line, tail = 0, 0
			k := c.l.inline_items[s.item].box
			in2 := intrinsic(c, k)
			m := intrinsic_margins(c, k)
			mn = max(mn, in2[0] + m)
			mx = max(mx, in2[1] + m)
		}
	}
	end_unit(&mn, &unit)
	mx = max(mx, line - tail)
	return {mn, max(mx, mn)}
}
