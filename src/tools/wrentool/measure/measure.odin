// What `wrentool replay` reads from a load, as plain functions of what it sampled: when the window thread settled, when the first viewport was ready, what a series
// of loads says. The rules are the constants below; docs/testing.md says them in words.
package measure

import "core:slice"

// Settled: the first moment after the load event from which the window thread stays idle for SETTLED_IDLE_MS, idle meaning at most SETTLED_BUSY_SHARE of it on a processor.
// Not zero: once their work is done cnn.com and theverge.com keep the thread 15 to 20 % busy for as long as they stay open, with frames and timers that are no part of a
// load (round 51 of docs/performance.md), and it never goes below that.
SETTLED_IDLE_MS :: 500.0
SETTLED_BUSY_SHARE :: 0.25

// Visually ready: the first frame from which the viewport stays within VISUAL_CHANGE_SHARE of its last picture, cell by cell, a cell being a pixel of the
// frame the timeline scaled down and differing when a channel moves by more than VISUAL_CELL_DELTA. Against the last picture and not the frame before: a slow
// fade is many small steps, each under any threshold, and still a change.
VISUAL_CHANGE_SHARE :: 0.005
VISUAL_CELL_DELTA :: 16
// A carousel, a video, a ticker: a cell that changes VISUAL_MOVING_CHANGES times or more after the load event, those changes VISUAL_MOVING_GAP_MS apart at least, is moving and left
// out of the comparison. After the load event: during a load a page moves under its own arrival, and that is what is being measured. The gap keeps what arrives in a
// burst (a font, a late sheet) from looking like motion.
VISUAL_MOVING_CHANGES :: 3
VISUAL_MOVING_GAP_MS :: 300.0

// The window thread's counter at a moment of the load.
Sample :: struct {
	ms:     f64,
	cycles: u64,
}

// `samples` from the start of the navigation, `cycles_per_ms` the counter's rate. The moment the idle window starts and its index in `samples`, the first at or after `from_ms`.
settled_find :: proc(samples: []Sample, from_ms, cycles_per_ms: f64) -> (index: int, ok: bool) {
	end := 0
	for i in 0 ..< len(samples) {
		if samples[i].ms < from_ms { continue }
		end = max(end, i)
		for end < len(samples) && samples[end].ms - samples[i].ms < SETTLED_IDLE_MS { end += 1 }
		if end == len(samples) { return 0, false }
		busy := f64(samples[end].cycles - samples[i].cycles) / cycles_per_ms
		if busy > SETTLED_BUSY_SHARE * (samples[end].ms - samples[i].ms) { continue }
		// (a window can hold the last of the work within its share: settled is when that has ended)
		index = i
		for index + 1 < end && f64(samples[index + 1].cycles - samples[index].cycles) / cycles_per_ms > SETTLED_BUSY_SHARE * (samples[index + 1].ms - samples[index].ms) { index += 1 }
		return index, true
	}
	return 0, false
}

Frame :: struct {
	ms:     f64,
	pixels: []u8,   // RGBA, every frame of a load the same size
}

@(private)
differs :: #force_inline proc(a, b: []u8, i: int) -> bool {
	return abs(int(a[i]) - int(b[i])) > VISUAL_CELL_DELTA || abs(int(a[i + 1]) - int(b[i + 1])) > VISUAL_CELL_DELTA || abs(int(a[i + 2]) - int(b[i + 2])) > VISUAL_CELL_DELTA
}

// Which cells move: the count of each cell's spaced changes.
@(private)
moving_cells :: proc(frames: []Frame, load_ms: f64, allocator := context.temp_allocator) -> []bool {
	cells := len(frames[0].pixels) / 4
	moving := make([]bool, cells, allocator)
	Cell :: struct { at: int, count: int, last_ms: f64 }
	state := make([]Cell, cells, context.temp_allocator)
	for c in 0 ..< cells { state[c].last_ms = frames[0].ms - VISUAL_MOVING_GAP_MS }
	for f, n in frames {
		for c in 0 ..< cells {
			s := &state[c]
			if !differs(f.pixels, frames[s.at].pixels, c * 4) { continue }
			s.at = n
			if f.ms < load_ms || f.ms - s.last_ms < VISUAL_MOVING_GAP_MS { continue }
			s.last_ms = f.ms
			s.count += 1
			if s.count >= VISUAL_MOVING_CHANGES { moving[c] = true }
		}
	}
	return moving
}

// When the viewport was ready, and the share of its cells left out as moving. 0 without frames.
visual_ready :: proc(frames: []Frame, load_ms: f64) -> (ms, moving_share: f64) {
	if len(frames) == 0 { return 0, 0 }
	moving := moving_cells(frames, load_ms)
	last := frames[len(frames) - 1].pixels
	cells := len(last) / 4
	left_out := 0
	for m in moving { if m { left_out += 1 } }
	moving_share = f64(left_out) / f64(cells)
	for n := len(frames) - 1; n >= 0; n -= 1 {
		changed := 0
		for c in 0 ..< cells { if !moving[c] && differs(frames[n].pixels, last, c * 4) { changed += 1 } }
		if f64(changed) / f64(cells) >= VISUAL_CHANGE_SHARE { return frames[min(n + 1, len(frames) - 1)].ms, moving_share }
	}
	return frames[0].ms, moving_share
}

Spread :: struct { median, least, most: f64 }

spread :: proc(values: []f64) -> Spread {
	if len(values) == 0 { return {} }
	v := slice.clone(values, context.temp_allocator)
	slice.sort(v)
	n := len(v)
	return {n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2, v[0], v[n - 1]}
}

// What two series of one binary say of the metric: the larger of the distance between their medians and of how far a run strays from its own median, in % of the
// median. A difference smaller than this is not told from nothing by a series of this length.
noise_floor :: proc(a, b: Spread) -> f64 {
	if a.median <= 0 || b.median <= 0 { return 0 }
	strays := max(a.most - a.median, a.median - a.least, b.most - b.median, b.median - b.least)
	return 100 * max(abs(a.median - b.median), strays) / min(a.median, b.median)
}

Verdict :: enum { Nothing, Gain, Moved }

// The rule of the project: a change counts as a gain if the viewport is ready sooner or the thread settles sooner, with the ranges of the two series apart, and
// total CPU to settled does not get worse. Work moved past a mark shows here as Moved: a mark came sooner and the CPU went up.
verdict :: proc(ready_a, ready_b, settled_a, settled_b, cpu_a, cpu_b: Spread) -> Verdict {
	sooner := ready_b.most < ready_a.least || settled_b.most < settled_a.least
	if !sooner { return .Nothing }
	return cpu_b.least > cpu_a.most ? .Moved : .Gain
}
