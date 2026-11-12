package webaudio

// The larger nodes: panners, the compressor, the wave shaper, the analyser, the convolver, and the two that exchange audio
// with something outside the graph (a script processor, a media element).

import "base:intrinsics"
import "core:math"
import "core:sync"

// ---- StereoPannerNode ----

stereo_panner_run :: proc(n: ^Node) {
	in_mix := &n.inputs[0].mix
	o := &n.outputs[0]
	if in_mix.silent { bus_clear(o, 2); return }
	bus_prepare(o, 2)
	pan := &n.params[0]
	l, r := bus_ch(o, 0), bus_ch(o, 1)
	if in_mix.channels == 1 {
		s := bus_ch(in_mix, 0)
		for i in 0 ..< RENDER_QUANTUM {
			x := (f64(param_at(pan, i)) + 1) / 2
			l[i] = s[i] * f32(math.cos(x * math.PI / 2))
			r[i] = s[i] * f32(math.sin(x * math.PI / 2))
		}
	} else {
		sl, sr := bus_ch(in_mix, 0), bus_ch(in_mix, 1)
		for i in 0 ..< RENDER_QUANTUM {
			p := f64(param_at(pan, i))
			x := p <= 0 ? p + 1 : p
			gl, gr := f32(math.cos(x * math.PI / 2)), f32(math.sin(x * math.PI / 2))
			if p <= 0 {
				l[i] = sl[i] + sr[i] * gl
				r[i] = sr[i] * gr
			} else {
				l[i] = sl[i] * gl
				r[i] = sr[i] + sl[i] * gr
			}
		}
	}
}

// ---- PannerNode (equal-power; "HRTF" pans the same way) ----

Distance_Model :: enum i32 { Linear, Inverse, Exponential }

Panner_Data :: struct {
	model:      Distance_Model,
	ref, max_d, rolloff: f64,
	cone_inner, cone_outer, cone_gain: f64,
}

panner_init :: proc(n: ^Node) {
	d := new(Panner_Data)
	d.model, d.ref, d.max_d, d.rolloff = .Inverse, 1, 10000, 1
	d.cone_inner, d.cone_outer, d.cone_gain = 360, 360, 0
	n.data = d
	n.params = make([]Param, 6)
	defaults := [6]f32{0, 0, 0, 1, 0, 0}
	for &p, i in n.params { param_init(&p, defaults[i], -PARAM_MAX, PARAM_MAX, true) }
}

panner_set :: proc(d: ^Panner_Data, field: Field, v: f64) {
	#partial switch field {
	case .Distance_Model: d.model = Distance_Model(clamp(i32(v), 0, 2))
	case .Ref_Distance: d.ref = v
	case .Max_Distance: d.max_d = v
	case .Rolloff: d.rolloff = v
	case .Cone_Inner: d.cone_inner = v
	case .Cone_Outer: d.cone_outer = v
	case .Cone_Outer_Gain: d.cone_gain = v
	}
}

@(private = "file") Vec3 :: [3]f64

@(private = "file")
dot :: #force_inline proc "contextless" (a, b: Vec3) -> f64 { return a.x * b.x + a.y * b.y + a.z * b.z }

@(private = "file")
cross :: #force_inline proc "contextless" (a, b: Vec3) -> Vec3 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

@(private = "file")
vec_len :: #force_inline proc "contextless" (a: Vec3) -> f64 { return math.sqrt_f64(dot(a, a)) }

@(private = "file")
normalized :: proc(a: Vec3) -> Vec3 {
	l := vec_len(a)
	return l > 0 ? a / l : Vec3{}
}

@(private = "file")
panner_gains :: proc(d: ^Panner_Data, lst, n: ^Node, i: int, channels: int) -> (gl, gr, azimuth: f64, gain: f64) {
	v3 :: proc(n: ^Node, first, i: int) -> Vec3 {
		return {f64(param_at(&n.params[first], i)), f64(param_at(&n.params[first + 1], i)), f64(param_at(&n.params[first + 2], i))}
	}
	src, orient := v3(n, 0, i), v3(n, 3, i)
	pos, forward, up := v3(lst, 0, i), v3(lst, 3, i), v3(lst, 6, i)
	to_source := src - pos
	dist := vec_len(to_source)
	// azimuth (Web Audio API, "Azimuth and Elevation")
	if dist > 0 {
		sl := to_source / dist
		right := cross(forward, up)
		if vec_len(right) > 0 {
			right = normalized(right)
			front := normalized(forward)
			up2 := cross(right, front)
			projection := sl - up2 * dot(sl, up2)
			projection = normalized(projection)
			azimuth = math.to_degrees(math.acos(clamp(dot(projection, right), -1, 1)))
			if dot(projection, front) < 0 { azimuth = 360 - azimuth }
			azimuth = azimuth <= 270 ? 90 - azimuth : 450 - azimuth
		}
	}
	// equal-power
	az := clamp(azimuth, -180, 180)
	if az < -90 { az = -180 - az } else if az > 90 { az = 180 - az }
	x: f64
	if channels == 1 {
		x = (az + 90) / 180
	} else {
		x = az <= 0 ? (az + 90) / 90 : az / 90
	}
	azimuth = az
	gl, gr = math.cos(x * math.PI / 2), math.sin(x * math.PI / 2)
	// distance
	dg := 1.0
	switch d.model {
	case .Linear:
		ref, top := min(d.ref, d.max_d), max(d.ref, d.max_d)
		dc := clamp(dist, ref, top)
		dg = top == ref ? 1 - d.rolloff : 1 - clamp(d.rolloff, 0, 1) * (dc - ref) / (top - ref)
	case .Inverse:
		// (a reference distance of 0: everything is infinitely far)
		dg = d.ref > 0 ? d.ref / (d.ref + d.rolloff * (max(dist, d.ref) - d.ref)) : 0
	case .Exponential:
		dg = d.ref > 0 ? math.pow(max(dist, d.ref) / d.ref, -d.rolloff) : 0
	}
	// cone
	cg := 1.0
	if dot(orient, orient) > 0 && !(d.cone_inner == 360 && d.cone_outer == 360) && dist > 0 {
		cos_a := dot((pos - src) / dist, normalized(orient))
		angle := math.to_degrees(math.acos(clamp(cos_a, -1, 1)))
		inner, outer := abs(d.cone_inner) / 2, abs(d.cone_outer) / 2
		if angle <= inner {
			cg = 1
		} else if angle >= outer {
			cg = d.cone_gain
		} else {
			cg = 1 + (angle - inner) / (outer - inner) * (d.cone_gain - 1)
		}
	}
	return gl, gr, azimuth, dg * cg
}

