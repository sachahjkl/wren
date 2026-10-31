package webaudio

// Nodes: what each kind holds, how it is made, and the sources and simple processors. The larger ones are in
// nodes_effects.odin (panners, compressor, wave shaper, analyser, convolver, script processor, media element source).

import "core:math"
import "core:sync"

// A nominal range without a limit, and the detune range (1200 * log2 of the largest float).
PARAM_MAX :: f32(math.F32_MAX)
DETUNE_MAX :: f32(153600)
// Largest gain in dB of a BiquadFilterNode (40 * log10 of the largest float).
BIQUAD_GAIN_MAX :: f32(1541.273681640625)

Node_Data :: union {
	^Source_Data, ^Osc_Data, ^Biquad_Data, ^Delay_Data, ^Panner_Data, ^Compressor_Data, ^Shaper_Data, ^Analyser_Data,
	^Convolver_Data, ^Script_Data, ^Element_Data, ^IIR_Data,
}

// Audio of a buffer, shared between the page's objects and the graphs that play it: it never changes once made.
Pcm :: struct {
	refs:     i32,
	rate:     f64,
	length:   int,
	samples:  []f32,      // channels * length, planar
	channels: int,
}

pcm_new :: proc(channels, length: int, rate: f64) -> ^Pcm {
	context.allocator = alloc()
	p := new(Pcm)
	p.refs, p.rate, p.length, p.channels = 1, rate, length, channels
	p.samples = make([]f32, channels * length)
	return p
}

pcm_retain :: proc(p: ^Pcm) -> ^Pcm {
	if p != nil { sync.atomic_add(&p.refs, 1) }
	return p
}

pcm_release :: proc(p: ^Pcm) {
	if p == nil || sync.atomic_sub(&p.refs, 1) != 1 { return }
	context.allocator = alloc()
	delete(p.samples)
	free(p)
}

pcm_channel :: #force_inline proc "contextless" (p: ^Pcm, c: int) -> []f32 { return p.samples[c * p.length:][:p.length] }

Source_Data :: struct {
	pcm:        ^Pcm,
	loop:       bool,
	loop_start, loop_end: f64,   // seconds
	offset:     f64,             // seconds, as start() gave it
	duration:   f64,             // seconds of buffer; < 0: no limit
	pos:        f64,             // the playhead, in frames of the buffer
	elapsed:    f64,             // frames of the buffer gone through
	playing:    bool,
	in_loop:    bool,
}

Osc_Data :: struct {
	type:  Oscillator_Type,
	wave:  ^Wave,                // Custom
	phase: f64,                  // in periods
	playing: bool,
}

Biquad_Data :: struct {
	type:  Biquad_Type,
	state: [dynamic][4]f64,      // per channel: x[n-1], x[n-2], y[n-1], y[n-2]
	coefs: Biquad_Coefs,
	last:  [4]f32,               // the parameters coefs were made from
	known: bool,
}

Delay_Data :: struct {
	ring:   []f32,               // channels * capacity, planar
	capacity: int,
	channels: int,
	pos:    int,                 // where the next quantum is written (a multiple of a quantum)
	max_delay: f64,
	history: []u8,               // channels that came in, quantum by quantum of the ring; 0: silence
}

