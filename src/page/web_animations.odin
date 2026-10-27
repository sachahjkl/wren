package page

import "core:math"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:style"

// Web Animations 1 for scripts (api/animations.widl; the JavaScript objects: native/js/runtime/web_animations.c).
//
// Each Animation is a host object holding the animation's state as Web Animations 1 §4.4 defines it: start time, hold
// time, playback rate and pending playback rate, pending play or pause task, previous current time, the states of its
// ready and finished promises, its replace state. Its keyframe effect (target, keyframes, timing) lives on the style
// timeline (style/script_anim.odin), which computes the effect's values from the clock the page gives it at each
// change (style.timeline_script_clock). Times here are the style timeline's (document ms, the animation time scale
// applied); the API adds the timeline's origin (`zero`) so that document.timeline.currentTime reads like
// performance.now().
//
// "Update animations and send events" (HTML's rendering step) runs before the animation frame callbacks
// (run_animation_frames) and from a timer of its own at the next moment something is due (a pending task, an
// animation reaching its end, queued events), so promises settle and events fire in a hidden tab too: pending tasks
// complete (their ready time is the timeline's time then), finished states are updated, replaced animations are
// removed, then the queued events are dispatched in order.
//
// The engine mirrors the promises: the page records what happened to them (`ops`) and queues the animation's notify
// microtask, which takes them (Animation_takeOps). It also says whether the JavaScript object must be kept alive
// (`k` / `u`): while the animation runs, has a pending task or queued events, or shows its effect on a target.

Anim_Pending :: enum u8 { None, Play, Pause }
Anim_Promise :: enum u8 { Pending, Resolved, Rejected }

Web_Animation :: struct {
	page:          ^Page,
	self:          u64,
	instance:      u32,
	notify, user:  u32,
	id:            u64,          // composite order; the effect's key on the style timeline
	has_effect:    bool,
	target:        base.Handle,
	props:         [dynamic]string,   // the properties the keyframes name (commitStyles)
	timeline:      bool,         // the document timeline (false: null)
	start, hold:   f64,
	has_start, has_hold: bool,
	rate:          f64,
	pending_rate:  f64,
	has_pending_rate: bool,
	pending:       Anim_Pending,
	prev:          f64,          // the previous current time
	has_prev:      bool,
	ready, finished: Anim_Promise,
	replace:       Api_AnimationReplaceState,
	ops:           [dynamic]u8,
	notify_queued: bool,
	kept:          bool,
	queued_events: int,
}

@(private)
Anim_Queued_Event :: struct {
	anim:     u64,
	type:     string,     // constant
	current:  f64,        // NaN: null
	timeline: f64,
}

Web_Anims :: struct {
	list:     [dynamic]^Web_Animation,   // composite order
	next_id:  u64,
	timer:    base.Handle,
	timer_at: f64,                       // loop ms the timer is set for
	events:   [dynamic]Anim_Queued_Event,
	zero:     f64,                       // performance.now() at timeline time 0
	has_zero: bool,
	updating: bool,
	now:      f64,                       // the timeline's time for this task (anims_now)
	now_valid, now_posted: bool,
}

web_animation_vt := Object_VTable{name = "Animation", destroy = web_animation_destroy}

lookup_Animation :: proc(c: ^Call, h: u64) -> ^Web_Animation { return (^Web_Animation)(object_data(c.page, h, &web_animation_vt)) }

@(private)
anims_of :: proc(p: ^Page) -> ^Web_Anims {
	if p.anim.scripted == nil { p.anim.scripted = new(Web_Anims) }
	return p.anim.scripted
}

// Frees the page's animations' bookkeeping (the animations themselves are host objects, freed with them).
@(private)
web_anims_destroy :: proc(p: ^Page) {
	w := p.anim.scripted
	if w == nil { return }
	if w.timer != base.NIL_HANDLE { host.clear_timer(p.loop, w.timer) }
	delete(w.list)
	delete(w.events)
	free(w)
	p.anim.scripted = nil
}

