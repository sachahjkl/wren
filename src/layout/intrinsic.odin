package layout

import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:style"

// Intrinsic sizes (CSS Sizing 3 §5): min-content and max-content border-box widths. Percentages resolve against zero
// here, as the specification allows for cyclic percentages. Results are cached per box for the pass.

@(private)
intrinsic_pb :: proc(c: ^Ctx, b: ^Box) -> f32 {
	cs := b.cs
	return px_of(c, cs.padding[.Left], 0) + px_of(c, cs.padding[.Right], 0) + border_px(c, cs.border_width[.Left]) + border_px(c, cs.border_width[.Right])
}

@(private)
intrinsic_margins :: proc(c: ^Ctx, bi: i32) -> f32 {
	cs := c.l.boxes[bi].cs
	m: f32
	if cs.margin[.Left].kind == .Px { m += cs.margin[.Left].v * c.scale }
	if cs.margin[.Right].kind == .Px { m += cs.margin[.Right].v * c.scale }
	return m
}

@(private)
intrinsic_clamp :: proc(c: ^Ctx, b: ^Box, w, pb: f32) -> f32 {
	cs := b.cs
	r := w
	bb := cs.box_sizing == .Border_Box
	if cs.max_width.kind == .Px { mx := cs.max_width.v * c.scale; r = min(r, bb ? max(mx, pb) : mx + pb) }
	if cs.min_width.kind == .Px { mn := cs.min_width.v * c.scale; r = max(r, bb ? max(mn, pb) : mn + pb) }
	return max(r, pb)
}

intrinsic :: proc(c: ^Ctx, bi: i32) -> [2]f32 {
	b := &c.l.boxes[bi]
	if b.intr_ok { return b.intr }
	res := intrinsic_compute(c, bi, false)
	b = &c.l.boxes[bi]
	b.intr, b.intr_ok = res, true
	return res
}

// Min-content width of a box's content, ignoring its own `width` (the content size suggestion of flex items, CSS
// Flexbox §4.5). Border and padding included.
intrinsic_content_min :: proc(c: ^Ctx, bi: i32) -> f32 {
	b := &c.l.boxes[bi]
	if b.cs.width.kind != .Px { return intrinsic(c, bi)[0] }
	return intrinsic_compute(c, bi, true)[0]
}

@(private)
intrinsic_compute :: proc(c: ^Ctx, bi: i32, ignore_width: bool) -> [2]f32 {
	b := &c.l.boxes[bi]
	if !stack_ok(c) { return {} }
	cs := b.cs
	pb := intrinsic_pb(c, b)
	res: [2]f32
	fixed := cs.width.kind == .Px && b.kind != .Table && b.kind != .Cell && b.kind != .Inline && !ignore_width
	if fixed {
		v := cs.width.v * c.scale
		w := cs.box_sizing == .Border_Box ? max(v, pb) : v + pb
		res = {w, w}
	} else {
		switch b.kind {
		case .Replaced:
			w := replaced_size(c, bi, -1, -1).x
			res = {w, w}
		case .Block, .Cell, .Caption:
			if .Ifc in b.flags {
				in2 := ifc_intrinsic(c, bi)
				res = in2 + pb
			} else {
				mn, mx, floats: f32
				for ch := c.l.boxes[bi].first; ch != NONE; ch = c.l.boxes[ch].next {
					k := &c.l.boxes[ch]
					if .Abs in k.flags || k.kind == .Inline { continue }
					ci := intrinsic(c, ch)
					m := intrinsic_margins(c, ch)
					if .Float in c.l.boxes[ch].flags {
						if c.l.boxes[ch].cs.clear != .None { floats = 0 }
						floats += ci[1] + m
						mn = max(mn, ci[0] + m)
						mx = max(mx, floats)
						continue
					}
					floats = 0
					mn = max(mn, ci[0] + m)
					mx = max(mx, ci[1] + m)
				}
				res = {mn + pb, max(mx, mn) + pb}
			}
			b = &c.l.boxes[bi]
			if b.kind == .Cell && cs.width.kind == .Px {
				v := cs.width.v * c.scale
				w := cs.box_sizing == .Border_Box ? max(v, pb) : v + pb
				res = {max(res[0], w), max(res[0], w)}
			}
		case .Flex:
			res = flex_intrinsic(c, bi) + pb
		case .Table:
			res = table_intrinsic(c, bi)
		case .Inline, .Row_Group, .Row:
		}
	}
	b = &c.l.boxes[bi]
	if b.kind != .Table {
		res[0] = intrinsic_clamp(c, b, res[0], pb)
		res[1] = intrinsic_clamp(c, b, res[1], pb)
	}
	res[1] = max(res[1], res[0])
	return res
}

