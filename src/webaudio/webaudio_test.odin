package webaudio

import "core:math"
import "core:testing"
import "core:time"
import "wb:media"

RATE :: 48000.0
TEST_MAX_BYTES :: 1 << 30

@(private = "file")
near :: proc(t: ^testing.T, got, want: f32, tolerance: f32, what: string, frame: int, loc := #caller_location) -> bool {
	if abs(got - want) <= tolerance { return true }
	testing.expectf(t, false, "%s, frame %d: got %v, want %v", what, frame, got, want, loc = loc)
	return false
}

// Renders `frames` frames offline, on this thread.
@(private = "file")
render :: proc(g: ^Graph, frames: int) -> ^Pcm {
	p := pcm_new(g.channels, frames, g.rate)
	offline_render(g, p)
	return p
}

@(test)
a_sine_oscillator_gives_the_samples_of_a_sine :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	o := node_create(g, .Oscillator)
	connect(g, o, 0, DESTINATION_ID, 0)
	node_start(g, o, 0, 0, -1)
	p := render(g, 1024)
	defer pcm_release(p)
	s := pcm_channel(p, 0)
	for i in 0 ..< 1024 {
		want := f32(math.sin(2 * math.PI * 440 * f64(i) / RATE))
		if !near(t, s[i], want, 1e-5, "sine", i) { break }
	}
}

@(test)
square_and_sawtooth_are_band_limited_with_the_right_shape :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	o := node_create(g, .Oscillator)
	node_set(g, o, .Oscillator_Type, f64(Oscillator_Type.Square))
	connect(g, o, 0, DESTINATION_ID, 0)
	node_start(g, o, 0, 0, -1)
	p := render(g, 4800)
	defer pcm_release(p)
	s := pcm_channel(p, 0)
	// positive for the first half of a period at 440 Hz, negative for the second; the peak is normalized to 1
	period := RATE / 440
	peak: f32
	for i in 0 ..< 4800 {
		peak = max(peak, abs(s[i]))
		phase := f64(i) / period
		phase -= math.floor(phase)
		if phase > 0.05 && phase < 0.45 { testing.expectf(t, s[i] > 0.5, "frame %d: %v in the high half", i, s[i]) }
		if phase > 0.55 && phase < 0.95 { testing.expectf(t, s[i] < -0.5, "frame %d: %v in the low half", i, s[i]) }
	}
	testing.expectf(t, peak <= 1.0001, "the peak is %v", peak)
	// a high note has no partial above Nyquist: its table has few of them
	w := wave_basic(.Square)
	defer wave_release(w)
	high := wave_table(w, 10000, RATE)
	testing.expect(t, len(high) == WAVE_TABLE_SIZE)
}

@(test)
a_custom_periodic_wave_is_its_series :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	o := node_create(g, .Oscillator)
	// sin(x) + 0.5 cos(2x), not normalized
	real := []f32{0, 0, 0.5}
	imag := []f32{0, 1, 0}
	node_set_wave(g, o, wave_new(real, imag, false))
	connect(g, o, 0, DESTINATION_ID, 0)
	node_start(g, o, 0, 0, -1)
	p := render(g, 512)
	defer pcm_release(p)
	s := pcm_channel(p, 0)
	for i in 0 ..< 512 {
		x := 2 * math.PI * 440 * f64(i) / RATE
		if !near(t, s[i], f32(math.sin(x) + 0.5 * math.cos(2 * x)), 2e-3, "wave", i) { break }
	}
}

// A constant source through a gain whose automation the proc sets: the output is the gain's curve.
@(private = "file")
gain_curve :: proc(frames: int, set: proc(g: ^Graph, gain: i32)) -> ^Pcm {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	c := node_create(g, .Constant)
	gain := node_create(g, .Gain)
	connect(g, c, 0, gain, 0)
	connect(g, gain, 0, DESTINATION_ID, 0)
	node_start(g, c, 0, 0, -1)
	set(g, gain)
	return render(g, frames)
}

@(test)
a_linear_ramp_is_a_line :: proc(t: ^testing.T) {
	p := gain_curve(4800, proc(g: ^Graph, gain: i32) {
		param_add_event(g, gain, 0, .Set_Value, 0, 0, 0, nil)
		param_add_event(g, gain, 0, .Linear_Ramp, 0.05, 1, 0, nil)
	})
	defer pcm_release(p)
	s := pcm_channel(p, 0)
	for i in 0 ..< 2400 {
		if !near(t, s[i], f32(i) / 2400, 1e-4, "ramp", i) { break }
	}
	near(t, s[2400], 1, 1e-6, "after", 2400)
	near(t, s[4000], 1, 1e-6, "after", 4000)
}

