package wpt

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:terminal"
import "core:time"

// The parent's side of a pass over the tests: one queue of tests, children that take the next one as they finish one. A full run with a fixed list per child (25 tests in path
// order) ended with one child alone for 20 minutes on html/cross-origin-opener-policy (25 long tests that time out at 60 s) while the others had ended: the tests now wait in
// one queue, the costliest first, and a child is handed CHILD_AHEAD of them at a time on its standard input.
//
// Each child goes Free (no process) -> Taking (it is handed tests as it reports them) -> Draining (its input is closed: it ends after what it has) -> Free. One thread decides,
// at each tick: what the children reported, which ended or hung, what each is handed, which start.

// What a child holds at once: the test it runs and the next one, so that it never waits for this loop's tick between two tests; no more, so that what is left goes to
// whichever child is free first.
CHILD_AHEAD :: 2
// How often the parent looks at its children (a test takes 60 ms at the least: a child never waits for it with CHILD_AHEAD).
PARENT_TICK :: 50 * time.Millisecond
// How often a pass says how far it is, on its standard output (the log of test_all's step) as well as on a terminal.
PROGRESS_EVERY :: 30 * time.Second
// A child's exit code when JavaScript cannot start in it: every test would wait out its limit for nothing, the run stops at once.
EXIT_NO_JAVASCRIPT :: 3
// Each test's time in the last run, "path \t ms": the order of the next one.
TIMES_FILE :: "build/wpt/times.txt"

Child_Phase :: enum { Free, Taking, Draining }

Child :: struct {
	phase:     Child_Phase,
	process:   os.Process,
	feed:      ^os.File,          // its standard input; nil once closed
	handed:    [dynamic]Test,     // handed to it, not reported yet, in order
	given:     int,               // tests this process was handed (at most -chunk)
	index:     int,               // its files: out_<index>.txt, log_<index>.txt
	out, log:  string,
	read_to:   i64,               // what of `out` has been read
	last_grow: time.Tick,         // when it last reported a test, or was handed one with nothing in hand
}

Run_Queue :: struct {
	waiting:   [dynamic]Test,     // the next test is the last one (the costliest)
	children:  []Child,
	results:   map[string]^Result,
	expected:  ^map[string]Expect,
	tests:     map[string]Test,
	total, done, regressed: int,
	next_index: int,
	hang_ms:   f64,
	began, last_progress: time.Tick,
	logs:      string,
}

// What a test is expected to cost, ms: its time in the last run, else its whole limit when it is expected to time out.
test_cost :: proc(t: Test, times: map[string]int, expected: ^map[string]Expect) -> int {
	limit := opts.timeout_ms * (t.long ? LONG_TIMEOUT_FACTOR : 1)
	if t.cap_ms > 0 { limit = min(limit, t.cap_ms) }
	if ms, known := times[t.path]; known { return min(ms, limit) }
	if e, found := expected[t.path]; found && strings.contains(e.status, "TIMEOUT") { return limit }
	return 0
}

queue_make :: proc(q: ^Run_Queue, tests: []Test, expected: ^map[string]Expect) {
	times := read_times()
	Costed :: struct { t: Test, cost: int }
	costed := make([]Costed, len(tests), context.temp_allocator)
	for t, i in tests { costed[i] = {t, test_cost(t, times, expected)} }
	slice.stable_sort_by(costed, proc(a, b: Costed) -> bool { return a.cost < b.cost })
	q.waiting = make([dynamic]Test, 0, len(tests))
	for c in costed { append(&q.waiting, c.t) }
	q.tests = make(map[string]Test, len(tests))
	for t in tests { q.tests[t.path] = t }
	q.results = make(map[string]^Result)
	q.expected = expected
	q.total = len(tests)
	q.children = make([]Child, opts.jobs)
	q.hang_ms = f64(opts.timeout_ms) * LONG_TIMEOUT_FACTOR + CHILD_HANG_MARGIN_MS   // longer than any one test may take
	q.logs = filepath.join({filepath.dir(opts.md != "" ? opts.md : "build/wpt/x"), "children"}) or_else "children"
	_ = os.make_directory_all(q.logs)
}

read_times :: proc() -> map[string]int {
	times := make(map[string]int)
	data, err := os.read_entire_file(TIMES_FILE, context.allocator)
	if err != nil { return times }
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		tab := strings.index_byte(line, '\t')
		if tab > 0 { times[line[:tab]] = atoi(line[tab + 1:]) }
	}
	return times
}

