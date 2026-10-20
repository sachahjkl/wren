package style

import "core:math"
import "core:strings"
import "wb:css"

// Easing functions (CSS Easing 2) and the list-valued transition-* / animation-* properties.

////////////////////////////////
// Parsing

parse_easing :: proc(cx: ^Cx, input: []css.Value) -> (Easing, bool) {
	vs := css.trim_values(input)
	if len(vs) != 1 { return {}, false }
	v := vs[0]
	if tok_is(v, .Ident) {
		switch ident_lower(v) {
		case "linear": return Easing{kind = .Linear}, true
		case "ease": return EASE, true
		case "ease-in": return Easing{kind = .Cubic_Bezier, p = {0.42, 0, 1, 1}}, true
		case "ease-out": return Easing{kind = .Cubic_Bezier, p = {0, 0, 0.58, 1}}, true
		case "ease-in-out": return Easing{kind = .Cubic_Bezier, p = {0.42, 0, 0.58, 1}}, true
		case "step-start": return Easing{kind = .Steps, steps = 1, pos = .Jump_Start}, true
		case "step-end": return Easing{kind = .Steps, steps = 1, pos = .Jump_End}, true
		}
		return {}, false
	}
	if v.kind != .Function { return {}, false }
	args := css.split_commas(v.children, context.temp_allocator)
	switch css.lower_temp(v.tok.text) {
	case "cubic-bezier":
		if len(args) != 4 { return {}, false }
		e := Easing{kind = .Cubic_Bezier}
		for a, i in args {
			n, ok := css.parse_number(a)
			if !ok || math.is_nan(n) || math.is_inf(n) { return {}, false }
			if (i == 0 || i == 2) && (n < 0 || n > 1) { return {}, false }
			e.p[i] = f32(n)
		}
		return e, true
	case "steps":
		if len(args) < 1 || len(args) > 2 { return {}, false }
		n, ok := css.parse_integer(args[0])
		if !ok { return {}, false }
		e := Easing{kind = .Steps, pos = .Jump_End}
		if len(args) == 2 {
			switch css.ident_of(args[1]) {
			case "jump-start", "start": e.pos = .Jump_Start
			case "jump-end", "end": e.pos = .Jump_End
			case "jump-none": e.pos = .Jump_None
			case "jump-both": e.pos = .Jump_Both
			case: return {}, false
			}
		}
		if n < 1 || (e.pos == .Jump_None && n < 2) { return {}, false }
		e.steps = i32(min(n, 1 << 24))
		return e, true
	case "linear":
		return parse_linear_points(cx, args)
	}
	return {}, false
}

@(private)
parse_linear_points :: proc(cx: ^Cx, args: [][]css.Value) -> (Easing, bool) {
	Raw :: struct { output: f32, input: f32, has_input: bool }
	raw := make([dynamic]Raw, context.temp_allocator)
	for a in args {
		items := split_items(a)
		output: f32
		have_out := false
		inputs: [2]f32
		n_in := 0
		for it in items {
			if tok_is(it, .Percentage) {
				if n_in >= 2 { return {}, false }
				inputs[n_in] = f32(it.tok.num / 100)
				n_in += 1
				continue
			}
			n, ok := number_of(it)
			if !ok || have_out { return {}, false }
			output, have_out = f32(n), true
		}
		if !have_out { return {}, false }
		if n_in == 0 { append(&raw, Raw{output = output}) }
		for k in 0 ..< n_in { append(&raw, Raw{output = output, input = inputs[k], has_input = true}) }
	}
	if len(raw) < 2 { return {}, false }
	// CSS Easing 2 §3.1.1: first input 0, last 1, never decreasing, runs of missing inputs spread evenly
	if !raw[0].has_input { raw[0].input, raw[0].has_input = 0, true }
	last := len(raw) - 1
	if !raw[last].has_input { raw[last].input, raw[last].has_input = max(1, raw[0].input), true }
	largest := raw[0].input
	for &r in raw {
		if !r.has_input { continue }
		r.input = max(r.input, largest)
		largest = r.input
	}
	i := 0
	for i < len(raw) {
		if raw[i].has_input { i += 1; continue }
		j := i
		for !raw[j].has_input { j += 1 }
		a, b := raw[i - 1].input, raw[j].input
		for k in i ..< j { raw[k].input = a + (b - a) * f32(k - i + 1) / f32(j - i + 1) }
		i = j
	}
	pts := make([]Linear_Stop, len(raw), cx.alloc)
	for r, k in raw { pts[k] = Linear_Stop{input = r.input, output = r.output} }
	return Easing{kind = .Points, points = pts}, true
}

