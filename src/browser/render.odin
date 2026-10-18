// Placeholder document painter: block layout, inline flow with wrapping across elements, default styles by tag. It is
// the seam where the real style + layout engine goes (Lexbor's CSS parser/selectors for styles, a Clay-style flex core,
// then full block/inline flow). Every document mutation re-runs it from scratch: fine for now, not the final design.
package browser

import "core:strings"
import "toolkit:draw"
import "toolkit:font"
import "wb:base"
import "wb:dom"

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
	bg:        draw.Color,    // Text: background chip (buttons), alpha 0 = none
	pad_x:     f32,           // horizontal padding inside the chip
	radius_bg: f32,
}

Layout :: struct {
	items:     [dynamic]Item,
	height:    f32,
	mutations: u64,
	width:     f32,
	scale:     f32,
	valid:     bool,
}

layout_reset :: proc(l: ^Layout) {
	clear(&l.items)
	l.valid = false
}

layout_destroy :: proc(l: ^Layout) { delete(l.items) }

Style :: struct {
	size_mult: f32,
	margin:    f32,   // em, above and below (blocks)
	pad:       f32,   // em
	bg:        draw.Color,
	radius:    f32,
	pre:       bool,
	hidden:    bool,
	inline:    bool,
	underline: bool,
	fg:        draw.Color,
}

DEFAULT_FG :: 0x1b1f2aff

style_for :: proc(tag: string, parent: Style) -> Style {
	s := Style{size_mult = 1, fg = parent.fg, underline = parent.underline, pre = false}
	if s.fg == {} { s.fg = draw.hex(DEFAULT_FG) }
	switch tag {
	case "head", "script", "style", "title", "meta", "link", "template", "noscript": s.hidden = true
	case "h1": s.size_mult, s.margin = 2.0, 0.67
	case "h2": s.size_mult, s.margin = 1.5, 0.75
	case "h3": s.size_mult, s.margin = 1.17, 0.83
	case "h4", "h5", "h6": s.size_mult, s.margin = 1.0, 1.0
	case "p", "ul", "ol", "blockquote": s.margin = 1
	case "li": s.margin = 0.25
	case "pre": s.pre, s.bg, s.pad, s.margin = true, draw.hex(0xeef0f5ff), 0.5, 0.5
	case "button": s.inline, s.bg, s.pad, s.radius = true, draw.hex(0xdde3f5ff), 0.6, 0.3
	case "hr": s.bg, s.pad = draw.hex(0xc9cedcff), 0.04
	case "a": s.inline, s.fg, s.underline = true, draw.hex(0x1d57baff), true
	case "code": s.inline, s.fg = true, draw.hex(0x9b2d5bff)
	case "u", "ins": s.inline, s.underline = true, true
	case "b", "strong", "i", "em", "span", "small", "label", "mark", "sup", "sub", "abbr", "cite", "q", "s", "del", "kbd", "samp", "var", "br":
		s.inline = true
	}
	return s
}

layout_document :: proc(l: ^Layout, d: ^dom.Document, fonts: ^font.State, font_id: font.Font_Id, width, scale: f32) {
	clear(&l.items)
	l.mutations = d.mutations
	l.width = width
	l.scale = scale
	l.valid = true
	c := Layout_Ctx{l, d, fonts, font_id, scale}
	y := 8 * scale
	root_style := Style{size_mult = 1, fg = draw.hex(DEFAULT_FG)}
	block(&c, d.root, 8 * scale, width - 16 * scale, &y, root_style, 16 * scale)
	l.height = y + 8 * scale
}

@(private)
Layout_Ctx :: struct {
	l:       ^Layout,
	d:       ^dom.Document,
	fonts:   ^font.State,
	font_id: font.Font_Id,
	scale:   f32,
}

@(private)
Run :: struct {
	text:      string,
	size:      f32,
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
block :: proc(c: ^Layout_Ctx, h: base.Handle, x, w: f32, y: ^f32, parent: Style, size: f32) {
	n := dom.get(c.d, h)
	if n == nil { return }
	st := parent
	if n.kind == .Element {
		st = style_for(n.name, parent)
		if st.hidden { return }
		if n.name == "li" { /* bullets are drawn as text below */ }
	}
	sz := size * (n.kind == .Element ? st.size_mult : 1)
	pad := st.pad * sz
	margin := st.margin * sz
	y^ += margin
	top := y^
	box_index := len(c.l.items)
	append(&c.l.items, Item{kind = .Box, node = h, color = st.bg, radius = st.radius * sz})
	y^ += pad
	cx, cw := x + pad, w - 2 * pad
	if n.kind == .Element && n.name == "li" {
		// marker, then the content indented
		bullet := Run{text = "•", size = sz, fg = st.fg, node = h}
		flow(c, {bullet}, cx, 1000, y, st, true)
		y^ -= sz * 1.35
		cx += sz * 1.2
		cw -= sz * 1.2
	}
	if n.kind == .Element && n.name == "ul" || n.kind == .Element && n.name == "ol" { cx += sz * 1.2; cw -= sz * 1.2 }
	if n.kind == .Element && n.name == "hr" { y^ += 2 }

	ch := n.first_child
	for ch != base.NIL_HANDLE {
		cn := dom.get(c.d, ch)
		if cn == nil { break }
		if is_inline_node(c, cn) {
			runs: [dynamic]Run
			defer delete(runs)
			ch = collect_runs(c, ch, st, sz, &runs)
			flow(c, runs[:], cx, cw, y, st, false)
			continue
		}
		block(c, ch, cx, cw, y, st, sz)
		ch = cn.next
	}
	y^ += pad
	c.l.items[box_index].rect = {{x, top}, {x + w, y^}}
	y^ += margin
}

@(private)
is_inline_node :: proc(c: ^Layout_Ctx, n: ^dom.Node) -> bool {
	#partial switch n.kind {
	case .Text: return true
	case .Element: return style_for(n.name, {}).inline
	}
	return false
}

