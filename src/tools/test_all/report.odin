package test_all

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:tools/tooling"

// Of a failure: this many of its last lines are printed when it ends (all of them with -CI), this many lines naming what failed in the report.
FAIL_TAIL_LINES :: 15
FAIL_NAMED_LINES :: 8
FLAKY_LINES :: 15
SLOWEST_STEPS :: 15
SLOWEST_NAME_CHARS :: 110

Run_Summary :: struct {
	skipped_ci, skipped_ui, left_out: int,
	selecting: bool,
	began:     time.Tick,
	durations: map[string]int,
}

// How many checks a step's output says it made (Odin's runner, the tools' "n passed", the PASS lines of a script, WPT's count): a run can be compared with another (build/test_steps.tsv); and its explicit skips.
read_log_facts :: proc(r: ^Step_Run) {
	data, err := os.read_entire_file(r.log, context.temp_allocator)
	if err != nil { return }
	r.checks = count_checks(string(data))
	skips: [dynamic]string
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, "SKIP [") { append(&skips, strings.clone(strings.trim_right_space(line))) }
	}
	r.skips = skips[:]
}

number_before :: proc(s: string, end: int) -> int {
	i := end
	for i > 0 && s[i - 1] >= '0' && s[i - 1] <= '9' { i -= 1 }
	v, _ := strconv.parse_int(s[i:end])
	return v
}

count_checks :: proc(log: string) -> int {
	n := 0
	text := log
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_left_space(line)
		if strings.has_prefix(l, "PASS") || strings.has_prefix(l, "ok ") || l == "ok" { n += 1; continue }
		// "Finished 12 tests", anywhere on the line
		if at := strings.index(l, "Finished "); at >= 0 {
			rest := l[at + len("Finished "):]
			end := 0
			for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' { end += 1 }
			if end > 0 && strings.has_prefix(rest[end:], " test") { v, _ := strconv.parse_int(rest[:end]); n += v }
			continue
		}
		// "12 passed, 0 failure(s)"
		if at := strings.index(l, " passed, "); at > 0 && strings.has_prefix(l[at + len(" passed, "):], "0 failure") || at > 0 && strings.contains(l[at:], " failure") {
			n += number_before(l, at)
			continue
		}
		// "880 tests in 48 folders"
		if at := strings.index(l, " tests in "); at > 0 && strings.contains(l[at:], " folders") { n += number_before(l, at) }
	}
	return n
}

status_word :: proc(s: Status) -> string {
	switch s {
	case .None: return "NONE"
	case .Pass: return "PASS"
	case .Fail: return "FAIL"
	case .Flaky: return "FLAKY"
	case .Cached: return "CACHED"
	case .Not_Run: return "NOT RUN"
	}
	return ""
}

print_step :: proc(s: ^Scheduler, r: ^Step_Run) {
	if s.quiet { return }
	switch r.status {
	case .None:
	case .Cached:
		fmt.printfln("CACHED %s (passed %s, %d s; -NoCache runs it)", r.step.name, r.when_passed, r.passed_seconds)
	case .Pass:
		fmt.printfln("PASS %s (%.0f s)", r.step.name, r.seconds)
	case .Not_Run:
		fmt.printfln("NOT RUN %s: %s", r.step.name, r.why)
	case .Flaky:
		fmt.printfln("FLAKY %s (known to fail at random: not counted)", r.step.name)
		for l, i in failure_lines(r, FLAKY_LINES) { if i < FLAKY_LINES { fmt.println(l) } }
	case .Fail:
		fmt.printfln("FAIL %s (%.0f s)%s", r.step.name, r.seconds, r.why != "" ? strings.concatenate({": ", r.why}, context.temp_allocator) : "")
		data, _ := os.read_entire_file(r.log, context.temp_allocator)
		text := strings.trim_right_space(string(data))
		if !s.cfg.ci {
			lines := strings.split_lines(text, context.temp_allocator)
			text = strings.join(lines[max(0, len(lines) - FAIL_TAIL_LINES):], "\n", context.temp_allocator)
		}
		fmt.println(text)
	}
}

// What names a failure in a log.
failure_lines :: proc(r: ^Step_Run, most: int) -> []string {
	data, _ := os.read_entire_file(r.log, context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "FAIL") || strings.has_prefix(l, "REGRESSION") || strings.has_prefix(l, "- ") && strings.contains(l, ".") || strings.has_prefix(l, "[ERROR]") {
			append(&out, l)
			if len(out) >= most { break }
		}
	}
	return out[:]
}

// The -define the test runner prints for its failed tests, when it does.
failed_tests_define :: proc(r: ^Step_Run) -> string {
	PREFIX :: "-define:ODIN_TEST_NAMES="
	data, _ := os.read_entire_file(r.log, context.temp_allocator)
	text := string(data)
	at := strings.index(text, PREFIX)
	if at < 0 { return "" }
	end := at
	for end < len(text) && text[end] > ' ' { end += 1 }
	return strings.trim_right(text[at:end], ",")
}

regex_escaped :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		if strings.index_byte(`\.^$|?*+()[]{}`, c) >= 0 { strings.write_byte(&b, '\\') }
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

