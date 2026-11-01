package layout

import "core:math"
import "core:unicode/utf8"
import "wb:base"
import "wb:style"

// Writing modes (CSS Writing Modes 4). The layout code knows one geometry: x is the inline axis, y the block axis. A box in
// a vertical writing mode is laid out in that geometry too, in the logical coordinates of its "frame", and turned into
// physical coordinates once the block layout of the pass is over: everything else (finishing, the display list, hit testing,
// queries) sees physical boxes.
//
//   * The frame of a box is the writing mode of its containing block (`frame_of`): its margins, borders, padding, size and
//     position are in that frame. Its content is in the frame of its own writing mode: a box whose own mode differs is a
//     frame root (Box_Fx.Frame_Root), an independent formatting context, and `frame_layout_contents` turns it from one frame
//     to the other for the time of its content.
//   * The style records a box points to during layout are copies with the physical properties named as their logical
//     equivalents for its frame (`transposed`: `height` holds what `width` says when the block axis is horizontal, and so
//     on). What is already flow-relative stays: flex-direction, grid-template-columns, align-*, justify-*, text-align.
//   * Before the block layout `frames_to_logical` puts every box back in its frame, exactly as it was (what is cached in
//     the boxes, lines and fragments is logical: the layout cache holds across passes), and after it `frames_to_physical`
//     saves what it changes and makes it physical.
//
// A page with no vertical writing mode and no columns never comes here (Layout.frames_on), nor does it pay for it but a test of
// that flag or of one byte of a box per block.

@(private)
is_vert :: #force_inline proc "contextless" (w: style.Writing_Mode) -> bool { return w != .Horizontal_Tb }

@(private)
Frame_Saved :: struct {
	box:      i32,
	pos, size: Vec2,
	margin, border, padding: [4]f32,
	marker_pos: Vec2,
}

@(private)
Frame_Saved_Ifc :: struct {
	box:      i32,
	lines:    [2]i32,   // range of Layout.frame_lines
	frags:    [2]i32,   // range of Layout.frame_frags
}

@(private)
Frame_Saved_Frag :: struct {
	x, y, w, h, baseline: f32,
	flags: bit_set[Frag_Flag; u8],
}

@(private)
Frame_Cs_Key :: struct { cs: ^style.Computed, wm: style.Writing_Mode }

@(private)
frames_reset :: proc(l: ^Layout) {
	l.frames_on = false
	clear(&l.frame_saved)
	clear(&l.frame_ifcs)
	clear(&l.frame_lines)
	clear(&l.frame_frags)
	for _, &r in l.mc_records { delete(r.frags); delete(r.rules) }
	clear(&l.mc_records)
	clear(&l.flow_frags)
}

@(private)
frames_destroy :: proc(l: ^Layout) {
	frames_reset(l)
	delete(l.frame_saved)
	delete(l.frame_ifcs)
	delete(l.frame_lines)
	delete(l.frame_frags)
	delete(l.mc_records)
	delete(l.flow_frags)
}

// The box whose content a box is laid out in: its containing block in the sense of frames.
@(private)
frame_parent :: #force_inline proc(l: ^Layout, b: ^Box) -> i32 {
	p := .Abs in b.flags ? b.cb : b.parent
	if p == NONE { return NONE }
	pb := &l.boxes[p]
	if pb.kind == .Inline && pb.ifc_root != NONE { return pb.ifc_root }
	return p
}

// The writing mode of the frame of box `bi`.
@(private)
frame_of :: proc(l: ^Layout, bi: i32) -> style.Writing_Mode {
	p := frame_parent(l, &l.boxes[bi])
	return p == NONE ? .Horizontal_Tb : l.boxes[p].wm
}

// A frame root whose block axis is its frame's inline axis.
@(private)
frame_orthogonal :: proc(l: ^Layout, bi: i32) -> bool {
	return is_vert(l.boxes[bi].wm) != is_vert(frame_of(l, bi))
}