////////////////////////////////
// Evaluation

// The eased output for an input progress `t` (usually 0..1). `before` is the before flag of CSS Easing 2 (the animation
// is in its before phase), which matters for jumps at t = 0.
easing_eval :: proc(e: Easing, t: f64, before := false) -> f64 {
	switch e.kind {
	case .Linear: return t
	case .Cubic_Bezier: return cubic_bezier(f64(e.p[0]), f64(e.p[1]), f64(e.p[2]), f64(e.p[3]), t)
	case .Steps:
		n := f64(max(e.steps, 1))
		step := math.floor(t * n)
		if e.pos == .Jump_Start || e.pos == .Jump_Both { step += 1 }
		if before && math.mod(t * n, 1) == 0 { step -= 1 }
		if t >= 0 && step < 0 { step = 0 }
		jumps := n
		switch e.pos {
		case .Jump_Start, .Jump_End: jumps = n
		case .Jump_None: jumps = n - 1
		case .Jump_Both: jumps = n + 1
		}
		if t <= 1 && step > jumps { step = jumps }
		return step / jumps
	case .Points:
		pts := e.points
		if len(pts) == 0 { return t }
		if len(pts) == 1 { return f64(pts[0].output) }
		// the last segment whose start is <= t (extrapolate before the first and after the last)
		k := 0
		for k + 2 < len(pts) && f64(pts[k + 1].input) <= t { k += 1 }
		if t >= f64(pts[len(pts) - 1].input) { k = len(pts) - 2 }
		a, b := pts[k], pts[k + 1]
		// at an input shared by two points, the later point wins once t reaches it
		if f64(b.input) == t { return f64(b.output) }
		span := f64(b.input - a.input)
		if span <= 0 { return f64(t < f64(a.input) ? a.output : b.output) }
		return f64(a.output) + (f64(b.output) - f64(a.output)) * (t - f64(a.input)) / span
	}
	return t
}

// y for the x = t of the curve through (0,0), (x1,y1), (x2,y2), (1,1). Outside 0..1 the curve is extended along its end
// tangents (CSS Easing 2 §3.3).
cubic_bezier :: proc(x1, y1, x2, y2, t: f64) -> f64 {
	if t <= 0 {
		if x1 > 0 { return y1 / x1 * t }
		if y1 == 0 && x2 > 0 { return y2 / x2 * t }
		return 0
	}
	if t >= 1 {
		if x2 < 1 { return 1 + (y2 - 1) / (x2 - 1) * (t - 1) }
		if y2 == 1 && x1 < 1 { return 1 + (y1 - 1) / (x1 - 1) * (t - 1) }
		return 1
	}
	// coefficients of x(s) = ((ax s + bx) s + cx) s
	cx := 3 * x1
	bx := 3 * (x2 - x1) - cx
	ax := 1 - cx - bx
	cy := 3 * y1
	by := 3 * (y2 - y1) - cy
	ay := 1 - cy - by
	sample_x :: #force_inline proc(a, b, c, s: f64) -> f64 { return ((a * s + b) * s + c) * s }
	// Newton-Raphson from s = t, then bisection if it did not converge (flat derivative)
	s := t
	for _ in 0 ..< 8 {
		x := sample_x(ax, bx, cx, s) - t
		if abs(x) < 1e-7 { return sample_x(ay, by, cy, s) }
		d := (3 * ax * s + 2 * bx) * s + cx
		if abs(d) < 1e-6 { break }
		s -= x / d
	}
	lo, hi := 0.0, 1.0
	s = t
	for _ in 0 ..< 64 {
		x := sample_x(ax, bx, cx, s)
		if abs(x - t) < 1e-7 { break }
		if x < t { lo = s } else { hi = s }
		s = (lo + hi) / 2
	}
	return sample_x(ay, by, cy, s)
}