node_init :: proc(g: ^Graph, kind: Kind, a, b: f64) -> ^Node {
	inputs, outputs := 1, 1
	#partial switch kind {
	case .Buffer_Source, .Oscillator, .Constant, .Element_Source: inputs = 0
	case .Splitter: outputs = int(a)
	case .Merger: inputs = int(a)
	}
	n := add_node(g, kind, inputs, outputs)
	nyquist := f32(g.rate / 2)
	#partial switch kind {
	case .Buffer_Source:
		d := new(Source_Data)
		d.duration = -1
		n.data = d
		n.params = make([]Param, 2)
		param_init(&n.params[0], 1, -PARAM_MAX, PARAM_MAX, false, true)    // playbackRate
		param_init(&n.params[1], 0, -PARAM_MAX, PARAM_MAX, false, true)    // detune
	case .Oscillator:
		n.data = new(Osc_Data)
		n.params = make([]Param, 2)
		param_init(&n.params[0], 440, -nyquist, nyquist, true)             // frequency
		param_init(&n.params[1], 0, -DETUNE_MAX, DETUNE_MAX, true)         // detune
	case .Gain:
		n.params = make([]Param, 1)
		param_init(&n.params[0], 1, -PARAM_MAX, PARAM_MAX, true)
	case .Constant:
		n.params = make([]Param, 1)
		param_init(&n.params[0], 1, -PARAM_MAX, PARAM_MAX, true)
	case .Biquad:
		n.data = new(Biquad_Data)
		n.params = make([]Param, 4)
		param_init(&n.params[0], 350, 0, nyquist, true)                    // frequency
		param_init(&n.params[1], 0, -DETUNE_MAX, DETUNE_MAX, true)         // detune
		param_init(&n.params[2], 1, -PARAM_MAX, PARAM_MAX, true)           // Q
		param_init(&n.params[3], 0, -PARAM_MAX, BIQUAD_GAIN_MAX, true)     // gain
	case .Delay:
		d := new(Delay_Data)
		d.max_delay = a
		// (a quantum more: a cycle reads before it writes; whole quanta: the history is by quantum)
		frames := int(math.ceil(a * g.rate)) + 2 * RENDER_QUANTUM + 1
		d.capacity = (frames + RENDER_QUANTUM - 1) / RENDER_QUANTUM * RENDER_QUANTUM
		d.channels = 1
		d.ring = make([]f32, d.capacity)
		d.history = make([]u8, d.capacity / RENDER_QUANTUM)
		n.data = d
		n.params = make([]Param, 1)
		param_init(&n.params[0], 0, 0, f32(a), true)
	case .Stereo_Panner:
		n.mode = .Clamped_Max
		n.params = make([]Param, 1)
		param_init(&n.params[0], 0, -1, 1, true)
	case .Panner:
		n.mode = .Clamped_Max
		panner_init(n)
	case .Splitter:
		n.channel_count, n.mode, n.interp = int(a), .Explicit, .Discrete
	case .Merger:
		n.channel_count, n.mode = 1, .Explicit
	case .Compressor:
		n.mode = .Clamped_Max
		compressor_init(n)
	case .Wave_Shaper:
		n.data = new(Shaper_Data)
	case .Analyser:
		n.data = analyser_new()
	case .Convolver:
		n.mode = .Clamped_Max
		n.data = new(Convolver_Data)
	case .Script_Processor:
		n.mode = .Explicit
		n.channel_count = max(int(b) >> 8, 1)
		n.data = script_new(int(a), int(b) >> 8, int(b) & 0xFF)
	case .Element_Source:
		n.data = element_new(g)
	case .IIR:
		n.data = new(IIR_Data)
	}
	return n
}

// The listener has no audio, only its params (a PannerNode reads them).
params_listener :: proc(n: ^Node) {
	n.params = make([]Param, 9)
	defaults := [9]f32{0, 0, 0, 0, 0, -1, 0, 1, 0}
	for &p, i in n.params { param_init(&p, defaults[i], -PARAM_MAX, PARAM_MAX, true) }
}

node_data_destroy :: proc(n: ^Node) {
	switch d in n.data {
	case ^Source_Data: pcm_release(d.pcm); free(d)
	case ^Osc_Data: wave_release(d.wave); free(d)
	case ^Biquad_Data: delete(d.state); free(d)
	case ^Delay_Data: delete(d.ring); delete(d.history); free(d)
	case ^Panner_Data: free(d)
	case ^Compressor_Data: compressor_destroy(d)
	case ^Shaper_Data: delete(d.curve); free(d)
	case ^Analyser_Data: analyser_destroy(d)
	case ^Convolver_Data: convolver_destroy(d)
	case ^Script_Data: script_destroy(d)
	case ^Element_Data: element_destroy(d)
	case ^IIR_Data: iir_destroy(d)
	}
}

