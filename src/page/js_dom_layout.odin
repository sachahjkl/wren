package page

// Geometry for JavaScript (api/js_dom_layout.widl; CSSOM View).
//
// The layout belongs to the embedder: the shell lays a tab's document out for its viewport, incrementally. A reading
// here asks the embedder to bring styles and layout up to date (Layout_Embedder.update) only when something they
// depend on moved since the last reading: the document (mutations), the computed styles (their serial, the state
// pseudo-classes), the viewport. Repeated readings with nothing changed in between cost a few comparisons
// (js_layout_now's fast path), so a script that reads offsetWidth in a loop does not lay the page out each time.
//
// Coordinates: the layout works in device pixels with the page's vertical scroll offset; CSSOM gives CSS pixels, in
// viewport coordinates (getBoundingClientRect) or document coordinates (offsetTop...).

import "core:math"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import lay "wb:layout"
import "wb:style"

// The viewport as the embedder shows it.
Viewport :: struct {
	width, height:      f64,   // CSS px
	scale:              f64,   // device px per CSS px (devicePixelRatio)
	scroll_x, scroll_y: f64,   // the document's scroll offsets, CSS px
}

Layout_Embedder :: struct {
	user:      rawptr,
	// Brings the page's styles and layout up to date (only what changed) and returns the layout; nil when the page is
	// not laid out (not shown).
	update:    proc(user: rawptr, p: ^Page) -> ^lay.Layout,
	viewport:  proc(user: rawptr, p: ^Page) -> Viewport,
	// Scrolls the document to (x, y), CSS px (clamped by the embedder); smoothly when `smooth`.
	scroll_to: proc(user: rawptr, p: ^Page, x, y: f64, smooth: bool),
	// Optional: something visible changed outside the document (a scroll container's offset): paint again.
	repaint:   proc(user: rawptr, p: ^Page),
}

@(private)
Js_Layout :: struct {
	embedder:  Layout_Embedder,
	has:       bool,
	result:    ^lay.Layout,
	mutations: u64,
	serial:    u64,
	vp:        Viewport,
	updates:   u64,     // how many times the embedder was asked (tests, measurements)
}

// Connects the page to the embedder that lays it out. Call after page_create; a zero value disconnects.
set_layout_embedder :: proc(p: ^Page, e: Layout_Embedder) {
	s := js_dom_state(p)
	s.layout = Js_Layout{embedder = e, has = e.update != nil && e.viewport != nil}
}

// How many times readings had to bring the layout up to date (the fast path does not count).
layout_updates :: proc(p: ^Page) -> u64 { return p.jsdom != nil ? p.jsdom.layout.updates : 0 }

@(private)
styles_clean :: proc(p: ^Page) -> bool {
	if p.styled == nil || p.style_stale || p.engine == nil || p.engine.dirty || p.engine.restyle_needed || p.engine.shadow.dirty { return false }
	return p.styled.mutations == p.doc.mutations && style.state_equal(effective_state(p), p.styled.state)
}

// Layouts a script's reading forced (the style pass and layout of the page up to date), and what they took: for the profile report.
forced_layouts: struct { n: int, ns: i64 }

// The layout as it is now (brought up to date if needed) and the viewport; nil without an embedder.
js_layout_now :: proc(p: ^Page) -> (^lay.Layout, Viewport) {
	if p.worker != nil { return nil, {} }
	s := js_dom_state(p)
	jl := &s.layout
	if !jl.has { return nil, Viewport{scale = 1} }
	vp := jl.embedder.viewport(jl.embedder.user, p)
	if vp.scale <= 0 { vp.scale = 1 }
	if jl.result != nil && jl.result.valid && jl.mutations == p.doc.mutations && styles_clean(p) && jl.serial == p.styled.serial &&
	   jl.vp.width == vp.width && jl.vp.height == vp.height && jl.vp.scale == vp.scale {
		jl.vp = vp   // scrolling moves nothing in the layout
		return jl.result, vp
	}
	jl.updates += 1
	t0 := time.tick_now()
	jl.result = jl.embedder.update(jl.embedder.user, p)
	forced_layouts.n += 1
	forced_layouts.ns += i64(time.tick_since(t0))
	jl.mutations = p.doc.mutations
	jl.serial = p.styled != nil ? p.styled.serial : 0
	jl.vp = vp
	return jl.result, vp
}

