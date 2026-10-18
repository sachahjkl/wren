package style

import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "wb:base"
import "wb:dom"

// The document timeline: CSS Transitions 1 and CSS Animations 1 on top of the cascade.
//
// After each style pass the page calls `timeline_restyled` (full pass) or `timeline_restyled_partial` (state restyle);
// they compare the styles before and after to start, reverse and cancel transitions, and start or stop animations when
// animation-name changes. `timeline_tick` advances the clock and writes the animated values: for each animated element
// the entry of `Styled.by_node` is replaced by a copy of its cascaded style (an overlay, owned by the timeline) with the
// animated properties overwritten, and inherited animated properties are pushed down to the descendants that inherit
// them. `Styled.overlaid` remembers the cascaded style under each overlay, so restyles, `computed_equal` and the partial
// restyle keep working on cascaded values. `Styled.serial` changes exactly when an animated value changed.
//
// Cost: a tick is proportional to the running effects (plus the descendants an inherited animated property reaches), not
// to the document. When nothing moves (paused, delayed, finished, filled), a tick computes nothing and
// `timeline_next_ms` tells the shell when the next change is due (-1: never), so an idle page costs no CPU.
//
// Pseudo-elements are not animated themselves (they inherit animated values of their element).

Anim_Event_Kind :: enum u8 {
	Transition_Run, Transition_Start, Transition_End, Transition_Cancel,
	Animation_Start, Animation_Iteration, Animation_End, Animation_Cancel,
}

// The DOM event type of each kind.
ANIM_EVENT_TYPES := [Anim_Event_Kind]string{
	.Transition_Run = "transitionrun", .Transition_Start = "transitionstart", .Transition_End = "transitionend",
	.Transition_Cancel = "transitioncancel", .Animation_Start = "animationstart", .Animation_Iteration = "animationiteration",
	.Animation_End = "animationend", .Animation_Cancel = "animationcancel",
}

Anim_Event :: struct {
	kind:    Anim_Event_Kind,
	node:    base.Handle,
	name:    string,    // the property (transitions) or the animation name; valid until `timeline_clear_events`
	elapsed: f64,       // elapsedTime, in milliseconds
}

@(private)
Phase :: enum u8 { Before, Active, After }

@(private)
Transition :: struct {
	prop:       Prop,
	arena:      virtual.Arena,
	from, to:   ^Computed,     // only `prop` is meaningful; owned by `arena`
	reverse_start: ^Computed,  // the reversing-adjusted start value (CSS Transitions 1 §3)
	start:      f64,           // document time of creation
	delay:      f64,
	duration:   f64,
	easing:     Easing,
	discrete:   bool,          // allow-discrete between values that do not interpolate
	shortening: f64,           // the reversing shortening factor
	start_sent: bool,
	done:       bool,
	key:        [2]f64,        // phase and eased progress of the last tick
}

@(private)
Frame_Value :: struct {
	offset:     f64,
	c:          ^Computed,     // the keyframe's values for this element (props only)
	props:      Prop_Set,
	easing:     Easing,
	has_easing: bool,
}

@(private)
Anim_Run :: struct {
	name:        string,       // heap
	spec:        Animation_Spec,
	spec_arena:  virtual.Arena,   // the spec's easing points
	frames_arena: virtual.Arena,
	frames:      []Frame_Value,
	props:       Prop_Set,
	frames_gen:  u64,          // the Element_Anim.base_gen the frames were computed for
	frames_rebuilds: u64,
	frames_ready: bool,
	local:       f64,          // time since the animation started, advancing only while it runs
	last_now:    f64,
	started:     bool,
	ended:       bool,
	iteration:   f64,          // last iteration reported
	key:         [3]f64,       // phase, directed progress, effect of the last tick
}

@(private)
Element_Anim :: struct {
	node:        base.Handle,
	transitions: [dynamic]^Transition,
	runs:        [dynamic]^Anim_Run,
	base:        ^Computed,    // its cascaded style as of the last restyle
	base_gen:    u64,          // changes with `base` (pointers into recycled style memory may repeat)
}

@(private)
Overlay :: struct {
	c:     Computed,
	arena: virtual.Arena,
	tick:  u64,
}

Timeline :: struct {
	engine:      ^Engine,
	now:         f64,          // document time, ms
	last_wall:   f64,
	has_wall:    bool,
	elements:    map[base.Handle]^Element_Anim,
	order:       [dynamic]^Element_Anim,   // tree order (parents before children)
	order_dirty: bool,
	overlays:    map[base.Handle]^Overlay,
	events:      [dynamic]Anim_Event,
	event_arena: virtual.Arena,
	dirty:       bool,         // the next tick recomputes the overlays even if no progress changed
	tick:        u64,
	running:     int,          // transitions + animations alive
	next_ms:     f64,          // document ms until a value changes next: 0 = every frame, -1 = never
	dropped_events: int,
	base_gens:   u64,
}

