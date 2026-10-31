package webaudio

// PeriodicWave: one period of a waveform, as tables band-limited for ranges of frequency (a higher note uses a table with
// fewer partials: what is above Nyquist would alias). The tables are made the first time a frequency needs them.

import "core:math"

WAVE_TABLE_SIZE :: 4096
// Tables per octave of the partial count. More: nearer to the band's edge, more memory.
WAVE_TIERS_PER_OCTAVE :: 3
WAVE_MAX_TIERS :: 11 * WAVE_TIERS_PER_OCTAVE

Oscillator_Type :: enum i32 { Sine, Square, Sawtooth, Triangle, Custom }

Wave :: struct {
	real, imag: []f64,            // the coefficients, index 0 the DC term
	scale:      f64,              // peak normalization (1: none)
	tables:     [WAVE_MAX_TIERS][]f32,
	refs:       int,              // with the graph's lock
}

// A wave from its coefficients (copied). `normalize`: the peak of the full table is 1.
wave_new :: proc(real, imag: []f32, normalize: bool) -> ^Wave {
	context.allocator = alloc()
	w := new(Wave)
	w.refs = 1
	n := max(len(real), len(imag))
	n = min(n, WAVE_TABLE_SIZE / 2)
	w.real, w.imag = make([]f64, n), make([]f64, n)
	for i in 0 ..< n {
		if i < len(real) { w.real[i] = f64(real[i]) }
		if i < len(imag) { w.imag[i] = f64(imag[i]) }
	}
	w.scale = 1
	if normalize {
		re, im := make([]f64, WAVE_TABLE_SIZE), make([]f64, WAVE_TABLE_SIZE)
		defer { delete(re); delete(im) }
		wave_synth(w, n, re, im)
		peak := 0.0
		for v in re { peak = max(peak, abs(v)) }
		if peak > 0 { w.scale = 1 / peak }
	}
	return w
}

// The wave of a basic type (the series of the specification), all partials the tables can hold.
wave_basic :: proc(type: Oscillator_Type) -> ^Wave {
	context.allocator = alloc()
	imag := make([]f32, WAVE_TABLE_SIZE / 2)
	defer delete(imag)
	for k in 1 ..< len(imag) {
		n := f64(k)
		odd := k % 2 == 1
		#partial switch type {
		case .Sine:     imag[k] = k == 1 ? 1 : 0
		case .Square:   imag[k] = f32(odd ? 4 / (n * math.PI) : 0)
		case .Sawtooth: imag[k] = f32((odd ? f64(1) : -1) * 2 / (n * math.PI))
		case .Triangle: imag[k] = f32(odd ? (k % 4 == 1 ? f64(1) : -1) * 8 / (n * n * math.PI * math.PI) : 0)
		}
	}
	return wave_new(nil, imag, type != .Sine)
}

wave_retain :: proc(w: ^Wave) -> ^Wave {
	if w != nil { w.refs += 1 }
	return w
}

wave_release :: proc(w: ^Wave) {
	context.allocator = alloc()
	if w == nil { return }
	w.refs -= 1
	if w.refs > 0 { return }
	for t in w.tables { delete(t) }
	delete(w.real)
	delete(w.imag)
	free(w)
}

// One period in `re` from the first `partials` partials: x[t] = sum(a[k] cos(k t) + b[k] sin(k t)).
@(private = "file")
wave_synth :: proc(w: ^Wave, partials: int, re, im: []f64) {
	for i in 0 ..< len(re) { re[i], im[i] = 0, 0 }
	for k in 1 ..< min(partials + 1, len(w.real)) {
		// X[k] = (a - ib) / 2, and its conjugate at -k
		re[k], im[k] = w.real[k] * 0.5, -w.imag[k] * 0.5
		re[len(re) - k], im[len(re) - k] = w.real[k] * 0.5, w.imag[k] * 0.5
	}
	fft(re, im, true)
}

@(private = "file")
tier_partials :: proc(tier: int) -> int {
	return int(f64(WAVE_TABLE_SIZE / 2) * math.pow(2, -f64(tier) / WAVE_TIERS_PER_OCTAVE))
}

// The table for a frequency at a sample rate: every partial below Nyquist that a tier allows.
wave_table :: proc(w: ^Wave, frequency, rate: f64) -> []f32 {
	context.allocator = alloc()
	f := abs(frequency)
	allowed := f > 0 ? rate * 0.5 / f : f64(WAVE_TABLE_SIZE / 2)
	tier := 0
	for tier < WAVE_MAX_TIERS - 1 && f64(tier_partials(tier)) > allowed { tier += 1 }
	if w.tables[tier] == nil {
		re, im := make([]f64, WAVE_TABLE_SIZE), make([]f64, WAVE_TABLE_SIZE)
		defer { delete(re); delete(im) }
		wave_synth(w, tier_partials(tier), re, im)
		t := make([]f32, WAVE_TABLE_SIZE)
		for i in 0 ..< WAVE_TABLE_SIZE { t[i] = f32(re[i] * w.scale) }
		w.tables[tier] = t
	}
	return w.tables[tier]
}