// A scheduled source that started and has not finished.
node_source_alive :: proc(n: ^Node) -> bool {
	#partial switch n.kind {
	case .Buffer_Source, .Oscillator, .Constant: return n.sched.started && !n.sched.finished
	}
	return false
}

// The field setters. The rules on values are the page's (web_audio.js), except what could break the thread.
node_set :: proc(g: ^Graph, id: i32, field: Field, value: f64) {
	context.allocator = alloc()
	sync.guard(&g.mu)
	n := node_of(g, id)
	if n == nil { return }
	switch field {
	case .Channel_Count: n.channel_count = clamp(int(value), 1, MAX_CHANNELS)
	case .Channel_Mode:  n.mode = Channel_Mode(clamp(i32(value), 0, 2))
	case .Channel_Interp: n.interp = Channel_Interp(clamp(i32(value), 0, 1))
	case .Loop:       if d, ok := n.data.(^Source_Data); ok { d.loop = value != 0 }
	case .Loop_Start: if d, ok := n.data.(^Source_Data); ok { d.loop_start = value }
	case .Loop_End:   if d, ok := n.data.(^Source_Data); ok { d.loop_end = value }
	case .Oscillator_Type:
		if d, ok := n.data.(^Osc_Data); ok { d.type = Oscillator_Type(clamp(i32(value), 0, i32(Oscillator_Type.Custom))) }
	case .Filter_Type:
		if d, ok := n.data.(^Biquad_Data); ok {
			d.type = Biquad_Type(clamp(i32(value), 0, i32(Biquad_Type.Allpass)))
			d.known = false
		}
	case .Oversample: if d, ok := n.data.(^Shaper_Data); ok { d.oversample = int(value) }
	case .Fft_Size:     if d, ok := n.data.(^Analyser_Data); ok { d.fft_size = clamp(int(value), ANALYSER_MIN_FFT, ANALYSER_MAX_FFT); d.smoothed_for = -1 }
	case .Min_Decibels: if d, ok := n.data.(^Analyser_Data); ok { d.min_db = value }
	case .Max_Decibels: if d, ok := n.data.(^Analyser_Data); ok { d.max_db = value }
	case .Smoothing:    if d, ok := n.data.(^Analyser_Data); ok { d.smoothing = value }
	case .Normalize:    if d, ok := n.data.(^Convolver_Data); ok { d.normalize = value != 0 }
	case .Panning_Model, .Distance_Model, .Ref_Distance, .Max_Distance, .Rolloff, .Cone_Inner, .Cone_Outer, .Cone_Outer_Gain:
		if d, ok := n.data.(^Panner_Data); ok { panner_set(d, field, value) }
	case .Reduction:
	}
}

node_get :: proc(g: ^Graph, id: i32, field: Field) -> f64 {
	sync.guard(&g.mu)
	n := node_of(g, id)
	if n == nil { return 0 }
	#partial switch field {
	case .Reduction: if d, ok := n.data.(^Compressor_Data); ok { return f64(d.reduction) }
	}
	return 0
}

// start(): `when` in seconds; offset and duration for an AudioBufferSourceNode (a negative duration: none).
node_start :: proc(g: ^Graph, id: i32, at, offset, duration: f64) {
	sync.guard(&g.mu)
	n := node_of(g, id)
	if n == nil { return }
	n.sched.start, n.sched.started = max(at, f64(g.frame) / g.rate), true
	if d, ok := n.data.(^Source_Data); ok { d.offset, d.duration = offset, duration }
}

node_stop :: proc(g: ^Graph, id: i32, at: f64) {
	sync.guard(&g.mu)
	n := node_of(g, id)
	if n == nil { return }
	n.sched.stop, n.sched.stop_set = max(at, f64(g.frame) / g.rate), true
}

