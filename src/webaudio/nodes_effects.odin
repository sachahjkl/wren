package webaudio

// The larger nodes: panners, the compressor, the wave shaper, the analyser, the convolver, and the two that exchange audio
// with something outside the graph (a script processor, a media element).

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
	sync.guard(&g.mu)
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
	sync.guard(&g.mu)
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

// ---- ConvolverNode: uniform partitioned convolution, no latency ----

// The partitions are a quantum long: the transforms are twice that.
CONV_FFT :: 2 * RENDER_QUANTUM
CONV_BINS :: RENDER_QUANTUM + 1
// Web Audio API, "Convolver": the normalization of an impulse response.
CONV_CALIBRATION :: 0.00125
CONV_CALIBRATION_RATE :: 44100
CONV_MIN_POWER :: 0.000125
@(private = "file") conv_silence: [RENDER_QUANTUM]f32
// The rounding error of the transforms: below it there is nothing.
CONV_NOISE :: 1e-11

// The spectra of an impulse's channel: partitions * CONV_BINS.
Conv_Kernel :: struct {
	re, im: []f64,
}

Conv_Path :: struct {
	in_re, in_im: []f64,    // the last spectra of the input, partitions * CONV_BINS, a ring
	head: int,
	prev: [RENDER_QUANTUM]f64,
}

Convolver_Data :: struct {
	normalize: bool,
	channels:  int,        // of the impulse: 1, 2 or 4; 0: none
	partitions: int,
	scale:     f64,
	kernels:   [4]Conv_Kernel,
	paths:     [2]Conv_Path,
	work_re, work_im: []f64,
	sum_re, sum_im: []f64,
}

@(private = "file")
convolver_free_content :: proc(d: ^Convolver_Data) {
	for &k in d.kernels { delete(k.re); delete(k.im); k = {} }
	for &p in d.paths { delete(p.in_re); delete(p.in_im); p = {} }
	delete(d.work_re); delete(d.work_im); delete(d.sum_re); delete(d.sum_im)
	d.work_re, d.work_im, d.sum_re, d.sum_im = nil, nil, nil, nil
}

convolver_destroy :: proc(d: ^Convolver_Data) {
	convolver_free_content(d)
	free(d)
}

// `buffer = pcm`: the spectra are made before the lock is taken (a long impulse takes a moment). nil: none.
convolver_set :: proc(g: ^Graph, id: i32, pcm: ^Pcm, normalize: bool) {
	context.allocator = alloc()
	new_data: Convolver_Data
	new_data.normalize = normalize
	if pcm != nil && pcm.length > 0 {
		new_data.channels = pcm.channels
		new_data.partitions = (pcm.length + RENDER_QUANTUM - 1) / RENDER_QUANTUM
		parts := new_data.partitions
		new_data.scale = 1
		if normalize {
			power := 0.0
			for v in pcm.samples { power += f64(v) * f64(v) }
			power = math.sqrt_f64(power / f64(pcm.channels * pcm.length))
			if power < CONV_MIN_POWER { power = CONV_MIN_POWER }
			new_data.scale = 1 / power * CONV_CALIBRATION * CONV_CALIBRATION_RATE / pcm.rate
			if pcm.channels == 4 { new_data.scale *= 0.5 }
		}
		re, im := make([]f64, CONV_FFT), make([]f64, CONV_FFT)
		defer { delete(re); delete(im) }
		for c in 0 ..< pcm.channels {
			k := &new_data.kernels[c]
			k.re, k.im = make([]f64, parts * CONV_BINS), make([]f64, parts * CONV_BINS)
			src := pcm_channel(pcm, c)
			for p in 0 ..< parts {
				for i in 0 ..< CONV_FFT { re[i], im[i] = 0, 0 }
				from := p * RENDER_QUANTUM
				for i in 0 ..< min(RENDER_QUANTUM, pcm.length - from) { re[i] = f64(src[from + i]) * new_data.scale }
				fft(re, im)
				copy(k.re[p * CONV_BINS:][:CONV_BINS], re[:CONV_BINS])
				copy(k.im[p * CONV_BINS:][:CONV_BINS], im[:CONV_BINS])
			}
		}
		for &path in new_data.paths {
			path.in_re, path.in_im = make([]f64, parts * CONV_BINS), make([]f64, parts * CONV_BINS)
		}
		new_data.work_re, new_data.work_im = make([]f64, CONV_FFT), make([]f64, CONV_FFT)
		new_data.sum_re, new_data.sum_im = make([]f64, CONV_FFT), make([]f64, CONV_FFT)
	}
	sync.guard(&g.mu)
	n := node_of(g, id)
	d: ^Convolver_Data
	ok: bool
	if n != nil { d, ok = n.data.(^Convolver_Data) }
	if !ok { convolver_free_content(&new_data); return }
	convolver_free_content(d)
	d^ = new_data
	if pcm != nil { n.active_until = g.frame + i64(pcm.length) }
}

