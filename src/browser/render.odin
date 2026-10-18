// Interim document painter. Styles come from the real style engine (package style: selectors, cascade, computed values);
// the layout itself is still simple: block boxes with margins, padding, borders and widths, and inline text flowing across
// elements. Flex, floats, positioning, tables and real inline formatting replace it next. Every change re-runs it from
// scratch, which is fine for now, not the final design.
package browser

import "core:slice"
import "core:strings"
import "toolkit:draw"
import "toolkit:font"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:style"

Item_Kind :: enum u8 { Box, Text }

Item :: struct {
	kind:      Item_Kind,
	rect:      draw.Rect,
	node:      base.Handle,   // element that owns the item (hit testing, default actions)
	color:     draw.Color,    // Box: background (alpha 0 = none), Text: foreground
	radius:    f32,
	text:      string,        // Text: a slice of the node's own text (valid until the next mutation)
	size:      f32,
	underline: bool,
	bg:        draw.Color,    // Text: background chip, alpha 0 = none
	pad_x:     f32,           // horizontal padding inside the chip
	radius_bg: f32,
	border:    [4]f32,        // Box: top, right, bottom, left widths
	border_color: [4]draw.Color,
}

Layout :: struct {
	items:     [dynamic]Item,
	height:    f32,
	mutations: u64,
	serial:    u64,           // the style pass this layout was made from
	width:     f32,
	scale:     f32,
	valid:     bool,
	owned:     [dynamic]string,   // strings made up by layout (list markers, generated content); items point into them
	// Spatial index: items grouped by horizontal band of the page, so painting and hit testing visit only what is near.
	band_h:       f32,
	band_start:   [dynamic]u32,       // CSR layout: band b owns band_items[band_start[b] : band_start[b + 1]]
	band_items:   [dynamic]u32,       // item indices, ascending within a band (= paint order)
}

layout_reset :: proc(l: ^Layout) {
	clear(&l.items)
	clear(&l.band_start); clear(&l.band_items)
	free_owned(l)
	l.valid = false
}

@(private)
free_owned :: proc(l: ^Layout) {
	for s in l.owned { delete(s) }
	clear(&l.owned)
}

layout_destroy :: proc(l: ^Layout) {
	delete(l.items)
	delete(l.band_start); delete(l.band_items)
	free_owned(l)
	delete(l.owned)
}

// A string that lives as long as the layout.
@(private)
persist :: proc(c: ^Layout_Ctx, s: string) -> string {
	p := strings.clone(s)
	append(&c.l.owned, p)
	return p
}

// The parts of a computed style this painter uses, in physical pixels.
@(private)
Look :: struct {
	size:       f32,
	line_h:     f32,
	fg, bg:     draw.Color,
	radius:     f32,
	pre, hidden, inline, underline, contents: bool,
	align:      style.Text_Align,
	margin:     [4]f32,     // top, right, bottom, left
	padding:    [4]f32,
	border:     [4]f32,
	border_color: [4]draw.Color,
	auto_x:     [2]bool,    // margin-left / margin-right are auto
	width:      f32,        // < 0: auto (border-box width when box_sizing is border-box)
	min_w, max_w: f32,      // max_w < 0: none
	height:     f32,
	border_box: bool,
	display:    style.Display,
	list_type:  style.List_Style_Type,
	inside_marker: bool,
}

@(private)
Layout_Ctx :: struct {
	l:       ^Layout,
	d:       ^dom.Document,
	styled:  ^style.Styled,
	measure: ^Measure,
	fonts:   ^font.State,
	font_id: font.Font_Id,
	scale:   f32,
}

// CSS colors are sRGB; the renderer blends in linear space.
to_draw :: proc(c: css.Color) -> draw.Color { return draw.srgb(c.r, c.g, c.b, c.a) }

@(private)
side4 :: proc(s: [style.Side]style.Length, base_w, scale: f32) -> [4]f32 {
	return {style.resolve(s[.Top], base_w) * scale, style.resolve(s[.Right], base_w) * scale, style.resolve(s[.Bottom], base_w) * scale, style.resolve(s[.Left], base_w) * scale}
}

