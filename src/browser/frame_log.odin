package browser

import "core:slice"
import "core:time"

// The times at which frames were presented, for `wren ctl stats` (frameIntervals, framesPresented): what a script reads to
// tell how evenly the window was redrawn while something else moved it (tools\altdrag_sim.ps1). A ring: the latest frames.
FRAME_LOG_CAP :: 8192

Frame_Log :: struct {
	at:        [FRAME_LOG_CAP]i64,   // tick of each present (ns)
	n:         int,                  // presents since the last reset
	presented: int,                  // presents since the last reset, however many the ring kept
	at_once:   int,                  // of them, presented without waiting for a refresh (framesAtOnce)
}

frame_log: Frame_Log

frame_log_presented :: proc(at_once: bool) {
	frame_log.at[frame_log.n % FRAME_LOG_CAP] = time.tick_now()._nsec
	frame_log.n += 1
	frame_log.presented += 1
	if at_once { frame_log.at_once += 1 }
}

frame_log_reset :: proc() { frame_log = {} }

Frame_Intervals :: struct {
	count:               int,
	p50, p95, p99, max:  f64,   // ms between two consecutive presents
}

// The gaps between consecutive presents kept in the ring. Percentiles by nearest rank.
frame_log_intervals :: proc(allocator := context.temp_allocator) -> (s: Frame_Intervals) {
	kept := min(frame_log.n, FRAME_LOG_CAP)
	if kept < 2 { return }
	first := frame_log.n - kept
	gaps := make([]f64, kept - 1, allocator)
	for i in 1 ..< kept {
		a := frame_log.at[(first + i - 1) % FRAME_LOG_CAP]
		b := frame_log.at[(first + i) % FRAME_LOG_CAP]
		gaps[i - 1] = f64(b - a) / 1e6
	}
	slice.sort(gaps)
	rank :: proc(g: []f64, q: f64) -> f64 { return g[min(len(g) - 1, int(q * f64(len(g))))] }
	return {count = len(gaps), p50 = rank(gaps, 0.5), p95 = rank(gaps, 0.95), p99 = rank(gaps, 0.99), max = gaps[len(gaps) - 1]}
}