@(private)
web_animation_destroy :: proc(p: ^Page, data: rawptr) {
	a := (^Web_Animation)(data)
	if !p.closed {
		if w := p.anim.scripted; w != nil {
			for x, i in w.list { if x == a { ordered_remove(&w.list, i); break } }
			for i := len(w.events) - 1; i >= 0; i -= 1 { if w.events[i].anim == a.self { ordered_remove(&w.events, i) } }
		}
		if p.anim.timeline != nil { style.timeline_script_remove(p.anim.timeline, a.id) }
	}
	for s in a.props { delete(s) }
	delete(a.props)
	delete(a.ops)
	free(a)
}

////////////////////////////////
// Time

// The timeline's time (style timeline units). As in browsers it holds still during a task: read once, it stays until
// the next turn of the loop or the next update (a script that seeks then reads gets back what it set).
@(private)
anims_now :: proc(p: ^Page) -> f64 {
	w := anims_of(p)
	if !w.now_valid {
		w.now = style.timeline_time(p.anim.timeline, document_time_ms(p))
		w.now_valid = true
		if !w.now_posted {
			w.now_posted = true
			post_page_task(p, proc(pg: ^Page, _: rawptr) {
				if pg == nil { return }
				if w := pg.anim.scripted; w != nil { w.now_valid, w.now_posted = false, false }
			}, nil)
		}
	}
	return w.now
}

// What the API shows of a timeline time: performance.now()'s scale.
@(private)
anims_zero :: proc(p: ^Page) -> f64 {
	w := anims_of(p)
	if !w.has_zero {
		w.zero = page_now_ms(p) - anims_now(p)
		w.has_zero = true
	}
	return w.zero
}

@(private)
anim_end :: proc(a: ^Web_Animation) -> f64 {
	if !a.has_effect { return 0 }
	t := style.timeline_script_timing(a.page.anim.timeline, a.id)
	return t != nil ? style.effect_end_time(t^) : 0
}

@(private)
anim_current :: proc(a: ^Web_Animation) -> (f64, bool) {
	if a.has_hold { return a.hold, true }
	if !a.timeline || !a.has_start { return 0, false }
	return (anims_now(a.page) - a.start) * a.rate, true
}

@(private)
anim_effective_rate :: proc(a: ^Web_Animation) -> f64 { return a.has_pending_rate ? a.pending_rate : a.rate }

@(private)
anim_apply_pending_rate :: proc(a: ^Web_Animation) {
	if !a.has_pending_rate { return }
	a.rate = a.pending_rate
	a.has_pending_rate = false
}

anim_play_state :: proc(a: ^Web_Animation) -> Api_AnimationPlayState {
	cur, has := anim_current(a)
	if !has && !a.has_start && a.pending == .None { return .Idle }
	if a.pending == .Pause || (!a.has_start && a.pending != .Play) { return .Paused }
	if has && ((a.rate > 0 && cur >= anim_end(a)) || (a.rate < 0 && cur <= 0)) { return .Finished }
	return .Running
}

// The effect is current or in effect (Web Animations 1 §4.6): the animation is relevant (getAnimations, keep alive).
@(private)
anim_relevant :: proc(a: ^Web_Animation) -> bool {
	if !a.has_effect || a.replace == .Removed { return false }
	t := style.timeline_script_timing(a.page.anim.timeline, a.id)
	if t == nil { return false }
	cur, has := anim_current(a)
	if !has { return false }
	st := style.effect_state(t^, cur, true, a.rate < 0)
	if st.has_active { return true }
	switch st.phase {
	case .Active: return true
	case .Before: return a.rate > 0 || a.pending == .Play
	case .After: return a.rate < 0
	}
	return false
}

////////////////////////////////
// Promises, the engine, the style timeline

@(private)
anim_op :: proc(a: ^Web_Animation, op: u8) { append(&a.ops, op) }