// `cw` is the width percentages refer to (the containing block's content width).
@(private)
look_of :: proc(c: ^Layout_Ctx, h: base.Handle, parent: Look, cw: f32) -> Look {
	cs := style.style_of(c.styled, h)
	if cs == nil { return Look{hidden = true} }
	return look_from(c, cs, parent, cw)
}

@(private)
look_from :: proc(c: ^Layout_Ctx, cs: ^style.Computed, parent: Look, cw: f32) -> Look {
	lk: Look
	lk.size = cs.font_size * c.scale
	switch cs.line_height.kind {
	case .Normal: lk.line_h = lk.size * c.styled.line_height_normal
	case .Number: lk.line_h = lk.size * cs.line_height.v
	case .Length: lk.line_h = cs.line_height.v * c.scale
	}
	lk.fg, lk.bg = to_draw(cs.color), to_draw(cs.background_color)
	lk.pre = cs.white_space == .Pre || cs.white_space == .Pre_Wrap
	lk.hidden = cs.display == .None || cs.visibility == .Collapse
	lk.contents = cs.display == .Contents
	lk.inline = cs.display == .Inline || cs.display == .Inline_Block || cs.display == .Inline_Flex
	lk.underline = parent.underline || .Underline in cs.text_decoration
	lk.align = cs.text_align
	lk.margin = side4(cs.margin, cw / c.scale, c.scale)
	lk.padding = side4(cs.padding, cw / c.scale, c.scale)
	for s in style.Side { lk.border[s] = cs.border_width[s] * c.scale; lk.border_color[s] = to_draw(cs.border_color[s]) }
	lk.auto_x = {cs.margin[.Left].kind == .Auto, cs.margin[.Right].kind == .Auto}
	lk.width, lk.height = -1, -1
	if cs.width.kind == .Px || cs.width.kind == .Percent || cs.width.kind == .Calc { lk.width = style.resolve(cs.width, cw / c.scale) * c.scale }
	if cs.height.kind == .Px { lk.height = cs.height.v * c.scale }
	lk.max_w = -1
	if cs.max_width.kind == .Px || cs.max_width.kind == .Percent || cs.max_width.kind == .Calc { lk.max_w = style.resolve(cs.max_width, cw / c.scale) * c.scale }
	if cs.min_width.kind == .Px || cs.min_width.kind == .Percent || cs.min_width.kind == .Calc { lk.min_w = style.resolve(cs.min_width, cw / c.scale) * c.scale }
	lk.border_box = cs.box_sizing == .Border_Box
	lk.radius = cs.radius[.Top_Left].h.v * c.scale
	lk.display = cs.display
	lk.list_type = cs.list_style_type
	// an inline box's vertical margins and borders do not take part in block layout
	if lk.inline { lk.margin = {0, lk.margin[1], 0, lk.margin[3]} }
	return lk
}

layout_document :: proc(l: ^Layout, d: ^dom.Document, styled: ^style.Styled, measure: ^Measure, fonts: ^font.State, font_id: font.Font_Id, width, scale, band_h: f32) {
	clear(&l.items)
	free_owned(l)
	l.mutations = d.mutations
	l.serial = styled.serial
	l.width = width
	l.scale = scale
	l.valid = true
	c := Layout_Ctx{l, d, styled, measure, fonts, font_id, scale}
	y: f32 = 0
	root := Look{size = 16 * scale, line_h = 16 * scale * styled.line_height_normal, fg = {0, 0, 0, 1}}
	block(&c, d.root, 0, width, &y, root)
	l.height = y
	build_bands(l, band_h * scale)
}

// Groups items by band. Two passes (count, then fill) into flat arrays: no per-band allocations.
@(private)
build_bands :: proc(l: ^Layout, band_h: f32) {
	l.band_h = max(band_h, 16)
	nb := int(l.height / l.band_h) + 2
	clear(&l.band_start)
	resize(&l.band_start, nb + 1)
	for i in 0 ..< len(l.band_start) { l.band_start[i] = 0 }
	span :: proc(l: ^Layout, it: ^Item, nb: int) -> (b0, b1: int) {
		b0 = clamp(int(it.rect.min.y / l.band_h), 0, nb - 1)
		b1 = clamp(int(it.rect.max.y / l.band_h), b0, nb - 1)
		return
	}
	for &it in l.items {
		b0, b1 := span(l, &it, nb)
		for b in b0 ..= b1 { l.band_start[b + 1] += 1 }
	}
	for b in 1 ..= nb { l.band_start[b] += l.band_start[b - 1] }
	clear(&l.band_items)
	resize(&l.band_items, int(l.band_start[nb]))
	fill := make([]u32, nb, context.temp_allocator)
	for &it, i in l.items {
		b0, b1 := span(l, &it, nb)
		for b in b0 ..= b1 {
			l.band_items[int(l.band_start[b] + fill[b])] = u32(i)
			fill[b] += 1
		}
	}
}