panner_run :: proc(g: ^Graph, n: ^Node) {
	d := n.data.(^Panner_Data)
	lst := g.listener
	in_mix := &n.inputs[0].mix
	o := &n.outputs[0]
	if in_mix.silent { bus_clear(o, 2); return }
	bus_prepare(o, 2)
	varying := false
	for &p in n.params { varying = varying || p.varying }
	for &p in lst.params { varying = varying || p.varying }
	l, r := bus_ch(o, 0), bus_ch(o, 1)
	channels := in_mix.channels
	gl, gr, az, gain := panner_gains(d, lst, n, 0, channels)
	sl := bus_ch(in_mix, 0)
	sr := channels > 1 ? bus_ch(in_mix, 1) : sl
	for i in 0 ..< RENDER_QUANTUM {
		if varying { gl, gr, az, gain = panner_gains(d, lst, n, i, channels) }
		a, b := f64(sl[i]) * gain, f64(sr[i]) * gain
		switch {
		case channels == 1:
			l[i], r[i] = f32(a * gl), f32(a * gr)
		case az <= 0:
			l[i], r[i] = f32(a + b * gl), f32(b * gr)
		case:
			l[i], r[i] = f32(a * gl), f32(b + a * gr)
		}
	}
}

// ---- DynamicsCompressorNode: the knee and ratio of the specification, a look-ahead, an envelope with attack and release ----

COMPRESSOR_LOOKAHEAD_S :: 0.006
COMPRESSOR_MAKEUP_POWER :: 0.6
// The largest knee steepness looked at, the search's start and steps (bisection on the slope at the knee's end).
COMPRESSOR_K_MIN :: 0.1
COMPRESSOR_K_MAX :: 10000
COMPRESSOR_K_START :: 5
COMPRESSOR_K_STEPS :: 15
// A tiny step along the curve, to measure its slope; the attack below which it is instantaneous.
COMPRESSOR_SLOPE_STEP :: 1.001
COMPRESSOR_MIN_TIME_S :: 0.0001

Compressor_Data :: struct {
	ring:     []f32,        // the look-ahead, channels * frames
	frames:   int,
	channels: int,
	pos:      int,
	env:      f64,          // the gain now, linear
	reduction: f32,         // dB, what `.reduction` reads
	last:     [3]f32,       // threshold, knee, ratio the curve was made from
	known:    bool,
	k, lin_thr, knee_thr, knee_db, slope, makeup: f64,
}

compressor_init :: proc(n: ^Node) {
	d := new(Compressor_Data)
	d.env = 1
	n.data = d
	n.params = make([]Param, 5)
	param_init(&n.params[0], -24, -100, 0, false, true)   // threshold
	param_init(&n.params[1], 30, 0, 40, false, true)      // knee
	param_init(&n.params[2], 12, 1, 20, false, true)      // ratio
	param_init(&n.params[3], 0.003, 0, 1, false, true)    // attack
	param_init(&n.params[4], 0.25, 0, 1, false, true)     // release
}

compressor_destroy :: proc(d: ^Compressor_Data) {
	delete(d.ring)
	free(d)
}

@(private = "file") db_of :: #force_inline proc "contextless" (x: f64) -> f64 { return x > 0 ? 20 * math.log10(x) : -1000 }
@(private = "file") linear_of :: #force_inline proc "contextless" (db: f64) -> f64 { return math.pow(10, db / 20) }

@(private = "file")
knee_curve :: proc(d: ^Compressor_Data, x, k: f64) -> f64 {
	if x < d.lin_thr { return x }
	return d.lin_thr + (1 - math.exp(-k * (x - d.lin_thr))) / k
}

// The static curve: linear, a soft knee, then the ratio.
@(private = "file")
saturate :: proc(d: ^Compressor_Data, x: f64) -> f64 {
	if x < d.knee_thr { return knee_curve(d, x, d.k) }
	return linear_of(d.knee_db + d.slope * (db_of(x) - db_of(d.knee_thr)))
}

@(private = "file")
compressor_curve :: proc(d: ^Compressor_Data, threshold, knee, ratio: f32) {
	d.lin_thr = linear_of(f64(threshold))
	d.slope = 1 / f64(ratio)
	d.knee_thr = linear_of(f64(threshold) + f64(knee))
	k := f64(COMPRESSOR_K_START)
	lo, hi := f64(COMPRESSOR_K_MIN), f64(COMPRESSOR_K_MAX)
	for _ in 0 ..< COMPRESSOR_K_STEPS {
		x := d.knee_thr
		x2 := x * COMPRESSOR_SLOPE_STEP
		m := (db_of(knee_curve(d, x2, k)) - db_of(knee_curve(d, x, k))) / (db_of(x2) - db_of(x))
		if m < d.slope { hi = k } else { lo = k }
		k = math.sqrt_f64(lo * hi)
	}
	d.k = k
	d.knee_db = db_of(knee_curve(d, d.knee_thr, k))
	full := saturate(d, 1)
	d.makeup = math.pow(full > 0 ? 1 / full : 1, COMPRESSOR_MAKEUP_POWER)
}

