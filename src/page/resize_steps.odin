package page

// CSSOM View "run the resize steps" (a step of the event loop's rendering update, before animation frame callbacks):
// when the viewport the embedder lays the document out in changed size since the last time, `resize` is fired at the
// window. Pages read innerWidth once and follow resize after that (DuckDuckGo decides its mobile layout this way): the
// first size seen is recorded without an event.

import "wb:dom"

@(private)
resize_steps :: proc(p: ^Page) {
	if p.worker != nil || p.closed || p.jsdom == nil { return }
	s := js_dom_state(p)
	if !s.layout.has { return }
	vp := s.layout.embedder.viewport(s.layout.embedder.user, p)
	if vp.width <= 0 || vp.height <= 0 { return }   // not shown: nothing to compare yet
	l := &s.layout
	if !l.resize_known {
		l.resize_known, l.resize_w, l.resize_h = true, vp.width, vp.height
		return
	}
	if vp.width == l.resize_w && vp.height == l.resize_h { return }
	l.resize_w, l.resize_h = vp.width, vp.height
	fire_window_event(p, dom.Event{type = "resize"})
}