@(private)
marker_text :: proc(c: ^Layout_Ctx, h: base.Handle, t: style.List_Style_Type) -> string {
	switch t {
	case .None: return ""
	case .Disc: return "\u2022"
	case .Circle: return "\u25e6"
	case .Square: return "\u25aa"
	case .Decimal, .Decimal_Leading_Zero, .Lower_Alpha, .Upper_Alpha, .Lower_Roman, .Upper_Roman, .Lower_Greek:
		n := 1
		for p := dom.get(c.d, h).prev; p != base.NIL_HANDLE; p = dom.get(c.d, p).prev {
			if cs := style.style_of(c.styled, p); cs != nil && cs.display == .List_Item { n += 1 }
		}
		#partial switch t {
		case .Lower_Alpha: return strings.clone(string([]u8{u8('a' + (n - 1) % 26), '.'}), context.temp_allocator)
		case .Upper_Alpha: return strings.clone(string([]u8{u8('A' + (n - 1) % 26), '.'}), context.temp_allocator)
		case .Decimal_Leading_Zero: return strings.concatenate({n < 10 ? "0" : "", itoa(n), "."}, context.temp_allocator)
		}
		return strings.concatenate({itoa(n), "."}, context.temp_allocator)
	}
	return ""
}

@(private)
itoa :: proc(n: int) -> string {
	buf: [20]u8
	i := len(buf)
	v := n
	if v == 0 { i -= 1; buf[i] = '0' }
	for v > 0 { i -= 1; buf[i] = u8('0' + v % 10); v /= 10 }
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

@(private)
Run :: struct {
	text:      string,
	size:      f32,
	line_h:    f32,
	fg:        draw.Color,
	underline: bool,
	node:      base.Handle,
	br:        bool,
	bg:        draw.Color,
	pad_x:     f32,
	radius:    f32,
}

// Lays out one block-level node (or the Document): its box, then its children, grouping inline children into flows.
@(private)
block :: proc(c: ^Layout_Ctx, h: base.Handle, x, w: f32, y: ^f32, parent: Look) {
	n := dom.get(c.d, h)
	if n == nil { return }
	lk := parent
	if n.kind == .Element {
		lk = look_of(c, h, parent, w)
		if lk.hidden { return }
	}
	is_box := n.kind == .Element && !lk.contents
	if !is_box {
		// the document itself, or display: contents: children flow in the parent's box
		flow_children(c, h, n, x, w, y, lk)
		return
	}
	y^ += lk.margin[0]
	bx, bw := x + lk.margin[3], w - lk.margin[1] - lk.margin[3]
	extra := lk.padding[1] + lk.padding[3] + lk.border[1] + lk.border[3]
	if lk.width >= 0 { bw = lk.border_box ? lk.width : lk.width + extra }
	{
		inner := bw - extra
		pad := lk.border_box ? extra : 0   // min/max-width follow box-sizing
		if lk.max_w >= 0 { inner = min(inner, lk.max_w - pad) }
		inner = max(inner, lk.min_w - pad, 0)
		bw = inner + extra
	}
	if avail := w - lk.margin[1] - lk.margin[3]; bw < avail {
		if lk.auto_x[0] && lk.auto_x[1] { bx = x + (w - bw) * 0.5 } else if lk.auto_x[0] { bx = x + w - lk.margin[1] - bw }
	}
	top := y^
	box_index := len(c.l.items)
	append(&c.l.items, Item{kind = .Box, node = h, color = lk.bg, radius = lk.radius, border = lk.border, border_color = lk.border_color})
	y^ += lk.border[0] + lk.padding[0]
	content_top := y^
	cx, cw := bx + lk.border[3] + lk.padding[3], bw - extra

	if lk.display == .List_Item && lk.list_type != .None {
		if m := marker_text(c, h, lk.list_type); m != "" {
			m = persist(c, m)
			mw := measure_width(c.measure, c.fonts, c.font_id, lk.size, m)
			saved := y^
			flow(c, {Run{text = m, size = lk.size, line_h = lk.line_h, fg = lk.fg, node = h}}, cx - mw - lk.size * 0.45, 1000, y, lk, true)
			y^ = saved
		}
	}
	flow_children(c, h, n, cx, cw, y, lk)

	if lk.height >= 0 {
		inner := lk.border_box ? lk.height - lk.border[0] - lk.border[2] - lk.padding[0] - lk.padding[2] : lk.height
		y^ = content_top + max(inner, 0)
	}
	y^ += lk.padding[2] + lk.border[2]
	c.l.items[box_index].rect = {{bx, top}, {bx + bw, y^}}
	y^ += lk.margin[2]
}

// Text of generated content (::before / ::after). Counters and images are not drawn.
@(private)
pseudo_run :: proc(c: ^Layout_Ctx, owner: base.Handle, pc: ^style.Computed, parent: Look, cw: f32) -> (Run, bool) {
	if pc == nil || pc.content.kind != .Items { return {}, false }
	sb := strings.builder_make(context.temp_allocator)
	for it in pc.content.items {
		switch it.kind {
		case .Text: strings.write_string(&sb, it.text)
		case .Attr:
			if v, ok := dom.get_attribute(c.d, owner, it.text); ok { strings.write_string(&sb, v) }
		case .Open_Quote: strings.write_string(&sb, "\u201c")
		case .Close_Quote: strings.write_string(&sb, "\u201d")
		case .Url:
		}
	}
	text := strings.to_string(sb)
	if text == "" { return {}, false }
	lk := look_from(c, pc, parent, cw)
	r := Run{text = persist(c, text), size = lk.size, line_h = lk.line_h, fg = lk.fg, underline = lk.underline, node = owner}
	return r, true
}

@(private)
flow_children :: proc(c: ^Layout_Ctx, h: base.Handle, n: ^dom.Node, cx, cw: f32, y: ^f32, lk: Look) {
	runs: [dynamic]Run
	defer delete(runs)
	flush :: proc(c: ^Layout_Ctx, runs: ^[dynamic]Run, cx, cw: f32, y: ^f32, lk: Look) {
		if len(runs) > 0 { flow(c, runs[:], cx, cw, y, lk, false); clear(runs) }
	}
	cs := n.kind == .Element ? style.style_of(c.styled, h) : nil
	if cs != nil { if r, ok := pseudo_run(c, h, cs.before, lk, cw); ok { append(&runs, r) } }
	ch := n.first_child
	for ch != base.NIL_HANDLE {
		cn := dom.get(c.d, ch)
		if cn == nil { break }
		if is_inline_node(c, ch, cn, lk) {
			ch = collect_runs(c, ch, lk, cw, &runs)
			continue
		}
		flush(c, &runs, cx, cw, y, lk)
		block(c, ch, cx, cw, y, lk)
		ch = cn.next
	}
	if cs != nil { if r, ok := pseudo_run(c, h, cs.after, lk, cw); ok { append(&runs, r) } }
	flush(c, &runs, cx, cw, y, lk)
}
@(private)
is_inline_node :: proc(c: ^Layout_Ctx, h: base.Handle, n: ^dom.Node, parent: Look) -> bool {
	#partial switch n.kind {
	case .Text: return true
	case .Element:
		cs := style.style_of(c.styled, h)
		return cs != nil && (cs.display == .Inline || cs.display == .Inline_Block || cs.display == .Inline_Flex) && cs.float == .None && cs.position != .Absolute && cs.position != .Fixed
	}
	return false
}

