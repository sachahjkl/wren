package page

// CSS Custom Highlight API: what CSS.highlights holds, for the painter (src/browser/selection_shell.odin). The objects a script sees are
// native/js/odin/web_highlight.js, which sends the whole registry here after a change; what ::highlight(name) rules say is in the
// style of each element (style.highlight_colors). The painter asks for the spans of a text node: what a range covers of each text
// node, worked out once per change of the registry or of the document.

import "core:slice"
import "core:strings"
import "wb:base"
import "wb:dom"
import lay "wb:layout"
import "wb:style"

Page_Highlight :: struct {
	kind:     style.Highlight_Kind,  // Custom: of CSS.highlights; the others are the browser's
	name:     string,
	priority: i32,
	order:    int,                   // its place in the registry: equal priorities paint in that order
	ranges:   [dynamic][2]lay.Text_Pos,
}

// A part of a text node in a highlight: bytes [lo, hi) of its text, `highlight` an index in Page_Highlights.list.
Highlight_Span :: struct {
	lo, hi, highlight: int,
}

Page_Highlights :: struct {
	list:      [dynamic]Page_Highlight,   // as sent; by overlay and priority once `sorted`
	sorted:    bool,
	spans:     map[base.Handle][dynamic]Highlight_Span,   // in painting order
	serial:    u64,                       // changes on every change of the registry (the painter records again)
	made_at:   u64,                       // `serial` the spans were made for
	mutations: u64,                       // doc.mutations they were made against
}

@(private = "file")
highlights_of :: proc(p: ^Page) -> ^Page_Highlights {
	if p.highlights == nil {
		p.highlights = new(Page_Highlights)
		base.on_close(p.scope, proc(data: rawptr) {
			h := (^Page_Highlights)(data)
			highlights_empty(h)
			delete(h.list)
			delete(h.spans)
			free(h)
		}, p.highlights)
	}
	return p.highlights
}

@(private = "file")
spans_empty :: proc(h: ^Page_Highlights) {
	for _, list in h.spans { delete(list) }
	clear(&h.spans)
}

@(private = "file")
highlights_empty :: proc(h: ^Page_Highlights) {
	spans_empty(h)
	for &x in h.list {
		delete(x.name)
		delete(x.ranges)
	}
	clear(&h.list)
}

Highlights_clear :: proc(c: ^Call) {
	h := highlights_of(c.page)
	marks_remove(h, .Custom)
	h.serial += 1
}

// Takes away what the list has of `kind`.
@(private = "file")
marks_remove :: proc(h: ^Page_Highlights, kind: style.Highlight_Kind) {
	spans_empty(h)
	for i := len(h.list) - 1; i >= 0; i -= 1 {
		if h.list[i].kind != kind { continue }
		delete(h.list[i].name)
		delete(h.list[i].ranges)
		ordered_remove(&h.list, i)
	}
	h.sorted = false
}

// What the browser marks in the document, in place of what it marked of this `kind` (::target-text, ::spelling-error, ::grammar-error).
marks_set :: proc(p: ^Page, kind: style.Highlight_Kind, ranges: [][2]lay.Text_Pos) {
	h := highlights_of(p)
	marks_remove(h, kind)
	if len(ranges) > 0 {
		m := Page_Highlight{kind = kind, name = strings.clone(""), order = len(h.list)}
		append(&m.ranges, ..ranges)
		append(&h.list, m)
	}
	h.serial += 1
}

Highlights_add :: proc(c: ^Call, name: string, priority: i32) {
	h := highlights_of(c.page)
	append(&h.list, Page_Highlight{name = strings.clone(name), priority = priority, order = len(h.list)})
	h.sorted = false
	h.serial += 1
}

Highlights_addRange :: proc(c: ^Call, start: Api_Node, start_offset: u32, end: Api_Node, end_offset: u32) {
	p := c.page
	h := highlights_of(p)
	if len(h.list) == 0 || h.list[len(h.list) - 1].kind != .Custom { return }
	a, ok1 := from_utf16_offset(p.doc, H(start.handle), start_offset)
	b, ok2 := from_utf16_offset(p.doc, H(end.handle), end_offset)
	if !ok1 || !ok2 { return }
	append(&h.list[len(h.list) - 1].ranges, [2]lay.Text_Pos{a, b})
	h.serial += 1
}

// The serial of what is registered (0: nothing ever was).
highlights_serial :: proc(p: ^Page) -> u64 { return p.highlights != nil ? p.highlights.serial : 0 }

@(private = "file")
spans_add :: proc(p: ^Page, h: ^Page_Highlights, index: int, a, b: lay.Text_Pos) {
	d := p.doc
	if !lay.in_document(d, a.node) || !lay.in_document(d, b.node) || lay.pos_compare(d, a, b) >= 0 { return }
	for cur := a.node; cur != base.NIL_HANDLE; cur = dom.next_in_tree(d, cur, d.root) {
		n := dom.get(d, cur)
		if n == nil { break }
		if lay.pos_compare(d, {cur, 0}, b) >= 0 { break }
		if n.kind != .Text { continue }
		lo := cur == a.node ? min(a.offset, len(n.text)) : 0
		hi := cur == b.node ? min(b.offset, len(n.text)) : len(n.text)
		if lay.pos_compare(d, {cur, hi}, a) <= 0 || lo >= hi { continue }
		list := h.spans[cur]
		append(&list, Highlight_Span{lo, hi, index})
		h.spans[cur] = list
	}
}

// The ranges of a highlight that overlap are one (CSS Custom Highlight API §4.2.4): its background is not drawn twice. Spans stay by highlight, in painting order.
@(private = "file")
spans_union :: proc(list: ^[dynamic]Highlight_Span) {
	slice.sort_by(list[:], proc(x, y: Highlight_Span) -> bool { return x.highlight != y.highlight ? x.highlight < y.highlight : x.lo < y.lo })
	out := 0
	for s in list {
		if out > 0 && list[out - 1].highlight == s.highlight && s.lo <= list[out - 1].hi {
			list[out - 1].hi = max(list[out - 1].hi, s.hi)
			continue
		}
		list[out] = s
		out += 1
	}
	resize(list, out)
}

// What is highlighted of the document, for a frame's painter: the highlights by priority, and their spans by text node. Nil: nothing.
highlights_paint :: proc(p: ^Page) -> ^Page_Highlights {
	h := p.highlights
	if h == nil || len(h.list) == 0 { return nil }
	if h.made_at == h.serial && h.mutations == p.doc.mutations { return h }
	if !h.sorted {
		slice.sort_by(h.list[:], proc(x, y: Page_Highlight) -> bool {
			if x.kind != y.kind { return x.kind < y.kind }
			return x.priority != y.priority ? x.priority < y.priority : x.order < y.order
		})
		h.sorted = true
	}
	spans_empty(h)
	for x, i in h.list {
		for r in x.ranges { spans_add(p, h, i, r[0], r[1]) }
	}
	for _, &list in h.spans { spans_union(&list) }
	h.made_at, h.mutations = h.serial, p.doc.mutations
	return h
}
