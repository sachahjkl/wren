package style

import "base:runtime"
import "core:math"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:css"

// Effects of Web Animations (Element.animate, new KeyframeEffect) on the document timeline.
//
// The page owns the animations (play state, pending tasks, promises, events: page/web_animations.odin); the timeline
// owns their keyframe effects: the keyframes compiled for the engine, the timing, and the animation's clock (start
// time, hold time, playback rate), from which each tick computes the effect's local time (Web Animations 1 §4.4) and
// writes the values exactly as it writes a CSS animation's (`apply_run`), above the CSS animations of the element and
// below its transitions, in composite order (the order the page created them in, `id`).
//
// Keyframes come packed by the engine (native/js/runtime/web_animations.c): keyframes separated by U+001E, the fields
// of one separated by U+001F: its computed offset, its easing ("" for linear), then property name / value pairs (CSS
// names, custom properties included). Each value is parsed for its property alone: a value that would hold another
// declaration ("red; width: 0") is refused like an invalid one. Keyframes at the same offset stay distinct (the later
// wins once its offset is reached), as Web Animations says.
//
// Limits: the composite operation of a keyframe is not used (the effect's applies to all of its keyframes); effects on
// pseudo-elements are not supported (the engine refuses them).

Effect_Phase :: enum u8 { Before, Active, After }

// The timing of an effect (Web Animations 1 §4.5 "EffectTiming", the values already checked). Times in ms.
Effect_Timing :: struct {
	delay, end_delay: f64,
	duration:         f64,   // the iteration duration (>= 0; "auto" is 0)
	iterations:       f64,   // >= 0, may be +Inf
	iteration_start:  f64,   // >= 0
	direction:        Anim_Direction,
	fill:             Fill_Mode,   // "auto" is none for a keyframe effect
	easing:           Easing,
}

// What the timing gives at a local time (Web Animations 1 §4.6-4.10). `has_*` false: the value is unresolved (null).
Effect_State :: struct {
	phase:         Effect_Phase,
	has_local:     bool,
	has_active:    bool,      // in effect: the effect gives values now
	active_time:   f64,
	progress:      f64,       // the transformed progress (the effect's easing applied)
	iteration:     f64,       // the current iteration (may be +Inf)
	before_flag:   bool,      // for step easings
}

// The clock of an animation: its current time is the hold time when there is one, else (timeline time - start time) x rate.
Script_Clock :: struct {
	start, hold:          f64,
	has_start, has_hold:  bool,
	rate:                 f64,
	timeline:             bool,   // associated with the document timeline (false: a null timeline, never resolved)
}

@(private)
Script_Run :: struct {
	using run:   Anim_Run,      // frames, props, composition: what apply_run reads
	id:          u64,
	node:        base.Handle,   // NIL: an effect without a target
	timing:      Effect_Timing,
	clock:       Script_Clock,
	set_arena:   virtual.Arena, // the compiled keyframes and the timing's easing
	skey:        [3]f64,        // phase, progress, in effect at the last tick
}

effect_active_duration :: proc(t: Effect_Timing) -> f64 {
	if t.duration == 0 || t.iterations == 0 { return 0 }
	return t.duration * t.iterations
}

effect_end_time :: proc(t: Effect_Timing) -> f64 {
	return max(t.delay + effect_active_duration(t) + t.end_delay, 0)
}

