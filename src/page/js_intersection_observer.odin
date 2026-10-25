package page

// IntersectionObserver for JavaScript (api/js_observers.widl; Intersection Observer §3). The browser keeps the
// observations and computes them from the layout at each rendering update (intersection_observers_update, after the
// animation frame callbacks and the resize observations, before the paint): for each target the rectangle of its border
// box where it is drawn, cut by the clips of the boxes between it and the root (overflow other than visible, each grown
// by scrollMargin), then by the root's rectangle grown by rootMargin (the viewport, or the root element's border box).
// An entry is queued when the target's threshold index or its intersecting state changed (and at the first update after
// observe), and a task of the page (post_page_task, not a timer of the script) calls the engine's `notify` for the
// observers that have entries; the engine takes them (IntersectionObserver_takeRecords) and runs the script's callback.
// A target is pinned while it is observed and while an entry names it.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:dom"
import lay "wb:layout"

@(private)
Io_Length :: struct {
	v:   f64,
	pct: bool,   // a percentage (of the rectangle's size), else CSS pixels
}

@(private)
Io_Target :: struct {
	node:        base.Handle,
	index:       int,    // the number of thresholds at or below the last ratio: -1 before the first update
	intersecting: bool,
}

@(private)
Io_Record :: struct {
	target:    base.Handle,
	time:      f64,
	ratio:     f64,
	flags:     u32,   // bit 0 isIntersecting, bit 1 isVisible, bit 2 rootBounds present
	root:      [4]f64,   // x, y, width, height (CSS px, viewport coordinates)
	bounding:  [4]f64,
	intersect: [4]f64,
}

@(private)
Intersection_Observer :: struct {
	page:         ^Page,
	self:         u64,
	instance:     u32,
	notify:       u32,
	user:         u32,
	root:         base.Handle,   // the root element or document; NIL: the implicit root, the viewport
	root_element: bool,
	margin:       [4]Io_Length,  // top, right, bottom, left
	scroll:       [4]Io_Length,
	margin_text:  string,        // owned: the serialization rootMargin gives
	scroll_text:  string,
	thresholds:   []f64,         // owned, ascending
	targets:      [dynamic]Io_Target,
	queue:        [dynamic]Io_Record,
	taken:        int,           // records the engine took (removed at release)
}

// A record: target u64, time f64, ratio f64, flags u32, u32 0, then twelve f64: the rootBounds, boundingClientRect and
// intersectionRect as x, y, width, height. Little endian.
IO_RECORD_SIZE :: 8 + 8 + 8 + 8 + 12 * 8

@(private)
io_vt := Object_VTable{name = "IntersectionObserver", destroy = proc(p: ^Page, data: rawptr) {
	io := (^Intersection_Observer)(data)
	io_clear_targets(p, io)
	io_clear_queue(p, io)
	if p.web != nil {
		list := &p.web.observers.intersection
		for x, i in list { if x == io { ordered_remove(list, i); break } }
		observers_refresh(p)
	}
	delete(io.targets)
	delete(io.queue)
	delete(io.margin_text)
	delete(io.scroll_text)
	delete(io.thresholds)
	free(io)
}}

@(private)
intersection_observer_of :: proc(c: ^Call, h: u64) -> ^Intersection_Observer {
	if call_doc(c) == nil { return nil }
	return (^Intersection_Observer)(object_data(c.page, h, &io_vt))
}

@(private)
io_clear_targets :: proc(p: ^Page, io: ^Intersection_Observer) {
	if !p.closed && p.doc != nil { for t in io.targets { dom.unpin(p.doc, t.node) } }
	clear(&io.targets)
}

@(private)
io_clear_queue :: proc(p: ^Page, io: ^Intersection_Observer) {
	if !p.closed && p.doc != nil { for r in io.queue { dom.unpin(p.doc, r.target) } }
	clear(&io.queue)
	io.taken = 0
}

