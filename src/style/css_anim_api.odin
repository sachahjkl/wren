package style

import "core:math"
import "wb:base"

// CSS animations and transitions as scripts see them (CSS Animations 2 CSSAnimation, CSS Transitions 2 CSSTransition,
// Web Animations getAnimations): each running CSS animation or transition of the timeline, known by a serial that is
// never reused, its timing and state, and the controls a script has over it (pause / play over animation-play-state,
// cancel, seek). The page makes the Animation objects (page/web_animations_css.odin).

Css_Anim_Info :: struct {
	serial:     u64,
	node:       base.Handle,
	transition: bool,
	name:       string,    // the animation name, or the transitioned property (valid until the next restyle)
	current:    f64,       // local time (ms): since the animation started, delay included
	delay, duration, iterations: f64,
	running:    bool,      // its clock advances (not paused, not canceled)
	canceled:   bool,
	finished:   bool,      // past its active interval
	filling:    bool,      // finished, its values still applied (animation-fill-mode)
}

@(private = "file")
run_info :: proc(tl: ^Timeline, ea: ^Element_Anim, r: ^Anim_Run) -> Css_Anim_Info {
	st := run_state(r)
	dur := max(f64(r.spec.duration), 0)
	iters := max(f64(r.spec.iterations), 0)
	finished := r.forced != .Canceled && st.phase == .After && !math.is_inf(iters)
	return {
		serial = r.serial, node = ea.node, name = r.name, current = r.local, delay = f64(r.spec.delay), duration = dur,
		iterations = iters, running = run_running(r), canceled = r.forced == .Canceled, finished = finished,
		filling = finished && st.effect,
	}
}

@(private = "file")
transition_info :: proc(tl: ^Timeline, ea: ^Element_Anim, tr: ^Transition) -> Css_Anim_Info {
	cur := tl.now - tr.start
	return {
		serial = tr.serial, node = ea.node, transition = true, name = prop_name(tr.prop), current = cur, delay = tr.delay,
		duration = tr.duration, iterations = 1, running = !tr.done, finished = tr.done || cur >= tr.delay + tr.duration,
	}
}

// The CSS transitions, then the CSS animations (in animation-name order) of `node`: the composite order of CSS
// Transitions 2 / CSS Animations 2 within one element. Temp allocator.
timeline_css_animations :: proc(tl: ^Timeline, node: base.Handle) -> []Css_Anim_Info {
	if tl == nil { return nil }
	ea := tl.elements[node]
	if ea == nil { return nil }
	out := make([dynamic]Css_Anim_Info, 0, len(ea.transitions) + len(ea.runs), context.temp_allocator)
	for tr in ea.transitions { append(&out, transition_info(tl, ea, tr)) }
	for r in ea.runs { if r.set == nil { append(&out, run_info(tl, ea, r)) } }
	return out[:]
}

// The timeline's document time (ms) as of its last tick.
timeline_now :: proc(tl: ^Timeline) -> f64 { return tl != nil ? tl.now : 0 }

// The nodes that have CSS animations or transitions now.
timeline_css_nodes :: proc(tl: ^Timeline) -> []base.Handle {
	if tl == nil { return nil }
	out := make([dynamic]base.Handle, 0, len(tl.elements), context.temp_allocator)
	for h, ea in tl.elements { if len(ea.transitions) > 0 || len(ea.runs) > 0 { append(&out, h) } }
	return out[:]
}

@(private = "file")
css_find :: proc(tl: ^Timeline, serial: u64) -> (ea: ^Element_Anim, r: ^Anim_Run, tr: ^Transition) {
	if tl == nil || serial == 0 { return }
	for _, e in tl.elements {
		for x in e.runs { if x.serial == serial { return e, x, nil } }
		for x in e.transitions { if x.serial == serial { return e, nil, x } }
	}
	return
}

// The state of one CSS animation or transition; false once it is gone (finished transition, name dropped).
timeline_css_info :: proc(tl: ^Timeline, serial: u64) -> (Css_Anim_Info, bool) {
	ea, r, tr := css_find(tl, serial)
	if r != nil { return run_info(tl, ea, r), true }
	if tr != nil { return transition_info(tl, ea, tr), true }
	return {}, false
}

// pause() (`paused`) or play() of a CSS animation: over its animation-play-state from now on. A transition cannot be
// held: false.
timeline_css_pause :: proc(tl: ^Timeline, serial: u64, paused: bool) -> bool {
	_, r, _ := css_find(tl, serial)
	if r == nil { return false }
	if r.forced == .Canceled {
		if paused { return true }
		r.local, r.started, r.ended, r.iteration = 0, false, false, -1   // play() after cancel(): from the start
	}
	r.forced = paused ? .Paused : .Running
	r.last_now = tl.now
	tl.dirty = true
	tl.next_ms = 0
	return true
}

// cancel(): the animation stops affecting values (animationcancel / transitioncancel when it had started).
timeline_css_cancel :: proc(tl: ^Timeline, serial: u64) -> bool {
	ea, r, tr := css_find(tl, serial)
	switch {
	case r != nil:
		if r.forced == .Canceled { return true }
		run_cancel_event(tl, ea.node, r)
		r.forced = .Canceled
		r.ended = true
	case tr != nil:
		remove_transition(tl, ea, tr, true)
	case:
		return false
	}
	tl.dirty = true
	tl.next_ms = 0
	return true
}

// currentTime = t (ms of local time) of a CSS animation or transition.
timeline_css_seek :: proc(tl: ^Timeline, serial: u64, t: f64) -> bool {
	_, r, tr := css_find(tl, serial)
	switch {
	case r != nil:
		r.local = t
		r.last_now = tl.now
	case tr != nil:
		tr.start = tl.now - t
	case:
		return false
	}
	tl.dirty = true
	tl.next_ms = 0
	return true
}