// True when the output only changes at discrete inputs (no need to repaint between them).
easing_is_stepped :: proc(e: Easing) -> bool { return e.kind == .Steps }

////////////////////////////////
// transition-* and animation-* lists

@(private)
list_parts :: proc(vs: []css.Value) -> [][]css.Value {
	return css.split_commas(css.trim_values(vs), context.temp_allocator)
}

apply_animation_list :: proc(cx: ^Cx, p: Prop, vs: []css.Value) -> bool {
	c := cx.c
	parts := list_parts(vs)
	n := len(parts)
	if n == 0 { return false }
	for part in parts { if len(css.trim_values(part)) == 0 { return false } }
	#partial switch p {
	case .Transition_Property:
		out := make([]Transition_Prop, n, cx.alloc)
		for part, i in parts {
			id, ok := ident_raw(part)
			if !ok { return false }
			lid := css.lower_temp(id)
			switch lid {
			case "none":
				if n != 1 { return false }
				out[i] = Transition_Prop{kind = .None}
				continue
			case "all":
				out[i] = Transition_Prop{kind = .All}
				continue
			case "initial", "inherit", "unset", "default", "revert", "revert-layer": return false
			}
			if pr, sh, known := lookup_property(lid); known {
				out[i] = sh == .None ? Transition_Prop{kind = .Prop, prop = pr} : Transition_Prop{kind = .Short, short = sh}
			} else {
				out[i] = Transition_Prop{kind = .Unknown, name = strings.clone(id, cx.alloc)}
			}
		}
		c.transition_property = out
	case .Transition_Duration, .Transition_Delay, .Animation_Duration, .Animation_Delay:
		out := make([]f32, n, cx.alloc)
		for part, i in parts {
			items := css.trim_values(part)
			if len(items) != 1 { return false }
			if p == .Animation_Duration && ident_lower(items[0]) == "auto" { out[i] = 0; continue }
			t, ok := parse_time(items[0], p == .Transition_Delay || p == .Animation_Delay)
			if !ok { return false }
			out[i] = t
		}
		#partial switch p {
		case .Transition_Duration: c.transition_duration = out
		case .Transition_Delay: c.transition_delay = out
		case .Animation_Duration: c.animation_duration = out
		case: c.animation_delay = out
		}
	case .Transition_Timing_Function, .Animation_Timing_Function:
		out := make([]Easing, n, cx.alloc)
		for part, i in parts {
			e, ok := parse_easing(cx, part)
			if !ok { return false }
			out[i] = e
		}
		if p == .Transition_Timing_Function { c.transition_timing = out } else { c.animation_timing = out }
	case .Transition_Behavior:
		out := make([]bool, n, cx.alloc)
		for part, i in parts {
			switch css.ident_of(part) {
			case "normal": out[i] = false
			case "allow-discrete": out[i] = true
			case: return false
			}
		}
		c.transition_behavior = out
	case .Animation_Name:
		out := make([]string, n, cx.alloc)
		for part, i in parts {
			items := css.trim_values(part)
			if len(items) != 1 { return false }
			if tok_is(items[0], .String) { out[i] = strings.clone(items[0].tok.text, cx.alloc); continue }
			if !tok_is(items[0], .Ident) { return false }
			switch ident_lower(items[0]) {
			case "none": out[i] = ""
			case "initial", "inherit", "unset", "default", "revert", "revert-layer": return false
			case: out[i] = strings.clone(items[0].tok.text, cx.alloc)
			}
		}
		c.animation_name = out
	case .Animation_Iteration_Count:
		out := make([]f32, n, cx.alloc)
		for part, i in parts {
			if css.ident_of(part) == "infinite" { out[i] = math.INF_F32; continue }
			v, ok := css.parse_number(part)
			if !ok || v < 0 || math.is_nan(v) { return false }
			out[i] = f32(v)
		}
		c.animation_iterations = out
	case .Animation_Direction:
		out := make([]Anim_Direction, n, cx.alloc)
		for part, i in parts { if !set_enum(part, &out[i]) { return false } }
		c.animation_direction = out
	case .Animation_Fill_Mode:
		out := make([]Fill_Mode, n, cx.alloc)
		for part, i in parts { if !set_enum(part, &out[i]) { return false } }
		c.animation_fill_mode = out
	case .Animation_Play_State:
		out := make([]Play_State, n, cx.alloc)
		for part, i in parts { if !set_enum(part, &out[i]) { return false } }
		c.animation_play_state = out
	case .Animation_Composition:
		out := make([]Composition, n, cx.alloc)
		for part, i in parts { if !set_enum(part, &out[i]) { return false } }
		c.animation_composition = out
	case: return false
	}
	return true
}