// The state of an effect at local time `local` (`has_local` false: unresolved). `backwards`: the animation plays
// backwards (a negative playback rate), which decides the phase at a boundary.
effect_state :: proc(t: Effect_Timing, local: f64, has_local: bool, backwards := false) -> (st: Effect_State) {
	if !has_local { return }
	st.has_local = true
	active := effect_active_duration(t)
	end := effect_end_time(t)
	before_active := max(min(t.delay, end), 0)
	active_after := max(min(t.delay + active, end), 0)
	switch {
	case local < before_active || (backwards && local == before_active): st.phase = .Before
	case local > active_after || (!backwards && local == active_after): st.phase = .After
	case: st.phase = .Active
	}
	switch st.phase {
	case .Before:
		if t.fill != .Backwards && t.fill != .Both { return }
		st.active_time = max(local - t.delay, 0)
	case .Active:
		st.active_time = local - t.delay
	case .After:
		if t.fill != .Forwards && t.fill != .Both { return }
		st.active_time = max(min(local - t.delay, active), 0)
	}
	st.has_active = true
	overall: f64
	if t.duration == 0 {
		overall = st.phase == .Before ? 0 : t.iterations
	} else {
		overall = st.active_time / t.duration
	}
	overall += t.iteration_start
	simple: f64
	if math.is_inf(overall) { simple = math.mod(t.iteration_start, 1) } else { simple = overall - math.floor(overall) }
	if simple == 0 && (st.phase == .Active || st.phase == .After) && st.active_time == active && t.iterations != 0 { simple = 1 }
	switch {
	case st.phase == .After && math.is_inf(t.iterations): st.iteration = math.inf_f64(1)
	case simple == 1: st.iteration = math.floor(overall) - 1
	case: st.iteration = math.floor(overall)
	}
	forwards := true
	switch t.direction {
	case .Normal: forwards = true
	case .Reverse: forwards = false
	case .Alternate, .Alternate_Reverse:
		d := st.iteration
		if t.direction == .Alternate_Reverse { d += 1 }
		forwards = math.is_inf(d) || math.mod(d, 2) == 0
	}
	directed := forwards ? simple : 1 - simple
	st.before_flag = (st.phase == .Before && forwards) || (st.phase == .After && !forwards)
	st.progress = easing_eval(t.easing, directed, st.before_flag)
	return
}

// The current time of a clock at timeline time `now`.
script_clock_time :: proc(c: Script_Clock, now: f64) -> (f64, bool) {
	if c.has_hold { return c.hold, true }
	if !c.timeline || !c.has_start { return 0, false }
	return (now - c.start) * c.rate, true
}

// Whether `text` is an easing function (CSS Easing 2).
easing_valid :: proc(e: ^Engine, text: string) -> bool {
	_, ok := parse_easing_text(e, text, context.temp_allocator)
	return ok
}

@(private)
parse_easing_text :: proc(e: ^Engine, text: string, a: runtime.Allocator) -> (Easing, bool) {
	if strings.trim_space(text) == "" { return {}, false }
	vs := css.parse_component_values(text, parse_options(&e.settings), a)
	probe := probe_context(e, a)
	return parse_easing(&probe, vs)
}

// Compiles packed keyframes (see above) into `a`. ok false: a keyframe's easing does not parse.
script_keyframes_compile :: proc(e: ^Engine, packed: string, a: runtime.Allocator) -> (set: ^Keyframes_Set, ok: bool) {
	set = new(Keyframes_Set, a)
	blocks := make([dynamic]Keyframe_Block, a)
	opt := parse_options(&e.settings)
	frames := packed
	for frame in strings.split_iterator(&frames, "\x1e") {
		if frame == "" { continue }
		fields := strings.split(frame, "\x1f", context.temp_allocator)
		if len(fields) < 2 { continue }
		offset, _ := strconv.parse_f64(fields[0])
		b := Keyframe_Block{offset = f32(clamp(offset, 0, 1))}
		if fields[1] != "" && fields[1] != "linear" {
			easing, good := parse_easing_text(e, fields[1], a)
			if !good { return nil, false }
			b.easing, b.has_easing = easing, true
		}
		decls := make([dynamic]css.Declaration, context.temp_allocator)
		for i := 2; i + 1 < len(fields); i += 2 {
			name, value := fields[i], fields[i + 1]
			if name == "" || strings.trim_space(value) == "" { continue }
			if !strings.has_prefix(name, "--") {
				p, _, known := lookup_property(name)
				if !known || not_in_keyframes(p) || p == .Animation_Timing_Function { continue }
			}
			// one declaration of that property, nothing else
			text := strings.concatenate({name, ":", value}, context.temp_allocator)
			parsed := css.parse_declarations(text, opt, a)
			if len(parsed) != 1 || parsed[0].important || !strings.equal_fold(parsed[0].name, name) { continue }
			append(&decls, parsed[0])
		}
		compiled, customs := compile_declarations(e, decls[:], a)
		b.decls = compiled
		b.customs = customs
		for d in compiled { ps_add(&b.props, d.prop); ps_add(&set.props, d.prop) }
		append(&blocks, b)
	}
	// stable: keyframes at the same offset keep their order
	for i in 1 ..< len(blocks) {
		for k := i; k > 0 && blocks[k - 1].offset > blocks[k].offset; k -= 1 { blocks[k - 1], blocks[k] = blocks[k], blocks[k - 1] }
	}
	set.frames = blocks[:]
	return set, true
}

