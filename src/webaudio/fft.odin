package webaudio

// A radix-2 complex FFT on separate real and imaginary arrays of a power-of-two length: enough for the analyser (a
// forward transform of a few thousand points when a script asks), the oscillators' tables and the convolver.

import "core:math"

// In place. `inverse` does not divide by the length (the caller does, or wants it so).
fft :: proc(re, im: []f64, inverse := false) {
	n := len(re)
	if n <= 1 { return }
	j := 0
	for i in 1 ..< n {
		bit := n >> 1
		for ; j & bit != 0; bit >>= 1 { j ~= bit }
		j ~= bit
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	sign := inverse ? 1.0 : -1.0
	for size := 2; size <= n; size <<= 1 {
		half := size >> 1
		step := sign * 2 * math.PI / f64(size)
		// the twiddle factors by a recurrence, restarted per block size (accurate enough at these sizes)
		wr_step, wi_step := math.cos(step), math.sin(step)
		wr, wi := 1.0, 0.0
		for k in 0 ..< half {
			for i := k; i < n; i += size {
				m := i + half
				tr := re[m] * wr - im[m] * wi
				ti := re[m] * wi + im[m] * wr
				re[m], im[m] = re[i] - tr, im[i] - ti
				re[i], im[i] = re[i] + tr, im[i] + ti
			}
			wr, wi = wr * wr_step - wi * wi_step, wr * wi_step + wi * wr_step
		}
	}
}

// A transform of one size planned once, for transforms run every quantum (the convolver): the twiddle factors computed
// each from its angle (no recurrence, so no error grows along a block) and the bit-reversal permutation, in tables.
Fft_Plan :: struct {
	n:      int,
	wr, wi: []f64,   // cos and -sin of 2 pi k / n, k < n / 2: the forward transform's factors
	rev:    []i32,   // i with its log2(n) bits reversed
}

// `n` a power of two, 2 or more.
fft_plan_make :: proc(n: int) -> (p: Fft_Plan) {
	assert(n >= 2 && n & (n - 1) == 0)
	p.n = n
	p.wr, p.wi = make([]f64, n / 2), make([]f64, n / 2)
	for k in 0 ..< n / 2 {
		angle := 2 * math.PI * f64(k) / f64(n)
		p.wr[k], p.wi[k] = math.cos(angle), -math.sin(angle)
	}
	p.rev = make([]i32, n)
	bits := 0
	for (1 << uint(bits)) < n { bits += 1 }
	for i in 0 ..< n {
		r := 0
		for b in 0 ..< bits { r |= ((i >> uint(b)) & 1) << uint(bits - 1 - b) }
		p.rev[i] = i32(r)
	}
	return
}

fft_plan_destroy :: proc(p: ^Fft_Plan) {
	delete(p.wr)
	delete(p.wi)
	delete(p.rev)
	p^ = {}
}

// fft, through a plan of len(re): in place, `inverse` not divided by the length.
fft_planned :: proc "contextless" (p: ^Fft_Plan, re, im: []f64, inverse := false) #no_bounds_check {
	n := p.n
	if n < 2 || len(re) < n || len(im) < n || len(p.rev) < n { return }
	for i in 0 ..< n {
		j := int(p.rev[i])
		if i < j {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	sign := inverse ? -1.0 : 1.0
	for size := 2; size <= n; size <<= 1 {
		half := size >> 1
		step := n / size
		for start := 0; start < n; start += size {
			for k in 0 ..< half {
				wr, wi := p.wr[k * step], p.wi[k * step] * sign
				i, m := start + k, start + k + half
				tr := re[m] * wr - im[m] * wi
				ti := re[m] * wi + im[m] * wr
				re[m], im[m] = re[i] - tr, im[i] - ti
				re[i], im[i] = re[i] + tr, im[i] + ti
			}
		}
	}
}