// The computed styles as they are now: through the embedder when there is one (the same pass as the layout), else
// computed for the last known viewport.
js_dom_styled :: proc(p: ^Page) -> ^style.Styled {
	if p.worker != nil || p.engine == nil { return nil }
	l, vp := js_layout_now(p)
	if l != nil && p.styled != nil { return p.styled }
	if styles_clean(p) { return p.styled }
	return styles(p, f32(vp.width), f32(vp.height), vp.scale > 0 ? vp.scale : 1)
}

// The box rectangles of an element in CSS px: the border box as drawn (transforms applied) in viewport coordinates,
// and the untransformed boxes in document coordinates.
@(private)
Element_Geometry :: struct {
	ok:       bool,
	client:   Api_DomRect,      // getBoundingClientRect
	border:   lay.Rect,         // document coordinates, CSS px
	padding:  lay.Rect,
	content:  lay.Rect,
	box:      ^lay.Box,
	fixed:    bool,
}

@(private)
element_geometry :: proc(p: ^Page, h: base.Handle) -> (Element_Geometry, ^lay.Layout, Viewport) {
	g: Element_Geometry
	l, vp := js_layout_now(p)
	if l == nil || !l.valid { return g, l, vp }
	s := f32(vp.scale)
	r, ok := lay.box_of(l, h, {f32(vp.width) * s, f32(vp.height) * s}, f32(vp.scroll_y) * s)
	if !ok { return g, l, vp }
	g.ok = true
	sc :: proc(r: lay.Rect, s: f32) -> lay.Rect { return lay.Rect{r.min / s, r.max / s} }
	g.border, g.padding, g.content = sc(r.border, s), sc(r.padding, s), sc(r.content, s)
	b := sc(r.bounds, s)
	g.client = Api_DomRect{x = f64(b.min.x) - vp.scroll_x, y = f64(b.min.y) - vp.scroll_y, width = f64(b.max.x - b.min.x), height = f64(b.max.y - b.min.y)}
	g.fixed = r.fixed
	if bi := lay.box_index(l, h); bi != lay.NONE { g.box = &l.boxes[bi] }
	return g, l, vp
}

// The used box sizes for getComputedStyle.
@(private)
used_box :: proc(p: ^Page, h: base.Handle) -> Used_Box {
	g, l, vp := element_geometry(p, h)
	if !g.ok || g.box == nil { return {} }
	_ = l
	s := f32(vp.scale)
	u := Used_Box{ok = true, width = g.content.max.x - g.content.min.x, height = g.content.max.y - g.content.min.y}
	for i in 0 ..< 4 { u.margin[i] = g.box.margin[i] / s; u.padding[i] = g.box.padding[i] / s }
	return u
}

Element_boundingRect :: proc(c: ^Call, element: Api_Element) -> Api_DomRect {
	g, _, _ := element_geometry(c.page, H(element.handle))
	return g.client
}

Element_clientRectsPacked :: proc(c: ^Call, element: Api_Element) -> []u8 {
	g, _, _ := element_geometry(c.page, H(element.handle))
	if !g.ok { return nil }
	return pack_rects({g.client})
}

@(private)
pack_rects :: proc(rects: []Api_DomRect) -> []u8 {
	out := make([]u8, len(rects) * 32, context.temp_allocator)
	for r, i in rects {
		vals := [4]f64{r.x, r.y, r.width, r.height}
		for v, k in vals {
			bits := transmute(u64)v
			for j in 0 ..< 8 { out[i * 32 + k * 8 + j] = u8(bits >> (8 * uint(j))) }
		}
	}
	return out
}

// The scrolling element (the root element; the body in quirks mode): its scroll offsets are the document's.
@(private)
is_scrolling_element :: proc(p: ^Page, h: base.Handle) -> bool {
	d := p.doc
	if d.mode == .Quirks { return h == jd_body(d) }
	return h == jd_document_element(d)
}

@(private)
is_inline_box :: proc(g: Element_Geometry) -> bool { return g.box == nil || g.box.kind == .Inline }

Element_clientTop :: proc(c: ^Call, element: Api_Element) -> i32 {
	g, _, vp := element_geometry(c.page, H(element.handle))
	if !g.ok || is_inline_box(g) { return 0 }
	return i32(math.round(f64(g.box.border[0]) / vp.scale))
}