compressor_run :: proc(g: ^Graph, n: ^Node) {
	d := n.data.(^Compressor_Data)
	in_mix := &n.inputs[0].mix
	o := &n.outputs[0]
	channels := in_mix.channels
	if d.ring == nil || channels != d.channels {
		delete(d.ring)
		d.frames = max(int(COMPRESSOR_LOOKAHEAD_S * g.rate), 1)
		d.channels = channels
		d.ring = make([]f32, channels * d.frames)
		d.pos = 0
	}
	now := [3]f32{param_at(&n.params[0], 0), param_at(&n.params[1], 0), param_at(&n.params[2], 0)}
	if !d.known || now != d.last {
		compressor_curve(d, now[0], now[1], now[2])
		d.last, d.known = now, true
	}
	attack := math.exp(-1 / (max(f64(param_at(&n.params[3], 0)), COMPRESSOR_MIN_TIME_S) * g.rate))
	release := math.exp(-1 / (max(f64(param_at(&n.params[4], 0)), COMPRESSOR_MIN_TIME_S) * g.rate))
	bus_prepare(o, channels)
	o.silent = false
	for i in 0 ..< RENDER_QUANTUM {
		level := 0.0
		for c in 0 ..< channels { level = max(level, abs(f64(bus_ch(in_mix, c)[i]))) }
		target := level > 0 ? saturate(d, level) / level : 1
		target = min(target, 1)
		coef := target < d.env ? attack : release
		d.env = target + (d.env - target) * coef
		out_gain := f32(d.env * d.makeup)
		for c in 0 ..< channels {
			ring := d.ring[c * d.frames:][:d.frames]
			delayed := ring[d.pos]
			ring[d.pos] = bus_ch(in_mix, c)[i]
			bus_ch(o, c)[i] = delayed * out_gain
		}
		d.pos = (d.pos + 1) % d.frames
	}
	d.reduction = f32(db_of(d.env))
}

// ---- WaveShaperNode (the attribute oversample is kept, the curve runs at the context's rate) ----

Shaper_Data :: struct {
	curve:      []f32,
	oversample: int,
}

shaper_set_curve :: proc(g: ^Graph, id: i32, curve: []f32) {
	context.allocator = alloc()
	c := make([]f32, len(curve))
	copy(c, curve)
	graph_guard(g)
	n := node_of(g, id)
	d: ^Shaper_Data
	ok: bool
	if n != nil { d, ok = n.data.(^Shaper_Data) }
	if !ok { delete(c); return }
	delete(d.curve)
	d.curve = c
}

shaper_run :: proc(n: ^Node) {
	d := n.data.(^Shaper_Data)
	in_mix := &n.inputs[0].mix
	o := &n.outputs[0]
	if len(d.curve) == 0 {
		bus_copy(o, in_mix)
		return
	}
	bus_prepare(o, in_mix.channels)
	o.silent = false
	last := len(d.curve) - 1
	for c in 0 ..< in_mix.channels {
		s, t := bus_ch(in_mix, c), bus_ch(o, c)
		for i in 0 ..< RENDER_QUANTUM {
			if last == 0 { t[i] = d.curve[0]; continue }
			v := f64(last) * (f64(s[i]) + 1) / 2
			if v <= 0 { t[i] = d.curve[0]; continue }
			if v >= f64(last) { t[i] = d.curve[last]; continue }
			k := int(v)
			frac := f32(v - f64(k))
			t[i] = d.curve[k] + (d.curve[k + 1] - d.curve[k]) * frac
		}
	}
}

// ---- AnalyserNode ----

ANALYSER_MIN_FFT :: 32
ANALYSER_MAX_FFT :: 32768
// Blackman window (Web Audio API, "Blackman window")
BLACKMAN_ALPHA :: 0.16

Analyser_Read :: enum i32 { Float_Frequency, Byte_Frequency, Float_Time, Byte_Time }

Analyser_Data :: struct {
	ring:      []f32,    // mono, the last ANALYSER_MAX_FFT frames
	pos:       int,
	fft_size:  int,
	min_db, max_db, smoothing: f64,
	smoothed:  []f64,    // ANALYSER_MAX_FFT / 2
	smoothed_for: i64,   // the frame they were computed at
	mono:      Bus,
}

analyser_new :: proc() -> ^Analyser_Data {
	d := new(Analyser_Data)
	d.ring = make([]f32, ANALYSER_MAX_FFT)
	d.smoothed = make([]f64, ANALYSER_MAX_FFT / 2)
	d.fft_size, d.min_db, d.max_db, d.smoothing = 2048, -100, -30, 0.8
	d.smoothed_for = -1
	return d
}

analyser_destroy :: proc(d: ^Analyser_Data) {
	delete(d.ring)
	delete(d.smoothed)
	bus_destroy(&d.mono)
	free(d)
}

analyser_run :: proc(g: ^Graph, n: ^Node) {
	d := n.data.(^Analyser_Data)
	in_mix := &n.inputs[0].mix
	bus_copy(&n.outputs[0], in_mix)
	bus_clear(&d.mono, 1)
	bus_sum(&d.mono, in_mix, .Speakers)
	s := bus_ch(&d.mono, 0)
	for i in 0 ..< RENDER_QUANTUM { d.ring[(d.pos + i) % ANALYSER_MAX_FFT] = s[i] }
	d.pos = (d.pos + RENDER_QUANTUM) % ANALYSER_MAX_FFT
}