node_set_buffer :: proc(g: ^Graph, id: i32, pcm: ^Pcm) {
	sync.guard(&g.mu)
	n := node_of(g, id)
	if n == nil { return }
	if d, ok := n.data.(^Source_Data); ok {
		if n.sched.finished { return }
		pcm_release(d.pcm)
		d.pcm = pcm_retain(pcm)
	}
}

node_set_wave :: proc(g: ^Graph, id: i32, w: ^Wave) {
	sync.guard(&g.mu)
	n := node_of(g, id)
	if n == nil { wave_release(w); return }
	if d, ok := n.data.(^Osc_Data); ok {
		wave_release(d.wave)
		d.wave, d.type = w, .Custom
	} else {
		wave_release(w)
	}
}

// The params: by node and index, the lock taken here.
param_of :: proc(g: ^Graph, id: i32, index: int) -> ^Param {
	n := node_of(g, id)
	if n == nil || index < 0 || index >= len(n.params) { return nil }
	return &n.params[index]
}

param_get :: proc(g: ^Graph, id: i32, index: int) -> f64 {
	sync.guard(&g.mu)
	p := param_of(g, id, index)
	return p != nil ? f64(p.value) : 0
}

param_set_value :: proc(g: ^Graph, id: i32, index: int, value: f32) -> bool {
	context.allocator = alloc()
	sync.guard(&g.mu)
	p := param_of(g, id, index)
	return p == nil || param_set_now(p, value, f64(g.frame) / g.rate)
}

param_set_rate :: proc(g: ^Graph, id: i32, index: int, a_rate: bool) {
	sync.guard(&g.mu)
	if p := param_of(g, id, index); p != nil { p.a_rate = a_rate }
}

// An automation event from the page. `time` already not before now.
param_add_event :: proc(g: ^Graph, id: i32, index: int, kind: Event_Kind, time: f64, value: f32, extra: f64, curve: []f32) -> bool {
	context.allocator = alloc()
	sync.guard(&g.mu)
	p := param_of(g, id, index)
	if p == nil { return true }
	now := f64(g.frame) / g.rate
	switch kind {
	case .Set_Value, .Set_Target:
		return param_insert(p, Param_Event{kind = kind, time = time, value = value, constant = extra})
	case .Linear_Ramp, .Exponential_Ramp:
		return param_ramp(p, kind, value, time, now)
	case .Set_Curve:
		e := Param_Event{kind = kind, time = time, duration = extra, stop = time + extra, value = len(curve) > 0 ? curve[0] : 0}
		e.curve = make([]f32, len(curve))
		copy(e.curve, curve)
		if !param_insert(p, e) { delete(e.curve); return false }
		return true
	}
	return true
}

param_cancel_events :: proc(g: ^Graph, id: i32, index: int, time: f64, hold: bool) {
	context.allocator = alloc()
	sync.guard(&g.mu)
	p := param_of(g, id, index)
	if p == nil { return }
	if hold { param_cancel_and_hold(p, time) } else { param_cancel(p, time) }
}

// What a node computes in a quantum: its inputs are mixed, its params computed.
node_run :: proc(g: ^Graph, n: ^Node) {
	switch n.kind {
	case .Destination, .Listener:
	case .Buffer_Source: source_run(g, n)
	case .Oscillator:    oscillator_run(g, n)
	case .Gain:          gain_run(n)
	case .Constant:      constant_run(g, n)
	case .Biquad:        biquad_run(g, n)
	case .Delay:         delay_run(g, n)
	case .Stereo_Panner: stereo_panner_run(n)
	case .Panner:        panner_run(g, n)
	case .Splitter:      splitter_run(n)
	case .Merger:        merger_run(n)
	case .Compressor:    compressor_run(g, n)
	case .Wave_Shaper:   shaper_run(n)
	case .Analyser:      analyser_run(g, n)
	case .Convolver:     convolver_run(n)
	case .Script_Processor: script_run(g, n)
	case .Element_Source:   element_run(n)
	case .IIR:           iir_run(n)
	}
}

// ---- scheduled sources ----