Element_clientLeft :: proc(c: ^Call, element: Api_Element) -> i32 {
	g, _, vp := element_geometry(c.page, H(element.handle))
	if !g.ok || is_inline_box(g) { return 0 }
	return i32(math.round(f64(g.box.border[3]) / vp.scale))
}

Element_clientWidth :: proc(c: ^Call, element: Api_Element) -> i32 {
	p := c.page
	h := H(element.handle)
	if h == jd_document_element(p.doc) || (p.doc.mode == .Quirks && h == jd_body(p.doc)) {
		_, vp := js_layout_now(p)
		return i32(vp.width)
	}
	g, _, _ := element_geometry(p, h)
	if !g.ok || is_inline_box(g) { return 0 }
	return i32(math.round(f64(g.padding.max.x - g.padding.min.x)))
}

Element_clientHeight :: proc(c: ^Call, element: Api_Element) -> i32 {
	p := c.page
	h := H(element.handle)
	if h == jd_document_element(p.doc) || (p.doc.mode == .Quirks && h == jd_body(p.doc)) {
		_, vp := js_layout_now(p)
		return i32(vp.height)
	}
	g, _, _ := element_geometry(p, h)
	if !g.ok || is_inline_box(g) { return 0 }
	return i32(math.round(f64(g.padding.max.y - g.padding.min.y)))
}

Element_scrollTop :: proc(c: ^Call, element: Api_Element) -> f64 {
	p := c.page
	h := H(element.handle)
	l, vp := js_layout_now(p)
	if is_scrolling_element(p, h) { return vp.scroll_y }
	if l == nil { return 0 }
	off, ok := lay.scroll_of(l, h)
	return ok ? f64(off.y) / vp.scale : 0
}

Element_scrollLeft :: proc(c: ^Call, element: Api_Element) -> f64 {
	p := c.page
	h := H(element.handle)
	l, vp := js_layout_now(p)
	if is_scrolling_element(p, h) { return vp.scroll_x }
	if l == nil { return 0 }
	off, ok := lay.scroll_of(l, h)
	return ok ? f64(off.x) / vp.scale : 0
}

// Scrolls a scroll container (or the document for the scrolling element) to (x, y) CSS px; NaN keeps an axis.
@(private)
scroll_element_to :: proc(p: ^Page, h: base.Handle, x, y: f64, smooth := false) {
	l, vp := js_layout_now(p)
	jl := &js_dom_state(p).layout
	scroll_events_mark(p)
	if is_scrolling_element(p, h) {
		if jl.has && jl.embedder.scroll_to != nil {
			nx := math.is_nan(x) ? vp.scroll_x : x
			ny := math.is_nan(y) ? vp.scroll_y : y
			jl.embedder.scroll_to(jl.embedder.user, p, nx, ny, smooth)
		}
		return
	}
	if l == nil { return }
	cur, ok := lay.scroll_of(l, h)
	if !ok { return }
	s := f32(vp.scale)
	target := cur
	if !math.is_nan(x) { target.x = f32(x) * s }
	if !math.is_nan(y) { target.y = f32(y) * s }
	// (its scroll event comes with the next frame, as for any other scrolling: scroll_events.odin)
	if _, set := lay.set_scroll(l, h, target); set && jl.embedder.repaint != nil { jl.embedder.repaint(jl.embedder.user, p) }
}

Element_set_scrollTop :: proc(c: ^Call, element: Api_Element, value: f64) {
	scroll_element_to(c.page, H(element.handle), math.nan_f64(), math.is_nan(value) ? 0 : value)
}

Element_set_scrollLeft :: proc(c: ^Call, element: Api_Element, value: f64) {
	scroll_element_to(c.page, H(element.handle), math.is_nan(value) ? 0 : value, math.nan_f64())
}

Element_scrollWidth :: proc(c: ^Call, element: Api_Element) -> i32 {
	p := c.page
	h := H(element.handle)
	if is_scrolling_element(p, h) {
		// the document scrolls vertically only (the layout keeps no horizontal overflow of the page)
		_, vp := js_layout_now(p)
		return i32(vp.width)
	}
	g, l, vp := element_geometry(p, h)
	if !g.ok || is_inline_box(g) { return 0 }
	w := f64(g.padding.max.x - g.padding.min.x)
	if mx, ok := lay.scroll_max(l, h); ok { w += f64(mx.x) / vp.scale }
	return i32(math.round(w))
}