// This pass's times over those of the runs before (a pass of some tests keeps the others').
write_times :: proc(results: map[string]^Result) {
	times := read_times()
	for path, r in results { times[path] = r.ms }
	paths := make([dynamic]string, 0, len(times), context.temp_allocator)
	for p in times { append(&paths, p) }
	slice.sort(paths[:])
	b := strings.builder_make(context.temp_allocator)
	for p in paths { fmt.sbprintfln(&b, "%s\t%d", p, times[p]) }
	_ = os.write_entire_file(TIMES_FILE, strings.to_string(b))
}

// A child process, its input a pipe of its own. `with_tests`: false for the first child of a run, which only starts the engine (it compiles it and writes the disk cache alone,
// the others read it) and says whether JavaScript starts at all.
child_start :: proc(q: ^Run_Queue, c: ^Child, with_tests: bool) -> bool {
	c^ = Child{index = q.next_index, handed = c.handed}
	clear(&c.handed)
	q.next_index += 1
	c.out = fmt.aprintf("%s/out_%d.txt", q.logs, c.index)
	c.log = fmt.aprintf("%s/log_%d.txt", q.logs, c.index)
	_ = os.write_entire_file(c.out, "")
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, opts.self, "-child", c.out, "-server", opts.server, "-timeout", fmt.tprint(opts.timeout_ms), "-idle", fmt.tprint(opts.idle_ms), "-root", opts.root)
	if opts.dump != "" { append(&cmd, "-dump", opts.dump) }
	if opts.dump_all { append(&cmd, "-dump-all") }
	append(&cmd, ..opts.prefs_args[:])
	input, feed, perr := os.pipe()
	if perr != nil { fmt.eprintfln("wpt: no pipe for a child: %v", perr); return false }
	keep_from_children(feed)   // (else every later child would hold this input open, and this child would never see its end)
	// (inheritable, or the child writes its standard error nowhere: os.create's handle is not)
	logf, _ := os.open(c.log, {.Write, .Create, .Trunc, .Inheritable})
	p, err := os.process_start({command = cmd[:], stdin = input, stdout = logf, stderr = logf})
	if logf != nil { os.close(logf) }
	os.close(input)
	if err != nil {
		os.close(feed)
		fmt.eprintfln("wpt: cannot start a child: %v", err)
		return false
	}
	c.process, c.feed = p, feed
	c.phase = .Taking
	c.last_grow = time.tick_now()
	if !with_tests { child_close_feed(c) }
	return true
}

child_close_feed :: proc(c: ^Child) {
	if c.feed != nil { os.close(c.feed); c.feed = nil }
	c.phase = .Draining
}

// The tests a child has reported since the last look: whole records only.
child_read :: proc(q: ^Run_Queue, c: ^Child) {
	fi, serr := os.stat(c.out, context.temp_allocator)
	if serr != nil || fi.size <= c.read_to { return }
	f, oerr := os.open(c.out, {.Read})
	if oerr != nil { return }
	defer os.close(f)
	buf := make([]u8, fi.size - c.read_to, context.temp_allocator)
	n, _ := os.read_at(f, buf, c.read_to)
	text := string(buf[:max(n, 0)])
	RECORD_END :: "\nE\n"
	end := strings.last_index(text, RECORD_END)
	if end < 0 { return }
	text = text[:end + len(RECORD_END)]
	c.read_to += i64(len(text))
	got := make([dynamic]^Result, context.temp_allocator)
	parse_child_text(text, &got)
	for r in got { record(q, c, r) }
	c.last_grow = time.tick_now()
}

// A result: kept, counted, and the test is no longer the child's.
record :: proc(q: ^Run_Queue, c: ^Child, r: ^Result) {
	q.results[r.path] = r
	q.done += 1
	if t, found := q.tests[r.path]; found {
		if e, has := q.expected[r.path]; has && regressions_of(t, r, e) > 0 { q.regressed += 1 }
	}
	if c == nil { return }
	for t, i in c.handed { if t.path == r.path { ordered_remove(&c.handed, i); break } }
}

