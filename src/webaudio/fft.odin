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
