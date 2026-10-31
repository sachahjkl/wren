package webaudio

// AudioParam: an intrinsic value and a timeline of automation events (Web Audio API, "AudioParam"), read once per frame
// (a-rate) or once per quantum (k-rate). Events are kept sorted; an event whose time has come leaves the list and
// becomes the state (Timeline): what holds now, and where the next ramp starts from.

import "core:math"

Event_Kind :: enum u8 { Set_Value, Linear_Ramp, Exponential_Ramp, Set_Target, Set_Curve }

Param_Event :: struct {
	kind:     Event_Kind,
	time:     f64,
	value:    f32,
	constant: f64,      // Set_Target: the time constant
	duration: f64,      // Set_Curve: the whole curve's duration
	stop:     f64,      // Set_Curve: where it ends (before time + duration after cancelAndHoldAtTime)
	curve:    []f32,    // Set_Curve: owned by the event
}

// What the last event that fired left behind.
Timeline :: struct {
	anchored: bool,        // an event has fired
	time:     f64,         // where the next ramp starts
	value:    f32,         // from this value
	cur:      Param_Event, // the event that fired: Set_Target and Set_Curve are still at work (its curve is owned here)
}

Param :: struct {
	value:     f32,        // what `.value` reads: the last computed value
	default_value, min_value, max_value: f32,
	a_rate:    bool,
	fixed_rate: bool,      // automationRate cannot change (Web Audio API, per node)
	events:    [dynamic]Param_Event,
	tl:        Timeline,
	inputs:    [dynamic]Conn,
	mix:       Bus,        // the connections, mixed to mono
	values:    [RENDER_QUANTUM]f32,
	varying:   bool,       // values differ within the quantum (otherwise values[0] holds for all, and only it is written)
}

param_init :: proc(p: ^Param, default_value, min_value, max_value: f32, a_rate: bool, fixed_rate := false) {
	p.value, p.default_value, p.min_value, p.max_value = default_value, default_value, min_value, max_value
	p.a_rate, p.fixed_rate = a_rate, fixed_rate
}

param_destroy :: proc(p: ^Param) {
	for e in p.events { delete(e.curve) }
	delete(p.events)
	delete(p.tl.cur.curve)
	delete(p.inputs)
	bus_destroy(&p.mix)
}

@(private = "file")
is_ramp :: #force_inline proc "contextless" (k: Event_Kind) -> bool { return k == .Linear_Ramp || k == .Exponential_Ramp }

// The value at time `t` with `next` the first event yet to fire.
@(private = "file")
timeline_eval :: proc(tl: ^Timeline, intrinsic: f32, next: ^Param_Event, t: f64) -> f32 {
	if tl.anchored && tl.cur.kind == .Set_Curve && t < tl.cur.stop {
		c := tl.cur.curve
		n := len(c)
		if n == 1 { return c[0] }
		pos := (t - tl.cur.time) / tl.cur.duration * f64(n - 1)
		k := int(pos)
		if k >= n - 1 { return c[n - 1] }
		frac := f32(pos - f64(k))
		return c[k] + (c[k + 1] - c[k]) * frac
	}
	if next != nil && is_ramp(next.kind) {
		t0, v0 := tl.anchored ? tl.time : t, tl.anchored ? tl.value : intrinsic
		span := next.time - t0
		if span <= 0 || t >= next.time { return next.value }
		x := (t - t0) / span
		if next.kind == .Linear_Ramp { return v0 + f32(f64(next.value - v0) * x) }
		if v0 == 0 || (v0 > 0) != (next.value > 0) { return v0 }   // (nothing to ramp from)
		return f32(f64(v0) * math.pow(f64(next.value) / f64(v0), x))
	}
	if !tl.anchored { return intrinsic }
	if tl.cur.kind == .Set_Target {
		if tl.cur.constant <= 0 { return tl.cur.value }
		return tl.cur.value + f32(f64(tl.value - tl.cur.value) * math.exp(-(t - tl.cur.time) / tl.cur.constant))
	}
	return tl.value
}