@(test)
an_exponential_ramp_is_an_exponential :: proc(t: ^testing.T) {
	p := gain_curve(4800, proc(g: ^Graph, gain: i32) {
		param_add_event(g, gain, 0, .Set_Value, 0, 0.01, 0, nil)
		param_add_event(g, gain, 0, .Exponential_Ramp, 0.1, 1, 0, nil)
	})
	defer pcm_release(p)
	s := pcm_channel(p, 0)
	for i in 0 ..< 4800 {
		want := f32(0.01 * math.pow(f64(100), f64(i) / 4800))
		if !near(t, s[i], want, 1e-4, "exponential", i) { break }
	}
}

@(test)
set_target_approaches_with_its_time_constant :: proc(t: ^testing.T) {
	p := gain_curve(4800, proc(g: ^Graph, gain: i32) {
		param_add_event(g, gain, 0, .Set_Value, 0, 1, 0, nil)
		param_add_event(g, gain, 0, .Set_Target, 0.01, 0, 0.02, nil)
	})
	defer pcm_release(p)
	s := pcm_channel(p, 0)
	near(t, s[100], 1, 1e-6, "before", 100)
	for i in 480 ..< 4800 {
		want := f32(math.exp(-(f64(i) / RATE - 0.01) / 0.02))
		if !near(t, s[i], want, 1e-4, "target", i) { break }
	}
}

@(test)
a_value_curve_interpolates_and_holds_its_end :: proc(t: ^testing.T) {
	p := gain_curve(4800, proc(g: ^Graph, gain: i32) {
		curve := []f32{0, 1, 0.5}
		testing_ok := param_add_event(g, gain, 0, .Set_Curve, 0, 0, 0.05, curve)
		assert(testing_ok)
		assert(!param_add_event(g, gain, 0, .Set_Value, 0.01, 1, 0, nil), "an event inside a curve is refused")
	})
	defer pcm_release(p)
	s := pcm_channel(p, 0)
	near(t, s[0], 0, 1e-5, "curve", 0)
	near(t, s[1200], 1, 1e-3, "curve", 1200)
	near(t, s[600], 0.5, 1e-3, "curve", 600)
	near(t, s[1800], 0.75, 1e-3, "curve", 1800)
	near(t, s[3000], 0.5, 1e-5, "held", 3000)
}

@(test)
cancelling_takes_back_what_is_scheduled :: proc(t: ^testing.T) {
	p := gain_curve(4800, proc(g: ^Graph, gain: i32) {
		param_add_event(g, gain, 0, .Set_Value, 0, 0.25, 0, nil)
		param_add_event(g, gain, 0, .Set_Value, 0.05, 0.75, 0, nil)
		param_cancel_events(g, gain, 0, 0.04, false)
	})
	defer pcm_release(p)
	near(t, pcm_channel(p, 0)[4000], 0.25, 1e-6, "kept", 4000)
}

@(test)
cancel_and_hold_stops_a_ramp_where_it_is :: proc(t: ^testing.T) {
	p := gain_curve(4800, proc(g: ^Graph, gain: i32) {
		param_add_event(g, gain, 0, .Set_Value, 0, 0, 0, nil)
		param_add_event(g, gain, 0, .Linear_Ramp, 0.1, 1, 0, nil)
		param_cancel_events(g, gain, 0, 0.05, true)
	})
	defer pcm_release(p)
	s := pcm_channel(p, 0)
	near(t, s[1200], 0.25, 1e-3, "the same ramp", 1200)
	near(t, s[3000], 0.5, 1e-3, "held", 3000)
	near(t, s[4700], 0.5, 1e-3, "held", 4700)
}

@(test)
a_k_rate_param_holds_for_the_quantum :: proc(t: ^testing.T) {
	p := gain_curve(512, proc(g: ^Graph, gain: i32) {
		param_set_rate(g, gain, 0, false)
		param_add_event(g, gain, 0, .Set_Value, 0, 0, 0, nil)
		param_add_event(g, gain, 0, .Linear_Ramp, 512 / RATE, 1, 0, nil)
	})
	defer pcm_release(p)
	s := pcm_channel(p, 0)
	for i in 0 ..< 128 { near(t, s[i], 0, 1e-6, "first quantum", i) }
	for i in 128 ..< 256 { near(t, s[i], 0.25, 1e-4, "second quantum", i) }
}