@(private)
list_at :: #force_inline proc(list: []$T, i: int, fallback: T) -> T { return len(list) == 0 ? fallback : list[i % len(list)] }

// The i-th transition of `c` (there are len(c.transition_property) of them), with the other lists repeated or cut to that
// length (CSS Transitions 1 §2).
Transition_Spec :: struct {
	property:       Transition_Prop,
	duration, delay: f32,     // ms
	easing:         Easing,
	allow_discrete: bool,
}

transition_at :: proc(c: ^Computed, i: int) -> Transition_Spec {
	return Transition_Spec{
		property = c.transition_property[i],
		duration = list_at(c.transition_duration, i, 0),
		delay = list_at(c.transition_delay, i, 0),
		easing = list_at(c.transition_timing, i, EASE),
		allow_discrete = list_at(c.transition_behavior, i, false),
	}
}

Animation_Spec :: struct {
	name:        string,
	duration, delay: f32,     // ms
	easing:      Easing,
	iterations:  f32,
	direction:   Anim_Direction,
	fill:        Fill_Mode,
	play_state:  Play_State,
	composition: Composition,
}

// The i-th animation of `c` (one per entry of animation-name).
animation_at :: proc(c: ^Computed, i: int) -> Animation_Spec {
	return Animation_Spec{
		name = c.animation_name[i],
		duration = list_at(c.animation_duration, i, 0),
		delay = list_at(c.animation_delay, i, 0),
		easing = list_at(c.animation_timing, i, EASE),
		iterations = list_at(c.animation_iterations, i, 1),
		direction = list_at(c.animation_direction, i, Anim_Direction.Normal),
		fill = list_at(c.animation_fill_mode, i, Fill_Mode.None),
		play_state = list_at(c.animation_play_state, i, Play_State.Running),
		composition = list_at(c.animation_composition, i, Composition.Replace),
	}
}

// Some transition of `c` has a positive combined duration: a change of value may start one.
has_transitions :: proc(c: ^Computed) -> bool {
	for i in 0 ..< len(c.transition_property) {
		if c.transition_property[i].kind == .None { continue }
		if max(list_at(c.transition_duration, i, 0), 0) + list_at(c.transition_delay, i, 0) > 0 { return true }
	}
	return false
}

has_animations :: proc(c: ^Computed) -> bool {
	for n in c.animation_name { if n != "" { return true } }
	return false
}
