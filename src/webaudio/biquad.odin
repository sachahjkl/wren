package webaudio

// BiquadFilterNode: the formulas of the specification (after Robert Bristow-Johnson's Audio EQ Cookbook), the filter in
// transposed direct form II, and its frequency response.

import "core:math"

Biquad_Type :: enum i32 { Lowpass, Highpass, Bandpass, Lowshelf, Highshelf, Peaking, Notch, Allpass }

Biquad_Coefs :: struct { b0, b1, b2, a1, a2: f64 }   // normalized: a0 = 1

// frequency in Hz (with detune applied), gain in dB.
biquad_coefs :: proc(type: Biquad_Type, frequency, q, gain, rate: f64) -> Biquad_Coefs {
	nyquist := rate / 2
	f := clamp(frequency, 0, nyquist)
	w := 2 * math.PI * f / rate
	a := math.pow(10, gain / 40)
	// the limits of the formulas: at frequency 0 and Nyquist, and at Q 0 where a Q in the denominator would be a division by 0
	#partial switch type {
	case .Lowpass:
		if f >= nyquist { return {b0 = 1} }
		if f <= 0 { return {} }
	case .Highpass:
		if f >= nyquist { return {} }
		if f <= 0 { return {b0 = 1} }
	case .Lowshelf:
		if f >= nyquist { return {b0 = a * a} }
		if f <= 0 { return {b0 = 1} }
	case .Highshelf:
		if f >= nyquist { return {b0 = 1} }
		if f <= 0 { return {b0 = a * a} }
	case .Bandpass:
		if f <= 0 || f >= nyquist { return {} }
		if q <= 0 { return {b0 = 1} }
	case .Notch:
		if f <= 0 || f >= nyquist { return {b0 = 1} }
		if q <= 0 { return {} }
	case .Peaking:
		if f <= 0 || f >= nyquist { return {b0 = 1} }
		if q <= 0 { return {b0 = a * a} }
	case .Allpass:
		if f <= 0 || f >= nyquist { return {b0 = 1} }
		if q <= 0 { return {b0 = -1} }
	}
	cw, sw := math.cos(w), math.sin(w)
	alpha_q := sw / (2 * q)
	alpha_db := sw / (2 * math.pow(10, q / 20))
	alpha_s := sw / 2 * math.sqrt_f64(2)    // (the slope S is 1)
	b0, b1, b2, a0, a1, a2: f64
	switch type {
	case .Lowpass:
		b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
		a0, a1, a2 = 1 + alpha_db, -2 * cw, 1 - alpha_db
	case .Highpass:
		b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
		a0, a1, a2 = 1 + alpha_db, -2 * cw, 1 - alpha_db
	case .Bandpass:
		b0, b1, b2 = alpha_q, 0, -alpha_q
		a0, a1, a2 = 1 + alpha_q, -2 * cw, 1 - alpha_q
	case .Notch:
		b0, b1, b2 = 1, -2 * cw, 1
		a0, a1, a2 = 1 + alpha_q, -2 * cw, 1 - alpha_q
	case .Allpass:
		b0, b1, b2 = 1 - alpha_q, -2 * cw, 1 + alpha_q
		a0, a1, a2 = 1 + alpha_q, -2 * cw, 1 - alpha_q
	case .Peaking:
		b0, b1, b2 = 1 + alpha_q * a, -2 * cw, 1 - alpha_q * a
		a0, a1, a2 = 1 + alpha_q / a, -2 * cw, 1 - alpha_q / a
	case .Lowshelf:
		s := 2 * alpha_s * math.sqrt_f64(a)
		b0 = a * ((a + 1) - (a - 1) * cw + s)
		b1 = 2 * a * ((a - 1) - (a + 1) * cw)
		b2 = a * ((a + 1) - (a - 1) * cw - s)
		a0 = (a + 1) + (a - 1) * cw + s
		a1 = -2 * ((a - 1) + (a + 1) * cw)
		a2 = (a + 1) + (a - 1) * cw - s
	case .Highshelf:
		s := 2 * alpha_s * math.sqrt_f64(a)
		b0 = a * ((a + 1) + (a - 1) * cw + s)
		b1 = -2 * a * ((a - 1) + (a + 1) * cw)
		b2 = a * ((a + 1) + (a - 1) * cw - s)
		a0 = (a + 1) - (a - 1) * cw + s
		a1 = 2 * ((a - 1) - (a + 1) * cw)
		a2 = (a + 1) - (a - 1) * cw - s
	}
	// the limits of the formulas (a frequency or a Q at their edge), so that nothing becomes NaN
	if !(a0 != 0) || math.is_nan(a0) || math.is_nan(b0) || math.is_nan(b2) {
		return Biquad_Coefs{b0 = 1}
	}
	return Biquad_Coefs{b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0}
}

// getFrequencyResponse at one normalized frequency (0..1 of Nyquist): magnitude and phase in radians.
biquad_response :: proc(c: Biquad_Coefs, normalized: f64) -> (mag, phase: f64) {
	w := math.PI * normalized
	cw, sw := math.cos(w), math.sin(w)
	c2w, s2w := math.cos(2 * w), math.sin(2 * w)
	// H(z) with z^-1 = e^-jw
	nr := c.b0 + c.b1 * cw + c.b2 * c2w
	ni := -(c.b1 * sw + c.b2 * s2w)
	dr := 1 + c.a1 * cw + c.a2 * c2w
	di := -(c.a1 * sw + c.a2 * s2w)
	d := dr * dr + di * di
	hr := (nr * dr + ni * di) / d
	hi := (ni * dr - nr * di) / d
	return math.sqrt_f64(hr * hr + hi * hi), math.atan2(hi, hr)
}