timeline_make :: proc(e: ^Engine) -> ^Timeline {
	tl := new(Timeline)
	tl.engine = e
	tl.elements = make(map[base.Handle]^Element_Anim)
	tl.overlays = make(map[base.Handle]^Overlay)
	tl.order = make([dynamic]^Element_Anim)
	tl.events = make([dynamic]Anim_Event)
	_ = virtual.arena_init_growing(&tl.event_arena, 64 * 1024)
	tl.next_ms = -1
	return tl
}

// Frees everything. When `s` is given, its entries are put back to the cascaded styles first.
timeline_destroy :: proc(tl: ^Timeline, s: ^Styled = nil) {
	if tl == nil { return }
	if s != nil { restore_overlays(tl, s) }
	for _, ea in tl.elements { element_free(tl, ea) }
	delete(tl.elements)
	for _, ov in tl.overlays { overlay_free(ov) }
	delete(tl.overlays)
	delete(tl.order)
	delete(tl.events)
	virtual.arena_destroy(&tl.event_arena)
	free(tl)
}

// Cancels everything (navigation, settings that turn animations off) without events.
timeline_reset :: proc(tl: ^Timeline, s: ^Styled) {
	if s != nil { restore_overlays(tl, s) }
	for _, ea in tl.elements { element_free(tl, ea) }
	clear(&tl.elements)
	for _, ov in tl.overlays { overlay_free(ov) }
	clear(&tl.overlays)
	clear(&tl.order)
	tl.running = 0
	tl.next_ms = -1
	if s != nil { styled_touch(s) }
}

@(private)
element_free :: proc(tl: ^Timeline, ea: ^Element_Anim) {
	for tr in ea.transitions { transition_free(tr); tl.running -= 1 }
	for r in ea.runs { run_free(r); tl.running -= 1 }
	delete(ea.transitions)
	delete(ea.runs)
	free(ea)
}

@(private)
transition_free :: proc(tr: ^Transition) { virtual.arena_destroy(&tr.arena); free(tr) }

@(private)
run_free :: proc(r: ^Anim_Run) {
	virtual.arena_destroy(&r.spec_arena)
	virtual.arena_destroy(&r.frames_arena)
	delete(r.name)
	free(r)
}

@(private)
overlay_free :: proc(ov: ^Overlay) { virtual.arena_destroy(&ov.arena); free(ov) }

////////////////////////////////
// Clock and events

@(private)
advance :: proc(tl: ^Timeline, wall_ms: f64) {
	if !tl.has_wall { tl.has_wall, tl.last_wall = true, wall_ms; return }
	d := wall_ms - tl.last_wall
	if d > 0 { tl.now += d * f64(max(tl.engine.settings.anim_time_scale, 0.0001)) }
	tl.last_wall = wall_ms
}

@(private)
push_event :: proc(tl: ^Timeline, kind: Anim_Event_Kind, node: base.Handle, name: string, elapsed: f64) {
	if len(tl.events) >= max(tl.engine.settings.anim_max_events, 1) { tl.dropped_events += 1; return }
	nm := strings.clone(name, virtual.arena_allocator(&tl.event_arena))
	append(&tl.events, Anim_Event{kind = kind, node = node, name = nm, elapsed = elapsed})
}

// The events queued since the last `timeline_clear_events`, in the order they happened.
timeline_events :: proc(tl: ^Timeline) -> []Anim_Event { return tl.events[:] }

timeline_clear_events :: proc(tl: ^Timeline) {
	clear(&tl.events)
	virtual.arena_free_all(&tl.event_arena)
}

// Some value changes at every frame: the shell should keep drawing.
timeline_active :: proc(tl: ^Timeline) -> bool { return tl != nil && tl.next_ms == 0 }

// Wall-clock milliseconds until the next change of an animated value (0 = now / every frame, -1 = nothing pending).
timeline_next_ms :: proc(tl: ^Timeline) -> f64 {
	if tl == nil || tl.next_ms < 0 { return -1 }
	return tl.next_ms / f64(max(tl.engine.settings.anim_time_scale, 0.0001))
}

timeline_running :: proc(tl: ^Timeline) -> int { return tl != nil ? tl.running : 0 }

////////////////////////////////
// After a style pass

@(private)
mode_of :: proc(tl: ^Timeline) -> Anim_Mode { return anim_mode_effective(&tl.engine.settings) }

// Durations and delays as the motion preferences allow.
@(private)
reduced :: proc(tl: ^Timeline, duration, delay: f64) -> (f64, f64) {
	if mode_of(tl) == .Reduce {
		m := f64(tl.engine.settings.anim_reduced_max_ms)
		return min(duration, m), min(delay, m)
	}
	return duration, delay
}