@(test)
a_param_connection_adds_to_the_value :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	one := node_create(g, .Constant)
	lfo := node_create(g, .Constant)
	gain := node_create(g, .Gain)
	connect(g, one, 0, gain, 0)
	connect_param(g, lfo, 0, gain, 0)
	connect(g, gain, 0, DESTINATION_ID, 0)
	node_start(g, one, 0, 0, -1)
	node_start(g, lfo, 0, 0, -1)
	p := render(g, 128)
	defer pcm_release(p)
	near(t, pcm_channel(p, 0)[10], 2, 1e-6, "1 (its value) + 1 (the connection)", 10)
}

@(private = "file")
reference_response :: proc(b0, b1, b2, a0, a1, a2, w: f64) -> f64 {
	// |H(e^jw)| from the unnormalized coefficients
	nr := b0 + b1 * math.cos(w) + b2 * math.cos(2 * w)
	ni := b1 * math.sin(w) + b2 * math.sin(2 * w)
	dr := a0 + a1 * math.cos(w) + a2 * math.cos(2 * w)
	di := a1 * math.sin(w) + a2 * math.sin(2 * w)
	return math.sqrt_f64((nr * nr + ni * ni) / (dr * dr + di * di))
}

@(test)
a_biquad_has_the_response_of_the_cookbook :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	b := node_create(g, .Biquad)
	// lowpass 1 kHz, Q 3 dB
	param_set_value(g, b, 0, 1000)
	param_set_value(g, b, 2, 3)
	w0 := 2 * math.PI * 1000 / RATE
	alpha := math.sin(w0) / (2 * math.pow(10, 3.0 / 20))
	cw := math.cos(w0)
	frequencies := []f32{100, 500, 1000, 2000, 10000, 24000}
	mag, phase: [6]f32
	biquad_frequency_response(g, b, frequencies, mag[:], phase[:])
	for hz, i in frequencies {
		w := 2 * math.PI * f64(hz) / RATE
		want := reference_response((1 - cw) / 2, 1 - cw, (1 - cw) / 2, 1 + alpha, -2 * cw, 1 - alpha, w)
		testing.expectf(t, abs(f64(mag[i]) - want) < 1e-4, "%v Hz: %v, want %v", hz, mag[i], want)
	}
	// at the cutoff the magnitude is the Q in linear terms
	testing.expectf(t, abs(mag[2] - f32(math.pow(10, 3.0 / 20))) < 1e-3, "at the cutoff: %v", mag[2])
	// peaking: the gain at its centre
	c := biquad_coefs(.Peaking, 1000, 2, 6, RATE)
	m, _ := biquad_response(c, 1000.0 / (RATE / 2))
	testing.expectf(t, abs(m - math.pow(10, 6.0 / 20)) < 1e-6, "peaking at the centre: %v", m)
	// outside 0..Nyquist: NaN
	out := []f32{-1, 30000}
	mag2, phase2: [2]f32
	biquad_frequency_response(g, b, out, mag2[:], phase2[:])
	testing.expect(t, math.is_nan(mag2[0]) && math.is_nan(phase2[1]))
}

@(test)
a_biquad_filters_as_its_difference_equation_says :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	src := node_create(g, .Buffer_Source)
	b := node_create(g, .Biquad)
	node_set(g, b, .Filter_Type, f64(Biquad_Type.Highpass))
	param_set_value(g, b, 0, 2000)
	connect(g, src, 0, b, 0)
	connect(g, b, 0, DESTINATION_ID, 0)
	impulse := pcm_new(1, 1024, RATE)
	defer pcm_release(impulse)
	pcm_channel(impulse, 0)[0] = 1
	node_set_buffer(g, src, impulse)
	node_start(g, src, 0, 0, -1)
	p := render(g, 512)
	defer pcm_release(p)
	s := pcm_channel(p, 0)
	c := biquad_coefs(.Highpass, 2000, 1, 0, RATE)
	y1, y2, x1, x2: f64
	for i in 0 ..< 512 {
		x := i == 0 ? 1.0 : 0.0
		y := c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
		x2, x1, y2, y1 = x1, x, y1, y
		if !near(t, s[i], f32(y), 1e-5, "impulse response", i) { break }
	}
}

