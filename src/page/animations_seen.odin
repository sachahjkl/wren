package page

// Who can see an animated element (style.Seen_Probe): the timeline asks it before it asks for the next frame. The answer comes
// from the layout the last frame painted, and only when that layout is the page as it is now (no mutation, no style pass, the same
// viewport since): otherwise every element counts as seen, and the frame that follows lays out and asks again. An element is unseen
//   * when it has no box: it is not rendered (display: none, or inside such an element); display: contents is seen;
//   * when what is animated only paints (style.paint_only) and the boxes of the element and of everything it holds lie farther
//     than SEEN_MARGIN_VIEWPORTS viewports from the one shown.
// What moves boxes is seen as soon as it has one: a change of its size moves the boxes around it.

import "wb:base"
import lay "wb:layout"
import "wb:style"

// How far from the viewport (in viewports, on each side) a box still counts as seen: what a transform may bring in before the next look.
SEEN_MARGIN_VIEWPORTS :: 1.0
// Most boxes looked at under one animated element; past it, it counts as seen.
SEEN_BOXES_MAX :: 4096
// The layout's viewport and the one shown are the same below this (device px).
SEEN_SIZE_SLACK_PX :: 0.5

// One tick's reading of the layout (animations_seen_begin).
@(private)
Anim_Seen :: struct {
	ok:    bool,   // the layout is the page as it is: its answers hold
	frame: Obs_Frame,
}

@(private)
animations_seen_install :: proc(p: ^Page) {
	style.timeline_set_seen(p.anim.timeline, style.Seen_Probe{user = p, begin = animations_seen_begin, seen = animations_seen})
}

@(private = "file")
animations_seen_begin :: proc(user: rawptr) {
	p := (^Page)(user)
	s := &p.anim.seen
	s^ = {}
	if p.worker != nil || p.jsdom == nil || p.styled == nil || p.doc == nil { return }
	jl := &p.jsdom.layout
	if !jl.has || jl.result == nil { return }
	l := jl.result
	vp := jl.embedder.viewport(jl.embedder.user, p)
	if vp.scale <= 0 { vp.scale = 1 }
	size := lay.Vec2{f32(vp.width * vp.scale), f32(vp.height * vp.scale)}
	// (the viewport went through CSS px and back: equal to a fraction of a device pixel)
	same_size := abs(l.viewport.x - size.x) < SEEN_SIZE_SLACK_PX && abs(l.viewport.y - size.y) < SEEN_SIZE_SLACK_PX
	if !l.valid || l.anchor_stale || l.mutations != p.doc.mutations || l.serial != p.styled.serial || !same_size { return }
	s.frame = Obs_Frame{ok = true, l = l, vp = vp, view = lay.view_make(l, size, f32(vp.scroll_y * vp.scale), cull = false)}
	s.ok = true
}

@(private = "file")
animations_seen :: proc(user: rawptr, node: base.Handle, moves_boxes: bool) -> bool {
	p := (^Page)(user)
	s := &p.anim.seen
	if !s.ok { return true }
	l := s.frame.l
	bi := lay.box_index(l, node)
	if bi == lay.NONE {
		c := style.style_of(p.styled, node)
		return c == nil || c.display == .Contents
	}
	if moves_boxes { return true }
	// the viewport and its margin, CSS px of the viewport's coordinates (what geometry_of_rects gives)
	w, h := s.frame.vp.width, s.frame.vp.height
	lo := [2]f64{-w * SEEN_MARGIN_VIEWPORTS, -h * SEEN_MARGIN_VIEWPORTS}
	hi := [2]f64{w * (1 + SEEN_MARGIN_VIEWPORTS), h * (1 + SEEN_MARGIN_VIEWPORTS)}
	// the box and those under it, in tree order
	at, n := bi, 0
	for at != lay.NONE {
		n += 1
		if n > SEEN_BOXES_MAX { return true }
		b := &l.boxes[at]
		if b.node != base.NIL_HANDLE {
			r, ok := lay.box_of_view(l, &s.frame.view, b.node)
			g := geometry_of_rects(l, s.frame.vp, b.node, r, ok)
			if g.ok {
				c := g.client
				if c.x <= hi.x && c.x + c.width >= lo.x && c.y <= hi.y && c.y + c.height >= lo.y { return true }
			}
		}
		// the next box in tree order inside the element's
		if b.first != lay.NONE { at = b.first; continue }
		for at != bi && l.boxes[at].next == lay.NONE { at = l.boxes[at].parent }
		at = at == bi ? lay.NONE : l.boxes[at].next
	}
	return false
}