// `e` fires. Takes its curve. `live`: the timeline owns the curves (false: a copy that only looks, cancelAndHoldAtTime).
@(private = "file")
timeline_fire :: proc(tl: ^Timeline, intrinsic: f32, e: Param_Event, live: bool) {
	start := e.value
	switch e.kind {
	case .Set_Value, .Linear_Ramp, .Exponential_Ramp:
	case .Set_Target:
		ev := e
		start = timeline_eval(tl, intrinsic, &ev, e.time)
	case .Set_Curve:
		start = len(e.curve) > 0 ? e.curve[len(e.curve) - 1] : e.value
	}
	if live { delete(tl.cur.curve) }
	tl.anchored, tl.cur, tl.value = true, e, start
	tl.time = e.kind == .Set_Curve ? e.stop : e.time
}

// The values of this quantum, from frame `frame` on (the events that come due fire). Without its connections.
param_advance :: proc(p: ^Param, frame: i64, rate: f64) {
	if len(p.events) == 0 && (!p.tl.anchored || (p.tl.cur.kind != .Set_Target && !(p.tl.cur.kind == .Set_Curve && f64(frame) / rate < p.tl.cur.stop))) {
		// nothing at work: the value holds
		if p.tl.anchored && p.tl.value != p.value && p.tl.cur.kind != .Set_Target { p.value = p.tl.value }
		p.values[0] = p.value
		p.varying = false
		return
	}
	count := p.a_rate ? RENDER_QUANTUM : 1
	for i in 0 ..< count {
		t := f64(frame + i64(i)) / rate
		for len(p.events) > 0 && p.events[0].time <= t {
			e := p.events[0]
			ordered_remove(&p.events, 0)
			timeline_fire(&p.tl, p.value, e, true)
		}
		p.values[i] = timeline_eval(&p.tl, p.value, len(p.events) > 0 ? &p.events[0] : nil, t)
	}
	p.value = clamp(p.values[count - 1], p.min_value, p.max_value)
	p.varying = p.a_rate
}

// The computed values: the timeline's, plus what is connected to the param (mixed to mono), in the nominal range.
param_finish :: proc(p: ^Param) {
	has_input := !p.mix.silent && len(p.inputs) > 0 && p.mix.channels > 0
	// a NaN that came in becomes the default value (Web Audio API, "Computation of Value")
	checked :: #force_inline proc "contextless" (p: ^Param, v: f32) -> f32 {
		return v != v ? p.default_value : clamp(v, p.min_value, p.max_value)
	}
	if !p.varying && !has_input {
		p.values[0] = checked(p, p.values[0])
		return
	}
	if !p.varying {
		v := p.values[0]
		for i in 1 ..< RENDER_QUANTUM { p.values[i] = v }
	}
	if has_input {
		in_mix := bus_ch(&p.mix, 0)
		if p.a_rate {
			for i in 0 ..< RENDER_QUANTUM { p.values[i] += in_mix[i] }
		} else {
			p.values[0] += in_mix[0]
			for i in 1 ..< RENDER_QUANTUM { p.values[i] = p.values[0] }
		}
	}
	for i in 0 ..< RENDER_QUANTUM { p.values[i] = checked(p, p.values[i]) }
	p.varying = p.a_rate
}

// The computed value at a frame of the quantum.
param_at :: #force_inline proc "contextless" (p: ^Param, i: int) -> f32 { return p.varying ? p.values[i] : p.values[0] }

@(private = "file")
curve_covers :: proc(e: ^Param_Event, t: f64) -> bool {
	return e.kind == .Set_Curve && t >= e.time && t < e.stop
}