@(test)
a_buffer_source_plays_loops_and_changes_rate :: proc(t: ^testing.T) {
	buffer := pcm_new(1, 256, RATE)
	defer pcm_release(buffer)
	for &v, i in pcm_channel(buffer, 0) { v = f32(i) / 256 }
	{
		g := graph_new(RATE, 1, true)
		defer graph_destroy(g)
		s := node_create(g, .Buffer_Source)
		node_set_buffer(g, s, buffer)
		connect(g, s, 0, DESTINATION_ID, 0)
		node_start(g, s, 100 / RATE, 0, -1)
		p := render(g, 512)
		defer pcm_release(p)
		o := pcm_channel(p, 0)
		near(t, o[99], 0, 0, "before the start", 99)
		near(t, o[100], 0, 1e-6, "the first sample", 100)
		near(t, o[300], 200.0 / 256, 1e-6, "as it is", 300)
		near(t, o[356], 0, 0, "after the end", 356)
		evs := take_events(g)
		defer delete(evs)
		testing.expect(t, len(evs) == 1 && evs[0].type == .Ended && evs[0].node == s, "ended, once")
	}
	{
		g := graph_new(RATE, 1, true)
		defer graph_destroy(g)
		s := node_create(g, .Buffer_Source)
		node_set_buffer(g, s, buffer)
		node_set(g, s, .Loop, 1)
		node_set(g, s, .Loop_Start, 64 / RATE)
		node_set(g, s, .Loop_End, 128 / RATE)
		connect(g, s, 0, DESTINATION_ID, 0)
		node_start(g, s, 0, 0, -1)
		p := render(g, 512)
		defer pcm_release(p)
		o := pcm_channel(p, 0)
		near(t, o[127], 127.0 / 256, 1e-6, "to the loop's end", 127)
		near(t, o[128], 64.0 / 256, 1e-6, "back to its start", 128)
		near(t, o[192], 64.0 / 256, 1e-6, "again", 192)
	}
	{
		g := graph_new(RATE, 1, true)
		defer graph_destroy(g)
		s := node_create(g, .Buffer_Source)
		node_set_buffer(g, s, buffer)
		param_set_value(g, s, 0, 2)      // playbackRate
		connect(g, s, 0, DESTINATION_ID, 0)
		node_start(g, s, 0, 0, -1)
		p := render(g, 256)
		defer pcm_release(p)
		o := pcm_channel(p, 0)
		near(t, o[50], 100.0 / 256, 1e-6, "twice as fast", 50)
		near(t, o[130], 0, 0, "over in half the time", 130)
	}
	{
		g := graph_new(RATE, 1, true)
		defer graph_destroy(g)
		s := node_create(g, .Buffer_Source)
		node_set_buffer(g, s, buffer)
		param_set_value(g, s, 1, 1200)   // detune: an octave
		connect(g, s, 0, DESTINATION_ID, 0)
		node_start(g, s, 0, 0, -1)
		p := render(g, 128)
		defer pcm_release(p)
		near(t, pcm_channel(p, 0)[50], 100.0 / 256, 1e-5, "an octave up", 50)
	}
}

@(test)
delays_delay_and_a_cycle_needs_one :: proc(t: ^testing.T) {
	impulse := pcm_new(1, 1, RATE)
	defer pcm_release(impulse)
	pcm_channel(impulse, 0)[0] = 1
	{
		g := graph_new(RATE, 1, true)
		defer graph_destroy(g)
		s := node_create(g, .Buffer_Source)
		d := node_create(g, .Delay, 1)
		param_set_value(g, d, 0, 50 / RATE)
		node_set_buffer(g, s, impulse)
		connect(g, s, 0, d, 0)
		connect(g, d, 0, DESTINATION_ID, 0)
		node_start(g, s, 0, 0, -1)
		p := render(g, 256)
		defer pcm_release(p)
		o := pcm_channel(p, 0)
		near(t, o[50], 1, 1e-4, "50 frames later", 50)
		near(t, o[49], 0, 1e-4, "not before", 49)
	}
	{
		// feedback: delay -> gain 0.5 -> delay, the delay shorter than a quantum: at least a quantum per turn
		g := graph_new(RATE, 1, true)
		defer graph_destroy(g)
		s := node_create(g, .Buffer_Source)
		d := node_create(g, .Delay, 1)
		fb := node_create(g, .Gain)
		param_set_value(g, d, 0, 256 / RATE)
		param_set_value(g, fb, 0, 0.5)
		node_set_buffer(g, s, impulse)
		connect(g, s, 0, d, 0)
		connect(g, d, 0, fb, 0)
		connect(g, fb, 0, d, 0)
		connect(g, d, 0, DESTINATION_ID, 0)
		node_start(g, s, 0, 0, -1)
		p := render(g, 1024)
		defer pcm_release(p)
		o := pcm_channel(p, 0)
		near(t, o[256], 1, 1e-4, "first echo", 256)
		near(t, o[512], 0.5, 1e-4, "second echo", 512)
		near(t, o[768], 0.25, 1e-4, "third echo", 768)
	}
	{
		// a cycle with no delay is silent
		g := graph_new(RATE, 1, true)
		defer graph_destroy(g)
		c := node_create(g, .Constant)
		a := node_create(g, .Gain)
		b := node_create(g, .Gain)
		connect(g, c, 0, a, 0)
		connect(g, a, 0, b, 0)
		connect(g, b, 0, a, 0)
		connect(g, b, 0, DESTINATION_ID, 0)
		node_start(g, c, 0, 0, -1)
		p := render(g, 256)
		defer pcm_release(p)
		near(t, pcm_channel(p, 0)[200], 0, 0, "muted", 200)
	}
}

