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

@(private)
Ro_Key :: struct {
	layout:        rawptr,
	valid:         bool,
	layout_passes: u64,
	layout_serial: u64,
	mutations:     u64,
	scale:         f64,
	target_serial: u64,
}

@(private)
Io_Key :: struct {
	layout:        rawptr,
	valid:         bool,
	passes:        u64,
	serial:        u64,
	mutations:     u64,
	scroll_digest: u64,
	vp:            Viewport,
	target_serial: u64,
}

Layout_Observers :: struct {
	resize:           [dynamic]^Resize_Observer,         // in creation order
	intersection:     [dynamic]^Intersection_Observer,
	io_task:          bool,                              // the task that delivers intersection entries is queued
	ro_target_serial: u64,                               // bumped when a ResizeObserver target is observed or changes box
	ro_key:           Ro_Key,                            // last state for which ResizeObserver converged
	ro_has_key:       bool,
	io_target_serial: u64,                               // bumped when an IntersectionObserver target is observed
	io_key:           Io_Key,                            // last state for which IntersectionObserver ran
	io_has_key:       bool,
}

// The layout of one stretch of the rendering update, read once: the view (where every space is for the viewport and the
// scroll of the page) is made once for all the boxes read, not for each. A callback of the script may change the layout:
// make a new one after running any.
@(private)
Obs_Frame :: struct {
	ok:       bool,
	l:        ^lay.Layout,
	vp:       Viewport,
	view_ptr: ^lay.View,   // non-nil: borrowed cached View (Tab or Js_Layout)
	view:     lay.View,    // fallback View when view_ptr is nil
}

@(private)
obs_view :: #force_inline proc(f: ^Obs_Frame) -> ^lay.View {
	return f.view_ptr != nil ? f.view_ptr : &f.view
}

@(private)
obs_frame_from :: proc(l: ^lay.Layout, vp: Viewport, p: ^Page = nil) -> (f: Obs_Frame) {
	f.l, f.vp = l, vp
	if l == nil || !l.valid { return }
	if v := page_layout_view(p, l, vp); v != nil {
		f.view_ptr = v
	} else {
		s := f32(vp.scale)
		f.view = lay.view_make(l, {f32(vp.width) * s, f32(vp.height) * s}, f32(vp.scroll_y) * s, cull = false)
	}
	f.ok = true
	return
}

@(private)
obs_frame :: proc(p: ^Page) -> Obs_Frame {
	l, vp := js_layout_now(p)
	return obs_frame_from(l, vp, p)
}

@(private)
obs_geometry :: proc(f: ^Obs_Frame, h: base.Handle) -> Element_Geometry {
	if !f.ok { return {} }
	r, ok := lay.box_of_view(f.l, obs_view(f), h)
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
	if !w.ro_active { w.ro_pending = false; w.observers.ro_has_key = false }
	if !w.io_active { w.io_pending = false; w.observers.io_has_key = false }
}

@(private)
layout_observers_destroy :: proc(w: ^Web_State) {
	delete(w.observers.resize)
	delete(w.observers.intersection)
	w.observers = {}
}
