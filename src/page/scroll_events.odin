package page

// (The window's "resize" event is here too: the resize steps of update the rendering, one per frame whose viewport size
// differs from the frame before.)
// Scroll events (HTML "run the scroll steps" of update the rendering; CSSOM View §13.1): once per rendered frame,
// before the animation frame callbacks, every scroll container whose offset changed since the last frame gets a
// `scroll` event (not bubbling), and the document a bubbling one at the Document (it reaches the Window) when the page
// itself scrolled. Whatever moved it counts the same: the wheel, the keyboard, a scroll bar, smooth scrolling, a
// script setting scrollTop or calling scrollTo. Virtual lists (Angular CDK, React Window...) render the rows in view
// from these events.
//
// `scrollend` (CSSOM View §13.2) comes once a target's scrolling is over: at the first frame where something that moved
// at the frame before did not move again, to the same target, the same way (an element without bubbling, the Document
// bubbling); a container removed in between gets none. A smooth scroll moves every frame until it ends, a held key or a
// turning wheel too, so each gives one scrollend at its end.
//
// The offsets are those of the embedder's layout (Layout_Embedder: the shell's, incremental); a page without one (no
// window) has nothing to compare and fires nothing.

import "core:slice"
import "wb:base"
import "wb:dom"

Scroll_Events :: struct {
	elements:   map[base.Handle][2]f32,   // device px, the containers' offsets at the last frame (absent: 0, 0)
	doc:        [2]f64,                   // CSS px
	doc_known:  bool,
	size:       [2]f64,                   // CSS px, the viewport at the last frame (the window's "resize" event)
	size_known: bool,
	doc_handle: ^dom.Document,            // the document they belong to (a navigation starts over)
	moving:     [dynamic]base.Handle,     // the containers that moved at the last frame: their scrollend waits for one where they do not
	doc_moving: bool,                     // the document moved at the last frame
	moved:      [dynamic]base.Handle,     // what a script moved since the last frame, even back to where it was (NIL: the document)
}

// A script (or a headless embedder's input) scrolled something: the page wants a frame for its scroll event
// (wants_animation_frame), even without a window that would render one anyway.
scroll_events_mark :: proc(p: ^Page) { p.web.scroll_pending = true }

// A script moved a scroll container (NIL: the document): its scroll event comes with the next frame even when another
// call put it back where it was before then (CSSOM View's pending scroll event targets).
@(private)
scroll_events_moved :: proc(p: ^Page, node: base.Handle) {
	se := scroll_events_state(p)
	if !slice.contains(se.moved[:], node) { append(&se.moved, node) }
	scroll_events_mark(p)
}

@(private = "file")
scroll_events_state :: proc(p: ^Page) -> ^Scroll_Events {
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
		clear(&se.moving)
		clear(&se.moved)
		se.doc_known, se.size_known, se.doc_moving = false, false, false
		se.doc_handle = p.doc
	}
	return se
}

@(private = "file")
scroll_events_free :: proc(data: rawptr) {
	p := (^Page)(data)
	if p.scroll_events == nil { return }
	delete(p.scroll_events.elements)
	delete(p.scroll_events.moving)
	delete(p.scroll_events.moved)
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
	se := scroll_events_state(p)
	targets := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	moved_doc := false
	for node in se.moved {
		if node == base.NIL_HANDLE { moved_doc = true } else { append(&targets, node) }
	}
	clear(&se.moved)
	for node, off in l.scroll {
		before := se.elements[node] or_else [2]f32{}
		if before != off && !slice.contains(targets[:], node) { append(&targets, node) }
	}
	// containers scrolled back to 0 that the layout no longer lists
	gone := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	for node, before in se.elements {
		if _, still := l.scroll[node]; !still {
			append(&gone, node)
			if before != {} && !slice.contains(targets[:], node) { append(&targets, node) }
		}
	}
	for node in gone { delete_key(&se.elements, node) }
	for node, off in l.scroll { se.elements[node] = off }

	doc_scrolled := moved_doc || (se.doc_known && (se.doc[0] != vp.scroll_x || se.doc[1] != vp.scroll_y))
	se.doc, se.doc_known = {vp.scroll_x, vp.scroll_y}, true

	// the resize steps come first: the window's size (a resized window, full screen, zoom) changed since the last frame
	size := [2]f64{vp.width, vp.height}
	if se.size_known && se.size != size {
		fire_window_event(p, dom.Event{type = "resize"})
		if p.closed { return }
	}
	se.size, se.size_known = size, true

	// what moved at the last frame and not at this one has stopped
	ended := make([dynamic]base.Handle, 0, 4, context.temp_allocator)
	for node in se.moving {
		if !slice.contains(targets[:], node) { append(&ended, node) }
	}
	doc_ended := se.doc_moving && !doc_scrolled
	clear(&se.moving)
	append(&se.moving, ..targets[:])
	se.doc_moving = doc_scrolled
	if len(targets) > 0 || doc_scrolled { scroll_events_mark(p) }   // the frame that tells whether they stopped

	// document order of the targets is not required; one event per target per frame is
	fire :: proc(p: ^Page, nodes: []base.Handle, type: string) {
		for node in nodes {
			if p.closed { return }
			n := dom.get(p.doc, node)
			if n == nil || n.kind != .Element || !dom.is_connected(p.doc, node) { continue }
			dispatch_event(p, node, dom.Event{type = type})
		}
	}
	fire(p, targets[:], "scroll")
	if doc_scrolled && !p.closed {
		dispatch_event(p, p.doc.root, dom.Event{type = "scroll", bubbles = true})
	}
	fire(p, ended[:], "scrollend")
	if doc_ended && !p.closed {
		dispatch_event(p, p.doc.root, dom.Event{type = "scrollend", bubbles = true})
	}
}