@(test)
panners_and_channel_nodes_route_as_specified :: proc(t: ^testing.T) {
	{
		g := graph_new(RATE, 2, true)
		defer graph_destroy(g)
		c := node_create(g, .Constant)
		pan := node_create(g, .Stereo_Panner)
		param_set_value(g, pan, 0, 0)
		connect(g, c, 0, pan, 0)
		connect(g, pan, 0, DESTINATION_ID, 0)
		node_start(g, c, 0, 0, -1)
		p := render(g, 128)
		defer pcm_release(p)
		// the centre: equal power on both
		near(t, pcm_channel(p, 0)[10], SQRT1_2, 1e-5, "left", 10)
		near(t, pcm_channel(p, 1)[10], SQRT1_2, 1e-5, "right", 10)
	}
	{
		g := graph_new(RATE, 2, true)
		defer graph_destroy(g)
		c := node_create(g, .Constant)
		pan := node_create(g, .Panner)
		param_set_value(g, pan, 0, 1)    // to the right of the listener, at the reference distance
		connect(g, c, 0, pan, 0)
		connect(g, pan, 0, DESTINATION_ID, 0)
		node_start(g, c, 0, 0, -1)
		p := render(g, 128)
		defer pcm_release(p)
		near(t, pcm_channel(p, 0)[10], 0, 1e-5, "left", 10)
		near(t, pcm_channel(p, 1)[10], 1, 1e-5, "right", 10)
	}
	{
		// split a stereo signal and merge it the other way round
		g := graph_new(RATE, 2, true)
		defer graph_destroy(g)
		l := node_create(g, .Constant)
		r := node_create(g, .Constant)
		param_set_value(g, r, 0, 0.5)
		merge := node_create(g, .Merger, 2)
		split := node_create(g, .Splitter, 2)
		swap := node_create(g, .Merger, 2)
		connect(g, l, 0, merge, 0)
		connect(g, r, 0, merge, 1)
		connect(g, merge, 0, split, 0)
		connect(g, split, 0, swap, 1)
		connect(g, split, 1, swap, 0)
		connect(g, swap, 0, DESTINATION_ID, 0)
		node_start(g, l, 0, 0, -1)
		node_start(g, r, 0, 0, -1)
		p := render(g, 128)
		defer pcm_release(p)
		near(t, pcm_channel(p, 0)[10], 0.5, 1e-6, "swapped left", 10)
		near(t, pcm_channel(p, 1)[10], 1, 1e-6, "swapped right", 10)
	}
}

@(test)
mixing_follows_the_rules :: proc(t: ^testing.T) {
	a, b: Bus
	defer { bus_destroy(&a); bus_destroy(&b) }
	bus_clear(&a, 2)
	a.silent = false
	for &v in bus_ch(&a, 0) { v = 1 }
	for &v in bus_ch(&a, 1) { v = 0.5 }
	bus_clear(&b, 1)
	bus_sum(&b, &a, .Speakers)
	near(t, bus_ch(&b, 0)[0], 0.75, 1e-6, "stereo to mono: (L + R) / 2", 0)
	bus_clear(&b, 6)
	bus_sum(&b, &a, .Speakers)
	near(t, bus_ch(&b, 1)[0], 0.5, 1e-6, "stereo to 5.1: R", 0)
	near(t, bus_ch(&b, 2)[0], 0, 0, "stereo to 5.1: no centre", 0)
	bus_clear(&b, 1)
	bus_sum(&b, &a, .Discrete)
	near(t, bus_ch(&b, 0)[0], 1, 1e-6, "discrete: the first channel", 0)
}

