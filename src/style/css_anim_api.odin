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
	inactive:   bool,      // its timeline has no time now
}

@(private = "file")
run_info :: proc(tl: ^Timeline, ea: ^Element_Anim, r: ^Anim_Run) -> Css_Anim_Info {
	st := run_state(r)
	dur := max(f64(r.spec.duration), 0)
	iters := max(f64(r.spec.iterations), 0)
	finished := r.forced != .Canceled && st.phase == .After && !math.is_inf(iters)
	current := r.local
	if r.timeline.kind != .Auto {
		// (the time of a progress-based one is a percentage of its timeline, from the start of its attachment range)
		t := &r.progress
		current = timeline_percent(t, t.offset) - timeline_percent(t, t.start)
	}
	return {
		serial = r.serial, node = ea.node, name = r.name, current = current, delay = f64(r.spec.delay), duration = dur,
		iterations = iters, running = run_running(r), canceled = r.forced == .Canceled, finished = finished,
		filling = finished && st.effect, inactive = r.timeline.kind != .Auto && !r.progress.active,
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

// What a CSS animation runs on; false once it is gone. A progress-based one tells its source and its attachment range.
timeline_css_timeline :: proc(tl: ^Timeline, serial: u64) -> (info: Css_Timeline_Info, ok: bool) {
	ea, r, _ := css_find(tl, serial)
	if r == nil { return }
	info.kind = r.timeline.kind
	if r.timeline.kind == .Named || r.timeline.kind == .Scroll || r.timeline.kind == .View {
		info.kind = r.src.view ? .View : .Scroll
		info.source, info.subject, info.axis, info.inset = r.src.source, r.src.subject, r.src.axis, r.src.inset
		info.range = {timeline_percent(&r.progress, r.progress.start), timeline_percent(&r.progress, r.progress.end)}
	}
	_ = ea
	return info, true
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