@(private)
anim_new_ready :: proc(a: ^Web_Animation) {
	if a.ready != .Pending { anim_op(a, 'n'); a.ready = .Pending }
}

@(private)
anim_resolve_ready :: proc(a: ^Web_Animation) {
	if a.ready == .Pending { anim_op(a, 'r'); a.ready = .Resolved }
}

// After every change: the style timeline's clock, the engine's notification, the next update.
@(private)
anim_changed :: proc(a: ^Web_Animation) {
	p := a.page
	if p.closed { return }
	if a.has_effect {
		clock := style.Script_Clock{start = a.start, hold = a.hold, has_start = a.has_start, has_hold = a.has_hold, rate = a.rate, timeline = a.timeline}
		if a.replace == .Removed { clock = {rate = 1} }   // removed: no local time, no values
		style.timeline_script_clock(p.anim.timeline, a.id, clock)
	}
	keep := a.pending != .None || a.queued_events > 0 || anim_play_state(a) == .Running || (a.target != base.NIL_HANDLE && anim_relevant(a))
	if keep != a.kept {
		a.kept = keep
		anim_op(a, keep ? 'k' : 'u')
	}
	if len(a.ops) > 0 && !a.notify_queued {
		a.notify_queued = true
		queue_microtask(p, Microtask{instance = a.instance, callback = a.notify, user = a.user})
		if p.objects.depth == 0 { host_post_checkpoint(p) }
	}
	anims_schedule(p)
}

@(private)
anim_queue_event :: proc(a: ^Web_Animation, type: string, current: f64) {
	w := anims_of(a.page)
	append(&w.events, Anim_Queued_Event{anim = a.self, type = type, current = current, timeline = a.timeline ? anims_now(a.page) + anims_zero(a.page) : math.nan_f64()})
	a.queued_events += 1
}

////////////////////////////////
// The procedures of Web Animations 1 §4.4

// "Update an animation's finished state"
@(private)
anim_update_finished :: proc(a: ^Web_Animation, did_seek, sync: bool) {
	now := anims_now(a.page)
	unconstrained: f64
	has_unc: bool
	if did_seek {
		unconstrained, has_unc = anim_current(a)
	} else if a.timeline && a.has_start {
		unconstrained, has_unc = (now - a.start) * a.rate, true
	}
	if has_unc && a.has_start && a.pending == .None {
		end := anim_end(a)
		switch {
		case a.rate > 0 && unconstrained >= end:
			a.hold = did_seek ? unconstrained : (a.has_prev ? max(a.prev, end) : end)
			a.has_hold = true
		case a.rate < 0 && unconstrained <= 0:
			a.hold = did_seek ? unconstrained : (a.has_prev ? min(a.prev, 0) : 0)
			a.has_hold = true
		case a.rate != 0 && a.has_hold && a.timeline:
			if did_seek { a.start = now - a.hold / a.rate }
			a.has_hold = false
		}
	}
	a.prev, a.has_prev = anim_current(a)
	finished := anim_play_state(a) == .Finished
	if finished && a.finished == .Pending {
		// the finish notification steps (run at once: the engine resolves the promise in a microtask of its own)
		anim_op(a, 'f')
		a.finished = .Resolved
		cur, has := anim_current(a)
		anim_queue_event(a, "finish", has ? cur : math.nan_f64())
	} else if !finished && a.finished == .Resolved {
		anim_op(a, 'm')
		a.finished = .Pending
	}
	_ = sync
}

// "Silently set the current time"
@(private)
anim_silently_set_current :: proc(a: ^Web_Animation, seek: f64, has_seek: bool) -> bool {
	if !has_seek {
		_, has := anim_current(a)
		return !has
	}
	if a.has_hold || !a.has_start || !a.timeline || a.rate == 0 {
		a.hold, a.has_hold = seek, true
	} else {
		a.start, a.has_start = anims_now(a.page) - seek / a.rate, true
	}
	if !a.timeline { a.has_start = false }
	a.has_prev = false
	return true
}