// The element's style with physical properties under the names of what they are for frame `wm`.
@(private)
transposed :: proc(c: ^Ctx, cs: ^style.Computed, wm: style.Writing_Mode) -> ^style.Computed {
	if !is_vert(wm) { return cs }
	key := Frame_Cs_Key{cs, wm}
	if s, ok := c.frame_cs[key]; ok { return s }
	s := new_clone(cs^, context.temp_allocator)
	sides := style.flow_sides(wm, false)
	for side in style.Side {
		p := sides[side]
		s.margin[side] = cs.margin[p]
		s.padding[side] = cs.padding[p]
		s.border_width[side] = cs.border_width[p]
		s.border_style[side] = cs.border_style[p]
		s.inset[side] = cs.inset[p]
	}
	s.width, s.height = cs.height, cs.width
	s.min_width, s.min_height = cs.min_height, cs.min_width
	s.max_width, s.max_height = cs.max_height, cs.max_width
	s.overflow_x, s.overflow_y = cs.overflow_y, cs.overflow_x
	if cs.aspect_ratio > 0 { s.aspect_ratio = 1 / cs.aspect_ratio }
	c.frame_cs[key] = s
	return s
}

// Sides given in frame `from` as the same sides named in frame `to` (both in the order top, right, bottom, left).
@(private)
rotate_sides :: proc(v: [4]f32, from, to: style.Writing_Mode) -> (out: [4]f32) {
	fs, ts := style.flow_sides(from, false), style.flow_sides(to, false)
	phys: [style.Side]f32
	for s in style.Side { phys[fs[s]] = v[int(s)] }
	for s in style.Side { out[int(s)] = phys[ts[s]] }
	return
}

// The writing mode of the viewport: the body's when there is one, else the root element's (CSS Writing Modes 4 §8). The root
// element takes it too.
@(private)
principal_mode :: proc(c: ^Ctx) -> style.Writing_Mode {
	if cs := style.style_of(c.st, c.body_el); cs != nil { return cs.writing_mode }
	if cs := style.style_of(c.st, c.root_el); cs != nil { return cs.writing_mode }
	return .Horizontal_Tb
}

// Every box back in the logical coordinates of its frame (exactly what the last pass left: see frames_to_physical), and the style
// records of the frame.
@(private)
frames_to_logical :: proc(c: ^Ctx) {
	l := c.l
	for &s in l.frame_saved {
		b := &l.boxes[s.box]
		if .Dead in b.flags { continue }
		b.pos, b.size, b.margin, b.border, b.padding, b.marker_pos = s.pos, s.size, s.margin, s.border, s.padding, s.marker_pos
	}
	for &s in l.frame_ifcs {
		b := &l.boxes[s.box]
		if .Dead in b.flags || b.lines[1] <= b.lines[0] { continue }
		li := s.lines[0]
		fi := s.frags[0]
		for k in b.lines[0] ..< b.lines[1] {
			ln := &l.lines[k]
			ln.y = l.frame_lines[li]
			li += 1
			for fk in ln.frags[0] ..< ln.frags[1] {
				f := &l.frags[fk]
				sf := &l.frame_frags[fi]
				f.x, f.y, f.w, f.h, f.baseline, f.flags = sf.x, sf.y, sf.w, sf.h, sf.baseline, sf.flags
				fi += 1
			}
		}
	}
	clear(&l.frame_saved)
	clear(&l.frame_ifcs)
	clear(&l.frame_lines)
	clear(&l.frame_frags)

	c.frame_cs = make(map[Frame_Cs_Key]^style.Computed, 64, context.temp_allocator)
	c.phys_cs = make([]^style.Computed, len(l.boxes), context.temp_allocator)
	c.frame_entered, c.frame_intr = NONE, NONE
	root_wm := principal_mode(c)
	l.boxes[0].wm = root_wm
	if ri := box_index(l, c.root_el); ri != NONE { l.boxes[ri].wm = root_wm }
	// (a parent has a lower index than its children, a partial rebuild's boxes too: the frame of a box is known when it is reached)
	for i in 1 ..< i32(len(l.boxes)) {
		b := &l.boxes[i]
		if .Dead in b.flags { continue }
		f := frame_of(l, i)
		// no own content to turn: these take their frame's mode
		if b.kind == .Inline || b.kind == .Replaced { b.wm = f }
		if f != b.wm {
			b.fx += {.Frame_Root}
			b.flags += {.Bfc}
		} else {
			b.fx -= {.Frame_Root}
		}
		c.phys_cs[i] = b.cs
		if is_vert(f) && b.cs != nil { b.cs = transposed(c, b.cs, f) }
	}
	c.vp_phys = c.vp
	if is_vert(root_wm) { c.vp = {c.vp.y, c.vp.x} }
}

// Inline size available to an orthogonal box when its frame's block size is not known: the viewport's size in that axis
// (CSS Writing Modes 4 §7.3).
@(private)
frame_fallback_inline :: proc(c: ^Ctx, pf: style.Writing_Mode) -> f32 {
	return is_vert(pf) == is_vert(c.l.boxes[0].wm) ? c.vp.y : c.vp.x
}