// After a full pass: `old` is the previous result (nil for the first one), still alive; `s` the new one.
timeline_restyled :: proc(tl: ^Timeline, doc: ^dom.Document, old, s: ^Styled, wall_ms: f64) {
	advance(tl, wall_ms)
	s.track_changes = true
	if !s.motion && len(tl.elements) == 0 && len(tl.overlays) == 0 { return }   // nothing moves: no walk
	tl.dirty, tl.order_dirty = true, true
	seen := make(map[base.Handle]bool, context.temp_allocator)
	Frame :: struct { h: base.Handle, hidden: bool }
	stack := make([dynamic]Frame, context.temp_allocator)
	root := dom.get(doc, doc.root)
	for ch := root.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, Frame{ch, false}) }
	for len(stack) > 0 {
		f := pop(&stack)
		n := dom.get(doc, f.h)
		if n == nil || n.kind != .Element { continue }
		c := style_of(s, f.h)
		if c == nil { continue }
		hidden := f.hidden || c.display == .None
		ea := tl.elements[f.h] or_else nil
		if ea != nil || (!hidden && (has_transitions(c) || has_animations(c))) {
			old_eff: ^Computed
			if old != nil {
				if oc := style_of(old, f.h); oc != nil && !hidden_in(old, doc, f.h) { old_eff = oc }
			}
			update_element(tl, doc, s, f.h, old_eff, c, hidden)
			seen[f.h] = true
		}
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, Frame{ch, hidden}) }
	}
	gone := make([dynamic]base.Handle, context.temp_allocator)
	for h in tl.elements { if h not_in seen { append(&gone, h) } }
	for h in gone { drop_element(tl, doc, h) }
}

// After a partial restyle of `s` (the changes it recorded).
timeline_restyled_partial :: proc(tl: ^Timeline, doc: ^dom.Document, s: ^Styled, wall_ms: f64) {
	advance(tl, wall_ms)
	if len(s.changes) == 0 { return }
	tl.dirty = true
	for ch in s.changes {
		c := ch.new
		hidden := c.display == .None || hidden_in(s, doc, ch.node)
		ea := tl.elements[ch.node] or_else nil
		if ea != nil || (!hidden && (has_transitions(c) || has_animations(c))) {
			old_eff := ch.old
			if old_eff != nil && old_eff.display == .None { old_eff = nil }   // it had no box: no before-change style
			update_element(tl, doc, s, ch.node, old_eff, c, hidden)
		}
		if c.display == .None && len(tl.elements) > 0 {
			// its descendants stop being rendered: their animations stop too
			inside := make([dynamic]base.Handle, context.temp_allocator)
			for h in tl.elements { if h != ch.node && is_inside(doc, h, ch.node) { append(&inside, h) } }
			for h in inside { drop_element(tl, doc, h) }
		}
	}
	clear(&s.changes)
}

@(private)
is_inside :: proc(doc: ^dom.Document, h, ancestor: base.Handle) -> bool {
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(doc, cur)
		if n == nil { return false }
		if n.parent == ancestor { return true }
		cur = n.parent
	}
	return false
}

// `h` or an ancestor has display: none in `s` (cascaded values).
@(private)
hidden_in :: proc(s: ^Styled, doc: ^dom.Document, h: base.Handle) -> bool {
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(doc, cur)
		if n == nil || n.kind != .Element { return false }
		if cs := base_style_of(s, cur); cs != nil && cs.display == .None { return true }
		cur = n.parent
	}
	return false
}

@(private)
drop_element :: proc(tl: ^Timeline, doc: ^dom.Document, h: base.Handle) {
	ea := tl.elements[h] or_else nil
	if ea == nil { return }
	alive := dom.get(doc, h) != nil
	for tr in ea.transitions { if alive { cancel_event(tl, h, tr) } }
	for r in ea.runs { if alive { run_cancel_event(tl, h, r) } }
	element_free(tl, ea)
	delete_key(&tl.elements, h)
	tl.order_dirty, tl.dirty = true, true
}

@(private)
update_element :: proc(tl: ^Timeline, doc: ^dom.Document, s: ^Styled, h: base.Handle, old_eff, c: ^Computed, hidden: bool) {
	if hidden || mode_of(tl) == .Off {
		drop_element(tl, doc, h)
		return
	}
	ea := tl.elements[h] or_else nil
	if ea == nil {
		ea = new(Element_Anim)
		ea.node = h
		ea.transitions = make([dynamic]^Transition)
		ea.runs = make([dynamic]^Anim_Run)
		tl.elements[h] = ea
		tl.order_dirty = true
	}
	ea.base = c
	tl.base_gens += 1
	ea.base_gen = tl.base_gens
	sync_runs(tl, ea, c)
	if old_eff != nil { update_transitions(tl, ea, old_eff, c) }
	if len(ea.runs) == 0 && len(ea.transitions) == 0 {
		element_free(tl, ea)
		delete_key(&tl.elements, h)
		tl.order_dirty = true
	}
	_ = s
}

