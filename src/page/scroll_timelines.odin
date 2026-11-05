package page

import "wb:base"
import lay "wb:layout"
import "wb:style"

// The scroll and view progress timelines of a page (style/scroll_timeline.odin), measured from a layout: the embedder calls this
// before the frame's style pass, and again after its layout, whose result the next frame shows if it moved them (true).

@(private = "file")
Timeline_Reading :: struct {
	l:  ^lay.Layout,
	vp: Viewport,
}

@(private = "file")
reading_scroller :: proc(user: rawptr, node: base.Handle) -> (m: style.Scroll_Measure) {
	r := (^Timeline_Reading)(user)
	l, s := r.l, r.vp.scale
	if node == base.NIL_HANDLE {
		lo_x, hi_x := lay.doc_scroll_x_range(l, f32(r.vp.width * s))
		lo_y, hi_y := lay.doc_scroll_y_range(l, f32(r.vp.height * s))
		m.pos = {r.vp.scroll_x, r.vp.scroll_y}
		m.lo, m.hi = {f64(lo_x) / s, f64(lo_y) / s}, {f64(hi_x) / s, f64(hi_y) / s}
		m.port = doc_client_size(l, r.vp)
		m.ok = true
		return
	}
	off, scrolls := lay.scroll_of(l, node)
	if !scrolls { return }
	hi, _ := lay.scroll_max(l, node)
	lo := lay.scroll_min(l, node)
	port, _ := lay.scroll_port(l, node)
	m.pos = {f64(off.x) / s, f64(off.y) / s}
	m.lo, m.hi = {f64(lo.x) / s, f64(lo.y) / s}, {f64(hi.x) / s, f64(hi.y) / s}
	m.port = {f64(port.max.x - port.min.x) / s, f64(port.max.y - port.min.y) / s}
	m.ok = true
	return
}

@(private = "file")
reading_subject :: proc(user: rawptr, subject, source: base.Handle) -> (lo, hi: [2]f64, ok: bool) {
	r := (^Timeline_Reading)(user)
	l, s := r.l, f32(r.vp.scale)
	view := [2]f32{f32(r.vp.width) * s, f32(r.vp.height) * s}
	doc_scroll := f32(r.vp.scroll_y) * s
	box, found := lay.box_of(l, subject, view, doc_scroll)
	if !found { return }
	at := [2]f32{}
	if source != base.NIL_HANDLE {
		// (box_of applies the containers' offsets: the scrollable area of `source` starts at its padding box, at offset zero)
		src, has := lay.box_of(l, source, view, doc_scroll)
		off, scrolls := lay.scroll_of(l, source)
		if !has || !scrolls { return }
		at = src.padding.min - off
	}
	lo = {f64((box.border.min.x - at.x) / s), f64((box.border.min.y - at.y) / s)}
	hi = {f64((box.border.max.x - at.x) / s), f64((box.border.max.y - at.y) / s)}
	return lo, hi, true
}

// Measures the page's timelines on layout `l`, shown as `vp` says. True: what they show moved.
scroll_timelines_sample :: proc(p: ^Page, l: ^lay.Layout, vp: Viewport) -> bool {
	if p == nil || p.closed || p.styled == nil || l == nil || !l.valid || p.doc == nil { return false }
	r := Timeline_Reading{l, vp}
	if r.vp.scale <= 0 { r.vp.scale = 1 }
	probe := style.Timeline_Probe{user = &r, root = jd_document_element(p.doc), scroller = reading_scroller, subject = reading_subject}
	return style.timeline_scroll_sample(p.anim.timeline, p.doc, p.styled, probe)
}