// getFloat/ByteFrequencyData, getFloat/ByteTimeDomainData: `out` holds floats or bytes. The number of values written.
analyser_read :: proc(g: ^Graph, id: i32, what: Analyser_Read, out: []u8) -> int {
	context.allocator = alloc()
	graph_guard(g)
	n := node_of(g, id)
	if n == nil { return 0 }
	d, ok := n.data.(^Analyser_Data)
	if !ok { return 0 }
	floats := ([^]f32)(raw_data(out))
	size := d.fft_size
	switch what {
	case .Float_Time, .Byte_Time:
		count := what == .Float_Time ? min(len(out) / 4, size) : min(len(out), size)
		start := (d.pos - size + ANALYSER_MAX_FFT) % ANALYSER_MAX_FFT
		for i in 0 ..< count {
			v := d.ring[(start + i) % ANALYSER_MAX_FFT]
			if what == .Float_Time {
				floats[i] = v
			} else {
				out[i] = u8(clamp(128 * (f64(v) + 1), 0, 255))
			}
		}
		return count
	case .Float_Frequency, .Byte_Frequency:
		if d.smoothed_for != g.frame {
			re, im := make([]f64, size), make([]f64, size)
			defer { delete(re); delete(im) }
			start := (d.pos - size + ANALYSER_MAX_FFT) % ANALYSER_MAX_FFT
			a0, a1, a2 := (1 - BLACKMAN_ALPHA) / 2, 0.5, BLACKMAN_ALPHA / 2
			for i in 0 ..< size {
				x := f64(i) / f64(size)
				w := a0 - a1 * math.cos(2 * math.PI * x) + a2 * math.cos(4 * math.PI * x)
				re[i] = f64(d.ring[(start + i) % ANALYSER_MAX_FFT]) * w
			}
			fft(re, im)
			for k in 0 ..< size / 2 {
				mag := math.sqrt_f64(re[k] * re[k] + im[k] * im[k]) / f64(size)
				v := d.smoothing * d.smoothed[k] + (1 - d.smoothing) * mag
				d.smoothed[k] = math.is_nan(v) || math.is_inf(v) ? 0 : v
			}
			d.smoothed_for = g.frame
		}
		count := what == .Float_Frequency ? min(len(out) / 4, size / 2) : min(len(out), size / 2)
		for k in 0 ..< count {
			db := d.smoothed[k] > 0 ? 20 * math.log10(d.smoothed[k]) : math.inf_f64(-1)
			if what == .Float_Frequency {
				floats[k] = f32(db)
			} else {
				out[k] = u8(clamp(255 / (d.max_db - d.min_db) * (db - d.min_db), 0, 255))
			}
		}
		return count
	}
	return 0
}

// ---- ConvolverNode: non-uniform partitioned convolution, no latency ----
//
// The impulse is cut into stages of growing blocks: a quantum (128 frames) at its head, then 256, 512... up to
// CONV_MAX_BLOCK for the rest of the tail. A stage of blocks of B frames convolves by transforms of 2B (overlap-save)
// once every B frames, so the work per frame grows with the logarithm of the impulse's length, not with its length.
// A stage starts at least B - 128 frames into the impulse: its output for a block is due no earlier than the quantum
// that completes the block, so nothing waits (no latency). The multiply-adds of a stage's older partitions, whose
// input is already known, are spread over the quanta of the block; only the newest partition waits for the block's end.

CONV_MAX_BLOCK :: 4096
// Blocks of each stage shorter than CONV_MAX_BLOCK (the last stage has as many as the impulse needs).
CONV_STAGE_BLOCKS :: 2
// Web Audio API, "Convolver": the normalization of an impulse response.
CONV_CALIBRATION :: 0.00125
CONV_CALIBRATION_RATE :: 44100
CONV_MIN_POWER :: 0.000125
@(private = "file") conv_silence: [RENDER_QUANTUM]f32
// The rounding error of the transforms: below it there is nothing.
CONV_NOISE :: 1e-11

// Complex spectra, real and imaginary parts apart, `stride` floats per partition (the block + 1 bins of a real
// signal, rounded up to 4 so that the vector loop has no tail; the extra bins stay 0).
Conv_Spectra :: struct {
	re, im: []f32,
}

// The impulse's frames [offset, offset + count * block), in `count` partitions of `block` frames.
Conv_Stage :: struct {
	block, count, offset: int,
	stride:  int,                // block + 4
	plan:    Fft_Plan,           // of 2 * block
	kernels: [4]Conv_Spectra,    // per impulse channel, `count` partitions
	inputs:  [2]Conv_Spectra,    // per path (input side), the spectra of its last `count` blocks, a ring
	time:    [2][]f64,           // per path, 2 * block frames: the last block, then the one being filled
	acc:     [2]Conv_Spectra,    // per output channel, the partitions added so far for the block being filled
	head:    int,                // the ring slot of the newest input spectrum
	fill:    int,                // frames of the block being filled
	done:    int,                // partitions (from 1) already in `acc`
}

Convolver_Data :: struct {
	normalize:  bool,
	channels:   int,          // of the impulse: 1, 2 or 4; 0: none
	scale:      f64,
	stages:     []Conv_Stage,
	out:        [2][]f32,     // per output channel, what is still to come: a ring, a power of two long
	out_pos:    int,          // the ring's frame of the current quantum
	work_re, work_im: []f64,  // 2 * the largest block
	tail_frames: int,         // how long the output goes on after the input ends
	quiet_quanta: int,        // quanta of silent input in a row
}

@(private = "file")
spectra_make :: proc(n: int) -> Conv_Spectra { return {make([]f32, n), make([]f32, n)} }

@(private = "file")
spectra_free :: proc(s: ^Conv_Spectra) {
	delete(s.re)
	delete(s.im)
	s^ = {}
}

@(private = "file")
convolver_free_content :: proc(d: ^Convolver_Data) {
	for &st in d.stages {
		fft_plan_destroy(&st.plan)
		for &k in st.kernels { spectra_free(&k) }
		for &x in st.inputs { spectra_free(&x) }
		for &a in st.acc { spectra_free(&a) }
		for t in st.time { delete(t) }
	}
	delete(d.stages)
	delete(d.out[0]); delete(d.out[1]); delete(d.work_re); delete(d.work_im)
	d.stages, d.out, d.work_re, d.work_im = nil, {}, nil, nil
}