////////////////////////////////
// Animations: starting and stopping

@(private)
clone_easing :: proc(e: Easing, a: runtime.Allocator) -> Easing {
	r := e
	if len(e.points) > 0 {
		pts := make([]Linear_Stop, len(e.points), a)
		copy(pts, e.points)
		r.points = pts
	}
	return r
}

@(private)
sync_runs :: proc(tl: ^Timeline, ea: ^Element_Anim, c: ^Computed) {
	matched := make([]bool, len(ea.runs), context.temp_allocator)
	next := make([dynamic]^Anim_Run)
	for name, i in c.animation_name {
		if name == "" || keyframes_lookup(tl.engine, name) == nil { continue }   // no @keyframes: no animation
		r: ^Anim_Run
		for old, k in ea.runs {
			if !matched[k] && old.name == name { r = old; matched[k] = true; break }
		}
		if r == nil {
			if tl.running >= tl.engine.settings.anim_max_running { continue }
			r = new(Anim_Run)
			r.name = strings.clone(name)
			r.last_now = tl.now
			r.iteration = -1
			r.key = {-1, -1, -1}
			_ = virtual.arena_init_growing(&r.spec_arena, 16 * 1024)
			_ = virtual.arena_init_growing(&r.frames_arena, 64 * 1024)
			tl.running += 1
		}
		spec := animation_at(c, i)
		virtual.arena_free_all(&r.spec_arena)
		spec.easing = clone_easing(spec.easing, virtual.arena_allocator(&r.spec_arena))
		spec.name = r.name
		if mode_of(tl) == .Reduce {
			d, dl := reduced(tl, f64(spec.duration), f64(spec.delay))
			spec.duration, spec.delay = f32(d), f32(dl)
			if math.is_inf(spec.iterations) { spec.iterations = 1 }
		}
		r.spec = spec
		append(&next, r)
	}
	for old, k in ea.runs {
		if matched[k] { continue }
		run_cancel_event(tl, ea.node, old)
		run_free(old)
		tl.running -= 1
	}
	delete(ea.runs)
	ea.runs = next
}

@(private)
run_cancel_event :: proc(tl: ^Timeline, h: base.Handle, r: ^Anim_Run) {
	if !r.started || r.ended { return }   // idle or finished: nothing to cancel
	push_event(tl, .Animation_Cancel, h, r.name, max(r.local - f64(r.spec.delay), 0))
}

////////////////////////////////
// Transitions: starting, reversing, cancelling

@(private)
find_transition :: proc(ea: ^Element_Anim, p: Prop) -> (^Transition, int) {
	for tr, i in ea.transitions { if tr.prop == p { return tr, i } }
	return nil, -1
}

@(private)
cancel_event :: proc(tl: ^Timeline, h: base.Handle, tr: ^Transition) {
	if tr.done { return }
	push_event(tl, .Transition_Cancel, h, prop_name(tr.prop), clamp(tl.now - tr.start - tr.delay, 0, tr.duration))
}

@(private)
remove_transition :: proc(tl: ^Timeline, ea: ^Element_Anim, tr: ^Transition, with_event: bool) {
	if with_event { cancel_event(tl, ea.node, tr) }
	if _, i := find_transition(ea, tr.prop); i >= 0 && ea.transitions[i] == tr { ordered_remove(&ea.transitions, i) }
	transition_free(tr)
	tl.running -= 1
}

@(private)
start_transition :: proc(tl: ^Timeline, ea: ^Element_Anim, p: Prop, from, to, reverse_start: ^Computed, duration, delay: f64, easing: Easing, discrete: bool, shortening: f64) -> ^Transition {
	tr := new(Transition)
	_ = virtual.arena_init_growing(&tr.arena, 16 * 1024)
	a := virtual.arena_allocator(&tr.arena)
	tr.prop = p
	tr.from, tr.to, tr.reverse_start = new(Computed, a), new(Computed, a), new(Computed, a)
	clone_prop(tr.from, from, p, a)
	clone_prop(tr.to, to, p, a)
	clone_prop(tr.reverse_start, reverse_start, p, a)
	tr.start = tl.now
	tr.duration, tr.delay = duration, delay
	tr.easing = clone_easing(easing, a)
	tr.discrete = discrete
	tr.shortening = shortening
	tr.key = {-1, -1}
	append(&ea.transitions, tr)
	tl.running += 1
	push_event(tl, .Transition_Run, ea.node, prop_name(p), max(min(-delay, duration), 0))
	return tr
}