////////////////////////////////
// Replaced elements (CSS 2.1 §10.3.2, §10.6.2, CSS Sizing 4 aspect-ratio) and form controls

@(private)
attr_px :: proc(c: ^Ctx, h: base.Handle, name: string) -> (f32, bool) {
	v, ok := dom.get_attribute(c.d, h, name)
	if !ok { return 0, false }
	t := strings.trim_space(v)
	end := 0
	for end < len(t) && ((t[end] >= '0' && t[end] <= '9') || t[end] == '.') { end += 1 }
	if end == 0 { return 0, false }
	n, nok := strconv.parse_f64(t[:end])
	if !nok || n < 0 { return 0, false }
	return f32(n), true
}

@(private)
attr_int :: proc(c: ^Ctx, h: base.Handle, name: string, fallback: int) -> int {
	v, ok := dom.get_attribute(c.d, h, name)
	if !ok { return fallback }
	n := parse_int(v, fallback)
	return n > 0 ? n : fallback
}

// Natural size in device px (content box). has_w / has_h: the dimension is known.
@(private)
natural_size :: proc(c: ^Ctx, bi: i32) -> (w, h: f32, has_w, has_h: bool) {
	b := &c.l.boxes[bi]
	h_node := b.node
	n := dom.get(c.d, h_node)
	if n == nil { return }
	s := c.scale
	fi := b.fi >= 0 ? b.fi : font_info(c, b.cs)
	f := c.l.fonts[fi]
	char_w := measure(c, fi, "0")
	switch n.name {
	case "img":
		if c.replaced.intrinsic != nil {
			if iw, ih, ok := c.replaced.intrinsic(c.replaced.user, h_node); ok { return iw * s, ih * s, true, true }
		}
		aw, okw := attr_px(c, h_node, "width")
		ah, okh := attr_px(c, h_node, "height")
		if okw || okh { return aw * s, ah * s, okw, okh }
		return c.set.placeholder_w * s, c.set.placeholder_h * s, true, true
	case "canvas":
		aw, okw := attr_px(c, h_node, "width")
		ah, okh := attr_px(c, h_node, "height")
		return (okw ? aw : 300) * s, (okh ? ah : 150) * s, true, true
	case "iframe", "embed", "object", "video":
		if n.name == "video" && c.replaced.intrinsic != nil {
			if iw, ih, ok := c.replaced.intrinsic(c.replaced.user, h_node); ok { return iw * s, ih * s, true, true }
		}
		aw, okw := attr_px(c, h_node, "width")
		ah, okh := attr_px(c, h_node, "height")
		return (okw ? aw : c.set.embed_w) * s, (okh ? ah : c.set.embed_h) * s, true, true
	case "audio":
		return c.set.embed_w * s, f.line_h * 2, true, true
	case "meter": return 80 * s, f.size, true, true
	case "progress": return 160 * s, f.size, true, true
	case "textarea":
		cols := attr_int(c, h_node, "cols", c.set.textarea_cols)
		rows := attr_int(c, h_node, "rows", c.set.textarea_rows)
		return f32(cols) * char_w + c.set.scrollbar_width * s, f32(rows) * f.line_h, true, true
	case "select":
		widest: f32
		stack := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(c.d, ch).prev { append(&stack, ch) }
		for len(stack) > 0 {
			x := pop(&stack)
			xn := dom.get(c.d, x)
			if xn == nil || xn.kind != .Element { continue }
			if xn.name == "optgroup" {
				for ch := xn.last_child; ch != base.NIL_HANDLE; ch = dom.get(c.d, ch).prev { append(&stack, ch) }
				continue
			}
			if xn.name != "option" { continue }
			label := strings.trim_space(dom.text_content(c.d, x))
			if v, ok := dom.get_attribute(c.d, x, "label"); ok { label = v }
			widest = max(widest, measure(c, fi, label))
		}
		rows := 1
		if _, multi := dom.get_attribute(c.d, h_node, "multiple"); multi { rows = 4 }
		rows = attr_int(c, h_node, "size", rows)
		return widest + c.set.select_arrow * s, f32(rows) * f.line_h, true, true
	case "input":
		t, _ := dom.get_attribute(c.d, h_node, "type")
		t = strings.to_lower(strings.trim_space(t), context.temp_allocator)
		switch t {
		case "checkbox", "radio": return 13 * s, 13 * s, true, true
		case "range": return 129 * s, 16 * s, true, true
		case "color": return 44 * s, f.line_h, true, true
		case "button", "submit", "reset":
			label, ok := dom.get_attribute(c.d, h_node, "value")
			if !ok { label = t == "submit" ? "Submit" : (t == "reset" ? "Reset" : "") }
			return measure(c, fi, label), f.line_h, true, true
		case "image":
			if c.replaced.intrinsic != nil {
				if iw, ih, ok := c.replaced.intrinsic(c.replaced.user, h_node); ok { return iw * s, ih * s, true, true }
			}
			aw, okw := attr_px(c, h_node, "width")
			ah, okh := attr_px(c, h_node, "height")
			return aw * s, ah * s, okw, okh
		case "file":
			return measure(c, fi, "Choose File") + 8 * s + measure(c, fi, "No file chosen"), f.line_h, true, true
		case "date", "time", "datetime-local", "month", "week":
			return 12 * char_w, f.line_h, true, true
		}
		size := attr_int(c, h_node, "size", c.set.input_size)
		return f32(size) * char_w, f.line_h, true, true
	}
	return 0, 0, true, true
}