@(private)
script_run_free :: proc(sr: ^Script_Run) {
	virtual.arena_destroy(&sr.set_arena)
	virtual.arena_destroy(&sr.frames_arena)
	free(sr)
}

@(private)
script_element :: proc(tl: ^Timeline, h: base.Handle) -> ^Element_Anim {
	ea := tl.elements[h] or_else nil
	if ea == nil {
		ea = new(Element_Anim)
		ea.node = h
		ea.transitions = make([dynamic]^Transition)
		ea.runs = make([dynamic]^Anim_Run)
		tl.elements[h] = ea
		tl.order_dirty = true
	}
	return ea
}

@(private)
script_detach :: proc(tl: ^Timeline, sr: ^Script_Run) {
	if sr.node == base.NIL_HANDLE { return }
	ea := tl.elements[sr.node] or_else nil
	sr.node = base.NIL_HANDLE
	if ea == nil { return }
	for x, i in ea.scripts { if x == sr { ordered_remove(&ea.scripts, i); break } }
	if len(ea.runs) == 0 && len(ea.transitions) == 0 && len(ea.scripts) == 0 {
		element_free(tl, ea)
		delete_key(&tl.elements, ea.node)
		tl.order_dirty = true
	}
}

@(private)
script_attach :: proc(tl: ^Timeline, sr: ^Script_Run, h: base.Handle) {
	sr.node = h
	if h == base.NIL_HANDLE { return }
	ea := script_element(tl, h)
	// composite order: by id
	at := len(ea.scripts)
	for x, i in ea.scripts { if x.id > sr.id { at = i; break } }
	inject_at(&ea.scripts, at, sr)
	sr.frames_ready = false
}

// Creates or replaces the keyframe effect of animation `id`: its target (NIL: none), its keyframes (packed), its timing
// (the easing as text) and composite operation. ok false (nothing changed): an easing does not parse.
timeline_script_put :: proc(tl: ^Timeline, id: u64, node: base.Handle, packed: string, timing: Effect_Timing, easing: string, composite: Composition) -> bool {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena, 16 * 1024)
	a := virtual.arena_allocator(&arena)
	t := timing
	t.easing = Easing{kind = .Linear}
	if easing != "" && easing != "linear" {
		ez, ok := parse_easing_text(tl.engine, easing, a)
		if !ok { virtual.arena_destroy(&arena); return false }
		t.easing = ez
	}
	set, ok := script_keyframes_compile(tl.engine, packed, a)
	if !ok { virtual.arena_destroy(&arena); return false }
	sr := tl.scripts[id] or_else nil
	if sr == nil {
		sr = new(Script_Run)
		sr.id = id
		sr.name = ""
		sr.key = {-1, -1, -1}
		sr.skey = {-1, -1, -1}
		sr.clock.rate = 1
		_ = virtual.arena_init_growing(&sr.frames_arena, 16 * 1024)
		tl.scripts[id] = sr
	} else {
		virtual.arena_destroy(&sr.set_arena)
	}
	sr.set_arena = arena
	sr.set = set
	sr.timing = t
	sr.spec = Animation_Spec{easing = Easing{kind = .Linear}, iterations = 1, composition = composite}
	sr.frames_ready = false
	if sr.node != node {
		script_detach(tl, sr)
		script_attach(tl, sr, node)
	}
	tl.dirty = true
	tl.next_ms = 0
	return true
}