// The end of a run for whoever reads it (a person, an agent, a CI log): how many steps did what, what failed, its log and how to run it again, where the time went; the same in build/test_report.txt, every step's
// result in build/test_steps.tsv, what failed in build/test_failed.txt (-Failed reads it).
run_report :: proc(s: ^Scheduler, sum: ^Run_Summary) -> (failed: int) {
	counts: [Status]int
	checks, skips := 0, 0
	lines := make([dynamic]string)
	cpu, step_seconds := 0.0, 0.0
	processes := 0
	for &r in s.runs {
		counts[r.status] += 1
		checks += r.checks
		skips += len(r.skips)
		cpu += r.cpu
		step_seconds += r.seconds
		processes += r.processes
	}
	failed = counts[.Fail]
	// (steps left out by the budget or the circuit breaker were not tested: the run fails even if what ran was flaky only)
	cut_short := s.out_of_budget || s.timeouts >= TIMEOUTS_MOST
	if cut_short { failed = max(failed, 1) }
	text := strings.builder_make()
	for status in Status {
		if counts[status] == 0 { continue }
		fmt.sbprintf(&text, "%s%d %s", strings.builder_len(text) > 0 ? ", " : "", counts[status], status_word(status))
	}
	append(&lines, fmt.aprintf("steps: %s; %d checks counted; %d explicit skip(s); skipped by their marks: %d for the CI, %d without -Ui", strings.to_string(text), checks, skips, sum.skipped_ci, sum.skipped_ui))
	if s.out_of_budget { append(&lines, fmt.aprintf("the run was stopped: it ran for its budget of %d s (-RunTimeoutSec); the steps it stopped say so, the others did not run", s.cfg.run_timeout)) }
	if s.timeouts >= TIMEOUTS_MOST { append(&lines, fmt.aprintf("%d steps ran out of time: no step started after the %dth (most likely one cause: read the first of them)", s.timeouts, TIMEOUTS_MOST)) }
	for &r in s.runs { for l in r.skips { append(&lines, l) } }
	if counts[.Cached] > 0 { append(&lines, fmt.aprintf("%d step(s) did not run: they passed with exactly these inputs (src\\tools\\test_all\\cache.odin). -NoCache runs them.", counts[.Cached])) }
	wall := time.duration_seconds(time.tick_since(sum.began))
	if s.cfg.use_cache { append(&lines, fmt.aprintf("the inputs of the steps were read in %.1f s; the first step started %.1f s after this run's start", s.key_seconds, s.first_start)) }
	if sum.selecting { append(&lines, fmt.aprintf("%d step(s) left out by -Only / -Except / -Failed / -Changed / -Group.", sum.left_out)) }
	// (where the time goes: what the machine gave, what waited for what)
	jobs := s.limits[.Heavy]
	total := s.busy_slots + s.blocked_slots + s.idle_slots
	if total > 0 {
		append(&lines, fmt.aprintf("where the time goes: %.0f s of wall clock, %.0f s of steps (they overlap), %.0f s of CPU in %d processes, %.1f processors on average; of the %d -Jobs slots, %.0f %% busy, %.0f %% free while a step waited for what it needs, %.0f %% free with nothing left to start",
			wall, step_seconds, cpu, processes, cpu / max(wall, 1), jobs, 100 * s.busy_slots / total, 100 * s.blocked_slots / total, 100 * s.idle_slots / total))
	}
	for &r in s.runs {
		if r.status != .Fail && r.status != .Flaky && r.status != .Not_Run { continue }
		append(&lines, fmt.aprintf("%s %s%s", status_word(r.status), r.step.name, r.why != "" ? strings.concatenate({": ", r.why}, context.temp_allocator) : ""))
		if r.status == .Not_Run { continue }
		append(&lines, fmt.aprintf("  log: %s", here(r.log)))
		append(&lines, fmt.aprintf("  again: build%stest_all%s %s-NoCache -Only \"%s\"", ODIN_OS == .Windows ? "\\" : "/", tooling.EXE_SUFFIX, s.cfg.again, regex_escaped(short_name(r.step.name))))
		if names := failed_tests_define(&r); names != "" { append(&lines, fmt.aprintf("  only the failed tests: add %s to its odin test", names)) }
		for l in failure_lines(&r, FAIL_NAMED_LINES) { append(&lines, fmt.aprintf("  %s", l)) }
	}
	report_text := strings.join(lines[:], "\n")
	fmt.println(report_text)
	_ = os.write_entire_file(REPORT_FILE, fmt.tprintln(report_text))
	write_step_files(s)
	summary("Result", report_text)
	return failed
}