@(private)
anim_play :: proc(a: ^Web_Animation, auto_rewind: bool) -> (ok: bool) {
	aborted_pause := a.pending == .Pause
	has_pending_ready := false
	seek: f64
	has_seek := false
	rate := anim_effective_rate(a)
	cur, has := anim_current(a)
	end := anim_end(a)
	switch {
	case rate > 0 && auto_rewind && (!has || cur < 0 || cur >= end):
		seek, has_seek = 0, true
	case rate < 0 && auto_rewind && (!has || cur <= 0 || cur > end):
		if math.is_inf(end) { return false }
		seek, has_seek = end, true
	case rate == 0 && !has:
		seek, has_seek = 0, true
	}
	if has_seek {
		a.has_start = false
		a.hold, a.has_hold = seek, true
	}
	if a.has_hold { a.has_start = false }
	if a.pending != .None {
		a.pending = .None
		has_pending_ready = true
	}
	if !a.has_hold && !has_seek && !aborted_pause && !a.has_pending_rate { return true }
	if !has_pending_ready { anim_new_ready(a) }
	a.pending = .Play
	anim_update_finished(a, false, false)
	return true
}

@(private)
anim_pause :: proc(a: ^Web_Animation) -> bool {
	if a.pending == .Pause || anim_play_state(a) == .Paused { return true }
	seek: f64
	has_seek := false
	if _, has := anim_current(a); !has {
		if a.rate >= 0 {
			seek, has_seek = 0, true
		} else {
			end := anim_end(a)
			if math.is_inf(end) { return false }
			seek, has_seek = end, true
		}
	}
	if has_seek {
		a.has_start = false
		a.hold, a.has_hold = seek, true
	}
	if a.pending == .Play { a.pending = .None } else { anim_new_ready(a) }
	a.pending = .Pause
	anim_update_finished(a, false, false)
	return true
}

// The pending task completes at `ready` (timeline time).
@(private)
anim_commit_pending :: proc(a: ^Web_Animation, ready: f64) {
	switch a.pending {
	case .None:
		return
	case .Play:
		if a.has_hold {
			anim_apply_pending_rate(a)
			a.start = a.rate == 0 ? ready : ready - a.hold / a.rate
			a.has_start = true
			if a.rate != 0 { a.has_hold = false }
		} else if a.has_start && a.has_pending_rate {
			at := (ready - a.start) * a.rate
			anim_apply_pending_rate(a)
			if a.rate == 0 {
				a.hold, a.has_hold = at, true
			} else {
				a.start = ready - at / a.rate
			}
		}
	case .Pause:
		if a.has_start && !a.has_hold { a.hold, a.has_hold = (ready - a.start) * a.rate, true }
		anim_apply_pending_rate(a)
		a.has_start = false
	}
	a.pending = .None
	anim_resolve_ready(a)
	anim_update_finished(a, false, false)
}

// "Reset an animation's pending tasks"
@(private)
anim_reset_pending :: proc(a: ^Web_Animation) {
	if a.pending == .None { return }
	a.pending = .None
	anim_apply_pending_rate(a)
	anim_op(a, 'R')
	a.ready = .Resolved
}

////////////////////////////////
// Update animations and send events

