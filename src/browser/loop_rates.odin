package browser

// The loop's own account, the factory's meters: how many turns, how many sleeps, how many frames and why each frame was made. No
// work without demand: a frame has a cause, a wake has a source, and the last few are kept with who asked (`wren ctl stats`: `loop`),
// so that what draws or wakes at rest can be read rather than guessed.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "wb:remote/api"

Frame_Cause :: api.Frame_Cause
Frame_Causes :: bit_set[Frame_Cause; u8]

// How many frames, and how many wakes that drew nothing, are kept with their reason.
LOOP_REASONS_KEPT :: 32

Loop_Reason :: struct {
	at_ms:  f64,
	causes: Frame_Causes,                   // none: a wake that drew nothing
	by:     runtime.Source_Code_Location,   // who asked: the task that ran, or the caller of request_frames
}

Loop_Rates :: struct {
	turns:   int,                   // passes of the loop
	sleeps:  int,                   // of them, the loop slept first: a wake
	barren:  int,                   // wakes after which no window drew
	frames:  int,                   // frames made, of every window
	causes:  [Frame_Cause]int,      // the frames, each under the first of its causes
	// two rings: the frames, and the wakes that drew nothing (one ring of both lost a frame among the wakes of a loop woken
	// every few milliseconds: what a frame at rest was for could not be read)
	drawn:   [LOOP_REASONS_KEPT]Loop_Reason,
	drawn_n: int,                   // how many went into it
	idle:    [LOOP_REASONS_KEPT]Loop_Reason,
	idle_n:  int,
}

@(private = "file")
loop_rates_note :: proc(r: ^Loop_Rates, causes: Frame_Causes, by: runtime.Source_Code_Location, now_ms: f64) {
	e := Loop_Reason{at_ms = now_ms, causes = causes, by = by}
	if causes != {} {
		r.drawn[r.drawn_n % LOOP_REASONS_KEPT] = e
		r.drawn_n += 1
	} else {
		r.idle[r.idle_n % LOOP_REASONS_KEPT] = e
		r.idle_n += 1
	}
}

// The frame that is about to be made.
loop_rates_frame :: proc(r: ^Loop_Rates, causes: Frame_Causes, by: runtime.Source_Code_Location, now_ms: f64) {
	for c in Frame_Cause { if c in causes { r.causes[c] += 1; break } }
	r.frames += 1
	loop_rates_note(r, causes, by, now_ms)
}

// A wake that drew nothing; `by`: the last quiet task, the one that may have been the reason.
loop_rates_barren :: proc(r: ^Loop_Rates, by: runtime.Source_Code_Location, now_ms: f64) {
	r.barren += 1
	loop_rates_note(r, {}, by, now_ms)
}

// What a client reads: the last frames and the last wakes that drew nothing, merged in time; "who" as a place in the sources.
loop_rates_stats :: proc(r: ^Loop_Rates, allocator := context.temp_allocator) -> api.Loop_Stats {
	st := api.Loop_Stats{turns = r.turns, sleeps = r.sleeps, barren = r.barren, frames = r.frames, causes = r.causes}
	nd, ni := min(r.drawn_n, LOOP_REASONS_KEPT), min(r.idle_n, LOOP_REASONS_KEPT)
	st.reasons = make([]api.Loop_Reason, nd + ni, allocator)
	d, i := 0, 0
	for k in 0 ..< nd + ni {
		e: Loop_Reason
		dd := r.drawn[(r.drawn_n - nd + d) % LOOP_REASONS_KEPT]
		ii := r.idle[(r.idle_n - ni + i) % LOOP_REASONS_KEPT]
		if i >= ni || (d < nd && dd.at_ms <= ii.at_ms) { e = dd; d += 1 } else { e = ii; i += 1 }
		who := e.by.file_path != "" ? fmt.aprintf("%s:%d", e.by.file_path, e.by.line, allocator = allocator) : ""
		st.reasons[k] = {at_ms = e.at_ms, causes = loop_causes_text(e.causes, allocator), by = who}
	}
	return st
}

@(private = "file")
loop_causes_text :: proc(causes: Frame_Causes, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for c in causes {
		if strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
		fmt.sbprint(&b, c)
	}
	if causes == {} { strings.write_string(&b, "wake, no frame") }
	return strings.to_string(b)
}

// control_stats' `loop` on the channel.
loop_rates_json :: proc(b: ^strings.Builder, st: api.Loop_Stats) {
	j_key(b, "loop"); j_begin(b)
	j_int(b, "turns", i64(st.turns)); j_int(b, "sleeps", i64(st.sleeps)); j_int(b, "barren", i64(st.barren)); j_int(b, "frames", i64(st.frames))
	j_key(b, "causes"); j_begin(b)
	for c in Frame_Cause { j_int(b, fmt.tprint(c), i64(st.causes[c])) }
	j_end(b)
	j_key(b, "reasons"); j_begin(b, '[')
	for r, i in st.reasons {
		if i > 0 { strings.write_byte(b, ',') }
		j_begin(b)
		j_num(b, "atMs", r.at_ms); j_str(b, "causes", r.causes); j_str(b, "by", r.by)
		j_end(b)
	}
	j_end(b, ']')
	j_end(b)
}