write_step_files :: proc(s: ^Scheduler) {
	sorted := make([]^Step_Run, len(s.runs), context.temp_allocator)
	for &r, i in s.runs { sorted[i] = &r }
	slice.sort_by(sorted, proc(a, b: ^Step_Run) -> bool { return a.step.name < b.step.name })
	tsv := strings.builder_make(context.temp_allocator)
	failed := strings.builder_make(context.temp_allocator)
	strings.write_string(&tsv, "status\tseconds\tcpu_seconds\tprocesses\tchecks\tname\n")
	for r in sorted {
		fmt.sbprintf(&tsv, "%s\t%d\t%.1f\t%d\t%d\t%s\n", status_word(r.status), int(r.seconds), r.cpu, r.processes, r.checks, r.step.name)
		if r.status == .Fail || r.status == .Flaky || r.status == .Not_Run { fmt.sbprintln(&failed, r.step.name) }
	}
	_ = os.write_entire_file(STEPS_FILE, strings.to_string(tsv))
	_ = os.write_entire_file(FAILED_FILE, strings.to_string(failed))
}

// The slowest steps, for a CI log and the job summary of a GitHub run.
slowest_steps :: proc(s: ^Scheduler) {
	ran := make([dynamic]^Step_Run, context.temp_allocator)
	for &r in s.runs { if r.seconds > 0 { append(&ran, &r) } }
	slice.sort_by(ran[:], proc(a, b: ^Step_Run) -> bool { return a.seconds > b.seconds })
	b := strings.builder_make()
	strings.write_string(&b, "slowest steps (seconds of wall clock, of CPU; with -Jobs n they overlap):\n")
	for r, i in ran {
		if i >= SLOWEST_STEPS { break }
		fmt.sbprintfln(&b, "  %5s s %7s s  %s", fmt.tprint(int(r.seconds)), fmt.tprintf("%.1f", r.cpu), r.step.name[:min(SLOWEST_NAME_CHARS, len(r.step.name))])
	}
	text := strings.to_string(b)
	fmt.print(text)
	summary("Test times", text)
}

summary :: proc(title, text: string) {
	path, ok := os.lookup_env("GITHUB_STEP_SUMMARY", context.temp_allocator)
	if !ok || path == "" { return }
	tooling.append_text(path, fmt.tprintf("### %s\n```\n%s\n```\n", title, text))
}

read_durations :: proc() -> (out: map[string]int) {
	data, err := os.read_entire_file(TIMES_FILE, context.allocator)
	if err != nil { return }
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		tab := strings.last_index_byte(line, '\t')
		if tab <= 0 { continue }
		if v, ok := strconv.parse_int(strings.trim_space(line[tab + 1:])); ok { out[line[:tab]] = v }
	}
	return
}

write_durations :: proc(s: ^Scheduler, durations: ^map[string]int) {
	for &r in s.runs { if r.status == .Pass || r.status == .Fail || r.status == .Flaky { durations[r.step.name] = int(r.seconds) } }
	names := make([dynamic]string, context.temp_allocator)
	for k in durations { append(&names, k) }
	slice.sort(names[:])
	b := strings.builder_make(context.temp_allocator)
	for k in names { fmt.sbprintf(&b, "%s\t%d\n", k, durations[k]) }
	_ = os.write_entire_file(TIMES_FILE, strings.to_string(b))
}

// The whole of a run, from the table to the exit code.
run_all :: proc(cfg: ^Config, table: []Step) -> int {
	began := time.tick_now()
	cache := new(Cache)
	if cfg.use_cache || cfg.changed || cfg.list {
		flags := fmt.aprintf("Quick=%v CI=%v Ui=%v slow=%d NoAsan=%v Jobs1=%v NoCache=%v", cfg.quick, cfg.ci, cfg.ui, cfg.slow, cfg.no_asan, cfg.jobs <= 1, cfg.no_cache)
		cache_init(cache, ".", flags)
	}
	sum := Run_Summary{began = began, durations = read_durations()}
	sum.selecting = cfg.only != "" || cfg.except != "" || cfg.failed || cfg.changed || cfg.by_group
	steps := choose_steps(cfg, table, cache, &sum.skipped_ci, &sum.skipped_ui, &sum.left_out)
	if cfg.list {
		for s in steps { fmt.printfln("%5s inputs  %-6s %s", fmt.tprint(len(step_inputs(cache, s))), GROUP_NAMES[s.group], s.name); free_all(context.temp_allocator) }
		return 0
	}
	tooling.raise_stack()
	fetch_emoji_when_missing()
	warn_programs_running()
	fmt.printfln("test_all: %s, -Jobs %d, started %s", here("."), cfg.jobs, now_stamp())
	s := scheduler_make(cfg, steps, &sum.durations, cache)
	// while it runs the report file says what is running (progress_text), the end of the run replaces it with the report
	s.progress_file = REPORT_FILE
	_ = os.write_entire_file(REPORT_FILE, fmt.tprintfln("test_all: started %s, the report comes at the end; meanwhile, every %v:", now_stamp(), PROGRESS_INTERVAL))
	if cfg.profile { s.profile = profile_begin() }
	schedule(s)
	if s.profile != nil { profile_end(s.profile) }
	slowest_steps(s)
	write_durations(s, &sum.durations)
	failed := run_report(s, &sum)
	fmt.printfln("failed steps: %d (%.0f s, -Jobs %d)", failed, time.duration_seconds(time.tick_since(began)), cfg.jobs)
	return failed
}