// Gathers consecutive inline siblings starting at `first` (descending into inline elements, iteratively).
// Returns the first sibling that is not part of the run.
@(private)
collect_runs :: proc(c: ^Layout_Ctx, first: base.Handle, parent: Look, cw: f32, out: ^[dynamic]Run) -> base.Handle {
	Frame :: struct { h: base.Handle, lk: Look, owner: base.Handle, after: ^style.Computed }
	cur := first
	for cur != base.NIL_HANDLE {
		cn := dom.get(c.d, cur)
		if cn == nil { return base.NIL_HANDLE }
		if !is_inline_node(c, cur, cn, parent) { return cur }
		stack: [dynamic]Frame
		defer delete(stack)
		append(&stack, Frame{cur, parent, cn.parent, nil})
		for len(stack) > 0 {
			f := pop(&stack)
			if f.after != nil {
				if r, ok := pseudo_run(c, f.h, f.after, f.lk, cw); ok { append(out, r) }
				continue
			}
			n := dom.get(c.d, f.h)
			if n == nil { continue }
			#partial switch n.kind {
			case .Text:
				// only inline boxes draw a chip behind their text; a block's own background and padding are not repeated per word
				r := Run{text = n.text, size = f.lk.size, line_h = f.lk.line_h, fg = f.lk.fg, underline = f.lk.underline, node = f.owner}
				if f.lk.inline { r.bg, r.pad_x, r.radius = f.lk.bg, f.lk.padding[3], f.lk.radius }
				append(out, r)
			case .Element:
				lk := look_of(c, f.h, f.lk, cw)
				if lk.hidden { continue }
				if n.name == "br" { append(out, Run{br = true, size = f.lk.size, line_h = lk.line_h, node = f.h}); continue }
				cs := style.style_of(c.styled, f.h)
				if cs != nil && cs.after != nil { append(&stack, Frame{h = f.h, lk = lk, after = cs.after}) }
				for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(c.d, ch).prev {
					append(&stack, Frame{ch, lk, f.h, nil})
				}
				if cs != nil { if r, ok := pseudo_run(c, f.h, cs.before, lk, cw); ok { append(out, r) } }
			}
		}
		cur = cn.next
	}
	return base.NIL_HANDLE
}