@(private)
transition_progress :: proc(tr: ^Transition, now: f64) -> (phase: Phase, eased: f64) {
	local := now - tr.start - tr.delay
	if local < 0 { return .Before, 0 }
	if tr.duration <= 0 { return .After, 1 }
	raw := clamp(local / tr.duration, 0, 1)
	if raw >= 1 { return .After, easing_eval(tr.easing, 1) }
	return .Active, easing_eval(tr.easing, raw)
}

// Writes the transition's value at `now` into dst (its property only).
@(private)
transition_value :: proc(tr: ^Transition, now: f64, dst: ^Computed, ctx: ^Interp_Ctx) {
	phase, t := transition_progress(tr, now)
	if phase == .Before { copy_prop(dst, tr.from, tr.prop); return }   // transitions fill backwards
	if tr.discrete || !interpolate_prop(dst, tr.from, tr.to, tr.prop, t, ctx) { discrete_prop(dst, tr.from, tr.to, tr.prop, t) }
}

@(private)
update_transitions :: proc(tl: ^Timeline, ea: ^Element_Anim, old_eff, c: ^Computed) {
	specs: [Prop]i32
	for &x in specs { x = -1 }
	listed := false
	for tp, i in c.transition_property {
		switch tp.kind {
		case .All: for p in Prop { if animatable(p) { specs[p] = i32(i) } }; listed = true
		case .Prop: if animatable(tp.prop) { specs[tp.prop] = i32(i); listed = true }
		case .Short: for p in short_longhands(tp.short) { if animatable(p) { specs[p] = i32(i); listed = true } }
		case .None, .Unknown:
		}
	}
	// a running transition whose property is no longer listed is cancelled
	for i := len(ea.transitions) - 1; i >= 0; i -= 1 {
		tr := ea.transitions[i]
		if specs[tr.prop] < 0 { remove_transition(tl, ea, tr, true) }
	}
	if !listed { return }
	if len(ea.transitions) == 0 && computed_equal(old_eff, c) { return }
	animated: Prop_Set
	for r in ea.runs { animated = ps_union(animated, r.props) }
	ctx := Interp_Ctx{alloc = context.temp_allocator, space = tl.engine.settings.anim_color_space}
	for p in Prop {
		if specs[p] < 0 || ps_has(animated, p) { continue }   // a CSS animation decides this property's value
		process_property(tl, ea, p, transition_at(c, int(specs[p])), old_eff, c, &ctx)
	}
}

@(private)
process_property :: proc(tl: ^Timeline, ea: ^Element_Anim, p: Prop, spec: Transition_Spec, old_eff, c: ^Computed, ctx: ^Interp_Ctx) {
	duration, delay := reduced(tl, max(f64(spec.duration), 0), f64(spec.delay))
	combined := max(duration, 0) + delay
	if mode_of(tl) == .Off { combined = 0 }
	running, _ := find_transition(ea, p)
	if running == nil {
		if combined <= 0 || prop_equal(old_eff, c, p) { return }
		ok := interpolable(old_eff, c, p, ctx)
		if !ok && !spec.allow_discrete { return }
		if tl.running >= tl.engine.settings.anim_max_running { return }
		start_transition(tl, ea, p, old_eff, c, old_eff, duration, delay, spec.easing, !ok, 1)
		return
	}
	if prop_equal(running.to, c, p) { return }   // already heading there
	current := new(Computed, context.temp_allocator)
	current^ = c^
	transition_value(running, tl.now, current, ctx)
	ok := interpolable(current, c, p, ctx)
	if prop_equal(current, c, p) || (!ok && !spec.allow_discrete) || combined <= 0 {
		remove_transition(tl, ea, running, true)
		return
	}
	if prop_equal(running.reverse_start, c, p) {
		// going back to where it came from: shorten by how far it got (CSS Transitions 1 §3, reversing)
		_, out := transition_progress(running, tl.now)
		factor := clamp(abs(out * running.shortening + 1 - running.shortening), 0, 1)
		d := delay < 0 ? delay * factor : delay
		start_transition(tl, ea, p, current, c, running.to, duration * factor, d, spec.easing, !ok, factor)
		remove_transition(tl, ea, running, true)
		return
	}
	start_transition(tl, ea, p, current, c, current, duration, delay, spec.easing, !ok, 1)
	remove_transition(tl, ea, running, true)
}

////////////////////////////////
// Animations: progress

@(private)
Run_State :: struct {
	phase:     Phase,
	effect:    bool,     // the animation affects values now (active, or filling)
	directed:  f64,      // directed progress in the iteration, 0..1
	iteration: f64,
	before:    bool,     // the before flag for step easings
	active:    f64,      // active duration
	t:         f64,      // local time minus delay
}