// A child that has ended or hung: what it reported, the test it was running when it died (a CRASH), the ones it was handed after back to the queue. A child that cannot start
// JavaScript stops the run: `why`.
child_ended :: proc(q: ^Run_Queue, c: ^Child, exit_code: int) -> (why: string) {
	child_read(q, c)
	if c.feed != nil { os.close(c.feed); c.feed = nil }
	c.phase = .Free   // (os.process_wait has closed its handle)
	if exit_code == EXIT_NO_JAVASCRIPT {
		said, _ := os.read_entire_file(c.log, context.temp_allocator)
		return fmt.aprintf("a test process cannot start JavaScript, every test would time out: the run stops (%s: %s)", c.log, strings.trim_space(string(said)))
	}
	for t, i in c.handed {
		if i > 0 { append(&q.waiting, t); continue }
		r := new(Result)
		r.path, r.status = t.path, "CRASH"
		r.message = fmt.aprintf("the test process ended (exit code %d) or stopped answering", exit_code)
		record(q, nil, r)
	}
	clear(&c.handed)
	return ""
}

// What a child is handed: up to CHILD_AHEAD tests in hand, at most -chunk in its life; its input closes when it will get no more.
child_feed :: proc(q: ^Run_Queue, c: ^Child) {
	for c.phase == .Taking && len(c.handed) < CHILD_AHEAD && c.given < opts.chunk && len(q.waiting) > 0 {
		t := pop(&q.waiting)
		line := fmt.tprintf("%s\t%d\t%d\t%d\n", t.path, t.long ? 1 : 0, t.is_reftest ? 1 : 0, t.cap_ms)
		if len(c.handed) == 0 { c.last_grow = time.tick_now() }
		if _, err := os.write_string(c.feed, line); err != nil {
			append(&q.waiting, t)   // (it has ended: its exit says why)
			child_close_feed(c)
			return
		}
		append(&c.handed, t)
		c.given += 1
	}
	if c.phase == .Taking && (c.given >= opts.chunk || len(q.waiting) == 0) { child_close_feed(c) }
}

// The whole pass; `why` when the run must stop.
queue_run :: proc(q: ^Run_Queue) -> (why: string) {
	q.began = time.tick_now()
	q.last_progress = q.began
	// (a run that stops leaves no child behind)
	defer {
		for &c in q.children {
			if c.phase == .Free { continue }
			_ = os.process_kill(c.process)
			_, _ = os.process_wait(c.process)
			if c.feed != nil { os.close(c.feed); c.feed = nil }
			c.phase = .Free
		}
	}
	// The first child alone: the engine compiled once for all, and a run that cannot start JavaScript stops here.
	if opts.jobs > 1 && !opts.quiet {
		if child_start(q, &q.children[0], false) {
			state, _ := os.process_wait(q.children[0].process)
			if w := child_ended(q, &q.children[0], state.exit_code); w != "" { return w }
		}
	}
	show_terminal := terminal.is_terminal(os.stderr)
	for {
		busy := false
		for &c in q.children {
			if c.phase != .Free {
				child_read(q, &c)
				state, werr := os.process_wait(c.process, 0)
				ended := werr == nil && state.exited
				if !ended && len(c.handed) > 0 && time.duration_milliseconds(time.tick_since(c.last_grow)) > q.hang_ms {
					// no result for longer than a test may take: killed, its test is a CRASH
					_ = os.process_kill(c.process)
					state, _ = os.process_wait(c.process)
					ended = true
				}
				if ended {
					if w := child_ended(q, &c, state.exit_code); w != "" { return w }
				}
			}
			if c.phase == .Free && len(q.waiting) > 0 {
				if !child_start(q, &c, true) {
					for len(q.waiting) > 0 {
						t := pop(&q.waiting)
						r := new(Result)
						r.path, r.status, r.message = t.path, "CRASH", "the test process could not start"
						record(q, nil, r)
					}
				}
			}
			child_feed(q, &c)
			if c.phase != .Free { busy = true }
		}
		if !busy && len(q.waiting) == 0 { break }
		if show_terminal { fmt.eprintf("%d/%d, %d regressed\r", q.done, q.total, q.regressed) }
		if time.tick_since(q.last_progress) >= PROGRESS_EVERY {
			q.last_progress = time.tick_now()
			if !opts.quiet { fmt.println(progress_line(q)) }
		}
		time.sleep(PARENT_TICK)
		free_all(context.temp_allocator)
	}
	return ""
}

progress_line :: proc(q: ^Run_Queue) -> string {
	running := 0
	for c in q.children { if c.phase != .Free { running += 1 } }
	return fmt.tprintf("wpt: %d of %d tests done, %d regressed so far, %d waiting, %d children running, %.0f s", q.done, q.total, q.regressed, len(q.waiting), running, time.duration_seconds(time.tick_since(q.began)))
}