@(test)
the_compressor_reduces_and_the_shaper_shapes :: proc(t: ^testing.T) {
	{
		g := graph_new(RATE, 1, true)
		defer graph_destroy(g)
		c := node_create(g, .Constant)
		k := node_create(g, .Compressor)
		connect(g, c, 0, k, 0)
		connect(g, k, 0, DESTINATION_ID, 0)
		node_start(g, c, 0, 0, -1)
		p := render(g, 4800)
		defer pcm_release(p)
		r := node_get(g, k, .Reduction)
		testing.expectf(t, r < -5 && r > -60, "reduction %v dB at full scale", r)
		testing.expect(t, pcm_channel(p, 0)[10] == 0, "the look-ahead delays by 6 ms")
		testing.expect(t, pcm_channel(p, 0)[4799] > 0)
	}
	{
		g := graph_new(RATE, 1, true)
		defer graph_destroy(g)
		c := node_create(g, .Constant)
		param_set_value(g, c, 0, 0.5)
		w := node_create(g, .Wave_Shaper)
		curve := []f32{-1, 0, 2}
		shaper_set_curve(g, w, curve)
		connect(g, c, 0, w, 0)
		connect(g, w, 0, DESTINATION_ID, 0)
		node_start(g, c, 0, 0, -1)
		p := render(g, 128)
		defer pcm_release(p)
		near(t, pcm_channel(p, 0)[10], 1, 1e-6, "x = 0.5: half way between 0 and 2", 10)
	}
}

@(test)
the_analyser_sees_the_note :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	o := node_create(g, .Oscillator)
	param_set_value(g, o, 0, 3000)
	a := node_create(g, .Analyser)
	node_set(g, a, .Smoothing, 0)
	connect(g, o, 0, a, 0)     // (nothing connected after it: it listens all the same)
	node_start(g, o, 0, 0, -1)
	p := render(g, 4096)
	defer pcm_release(p)
	freq: [1024]f32
	testing.expect_value(t, analyser_read(g, a, .Float_Frequency, ([^]u8)(&freq[0])[:len(freq) * 4]), 1024)
	best := 0
	for v, i in freq { if v > freq[best] { best = i } }
	testing.expect_value(t, best, 128)    // 3000 Hz / (48000 Hz / 2048)
	wave: [2048]f32
	analyser_read(g, a, .Float_Time, ([^]u8)(&wave[0])[:len(wave) * 4])
	peak: f32
	for v in wave { peak = max(peak, abs(v)) }
	near(t, peak, 1, 0.01, "the wave as it is", 0)
	b: [1024]u8
	testing.expect_value(t, analyser_read(g, a, .Byte_Frequency, b[:]), 1024)
	testing.expect(t, b[best] > 200, "the note is near the top of the bytes")
}

@(test)
the_convolver_convolves :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	s := node_create(g, .Buffer_Source)
	c := node_create(g, .Convolver)
	input := pcm_new(1, 400, RATE)
	defer pcm_release(input)
	for &v, i in pcm_channel(input, 0) { v = f32(math.sin(f64(i) * 0.1)) }
	// an impulse response: 1 at 0, 0.5 at 300 (beyond one partition)
	ir := pcm_new(1, 301, RATE)
	defer pcm_release(ir)
	pcm_channel(ir, 0)[0] = 1
	pcm_channel(ir, 0)[300] = 0.5
	convolver_set(g, c, ir, false)
	node_set_buffer(g, s, input)
	connect(g, s, 0, c, 0)
	connect(g, c, 0, DESTINATION_ID, 0)
	node_start(g, s, 0, 0, -1)
	p := render(g, 1024)
	defer pcm_release(p)
	o := pcm_channel(p, 0)
	x := pcm_channel(input, 0)
	for i in 0 ..< 800 {
		want: f32
		if i < 400 { want += x[i] }
		if i >= 300 && i < 700 { want += 0.5 * x[i - 300] }
		if !near(t, o[i], want, 1e-3, "convolution", i) { break }
	}
}

@(test)
released_nodes_leave_the_graph_once_silent :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	buffer := pcm_new(1, 64, RATE)
	defer pcm_release(buffer)
	s := node_create(g, .Buffer_Source)
	gain := node_create(g, .Gain)
	node_set_buffer(g, s, buffer)
	connect(g, s, 0, gain, 0)
	connect(g, gain, 0, DESTINATION_ID, 0)
	node_start(g, s, 0, 0, -1)
	node_release(g, s)
	node_release(g, gain)
	// still playing: they stay
	sync_render :: proc(g: ^Graph) { render_quantum(g) }
	testing.expect(t, node_of(g, s) != nil, "still there before it plays")
	sync_render(g)   // (the buffer ends in this quantum)
	sync_render(g)
	testing.expect(t, node_of(g, s) == nil, "the source went")
	testing.expect(t, node_of(g, gain) == nil, "the gain went with it")
	evs := take_events(g)
	defer delete(evs)
	testing.expect_value(t, len(evs), 1)
	// a released id can be used again
	again := node_create(g, .Gain)
	testing.expect(t, again == s || again == gain)
}