@(private)
run_state :: proc(r: ^Anim_Run) -> (st: Run_State) {
	dur := max(f64(r.spec.duration), 0)
	iters := max(f64(r.spec.iterations), 0)
	st.t = r.local - f64(r.spec.delay)
	st.active = dur * iters
	if dur == 0 || iters == 0 { st.active = 0 }
	switch {
	case st.t < 0: st.phase = .Before
	case st.t < st.active: st.phase = .Active
	case: st.phase = .After
	}
	fill := r.spec.fill
	overall: f64
	switch st.phase {
	case .Before:
		if fill != .Backwards && fill != .Both { return }
		overall = 0
		st.before = true
	case .Active:
		overall = st.t / dur
	case .After:
		if fill != .Forwards && fill != .Both { return }
		overall = math.is_inf(iters) ? 0 : iters
	}
	st.effect = true
	sip := overall - math.floor(overall)
	if math.is_inf(overall) || math.is_nan(overall) { sip = 0 }
	cur := math.floor(overall)
	if sip == 0 && st.phase == .After && overall != 0 { sip = 1; cur -= 1 }
	st.iteration = cur
	forwards := true
	odd := math.mod(cur, 2) != 0
	switch r.spec.direction {
	case .Normal: forwards = true
	case .Reverse: forwards = false
	case .Alternate: forwards = !odd
	case .Alternate_Reverse: forwards = odd
	}
	st.directed = forwards ? sip : 1 - sip
	return
}

@(private)
ensure_frames :: proc(tl: ^Timeline, doc: ^dom.Document, s: ^Styled, ea: ^Element_Anim, r: ^Anim_Run) {
	if r.frames_ready && r.frames_gen == ea.base_gen && r.frames_rebuilds == tl.engine.rebuilds { return }
	virtual.arena_free_all(&r.frames_arena)
	a := virtual.arena_allocator(&r.frames_arena)
	r.frames, r.props = nil, {}
	r.frames_gen, r.frames_rebuilds, r.frames_ready = ea.base_gen, tl.engine.rebuilds, true
	set := keyframes_lookup(tl.engine, r.name)
	if set == nil || ea.base == nil { return }
	parent: ^Computed
	if n := dom.get(doc, ea.node); n != nil && n.parent != base.NIL_HANDLE { parent = base_style_of(s, n.parent) }
	frames := make([]Frame_Value, len(set.frames), a)
	for &block, i in set.frames {
		c := compute_keyframe(tl.engine, &block, ea.base, parent, s.initial, s.root_font_size, a)
		frames[i] = Frame_Value{offset = f64(block.offset), c = c, props = block.props, easing = clone_easing(block.easing, a), has_easing = block.has_easing}
	}
	r.frames = frames
	r.props = set.props
}

// Writes the animation's values into dst (the element's overlay). `scratch` is a temporary for underlying values.
@(private)
apply_run :: proc(r: ^Anim_Run, st: Run_State, dst, scratch: ^Computed, ctx: ^Interp_Ctx) -> Prop_Set {
	if !st.effect { return {} }
	Kf :: struct { offset: f64, c: ^Computed, easing: Easing }
	list := make([dynamic]Kf, context.temp_allocator)
	for p in Prop {
		if !ps_has(r.props, p) { continue }
		clear(&list)
		for f in r.frames {
			if ps_has(f.props, p) { append(&list, Kf{f.offset, f.c, f.has_easing ? f.easing : r.spec.easing}) }
		}
		if len(list) == 0 { continue }
		// implicit 0% and 100% keyframes take the underlying value
		if list[0].offset > 0 { inject_at(&list, 0, Kf{0, nil, r.spec.easing}) }
		if list[len(list) - 1].offset < 1 { append(&list, Kf{1, nil, r.spec.easing}) }
		copy_prop(scratch, dst, p)
		x := st.directed
		k := 0
		for k + 2 < len(list) && list[k + 1].offset <= x { k += 1 }
		ka, kb := list[k], list[k + 1]
		span := kb.offset - ka.offset
		local := span > 0 ? (x - ka.offset) / span : (x >= kb.offset ? 1 : 0)
		t := easing_eval(ka.easing, local, st.before)
		a := ka.c != nil ? ka.c : scratch
		b := kb.c != nil ? kb.c : scratch
		if r.spec.composition != .Replace {
			// each keyframe value is composed with the underlying value, then interpolated
			ca := new(Computed, context.temp_allocator)
			cb := new(Computed, context.temp_allocator)
			ca^, cb^ = scratch^, scratch^
			if ka.c != nil && add_prop(ca, scratch, ka.c, p, ctx) { a = ca }
			if kb.c != nil && add_prop(cb, scratch, kb.c, p, ctx) { b = cb }
		}
		if !interpolate_prop(dst, a, b, p, t, ctx) { discrete_prop(dst, a, b, p, t) }
	}
	return r.props
}

