package style

import "base:runtime"
import "core:math"
import "core:slice"
import "core:strings"
import "wb:base"
import "wb:dom"

// The floor of style.animations.time_scale in the arithmetic of the timelines (page/web_animations.odin too).
ANIM_TIME_SCALE_MIN :: 0.0001

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
	arena:      base.Arena,
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
	serial:     u64,           // its identity for scripts (css_anim_api.odin): never reused
}

@(private)
Frame_Value :: struct {
	offset:     f64,
	c:          ^Computed,     // the keyframe's values for this element (props only)
	props:      Prop_Set,
	easing:     Easing,
	has_easing: bool,
	composition: Composition,
	has_composition: bool,   // false: the animation's
}

@(private)
Anim_Run :: struct {
	name:        string,       // heap
	spec:        Animation_Spec,
	spec_arena:  base.Arena,   // the spec's easing points
	frames_arena: base.Arena,
	frames:      []Frame_Value,
	props:       Prop_Set,
	frames_gen:  u64,          // the Element_Anim.base_gen the frames were computed for
	frames_rebuilds: u64,
	frames_ready: bool,
	frames_ranged: bool,       // some keyframe is at a named range: its place follows the timeline
	frames_moved:  bool,       // those ranges moved since
	local:       f64,          // time since the animation started, advancing only while it runs
	last_now:    f64,
	started:     bool,
	ended:       bool,
	iteration:   f64,          // last iteration reported
	key:         [3]f64,       // phase, directed progress, effect of the last tick
	set:         ^Keyframes_Set,   // the keyframes of a script's effect (script_anim.odin); nil: the @keyframes `name`
	serial:      u64,          // its identity for scripts (css_anim_api.odin): never reused
	forced:      Css_Forced,   // what a script's pause() / play() / cancel() set over animation-play-state
	timeline:    Anim_Timeline,       // animation-timeline (.Auto: the document's; its name in spec_arena). Another: `local` is progress (scroll_timeline.odin)
	index:       int,                 // its place in the animation-* lists
	src:         Timeline_Source,     // what that timeline reads
	progress:    Progress_Timeline,   // that timeline as last measured
	phase_seen:  Phase,               // the phase its events last told (a progress-based animation goes back and forth)
}

// A script's hold on a CSS animation (CSSAnimation.pause / play / cancel): it wins over animation-play-state until
// animation-name drops the animation.
Css_Forced :: enum u8 { None, Paused, Running, Canceled }

@(private)
run_running :: #force_inline proc(r: ^Anim_Run) -> bool {
	switch r.forced {
	case .Paused, .Canceled: return false
	case .Running: return true
	case .None:
	}
	return r.spec.play_state == .Running
}

@(private)
Element_Anim :: struct {
	node:        base.Handle,
	transitions: [dynamic]^Transition,
	runs:        [dynamic]^Anim_Run,
	scripts:     [dynamic]^Script_Run,   // effects of Web Animations on it, in composite order (owned by Timeline.scripts)
	base:        ^Computed,    // its cascaded style as of the last restyle
	base_gen:    u64,          // changes with `base` (pointers into recycled style memory may repeat)
}

@(private)
Overlay :: struct {
	c:     Computed,
	arena: base.Arena,
	tick:  u64,
	sig:   u8,     // structure_sig of `c` as last applied (what layout saw)
	pushed_by: base.Handle,   // the animated ancestor it inherits `pushed` from (push_inherited); NIL: none
	pushed:    Prop_Set,
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
	event_arena: base.Arena,
	dirty:       bool,         // the next tick recomputes the overlays even if no progress changed
	tick:        u64,
	running:     int,          // transitions + animations alive
	next_ms:     f64,          // document ms until a value changes next: 0 = every frame, -1 = never
	dropped_events: int,
	base_gens:   u64,
	last_props:  Prop_Set,     // properties the overlays wrote at the last application
	retired:     [dynamic]^Anim_Run,   // animations that ended in this restyle, freed once update_element is done with the old style
	scripts:     map[u64]^Script_Run,  // the effects of Web Animations, by animation (script_anim.odin)
	css_serial:  u64,                  // the last serial given to a CSS animation or transition
	progress_timelines: map[u64]^Script_Timeline,   // the ScrollTimeline and ViewTimeline objects of scripts
	seen:        Seen_Probe,   // who can see an animated element (timeline_set_seen); none: everyone
	throttled:   bool,         // the last tick let an animation nobody sees wait past the next frame (timeline_behind)
}

// Whether an animated element can be seen, as the page's last layout says (page/animations_seen.odin). An animation moves at every frame
// only for what can be: one that nobody sees asks for its next tick at its next event, or after `anim_unseen_tick_ms` to look again
// (a transform may bring it into view). Asked during a tick: `begin` once before the first question, then `seen` per element.
// `moves_boxes`: what is animated is not paint-only, so its changes move other boxes, which may be seen.
Seen_Probe :: struct {
	user:  rawptr,
	begin: proc(user: rawptr),
	seen:  proc(user: rawptr, node: base.Handle, moves_boxes: bool) -> bool,
}

timeline_set_seen :: proc(tl: ^Timeline, probe: Seen_Probe) { tl.seen = probe }

// The unseen tick governs what is painted, never what a script reads: a reading of the styles or of the animations at `wall_ms` later
// than the last tick, when that tick let an unseen animation wait, ticks first (page/js_dom_layout.odin styles_clean, web_animations_css.odin).
timeline_behind :: proc(tl: ^Timeline, wall_ms: f64) -> bool { return tl != nil && tl.throttled && tl.has_wall && wall_ms > tl.last_wall }