Element_scrollHeight :: proc(c: ^Call, element: Api_Element) -> i32 {
	p := c.page
	h := H(element.handle)
	if is_scrolling_element(p, h) {
		l, vp := js_layout_now(p)
		if l == nil { return 0 }
		return i32(math.max(vp.height, f64(l.height) / vp.scale))
	}
	g, l, vp := element_geometry(p, h)
	if !g.ok || is_inline_box(g) { return 0 }
	hgt := f64(g.padding.max.y - g.padding.min.y)
	if mx, ok := lay.scroll_max(l, h); ok { hgt += f64(mx.y) / vp.scale }
	return i32(math.round(hgt))
}

Element_scrollToXY :: proc(c: ^Call, element: Api_Element, x: f64, y: f64, relative: bool) {
	p := c.page
	h := H(element.handle)
	nx, ny := x, y
	if relative {
		if !math.is_nan(x) { nx = Element_scrollLeft(c, element) + x }
		if !math.is_nan(y) { ny = Element_scrollTop(c, element) + y }
	}
	scroll_element_to(p, h, nx, ny)
}

// scrollIntoView: the document scrolls so that the element's border box is at the start / center / end / nearest
// edge of the viewport, on each axis (scroll containers between them are not scrolled).
Element_scrollIntoViewAt :: proc(c: ^Call, element: Api_Element, block: i32, inline_pos: i32) {
	p := c.page
	g, _, vp := element_geometry(p, H(element.handle))
	if !g.ok || g.fixed { return }
	pick :: proc(start, end, view, cur: f64, how: i32) -> f64 {
		switch how {
		case 1: return start + (end - start) / 2 - view / 2
		case 2: return end - view
		case 3:
			if start >= cur && end <= cur + view { return cur }
			if end - start > view || start < cur { return start }
			return end - view
		}
		return start
	}
	y := pick(f64(g.border.min.y), f64(g.border.max.y), vp.height, vp.scroll_y, block)
	x := pick(f64(g.border.min.x), f64(g.border.max.x), vp.width, vp.scroll_x, inline_pos)
	jl := &js_dom_state(p).layout
	if jl.has && jl.embedder.scroll_to != nil { scroll_events_mark(p); jl.embedder.scroll_to(jl.embedder.user, p, math.max(x, 0), math.max(y, 0), false) }
}

// offsetParent: the nearest ancestor that is positioned, or a td / th / table when the element is not positioned,
// or the body; null for the body, the root, a fixed element, or an element without a box.
HTMLElement_offsetParent :: proc(c: ^Call, element: Api_Element) -> u64 {
	return u64(offset_parent(c.page, H(element.handle)))
}

@(private)
offset_parent :: proc(p: ^Page, h: base.Handle) -> base.Handle {
	d := p.doc
	st := js_dom_styled(p)
	if st == nil { return base.NIL_HANDLE }
	cs := style.style_of(st, h)
	body := jd_body(d)
	if cs == nil || cs.display == .None || h == body || h == jd_document_element(d) { return base.NIL_HANDLE }
	fixed := cs.position == .Fixed
	self_static := cs.position == .Static
	shadows := dom.has_shadow_trees(d)
	// the flat-tree ancestors (slots included), but not those of a shadow tree hidden from the element (CSSOM View §7,
	// as engines do for open trees too); past a fixed box (the element, or a hidden ancestor), only the box that
	// contains fixed boxes goes on the chain of containing blocks, none: null
	for cur := dom.flat_parent(d, h); cur != base.NIL_HANDLE; cur = dom.flat_parent(d, cur) {
		n := dom.get(d, cur)
		if n.kind != .Element { break }
		acs := style.style_of(st, cur)
		if shadows && dom.retarget(d, cur, h) != cur {
			if acs == nil { continue }
			if fixed && len(acs.transform) > 0 { fixed = false } else if !fixed && acs.position == .Fixed { fixed = true }
			continue
		}
		if fixed {
			if acs != nil && len(acs.transform) > 0 { return cur }
			continue
		}
		if cur == body { return cur }
		if acs == nil { continue }
		if acs.position != .Static || len(acs.transform) > 0 { return cur }
		if self_static && n.ns == .HTML && (n.name == "td" || n.name == "th" || n.name == "table") { return cur }
	}
	return fixed ? base.NIL_HANDLE : body
}