////////////////////////////////
// The tick

// Advances the clock to `wall_ms`, fires the events that became due and writes the animated values into `s`.
// Returns true when some computed value changed (s.serial changed too).
timeline_tick :: proc(tl: ^Timeline, doc: ^dom.Document, s: ^Styled, wall_ms: f64) -> bool {
	advance(tl, wall_ms)
	now := tl.now
	changed := tl.dirty
	next := -1.0
	want :: proc(next: ^f64, ms: f64) { if next^ < 0 || ms < next^ { next^ = max(ms, 0) } }
	finished := make([dynamic]^Transition, context.temp_allocator)
	for _, ea in tl.elements {
		for tr in ea.transitions {
			phase, eased := transition_progress(tr, now)
			if phase != .Before && !tr.start_sent {
				tr.start_sent = true
				push_event(tl, .Transition_Start, ea.node, prop_name(tr.prop), max(min(-tr.delay, tr.duration), 0))
			}
			if phase == .After && !tr.done {
				tr.done = true
				push_event(tl, .Transition_End, ea.node, prop_name(tr.prop), tr.duration)
				append(&finished, tr)
			}
			key := [2]f64{f64(phase), eased}
			if key != tr.key { tr.key = key; changed = true }
			switch phase {
			case .Before: want(&next, tr.start + tr.delay - now)
			case .Active: want(&next, 0)
			case .After:
			}
		}
		for r in ea.runs {
			if r.spec.play_state == .Running { r.local += now - r.last_now }
			r.last_now = now
			st := run_state(r)
			if st.phase != .Before && !r.started {
				r.started = true
				push_event(tl, .Animation_Start, ea.node, r.name, max(min(-f64(r.spec.delay), st.active), 0))
			}
			if st.phase == .Active && r.spec.duration > 0 {
				it := math.floor(st.t / f64(r.spec.duration))
				if r.iteration >= 0 && it > r.iteration {
					push_event(tl, .Animation_Iteration, ea.node, r.name, it * f64(r.spec.duration))
				}
				r.iteration = it
			}
			if st.phase == .After && !r.ended {
				r.ended = true
				push_event(tl, .Animation_End, ea.node, r.name, st.active)
			}
			key := [3]f64{f64(st.phase), st.directed, st.effect ? 1 : 0}
			if key != r.key { r.key = key; changed = true }
			if r.spec.play_state == .Running {
				switch st.phase {
				case .Before: want(&next, -st.t)
				case .Active: want(&next, 0)
				case .After:
				}
			}
		}
	}
	tl.next_ms = next
	// a finished transition leaves the cascaded value in place; the overlays that pointed into it are rebuilt below
	// before anything reads them
	for tr in finished { remove_finished(tl, tr) }
	if !changed { return false }
	tl.dirty = false
	if len(tl.elements) == 0 && len(tl.overlays) == 0 { return false }
	apply_overlays(tl, doc, s)
	styled_touch(s)
	update_canvas(s, doc)
	return true
}

@(private)
remove_finished :: proc(tl: ^Timeline, tr: ^Transition) {
	for h, ea in tl.elements {
		if _, i := find_transition(ea, tr.prop); i >= 0 && ea.transitions[i] == tr {
			remove_transition(tl, ea, tr, false)
			if len(ea.transitions) == 0 && len(ea.runs) == 0 {
				element_free(tl, ea)
				delete_key(&tl.elements, h)
				tl.order_dirty = true
			}
			return
		}
	}
}

@(private)
restore_overlays :: proc(tl: ^Timeline, s: ^Styled) {
	for h, ov in tl.overlays {
		idx := int(base.handle_index(h))
		if idx < len(s.by_node) && s.by_node[idx] == &ov.c {
			if b, ok := s.overlaid[h]; ok { s.by_node[idx] = b }
		}
		delete_key(&s.overlaid, h)
	}
}

// Tree order of two nodes (index paths from the root).
@(private)
sort_order :: proc(tl: ^Timeline, doc: ^dom.Document) {
	clear(&tl.order)
	for _, ea in tl.elements { append(&tl.order, ea) }
	Keyed :: struct { ea: ^Element_Anim, path: []int }
	keyed := make([]Keyed, len(tl.order), context.temp_allocator)
	for ea, i in tl.order {
		path := make([dynamic]int, context.temp_allocator)
		for cur := ea.node; cur != base.NIL_HANDLE; {
			n := dom.get(doc, cur)
			if n == nil { break }
			k := 0
			for p := n.prev; p != base.NIL_HANDLE; p = dom.get(doc, p).prev { k += 1 }
			append(&path, k)
			cur = n.parent
		}
		slice.reverse(path[:])
		keyed[i] = Keyed{ea, path[:]}
	}
	slice.sort_by(keyed, proc(a, b: Keyed) -> bool {
		for i in 0 ..< min(len(a.path), len(b.path)) { if a.path[i] != b.path[i] { return a.path[i] < b.path[i] } }
		return len(a.path) < len(b.path)
	})
	for k, i in keyed { tl.order[i] = k.ea }
	tl.order_dirty = false
}