@(private = "file")
finish :: proc(g: ^Graph, n: ^Node) {
	n.sched.finished = true
	g.sweep_due = true
	if !n.sched.ended_sent {
		n.sched.ended_sent = true
		post_event(g, .Ended, n.id, 0)
	}
}

// Where the node sounds in this quantum: [from, to) frames. A stop inside it sets the end; finished once it is reached.
@(private = "file")
scheduled_range :: proc(g: ^Graph, n: ^Node) -> (from, to: int) {
	s := &n.sched
	if !s.started || s.finished { return 0, 0 }
	rate := g.rate
	first := f64(g.frame)
	// (a huge time stays in the range before it becomes an integer; a time a rounding error past a frame counts as that frame)
	at_frame :: proc(x: f64) -> int { return int(clamp(math.ceil(x - SCHEDULE_ROUNDING), 0, RENDER_QUANTUM)) }
	from = at_frame(s.start * rate - first)
	to = RENDER_QUANTUM
	if s.stop_set { to = at_frame(s.stop * rate - first) }
	return from, max(from, to)
}

// In frames: what a start or stop time may be past a frame through rounding only.
SCHEDULE_ROUNDING :: 1e-7

@(private = "file")
past_stop :: proc(g: ^Graph, n: ^Node) -> bool {
	s := &n.sched
	return s.started && !s.finished && s.stop_set && s.stop * g.rate <= f64(g.frame) + RENDER_QUANTUM
}

source_run :: proc(g: ^Graph, n: ^Node) {
	d := n.data.(^Source_Data)
	o := &n.outputs[0]
	from, to := scheduled_range(g, n)
	if d.pcm == nil || from >= to || d.pcm.length == 0 {
		// (one channel of silence when it does not sound, whatever its buffer; started with no buffer: over at once)
		bus_clear(o, 1)
		if past_stop(g, n) || (d.pcm == nil && n.sched.started && !n.sched.finished) { finish(g, n) }
		return
	}
	pcm := d.pcm
	bus_clear(o, pcm.channels)
	o.silent = false
	// k-rate: both params hold for the quantum
	computed := f64(param_at(&n.params[0], 0)) * math.pow(2, f64(param_at(&n.params[1], 0)) / 1200) * pcm.rate / g.rate
	if !(abs(computed) < 1e30) { computed = 0 }
	length := f64(pcm.length)
	loop_start, loop_end := 0.0, length
	if d.loop && d.loop_end > d.loop_start && d.loop_end > 0 {
		loop_start = clamp(d.loop_start * pcm.rate, 0, length)
		loop_end = min(d.loop_end * pcm.rate, length)
	}
	if !d.playing {
		start_at := min(d.offset * pcm.rate, length)
		if d.loop && computed >= 0 && start_at >= loop_end { start_at = loop_end }
		if d.loop && computed < 0 && start_at < loop_start { start_at = loop_start }
		// a start between two frames: the playhead has already moved on by the first frame (sub-sample accuracy)
		first := max(f64(g.frame + i64(from)) - n.sched.start * g.rate, 0)
		d.pos = start_at + first * computed
		d.elapsed = first * abs(computed)
		d.playing = true
	}
	limit := d.duration >= 0 ? d.duration * pcm.rate : max(f64)
	ended := false
	for i in from ..< to {
		if d.loop {
			if !d.in_loop {
				if d.offset * pcm.rate < loop_end && d.pos >= loop_start { d.in_loop = true }
				if d.offset * pcm.rate >= loop_end && d.pos < loop_end { d.in_loop = true }
			}
			if d.in_loop {
				span := loop_end - loop_start
				if span > 0 {
					for d.pos >= loop_end { d.pos -= span }
					for d.pos < loop_start { d.pos += span }
				}
			}
		}
		if d.pos >= 0 && d.pos < length {
			k := int(d.pos)
			frac := f32(d.pos - f64(k))
			for c in 0 ..< pcm.channels {
				src := pcm_channel(pcm, c)
				s0 := src[k]
				if frac != 0 {
					s1: f32
					if k + 1 < pcm.length && f64(k + 1) < loop_end {
						s1 = src[k + 1]
					} else if d.loop {
						s1 = src[int(loop_start)]
					} else if k + 1 < pcm.length {
						s1 = src[k + 1]
					} else {
						// past the last frame: the line through the last two (buffers played end to end stay smooth)
						s1 = k > 0 ? 2 * s0 - src[k - 1] : s0
					}
					s0 += (s1 - s0) * frac
				}
				bus_ch(o, c)[i] = s0
			}
		}
		d.pos += computed
		d.elapsed += abs(computed)
		if d.elapsed >= limit || (!d.loop && (computed >= 0 ? d.pos >= length : d.pos < 0)) {
			ended = true
			break
		}
	}
	if ended || past_stop(g, n) { finish(g, n) }
}