@(private)
is_space :: proc(b: u8) -> bool { return b == ' ' || b == '\n' || b == '\t' || b == '\r' }

// Greedy line filling across runs; words keep the style of the run they come from.
@(private)
flow :: proc(c: ^Layout_Ctx, runs: []Run, x, w: f32, y: ^f32, lk: Look, single_line: bool) {
	if len(runs) == 0 { return }
	if lk.pre {
		for r in runs {
			rest := r.text
			for line in strings.split_lines_iterator(&rest) {
				tw := measure_width(c.measure, c.fonts, c.font_id, r.size, line)
				append(&c.l.items, Item{kind = .Text, rect = {{x, y^}, {x + tw, y^ + r.line_h}}, node = r.node, color = r.fg, text = line, size = r.size, underline = r.underline})
				y^ += r.line_h
			}
		}
		return
	}
	line_start := len(c.l.items)
	line_x: f32 = 0
	line_h: f32 = 0
	pending_space := false
	line_empty := true

	finish_line :: proc(c: ^Layout_Ctx, from: int, y: ^f32, line_h: f32, line_w, avail: f32, align: style.Text_Align) {
		shift: f32
		#partial switch align {
		case .Center: shift = max((avail - line_w) * 0.5, 0)
		case .Right, .End: shift = max(avail - line_w, 0)
		}
		for i in from ..< len(c.l.items) {
			it := &c.l.items[i]
			it.rect.min.y = y^
			it.rect.max.y = y^ + line_h
			it.rect.min.x += shift
			it.rect.max.x += shift
		}
		y^ += line_h
	}

	for r in runs {
		if r.br {
			finish_line(c, line_start, y, max(line_h, r.line_h), line_x, w, lk.align)   // an empty line still takes height
			line_start = len(c.l.items)
			line_x, line_h, line_empty, pending_space = 0, 0, true, false
			continue
		}
		text := r.text
		i := 0
		if len(text) > 0 && is_space(text[0]) { pending_space = true }
		for i < len(text) {
			for i < len(text) && is_space(text[i]) { pending_space = true; i += 1 }
			if i >= len(text) { break }
			j := i
			for j < len(text) && !is_space(text[j]) { j += 1 }
			ww := measure_width(c.measure, c.fonts, c.font_id, r.size, text[i:j]) + 2 * r.pad_x
			space := (pending_space && !line_empty) ? measure_width(c.measure, c.fonts, c.font_id, r.size, " ") : 0
			if !line_empty && !single_line && line_x + space + ww > w {
				finish_line(c, line_start, y, line_h, line_x, w, lk.align)
				line_start = len(c.l.items)
				line_x, line_h, line_empty, space = 0, 0, true, 0
			}
			line_h = max(line_h, r.line_h)
			append(&c.l.items, Item{
				kind = .Text, rect = {{x + line_x + space, 0}, {x + line_x + space + ww, 0}}, node = r.node,
				color = r.fg, text = text[i:j], size = r.size, underline = r.underline,
				bg = r.bg, pad_x = r.pad_x, radius_bg = r.radius,
			})
			line_x += space + ww
			line_empty = false
			pending_space = false
			i = j
		}
		if len(text) > 0 && is_space(text[len(text) - 1]) { pending_space = true }
	}
	if !line_empty { finish_line(c, line_start, y, line_h, line_x, w, lk.align) }
}