@(private)
offset_rect :: proc(p: ^Page, h: base.Handle) -> (x, y, w, hh: f64, ok: bool) {
	g, _, _ := element_geometry(p, h)
	if !g.ok { return }
	x, y = f64(g.border.min.x), f64(g.border.min.y)
	w, hh = f64(g.border.max.x - g.border.min.x), f64(g.border.max.y - g.border.min.y)
	parent := offset_parent(p, h)
	if parent != base.NIL_HANDLE && parent != jd_body(p.doc) {
		pg, _, _ := element_geometry(p, parent)
		if pg.ok { x -= f64(pg.padding.min.x); y -= f64(pg.padding.min.y) }
	}
	return x, y, w, hh, true
}

HTMLElement_offsetTop :: proc(c: ^Call, element: Api_Element) -> i32 { _, y, _, _, _ := offset_rect(c.page, H(element.handle)); return i32(math.round(y)) }
HTMLElement_offsetLeft :: proc(c: ^Call, element: Api_Element) -> i32 { x, _, _, _, _ := offset_rect(c.page, H(element.handle)); return i32(math.round(x)) }
HTMLElement_offsetWidth :: proc(c: ^Call, element: Api_Element) -> i32 { _, _, w, _, _ := offset_rect(c.page, H(element.handle)); return i32(math.round(w)) }
HTMLElement_offsetHeight :: proc(c: ^Call, element: Api_Element) -> i32 { _, _, _, hh, _ := offset_rect(c.page, H(element.handle)); return i32(math.round(hh)) }

Document_elementFromPoint :: proc(c: ^Call, x: f64, y: f64) -> u64 {
	p := c.page
	l, vp := js_layout_now(p)
	if l == nil || !l.valid || x < 0 || y < 0 || x > vp.width || y > vp.height { return 0 }
	s := f32(vp.scale)
	hit := lay.hit_test(l, {f32(x) * s, f32(y) * s}, {f32(vp.width) * s, f32(vp.height) * s}, f32(vp.scroll_y) * s)
	// a text node hit: its flat-tree parent element; retargeted: an element of a shadow tree shows as its host
	cur := hit.node
	for cur != base.NIL_HANDLE && !jd_is_element(p.doc, cur) { cur = dom.flat_parent(p.doc, cur) }
	if cur != base.NIL_HANDLE {
		return u64(dom.has_shadow_trees(p.doc) ? dom.retarget(p.doc, cur, p.doc.root) : cur)
	}
	return u64(jd_document_element(p.doc))
}

// document.elementsFromPoint / shadowRoot.elementsFromPoint (CSSOM View §6.1 with shadow trees): the element hit and its
// flat-tree ancestors, each retargeted against `root` (the elements of inner trees show as their hosts, those outside
// as themselves) and kept once, the document element last. Handles, 8 bytes each.
DocumentOrShadowRoot_elementsFromPointPacked :: proc(c: ^Call, root: Api_Node, x: f64, y: f64) -> []u8 {
	p := c.page
	d := p.doc
	out := make([dynamic]base.Handle, context.temp_allocator)
	l, vp := js_layout_now(p)
	if l == nil || !l.valid || x < 0 || y < 0 || x > vp.width || y > vp.height { return nil }
	s := f32(vp.scale)
	hit := lay.hit_test(l, {f32(x) * s, f32(y) * s}, {f32(vp.width) * s, f32(vp.height) * s}, f32(vp.scroll_y) * s)
	r := H(root.handle)
	for cur := hit.node; cur != base.NIL_HANDLE; cur = dom.flat_parent(d, cur) {
		if !jd_is_element(d, cur) { continue }
		t := dom.retarget(d, cur, r)
		seen := false
		for x in out { if x == t { seen = true; break } }
		if !seen { append(&out, t) }
	}
	if de := jd_document_element(d); de != base.NIL_HANDLE {
		seen := false
		for x in out { if x == de { seen = true; break } }
		if !seen { append(&out, de) }
	}
	return pack_handles(out[:])
}

////////////////////////////////
// Window

@(private)
viewport_now :: proc(c: ^Call) -> Viewport {
	if c.page.worker != nil { return {} }
	s := js_dom_state(c.page)
	if !s.layout.has { return Viewport{scale = 1} }
	vp := s.layout.embedder.viewport(s.layout.embedder.user, c.page)
	if vp.scale <= 0 { vp.scale = 1 }
	return vp
}