oscillator_run :: proc(g: ^Graph, n: ^Node) {
	d := n.data.(^Osc_Data)
	o := &n.outputs[0]
	from, to := scheduled_range(g, n)
	if from >= to {
		bus_clear(o, 1)
		if past_stop(g, n) { finish(g, n) }
		return
	}
	bus_clear(o, 1)
	o.silent = false
	out := bus_ch(o, 0)
	freq, det := &n.params[0], &n.params[1]
	rate := g.rate
	if !d.playing {
		d.playing = true
		// a start between two frames: the phase has moved on by the first frame
		first := max(f64(g.frame + i64(from)) / rate - n.sched.start, 0)
		d.phase = first * f64(param_at(freq, from)) * math.pow(2, f64(param_at(det, from)) / 1200)
	}
	wave: ^Wave
	if d.type == .Custom {
		wave = d.wave
	} else if d.type != .Sine {
		if g.basic[d.type] == nil { g.basic[d.type] = wave_basic(d.type) }
		wave = g.basic[d.type]
	}
	constant := !freq.varying && !det.varying
	f := f64(param_at(freq, from)) * math.pow(2, f64(param_at(det, from)) / 1200)
	table: []f32
	if wave != nil { table = wave_table(wave, f, rate) }
	nyquist := rate / 2
	for i in from ..< to {
		if !constant {
			f = f64(param_at(freq, i)) * math.pow(2, f64(param_at(det, i)) / 1200)
			if wave != nil && i % OSC_TABLE_CHECK == 0 { table = wave_table(wave, f, rate) }
		}
		if abs(f) >= nyquist {
			// (at Nyquist or above: silence; the phase goes on)
			out[i] = 0
		} else if wave != nil {
			x := d.phase * WAVE_TABLE_SIZE
			k := int(x)
			frac := f32(x - f64(k))
			k &= WAVE_TABLE_SIZE - 1
			out[i] = table[k] + (table[(k + 1) & (WAVE_TABLE_SIZE - 1)] - table[k]) * frac
		} else {
			out[i] = f32(math.sin(2 * math.PI * d.phase))
		}
		d.phase += f / rate
		if abs(d.phase) < OSC_PHASE_LIMIT { d.phase -= math.floor(d.phase) } else { d.phase = 0 }
	}
	if past_stop(g, n) { finish(g, n) }
}

// How often (frames) a changing frequency looks for its table.
OSC_TABLE_CHECK :: 16
// A phase past this came from an absurd frequency (a detune out of all range): it starts again.
OSC_PHASE_LIMIT :: 1e15
// Below this a filter's memory is taken for 0.
BIQUAD_DENORMAL :: 1e-300

constant_run :: proc(g: ^Graph, n: ^Node) {
	o := &n.outputs[0]
	from, to := scheduled_range(g, n)
	bus_clear(o, 1)
	if from < to {
		o.silent = false
		out := bus_ch(o, 0)
		for i in from ..< to { out[i] = param_at(&n.params[0], i) }
	}
	if past_stop(g, n) { finish(g, n) }
}

// ---- simple processors ----