// The box in the frame of its own content; the values of its frame's are given back by frame_leave.
@(private)
Frame_Entry :: struct { cs: ^style.Computed, border, padding: [4]f32 }

@(private)
frame_enter :: proc(c: ^Ctx, bi: i32, pf: style.Writing_Mode) -> Frame_Entry {
	b := &c.l.boxes[bi]
	e := Frame_Entry{b.cs, b.border, b.padding}
	b.cs = transposed(c, c.phys_cs[bi], b.wm)
	b.border = rotate_sides(b.border, pf, b.wm)
	b.padding = rotate_sides(b.padding, pf, b.wm)
	return e
}

@(private)
frame_leave :: proc(c: ^Ctx, bi: i32, e: Frame_Entry) {
	b := &c.l.boxes[bi]
	b.cs, b.border, b.padding = e.cs, e.border, e.padding
}

// The inline size (its frame's block axis) of an orthogonal box whose block size is `auto` there, or fit-content in `avail`.
// Called inside the box's own frame.
@(private)
frame_fit_inline :: proc(c: ^Ctx, bi: i32, avail: f32) -> f32 {
	c.frame_intr = bi
	in2 := intrinsic_compute(c, bi, false)
	c.frame_intr = NONE
	return min(max(in2[0], avail), in2[1])
}

// layout_contents of a frame root: `w`, `cb_h`, `forced_h` and the result are in its frame; the content in its own.
@(private)
frame_layout_contents :: proc(c: ^Ctx, bi: i32, w, cb_h, forced_h: f32) -> Result {
	b := &c.l.boxes[bi]
	pf := frame_of(c.l, bi)
	orth := is_vert(b.wm) != is_vert(pf)
	own_w, own_cb, own_forced := w, cb_h, forced_h
	spec_ok := false
	if orth {
		own_cb, own_forced = -1, w
		if forced_h >= 0 {
			own_w, spec_ok = forced_h, true
		} else if v, ok := specified_height(c, b, cb_h); ok {
			own_w, spec_ok = clamp_h(c, b, v, cb_h), true
		}
	}
	margin_h := mg_h(b)
	e := frame_enter(c, bi, pf)
	if orth && !spec_ok {
		avail := cb_h >= 0 ? cb_h : frame_fallback_inline(c, pf)
		own_w = frame_fit_inline(c, bi, avail - margin_h)
	}
	c.frame_entered = bi
	r := layout_contents(c, bi, own_w, own_cb, own_forced, nil)
	frame_leave(c, bi, e)
	b = &c.l.boxes[bi]
	if orth && !spec_ok {
		// (its frame's min-height and max-height: laid out again when they change the answer)
		v := clamp_h(c, b, own_w, cb_h)
		if v != own_w {
			e2 := frame_enter(c, bi, pf)
			c.frame_entered = bi
			layout_contents(c, bi, v, own_cb, own_forced, nil)
			frame_leave(c, bi, e2)
			own_w = v
		}
	}
	b = &c.l.boxes[bi]
	if orth {
		b.size = {w, own_w}
		b.baseline, b.last_baseline = -1, -1
		return Result{h = own_w}
	}
	b.size = {w, r.h}
	return Result{h = r.h}
}

// The size of an orthogonal box along its frame's inline axis: its own block size, laid out at the inline size it would get.
@(private)
frame_intrinsic :: proc(c: ^Ctx, bi: i32) -> [2]f32 {
	b := &c.l.boxes[bi]
	pf := frame_of(c.l, bi)
	own_w: f32
	spec_ok := false
	if v, ok := specified_height(c, b, -1); ok { own_w, spec_ok = clamp_h(c, b, v, -1), true }
	margin_h := mg_h(b)
	e := frame_enter(c, bi, pf)
	if !spec_ok { own_w = frame_fit_inline(c, bi, frame_fallback_inline(c, pf) - margin_h) }
	c.frame_entered = bi
	r := layout_contents(c, bi, own_w, -1, -1, nil)
	frame_leave(c, bi, e)
	return {r.h, r.h}
}