// Runs the update (the page's rendering step, or the timer below).
web_animations_update :: proc(p: ^Page) {
	w := p.anim.scripted
	if w == nil || p.closed || w.updating || len(w.list) == 0 && len(w.events) == 0 { return }
	w.updating = true
	defer if !p.closed {
		w.updating = false
		anims_schedule(p)
	}
	w.now_valid = false   // the time of this update
	now := anims_now(p)
	snapshot := make([dynamic]^Web_Animation, 0, len(w.list), context.temp_allocator)
	append(&snapshot, ..w.list[:])
	for a in snapshot {
		if a.pending != .None { anim_commit_pending(a, now) } else { anim_update_finished(a, false, false) }
	}
	// removing replaced animations (Web Animations 1 §5.5)
	later := make([dynamic]u64, 0, len(snapshot), context.temp_allocator)
	for i := len(snapshot) - 1; i >= 0; i -= 1 {
		a := snapshot[i]
		replaceable := a.replace == .Active && a.has_effect && a.timeline && a.target != base.NIL_HANDLE && anim_play_state(a) == .Finished && anim_relevant(a)
		if !replaceable { continue }
		if len(later) > 0 && style.timeline_script_covered(p.anim.timeline, a.id, later[:]) {
			a.replace = .Removed
			cur, has := anim_current(a)
			anim_queue_event(a, "remove", has ? cur : math.nan_f64())
			continue
		}
		append(&later, a.id)
	}
	for a in snapshot { anim_changed(a) }
	// send the events, in the order they were queued
	if len(w.events) > 0 {
		batch := w.events
		w.events = make([dynamic]Anim_Queued_Event)
		defer delete(batch)
		for e in batch {
			if p.closed { return }
			a := (^Web_Animation)(object_data(p, e.anim, &web_animation_vt))
			if a == nil { continue }
			a.queued_events -= 1
			object_dispatch(p, e.anim, dom.Event{type = e.type, x = e.current, y = e.timeline})
			if a = (^Web_Animation)(object_data(p, e.anim, &web_animation_vt)); a != nil { anim_changed(a) }
		}
	}
}

// Arms the timer for the next moment the update has something to do.
@(private)
anims_schedule :: proc(p: ^Page) {
	w := p.anim.scripted
	if w == nil || p.closed || w.updating { return }
	due := -1.0   // timeline ms from now
	want :: proc(due: ^f64, ms: f64) { if due^ < 0 || ms < due^ { due^ = max(ms, 0) } }
	if len(w.events) > 0 { want(&due, 0) }
	for a in w.list {
		if a.pending != .None { want(&due, 0); continue }
		if a.has_hold || !a.has_start || !a.timeline || a.rate == 0 || a.finished != .Pending { continue }
		cur, _ := anim_current(a)
		if a.rate > 0 {
			end := anim_end(a)
			if !math.is_inf(end) { want(&due, (end - cur) / a.rate) }
		} else {
			want(&due, cur / -a.rate)
		}
	}
	if due < 0 { return }
	ms := due / f64(max(p.engine.settings.anim_time_scale, 0.0001))
	at := f64(host.now_ns(p.loop)) / 1e6 + ms
	if w.timer != base.NIL_HANDLE {
		if at >= w.timer_at - 0.5 { return }
		host.clear_timer(p.loop, w.timer)
	}
	w.timer_at = at
	w.timer = host.set_timer(p.loop, ms, 0, proc(data: rawptr) {
		p := (^Page)(data)
		w := p.anim.scripted
		if w == nil || p.closed { return }
		w.timer = base.NIL_HANDLE
		web_animations_update(p)
	}, p, p.scope)
}

////////////////////////////////
// The API

Animation_create :: proc(c: ^Call, notify: u32, user: i32) -> u64 {
	p := c.page
	if call_doc(c) == nil { return 0 }
	w := anims_of(p)
	a := new(Web_Animation)
	w.next_id += 1
	a.page, a.instance, a.notify, a.user, a.id = p, c.owner, notify, u32(user), w.next_id
	a.timeline = true
	a.rate = 1
	a.ready, a.finished = .Resolved, .Pending
	a.kept = true   // the engine keeps a new wrapper until told otherwise (`u`)
	a.self = object_create(p, &web_animation_vt, a, c.owner)
	append(&w.list, a)
	anim_changed(a)
	return a.self
}