// Adds an event, after those of the same time. false: it overlaps a value curve (NotSupportedError).
param_insert :: proc(p: ^Param, event: Param_Event) -> bool {
	e := event
	if p.tl.anchored && curve_covers(&p.tl.cur, e.time) { return false }
	for &o in p.events {
		if curve_covers(&o, e.time) { return false }
		// (an event of the same time as a new curve comes before it: that one is allowed)
		if e.kind == .Set_Curve && o.time > e.time && o.time < e.stop { return false }
	}
	at := len(p.events)
	for o, i in p.events { if o.time > e.time { at = i; break } }
	inject_at(&p.events, at, e)
	return true
}

// A ramp with no event before it starts from the value now (the specification: as if setValueAtTime were called).
param_ramp :: proc(p: ^Param, kind: Event_Kind, value: f32, end, now: f64) -> bool {
	before := p.tl.anchored
	for o in p.events { if o.time <= end { before = true; break } }
	if !before {
		if !param_insert(p, Param_Event{kind = .Set_Value, time = now, value = p.value}) { return false }
	}
	return param_insert(p, Param_Event{kind = kind, time = end, value = value})
}

// `.value = v`: the intrinsic value at once, and an event at the current time.
param_set_now :: proc(p: ^Param, value: f32, now: f64) -> bool {
	v := clamp(value, p.min_value, p.max_value)
	if !param_insert(p, Param_Event{kind = .Set_Value, time = now, value = v}) { return false }
	p.value = v
	return true
}

// Drops the events at or after `t`; a curve that reaches past it goes whole.
param_cancel :: proc(p: ^Param, t: f64) {
	w := 0
	for e in p.events {
		if e.time >= t || (e.kind == .Set_Curve && e.time + e.duration > t) {
			delete(e.curve)
		} else {
			p.events[w] = e
			w += 1
		}
	}
	resize(&p.events, w)
	if p.tl.anchored && p.tl.cur.kind == .Set_Curve && p.tl.cur.stop > t {
		delete(p.tl.cur.curve)
		p.tl.cur = Param_Event{kind = .Set_Value, time = p.tl.time, value = p.value}
		p.tl.value = p.value
	}
}

// The value the timeline will have at `t`, from the state now (fires nothing).
param_value_at :: proc(p: ^Param, t: f64) -> f32 {
	tl := p.tl
	for i in 0 ..< len(p.events) {
		if p.events[i].time > t { return timeline_eval(&tl, p.value, &p.events[i], t) }
		timeline_fire(&tl, p.value, p.events[i], false)
	}
	return timeline_eval(&tl, p.value, nil, t)
}

// cancelAndHoldAtTime: what is scheduled after `t` goes, a ramp or a curve at work stops where it is at `t`, and that value
// holds. A curve or a setTarget that starts at `t` goes whole: nothing of it happened.
param_cancel_and_hold :: proc(p: ^Param, t: f64) {
	next := len(p.events)
	for e, i in p.events { if e.time > t { next = i; break } }
	drop_from :: proc(p: ^Param, at: int) {
		for e in p.events[at:] { delete(e.curve) }
		resize(&p.events, at)
	}
	if next > 0 {
		e := &p.events[next - 1]
		if e.kind == .Set_Target || e.kind == .Set_Curve {
			if e.time >= t { drop_from(p, next - 1); return }
			if e.kind == .Set_Curve && t > e.stop { drop_from(p, next); return }
		}
	}
	hold := param_value_at(p, t)
	ramp_kind := Event_Kind.Set_Value
	if next < len(p.events) && is_ramp(p.events[next].kind) { ramp_kind = p.events[next].kind }
	drop_from(p, next)
	if next > 0 {
		e := &p.events[next - 1]
		if e.kind == .Set_Curve && e.stop > t { e.stop = t }
	} else if p.tl.anchored && p.tl.cur.kind == .Set_Curve && p.tl.cur.stop > t {
		p.tl.cur.stop = t
		p.tl.time, p.tl.value = t, hold
	}
	// (a ramp keeps its line or curve with an end nearer; anything else: the value from there on)
	param_insert(p, Param_Event{kind = ramp_kind, time = t, value = hold})
}