// Used border-box size of a replaced element. cb_w / cb_h < 0: indefinite percentage bases.
replaced_size :: proc(c: ^Ctx, bi: i32, cb_w, cb_h: f32) -> Vec2 {
	b := &c.l.boxes[bi]
	cs := b.cs
	base := max(cb_w, 0)
	pbw := px_of(c, cs.padding[.Left], base) + px_of(c, cs.padding[.Right], base) + border_px(c, cs.border_width[.Left]) + border_px(c, cs.border_width[.Right])
	pbh := px_of(c, cs.padding[.Top], base) + px_of(c, cs.padding[.Bottom], base) + border_px(c, cs.border_width[.Top]) + border_px(c, cs.border_width[.Bottom])
	bb := cs.box_sizing == .Border_Box
	nw, nh, has_w, has_h := natural_size(c, bi)
	b = &c.l.boxes[bi]
	ratio := cs.aspect_ratio
	// only real replaced content (images, video, canvas...) has a natural aspect ratio: a text field given a width keeps
	// its natural height instead of growing in proportion
	if ratio <= 0 && has_w && has_h && nh > 0 && nw > 0 && .Control not_in b.flags { ratio = nw / nh }
	sw, okw := definite(c, cs.width, cb_w)
	sh, okh := definite(c, cs.height, cb_h)
	if okw && bb { sw = max(sw - pbw, 0) }
	if okh && bb { sh = max(sh - pbh, 0) }
	w, h: f32
	switch {
	case okw && okh: w, h = sw, sh
	case okw: w = sw; h = ratio > 0 ? sw / ratio : (has_h ? nh : 0)
	case okh: h = sh; w = ratio > 0 ? sh * ratio : (has_w ? nw : 0)
	case:
		w = has_w ? nw : (ratio > 0 && has_h ? nh * ratio : 0)
		h = has_h ? nh : (ratio > 0 && has_w ? nw / ratio : 0)
	}
	// min / max (CSS 2.1 §10.4 table, simplified: each dimension on its own)
	clamp_dim :: proc(c: ^Ctx, v: f32, mn, mx: style.Length, base, pb: f32, bb: bool) -> f32 {
		r := v
		if mx.kind != .None {
			if m, ok := definite(c, mx, base); ok { r = min(r, bb ? max(m - pb, 0) : m) }
		}
		if m, ok := definite(c, mn, base); ok { r = max(r, bb ? max(m - pb, 0) : m) }
		return max(r, 0)
	}
	w = clamp_dim(c, w, cs.min_width, cs.max_width, cb_w, pbw, bb)
	h = clamp_dim(c, h, cs.min_height, cs.max_height, cb_h, pbh, bb)
	return {w + pbw, h + pbh}
}