Animation_setEffect :: proc(c: ^Call, animation: Api_Animation, target: Api_Element, keyframes: string, duration, delay, end_delay, iterations, iteration_start: f64, direction, fill: i32, easing: string, composite: i32) -> Api_Error {
	a := animation.data
	p := c.page
	t := style.Effect_Timing{
		delay = delay, end_delay = end_delay, duration = math.is_nan(duration) ? 0 : max(duration, 0),
		iterations = max(iterations, 0), iteration_start = max(iteration_start, 0),
		direction = style.Anim_Direction(clamp(direction, 0, 3)), fill = style.Fill_Mode(clamp(fill, 0, 3)),
	}
	node := H(target.handle)
	if !style.timeline_script_put(p.anim.timeline, a.id, node, keyframes, t, easing, style.Composition(clamp(composite, 0, 2))) {
		return fail(c, .Type, "the easing of the effect or of a keyframe is not a valid easing function")
	}
	a.has_effect = true
	a.target = node
	for s in a.props { delete(s) }
	clear(&a.props)
	frames := keyframes
	for frame in strings.split_iterator(&frames, "\x1e") {
		fields := strings.split(frame, "\x1f", context.temp_allocator)
		for i := 2; i < len(fields); i += 2 {
			known := false
			for s in a.props { if s == fields[i] { known = true; break } }
			if !known { append(&a.props, strings.clone(fields[i])) }
		}
	}
	anim_update_finished(a, false, false)
	anim_changed(a)
	return .None
}

Animation_clearEffect :: proc(c: ^Call, animation: Api_Animation) {
	a := animation.data
	style.timeline_script_remove(c.page.anim.timeline, a.id)
	a.has_effect = false
	a.target = base.NIL_HANDLE
	anim_update_finished(a, false, false)
	anim_changed(a)
}

Animation_setTimeline :: proc(c: ^Call, animation: Api_Animation, document_timeline: bool) {
	a := animation.data
	if a.timeline == document_timeline { return }
	prev, has_prev := anim_current(a)
	a.timeline = document_timeline
	if has_prev { anim_silently_set_current(a, prev, true) }
	anim_update_finished(a, false, false)
	anim_changed(a)
}

Animation_play :: proc(c: ^Call, animation: Api_Animation) -> Api_Error {
	a := animation.data
	defer anim_changed(a)
	if !anim_play(a, true) { return fail(c, .Invalid_State, "Cannot play reversed Animation with infinite target effect end.") }
	return .None
}

Animation_pause :: proc(c: ^Call, animation: Api_Animation) -> Api_Error {
	a := animation.data
	defer anim_changed(a)
	if !anim_pause(a) { return fail(c, .Invalid_State, "Cannot pause, Animation has infinite target effect end.") }
	return .None
}

Animation_finish :: proc(c: ^Call, animation: Api_Animation) -> Api_Error {
	a := animation.data
	rate := anim_effective_rate(a)
	end := anim_end(a)
	if rate == 0 { return fail(c, .Invalid_State, "Cannot finish Animation with a playbackRate of 0.") }
	if rate > 0 && math.is_inf(end) { return fail(c, .Invalid_State, "Cannot finish Animation with an infinite target effect end.") }
	defer anim_changed(a)
	anim_apply_pending_rate(a)
	limit := a.rate > 0 ? end : 0
	anim_silently_set_current(a, limit, true)
	if !a.has_start && a.timeline {
		a.start, a.has_start = anims_now(c.page) - limit / a.rate, true
	}
	if a.pending == .Pause && a.has_start {
		a.has_hold = false
		a.pending = .None
		anim_resolve_ready(a)
	}
	if a.pending == .Play && a.has_start {
		a.pending = .None
		anim_resolve_ready(a)
	}
	anim_update_finished(a, true, true)
	return .None
}

Animation_cancel :: proc(c: ^Call, animation: Api_Animation) {
	a := animation.data
	if anim_play_state(a) != .Idle {
		anim_reset_pending(a)
		if a.finished == .Pending {
			anim_op(a, 'F')   // rejected, and a new pending one
		} else {
			anim_op(a, 'm')
			a.finished = .Pending
		}
		anim_queue_event(a, "cancel", math.nan_f64())
	}
	a.has_hold, a.has_start = false, false
	a.has_prev = false
	anim_changed(a)
}