gain_run :: proc(n: ^Node) {
	in_mix := &n.inputs[0].mix
	o := &n.outputs[0]
	if in_mix.silent {
		bus_clear(o, in_mix.channels)
		return
	}
	bus_prepare(o, in_mix.channels)
	g := &n.params[0]
	for c in 0 ..< in_mix.channels {
		s, t := bus_ch(in_mix, c), bus_ch(o, c)
		if g.varying {
			for i in 0 ..< RENDER_QUANTUM { t[i] = s[i] * g.values[i] }
		} else {
			k := g.values[0]
			for i in 0 ..< RENDER_QUANTUM { t[i] = s[i] * k }
		}
	}
}

biquad_run :: proc(g: ^Graph, n: ^Node) {
	d := n.data.(^Biquad_Data)
	in_mix := &n.inputs[0].mix
	o := &n.outputs[0]
	channels := in_mix.channels
	for len(d.state) < channels { append(&d.state, [4]f64{}) }
	bus_prepare(o, channels)
	o.silent = false
	freq, det, q, gain := &n.params[0], &n.params[1], &n.params[2], &n.params[3]
	varying := freq.varying || det.varying || q.varying || gain.varying
	coefs_at :: proc(g: ^Graph, d: ^Biquad_Data, freq, det, q, gain: ^Param, i: int) -> Biquad_Coefs {
		f := f64(param_at(freq, i)) * math.pow(2, f64(param_at(det, i)) / 1200)
		return biquad_coefs(d.type, f, f64(param_at(q, i)), f64(param_at(gain, i)), g.rate)
	}
	if !varying {
		now := [4]f32{param_at(freq, 0), param_at(det, 0), param_at(q, 0), param_at(gain, 0)}
		if !d.known || now != d.last {
			d.coefs = coefs_at(g, d, freq, det, q, gain, 0)
			d.last, d.known = now, true
		}
	} else {
		d.known = false
	}
	for c in 0 ..< channels {
		s, t := bus_ch(in_mix, c), bus_ch(o, c)
		// direct form I, as the specification writes it: what its coefficients changing from frame to frame means
		x1, x2, y1, y2 := d.state[c][0], d.state[c][1], d.state[c][2], d.state[c][3]
		cf := d.coefs
		for i in 0 ..< RENDER_QUANTUM {
			if varying { cf = coefs_at(g, d, freq, det, q, gain, i) }
			x := f64(s[i])
			y := cf.b0 * x + cf.b1 * x1 + cf.b2 * x2 - cf.a1 * y1 - cf.a2 * y2
			x2, x1, y2, y1 = x1, x, y1, y
			t[i] = f32(y)
		}
		// a tail that has died away leaves no denormals behind
		if abs(y1) < BIQUAD_DENORMAL { y1 = 0 }
		if abs(y2) < BIQUAD_DENORMAL { y2 = 0 }
		d.state[c] = {x1, x2, y1, y2}
	}
}

// getFrequencyResponse with the params as they are now.
biquad_frequency_response :: proc(g: ^Graph, id: i32, frequencies: []f32, mag, phase: []f32) {
	sync.guard(&g.mu)
	n := node_of(g, id)
	if n == nil { return }
	d, ok := n.data.(^Biquad_Data)
	if !ok { return }
	nyquist := g.rate / 2
	f := f64(n.params[0].value) * math.pow(2, f64(n.params[1].value) / 1200)
	c := biquad_coefs(d.type, f, f64(n.params[2].value), f64(n.params[3].value), g.rate)
	for hz, i in frequencies {
		if hz < 0 || f64(hz) > nyquist || math.is_nan(hz) {
			mag[i], phase[i] = math.nan_f32(), math.nan_f32()
			continue
		}
		m, ph := biquad_response(c, f64(hz) / nyquist)
		mag[i], phase[i] = f32(m), f32(ph)
	}
}

@(private = "file")
delay_grow :: proc(d: ^Delay_Data, channels: int) {
	if channels <= d.channels { return }
	ring := make([]f32, channels * d.capacity)
	copy(ring, d.ring)
	delete(d.ring)
	d.ring, d.channels = ring, channels
}