// Where a point of `from`'s frame given relative to box `from` lies relative to `ref`, across the frames between them (the
// static position of an absolutely positioned box whose containing block is outside of a frame root).
@(private)
frame_point_between :: proc(c: ^Ctx, from, ref: i32, p: Vec2) -> (Vec2, bool) {
	cur := from
	q := p
	for steps := 0; steps < OFFSET_WALK_MAX_STEPS && cur != NONE; steps += 1 {
		if cur == ref { return q, true }
		b := &c.l.boxes[cur]
		if .Multicol in b.fx { q = multicol_flow_to_visual(c.l, cur, q) }
		if b.kind != .Inline {
			if .Frame_Root in b.fx {
				pf := frame_of(c.l, cur)
				q = frame_point_up(q, b.size, b.wm, pf)
			}
			q += b.pos
		}
		cur = b.pos_ref
	}
	return q, false
}

// A point relative to a frame root's border box of size `size` (given in its frame `pf`), from its own frame `own` to `pf`.
@(private)
frame_point_up :: proc(q: Vec2, size: Vec2, own, pf: style.Writing_Mode) -> Vec2 {
	// physical size of the box
	pw, ph := size.x, size.y
	if is_vert(pf) { pw, ph = size.y, size.x }
	phys := logical_to_physical_point(q, pw, ph, own)
	return physical_to_logical_point(phys, pw, ph, pf)
}

@(private)
logical_to_physical_point :: proc(q: Vec2, pw, ph: f32, wm: style.Writing_Mode) -> Vec2 {
	switch wm {
	case .Horizontal_Tb: return q
	case .Vertical_Rl, .Sideways_Rl: return {pw - q.y, q.x}
	case .Vertical_Lr: return {q.y, q.x}
	case .Sideways_Lr: return {q.y, ph - q.x}
	}
	return q
}

@(private)
physical_to_logical_point :: proc(q: Vec2, pw, ph: f32, wm: style.Writing_Mode) -> Vec2 {
	switch wm {
	case .Horizontal_Tb: return q
	case .Vertical_Rl, .Sideways_Rl: return {q.y, pw - q.x}
	case .Vertical_Lr: return {q.y, q.x}
	case .Sideways_Lr: return {ph - q.y, q.x}
	}
	return q
}

// A rectangle (min, max in logical coordinates relative to a box of physical size pw x ph) in physical coordinates.
@(private)
logical_to_physical_rect :: proc(r: Rect, pw, ph: f32, wm: style.Writing_Mode) -> Rect {
	a := logical_to_physical_point(r.min, pw, ph, wm)
	b := logical_to_physical_point(r.max, pw, ph, wm)
	return Rect{{min(a.x, b.x), min(a.y, b.y)}, {max(a.x, b.x), max(a.y, b.y)}}
}

// A rectangle in physical coordinates relative to a box of physical size pw x ph from its logical frame position.
@(private)
frag_to_physical :: proc(f: ^Frag, pw, ph: f32, wm: style.Writing_Mode) {
	r := logical_to_physical_rect(Rect{{f.x, f.y}, {f.x + f.w, f.y + f.h}}, pw, ph, wm)
	bp := logical_to_physical_point({0, f.baseline}, pw, ph, wm).x
	f.x, f.y, f.w, f.h = r.min.x, r.min.y, r.max.x - r.min.x, r.max.y - r.min.y
	f.baseline = bp
	f.flags += {.Vertical}
	if wm == .Sideways_Lr {
		f.flags += {.Flip}
		// the start edge of the fragment is its bottom edge
		left, right := .Left_Edge in f.flags, .Right_Edge in f.flags
		f.flags -= {.Left_Edge, .Right_Edge}
		if left { f.flags += {.Right_Edge} }
		if right { f.flags += {.Left_Edge} }
	}
}