// Gathers consecutive inline siblings starting at `first` (descending into inline elements, iteratively).
// Returns the first sibling that is not part of the run.
@(private)
collect_runs :: proc(c: ^Layout_Ctx, first: base.Handle, parent: Style, size: f32, out: ^[dynamic]Run) -> base.Handle {
	Frame :: struct { h: base.Handle, st: Style, size: f32, owner: base.Handle }
	cur := first
	for cur != base.NIL_HANDLE {
		cn := dom.get(c.d, cur)
		if cn == nil { return base.NIL_HANDLE }
		if !is_inline_node(c, cn) { return cur }
		stack: [dynamic]Frame
		defer delete(stack)
		append(&stack, Frame{cur, parent, size, dom.get(c.d, cur).parent})
		for len(stack) > 0 {
			f := pop(&stack)
			n := dom.get(c.d, f.h)
			if n == nil { continue }
			#partial switch n.kind {
			case .Text:
				append(out, Run{text = n.text, size = f.size, fg = f.st.fg, underline = f.st.underline, node = f.owner, bg = f.st.bg, pad_x = f.st.pad * f.size, radius = f.st.radius * f.size})
			case .Element:
				st := style_for(n.name, f.st)
				if st.hidden { continue }
				if !(n.name == "button") { st.bg = {}; st.pad = 0 }   // only buttons draw a chip; block backgrounds do not inherit
				if n.name == "br" { append(out, Run{br = true, size = f.size, node = f.h}); continue }
				sz := f.size * st.size_mult
				for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(c.d, ch).prev {
					append(&stack, Frame{ch, st, sz, f.h})
				}
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
flow :: proc(c: ^Layout_Ctx, runs: []Run, x, w: f32, y: ^f32, st: Style, single_line: bool) {
	if len(runs) == 0 { return }
	if st.pre {
		for r in runs {
			rest := r.text
			for line in strings.split_lines_iterator(&rest) {
				tw := font.text_width(c.fonts, c.font_id, r.size, line)
				append(&c.l.items, Item{kind = .Text, rect = {{x, y^}, {x + tw, y^ + r.size * 1.35}}, node = r.node, color = r.fg, text = line, size = r.size})
				y^ += r.size * 1.35
			}
		}
		return
	}
	line_start := len(c.l.items)
	line_x: f32 = 0
	line_h: f32 = 0
	pending_space := false
	line_empty := true

	finish_line :: proc(c: ^Layout_Ctx, from: int, y: ^f32, line_h: f32, x: f32) {
		for i in from ..< len(c.l.items) {
			it := &c.l.items[i]
			it.rect.min.y = y^
			it.rect.max.y = y^ + line_h
		}
		y^ += line_h
	}

	for r in runs {
		if r.br {
			finish_line(c, line_start, y, max(line_h, r.size * 1.35), x)   // an empty line still takes height
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
			ww := font.text_width(c.fonts, c.font_id, r.size, text[i:j]) + 2 * r.pad_x
			space := (pending_space && !line_empty) ? font.text_width(c.fonts, c.font_id, r.size, " ") : 0
			if !line_empty && !single_line && line_x + space + ww > w {
				finish_line(c, line_start, y, line_h, x)
				line_start = len(c.l.items)
				line_x, line_h, line_empty, space = 0, 0, true, 0
			}
			lh := r.size * 1.35
			line_h = max(line_h, lh)
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
	if !line_empty { finish_line(c, line_start, y, line_h, x) }
}

// Deepest element under a point (layout coordinates); text fragments report the element that owns them.
hit_test :: proc(l: ^Layout, p: draw.Vec2) -> base.Handle {
	for i := len(l.items) - 1; i >= 0; i -= 1 {
		it := l.items[i]
		if draw.rect_contains(it.rect, p) { return it.node }
	}
	return base.NIL_HANDLE
}

paint :: proc(l: ^Layout, dc: ^draw.Context, fonts: ^font.State, font_id: font.Font_Id, origin: draw.Vec2, clip: draw.Rect) {
	for it in l.items {
		r := draw.rect_shift(it.rect, origin)
		if r.max.y < clip.min.y || r.min.y > clip.max.y { continue }
		switch it.kind {
		case .Box:
			if it.color.a > 0 { draw.rect(dc, r, it.color, it.radius) }
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
