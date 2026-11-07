package measure

import "core:testing"

CYCLES_PER_MS :: 1000.0

// Samples each 10 ms; the thread is busy for all of a sample where `busy` says so, idle otherwise.
@(private = "file")
samples_of :: proc(busy: proc(ms: f64) -> bool, until_ms: f64) -> []Sample {
	out := make([dynamic]Sample, context.temp_allocator)
	cycles: u64
	for ms := 0.0; ms <= until_ms; ms += 10 {
		append(&out, Sample{ms, cycles})
		if busy(ms) { cycles += u64(10 * CYCLES_PER_MS) }
	}
	return out[:]
}

@(test)
settled_is_the_start_of_the_first_idle_window_after_the_load :: proc(t: ^testing.T) {
	// an idle moment at 300 to 700 ms is before the load event: it does not count
	s := samples_of(proc(ms: f64) -> bool { return ms < 300 || (ms >= 700 && ms < 1500) }, 3000)
	i, ok := settled_find(s, 1000, CYCLES_PER_MS)
	testing.expect(t, ok)
	testing.expect_value(t, s[i].ms, 1500)
}

@(test)
a_short_gap_is_not_settled :: proc(t: ^testing.T) {
	// 300 ms of idle, then work again
	s := samples_of(proc(ms: f64) -> bool { return ms < 1000 || ms >= 1300 }, 2000)
	_, ok := settled_find(s, 500, CYCLES_PER_MS)
	testing.expect(t, !ok)
}

@(test)
a_frame_loop_of_a_few_ms_in_each_sixteen_never_settles :: proc(t: ^testing.T) {
	s := make([dynamic]Sample, context.temp_allocator)
	for n in 0 ..= 300 { append(&s, Sample{f64(n) * 10, u64(n) * 4 * u64(CYCLES_PER_MS)}) }   // 40 % busy
	_, ok := settled_find(s[:], 0, CYCLES_PER_MS)
	testing.expect(t, !ok)
}

@(private = "file")
PICTURE_CELLS :: 1000

@(private = "file")
picture :: proc(painted: int, value: u8 = 200, from := 0) -> []u8 {
	p := make([]u8, PICTURE_CELLS * 4, context.temp_allocator)
	for c in from ..< painted { p[c * 4], p[c * 4 + 1], p[c * 4 + 2] = value, value, value }
	return p
}

@(test)
ready_is_the_first_frame_within_the_share_of_the_last :: proc(t: ^testing.T) {
	frames := []Frame{{0, picture(0)}, {100, picture(500)}, {200, picture(990)}, {300, picture(998)}, {400, picture(1000)}}
	// the frame at 200 is 10 cells off, 1 %; the one at 300 is 2 off, 0.2 %
	ms, moving := visual_ready(frames, 0)
	testing.expect_value(t, ms, 300)
	testing.expect_value(t, moving, 0)
}

@(test)
a_slow_fade_counts_though_each_step_is_small :: proc(t: ^testing.T) {
	// each frame moves all the cells by 10, under VISUAL_CELL_DELTA from the frame before: only the last picture says how far it still is
	frames := make([dynamic]Frame, context.temp_allocator)
	for n in 0 ..= 20 { append(&frames, Frame{f64(n) * 16, picture(PICTURE_CELLS, u8(n * 10))}) }
	ms, _ := visual_ready(frames[:], 0)
	testing.expect_value(t, ms, 19 * 16)
}

@(test)
a_carousel_is_left_out :: proc(t: ^testing.T) {
	// 10 % of the viewport flips each 500 ms for ever; the rest is done at 1 000 ms
	frames := make([dynamic]Frame, context.temp_allocator)
	for n in 0 ..< 12 {
		ms := f64(n) * 500
		p := picture(ms >= 1000 ? 900 : 0)
		if n % 2 == 1 { for c in 900 ..< PICTURE_CELLS { p[c * 4] = 255 } }
		append(&frames, Frame{ms, p})
	}
	ms, moving := visual_ready(frames[:], 1000)
	testing.expect_value(t, ms, 1000)
	testing.expect_value(t, moving, 0.1)
}

@(test)
no_frames_say_nothing :: proc(t: ^testing.T) {
	ms, _ := visual_ready(nil, 0)
	testing.expect_value(t, ms, 0)
}

@(test)
spread_and_noise_of_two_series :: proc(t: ^testing.T) {
	a := spread({1000, 1010, 990, 1005, 995})
	b := spread({1020, 1030, 1025, 1010})
	testing.expect_value(t, a, Spread{1000, 990, 1010})
	testing.expect_value(t, b.median, 1022.5)
	testing.expect_value(t, noise_floor(a, b), 100 * 22.5 / 1000)
	testing.expect_value(t, noise_floor(a, a), 1)
	testing.expect_value(t, noise_floor({}, a), 0)
}

@(test)
a_gain_needs_a_sooner_mark_and_no_more_cpu :: proc(t: ^testing.T) {
	same := Spread{1000, 990, 1010}
	sooner := Spread{900, 890, 910}
	touching := Spread{985, 975, 995}
	more := Spread{1100, 1090, 1110}
	testing.expect_value(t, verdict(same, sooner, same, same, same, same), Verdict.Gain)
	testing.expect_value(t, verdict(same, same, same, sooner, same, same), Verdict.Gain)
	testing.expect_value(t, verdict(same, touching, same, touching, same, same), Verdict.Nothing)
	testing.expect_value(t, verdict(same, sooner, same, sooner, same, more), Verdict.Moved)
	testing.expect_value(t, verdict(same, same, same, same, same, sooner), Verdict.Nothing)   // less CPU alone moves neither mark
}