// The input's next spectrum of a path.
@(private = "file")
conv_feed :: proc(d: ^Convolver_Data, path: ^Conv_Path, s: []f32) {
	for i in 0 ..< RENDER_QUANTUM {
		d.work_re[i] = path.prev[i]
		d.work_re[RENDER_QUANTUM + i] = f64(s[i])
		path.prev[i] = f64(s[i])
		d.work_im[i], d.work_im[RENDER_QUANTUM + i] = 0, 0
	}
	fft(d.work_re, d.work_im)
	path.head = (path.head + 1) % d.partitions
	copy(path.in_re[path.head * CONV_BINS:][:CONV_BINS], d.work_re[:CONV_BINS])
	copy(path.in_im[path.head * CONV_BINS:][:CONV_BINS], d.work_im[:CONV_BINS])
}

// Adds what a kernel gives for a path's history to `out`.
@(private = "file")
conv_apply :: proc(d: ^Convolver_Data, path: ^Conv_Path, k: ^Conv_Kernel, out: []f32) {
	for i in 0 ..< CONV_FFT { d.sum_re[i], d.sum_im[i] = 0, 0 }
	for p in 0 ..< d.partitions {
		at := (path.head - p + d.partitions) % d.partitions
		xr, xi := path.in_re[at * CONV_BINS:][:CONV_BINS], path.in_im[at * CONV_BINS:][:CONV_BINS]
		hr, hi := k.re[p * CONV_BINS:][:CONV_BINS], k.im[p * CONV_BINS:][:CONV_BINS]
		for b in 0 ..< CONV_BINS {
			d.sum_re[b] += xr[b] * hr[b] - xi[b] * hi[b]
			d.sum_im[b] += xr[b] * hi[b] + xi[b] * hr[b]
		}
	}
	// the other half of the spectrum of a real signal
	for b in 1 ..< RENDER_QUANTUM {
		d.sum_re[CONV_FFT - b], d.sum_im[CONV_FFT - b] = d.sum_re[b], -d.sum_im[b]
	}
	fft(d.sum_re, d.sum_im, true)
	for i in 0 ..< RENDER_QUANTUM {
		v := d.sum_re[RENDER_QUANTUM + i] / CONV_FFT
		if abs(v) > CONV_NOISE { out[i] += f32(v) }   // (what is left of a zero after two transforms stays a zero)
	}
}

convolver_run :: proc(n: ^Node) {
	d := n.data.(^Convolver_Data)
	in_mix := &n.inputs[0].mix
	o := &n.outputs[0]
	if d.channels == 0 {
		bus_clear(o, 1)
		return
	}
	// mono only for a mono input and a mono impulse (Web Audio API, "Channel Configurations for Input, Impulse Response and Output")
	stereo := in_mix.channels > 1 || d.channels > 1
	bus_clear(o, stereo ? 2 : 1)
	o.silent = false
	sl := bus_ch(in_mix, 0)
	// (a mono input up-mixed: to both by the speakers rule, to the left alone by the discrete one)
	sr := in_mix.channels > 1 ? bus_ch(in_mix, 1) : (n.interp == .Discrete ? conv_silence[:] : sl)
	conv_feed(d, &d.paths[0], sl)
	conv_feed(d, &d.paths[1], sr)
	if !stereo {
		conv_apply(d, &d.paths[0], &d.kernels[0], bus_ch(o, 0))
		return
	}
	l, r := bus_ch(o, 0), bus_ch(o, 1)
	switch d.channels {
	case 1:
		conv_apply(d, &d.paths[0], &d.kernels[0], l)
		conv_apply(d, &d.paths[1], &d.kernels[0], r)
	case 2:
		conv_apply(d, &d.paths[0], &d.kernels[0], l)
		conv_apply(d, &d.paths[1], &d.kernels[1], r)
	case:
		// "true" stereo: LL, LR, RL, RR
		conv_apply(d, &d.paths[0], &d.kernels[0], l)
		conv_apply(d, &d.paths[1], &d.kernels[2], l)
		conv_apply(d, &d.paths[0], &d.kernels[1], r)
		conv_apply(d, &d.paths[1], &d.kernels[3], r)
	}
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
	sync.guard(&g.mu)
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
	sync.guard(&g.mu)
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
	sync.guard(&g.mu)
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
	sync.guard(&g.mu)
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
	sync.guard(&g.mu)
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