@(test)
disconnecting_undoes_connecting :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	c := node_create(g, .Constant)
	gain := node_create(g, .Gain)
	connect(g, c, 0, gain, 0)
	connect(g, c, 0, gain, 0)    // (the same one)
	connect_param(g, c, 0, gain, 0)
	connect(g, gain, 0, DESTINATION_ID, 0)
	testing.expect_value(t, disconnect(g, c, -1, gain, -1, false), 1)
	testing.expect_value(t, disconnect(g, c, -1, gain, -1, false), 0)
	testing.expect_value(t, disconnect(g, c, -1, gain, 0, true), 1)
	testing.expect_value(t, disconnect(g, gain, -1, -1, -1, false), 1)
	testing.expect_value(t, disconnect(g, gain, -1, -1, -1, false), 0)
}

@(private = "file")
wav_of :: proc(channels, rate, frames: int, sample: proc(c, i: int) -> i16) -> []u8 {
	data_size := channels * frames * 2
	b := make([]u8, 44 + data_size, context.temp_allocator)
	put32 :: proc(b: []u8, v: int) { b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }
	put16 :: proc(b: []u8, v: int) { b[0], b[1] = u8(v), u8(v >> 8) }
	copy(b, "RIFF"); put32(b[4:], 36 + data_size); copy(b[8:], "WAVEfmt ")
	put32(b[16:], 16); put16(b[20:], 1); put16(b[22:], channels); put32(b[24:], rate)
	put32(b[28:], rate * channels * 2); put16(b[32:], channels * 2); put16(b[34:], 16)
	copy(b[36:], "data"); put32(b[40:], data_size)
	for i in 0 ..< frames {
		for c in 0 ..< channels { put16(b[44 + (i * channels + c) * 2:], int(sample(c, i))) }
	}
	return b
}

@(test)
decoding_a_wav_gives_its_samples :: proc(t: ^testing.T) {
	data := wav_of(2, 48000, 1000, proc(c, i: int) -> i16 { return c == 0 ? i16(i) : i16(-i) })
	p := decode_audio(data, RATE, TEST_MAX_BYTES)
	testing.expect(t, p != nil)
	if p == nil { return }
	defer pcm_release(p)
	testing.expect_value(t, p.channels, 2)
	testing.expect_value(t, p.length, 1000)
	near(t, pcm_channel(p, 0)[500], 500.0 / 32768, 1e-6, "left", 500)
	near(t, pcm_channel(p, 1)[500], -500.0 / 32768, 1e-6, "right", 500)
	testing.expect(t, decode_audio([]u8{1, 2, 3, 4, 5, 6, 7, 8}, RATE, TEST_MAX_BYTES) == nil, "not audio")
	testing.expect(t, decode_audio(nil, RATE, TEST_MAX_BYTES) == nil, "nothing")
}

@(test)
decoding_converts_to_the_context_rate :: proc(t: ^testing.T) {
	data := wav_of(1, 24000, 2400, proc(c, i: int) -> i16 { return i16(20000 * math.sin(2 * math.PI * 440 * f64(i) / 24000)) })
	p := decode_audio(data, RATE, TEST_MAX_BYTES)
	testing.expect(t, p != nil)
	if p == nil { return }
	defer pcm_release(p)
	testing.expect_value(t, p.length, 4800)
	testing.expect_value(t, p.rate, RATE)
	s := pcm_channel(p, 0)
	amp := 20000.0 / 32768
	for i in 200 ..< 4600 {
		want := f32(amp * math.sin(2 * math.PI * 440 * f64(i) / RATE))
		if !near(t, s[i], want, 2e-3, "converted", i) { break }
	}
}

