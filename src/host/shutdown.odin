package host

// Diagnostics for the end of the process. A program that closes its window tears its subsystems down in a fixed order
// (the browser: tabs, pages, loader, pools, runtime); when one of those steps waits for a thread that never answers, the
// window stays on screen and the process has to be killed. This file names what waits.
//
//   shutdown_begin   the window is closed: starts a watchdog thread and the clock
//   shutdown_step    the teardown enters a named step (the watchdog reports the current one)
//   shutdown_end     the teardown is finished: the watchdog stops
//
// The watchdog wakes every 200 ms. After `warn_ms` it writes, once a second, the current step, how long it lasts, what
// thread_join waits for, and every thread still running. After `force_ms` it writes that it ends the process and calls
// ends the process at once (ExitProcess, exit_group): the last resort (what the profile keeps is saved before the teardown starts). The text goes to stderr
// and to `log_path` (rewritten as a whole, so the file holds the last slow shutdown only: a fast one writes nothing).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

@(private = "file")
Shutdown :: struct {
	mu:         sync.Mutex,
	active:     bool,
	stop:       bool,
	start:      time.Tick,
	step:       [96]u8,
	step_len:   int,
	step_start: time.Tick,
	joining:    [64]u8,   // the thread the teardown is waiting for in thread_join ("" = none)
	joining_len: int,
	log_path:   string,
	log:        strings.Builder,
	warn_ms:    int,
	force_ms:   int,
	watchdog:   ^Thread,
	done:       [160]Step_Time,   // the steps that ended, in order (the slowest are named when the teardown was slow)
	done_count: int,
}

@(private = "file")
Step_Time :: struct {
	name: [48]u8,
	len:  int,
	ms:   f64,
}

// A teardown at least this long names its slowest steps when it ends, whether or not the watchdog had to speak.
SLOW_SUMMARY_MS :: 1000

@(private = "file")
sd: Shutdown

@(private = "file")
fixed_copy :: proc(dst: []u8, s: string) -> int {
	n := min(len(dst), len(s))
	copy(dst[:n], s[:n])
	return n
}

// `log_path` "" = stderr only. force_ms 0 = never force the exit. Call from the thread that tears down.
shutdown_begin :: proc(log_path: string, warn_ms := 2000, force_ms := 10_000) {
	if sd.active { return }
	sd.active, sd.stop = true, false
	sd.start = time.tick_now()
	sd.step_start = sd.start
	sd.step_len, sd.joining_len = 0, 0
	sd.log_path = strings.clone(log_path)
	sd.log = strings.builder_make()
	sd.warn_ms, sd.force_ms = warn_ms, force_ms
	// The process is ending and wants to be gone: it runs above normal priority from here on, so that every thread it has to wake
	// (the ones it joins, the pipe's, the decoders', the compositor's helpers) is not made to queue behind other programs' busy
	// loops. With every core saturated, each hand-over of the teardown cost up to several seconds (measured: 4 to 8 s in one step,
	// 25 s in all with the forced exit); at this class none of them waits for a time slice.
	shutdown_raise_priority()
	sd.watchdog = thread_start(shutdown_watchdog, nil, name = "wren-shutdown-watchdog")
}

shutdown_step :: proc(name: string) {
	if !sd.active { return }
	sync.mutex_lock(&sd.mu)
	step_finished()
	sd.step_len = fixed_copy(sd.step[:], name)
	sd.step_start = time.tick_now()
	sync.mutex_unlock(&sd.mu)
}

// Notes the step that was running as finished now (sd.mu held).
@(private = "file")
step_finished :: proc() {
	if sd.step_len == 0 || sd.done_count >= len(sd.done) { return }
	d := &sd.done[sd.done_count]
	d.len = fixed_copy(d.name[:], string(sd.step[:sd.step_len]))
	d.ms = time.duration_milliseconds(time.tick_since(sd.step_start))
	sd.done_count += 1
}

// Stops the watchdog. Anything the teardown waited for beyond `warn_ms` has been reported by then.
shutdown_end :: proc() {
	if !sd.active { return }
	sync.atomic_store(&sd.stop, true)
	thread_join(sd.watchdog)
	elapsed := time.duration_milliseconds(time.tick_since(sd.start))
	sync.mutex_lock(&sd.mu)
	step_finished()
	sync.mutex_unlock(&sd.mu)
	if int(elapsed) >= sd.warn_ms {
		shutdown_line(fmt.tprintf("shutdown: finished after %.1f s", elapsed / 1000))
	}
	if int(elapsed) >= SLOW_SUMMARY_MS {
		// the three steps that took longest, longest first
		order := make([dynamic]int, context.temp_allocator)
		for i in 0 ..< sd.done_count { append(&order, i) }
		for i in 1 ..< len(order) {
			for j := i; j > 0 && sd.done[order[j]].ms > sd.done[order[j - 1]].ms; j -= 1 { order[j], order[j - 1] = order[j - 1], order[j] }
		}
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "shutdown: %.2f s in all; slowest steps:", elapsed / 1000)
		for i in 0 ..< min(3, len(order)) {
			d := &sd.done[order[i]]
			fmt.sbprintf(&b, "%s %q %.0f ms", i > 0 ? "," : "", string(d.name[:d.len]), d.ms)
		}
		shutdown_line(strings.to_string(b))
	}
	delete(sd.log_path)
	strings.builder_destroy(&sd.log)
	sd = {}
}

// thread_join is waiting for `name` ("" when it is done).
@(private)
shutdown_joining :: proc(name: string) {
	if !sd.active { return }
	sync.mutex_lock(&sd.mu)
	sd.joining_len = fixed_copy(sd.joining[:], name)
	sync.mutex_unlock(&sd.mu)
}

@(private = "file")
shutdown_line :: proc(line: string) {
	fmt.eprintln(line)
	if sd.log_path == "" { return }
	strings.write_string(&sd.log, line)
	strings.write_byte(&sd.log, '\n')
	_ = os.write_entire_file(sd.log_path, transmute([]byte)strings.to_string(sd.log))
}

@(private = "file")
shutdown_watchdog :: proc(_: rawptr) {
	next_report := time.Duration(sd.warn_ms) * time.Millisecond
	for !sync.atomic_load(&sd.stop) {
		time.sleep(200 * time.Millisecond)
		elapsed := time.tick_since(sd.start)
		if elapsed < next_report || sync.atomic_load(&sd.stop) { continue }
		next_report = elapsed + time.Second
		sync.mutex_lock(&sd.mu)
		step := string(sd.step[:sd.step_len])
		joining := string(sd.joining[:sd.joining_len])
		in_step := time.duration_seconds(time.tick_since(sd.step_start))
		sync.mutex_unlock(&sd.mu)
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "shutdown: %.1f s since the window closed; step %q for %.1f s", time.duration_seconds(elapsed), step, in_step)
		if joining != "" { fmt.sbprintf(&b, "; waiting for thread %q", joining) }
		fmt.sbprint(&b, "; threads still running:")
		for name in threads_running(context.temp_allocator) { fmt.sbprintf(&b, " %s", name) }
		shutdown_line(strings.to_string(b))
		if sd.force_ms > 0 && int(time.duration_milliseconds(elapsed)) >= sd.force_ms {
			shutdown_line(fmt.tprintf("shutdown: still in step %q after %d ms: ending the process (the profile was saved before the teardown)", step, sd.force_ms))
			shutdown_force_exit()
		}
		free_all(context.temp_allocator)
	}
}
