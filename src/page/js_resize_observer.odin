package page

// ResizeObserver for JavaScript (api/js_observers.widl; Resize Observer §3). The browser keeps the observations and
// measures the targets from the layout; the engine (native/js/runtime/web_resize.c) keeps the script's objects. At each
// rendering update (resize_observers_update, after the animation frame callbacks and the layout they asked for, before
// the intersection observations and the paint) every observer's targets are measured; the observers with a target whose
// observed box differs from the size last reported get their entries in one call of the engine's `notify`, which takes
// them (ResizeObserver_takeEntries) and runs the script's callback. The sizes are taken again afterwards (what the
// callbacks changed), up to javascript.dom.max_resize_passes times; the rest waits for the next frame.
//
// Sizes are those of the layout's boxes (the horizontal writing mode: the inline size is the width), not the transformed
// ones getBoundingClientRect gives: a box that is not rendered (display: none, not connected, a non-replaced inline) is
// 0 x 0. The targets are pinned for as long as they are observed, as a script's reference to them would.

import "core:math"
import "wb:base"
import "wb:dom"

Ro_Box :: enum u8 { Content, Border, Device }   // the ResizeObserverBoxOptions, in the order the engine numbers them

@(private)
Ro_Target :: struct {
	node: base.Handle,
	box:  Ro_Box,
	last: [2]f64,   // the observed box's size when last reported (inline, block): 0 x 0 before the first report
}

@(private)
Resize_Observer :: struct {
	page:     ^Page,
	self:     u64,
	instance: u32,
	notify:   u32,
	user:     u32,
	targets:  [dynamic]Ro_Target,
	pending:  [dynamic]u8,   // the entries the engine is to take, packed (ro_entry_size bytes each)
}

// An entry: target u64, then eight f64: borderBoxSize (inline, block), contentBoxSize, devicePixelContentBoxSize, and
// the content rect's left and top (the padding's offsets). Little endian.
RO_ENTRY_SIZE :: 8 + 8 * 8

@(private)
ro_vt := Object_VTable{name = "ResizeObserver", destroy = proc(p: ^Page, data: rawptr) {
	ro := (^Resize_Observer)(data)
	ro_clear(p, ro)
	if p.web != nil {
		list := &p.web.observers.resize
		for x, i in list { if x == ro { ordered_remove(list, i); break } }
		observers_refresh(p)
	}
	delete(ro.targets)
	delete(ro.pending)
	free(ro)
}}

@(private)
resize_observer_of :: proc(c: ^Call, h: u64) -> ^Resize_Observer {
	if call_doc(c) == nil { return nil }
	return (^Resize_Observer)(object_data(c.page, h, &ro_vt))
}

@(private)
ro_clear :: proc(p: ^Page, ro: ^Resize_Observer) {
	if !p.closed && p.doc != nil { for t in ro.targets { dom.unpin(p.doc, t.node) } }
	clear(&ro.targets)
	clear(&ro.pending)
}

ResizeObserver_create :: proc(c: ^Call, notify: u32, user: i32) -> u64 {
	if call_doc(c) == nil { return 0 }
	ro := new(Resize_Observer)
	ro.page, ro.instance, ro.notify, ro.user = c.page, c.owner, notify, u32(user)
	h := object_create(c.page, &ro_vt, ro, c.owner)
	ro.self = h
	append(&c.page.web.observers.resize, ro)
	return h
}

ResizeObserver_observe :: proc(c: ^Call, observer: u64, target: Api_Element, box: i32) -> Api_Error {
	ro := resize_observer_of(c, observer)
	if ro == nil { return fail(c, .Invalid_Handle, "not a ResizeObserver") }
	h := H(target.handle)
	b := Ro_Box(clamp(box, 0, i32(Ro_Box.Device)))
	// observing a target again with another box replaces its observation (and it is reported again); with the same, nothing
	for &t in ro.targets {
		if t.node != h { continue }
		if t.box == b { return .None }
		t.box, t.last = b, {}
		c.page.web.ro_active, c.page.web.ro_pending = true, true
		return .None
	}
	if !dom.pin(c.page.doc, h) { return fail(c, .Invalid_Handle, "not a live Element") }
	append(&ro.targets, Ro_Target{node = h, box = b})
	c.page.web.ro_active, c.page.web.ro_pending = true, true
	return .None
}

