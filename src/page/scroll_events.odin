package page

// Scroll events (HTML "run the scroll steps" of update the rendering; CSSOM View §13.1): once per rendered frame,
// before the animation frame callbacks, every scroll container whose offset changed since the last frame gets a
// `scroll` event (not bubbling), and the document a bubbling one at the Document (it reaches the Window) when the page
// itself scrolled. Whatever moved it counts the same: the wheel, the keyboard, a scroll bar, smooth scrolling, a
// script setting scrollTop or calling scrollTo. Virtual lists (Angular CDK, React Window...) render the rows in view
// from these events.
//
// The offsets are those of the embedder's layout (Layout_Embedder: the shell's, incremental); a page without one (no
// window) has nothing to compare and fires nothing.

import "wb:base"
import "wb:dom"

Scroll_Events :: struct {
	elements:   map[base.Handle][2]f32,   // device px, the containers' offsets at the last frame (absent: 0, 0)
	doc:        [2]f64,                   // CSS px
	doc_known:  bool,
	doc_handle: ^dom.Document,            // the document they belong to (a navigation starts over)
}

// A script scrolled something: the page wants a frame for its scroll event (wants_animation_frame), even without a
// window that would render one anyway.
@(private)
scroll_events_mark :: proc(p: ^Page) { p.web.scroll_pending = true }

@(private = "file")
scroll_events_free :: proc(data: rawptr) {
	p := (^Page)(data)
	if p.scroll_events == nil { return }
	delete(p.scroll_events.elements)
	free(p.scroll_events)
	p.scroll_events = nil
}

// Fires the scroll events of this frame. Called from run_animation_frames.
@(private)
run_scroll_steps :: proc(p: ^Page) {
	if p.web != nil { p.web.scroll_pending = false }
	if p.worker != nil || p.jsdom == nil || !p.jsdom.layout.has || p.doc == nil { return }
	l, vp := js_layout_now(p)
	if l == nil || !l.valid { return }
	se := p.scroll_events
	if se == nil {
		se = new(Scroll_Events)
		se.elements = make(map[base.Handle][2]f32)
		p.scroll_events = se
		base.on_close(p.scope, scroll_events_free, p)
	}
	if se.doc_handle != p.doc {
		// a new document: what it shows first is no scroll
		clear(&se.elements)
		se.doc_known = false
		se.doc_handle = p.doc
	}
	targets := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	for node, off in l.scroll {
		before := se.elements[node] or_else [2]f32{}
		if before != off { append(&targets, node) }
	}
	// containers scrolled back to 0 that the layout no longer lists
	gone := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	for node, before in se.elements {
		if _, still := l.scroll[node]; !still {
			append(&gone, node)
			if before != {} { append(&targets, node) }
		}
	}
	for node in gone { delete_key(&se.elements, node) }
	for node, off in l.scroll { se.elements[node] = off }

	doc_scrolled := se.doc_known && (se.doc[0] != vp.scroll_x || se.doc[1] != vp.scroll_y)
	se.doc, se.doc_known = {vp.scroll_x, vp.scroll_y}, true

	// document order of the targets is not required; one event per target per frame is
	for node in targets {
		if p.closed { return }
		n := dom.get(p.doc, node)
		if n == nil || n.kind != .Element || !dom.is_connected(p.doc, node) { continue }
		dispatch_event(p, node, dom.Event{type = "scroll"})
	}
	if doc_scrolled && !p.closed {
		dispatch_event(p, p.doc.root, dom.Event{type = "scroll", bubbles = true})
	}
}

