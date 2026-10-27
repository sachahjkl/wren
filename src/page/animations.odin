package page

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:style"

// CSS transitions and animations of a page: the document clock, the style timeline (style/timeline.odin) and its events.
//
// The clock is the shell's event loop clock (`host.now_ns`), in milliseconds; a shell that wants every page of a frame
// to see the same instant pins it with `set_frame_time` before drawing. `styles` advances the timeline on every call.
//
// Events are taken from the timeline after each step and dispatched on the next turn of the loop (never in the middle
// of a style computation or a paint) as DOM events on their element:
//   type    transitionrun / transitionstart / transitionend / transitioncancel /
//           animationstart / animationiteration / animationend / animationcancel
//   bubbles true, cancelable false
//   data    the property name (transitions, e.g. "opacity") or the animation name (animations)
//   code    elapsedTime in microseconds (elapsedTime in seconds = code / 1e6)
//   text    the pseudo-element ("" : pseudo-elements are not animated on their own)
//
// Frames: `animations_active` is true while some value changes at every frame (the shell keeps drawing); a later change
// (the end of a delay) arms a one-shot loop timer, whose firing wakes the shell. Nothing pending: no timer, no frame.

Pending_Anim_Event :: struct {
	kind:    style.Anim_Event_Kind,
	node:    base.Handle,
	name:    string,    // owned
	elapsed: f64,       // ms
}

Page_Animations :: struct {
	timeline:     ^style.Timeline,
	pending:      [dynamic]Pending_Anim_Event,
	flush_timer:  base.Handle,
	wake_timer:   base.Handle,
	wake_at:      f64,          // document clock (ms) the wake timer is set for
	frame_time:   f64,
	pinned:       bool,
	scripted:     ^Web_Anims,   // Web Animations of scripts (web_animations.odin), made on first use
}

@(private)
animations_init :: proc(p: ^Page) {
	p.anim.timeline = style.timeline_make(p.engine)
	p.anim.pending = make([dynamic]Pending_Anim_Event)
}

@(private)
animations_destroy :: proc(p: ^Page) {
	if p.anim.flush_timer != base.NIL_HANDLE { host.clear_timer(p.loop, p.anim.flush_timer) }
	if p.anim.wake_timer != base.NIL_HANDLE { host.clear_timer(p.loop, p.anim.wake_timer) }
	web_anims_destroy(p)
	style.timeline_destroy(p.anim.timeline, p.styled)
	p.anim.timeline = nil
	for e in p.anim.pending { delete(e.name) }
	delete(p.anim.pending)
}

// The document clock in milliseconds.
document_time_ms :: proc(p: ^Page) -> f64 {
	if p.anim.pinned { return p.anim.frame_time }
	return f64(host.now_ns(p.loop)) / 1e6
}

// Pins the clock for the frame being drawn (ms, the loop clock's scale); `unpin` returns to the live clock.
set_frame_time :: proc(p: ^Page, ms: f64, unpin := false) {
	p.anim.pinned = !unpin
	p.anim.frame_time = ms
}

// Some animated value changes at every frame: the shell should request the next one.
animations_active :: proc(p: ^Page) -> bool {
	return p != nil && !p.closed && style.timeline_active(p.anim.timeline)
}

// Milliseconds until an animated value changes next (0 = at every frame, -1 = nothing pending).
animations_next_ms :: proc(p: ^Page) -> f64 {
	if p == nil || p.closed { return -1 }
	return style.timeline_next_ms(p.anim.timeline)
}

// After `styles` stepped the timeline: queue its events, arm the timers.
@(private)
animations_after_tick :: proc(p: ^Page) {
	tl := p.anim.timeline
	evs := style.timeline_events(tl)
	if len(evs) > 0 {
		for e in evs { append(&p.anim.pending, Pending_Anim_Event{kind = e.kind, node = e.node, name = strings.clone(e.name), elapsed = e.elapsed}) }
		style.timeline_clear_events(tl)
		if p.anim.flush_timer == base.NIL_HANDLE {
			p.anim.flush_timer = host.set_timer(p.loop, 0, 0, flush_anim_events, p, p.scope)
		}
	}
	next := style.timeline_next_ms(tl)
	if next > 0 {
		at := document_time_ms(p) + next
		if p.anim.wake_timer == base.NIL_HANDLE || at < p.anim.wake_at - 0.5 {
			if p.anim.wake_timer != base.NIL_HANDLE { host.clear_timer(p.loop, p.anim.wake_timer) }
			p.anim.wake_timer = host.set_timer(p.loop, next, 0, wake_for_animation, p, p.scope)
			p.anim.wake_at = at
		}
	}
}

// The timer's only job is to make the loop run (the shell then draws, and `styles` steps the timeline).
@(private)
wake_for_animation :: proc(data: rawptr) {
	p := (^Page)(data)
	p.anim.wake_timer = base.NIL_HANDLE
}

@(private)
flush_anim_events :: proc(data: rawptr) {
	p := (^Page)(data)
	p.anim.flush_timer = base.NIL_HANDLE
	if p.closed { return }
	batch := p.anim.pending
	p.anim.pending = make([dynamic]Pending_Anim_Event)   // listeners may restyle and queue more
	defer {
		for e in batch { delete(e.name) }
		delete(batch)
	}
	for e in batch {
		if p.closed { return }
		if dom.get(p.doc, e.node) == nil { continue }
		dispatch_event(p, e.node, dom.Event{
			type = style.ANIM_EVENT_TYPES[e.kind], bubbles = true, cancelable = false,
			data = e.name, code = i64(e.elapsed * 1000),
		})
	}
}