ResizeObserver_unobserve :: proc(c: ^Call, observer: u64, target: Api_Element) {
	ro := resize_observer_of(c, observer)
	if ro == nil { return }
	h := H(target.handle)
	for t, i in ro.targets {
		if t.node != h { continue }
		ordered_remove(&ro.targets, i)
		dom.unpin(c.page.doc, h)
		break
	}
	observers_refresh(c.page)
}

ResizeObserver_disconnect :: proc(c: ^Call, observer: u64) {
	ro := resize_observer_of(c, observer)
	if ro == nil { return }
	ro_clear(c.page, ro)
	observers_refresh(c.page)
}

// How many targets the observer observes: the engine keeps the observer's script object alive while it is not 0.
ResizeObserver_observed :: proc(c: ^Call, observer: u64) -> u32 {
	ro := resize_observer_of(c, observer)
	return ro == nil ? 0 : u32(len(ro.targets))
}

// The entries of the delivery in progress (the engine asks again with a larger buffer when this did not fit).
ResizeObserver_takeEntries :: proc(c: ^Call, observer: u64) -> []u8 {
	ro := resize_observer_of(c, observer)
	return ro == nil ? nil : ro.pending[:]
}

@(private)
Ro_Sizes :: struct {
	border, content, device: [2]f64,
	left, top:               f64,
}

// The boxes of a target as the layout has them now. Not rendered: all zero.
@(private)
ro_measure :: proc(p: ^Page, f: ^Obs_Frame, node: base.Handle) -> (m: Ro_Sizes) {
	if !dom.is_connected(p.doc, node) { return }
	g := obs_geometry(f, node)
	if !g.ok || is_inline_box(g) { return }
	m.border = {f64(g.border.max.x - g.border.min.x), f64(g.border.max.y - g.border.min.y)}
	m.content = {f64(g.content.max.x - g.content.min.x), f64(g.content.max.y - g.content.min.y)}
	m.device = {math.round(m.content[0] * f.vp.scale), math.round(m.content[1] * f.vp.scale)}
	m.left, m.top = f64(g.content.min.x - g.padding.min.x), f64(g.content.min.y - g.padding.min.y)
	return
}

// "Gather active resize observations" of one observer: the entries (packed in ro.pending) of the targets whose observed
// box changed since they were reported. Returns how many.
@(private)
ro_gather :: proc(p: ^Page, f: ^Obs_Frame, ro: ^Resize_Observer) -> int {
	clear(&ro.pending)
	n := 0
	for &t in ro.targets {
		m := ro_measure(p, f, t.node)
		size := m.content
		switch t.box {
		case .Content:
		case .Border: size = m.border
		case .Device: size = m.device
		}
		if size == t.last { continue }
		t.last = size
		put_u64(&ro.pending, u64(t.node))
		for v in ([8]f64{m.border[0], m.border[1], m.content[0], m.content[1], m.device[0], m.device[1], m.left, m.top}) {
			put_u64(&ro.pending, transmute(u64)v)
		}
		n += 1
	}
	return n
}

// The resize observations of a rendering update. The observers are looked up again by handle after each delivery: a
// callback may disconnect or drop any of them.
@(private)
resize_observers_update :: proc(p: ^Page) {
	w := p.web
	if p.closed || !w.ro_active { return }
	w.ro_pending = false
	passes := max(p.settings.dom.max_resize_passes, 1)
	delivered := false
	for _ in 0 ..< passes {
		delivered = false
		handles := make([dynamic]u64, 0, len(w.observers.resize), context.temp_allocator)
		for ro in w.observers.resize { append(&handles, ro.self) }
		f := obs_frame(p)
		for h in handles {
			ro := (^Resize_Observer)(object_data(p, h, &ro_vt))
			if ro == nil || len(ro.targets) == 0 { continue }
			if ro_gather(p, &f, ro) == 0 { continue }
			inst := instance_by_index(p, ro.instance)
			if inst == nil { clear(&ro.pending); continue }
			delivered = true
			argv := [1]u32{ro.user}
			call_guest(p, inst, ro.notify, argv[:])
			if p.closed { return }
			if (^Resize_Observer)(object_data(p, h, &ro_vt)) == ro { clear(&ro.pending) }
			f = obs_frame(p)   // the callback may have changed the layout
		}
		if !delivered { break }
	}
	// still changing after the last pass: the next frame delivers the rest
	if delivered && w.ro_active { w.ro_pending = true }
}