Animation_reverse :: proc(c: ^Call, animation: Api_Animation) -> Api_Error {
	a := animation.data
	if !a.timeline { return fail(c, .Invalid_State, "Cannot reverse an animation with no active timeline") }
	defer anim_changed(a)
	saved, had := a.pending_rate, a.has_pending_rate
	a.pending_rate, a.has_pending_rate = -anim_effective_rate(a), true
	if !anim_play(a, true) {
		a.pending_rate, a.has_pending_rate = saved, had
		return fail(c, .Invalid_State, "Cannot play reversed Animation with infinite target effect end.")
	}
	return .None
}

Animation_persist :: proc(c: ^Call, animation: Api_Animation) {
	a := animation.data
	a.replace = .Persisted
	anim_changed(a)
}

Animation_commitStyles :: proc(c: ^Call, animation: Api_Animation) -> Api_Error {
	a := animation.data
	p := c.page
	d := call_doc(c)
	n := d != nil ? dom.get(d, a.target) : nil
	if n == nil || n.kind != .Element { return fail(c, .No_Modification_Allowed, "Target is not capable of having a style attribute") }
	st := js_dom_styled(p)
	cs := st != nil ? style.style_of(st, a.target) : nil
	if cs == nil || !dom.is_connected(d, a.target) || cs.display == .None {
		return fail(c, .Invalid_State, "Target element is not rendered.")
	}
	el := Api_Element{handle = u64(a.target), data = n}
	// the values first (setting one restyles the element), then the declarations
	values := make([]string, len(a.props), context.temp_allocator)
	for name, i in a.props { values[i] = strings.clone(ComputedStyle_get(c, el, "", name), context.temp_allocator) }
	for name, i in a.props {
		if values[i] == "" { continue }
		if err := InlineStyle_setProperty(c, el, name, values[i], ""); err != .None { return err }
	}
	return .None
}

Animation_updatePlaybackRate :: proc(c: ^Call, animation: Api_Animation, rate: f64) {
	a := animation.data
	defer anim_changed(a)
	state := anim_play_state(a)
	a.pending_rate, a.has_pending_rate = rate, true
	if a.pending != .None { return }
	cur, has := anim_current(a)
	switch {
	case state == .Idle || state == .Paused || !has:
		anim_apply_pending_rate(a)
	case state == .Finished:
		now := anims_now(c.page)
		unconstrained := a.has_start ? (now - a.start) * a.rate : cur
		a.start = rate == 0 ? now : now - unconstrained / rate
		a.has_start = true
		anim_apply_pending_rate(a)
		anim_update_finished(a, false, false)
	case:
		anim_play(a, false)
	}
}

Animation_playbackRate :: proc(c: ^Call, animation: Api_Animation) -> f64 { return animation.data.rate }

Animation_set_playbackRate :: proc(c: ^Call, animation: Api_Animation, rate: f64) {
	a := animation.data
	a.has_pending_rate = false
	prev, has := anim_current(a)
	a.rate = rate
	if has { set_current_time(a, prev) }
	anim_changed(a)
}

@(private)
set_current_time :: proc(a: ^Web_Animation, t: f64) {
	anim_silently_set_current(a, t, true)
	if a.pending == .Pause {
		a.hold, a.has_hold = t, true
		anim_apply_pending_rate(a)
		a.has_start = false
		a.pending = .None
		anim_resolve_ready(a)
	}
	anim_update_finished(a, true, false)
}

Animation_currentTime :: proc(c: ^Call, animation: Api_Animation) -> f64 {
	t, has := anim_current(animation.data)
	return has ? t : math.nan_f64()
}

Animation_set_currentTime :: proc(c: ^Call, animation: Api_Animation, time: f64) -> Api_Error {
	a := animation.data
	defer anim_changed(a)
	if math.is_nan(time) {
		if _, has := anim_current(a); has { return fail(c, .Type, "currentTime may not be changed from resolved to unresolved") }
		return .None
	}
	set_current_time(a, time)
	return .None
}