convolver_destroy :: proc(d: ^Convolver_Data) {
	convolver_free_content(d)
	free(d)
}

// `buffer = pcm`: the spectra are made before the lock is taken (a long impulse takes a moment). nil: none. Only the
// first `max_seconds` of the impulse are used (webaudio.max_convolver_seconds): the memory and the work grow with it.
convolver_set :: proc(g: ^Graph, id: i32, pcm: ^Pcm, normalize: bool, max_seconds := MAX_CONVOLVER_SECONDS) {
	context.allocator = alloc()
	new_data: Convolver_Data
	new_data.normalize = normalize
	if pcm != nil && pcm.length > 0 && (pcm.channels == 1 || pcm.channels == 2 || pcm.channels == 4) {
		new_data.channels = pcm.channels
		length := pcm.length
		if max_seconds > 0 && max_seconds * pcm.rate < f64(length) { length = max(int(max_seconds * pcm.rate), 1) }
		new_data.scale = 1
		if normalize {
			// (the power of the whole buffer, as the specification says, even past the part that is used)
			power := 0.0
			for v in pcm.samples { power += f64(v) * f64(v) }
			power = math.sqrt_f64(power / f64(pcm.channels * pcm.length))
			if power < CONV_MIN_POWER { power = CONV_MIN_POWER }
			new_data.scale = 1 / power * CONV_CALIBRATION * CONV_CALIBRATION_RATE / pcm.rate
			if pcm.channels == 4 { new_data.scale *= 0.5 }
		}
		conv_build(&new_data, pcm, length)
	}
	graph_guard(g)
	n := node_of(g, id)
	d: ^Convolver_Data
	ok: bool
	if n != nil { d, ok = n.data.(^Convolver_Data) }
	if !ok { convolver_free_content(&new_data); return }
	convolver_free_content(d)
	d^ = new_data
	if pcm != nil { n.active_until = g.frame + i64(new_data.tail_frames) }
}

// The stages of an impulse of `length` frames, and their spectra.
@(private = "file")
conv_build :: proc(d: ^Convolver_Data, pcm: ^Pcm, length: int) {
	stages := 0
	off, block := 0, RENDER_QUANTUM
	for off < length {
		off += conv_stage_count(length - off, block) * block
		if block < CONV_MAX_BLOCK { block *= 2 }
		stages += 1
	}
	d.stages = make([]Conv_Stage, stages)
	off, block = 0, RENDER_QUANTUM
	biggest := RENDER_QUANTUM
	for &st in d.stages {
		st.block, st.count, st.offset, st.stride = block, conv_stage_count(length - off, block), off, block + 4
		st.plan = fft_plan_make(2 * block)
		st.done = 1
		for c in 0 ..< pcm.channels { st.kernels[c] = spectra_make(st.count * st.stride) }
		for p in 0 ..< 2 {
			st.inputs[p] = spectra_make(st.count * st.stride)
			st.acc[p] = spectra_make(st.stride)
			st.time[p] = make([]f64, 2 * block)
		}
		off += st.count * block
		biggest = block
		if block < CONV_MAX_BLOCK { block *= 2 }
	}
	d.work_re, d.work_im = make([]f64, 2 * biggest), make([]f64, 2 * biggest)
	for &st in d.stages {
		re, im := d.work_re[:2 * st.block], d.work_im[:2 * st.block]
		for c in 0 ..< pcm.channels {
			src := pcm_channel(pcm, c)
			k := &st.kernels[c]
			for q in 0 ..< st.count {
				for i in 0 ..< len(re) { re[i], im[i] = 0, 0 }
				from := st.offset + q * st.block
				for i in 0 ..< min(st.block, length - from) { re[i] = f64(src[from + i]) * d.scale }
				fft_planned(&st.plan, re, im)
				for b in 0 ..= st.block { k.re[q * st.stride + b], k.im[q * st.stride + b] = f32(re[b]), f32(im[b]) }
			}
		}
	}
	// the ring reaches from the current quantum to the end of what the last stage writes (its offset + 128)
	ring := RENDER_QUANTUM
	for ring < off + 2 * biggest + RENDER_QUANTUM { ring *= 2 }
	d.out[0], d.out[1] = make([]f32, ring), make([]f32, ring)
	d.tail_frames = off + 2 * biggest
}

// Partitions of a stage of blocks of `block` frames for the `rest` frames of the impulse not yet covered.
@(private = "file")
conv_stage_count :: proc "contextless" (rest, block: int) -> int {
	n := (rest + block - 1) / block
	return block < CONV_MAX_BLOCK ? min(n, CONV_STAGE_BLOCKS) : n
}

// The (path, impulse channel) pairs summed into an output channel (Web Audio API, "Channel Configurations for Input,
// Impulse Response and Output"): a mono or stereo impulse convolves each side; "true" stereo (4 channels) mixes
// LL + RL into the left, LR + RR into the right.
@(private = "file")
conv_pairs :: proc "contextless" (channels, out: int) -> (pairs: [2][2]int, n: int) {
	switch channels {
	case 1: return {{out, 0}, {}}, 1
	case 2: return {{out, out}, {}}, 1
	}
	if out == 0 { return {{0, 0}, {1, 2}}, 2 }
	return {{0, 1}, {1, 3}}, 2
}