// Writes the input of this quantum at the head of the ring.
delay_store :: proc(n: ^Node) {
	d := n.data.(^Delay_Data)
	in_mix := &n.inputs[0].mix
	delay_grow(d, in_mix.channels)
	d.history[d.pos / RENDER_QUANTUM] = in_mix.silent ? 0 : u8(in_mix.channels)
	for c in 0 ..< d.channels {
		ring := d.ring[c * d.capacity:][:d.capacity]
		if c < in_mix.channels {
			s := bus_ch(in_mix, c)
			for i in 0 ..< RENDER_QUANTUM { ring[(d.pos + i) % d.capacity] = s[i] }
		} else {
			for i in 0 ..< RENDER_QUANTUM { ring[(d.pos + i) % d.capacity] = 0 }
		}
	}
	d.pos = (d.pos + RENDER_QUANTUM) % d.capacity
}

delay_run :: proc(g: ^Graph, n: ^Node) {
	d := n.data.(^Delay_Data)
	in_mix := &n.inputs[0].mix
	base := d.pos
	if !n.in_cycle {
		delay_store(n)
		if !in_mix.silent { n.active_until = g.frame + i64(d.capacity) }
	} else if in_mix.channels > 0 && !in_mix.silent {
		n.active_until = g.frame + i64(d.capacity)
	}
	o := &n.outputs[0]
	delay_time := &n.params[0]
	cycle_min := n.in_cycle ? f64(RENDER_QUANTUM) : 0
	capacity := f64(d.capacity)
	position :: proc(d: ^Delay_Data, delay_time: ^Param, base, i: int, rate, cycle_min, capacity: f64) -> f64 {
		back := max(f64(param_at(delay_time, i)) * rate, cycle_min)
		back = min(back, capacity - RENDER_QUANTUM - 1)
		at := f64(base + i) - back
		return at < 0 ? at + capacity : at
	}
	// its output has the channels of what comes out now: mono silence until the signal gets there, and after it has gone
	channels := 1
	any := false
	for i in 0 ..< RENDER_QUANTUM {
		if i > 0 && i < RENDER_QUANTUM - 1 && !delay_time.varying { continue }
		q := int(position(d, delay_time, base, i, g.rate, cycle_min, capacity)) / RENDER_QUANTUM
		h := d.history[q % len(d.history)]
		if h > 0 {
			any = true
			channels = max(channels, int(h))
		}
	}
	if !any {
		bus_clear(o, 1)
		return
	}
	bus_prepare(o, channels)
	o.silent = false
	for c in 0 ..< channels {
		ring := d.ring[c * d.capacity:][:d.capacity]
		t := bus_ch(o, c)
		for i in 0 ..< RENDER_QUANTUM {
			at := position(d, delay_time, base, i, g.rate, cycle_min, capacity)
			k := int(at)
			frac := f32(at - f64(k))
			k %= d.capacity
			s0 := ring[k]
			if frac != 0 { s0 += (ring[(k + 1) % d.capacity] - s0) * frac }
			t[i] = s0
		}
	}
}

splitter_run :: proc(n: ^Node) {
	in_mix := &n.inputs[0].mix
	for &o, c in n.outputs {
		bus_prepare(&o, 1)
		if c < in_mix.channels {
			copy(o.data[:RENDER_QUANTUM], bus_ch(in_mix, c))
			o.silent = in_mix.silent
		} else {
			bus_clear(&o, 1)
		}
	}
}

merger_run :: proc(n: ^Node) {
	o := &n.outputs[0]
	bus_prepare(o, len(n.inputs))
	silent := true
	for &in_put, c in n.inputs {
		copy(bus_ch(o, c), bus_ch(&in_put.mix, 0))
		if !in_put.mix.silent { silent = false }
	}
	o.silent = silent
}

// Something other than the holder of this reference has it (a node that plays it).
pcm_shared :: proc(p: ^Pcm) -> bool { return sync.atomic_load(&p.refs) > 1 }