// The questions of one tick: the probe begins only if one is asked.
@(private)
Seen_Ask :: struct {
	tl:        ^Timeline,
	begun:     bool,
	throttled: bool,   // an answer let an animation wait
}

// When an active animation of `node` animating `props` wants its next tick: 0 when it can be seen (or nobody says), else `until`
// (ms to its next event) capped by the setting.
@(private)
seen_wait :: proc(a: ^Seen_Ask, node: base.Handle, props: Prop_Set, until: f64) -> f64 {
	tl := a.tl
	every := tl.engine.settings.anim_unseen_tick_ms
	if every <= 0 || tl.seen.seen == nil { return 0 }
	if !a.begun {
		a.begun = true
		if tl.seen.begin != nil { tl.seen.begin(tl.seen.user) }
	}
	if tl.seen.seen(tl.seen.user, node, !paint_only(props)) { return 0 }
	a.throttled = true
	return max(min(until, every), 0)
}

// The document time until an active run's next event: the end of its iteration, or of its active phase (+1: after it, as hold_ms).
@(private)
run_next_event_ms :: proc(r: ^Anim_Run, st: Run_State) -> f64 {
	left := st.active - st.t
	if dur := f64(r.spec.duration); dur > 0 { left = min(left, dur - math.mod(st.t, dur)) }
	return left + 1
}

timeline_make :: proc(e: ^Engine) -> ^Timeline {
	tl := new(Timeline)
	tl.engine = e
	tl.elements = make(map[base.Handle]^Element_Anim)
	tl.overlays = make(map[base.Handle]^Overlay)
	tl.scripts = make(map[u64]^Script_Run)
	tl.order = make([dynamic]^Element_Anim)
	tl.events = make([dynamic]Anim_Event)
	_ = base.arena_init_growing(&tl.event_arena, 64 * 1024)
	tl.next_ms = -1
	return tl
}

// Frees everything. When `s` is given, its entries are put back to the cascaded styles first.
timeline_destroy :: proc(tl: ^Timeline, s: ^Styled = nil) {
	if tl == nil { return }
	if s != nil { restore_overlays(tl, s) }
	for _, ea in tl.elements { element_free(tl, ea) }
	delete(tl.elements)
	for _, sr in tl.scripts { script_run_free(sr) }
	delete(tl.scripts)
	for _, st in tl.progress_timelines { free(st) }
	delete(tl.progress_timelines)
	for _, ov in tl.overlays { overlay_retire(s, ov) }
	delete(tl.overlays)
	delete(tl.order)
	delete(tl.events)
	for r in tl.retired { run_free(r) }
	delete(tl.retired)
	base.arena_destroy(&tl.event_arena)
	free(tl)
}

// Cancels everything (navigation, settings that turn animations off) without events.
timeline_reset :: proc(tl: ^Timeline, s: ^Styled) {
	if s != nil {
		for h in overlay_handles(tl) { journal_add(s, h, .Box) }   // back to their cascaded values, whatever was animated
		restore_overlays(tl, s)
	}
	for _, ea in tl.elements { element_free(tl, ea) }
	clear(&tl.elements)
	for _, sr in tl.scripts { script_run_free(sr) }
	clear(&tl.scripts)
	for _, ov in tl.overlays { overlay_retire(s, ov) }
	clear(&tl.overlays)
	clear(&tl.order)
	tl.running = 0
	tl.next_ms = -1
	tl.last_props = {}
	if s != nil { styled_touch(s) }
}

@(private)
element_free :: proc(tl: ^Timeline, ea: ^Element_Anim) {
	for tr in ea.transitions { transition_free(tr); tl.running -= 1 }
	for r in ea.runs { run_free(r); tl.running -= 1 }
	for sr in ea.scripts { sr.node = base.NIL_HANDLE }
	delete(ea.transitions)
	delete(ea.runs)
	delete(ea.scripts)
	free(ea)
}

@(private)
transition_free :: proc(tr: ^Transition) { base.arena_destroy(&tr.arena); free(tr) }

@(private)
run_free :: proc(r: ^Anim_Run) {
	base.arena_destroy(&r.spec_arena)
	base.arena_destroy(&r.frames_arena)
	delete(r.name)
	free(r)
}

@(private)
overlay_free :: proc(ov: ^Overlay) { base.arena_destroy(&ov.arena); free(ov) }

// An overlay is over: a layout of `s` may still point at its record (see styled_read_begin), until it has followed the journal.
@(private)
overlay_retire :: proc(s: ^Styled, ov: ^Overlay) {
	if s != nil && s.readers > 0 { append(&s.dead_overlays, ov) } else { overlay_free(ov) }
}

////////////////////////////////
// Clock and events

@(private)
advance :: proc(tl: ^Timeline, wall_ms: f64) {
	if !tl.has_wall { tl.has_wall, tl.last_wall = true, wall_ms; return }
	// (a task's time, held, may be older than a frame made meanwhile: the clock never goes back, nor counts a span twice)
	d := wall_ms - tl.last_wall
	if d <= 0 { return }
	tl.now += d * f64(max(tl.engine.settings.anim_time_scale, ANIM_TIME_SCALE_MIN))
	tl.last_wall = wall_ms
}