Window_innerWidth :: proc(c: ^Call) -> i32 { return i32(viewport_now(c).width) }
Window_innerHeight :: proc(c: ^Call) -> i32 { return i32(viewport_now(c).height) }
Window_outerWidth :: proc(c: ^Call) -> i32 { return i32(viewport_now(c).width) }
Window_outerHeight :: proc(c: ^Call) -> i32 { return i32(viewport_now(c).height) }
Window_scrollX :: proc(c: ^Call) -> f64 { return viewport_now(c).scroll_x }
Window_scrollY :: proc(c: ^Call) -> f64 { return viewport_now(c).scroll_y }
Window_pageXOffset :: proc(c: ^Call) -> f64 { return viewport_now(c).scroll_x }
Window_pageYOffset :: proc(c: ^Call) -> f64 { return viewport_now(c).scroll_y }
Window_devicePixelRatio :: proc(c: ^Call) -> f64 { return viewport_now(c).scale }
Window_screenX :: proc(c: ^Call) -> i32 { return 0 }
Window_screenY :: proc(c: ^Call) -> i32 { return 0 }
Window_screenLeft :: proc(c: ^Call) -> i32 { return 0 }
Window_screenTop :: proc(c: ^Call) -> i32 { return 0 }

Window_scrollToXY :: proc(c: ^Call, x: f64, y: f64, relative: bool, smooth: bool) {
	p := c.page
	if p.worker != nil { return }
	s := js_dom_state(p)
	if !s.layout.has || s.layout.embedder.scroll_to == nil { return }
	vp := viewport_now(c)
	nx := math.is_nan(x) ? vp.scroll_x : (relative ? vp.scroll_x + x : x)
	ny := math.is_nan(y) ? vp.scroll_y : (relative ? vp.scroll_y + y : y)
	scroll_events_mark(p)
	s.layout.embedder.scroll_to(s.layout.embedder.user, p, nx, ny, smooth)
}

////////////////////////////////
// Ranges

// The element boxes a range touches: elements inside it, and the elements whose text it covers.
@(private)
range_rects :: proc(c: ^Call, start: base.Handle, so: u32, end: base.Handle, eo: u32) -> [dynamic]Api_DomRect {
	p := c.page
	d := p.doc
	out := make([dynamic]Api_DomRect, 0, 4, context.temp_allocator)
	first := start
	if n := dom.get(d, start); n != nil && n.kind != .Text && n.kind != .Comment {
		if ch := dom.child_at(d, start, int(so)); ch != base.NIL_HANDLE { first = ch } else { first = dom.next_skipping_children(d, start, d.root) }
	}
	last := end
	if n := dom.get(d, end); n != nil && n.kind != .Text && n.kind != .Comment && eo > 0 {
		if ch := dom.child_at(d, end, int(eo) - 1); ch != base.NIL_HANDLE { last = ch }
	}
	seen := make(map[base.Handle]bool, 8, context.temp_allocator)
	limit := p.settings.dom.max_rects
	for cur := first; cur != base.NIL_HANDLE && len(out) < limit; cur = dom.next_in_tree(d, cur, d.root) {
		n := dom.get(d, cur)
		target := cur
		if n.kind == .Text { target = n.parent }
		if n.kind == .Element || n.kind == .Text {
			if !(target in seen) {
				seen[target] = true
				if g, _, _ := element_geometry(p, target); g.ok { append(&out, g.client) }
			}
		}
		if cur == last { break }
	}
	return out
}

Range_boundingRect :: proc(c: ^Call, start: Api_Node, start_offset: u32, end: Api_Node, end_offset: u32) -> Api_DomRect {
	rects := range_rects(c, H(start.handle), start_offset, H(end.handle), end_offset)
	if len(rects) == 0 { return {} }
	x0, y0 := rects[0].x, rects[0].y
	x1, y1 := x0 + rects[0].width, y0 + rects[0].height
	for r in rects[1:] {
		x0, y0 = math.min(x0, r.x), math.min(y0, r.y)
		x1, y1 = math.max(x1, r.x + r.width), math.max(y1, r.y + r.height)
	}
	return {x0, y0, x1 - x0, y1 - y0}
}

Range_clientRectsPacked :: proc(c: ^Call, start: Api_Node, start_offset: u32, end: Api_Node, end_offset: u32) -> []u8 {
	rects := range_rects(c, H(start.handle), start_offset, H(end.handle), end_offset)
	return pack_rects(rects[:])
}

_ :: strings
