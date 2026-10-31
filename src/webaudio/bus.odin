package webaudio

// A block of audio: planar channels of one render quantum, and the mixing rules of the specification
// ("Channel Up-Mixing and Down-Mixing"): speakers for the layouts it names (1, 2, 4, 6), discrete otherwise.

import "core:math"

Channel_Mode :: enum i32 { Max, Clamped_Max, Explicit }
Channel_Interp :: enum i32 { Speakers, Discrete }

Bus :: struct {
	channels: int,
	data:     []f32,    // channels * RENDER_QUANTUM, grown as needed (never shrunk: it comes back)
	silent:   bool,     // known to be all zeros
}

bus_destroy :: proc(b: ^Bus) {
	delete(b.data)
	b^ = {}
}

// A channel of the block.
bus_ch :: #force_inline proc "contextless" (b: ^Bus, c: int) -> []f32 { return b.data[c * RENDER_QUANTUM:][:RENDER_QUANTUM] }

// Gives the block `channels` channels of zeros.
bus_clear :: proc(b: ^Bus, channels: int) {
	if channels * RENDER_QUANTUM > len(b.data) {
		delete(b.data)
		b.data = make([]f32, channels * RENDER_QUANTUM)
	}
	b.channels = channels
	for &v in b.data[:channels * RENDER_QUANTUM] { v = 0 }
	b.silent = true
}

// Gives the block `channels` channels whose content the caller writes in full.
bus_prepare :: proc(b: ^Bus, channels: int) {
	if channels * RENDER_QUANTUM > len(b.data) {
		delete(b.data)
		b.data = make([]f32, channels * RENDER_QUANTUM)
	}
	b.channels = channels
	b.silent = false
}

bus_copy :: proc(dst, src: ^Bus) {
	bus_prepare(dst, src.channels)
	copy(dst.data[:src.channels * RENDER_QUANTUM], src.data[:src.channels * RENDER_QUANTUM])
	dst.silent = src.silent
}

SQRT1_2 :: f32(math.SQRT_TWO / 2)

// Adds `src` to `dst`, mixing it to dst's channels.
bus_sum :: proc(dst, src: ^Bus, interp: Channel_Interp) {
	if src.silent || src.channels == 0 { return }
	dst.silent = false
	n, m := dst.channels, src.channels
	add :: #force_inline proc "contextless" (d, s: []f32, k: f32 = 1) {
		for i in 0 ..< RENDER_QUANTUM { d[i] += s[i] * k }
	}
	if n == m {
		for c in 0 ..< n { add(bus_ch(dst, c), bus_ch(src, c)) }
		return
	}
	if interp == .Discrete {
		for c in 0 ..< min(n, m) { add(bus_ch(dst, c), bus_ch(src, c)) }
		return
	}
	d := proc(b: ^Bus, c: int) -> []f32 { return bus_ch(b, c) }
	switch {
	// up-mixing
	case m == 1 && n == 2:
		add(d(dst, 0), d(src, 0)); add(d(dst, 1), d(src, 0))
	case m == 1 && n == 4:
		add(d(dst, 0), d(src, 0)); add(d(dst, 1), d(src, 0))
	case m == 1 && n == 6:
		add(d(dst, 2), d(src, 0))
	case m == 2 && (n == 4 || n == 6):
		add(d(dst, 0), d(src, 0)); add(d(dst, 1), d(src, 1))
	case m == 4 && n == 6:
		add(d(dst, 0), d(src, 0)); add(d(dst, 1), d(src, 1))
		add(d(dst, 4), d(src, 2)); add(d(dst, 5), d(src, 3))
	// down-mixing
	case n == 1 && m == 2:
		add(d(dst, 0), d(src, 0), 0.5); add(d(dst, 0), d(src, 1), 0.5)
	case n == 1 && m == 4:
		for c in 0 ..< 4 { add(d(dst, 0), d(src, c), 0.25) }
	case n == 1 && m == 6:
		add(d(dst, 0), d(src, 0), SQRT1_2); add(d(dst, 0), d(src, 1), SQRT1_2)
		add(d(dst, 0), d(src, 2)); add(d(dst, 0), d(src, 4), 0.5); add(d(dst, 0), d(src, 5), 0.5)
	case n == 2 && m == 4:
		add(d(dst, 0), d(src, 0), 0.5); add(d(dst, 0), d(src, 2), 0.5)
		add(d(dst, 1), d(src, 1), 0.5); add(d(dst, 1), d(src, 3), 0.5)
	case n == 2 && m == 6:
		add(d(dst, 0), d(src, 0)); add(d(dst, 0), d(src, 2), SQRT1_2); add(d(dst, 0), d(src, 4), SQRT1_2)
		add(d(dst, 1), d(src, 1)); add(d(dst, 1), d(src, 2), SQRT1_2); add(d(dst, 1), d(src, 5), SQRT1_2)
	case n == 4 && m == 6:
		add(d(dst, 0), d(src, 0)); add(d(dst, 0), d(src, 2), SQRT1_2)
		add(d(dst, 1), d(src, 1)); add(d(dst, 1), d(src, 2), SQRT1_2)
		add(d(dst, 2), d(src, 4)); add(d(dst, 3), d(src, 5))
	case:
		for c in 0 ..< min(n, m) { add(bus_ch(dst, c), bus_ch(src, c)) }
	}
}