@(private)
push_event :: proc(tl: ^Timeline, kind: Anim_Event_Kind, node: base.Handle, name: string, elapsed: f64) {
	if len(tl.events) >= max(tl.engine.settings.anim_max_events, 1) { tl.dropped_events += 1; return }
	nm := strings.clone(name, base.arena_allocator(&tl.event_arena))
	append(&tl.events, Anim_Event{kind = kind, node = node, name = nm, elapsed = elapsed})
}

// The events queued since the last `timeline_clear_events`, in the order they happened.
timeline_events :: proc(tl: ^Timeline) -> []Anim_Event { return tl.events[:] }

timeline_clear_events :: proc(tl: ^Timeline) {
	clear(&tl.events)
	base.arena_free_all(&tl.event_arena)
}

// Some value changes at every frame: the shell should keep drawing.
timeline_active :: proc(tl: ^Timeline) -> bool { return tl != nil && tl.next_ms == 0 }

// The wall time its clock last moved to (0: it never moved).
timeline_wall :: proc(tl: ^Timeline) -> f64 { return tl != nil && tl.has_wall ? tl.last_wall : 0 }

// Wall-clock milliseconds until the next change of an animated value (0 = now / every frame, -1 = nothing pending).
timeline_next_ms :: proc(tl: ^Timeline) -> f64 {
	if tl == nil || tl.next_ms < 0 { return -1 }
	return tl.next_ms / f64(max(tl.engine.settings.anim_time_scale, ANIM_TIME_SCALE_MIN))
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
	// what partial restyles replaced in `old` before they handed over to this pass: their change is still to be heard
	before := make(map[base.Handle]^Computed, context.temp_allocator)
	if old != nil { for ch in old.changes { if ch.node not_in before { before[ch.node] = ch.old } } }
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
				if oc := before[f.h] or_else style_of(old, f.h); oc != nil && !hidden_in(old, doc, f.h, before) { old_eff = oc }
			}
			update_element(tl, doc, s, f.h, old_eff, c, hidden)
			seen[f.h] = true
		}
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, Frame{ch, hidden}) }
	}
	gone := make([dynamic]base.Handle, context.temp_allocator)
	for h in tl.elements { if h not_in seen { append(&gone, h) } }
	slice.sort(gone[:])
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
			slice.sort(inside[:])
			for h in inside { drop_element(tl, doc, h) }
		}
	}
	clear(&s.changes)
}