@(test)
a_running_context_follows_the_output_and_stops_with_it :: proc(t: ^testing.T) {
	g := graph_new(RATE, 2, false)
	defer graph_destroy(g)
	g.thread.open = media.null_audio_open
	o := node_create(g, .Oscillator)
	connect(g, o, 0, DESTINATION_ID, 0)
	node_start(g, o, 0, 0, -1)
	testing.expect(t, graph_time(g) == 0, "suspended: time stands still")
	graph_resume(g, 2400)
	testing.expect(t, graph_state(g) == .Running)
	time.sleep(200 * time.Millisecond)
	now := graph_time(g)
	// the clock of the output, plus what is queued ahead (50 ms), within what a busy machine allows
	testing.expectf(t, now > 0.1 && now < 1, "after 200 ms the context is at %v s", now)
	graph_suspend(g)
	stopped := graph_time(g)
	time.sleep(30 * time.Millisecond)
	testing.expect(t, graph_time(g) == stopped, "suspended: time stands still")
	graph_resume(g, 2400)
	time.sleep(30 * time.Millisecond)
	testing.expect(t, graph_time(g) > stopped, "resumed: on it goes")
	graph_close(g)
	testing.expect(t, graph_state(g) == .Closed)
	evs := take_events(g)
	defer delete(evs)
	testing.expect_value(t, len(evs), 4)     // running, suspended, running, closed
}

@(test)
closing_a_page_with_a_context_running_leaves_no_thread :: proc(t: ^testing.T) {
	g := graph_new(RATE, 2, false)
	g.thread.open = media.null_audio_open
	graph_resume(g, 2400)
	time.sleep(10 * time.Millisecond)
	graph_destroy(g)    // (joins the thread; a leak or a hang shows here)
}

// A Wasm module of a page calls the same functions as web_audio.js, with no script to check its numbers.
@(test)
absurd_numbers_change_nothing :: proc(t: ^testing.T) {
	g := graph_new(RATE, 1, true)
	defer graph_destroy(g)
	nan := math.nan_f64()
	testing.expect_value(t, node_create(g, .Destination), i32(-1))
	testing.expect_value(t, node_create(g, .Splitter, 0), i32(-1))
	testing.expect_value(t, node_create(g, .Merger, 1e9), i32(-1))
	testing.expect_value(t, node_create(g, .Delay, -1), i32(-1))
	testing.expect_value(t, node_create(g, .Delay, 1e300), i32(-1))
	testing.expect_value(t, node_create(g, .Script_Processor, 100, 0x0101), i32(-1))
	node_release(g, DESTINATION_ID)
	node_release(g, LISTENER_ID)
	o := node_create(g, .Oscillator)
	gain := node_create(g, .Gain)
	a := node_create(g, .Analyser)
	c := node_create(g, .Convolver)
	connect(g, o, 0, gain, 0)
	connect(g, gain, 0, a, 0)
	connect(g, a, 0, c, 0)
	connect(g, c, 0, DESTINATION_ID, 0)
	testing.expect(t, !connect(g, o, 5, gain, 0), "no such output")
	testing.expect(t, !connect(g, o, 0, gain, 5), "no such input")
	testing.expect(t, !connect_param(g, o, 0, gain, 5), "no such param")
	node_start(g, o, nan, 0, -1)
	node_start(g, o, 0, 0, -1)
	node_stop(g, o, nan)
	node_set(g, a, .Fft_Size, 100)     // (not a power of 2: it stays as it was)
	param_add_event(g, gain, 0, .Set_Value, nan, 1, 0, nil)
	param_add_event(g, gain, 0, .Set_Curve, 0, 1, 1, []f32{1})
	param_add_event(g, gain, 0, .Set_Curve, 0, 1, nan, []f32{1, 2})
	param_set_value(g, gain, 0, f32(nan))
	three := pcm_new(3, 8, RATE)      // (an impulse of 3 channels is none)
	defer pcm_release(three)
	convolver_set(g, c, three, true)
	p := render(g, 256)
	defer pcm_release(p)
	testing.expect(t, node_of(g, DESTINATION_ID) != nil, "the destination stays")
	out: [8]f32
	testing.expect_value(t, analyser_read(g, a, .Float_Frequency, ([^]u8)(&out[0])[:len(out) * 4]), 8)
}

@(test)
offline_rendering_on_its_thread_ends_with_the_result :: proc(t: ^testing.T) {
	g := graph_new(RATE, 2, true)
	defer graph_destroy(g)
	c := node_create(g, .Constant)
	connect(g, c, 0, DESTINATION_ID, 0)
	node_start(g, c, 0, 0, -1)
	testing.expect(t, offline_start(g, 1000))
	deadline := time.tick_now()
	for graph_state(g) != .Closed && time.tick_since(deadline) < 5 * time.Second { time.sleep(time.Millisecond) }
	p := offline_take_result(g)
	testing.expect(t, p != nil)
	if p == nil { return }
	defer pcm_release(p)
	testing.expect_value(t, p.length, 1000)
	near(t, pcm_channel(p, 1)[999], 1, 1e-6, "mono to stereo", 999)
}