Animation_startTime :: proc(c: ^Call, animation: Api_Animation) -> f64 {
	a := animation.data
	return a.has_start ? a.start + anims_zero(c.page) : math.nan_f64()
}

Animation_set_startTime :: proc(c: ^Call, animation: Api_Animation, time: f64) {
	a := animation.data
	defer anim_changed(a)
	has_new := !math.is_nan(time)
	if !a.timeline && has_new { a.has_hold = false }
	anim_apply_pending_rate(a)
	prev, has_prev := anim_current(a)
	a.start, a.has_start = has_new ? time - anims_zero(c.page) : 0, has_new
	if has_new {
		if a.rate != 0 { a.has_hold = false }
	} else {
		a.hold, a.has_hold = prev, has_prev
	}
	if a.pending != .None {
		a.pending = .None
		anim_resolve_ready(a)
	}
	anim_update_finished(a, true, false)
}

Animation_playState :: proc(c: ^Call, animation: Api_Animation) -> Api_AnimationPlayState { return anim_play_state(animation.data) }

Animation_replaceState :: proc(c: ^Call, animation: Api_Animation) -> Api_AnimationReplaceState { return animation.data.replace }

Animation_pending :: proc(c: ^Call, animation: Api_Animation) -> bool { return animation.data.pending != .None }

Animation_takeOps :: proc(c: ^Call, animation: Api_Animation) -> string {
	return strings.clone(string(animation.data.ops[:]), context.temp_allocator)
}

Animation_dropOps :: proc(c: ^Call, animation: Api_Animation, count: i32) {
	a := animation.data
	a.notify_queued = false
	remove_range(&a.ops, 0, clamp(int(count), 0, len(a.ops)))
}

AnimationPlaybackEvent_time :: proc(c: ^Call, event: Api_Event, which: i32) -> f64 {
	return which == 0 ? event.data.x : event.data.y
}

Animation_computedTiming :: proc(c: ^Call, animation: Api_Animation, which: i32) -> f64 {
	a := animation.data
	nan := math.nan_f64()
	cur, has := anim_current(a)
	if which == 0 { return has && a.has_effect ? cur : nan }
	t := a.has_effect ? style.timeline_script_timing(c.page.anim.timeline, a.id) : nil
	if t == nil || !has { return nan }
	st := style.effect_state(t^, cur, true, a.rate < 0)
	if !st.has_active { return nan }
	return which == 1 ? st.progress : st.iteration
}

Animation_relevant :: proc(c: ^Call, root: Api_Node, subtree: bool) -> []u8 {
	p := c.page
	d := call_doc(c)
	w := p.anim.scripted
	if d == nil || w == nil { return nil }
	out := make([dynamic]u8, 0, 8 * len(w.list), context.temp_allocator)
	r := H(root.handle)
	for a in w.list {
		if a.target == base.NIL_HANDLE || !anim_relevant(a) || dom.get(d, a.target) == nil { continue }
		if r == base.NIL_HANDLE {
			if !dom.is_connected(d, a.target) { continue }
		} else if a.target != r {
			if !subtree { continue }
			inside := false
			for cur := dom.parent_or_host(d, a.target); cur != base.NIL_HANDLE; cur = dom.parent_or_host(d, cur) {
				if cur == r { inside = true; break }
			}
			if !inside { continue }
		}
		v := a.self
		for k in 0 ..< 8 { append(&out, u8(v >> (8 * uint(k)))) }
	}
	return out[:]
}

DocumentTimeline_currentTime :: proc(c: ^Call) -> f64 {
	if call_doc(c) == nil { return math.nan_f64() }
	return anims_now(c.page) + anims_zero(c.page)
}

Animation_validEasing :: proc(c: ^Call, easing: string) -> bool { return style.easing_valid(c.page.engine, easing) }