// The clock of animation `id` changed (play, pause, seek, playback rate...).
timeline_script_clock :: proc(tl: ^Timeline, id: u64, clock: Script_Clock) {
	sr := tl.scripts[id] or_else nil
	if sr == nil || sr.clock == clock { return }
	sr.clock = clock
	tl.dirty = true
	tl.next_ms = 0
}

// The effect of animation `id` goes (its animation was cancelled, removed, freed, or lost its effect).
timeline_script_remove :: proc(tl: ^Timeline, id: u64) {
	sr := tl.scripts[id] or_else nil
	if sr == nil { return }
	script_detach(tl, sr)
	delete_key(&tl.scripts, id)
	script_run_free(sr)
	tl.dirty = true
	tl.next_ms = 0
}

// The timing of the effect of animation `id` (nil: it has none).
timeline_script_timing :: proc(tl: ^Timeline, id: u64) -> ^Effect_Timing {
	sr := tl.scripts[id] or_else nil
	return sr != nil ? &sr.timing : nil
}

timeline_script_target :: proc(tl: ^Timeline, id: u64) -> base.Handle {
	sr := tl.scripts[id] or_else nil
	return sr != nil ? sr.node : base.NIL_HANDLE
}

// Every property the effect of `id` animates is animated by one of the effects of `later` on the same target (Web
// Animations 1 §5.5 "removing replaced animations").
timeline_script_covered :: proc(tl: ^Timeline, id: u64, later: []u64) -> bool {
	sr := tl.scripts[id] or_else nil
	if sr == nil || sr.set == nil || sr.node == base.NIL_HANDLE { return false }
	left := sr.set.props
	for lid in later {
		o := tl.scripts[lid] or_else nil
		if o == nil || o == sr || o.node != sr.node || o.set == nil { continue }
		for i in 0 ..< len(left.bits) { left.bits[i] &~= o.set.props.bits[i] }
		if ps_empty(left) { return true }
	}
	return ps_empty(left)
}

// Some effect of a script changed since the last tick: the styles are not up to date (getComputedStyle must tick).
timeline_dirty :: proc(tl: ^Timeline) -> bool { return tl != nil && tl.dirty }

// The timeline's current time (document ms, the animation time scale applied), advanced to the wall clock first.
timeline_time :: proc(tl: ^Timeline, wall_ms: f64) -> f64 {
	advance(tl, wall_ms)
	return tl.now
}

@(private)
script_state_of :: proc(sr: ^Script_Run, now: f64) -> Effect_State {
	local, has := script_clock_time(sr.clock, now)
	return effect_state(sr.timing, local, has, sr.clock.rate < 0)
}

// The tick's part for the effects of scripts: did a value change, and when does one change next.
@(private)
script_tick :: proc(tl: ^Timeline, now: f64, next: ^f64) -> (changed: bool) {
	want :: proc(next: ^f64, ms: f64) { if next^ < 0 || ms < next^ { next^ = max(ms, 0) } }
	for _, sr in tl.scripts {
		if sr.node == base.NIL_HANDLE { continue }
		st := script_state_of(sr, now)
		key := [3]f64{f64(st.phase), st.progress, st.has_active ? 1 : 0}
		if !st.has_local { key = {-2, 0, 0} }
		if key != sr.skey { sr.skey = key; changed = true }
		c := sr.clock
		if !st.has_local || c.has_hold || !c.has_start || !c.timeline || c.rate == 0 { continue }
		local, _ := script_clock_time(c, now)
		t := sr.timing
		active := effect_active_duration(t)
		end := effect_end_time(t)
		rate := abs(c.rate)
		switch st.phase {
		case .Before:
			if c.rate > 0 { want(next, (max(min(t.delay, end), 0) - local) / rate) }
		case .Active:
			want(next, 0)
		case .After:
			if c.rate < 0 { want(next, (local - max(min(t.delay + active, end), 0)) / rate) }
		}
	}
	return
}