// rootMargin / scrollMargin: one to four <length> or <percentage> (px or %, or a bare 0), in CSS margin order. The
// text is the serialization the attribute gives: four sides, each as a number and its unit.
@(private)
parse_margin :: proc(text: string) -> (sides: [4]Io_Length, canonical: string, ok: bool) {
	parts := strings.fields(text, context.temp_allocator)
	if len(parts) == 0 || len(parts) > 4 { return }
	got: [4]Io_Length
	for part, i in parts {
		s := part
		if s == "0" { got[i] = {}; continue }
		if len(s) == 0 || !(s[0] == '-' || s[0] == '.' || (s[0] >= '0' && s[0] <= '9')) { return }
		v, n, parsed := strconv.parse_f64_prefix(s)
		if !parsed || n == 0 || math.is_nan(v) || math.is_inf(v) { return }
		unit := s[n:]
		switch {
		case unit == "%": got[i] = {v, true}
		case strings.equal_fold(unit, "px"): got[i] = {v, false}
		case: return
		}
	}
	switch len(parts) {   // CSS margin order: missing sides copy the opposite one
	case 1: got[1], got[2], got[3] = got[0], got[0], got[0]
	case 2: got[2], got[3] = got[0], got[1]
	case 3: got[3] = got[1]
	}
	b := strings.builder_make(context.temp_allocator)
	for s, i in got {
		if i > 0 { strings.write_byte(&b, ' ') }
		v := s.v == 0 ? 0 : s.v   // -0 serializes as 0
		fmt.sbprintf(&b, "%v%s", v, s.pct ? "%" : "px")
	}
	return got, strings.clone(strings.to_string(b)), true
}

IntersectionObserver_create :: proc(c: ^Call, notify: u32, user: i32, root: u64, root_margin: string, scroll_margin: string, thresholds: []u8) -> (u64, Api_Error) {
	if call_doc(c) == nil { return 0, fail(c, .Invalid_State, "there is no document to observe") }
	margin, mtext, ok := parse_margin(root_margin)
	if !ok { return 0, fail(c, .Syntax, "Failed to construct 'IntersectionObserver': rootMargin must be specified in pixels or percent.") }
	scroll, stext, sok := parse_margin(scroll_margin)
	if !sok {
		delete(mtext)
		return 0, fail(c, .Syntax, "Failed to construct 'IntersectionObserver': scrollMargin must be specified in pixels or percent.")
	}
	io := new(Intersection_Observer)
	io.page, io.instance, io.notify, io.user = c.page, c.owner, notify, u32(user)
	io.margin, io.scroll, io.margin_text, io.scroll_text = margin, scroll, mtext, stext
	io.thresholds = make([]f64, len(thresholds) / 8)
	for i in 0 ..< len(io.thresholds) {
		bits: u64
		for k in 0 ..< 8 { bits |= u64(thresholds[i * 8 + k]) << (8 * uint(k)) }
		io.thresholds[i] = transmute(f64)bits
	}
	slice.sort(io.thresholds)
	if len(io.thresholds) == 0 { io.thresholds = make([]f64, 1) }
	if root != 0 {
		if n := lookup_Node(c, root); n != nil && (n.kind == .Element || n.kind == .Document) {
			io.root, io.root_element = H(root), n.kind == .Element   // (the script's observer holds the root's wrapper, which pins it)
		}
	}
	h := object_create(c.page, &io_vt, io, c.owner)
	io.self = h
	append(&c.page.web.observers.intersection, io)
	return h, .None
}

IntersectionObserver_rootMargin :: proc(c: ^Call, observer: u64) -> string {
	io := intersection_observer_of(c, observer)
	return io == nil ? "" : io.margin_text
}

IntersectionObserver_scrollMargin :: proc(c: ^Call, observer: u64) -> string {
	io := intersection_observer_of(c, observer)
	return io == nil ? "" : io.scroll_text
}

IntersectionObserver_observe :: proc(c: ^Call, observer: u64, target: Api_Element) -> Api_Error {
	io := intersection_observer_of(c, observer)
	if io == nil { return fail(c, .Invalid_Handle, "not an IntersectionObserver") }
	h := H(target.handle)
	for t in io.targets { if t.node == h { return .None } }
	if !dom.pin(c.page.doc, h) { return fail(c, .Invalid_Handle, "not a live Element") }
	append(&io.targets, Io_Target{node = h, index = -1})
	c.page.web.io_active, c.page.web.io_pending = true, true
	return .None
}

