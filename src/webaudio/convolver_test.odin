package webaudio

import "core:math"
import "core:testing"

// The planned FFT against the definition, the vector multiply-add against its scalar reference, and the staged
// convolver against a direct convolution, with impulses long enough to reach every stage.

@(private = "file")
Rng :: struct { s: u64 }

@(private = "file")
next :: proc(r: ^Rng) -> f32 {
	r.s ~= r.s << 13
	r.s ~= r.s >> 7
	r.s ~= r.s << 17
	return f32(r.s >> 40) / f32(1 << 24) * 2 - 1   // [-1, 1)
}

@(test)
the_planned_fft_is_the_dft :: proc(t: ^testing.T) {
	r := Rng{99}
	for n := 2; n <= 256; n *= 2 {
		plan := fft_plan_make(n)
		defer fft_plan_destroy(&plan)
		for inverse in ([2]bool{false, true}) {
			xr, xi := make([]f64, n), make([]f64, n)
			defer { delete(xr); delete(xi) }
			for i in 0 ..< n { xr[i], xi[i] = f64(next(&r)), f64(next(&r)) }
			re, im := make([]f64, n), make([]f64, n)
			defer { delete(re); delete(im) }
			copy(re, xr)
			copy(im, xi)
			fft_planned(&plan, re, im, inverse)
			sign := inverse ? 1.0 : -1.0
			worst := 0.0
			for k in 0 ..< n {
				sr, si := 0.0, 0.0
				for j in 0 ..< n {
					a := sign * 2 * math.PI * f64(j * k % n) / f64(n)
					c, s := math.cos(a), math.sin(a)
					sr += xr[j] * c - xi[j] * s
					si += xr[j] * s + xi[j] * c
				}
				worst = max(worst, abs(sr - re[k]), abs(si - im[k]))
			}
			testing.expectf(t, worst < 1e-9 * f64(n), "n %d, inverse %v: off by %v", n, inverse, worst)
		}
	}
}

@(test)
the_vector_multiply_add_is_the_scalar_one :: proc(t: ^testing.T) {
	r := Rng{4242}
	for n in 1 ..= 33 {
		for off in 0 ..< 4 {
			buf := make([]f32, 8 * (n + off))
			defer delete(buf)
			for &v in buf { v = next(&r) * 100 }
			part :: proc(buf: []f32, k, n, off: int) -> []f32 { return buf[k * (len(buf) / 8) + off:][:n] }
			ar, ai := part(buf, 0, n, off), part(buf, 1, n, off)
			br, bi := part(buf, 2, n, off), part(buf, 3, n, off)
			copy(br, ar)
			copy(bi, ai)
			xr, xi, hr, hi := part(buf, 4, n, off), part(buf, 5, n, off), part(buf, 6, n, off), part(buf, 7, n, off)
			conv_cmac(ar, ai, xr, xi, hr, hi)
			conv_cmac_scalar(br, bi, xr, xi, hr, hi)
			same := true
			for i in 0 ..< n {
				// (the same operations in the same order; the slack is for a compiler that fuses a multiply-add)
				if abs(ar[i] - br[i]) > 1e-2 || abs(ai[i] - bi[i]) > 1e-2 { same = false }
			}
			testing.expectf(t, same, "width %d, offset %d", n, off)
		}
	}
}

// Renders `input` (its channels) through a convolver of `ir` into a destination of `out_channels`.
@(private = "file")
convolve :: proc(input, ir: ^Pcm, out_channels, frames: int, max_seconds := MAX_CONVOLVER_SECONDS) -> ^Pcm {
	g := graph_new(RATE, out_channels, true)
	defer graph_destroy(g)
	s := node_create(g, .Buffer_Source)
	c := node_create(g, .Convolver)
	convolver_set(g, c, ir, false, max_seconds)
	node_set_buffer(g, s, input)
	connect(g, s, 0, c, 0)
	connect(g, c, 0, DESTINATION_ID, 0)
	node_start(g, s, 0, 0, -1)
	p := pcm_new(out_channels, frames, RATE)
	offline_render(g, p)
	return p
}

// sum over k of x[n - k] h[k]
@(private = "file")
direct :: proc(x, h: []f32, n: int) -> f64 {
	s := 0.0
	for k in max(0, n - len(x) + 1) ..= min(n, len(h) - 1) { s += f64(x[n - k]) * f64(h[k]) }
	return s
}

@(test)
a_long_impulse_convolves_through_every_stage :: proc(t: ^testing.T) {
	r := Rng{2024}
	// longer than every stage below CONV_MAX_BLOCK together, so the last stage has several blocks
	IR :: 3 * CONV_MAX_BLOCK + 777
	IN :: 2500
	FRAMES :: IN + IR + 300
	for channels in ([3]int{1, 2, 4}) {
		ir := pcm_new(channels, IR, RATE)
		defer pcm_release(ir)
		for c in 0 ..< channels {
			for &v, i in pcm_channel(ir, c) { v = next(&r) * 0.05 * f32(math.exp(-f64(i) / 4000)) }
		}
		in_channels := channels == 1 ? 1 : 2
		input := pcm_new(in_channels, IN, RATE)
		defer pcm_release(input)
		for c in 0 ..< in_channels { for &v in pcm_channel(input, c) { v = next(&r) } }
		out_channels := channels == 1 ? 1 : 2
		p := convolve(input, ir, out_channels, FRAMES)
		defer pcm_release(p)
		for oc in 0 ..< out_channels {
			o := pcm_channel(p, oc)
			// stride through the output (a direct convolution of every frame is slow), and its very start and end
			for n := 0; n < FRAMES; n += n < 600 || n > FRAMES - 600 ? 1 : 97 {
				want: f64
				switch channels {
				case 1: want = direct(pcm_channel(input, 0), pcm_channel(ir, 0), n)
				case 2: want = direct(pcm_channel(input, oc), pcm_channel(ir, oc), n)
				case:
					// true stereo: LL + RL to the left, LR + RR to the right
					want = direct(pcm_channel(input, 0), pcm_channel(ir, oc), n) + direct(pcm_channel(input, 1), pcm_channel(ir, 2 + oc), n)
				}
				if abs(f64(o[n]) - want) > 2e-3 {
					testing.expectf(t, false, "%d impulse channels, output %d, frame %d: %v, want %v", channels, oc, n, o[n], want)
					break
				}
			}
		}
	}
}

@(test)
the_impulse_is_cut_at_max_seconds :: proc(t: ^testing.T) {
	ir := pcm_new(1, 1000, RATE)
	defer pcm_release(ir)
	pcm_channel(ir, 0)[0] = 1
	pcm_channel(ir, 0)[500] = 1   // past the 300 frames kept
	input := pcm_new(1, 200, RATE)
	defer pcm_release(input)
	for &v, i in pcm_channel(input, 0) { v = f32(math.sin(f64(i) * 0.3)) }
	p := convolve(input, ir, 1, 1024, 300 / RATE)
	defer pcm_release(p)
	o, x := pcm_channel(p, 0), pcm_channel(input, 0)
	for i in 0 ..< 1024 {
		want := i < 200 ? x[i] : 0
		if abs(o[i] - want) > 1e-4 {
			testing.expectf(t, false, "frame %d: %v, want %v", i, o[i], want)
			break
		}
	}
}
