// Placeholder document painter: block layout with wrapped text, enough to see and click a page. It is the seam where
// the real style + layout engine goes (Lexbor for parsing, a Clay-style flex core, then block/inline flow).
package browser

import "core:strings"
import "toolkit:draw"
import "toolkit:font"
import "wb:base"
import "wb:dom"

Item_Kind :: enum u8 { Box, Text }

Item :: struct {
	kind:   Item_Kind,
	rect:   draw.Rect,
	node:   base.Handle,
	color:  draw.Color,    // Box: background (alpha 0 = none), Text: foreground
	radius: f32,
	text:   string,        // Text: a slice of the node's own text (valid until the next mutation)
	size:   f32,
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
	margin:    f32,   // em, above and below
	pad:       f32,   // em
	bg:        draw.Color,
	radius:    f32,
	pre:       bool,
	hidden:    bool,
	fg:        draw.Color,
}

style_for :: proc(tag: string) -> Style {
	s := Style{size_mult = 1, fg = draw.hex(0x1b1f2aff)}
	switch tag {
	case "head", "script", "style", "title", "meta", "link": s.hidden = true
	case "h1": s.size_mult, s.margin = 2.0, 0.67
	case "h2": s.size_mult, s.margin = 1.5, 0.75
	case "h3": s.size_mult, s.margin = 1.17, 0.83
	case "p": s.margin = 1
	case "pre", "code": s.pre, s.bg, s.pad, s.margin = true, draw.hex(0xeef0f5ff), 0.5, 0.5
	case "button": s.bg, s.pad, s.radius, s.margin = draw.hex(0xdde3f5ff), 0.4, 0.3, 0.25
	case "a": s.fg = draw.hex(0x1d57baff)
	}
	return s
}

layout_document :: proc(l: ^Layout, d: ^dom.Document, fonts: ^font.State, font_id: font.Font_Id, width, scale: f32) {
	clear(&l.items)
	l.mutations = d.mutations
	l.width = width
	l.scale = scale
	l.valid = true
	ctx := Layout_Ctx{l, d, fonts, font_id, scale}
	y := 8 * scale
	walk(&ctx, d.root, 8 * scale, width - 16 * scale, &y, style_for(""), 16 * scale)
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
walk :: proc(c: ^Layout_Ctx, h: base.Handle, x, w: f32, y: ^f32, inherited: Style, size: f32) {
	n := dom.get(c.d, h)
	if n == nil { return }
	#partial switch n.kind {
	case .Text:
		wrap_text(c, n.text, x, w, y, size, inherited, h)
	case .Element, .Document:
		st := inherited
		if n.kind == .Element {
			st = style_for(n.name)
			if st.hidden { return }
			if st.fg == draw.hex(0x1b1f2aff) { st.fg = inherited.fg }
			if n.name != "pre" && n.name != "code" { st.pre = inherited.pre }
		}
		sz := size * (n.kind == .Element ? st.size_mult : 1)
		em := sz
		pad := st.pad * em
		margin := st.margin * em
		y^ += margin
		top := y^
		box_index := len(c.l.items)
		append(&c.l.items, Item{kind = .Box, node = h, color = st.bg, radius = st.radius * em})
		y^ += pad
		for ch := n.first_child; ch != base.NIL_HANDLE; {
			walk(c, ch, x + pad, w - 2 * pad, y, st, sz)
			cn := dom.get(c.d, ch)
			if cn == nil { break }
			ch = cn.next
		}
		y^ += pad
		c.l.items[box_index].rect = {{x, top}, {x + w, y^}}
		y^ += margin
	}
}

@(private)
wrap_text :: proc(c: ^Layout_Ctx, text: string, x, w: f32, y: ^f32, size: f32, st: Style, owner: base.Handle) {
	parent := dom.get(c.d, owner).parent
	line_h := size * 1.35
	emit :: proc(c: ^Layout_Ctx, s: string, x, y, size: f32, w, line_h: f32, color: draw.Color, parent: base.Handle) {
		append(&c.l.items, Item{kind = .Text, rect = {{x, y}, {x + w, y + line_h}}, node = parent, color = color, text = s, size = size})
	}
	if st.pre {
		rest := text
		for line in strings.split_lines_iterator(&rest) {
			tw := font.text_width(c.fonts, c.font_id, size, line)
			emit(c, line, x, y^, size, tw, line_h, st.fg, parent)
			y^ += line_h
		}
		return
	}
	// split on whitespace, greedy fill
	start := -1       // start of the current line in `text`
	last_end := 0     // end of the last word placed on the line
	line_w: f32
	space := font.text_width(c.fonts, c.font_id, size, " ")
	i := 0
	flush :: proc(c: ^Layout_Ctx, text: string, start, end: int, x: f32, y: ^f32, size, line_h, line_w: f32, st: Style, parent: base.Handle) {
		if start < 0 || end <= start { return }
		emit(c, text[start:end], x, y^, size, line_w, line_h, st.fg, parent)
		y^ += line_h
	}
	for i < len(text) {
		for i < len(text) && (text[i] == ' ' || text[i] == '\n' || text[i] == '\t' || text[i] == '\r') { i += 1 }
		if i >= len(text) { break }
		j := i
		for j < len(text) && !(text[j] == ' ' || text[j] == '\n' || text[j] == '\t' || text[j] == '\r') { j += 1 }
		word_w := font.text_width(c.fonts, c.font_id, size, text[i:j])
		if start >= 0 && line_w + space + word_w > w {
			flush(c, text, start, last_end, x, y, size, line_h, line_w, st, parent)
			start = -1
		}
		if start < 0 { start, line_w = i, word_w } else { line_w += space + word_w }
		last_end = j
		i = j
	}
	flush(c, text, start, last_end, x, y, size, line_h, line_w, st, parent)
}

// Deepest element box under a point (layout coordinates).
hit_test :: proc(l: ^Layout, p: draw.Vec2) -> base.Handle {
	for i := len(l.items) - 1; i >= 0; i -= 1 {
		it := l.items[i]
		if it.kind == .Box && draw.rect_contains(it.rect, p) { return it.node }
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
			draw.text(dc, font_id, it.size, {r.min.x, baseline}, it.color, it.text)
		}
	}
}