// After the block layout: every box in physical coordinates, what is changed saved for frames_to_logical. A box of size (w, h) in
// a frame takes its physical place from the physical size of the box it is positioned against, known first (tree order).
@(private)
frames_to_physical :: proc(c: ^Ctx) {
	l := c.l
	if is_vert(l.boxes[0].wm) { c.vp = c.vp_phys; l.boxes[0].size = c.vp }
	order := preorder(l)
	for x in order {
		if x == 0 { continue }
		b := &l.boxes[x]
		if c.phys_cs != nil && int(x) < len(c.phys_cs) && c.phys_cs[x] != nil { b.cs = c.phys_cs[x] }
		f := frame_of(l, x)
		own := b.wm
		if !is_vert(f) && !is_vert(own) { continue }
		if is_vert(f) || .List_Item in b.flags {
			append(&l.frame_saved, Frame_Saved{x, b.pos, b.size, b.margin, b.border, b.padding, b.marker_pos})
		}
		if is_vert(f) {
			log_pos, log_size := b.pos, b.size
			ref_w, ref_h: f32
			if b.pos_ref != NONE { ref_w, ref_h = l.boxes[b.pos_ref].size.x, l.boxes[b.pos_ref].size.y }
			b.size = {log_size.y, log_size.x}
			b.margin = rotate_sides(b.margin, f, .Horizontal_Tb)
			b.border = rotate_sides(b.border, f, .Horizontal_Tb)
			b.padding = rotate_sides(b.padding, f, .Horizontal_Tb)
			switch f {
			case .Horizontal_Tb:
			case .Vertical_Rl, .Sideways_Rl: b.pos = {ref_w - (log_pos.y + log_size.y), log_pos.x}
			case .Vertical_Lr: b.pos = {log_pos.y, log_pos.x}
			case .Sideways_Lr: b.pos = {log_pos.y, ref_h - (log_pos.x + log_size.x)}
			}
		}
		if !is_vert(own) { continue }
		// the marker's (start, baseline): the baseline as x, the start as y
		if .List_Item in b.flags && b.marker_w != 0 { b.marker_pos = logical_to_physical_point(b.marker_pos, b.size.x, b.size.y, own) }
		if .Ifc in b.flags && b.lines[1] > b.lines[0] {
			rec := Frame_Saved_Ifc{box = x}
			rec.lines[0] = i32(len(l.frame_lines))
			rec.frags[0] = i32(len(l.frame_frags))
			for k in b.lines[0] ..< b.lines[1] {
				ln := &l.lines[k]
				append(&l.frame_lines, ln.y)
				ly := ln.y
				switch own {
				case .Horizontal_Tb:
				case .Vertical_Rl, .Sideways_Rl: ln.y = b.size.x - (ly + ln.h)
				case .Vertical_Lr, .Sideways_Lr:
				}
				for fk in ln.frags[0] ..< ln.frags[1] {
					fr := &l.frags[fk]
					append(&l.frame_frags, Frame_Saved_Frag{fr.x, fr.y, fr.w, fr.h, fr.baseline, fr.flags})
					frag_to_physical(fr, b.size.x, b.size.y, own)
				}
			}
			rec.lines[1] = i32(len(l.frame_lines))
			rec.frags[1] = i32(len(l.frame_frags))
			append(&l.frame_ifcs, rec)
		}
	}
	c.phys_cs = nil
}

////////////////////////////////
// Text

// How a font is used in a vertical line: Central is the central baseline of upright and mixed text (the line's ascent and
// descent are half of the face's height each); Sideways_Over_Right is text set sideways in a mode whose block-start side is on the left: the ascent
// of the rotated glyphs is on the side lines progress away from.
Font_Vmode :: enum u8 { None, Central, Sideways_Over_Right }

@(private)
font_vmode :: proc(cs: ^style.Computed) -> Font_Vmode {
	#partial switch cs.writing_mode {
	case .Horizontal_Tb, .Sideways_Rl, .Sideways_Lr: return .None
	case .Vertical_Rl: return cs.text_orientation == .Sideways ? .None : .Central
	case .Vertical_Lr: return cs.text_orientation == .Sideways ? .Sideways_Over_Right : .Central
	}
	return .None
}

@(private)
font_vmode_metrics :: proc(c: ^Ctx, info: ^Font_Info) {
	info.raw_ascent, info.raw_descent = info.ascent, info.descent
	switch info.vmode {
	case .None:
	case .Central:
		h := info.ascent + info.descent
		half := c.set.round_metrics ? math.floor(h * 0.5) : h * 0.5
		info.ascent, info.descent = h - half, half
	case .Sideways_Over_Right:
		info.ascent, info.descent = info.descent, info.ascent
	}
}