@(private)
overlay_for :: proc(tl: ^Timeline, s: ^Styled, h: base.Handle) -> ^Overlay {
	ov := tl.overlays[h] or_else nil
	if ov == nil {
		ov = new(Overlay)
		_ = virtual.arena_init_growing(&ov.arena, 16 * 1024)
		tl.overlays[h] = ov
	}
	if ov.tick != tl.tick {
		virtual.arena_free_all(&ov.arena)
		b := base_style_of(s, h)
		ov.c = b^
		ov.tick = tl.tick
		idx := int(base.handle_index(h))
		s.by_node[idx] = &ov.c
		s.overlaid[h] = b
	}
	return ov
}

// Rebuilds every overlay from the cascaded styles and the effects in force.
@(private)
apply_overlays :: proc(tl: ^Timeline, doc: ^dom.Document, s: ^Styled) {
	restore_overlays(tl, s)
	if s.overlaid == nil { s.overlaid = make(map[base.Handle]^Computed) }
	tl.tick += 1
	if tl.order_dirty { sort_order(tl, doc) }
	scratch := new(Computed, context.temp_allocator)
	for ea in tl.order {
		if style_of(s, ea.node) == nil { continue }
		has := len(ea.transitions) > 0
		for r in ea.runs { if run_state(r).effect { has = true } }
		if !has { continue }
		ov := overlay_for(tl, s, ea.node)
		ctx := Interp_Ctx{alloc = virtual.arena_allocator(&ov.arena), space = tl.engine.settings.anim_color_space}
		animated: Prop_Set
		for r in ea.runs {
			st := run_state(r)
			if !st.effect { continue }
			ensure_frames(tl, doc, s, ea, r)
			animated = ps_union(animated, apply_run(r, st, &ov.c, scratch, &ctx))
		}
		for tr in ea.transitions {   // transitions override animations (CSS Cascade 5: the transition origin)
			transition_value(tr, tl.now, &ov.c, &ctx)
			ps_add(&animated, tr.prop)
		}
		derive_fields(&ov.c)
		push := ps_intersect(animated, inherited_set)
		if !ps_empty(push) {
			pseudo_inherit(&ov.c, push, ctx.alloc)
			push_inherited(tl, doc, s, ea.node, &ov.c, push)
		}
	}
	// overlays nobody needed this time
	stale := make([dynamic]base.Handle, context.temp_allocator)
	for h, ov in tl.overlays { if ov.tick != tl.tick { append(&stale, h) } }
	for h in stale {
		overlay_free(tl.overlays[h])
		delete_key(&tl.overlays, h)
	}
}

// ::before / ::after take the animated inherited values of their element.
@(private)
pseudo_inherit :: proc(c: ^Computed, set: Prop_Set, alloc: runtime.Allocator) {
	for slot in ([2]^^Computed{&c.before, &c.after}) {
		pc := slot^
		if pc == nil { continue }
		take := ps_intersect(set, pc.inherits)
		if ps_empty(take) { continue }
		cp := new(Computed, alloc)
		cp^ = pc^
		for p in Prop { if ps_has(take, p) { copy_prop(cp, c, p) } }
		derive_fields(cp)
		slot^ = cp
	}
}

// Inherited animated properties reach the descendants that inherit them (and stop where one sets its own value).
@(private)
push_inherited :: proc(tl: ^Timeline, doc: ^dom.Document, s: ^Styled, h: base.Handle, src: ^Computed, set: Prop_Set) {
	Item :: struct { h: base.Handle, src: ^Computed, set: Prop_Set }
	stack := make([dynamic]Item, context.temp_allocator)
	n := dom.get(doc, h)
	if n == nil { return }
	for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, Item{ch, src, set}) }
	for len(stack) > 0 {
		it := pop(&stack)
		cn := dom.get(doc, it.h)
		if cn == nil || cn.kind != .Element { continue }
		cb := base_style_of(s, it.h)
		if cb == nil { continue }
		take := ps_intersect(it.set, cb.inherits)
		if ps_empty(take) { continue }
		ov := overlay_for(tl, s, it.h)
		for p in Prop { if ps_has(take, p) { copy_prop(&ov.c, it.src, p) } }
		derive_fields(&ov.c)
		pseudo_inherit(&ov.c, take, virtual.arena_allocator(&ov.arena))
		for ch := cn.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, Item{ch, &ov.c, take}) }
	}
}