// Deepest element under a point (layout coordinates); text fragments report the element that owns them.
hit_test :: proc(l: ^Layout, p: draw.Vec2) -> base.Handle {
	if len(l.band_start) < 2 { return base.NIL_HANDLE }
	nb := len(l.band_start) - 1
	b := clamp(int(p.y / l.band_h), 0, nb - 1)
	list := l.band_items[l.band_start[b]:l.band_start[b + 1]]
	for k := len(list) - 1; k >= 0; k -= 1 {   // later items are painted on top
		it := &l.items[list[k]]
		if draw.rect_contains(it.rect, p) { return it.node }
	}
	return base.NIL_HANDLE
}

paint :: proc(l: ^Layout, dc: ^draw.Context, fonts: ^font.State, font_id: font.Font_Id, origin: draw.Vec2, clip: draw.Rect) {
	if len(l.band_start) < 2 { return }
	nb := len(l.band_start) - 1
	// visible range in layout coordinates, then the bands it touches
	y0, y1 := clip.min.y - origin.y, clip.max.y - origin.y
	b0 := clamp(int(y0 / l.band_h), 0, nb - 1)
	b1 := clamp(int(y1 / l.band_h), b0, nb - 1)
	visible := make([dynamic]u32, 0, 1024, context.temp_allocator)
	for b in b0 ..= b1 { append(&visible, ..l.band_items[l.band_start[b]:l.band_start[b + 1]]) }
	slice.sort(visible[:])   // paint order = item order; an item spanning several bands is listed once per band
	last := u32(max(u32))
	for idx in visible {
		if idx == last { continue }
		last = idx
		it := &l.items[idx]
		r := draw.rect_shift(it.rect, origin)
		if r.max.y < clip.min.y || r.min.y > clip.max.y { continue }
		switch it.kind {
		case .Box:
			if it.color.a > 0 { draw.rect(dc, r, it.color, it.radius) }
			bt, br, bb, bl := it.border[0], it.border[1], it.border[2], it.border[3]
			if bt > 0 { draw.rect(dc, {r.min, {r.max.x, r.min.y + bt}}, it.border_color[0]) }
			if bb > 0 { draw.rect(dc, {{r.min.x, r.max.y - bb}, r.max}, it.border_color[2]) }
			if bl > 0 { draw.rect(dc, {{r.min.x, r.min.y + bt}, {r.min.x + bl, r.max.y - bb}}, it.border_color[3]) }
			if br > 0 { draw.rect(dc, {{r.max.x - br, r.min.y + bt}, {r.max.x, r.max.y - bb}}, it.border_color[1]) }
		case .Text:
			// draw.text takes (left, baseline); the item rect is the line box
			m := font.metrics(fonts, font_id, it.size)
			baseline := r.min.y + (draw.rect_size(r).y - (m.ascent + m.descent)) * 0.5 + m.ascent
			if it.bg.a > 0 { draw.rect(dc, draw.rect_pad(r, 0), it.bg, it.radius_bg) }
			draw.text(dc, font_id, it.size, {r.min.x + it.pad_x, baseline}, it.color, it.text)
			if it.underline { draw.rect(dc, {{r.min.x, baseline + 2}, {r.max.x, baseline + 3}}, it.color) }
		}
	}
}