// Characters set upright in `text-orientation: mixed` (UTR #50 classes U and Tu; those of class Tr turn with an alternate
// glyph from the `vert` feature when the face has one, and are upright here too).
vertical_upright :: proc(r: rune) -> bool {
	switch {
	case r >= 0x1100 && r <= 0x11FF: return true      // Hangul Jamo
	case r >= 0x2E80 && r <= 0x2FFF: return true      // CJK radicals, description characters
	case r >= 0x3000 && r <= 0x4DBF: return true      // CJK symbols, kana, bopomofo, Hangul compatibility, Kanbun, CJK A
	case r >= 0x4E00 && r <= 0x9FFF: return true      // CJK
	case r >= 0xA000 && r <= 0xA4CF: return true      // Yi
	case r >= 0xA960 && r <= 0xA97F: return true      // Hangul Jamo Extended-A
	case r >= 0xAC00 && r <= 0xD7FF: return true      // Hangul
	case r >= 0xE000 && r <= 0xFAFF: return true      // private use, CJK compatibility
	case r >= 0xFE10 && r <= 0xFE1F: return true      // vertical forms
	case r >= 0xFE30 && r <= 0xFE6F: return true      // CJK compatibility forms, small forms
	case r >= 0xFF00 && r <= 0xFF60: return true      // fullwidth forms
	case r >= 0xFFE0 && r <= 0xFFE7: return true      // fullwidth signs
	case r >= 0x1F000 && r <= 0x1FAFF: return true    // emoji, symbols
	case r >= 0x20000 && r <= 0x3FFFD: return true    // CJK supplementary planes
	case r == 0xA7 || r == 0xA9 || r == 0xAE || r == 0xB1 || r == 0xBC || r == 0xBD || r == 0xBE || r == 0xD7 || r == 0xF7: return true
	}
	return false
}

// Marks that stay with what comes before them: part of its upright cluster.
vertical_extends_cluster :: proc(r: rune) -> bool {
	return (r >= 0x0300 && r <= 0x036F) || r == 0x3099 || r == 0x309A || (r >= 0xFE00 && r <= 0xFE0F) || r == 0x200D || (r >= 0xE0100 && r <= 0xE01EF) || (r >= 0x1F3FB && r <= 0x1F3FF)
}

// The advance of a character cluster set upright: an em for what is drawn in an em box, else the face's height.
upright_advance :: proc(r: rune, size, raw_height: f32) -> f32 {
	return vertical_upright(r) ? size : raw_height
}

// The length of a piece of text along a vertical line.
@(private)
vertical_text_width :: proc(c: ^Ctx, fi: i32, cs: ^style.Computed, s: string) -> f32 {
	f := &c.l.fonts[fi]
	w: f32
	ls := cs.letter_spacing * c.scale
	pos := 0
	// (font_vmode is Central only for vertical-rl and vertical-lr with mixed or upright text)
	for {
		run, ok := next_vertical_run(s, pos, cs.text_orientation)
		if !ok { break }
		piece := s[run.start:run.end]
		if run.upright {
			r, _ := utf8.decode_rune_in_string(piece)
			w += upright_advance(r, f.size, f.raw_ascent + f.raw_descent) + ls
		} else {
			w += measure(c, fi, piece) + ls * f32(rune_count(piece))
		}
		pos = run.end
	}
	return w
}

// The length along a vertical line of the start `s` of a text item: as vertical_text_width, outside of a layout pass.
@(private)
vertical_item_length :: proc(l: ^Layout, it: ^Display_Item, fi: ^Font_Info, s: string, api: Text_Api) -> f32 {
	orient := it.cs.text_orientation
	if it.cs.writing_mode == .Sideways_Rl || it.cs.writing_mode == .Sideways_Lr { orient = .Sideways }
	if it.cs.text_combine_upright == .All { return s == it.text ? fi.size : 0 }
	ls := it.cs.letter_spacing * l.scale
	w: f32
	pos := 0
	for {
		run, ok := next_vertical_run(s, pos, orient)
		if !ok { break }
		piece := s[run.start:run.end]
		if run.upright {
			r, _ := utf8.decode_rune_in_string(piece)
			w += upright_advance(r, fi.size, fi.raw_ascent + fi.raw_descent) + ls
		} else {
			w += api.width(api.user, fi.font, fi.size, piece) + ls * f32(utf8.rune_count_in_string(piece))
		}
		pos = run.end
	}
	return w
}

// A run of a vertical line of text: consecutive characters set the same way.
Vertical_Run :: struct { upright: bool, start, end: int }

// The next run of `text` from byte `pos`: an upright run is one character cluster, a sideways run as long as it goes.
next_vertical_run :: proc(text: string, pos: int, orientation: style.Text_Orientation) -> (run: Vertical_Run, ok: bool) {
	if pos >= len(text) { return {}, false }
	run.start = pos
	i := pos
	first := true
	for i < len(text) {
		r, n := utf8.decode_rune_in_string(text[i:])
		up := orientation == .Upright || (orientation == .Mixed && vertical_upright(r))
		if first {
			run.upright = up
			i += n
			first = false
			continue
		}
		if run.upright {
			if !vertical_extends_cluster(r) { break }
		} else if up {
			break
		}
		i += n
	}
	run.end = i
	return run, true
}

_ :: base.NIL_HANDLE
