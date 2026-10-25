package page

// What ResizeObserver and IntersectionObserver share (api/js_observers.widl): the observers of a page, and the layout
// as one rendering update reads it. The observations live here, in the browser: the engine only keeps the script's
// objects (the callback, the observer, the entries it hands out) and is called back when there is something to deliver.
//
// The rendering update (run_animation_frames) runs the resize observations, then the intersection ones, after the
// animation frame callbacks and the layout they asked for (a reading of the geometry brings it up to date first, so the
// observers see the layout of this frame, before it is painted), as HTML's "update the rendering" orders them.

import "wb:base"
import lay "wb:layout"

Layout_Observers :: struct {
	resize:       [dynamic]^Resize_Observer,         // in creation order
	intersection: [dynamic]^Intersection_Observer,
	io_task:      bool,                              // the task that delivers intersection entries is queued
}

// The layout of one stretch of the rendering update, read once: the view (where every space is for the viewport and the
// scroll of the page) is made once for all the boxes read, not for each. A callback of the script may change the layout:
// make a new one after running any.
@(private)
Obs_Frame :: struct {
	ok:   bool,
	l:    ^lay.Layout,
	vp:   Viewport,
	view: lay.View,
}

@(private)
obs_frame :: proc(p: ^Page) -> (f: Obs_Frame) {
	l, vp := js_layout_now(p)
	f.l, f.vp = l, vp
	if l == nil || !l.valid { return }
	s := f32(vp.scale)
	f.view = lay.view_make(l, {f32(vp.width) * s, f32(vp.height) * s}, f32(vp.scroll_y) * s, cull = false)
	f.ok = true
	return
}

@(private)
obs_geometry :: proc(f: ^Obs_Frame, h: base.Handle) -> Element_Geometry {
	if !f.ok { return {} }
	r, ok := lay.box_of_view(f.l, &f.view, h)
	return geometry_of_rects(f.l, f.vp, h, r, ok)
}

// The wake-up flags of wants_animation_frame follow what is observed: a target just observed wants a frame, and nothing
// is computed for a page that observes nothing.
@(private)
observers_refresh :: proc(p: ^Page) {
	w := p.web
	if w == nil { return }
	w.ro_active, w.io_active = false, false
	for ro in w.observers.resize { if len(ro.targets) > 0 { w.ro_active = true; break } }
	for io in w.observers.intersection { if len(io.targets) > 0 { w.io_active = true; break } }
	if !w.ro_active { w.ro_pending = false }
	if !w.io_active { w.io_pending = false }
}

@(private)
layout_observers_destroy :: proc(w: ^Web_State) {
	delete(w.observers.resize)
	delete(w.observers.intersection)
	w.observers = {}
}