// acc += x * h, bin by bin (complex, real and imaginary parts apart), 4 bins a step: the convolver's inner loop.
conv_cmac :: proc "contextless" (acc_re, acc_im, xr, xi, hr, hi: []f32) #no_bounds_check {
	n := len(acc_re)
	if len(acc_im) < n || len(xr) < n || len(xi) < n || len(hr) < n || len(hi) < n { return }
	V :: #simd[4]f32
	i := 0
	for ; i + 4 <= n; i += 4 {
		a, b := intrinsics.unaligned_load((^V)(&xr[i])), intrinsics.unaligned_load((^V)(&xi[i]))
		c, e := intrinsics.unaligned_load((^V)(&hr[i])), intrinsics.unaligned_load((^V)(&hi[i]))
		intrinsics.unaligned_store((^V)(&acc_re[i]), intrinsics.unaligned_load((^V)(&acc_re[i])) + (a * c - b * e))
		intrinsics.unaligned_store((^V)(&acc_im[i]), intrinsics.unaligned_load((^V)(&acc_im[i])) + (a * e + b * c))
	}
	conv_cmac_scalar(acc_re[i:n], acc_im[i:n], xr[i:n], xi[i:n], hr[i:n], hi[i:n])
}

// The reference of conv_cmac.
conv_cmac_scalar :: proc "contextless" (acc_re, acc_im, xr, xi, hr, hi: []f32) {
	for b in 0 ..< len(acc_re) {
		acc_re[b] += xr[b] * hr[b] - xi[b] * hi[b]
		acc_im[b] += xr[b] * hi[b] + xi[b] * hr[b]
	}
}

// Adds partitions [st.done, upto) of the block being filled to the stage's sums: partition q meets the input of q
// blocks ago, already in the ring (the newest spectrum, at `head`, is the block before the one being filled).
@(private = "file")
conv_accumulate :: proc(d: ^Convolver_Data, st: ^Conv_Stage, upto: int) {
	w := st.stride
	for q in st.done ..< upto {
		x := ((st.head - (q - 1)) % st.count + st.count) % st.count * w
		for ch in 0 ..< 2 {
			acc := &st.acc[ch]
			pairs, np := conv_pairs(d.channels, ch)
			for k in 0 ..< np {
				in_s, h := &st.inputs[pairs[k][0]], &st.kernels[pairs[k][1]]
				conv_cmac(acc.re, acc.im, in_s.re[x:][:w], in_s.im[x:][:w], h.re[q * w:][:w], h.im[q * w:][:w])
			}
		}
	}
	st.done = max(st.done, upto)
}

// One quantum of input through a stage; at the end of a block, its output into the ring.
@(private = "file")
conv_stage_run :: proc(d: ^Convolver_Data, st: ^Conv_Stage, ins: [2][]f32) {
	B := st.block
	for p in 0 ..< 2 {
		t := st.time[p][B + st.fill:][:RENDER_QUANTUM]
		for i in 0 ..< RENDER_QUANTUM { t[i] = f64(ins[p][i]) }
	}
	st.fill += RENDER_QUANTUM
	if st.fill < B {
		// the older partitions' share of this quantum
		conv_accumulate(d, st, 1 + (st.count - 1) * st.fill / B)
		return
	}
	conv_accumulate(d, st, st.count)
	// the block is complete: its spectrum becomes the newest, and it the last block
	st.head = (st.head + 1) % st.count
	re, im := d.work_re[:2 * B], d.work_im[:2 * B]
	w := st.stride
	for p in 0 ..< 2 {
		copy(re, st.time[p])
		for i in 0 ..< len(im) { im[i] = 0 }
		fft_planned(&st.plan, re, im)
		x := &st.inputs[p]
		for b in 0 ..= B { x.re[st.head * w + b], x.im[st.head * w + b] = f32(re[b]), f32(im[b]) }
		copy(st.time[p][:B], st.time[p][B:])
	}
	ring_mask := len(d.out[0]) - 1
	// overlap-save: the second half of the inverse is the block's output, due `offset` frames after the block began
	at := d.out_pos + RENDER_QUANTUM - B + st.offset
	inv_n := 1 / f64(2 * B)
	for ch in 0 ..< 2 {
		acc := &st.acc[ch]
		pairs, np := conv_pairs(d.channels, ch)
		for k in 0 ..< np {
			in_s, h := &st.inputs[pairs[k][0]], &st.kernels[pairs[k][1]]
			conv_cmac(acc.re, acc.im, in_s.re[st.head * w:][:w], in_s.im[st.head * w:][:w], h.re[:w], h.im[:w])
		}
		for b in 0 ..= B { re[b], im[b] = f64(acc.re[b]), f64(acc.im[b]) }
		// the other half of the spectrum of a real signal
		for b in 1 ..< B { re[2 * B - b], im[2 * B - b] = re[b], -im[b] }
		fft_planned(&st.plan, re, im, true)
		out := d.out[ch]
		for i in 0 ..< B { out[(at + i) & ring_mask] += f32(re[B + i] * inv_n) }
		for b in 0 ..< w { acc.re[b], acc.im[b] = 0, 0 }
	}
	st.fill = 0
	st.done = 1
}

convolver_run :: proc(n: ^Node) {
	d := n.data.(^Convolver_Data)
	in_mix := &n.inputs[0].mix
	o := &n.outputs[0]
	if d.channels == 0 {
		bus_clear(o, 1)
		return
	}
	// the tail of what came in is over: not actively processing, one channel of silence (the specification). Every
	// buffer of the stages holds zeros by then, so stopping them (and the ring) keeps them in step.
	if in_mix.silent {
		d.quiet_quanta += 1
		if d.quiet_quanta > d.tail_frames / RENDER_QUANTUM + 2 {
			bus_clear(o, 1)
			return
		}
	} else {
		d.quiet_quanta = 0
	}
	// mono only for a mono input and a mono impulse (Web Audio API, "Channel Configurations for Input, Impulse Response and Output")
	stereo := in_mix.channels > 1 || d.channels > 1
	bus_clear(o, stereo ? 2 : 1)
	o.silent = false
	sl := bus_ch(in_mix, 0)
	// (a mono input up-mixed: to both by the speakers rule, to the left alone by the discrete one)
	sr := in_mix.channels > 1 ? bus_ch(in_mix, 1) : (n.interp == .Discrete ? conv_silence[:] : sl)
	for &st in d.stages { conv_stage_run(d, &st, {sl, sr}) }
	// the quantum due now, out of the ring, then cleared for its next turn
	for ch in 0 ..< 2 {
		ring := d.out[ch][d.out_pos:][:RENDER_QUANTUM]
		if ch < o.channels {
			out := bus_ch(o, ch)
			for i in 0 ..< RENDER_QUANTUM {
				if abs(ring[i]) > CONV_NOISE { out[i] += ring[i] }   // (what is left of a zero after two transforms stays a zero)
			}
		}
		for &v in ring { v = 0 }
	}
	d.out_pos = (d.out_pos + RENDER_QUANTUM) & (len(d.out[0]) - 1)
}