IntersectionObserver_unobserve :: proc(c: ^Call, observer: u64, target: Api_Element) {
	io := intersection_observer_of(c, observer)
	if io == nil { return }
	h := H(target.handle)
	for t, i in io.targets {
		if t.node != h { continue }
		ordered_remove(&io.targets, i)
		dom.unpin(c.page.doc, h)
		break
	}
	observers_refresh(c.page)
}

// The records waiting stay (the specification's disconnect leaves them for takeRecords).
IntersectionObserver_disconnect :: proc(c: ^Call, observer: u64) {
	io := intersection_observer_of(c, observer)
	if io == nil { return }
	io_clear_targets(c.page, io)
	observers_refresh(c.page)
}

// How many targets the observer observes (the engine keeps the observer alive while it is not 0).
IntersectionObserver_observed :: proc(c: ^Call, observer: u64) -> u32 {
	io := intersection_observer_of(c, observer)
	return io == nil ? 0 : u32(len(io.targets))
}

// The records waiting, packed (IO_RECORD_SIZE bytes each). Nothing changes until IntersectionObserver_release, so a call
// that did not fit can be made again.
IntersectionObserver_takeRecords :: proc(c: ^Call, observer: u64) -> []u8 {
	io := intersection_observer_of(c, observer)
	if io == nil { return nil }
	b := make([dynamic]u8, 0, IO_RECORD_SIZE * len(io.queue), context.temp_allocator)
	for &r in io.queue {
		put_u64(&b, u64(r.target))
		put_u64(&b, transmute(u64)r.time)
		put_u64(&b, transmute(u64)r.ratio)
		put_u32(&b, r.flags)
		put_u32(&b, 0)
		for v in r.root { put_u64(&b, transmute(u64)v) }
		for v in r.bounding { put_u64(&b, transmute(u64)v) }
		for v in r.intersect { put_u64(&b, transmute(u64)v) }
	}
	io.taken = len(io.queue)
	return b[:]
}

// The engine made the entries it took: they leave the queue (and the pins of their targets go).
IntersectionObserver_release :: proc(c: ^Call, observer: u64) {
	io := intersection_observer_of(c, observer)
	if io == nil { return }
	n := min(io.taken, len(io.queue))
	for i in 0 ..< n { dom.unpin(c.page.doc, io.queue[i].target) }
	remove_range(&io.queue, 0, n)
	io.taken = 0
}

////////////////////////////////
// The computation

@(private)
Io_Rect :: struct { x0, y0, x1, y1: f64 }   // viewport coordinates, CSS px; x1 < x0 once nothing is left

@(private)
io_intersect :: proc(a, b: Io_Rect) -> Io_Rect {
	return {max(a.x0, b.x0), max(a.y0, b.y0), min(a.x1, b.x1), min(a.y1, b.y1)}
}

// The rectangle grown by a margin (percentages are of the rectangle's own size)
@(private)
io_grow :: proc(r: Io_Rect, m: [4]Io_Length) -> Io_Rect {
	w, h := r.x1 - r.x0, r.y1 - r.y0
	side :: proc(l: Io_Length, size: f64) -> f64 { return l.pct ? l.v / 100 * size : l.v }
	return {r.x0 - side(m[3], w), r.y0 - side(m[0], h), r.x1 + side(m[1], w), r.y1 + side(m[2], h)}
}

@(private)
io_rect_values :: proc(r: Io_Rect) -> [4]f64 { return {r.x0, r.y0, r.x1 - r.x0, r.y1 - r.y0} }

// Index of the first threshold above the ratio.
@(private)
io_threshold_index :: proc(thresholds: []f64, ratio: f64) -> int {
	i := 0
	for i < len(thresholds) && thresholds[i] <= ratio { i += 1 }
	return i
}