// After partial restyles (restyle_dom, restyle_state): the changes they recorded, the animations of elements that
// left the document, and those of elements inside subtrees shown again (their own style may not have changed).
timeline_restyled_dom :: proc(tl: ^Timeline, doc: ^dom.Document, s: ^Styled, wall_ms: f64) {
	timeline_restyled_partial(tl, doc, s, wall_ms)
	if s.removed_any && len(tl.elements) > 0 {
		gone := make([dynamic]base.Handle, context.temp_allocator)
		for h in tl.elements { if !connected(doc, h) || style_of(s, h) == nil { append(&gone, h) } }
		slice.sort(gone[:])
		for h in gone { drop_element(tl, doc, h) }
	}
	s.removed_any = false
	if len(s.shown) > 0 && s.motion && mode_of(tl) != .Off {
		stack := make([dynamic]base.Handle, context.temp_allocator)
		for r in s.shown {
			if hidden_in(s, doc, r) { continue }
			clear(&stack)
			append(&stack, r)
			for len(stack) > 0 {
				h := pop(&stack)
				n := dom.get(doc, h)
				if n == nil || n.kind != .Element { continue }
				c := base_style_of(s, h)
				if c == nil || c.display == .None { continue }
				if h != r && h not_in tl.elements && (has_transitions(c) || has_animations(c)) {
					update_element(tl, doc, s, h, nil, c, false)
					tl.dirty = true
				}
				for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
			}
		}
	}
	clear(&s.shown)
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

// `h` or an ancestor has display: none in `s` (cascaded values), or in the record of `before` that stands for its own.
@(private)
hidden_in :: proc(s: ^Styled, doc: ^dom.Document, h: base.Handle, before: map[base.Handle]^Computed = nil) -> bool {
	for cur := h; cur != base.NIL_HANDLE; {
		n := dom.get(doc, cur)
		if n == nil || n.kind != .Element { return false }
		if cs := before[cur] or_else base_style_of(s, cur); cs != nil && cs.display == .None { return true }
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
	tl.order_dirty, tl.dirty = true, true
	if len(ea.scripts) > 0 {
		// the effects of scripts stay with their target (it may be shown or inserted again); its CSS ones go
		for tr in ea.transitions { transition_free(tr); tl.running -= 1 }
		for r in ea.runs { run_free(r); tl.running -= 1 }
		clear(&ea.transitions)
		clear(&ea.runs)
		ea.base = nil
		return
	}
	element_free(tl, ea)
	delete_key(&tl.elements, h)
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
	for r in tl.retired { run_free(r) }
	clear(&tl.retired)
	if len(ea.runs) == 0 && len(ea.transitions) == 0 && len(ea.scripts) == 0 {
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
			tl.css_serial += 1
			r.serial = tl.css_serial
			r.last_now = tl.now
			r.iteration = -1
			r.key = {-1, -1, -1}
			_ = base.arena_init_growing(&r.spec_arena, 16 * 1024)
			_ = base.arena_init_growing(&r.frames_arena, 64 * 1024)
			tl.running += 1
		}
		// the time since its last tick went by under the spec it had: a paused run was not ticked while the page drew nothing
		if r.timeline.kind == .Auto && run_running(r) { r.local += tl.now - r.last_now }
		r.last_now = tl.now
		spec := animation_at(c, i)
		base.arena_free_all(&r.spec_arena)
		spec.easing = clone_easing(spec.easing, base.arena_allocator(&r.spec_arena))
		spec.name = r.name
		r.index = i
		r.timeline = spec.timeline
		r.timeline.name = strings.clone(spec.timeline.name, base.arena_allocator(&r.spec_arena))
		spec.timeline, spec.range_start, spec.range_end = {}, {}, {}   // (in the style's memory: the sample reads them again)
		if r.timeline.kind != .Auto {
			spec = spec_normalised(spec)
		} else if mode_of(tl) == .Reduce {
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
		// freed after update_transitions (update_element): the effective style of the last frame, which that compares with the new
		// base, holds strings and slices of this run's frames arena (a value a keyframe or a var() of an animated custom property made)
		append(&tl.retired, old)
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
	_ = base.arena_init_growing(&tr.arena, 16 * 1024)
	a := base.arena_allocator(&tr.arena)
	tr.prop = p
	tl.css_serial += 1
	tr.serial = tl.css_serial
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
	prop_take(dst, tr.prop, ctx.alloc)
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
	if r.forced == .Canceled { return }   // canceled by a script: idle, no effect
	if r.timeline.kind != .Auto && !r.progress.active { return }   // an inactive timeline: no current time
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
		// (a scroller at the very end of its range still shows the end of an animation that reaches it: the boundary is the active phase's)
		at_limit := r.timeline.kind != .Auto && r.progress.offset >= r.progress.hi && st.t <= st.active
		if fill != .Forwards && fill != .Both && !at_limit { return }
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
	if r.frames_ready && !r.frames_moved && r.frames_gen == ea.base_gen && r.frames_rebuilds == tl.engine.rebuilds { return }
	r.frames_moved = false
	base.arena_free_all(&r.frames_arena)
	a := base.arena_allocator(&r.frames_arena)
	r.frames, r.props = nil, {}
	r.frames_gen, r.frames_rebuilds, r.frames_ready = ea.base_gen, tl.engine.rebuilds, true
	set := r.set != nil ? r.set : keyframes_lookup(tl.engine, r.name)
	if set == nil || ea.base == nil { return }
	parent: ^Computed
	if n := dom.get(doc, ea.node); n != nil && n.parent != base.NIL_HANDLE { parent = base_style_of(s, n.parent) }
	frames := make([dynamic]Frame_Value, 0, len(set.frames), a)
	props := set.props
	for &block in set.frames {
		if block.range != .Normal { r.frames_ranged = true }
		offset, used := keyframe_offset(r, &block)
		if !used { continue }
		c, extra := compute_keyframe(tl.engine, &block, ea.base, parent, s.initial, s.root_font_size, a)
		append(&frames, Frame_Value{offset = offset, c = c, props = ps_union(block.props, extra), easing = clone_easing(block.easing, a), has_easing = block.has_easing,
			composition = block.composition, has_composition = block.has_composition})
		props = ps_union(props, extra)
	}
	slice.stable_sort_by(frames[:], proc(a, b: Frame_Value) -> bool { return a.offset < b.offset })
	r.frames = frames[:]
	r.props = props
}

// Where a keyframe stands in its animation. One at a named range (`entry 50%`) has a place only on a timeline with that range, within the attachment range.
@(private)
keyframe_offset :: proc(r: ^Anim_Run, block: ^Keyframe_Block) -> (offset: f64, used: bool) {
	if block.range == .Normal { return f64(block.offset), true }
	t := &r.progress
	if !t.active || t.end <= t.start { return 0, false }
	span := t.ranges[block.range]
	offset = (span[0] + (span[1] - span[0]) * f64(block.offset) - t.start) / (t.end - t.start)
	return offset, offset >= 0 && offset <= 1
}

// Writes the animation's values into dst (the element's overlay). `scratch` is a temporary for underlying values.
@(private)
apply_run :: proc(r: ^Anim_Run, st: Run_State, dst, scratch: ^Computed, ctx: ^Interp_Ctx) -> Prop_Set {
	if !st.effect { return {} }
	Kf :: struct { offset: f64, c: ^Computed, easing: Easing, composition: Composition }
	list := make([dynamic]Kf, context.temp_allocator)
	for p in Prop {
		if !ps_has(r.props, p) { continue }
		clear(&list)
		for f in r.frames {
			if ps_has(f.props, p) { append(&list, Kf{f.offset, f.c, f.has_easing ? f.easing : r.spec.easing, f.has_composition ? f.composition : r.spec.composition}) }
		}
		if len(list) == 0 { continue }
		// implicit 0% and 100% keyframes take the underlying value
		if list[0].offset > 0 { inject_at(&list, 0, Kf{0, nil, r.spec.easing, .Replace}) }
		if list[len(list) - 1].offset < 1 { append(&list, Kf{1, nil, r.spec.easing, .Replace}) }
		prop_take(dst, p, ctx.alloc)
		prop_take(scratch, p, context.temp_allocator)
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
		// each keyframe value is composed with the underlying value (its own composite operation, else the
		// animation's), then interpolated
		if ka.composition != .Replace && ka.c != nil {
			ca := new(Computed, context.temp_allocator)
			ca^ = scratch^
			prop_take(ca, p, context.temp_allocator)
			if add_prop(ca, scratch, ka.c, p, ctx) { a = ca }
		}
		if kb.composition != .Replace && kb.c != nil {
			cb := new(Computed, context.temp_allocator)
			cb^ = scratch^
			prop_take(cb, p, context.temp_allocator)
			if add_prop(cb, scratch, kb.c, p, ctx) { b = cb }
		}
		if !interpolate_prop(dst, a, b, p, t, ctx) { discrete_prop(dst, a, b, p, t) }
	}
	return r.props
}

// How long until the values of a running animation change again, when they hold still now: the two keyframes that bound its
// progress give every animated property the same value (the pause of a loop: `40% { a } 100% { a }`). The timeline then asks for
// its next tick at the end of that stretch instead of at once, so a page whose only motion is such a loop does not redraw at every
// frame while the loop rests. ok false: something moves now, or this cannot be told (a property with an implicit 0% or 100% keyframe
// takes the underlying value, which is not known here).
@(private)
hold_ms :: proc(r: ^Anim_Run, st: Run_State) -> (ms: f64, ok: bool) {
	if !r.frames_ready || len(r.frames) == 0 || !(r.spec.duration > 0) { return 0, false }
	odd := math.mod(st.iteration, 2) != 0
	forwards := true
	switch r.spec.direction {
	case .Normal: forwards = true
	case .Reverse: forwards = false
	case .Alternate: forwards = !odd
	case .Alternate_Reverse: forwards = odd
	}
	x := st.directed
	left := math.INF_F64   // progress left until the nearest keyframe at which a value may start to move, in the direction the animation runs
	for p in Prop {
		if !ps_has(r.props, p) { continue }
		lo, hi: ^Frame_Value
		lo_off, hi_off := -1.0, 2.0
		for &f in r.frames {
			if !ps_has(f.props, p) { continue }
			if f.offset <= x && f.offset >= lo_off { lo, lo_off = &f, f.offset }
			if f.offset > x && f.offset < hi_off { hi, hi_off = &f, f.offset }
		}
		if lo == nil || hi == nil || lo.c == nil || hi.c == nil || !prop_equal(lo.c, hi.c, p) { return 0, false }
		left = min(left, forwards ? hi_off - x : x - lo_off)
	}
	if math.is_inf(left) || !(left > 0) { return 0, false }
	return left * f64(r.spec.duration) + 1, true
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
	ask := Seen_Ask{tl = tl}
	finished := make([dynamic]^Transition, context.temp_allocator)
	if tl.order_dirty { sort_order(tl, doc) }   // (the events reach the page in this order: a map's comes from addresses)
	for ea in tl.order {
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
			case .Active:
				props: Prop_Set
				ps_add(&props, tr.prop)
				want(&next, next == 0 ? 0 : seen_wait(&ask, ea.node, props, tr.start + tr.delay + tr.duration - now + 1))   // (one seen: every frame, no more questions)
			case .After:
			}
		}
		for r in ea.runs {
			if r.timeline.kind != .Auto {
				if progress_tick(tl, ea, r) { changed = true }
				continue
			}
			if run_running(r) { r.local += now - r.last_now }
			r.last_now = now
			if r.forced == .Canceled { continue }
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
			if run_running(r) {
				switch st.phase {
				case .Before: want(&next, -st.t)
				case .Active:
					if ms, held := hold_ms(r, st); held { want(&next, ms) } else { want(&next, next == 0 ? 0 : seen_wait(&ask, ea.node, r.props, run_next_event_ms(r, st))) }
				case .After:
				}
			}
		}
	}
	if len(tl.scripts) > 0 && script_tick(tl, now, &next) { changed = true }
	tl.next_ms = next
	tl.throttled = ask.throttled
	// a finished transition leaves the cascaded value in place; the overlays that pointed into it are rebuilt below
	// before anything reads them
	for tr in finished { remove_finished(tl, tr) }
	if !changed { return false }
	tl.dirty = false
	if len(tl.elements) == 0 && len(tl.overlays) == 0 { return false }
	// only paint-only values moved (the usual transform / opacity / color animation): layout may refresh instead of
	// laying out again
	if apply_overlays(tl, doc, s) { styled_touch(s) } else { styled_touch_paint(s) }
	update_canvas(s, doc)
	return true
}

// The tick of an animation on a progress timeline: it stands where its timeline was last measured, and asks for no frame of its own
// (the scroll that moves it brings one). Its events follow its phase, either way (CSS Animations 2 §4.3).
@(private)
progress_tick :: proc(tl: ^Timeline, ea: ^Element_Anim, r: ^Anim_Run) -> (changed: bool) {
	r.last_now = tl.now
	if r.forced == .Canceled { return }
	if run_running(r) && r.progress.active { r.local = progress_local(&r.progress, r.progress.offset) }
	st := run_state(r)
	key := [3]f64{f64(st.phase), st.directed, st.effect ? 1 : 0}
	if key != r.key { r.key = key; changed = true }
	if !r.progress.active { return }
	if st.phase == .Active && r.spec.duration > 0 {
		it := math.floor(st.t / f64(r.spec.duration))
		if r.iteration >= 0 && it != r.iteration { push_event(tl, .Animation_Iteration, ea.node, r.name, it * f64(r.spec.duration)) }
		r.iteration = it
	}
	if !r.started || st.phase != r.phase_seen {
		was := r.started ? r.phase_seen : Phase.Before
		if st.phase != was {
			if was != .Active && st.phase != was { push_event(tl, .Animation_Start, ea.node, r.name, 0) }
			if st.phase != .Active { push_event(tl, .Animation_End, ea.node, r.name, st.active) }
		}
		r.started, r.ended = st.phase != .Before || r.started, st.phase == .After
		r.phase_seen = st.phase
	}
	return
}

////////////////////////////////
// The compositor's values

// What a box keeps while an animation may change it (Computed.compositing).
Compositing :: enum u8 { Transform, Opacity, Filter, Clip_Path }
Compositing_Set :: bit_set[Compositing; u8]

// What the compositor may move without the page: a transformed box's matrix and an opacity group's alpha.
COMPOSITOR_PROPS :: [?]Prop{.Transform, .Translate, .Rotate, .Scale, .Opacity}
// What a chrome frame paints from the style record of the box (Compositor_Value.record): colours, shadows, radii, effects' parameters. The
// items keep their place, and the pictures of the chunks they are in are recorded again.
RECORD_PROPS :: [?]Prop{
	.Color, .Background_Color, .Background_Position, .Background_Size, .Border_Top_Color, .Border_Right_Color, .Border_Bottom_Color, .Border_Left_Color,
	.Border_Top_Left_Radius, .Border_Top_Right_Radius, .Border_Bottom_Right_Radius, .Border_Bottom_Left_Radius, .Box_Shadow, .Text_Shadow,
	.Text_Decoration_Color, .Outline_Color, .Outline_Offset, .Filter, .Backdrop_Filter, .Clip_Path, .Object_Position, .Caret_Color, .Accent_Color,
	.Mask_Position, .Mask_Size, .Text_Fill_Color, .Text_Stroke_Color, .Text_Emphasis_Color, .Text_Stroke_Width,
}

@(private)
compositing_of :: proc(props: Prop_Set) -> (out: Compositing_Set) {
	if ps_has(props, .Transform) || ps_has(props, .Translate) || ps_has(props, .Rotate) || ps_has(props, .Scale) { out += {.Transform} }
	if ps_has(props, .Opacity) { out += {.Opacity} }
	if ps_has(props, .Filter) { out += {.Filter} }
	if ps_has(props, .Clip_Path) { out += {.Clip_Path} }
	return
}

// An element's style at a later instant than the page's last tick, for its compositor-only animations.
Compositor_Value :: struct {
	node:   base.Handle,
	cs:     ^Computed,   // its cascaded style with the animated properties at that instant (temp allocator)
	props:  Prop_Set,    // what is animated (some of COMPOSITOR_PROPS and RECORD_PROPS)
	record: ^Computed,   // the record its boxes and display items hold: `cs` takes its place for one paint, for RECORD_PROPS (nil: it has none now)
}

// What among `props` moves a box's transform space.
compositor_moves :: proc(props: Prop_Set) -> Prop_Set {
	list := COMPOSITOR_PROPS
	moves := ps_intersect(props, ps_of(..list[:]))
	ps_remove(&moves, .Opacity)
	return moves
}

// Something among `props` is more than the compositor can show over the last layout.
compositor_lays_out :: proc(props: Prop_Set) -> bool {
	list, records := COMPOSITOR_PROPS, RECORD_PROPS
	return ps_intersect(props, ps_union(ps_of(..list[:]), ps_of(..records[:]))) != props
}

// The RECORD_PROPS among `props`.
compositor_record_props :: proc(props: Prop_Set) -> Prop_Set {
	list := RECORD_PROPS
	return ps_intersect(props, ps_of(..list[:]))
}

// Where a chrome frame shows a scroller (CSS px; `source` NIL: the document).
Shown_Offset :: struct {
	source: base.Handle,
	pos:    [2]f64,
}

// `at` (a copy of a progress-based run) at the offset its scroller is shown at, if the chrome frame moved it.
@(private)
progress_shown :: proc(at: ^Anim_Run, shown: []Shown_Offset) {
	if !run_running(at) || !at.progress.active { return }
	for o in shown {
		if o.source != at.progress.source { continue }
		at.progress.offset = progress_offset(&at.progress, o.pos)
		at.local = progress_local(&at.progress, at.progress.offset)
		return
	}
}

// The values at `wall_ms` of the elements whose effects are CSS animations and transitions of COMPOSITOR_PROPS only, written
// into `out` without moving the timeline: its clock, runs, events and overlays stay as the page's last tick left them, and that
// is what scripts read. The page's tick takes over at its turn from the same clock. An animation on a scroll or view timeline
// stands where `shown` puts its scroller. Left out: elements a script animates (Web Animations), animations whose keyframes were
// not resolved for the element's style yet, effects that do not run. `moving`: one of the values changes at every frame; `any`: there is one (`out` nil: only that is told).
timeline_compositor_values :: proc(tl: ^Timeline, s: ^Styled, wall_ms: f64, shown: []Shown_Offset, lays_out: bool, out: ^[dynamic]Compositor_Value) -> (moving, any: bool) {
	if tl == nil || s == nil || !tl.has_wall || len(tl.elements) == 0 { return }
	list, records := COMPOSITOR_PROPS, RECORD_PROPS
	allowed := ps_union(ps_of(..list[:]), ps_of(..records[:]))
	now := tl.now + max(wall_ms - tl.last_wall, 0) * f64(max(tl.engine.settings.anim_time_scale, ANIM_TIME_SCALE_MIN))
	scratch := new(Computed, context.temp_allocator)
	ctx := Interp_Ctx{alloc = context.temp_allocator, space = tl.engine.settings.anim_color_space}
	elements: for _, ea in tl.elements {
		b := base_style_of(s, ea.node)
		if len(ea.scripts) > 0 || b == nil || style_of(s, ea.node) == nil { continue }
		props: Prop_Set
		live := false   // (by the page's time: an effect that ends at the later instant shows its end, not the layout's value)
		for r in ea.runs {
			if !r.frames_ready || r.frames_gen != ea.base_gen || r.frames_rebuilds != tl.engine.rebuilds { continue elements }
			props = ps_union(props, r.props)
			if run_running(r) && (run_state(r).phase != .After || r.timeline.kind != .Auto) { live = true }
		}
		for tr in ea.transitions {
			ps_add(&props, tr.prop)
			if phase, _ := transition_progress(tr, tl.now); phase != .After { live = true }
		}
		if !live || ps_empty(props) || (!lays_out && ps_intersect(props, allowed) != props) { continue }
		any = true
		if out == nil {
			for r in ea.runs {
				if r.timeline.kind != .Auto || !run_running(r) { continue }
				at := r^
				at.local += now - at.last_now
				if run_state(&at).phase == .Active { moving = true }
			}
			for tr in ea.transitions { if phase, _ := transition_progress(tr, now); phase == .Active { moving = true } }
			continue
		}
		c := new(Computed, context.temp_allocator)
		c^ = b^
		for r in ea.runs {
			at := r^   // (a copy at that instant: the run keeps the page's time)
			if at.timeline.kind != .Auto {
				progress_shown(&at, shown)
			} else {
				if run_running(&at) { at.local += now - at.last_now }
				if run_state(&at).phase == .Active && run_running(&at) { moving = true }
			}
			apply_run(&at, run_state(&at), c, scratch, &ctx)
		}
		for tr in ea.transitions {
			if phase, _ := transition_progress(tr, now); phase == .Active { moving = true }
			transition_value(tr, now, c, &ctx)
		}
		derive_fields(c, context.temp_allocator)
		ov := tl.overlays[ea.node] or_else nil
		record: ^Computed
		if ov != nil {
			record = &ov.c
			c.compositing = ov.c.compositing
		}
		push := ps_intersect(props, inherited_set)
		if !ps_empty(push) { pseudo_inherit(c, push, context.temp_allocator) }
		append(out, Compositor_Value{node = ea.node, cs = c, props = props, record = record})
	}
	if out != nil { compositor_inherited(tl, out) }
	return
}

// The descendants that inherit an animated value at that instant (their overlays say from whom: push_inherited).
@(private)
compositor_inherited :: proc(tl: ^Timeline, out: ^[dynamic]Compositor_Value) {
	shown := len(out)
	any_inherited := false
	for &v in out[:shown] { if !ps_empty(ps_intersect(v.props, inherited_set)) { any_inherited = true } }
	if !any_inherited { return }
	for h, ov in tl.overlays {
		if ov.pushed_by == base.NIL_HANDLE { continue }
		for &v in out[:shown] {
			if v.node != ov.pushed_by { continue }
			take := ps_intersect(ov.pushed, v.props)
			if ps_empty(take) { break }
			c := new(Computed, context.temp_allocator)
			c^ = ov.c
			group_take(c, .Inherited, context.temp_allocator)
			for p in Prop { if ps_has(take, p) { copy_prop(c, v.cs, p) } }
			derive_fields(c, context.temp_allocator)
			pseudo_inherit(c, take, context.temp_allocator)
			append(out, Compositor_Value{node = h, cs = c, props = take, record = &ov.c})
			break
		}
	}
}

@(private)
remove_finished :: proc(tl: ^Timeline, tr: ^Transition) {
	for h, ea in tl.elements {
		if _, i := find_transition(ea, tr.prop); i >= 0 && ea.transitions[i] == tr {
			remove_transition(tl, ea, tr, false)
			if len(ea.transitions) == 0 && len(ea.runs) == 0 && len(ea.scripts) == 0 {
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
		return len(a.path) != len(b.path) ? len(a.path) < len(b.path) : u64(a.ea.node) < u64(b.ea.node)   // (nodes that are gone have one path)
	})
	for k, i in keyed { tl.order[i] = k.ea }
	tl.order_dirty = false
}

@(private)
overlay_for :: proc(tl: ^Timeline, s: ^Styled, h: base.Handle) -> ^Overlay {
	ov := tl.overlays[h] or_else nil
	if ov == nil {
		ov = new(Overlay)
		_ = base.arena_init_growing(&ov.arena, 16 * 1024)
		ov.sig = structure_sig(base_style_of(s, h))
		tl.overlays[h] = ov
	}
	if ov.tick != tl.tick {
		base.arena_free_all(&ov.arena)
		b := base_style_of(s, h)
		ov.c = b^
		ov.tick = tl.tick
		ov.pushed_by, ov.pushed = base.NIL_HANDLE, {}
		idx := int(base.handle_index(h))
		s.by_node[idx] = &ov.c
		s.overlaid[h] = b
	}
	return ov
}

// Rebuilds every overlay from the cascaded styles and the effects in force. Returns true when what changed may affect
// layout: a property that is not paint-only was (or stops being) animated, or a structural threshold was crossed.
@(private)
apply_overlays :: proc(tl: ^Timeline, doc: ^dom.Document, s: ^Styled) -> (layout: bool) {
	props: Prop_Set
	restore_overlays(tl, s)
	if s.overlaid == nil { s.overlaid = make(map[base.Handle]^Computed) }
	tl.tick += 1
	if tl.order_dirty { sort_order(tl, doc) }
	scratch := new(Computed, context.temp_allocator)
	for ea in tl.order {
		if style_of(s, ea.node) == nil { continue }
		has := len(ea.transitions) > 0
		for r in ea.runs { if run_state(r).effect || (r.timeline.kind != .Auto && r.progress.active) { has = true } }
		for sr in ea.scripts { if script_state_of(tl, sr, tl.now).has_active { has = true } }
		if !has { continue }
		if ea.base == nil {   // an element only scripts animate, not restyled since
			ea.base = base_style_of(s, ea.node)
			tl.base_gens += 1
			ea.base_gen = tl.base_gens
		}
		ov := overlay_for(tl, s, ea.node)
		ctx := Interp_Ctx{alloc = base.arena_allocator(&ov.arena), space = tl.engine.settings.anim_color_space}
		animated: Prop_Set
		promised: Prop_Set   // (CSS Animations 1 §3: the box behaves as under will-change for what a running animation targets)
		for r in ea.runs {
			st := run_state(r)
			on_scroll := r.timeline.kind != .Auto && r.progress.active   // (out of its range now, in it as soon as the scroll moves: chrome frames show it then)
			if !st.effect && !on_scroll { continue }
			ensure_frames(tl, doc, s, ea, r)
			promised = ps_union(promised, r.props)
			if st.effect { animated = ps_union(animated, apply_run(r, st, &ov.c, scratch, &ctx)) }
		}
		ov.c.compositing = compositing_of(promised)
		// Web Animations, above the CSS animations (composite order: CSS animations first)
		for sr in ea.scripts {
			es := script_state_of(tl, sr, tl.now)
			if !es.has_active { continue }
			ensure_frames(tl, doc, s, ea, &sr.run)
			animated = ps_union(animated, apply_run(&sr.run, Run_State{effect = true, directed = es.progress, before = es.before_flag}, &ov.c, scratch, &ctx))
		}
		for tr in ea.transitions {   // transitions override animations (CSS Cascade 5: the transition origin)
			transition_value(tr, tl.now, &ov.c, &ctx)
			ps_add(&animated, tr.prop)
		}
		derive_fields(&ov.c, ctx.alloc)
		props = ps_union(props, animated)
		if !paint_only(animated) { // TMPDBG
			n := dom.get(doc, ea.node); id, _ := dom.get_attribute(doc, ea.node, "id"); cl, _ := dom.get_attribute(doc, ea.node, "class")
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, dbg_layout_anim)
			strings.write_string(&b, n != nil ? n.name : "?"); strings.write_string(&b, "#"); strings.write_string(&b, id); strings.write_string(&b, "."); strings.write_string(&b, cl[:min(len(cl), 40)])
			for pp in Prop { if ps_has(animated, pp) && !ps_has(paint_set, pp) { strings.write_string(&b, ":"); strings.write_string(&b, prop_name(pp)) } }
			strings.write_string(&b, " ")
			dbg_layout_anim = strings.to_string(b)
		}
		push := ps_intersect(animated, inherited_set)
		if !ps_empty(push) {
			pseudo_inherit(&ov.c, push, ctx.alloc)
			push_inherited(tl, doc, s, ea.node, &ov.c, push)
		}
	}
	// overlays nobody needed this time
	stale := make([dynamic]base.Handle, context.temp_allocator)
	// for the layout journal: what the animated values (and those going back to their cascaded values) may change
	level := props_level(ps_union(props, tl.last_props))
	for h in overlay_handles(tl) {
		ov := tl.overlays[h]
		if ov.tick != tl.tick {
			append(&stale, h)
			crossed := ov.sig != structure_sig(style_of(s, h))
			if crossed { layout = true }
			journal_add(s, h, crossed ? .Box : max(level, Change_Level.Paint))   // back to its cascaded record
			continue
		}
		sig := structure_sig(&ov.c)
		crossed := sig != ov.sig
		if crossed { layout = true; ov.sig = sig; dbg_layout_anim = strings.concatenate({dbg_layout_anim, "CROSSED "}, context.temp_allocator) } // TMPDBG
		journal_add(s, h, crossed ? .Box : max(level, Change_Level.Paint))   // the overlay record (and its pseudo-elements')
	}
	for h in stale {
		overlay_retire(s, tl.overlays[h])
		delete_key(&tl.overlays, h)
	}
	if !paint_only(ps_union(props, tl.last_props)) { layout = true; if !paint_only(tl.last_props) && paint_only(props) { dbg_layout_anim = strings.concatenate({dbg_layout_anim, "LASTPROPS "}, context.temp_allocator) } } // TMPDBG
	s.animated = ps_union(props, tl.last_props)
	tl.last_props = props
	return
}

// The elements with an overlay, by handle: the journal says the same in every run (a map's order comes from addresses).
@(private)
overlay_handles :: proc(tl: ^Timeline) -> []base.Handle {
	hs, _ := slice.map_keys(tl.overlays, context.temp_allocator)
	slice.sort(hs)
	return hs
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
		group_take(cp, .Inherited, alloc)   // (shared with its element's cascaded style)
		for p in Prop { if ps_has(take, p) { copy_prop(cp, c, p) } }
		derive_fields(cp, alloc)
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
		ov.pushed_by, ov.pushed = h, take
		oa := base.arena_allocator(&ov.arena)
		group_take(&ov.c, .Inherited, oa)   // (shared with its cascaded style, or with the parent's)
		for p in Prop { if ps_has(take, p) { copy_prop(&ov.c, it.src, p) } }
		derive_fields(&ov.c, oa)
		pseudo_inherit(&ov.c, take, oa)
		for ch := cn.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, Item{ch, &ov.c, take}) }
	}
}

dbg_layout_anim: string // TMPDBG