// ---- MediaElementAudioSourceNode: the player gives what it plays; a ring in between ----

// Seconds of audio the ring holds. The player leads by what it queues ahead; more is dropped, oldest first.
ELEMENT_RING_SECONDS :: 1

Element_Data :: struct {
	ring:  []f32,     // stereo interleaved
	read, write: i64, // frames, ever
	frac:  f64,       // of the conversion of rates
	last:  [2]f32,
	rate:  f64,       // the context's
}

element_new :: proc(g: ^Graph) -> ^Element_Data {
	d := new(Element_Data)
	d.rate = g.rate
	d.ring = make([]f32, int(g.rate * ELEMENT_RING_SECONDS) * 2)
	return d
}

element_destroy :: proc(d: ^Element_Data) {
	delete(d.ring)
	free(d)
}

// From the player's thread: interleaved stereo at `rate`, converted to the context's rate (linear).
element_push :: proc(g: ^Graph, id: i32, samples: []f32, rate: f64) {
	graph_guard(g)
	n := node_of(g, id)
	if n == nil { return }
	d, ok := n.data.(^Element_Data)
	if !ok { return }
	frames := len(samples) / 2
	capacity := i64(len(d.ring) / 2)
	step := rate / d.rate
	pos := d.frac
	for pos < f64(frames) {
		k := int(pos)
		t := f32(pos - f64(k))
		a0, a1 := k == 0 ? d.last[0] : samples[(k - 1) * 2], k == 0 ? d.last[1] : samples[(k - 1) * 2 + 1]
		b0, b1 := samples[k * 2], samples[k * 2 + 1]
		at := int(d.write % capacity) * 2
		d.ring[at] = a0 + (b0 - a0) * t
		d.ring[at + 1] = a1 + (b1 - a1) * t
		d.write += 1
		pos += step
	}
	d.frac = pos - f64(frames)
	if frames > 0 { d.last = {samples[(frames - 1) * 2], samples[(frames - 1) * 2 + 1]} }
	if d.write - d.read > capacity { d.read = d.write - capacity }
}

element_run :: proc(n: ^Node) {
	d := n.data.(^Element_Data)
	o := &n.outputs[0]
	if d.read >= d.write { bus_clear(o, 2); return }
	bus_clear(o, 2)
	o.silent = false
	l, r := bus_ch(o, 0), bus_ch(o, 1)
	capacity := i64(len(d.ring) / 2)
	for i in 0 ..< RENDER_QUANTUM {
		if d.read >= d.write { break }
		at := int(d.read % capacity) * 2
		l[i], r[i] = d.ring[at], d.ring[at + 1]
		d.read += 1
	}
}
// ---- ScriptProcessorNode: blocks go to the page and come back, in rings: the thread renders a few quanta in a go, and the
// page answers when it can. An answer that comes late plays late; with none yet, silence. ----

// Blocks each way.
SCRIPT_RING_BLOCKS :: 8
// Silent blocks it starts with: an answer plays this many blocks after its input.
SCRIPT_PREFILL_BLOCKS :: 2

Script_Data :: struct {
	size:     int,            // frames of a block
	in_ch, out_ch: int,
	in_ring:  []f32,          // SCRIPT_RING_BLOCKS * in_ch * size
	out_ring: []f32,          // SCRIPT_RING_BLOCKS * out_ch * size
	in_w, in_r, out_w, out_r: i64,   // blocks, ever
	pos:      int,            // within the block
	playing:  bool,           // this block has an answer (else silence until its end)
}

script_new :: proc(size, in_ch, out_ch: int) -> ^Script_Data {
	d := new(Script_Data)
	d.size, d.in_ch, d.out_ch = size, in_ch, out_ch
	d.in_ring, d.out_ring = make([]f32, SCRIPT_RING_BLOCKS * in_ch * size), make([]f32, SCRIPT_RING_BLOCKS * out_ch * size)
	d.out_w = SCRIPT_PREFILL_BLOCKS
	return d
}

script_destroy :: proc(d: ^Script_Data) {
	delete(d.in_ring)
	delete(d.out_ring)
	free(d)
}

@(private = "file")
script_channel :: #force_inline proc "contextless" (ring: []f32, block: i64, channels, size, c: int) -> []f32 {
	return ring[(int(block % SCRIPT_RING_BLOCKS) * channels + c) * size:][:size]
}