// The area of `target` (viewport coordinates) that the boxes between it and the root let through, then the root's:
// "compute the intersection". ok = false: nothing is left (an empty result still counts when its edges touch).
@(private)
io_clipped :: proc(p: ^Page, f: ^Obs_Frame, io: ^Intersection_Observer, g: Element_Geometry, root: Io_Rect) -> (Io_Rect, bool) {
	r := Io_Rect{g.client.x, g.client.y, g.client.x + g.client.width, g.client.y + g.client.height}
	if g.box != nil && !g.fixed {
		s := f.vp.scale
		for ci := g.box.clip; ci != lay.NONE; ci = f.l.clips[ci].parent {
			// the clips of the root element and of what is outside it are not between the target and the root
			if io.root_element && f.l.boxes[f.l.clips[ci].box].node == io.root { break }
			b, ok := lay.clip_bounds(f.l, &f.view, ci)
			if !ok { continue }
			c := io_grow(Io_Rect{f64(b.min.x) / s - f.vp.scroll_x, f64(b.min.y) / s, f64(b.max.x) / s - f.vp.scroll_x, f64(b.max.y) / s}, io.scroll)
			r = io_intersect(r, c)
		}
	}
	r = io_intersect(r, root)
	return r, r.x1 >= r.x0 && r.y1 >= r.y0
}

// "Run the update intersection observations steps" for one observer; true when some entry was queued.
@(private)
io_update :: proc(p: ^Page, f: ^Obs_Frame, io: ^Intersection_Observer, time: f64) -> (queued: bool) {
	d := p.doc
	root := Io_Rect{0, 0, f.vp.width, f.vp.height}
	if io.root_element {
		g := obs_geometry(f, io.root)
		root = {g.client.x, g.client.y, g.client.x + g.client.width, g.client.y + g.client.height}
	}
	root = io_grow(root, io.margin)
	root_connected := io.root == base.NIL_HANDLE || dom.is_connected(d, io.root)
	for &t in io.targets {
		g := obs_geometry(f, t.node)
		// HTML "is rendered": connected, with a box, and inside its root element
		rendered := dom.is_connected(d, t.node) && root_connected && g.ok &&
			(!io.root_element || (io.root != t.node && dom.contains(d, io.root, t.node)))
		bounding := [4]f64{g.client.x, g.client.y, g.client.width, g.client.height}
		inter: Io_Rect
		intersecting := false
		if rendered { inter, intersecting = io_clipped(p, f, io, g, root) }
		area := g.client.width * g.client.height
		ratio := 0.0
		if intersecting {
			iw, ih := inter.x1 - inter.x0, inter.y1 - inter.y0
			ratio = area > 0 ? min(1, (iw * ih) / area) : 1
		}
		index := io_threshold_index(io.thresholds, ratio)
		if index == t.index && intersecting == t.intersecting { continue }
		t.index, t.intersecting = index, intersecting
		rec := Io_Record{target = t.node, time = time, ratio = ratio, bounding = bounding}
		if intersecting { rec.flags |= 1; rec.intersect = io_rect_values(inter) }
		if rendered || io.root == base.NIL_HANDLE { rec.flags |= 4; rec.root = io_rect_values(root) }
		dom.pin(d, t.node)
		append(&io.queue, rec)
		queued = true
	}
	return
}

@(private)
intersection_observers_update :: proc(p: ^Page) {
	w := p.web
	if p.closed || !w.io_active { return }
	w.io_pending = false
	f := obs_frame(p)
	time := page_now_ms(p)
	queued := false
	// (no script runs here: the list cannot change under the loop)
	for io in w.observers.intersection {
		if len(io.targets) > 0 && io_update(p, &f, io, time) { queued = true }
	}
	if queued && !w.observers.io_task {
		w.observers.io_task = true
		post_page_task(p, io_deliver, nil)
	}
}

// "Notify intersection observers": a task of its own, as the specification queues it.
@(private)
io_deliver :: proc(p: ^Page, _: rawptr) {
	if p == nil || p.closed || p.web == nil { return }
	w := p.web
	w.observers.io_task = false
	handles := make([dynamic]u64, 0, len(w.observers.intersection), context.temp_allocator)
	for io in w.observers.intersection { if len(io.queue) > 0 && len(io.targets) > 0 { append(&handles, io.self) } }
	for h in handles {
		io := (^Intersection_Observer)(object_data(p, h, &io_vt))
		if io == nil || len(io.queue) == 0 { continue }
		inst := instance_by_index(p, io.instance)
		if inst == nil { continue }
		argv := [1]u32{io.user}
		call_guest(p, inst, io.notify, argv[:])
		if p.closed { return }
	}
}