script_run :: proc(g: ^Graph, n: ^Node) {
	d := n.data.(^Script_Data)
	in_mix := &n.inputs[0].mix
	o := &n.outputs[0]
	if d.pos == 0 { d.playing = d.out_r < d.out_w }
	for c in 0 ..< d.in_ch {
		s := bus_ch(in_mix, min(c, in_mix.channels - 1))
		copy(script_channel(d.in_ring, d.in_w, d.in_ch, d.size, c)[d.pos:][:RENDER_QUANTUM], s)
	}
	if d.out_ch == 0 || !d.playing {
		bus_clear(o, max(d.out_ch, 1))
	} else {
		bus_prepare(o, d.out_ch)
		for c in 0 ..< d.out_ch { copy(bus_ch(o, c), script_channel(d.out_ring, d.out_r, d.out_ch, d.size, c)[d.pos:][:RENDER_QUANTUM]) }
	}
	d.pos += RENDER_QUANTUM
	if d.pos >= d.size {
		d.pos = 0
		if d.playing { d.out_r += 1 }
		d.in_w += 1
		if d.in_w - d.in_r > SCRIPT_RING_BLOCKS { d.in_r = d.in_w - SCRIPT_RING_BLOCKS }
		post_event(g, .Script_Block, n.id, 0)
		// An offline rendering has all the time: it waits for the answer, which then comes exactly a block later.
		if g.offline {
			want := d.out_w + 1
			for d.out_w < want && !sync.atomic_load(&g.thread.quit) { sync.cond_wait(&g.thread.wake, &g.mu) }
		}
	}
}

// The page takes the oldest full input block (planar).
script_pull :: proc(g: ^Graph, id: i32, out: []u8) {
	graph_guard(g)
	n := node_of(g, id)
	if n == nil { return }
	d, ok := n.data.(^Script_Data)
	if !ok || d.in_r >= d.in_w { return }
	block := d.in_ring[int(d.in_r % SCRIPT_RING_BLOCKS) * d.in_ch * d.size:][:d.in_ch * d.size]
	copy(out, ([^]u8)(raw_data(block))[:len(block) * size_of(f32)])
	d.in_r += 1
}

// The page's answer (planar) goes after the others.
script_push :: proc(g: ^Graph, id: i32, data: []u8) {
	graph_guard(g)
	n := node_of(g, id)
	if n == nil { return }
	d, ok := n.data.(^Script_Data)
	if !ok || d.out_ch == 0 { return }
	block := d.out_ring[int(d.out_w % SCRIPT_RING_BLOCKS) * d.out_ch * d.size:][:d.out_ch * d.size]
	copy(([^]u8)(raw_data(block))[:len(block) * size_of(f32)], data)
	d.out_w += 1
	if d.out_w - d.out_r > SCRIPT_RING_BLOCKS { d.out_r = d.out_w - SCRIPT_RING_BLOCKS }
	sync.cond_broadcast(&g.thread.wake)
}


// ---- IIRFilterNode: y[n] = sum(b[k] x[n-k]) - sum(a[k] y[n-k]), normalized by a[0] ----

IIR_Data :: struct {
	feedforward, feedback: []f64,
	x, y:  [dynamic]f64,    // per channel: the last values, IIR_HISTORY of each
	pos:   int,
}

// More than the longest filter there can be (20 coefficients), a power of two.
IIR_HISTORY :: 32

iir_destroy :: proc(d: ^IIR_Data) {
	delete(d.feedforward)
	delete(d.feedback)
	delete(d.x)
	delete(d.y)
	free(d)
}

iir_set :: proc(g: ^Graph, id: i32, feedforward, feedback: []f64) {
	context.allocator = alloc()
	graph_guard(g)
	n := node_of(g, id)
	if n == nil { return }
	d, ok := n.data.(^IIR_Data)
	if !ok || len(feedback) == 0 { return }
	delete(d.feedforward)
	delete(d.feedback)
	d.feedforward, d.feedback = make([]f64, len(feedforward)), make([]f64, len(feedback))
	for v, i in feedforward { d.feedforward[i] = v / feedback[0] }
	for v, i in feedback { d.feedback[i] = v / feedback[0] }
}

iir_run :: proc(n: ^Node) {
	d := n.data.(^IIR_Data)
	in_mix := &n.inputs[0].mix
	o := &n.outputs[0]
	channels := in_mix.channels
	for len(d.x) < channels * IIR_HISTORY {
		append(&d.x, 0)
		append(&d.y, 0)
	}
	bus_prepare(o, channels)
	o.silent = false
	mask := IIR_HISTORY - 1
	start := d.pos
	for c in 0 ..< channels {
		s, t := bus_ch(in_mix, c), bus_ch(o, c)
		xs, ys := d.x[c * IIR_HISTORY:][:IIR_HISTORY], d.y[c * IIR_HISTORY:][:IIR_HISTORY]
		at := start
		for i in 0 ..< RENDER_QUANTUM {
			xs[at] = f64(s[i])
			y := 0.0
			for b, k in d.feedforward { y += b * xs[(at - k) & mask] }
			for a, k in d.feedback { if k > 0 { y -= a * ys[(at - k) & mask] } }
			ys[at] = y
			t[i] = f32(y)
			at = (at + 1) & mask
		}
		d.pos = at
	}
}

iir_frequency_response :: proc(g: ^Graph, id: i32, frequencies: []f32, mag, phase: []f32) {
	graph_guard(g)
	n := node_of(g, id)
	if n == nil { return }
	d, ok := n.data.(^IIR_Data)
	if !ok { return }
	nyquist := g.rate / 2
	eval :: proc(c: []f64, w: f64) -> (re, im: f64) {
		for v, k in c {
			re += v * math.cos(f64(k) * w)
			im -= v * math.sin(f64(k) * w)
		}
		return
	}
	for hz, i in frequencies {
		if hz < 0 || f64(hz) > nyquist || math.is_nan(hz) {
			mag[i], phase[i] = math.nan_f32(), math.nan_f32()
			continue
		}
		w := math.PI * f64(hz) / nyquist
		nr, ni := eval(d.feedforward, w)
		dr, di := eval(d.feedback, w)
		den := dr * dr + di * di
		hr, hi := (nr * dr + ni * di) / den, (ni * dr - nr * di) / den
		mag[i], phase[i] = f32(math.sqrt_f64(hr * hr + hi * hi)), f32(math.atan2(hi, hr))
	}
}
