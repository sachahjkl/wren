package test_all

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// Of scheduler.odin: the states of a run, with tasks that say when they ran instead of processes.

@(private = "file") order_lock: sync.Mutex
@(private = "file") order: [dynamic]string

@(private = "file")
fake_task :: proc(t: ^Task_Run) -> bool {
	sync.guard(&order_lock)
	append(&order, t.arg)
	return !strings.has_prefix(t.arg, "fail")
}

// A task that stays until it is let go, to see what runs beside it.
@(private = "file") let_go: bool
@(private = "file")
held_task :: proc(t: ^Task_Run) -> bool {
	for !sync.atomic_load(&let_go) { time.sleep(time.Millisecond) }
	return true
}
@(private = "file")
fake :: proc(name: string, needs := Products{}, makes := Products{}, marks := Marks{}, weight := 0, task: proc(t: ^Task_Run) -> bool = fake_task) -> Step {
	return Step{name = name, actions = slice_of(Task{name, task, name}), needs = needs, makes = makes, marks = marks + {.No_Result}, weight = weight}
}

@(private = "file")
table_scheduler :: proc(table: []Step, jobs: int, light: int) -> ^Scheduler {
	clear(&order)
	let_go = false
	cfg := new(Config)
	cfg.jobs, cfg.light_jobs, cfg.step_timeout = jobs, light, STEP_TIMEOUT_SECONDS
	steps := make([dynamic]^Step, 0, len(table))
	for &s in table { append(&steps, &s) }
	durations: map[string]int
	s := scheduler_make(cfg, steps[:], &durations, new(Cache))
	s.quiet = true
	return s
}

@(private = "file")
run_table :: proc(table: []Step, jobs := 4, light := 2) -> ^Scheduler {
	s := table_scheduler(table, jobs, light)
	schedule(s)
	return s
}
@(private = "file")
status_of :: proc(s: ^Scheduler, name: string) -> Status {
	for &r in s.runs { if r.step.name == name { return r.status } }
	return .None
}

@(test)
what_a_step_needs_runs_before_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	table := []Step{fake("uses", needs = {.E2E}), fake("makes", makes = {.E2E}), fake("makes first", makes = {.JS_Engine}), fake("needs both", needs = {.E2E, .JS_Engine})}
	s := run_table(table, jobs = 1)
	index :: proc(name: string) -> int {
		for n, i in order { if n == name { return i } }
		return -1
	}
	testing.expect(t, index("makes") < index("uses"), "the maker first")
	testing.expect(t, index("makes") < index("needs both") && index("makes first") < index("needs both"), "both makers first")
	testing.expect_value(t, status_of(s, "uses"), Status.Pass)
}

@(test)
what_a_failed_maker_blocks_does_not_run :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	table := []Step{fake("fail maker", makes = {.E2E}), fake("uses", needs = {.E2E}), fake("uses that", needs = {.Guests}, makes = {}), fake("makes other", needs = {.E2E}, makes = {.Guests}), fake("alone")}
	s := run_table(table)
	testing.expect_value(t, status_of(s, "fail maker"), Status.Fail)
	testing.expect_value(t, status_of(s, "uses"), Status.Not_Run)
	testing.expect_value(t, status_of(s, "makes other"), Status.Not_Run)
	testing.expect_value(t, status_of(s, "uses that"), Status.Not_Run)
	testing.expect_value(t, status_of(s, "alone"), Status.Pass)
	for name in order { testing.expect(t, name != "uses" && name != "uses that", "what depends on a failure does not start") }
}

@(test)
the_longest_starts_first :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	table := []Step{fake("short", weight = 1), fake("long", weight = 100), fake("middle", weight = 10)}
	run_table(table, jobs = 1)
	testing.expect_value(t, order[0], "long")
	testing.expect_value(t, order[1], "middle")
	testing.expect_value(t, order[2], "short")
}

@(test)
what_makes_something_starts_before_a_longer_step_when_its_chain_is_longer :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	table := []Step{fake("long alone", weight = 50), fake("build", makes = {.E2E}, weight = 10), fake("what it unlocks", needs = {.E2E}, weight = 60)}
	run_table(table, jobs = 1)
	testing.expect_value(t, order[0], "build")
}

@(test)
a_slot_limits_what_runs_at_a_time :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	table := make([]Step, 6)
	for &step in table { step = fake("step", task = held_task) }
	s := table_scheduler(table, 2, 2)
	schedule_turn(s)
	testing.expect_value(t, s.running[.Heavy], 2)
	sync.atomic_store(&let_go, true)
	schedule(s)
	testing.expect_value(t, s.running[.Heavy], 0)
}

@(test)
the_progress_line_names_the_running_steps :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	table := []Step{fake("held one (a detail)", task = held_task), fake("held two", task = held_task), fake("held three", task = held_task)}
	s := table_scheduler(table, 2, 2)
	schedule_turn(s)
	text := progress_text(s)
	testing.expect(t, strings.contains(text, "0 of 3 steps done"), text)
	testing.expect_value(t, strings.count(text, " held "), 2)   // the two running, not the one waiting for a slot
	testing.expect_value(t, strings.count(text, " s)"), 2)
	testing.expect(t, !strings.contains(text, "a detail"), text)
	sync.atomic_store(&let_go, true)
	schedule(s)
}

@(test)
a_light_step_takes_no_slot_of_the_others :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	table := make([]Step, 6)
	for &step, i in table { step = fake("step", marks = i < 3 ? Marks{.Light} : Marks{}, task = held_task) }
	s := table_scheduler(table, 2, 2)
	schedule_turn(s)
	testing.expect_value(t, s.running[.Heavy], 2)
	testing.expect_value(t, s.running[.Light], 2)
	sync.atomic_store(&let_go, true)
	schedule(s)
}

@(test)
two_build_bat_never_run_at_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	table := []Step{fake("one", marks = {.Browser_Build}, task = held_task), fake("other", marks = {.Browser_Build}, task = held_task)}
	s := table_scheduler(table, 4, 2)
	schedule_turn(s)
	testing.expect_value(t, s.running[.Browser_Build], 1)
	sync.atomic_store(&let_go, true)
	schedule(s)
}

@(test)
a_step_marked_alone_runs_when_nothing_else_does :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	table := []Step{fake("alone", marks = {.Alone}, weight = 100), fake("a"), fake("b")}
	run_table(table)
	testing.expect_value(t, order[len(order) - 1], "alone")
}

@(test)
two_steps_marked_alone_run_one_after_the_other :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	table := []Step{fake("alone 1", marks = {.Alone}), fake("alone 2", marks = {.Alone}), fake("a")}
	run_table(table)
	testing.expect_value(t, len(order), 3)
	testing.expect_value(t, order[0], "a")
}

@(test)
every_action_runs_with_run_all :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	both := Step{name = "both", actions = slice_of(Task{"x", fake_task, "fail first"}, Task{"y", fake_task, "second"}), marks = {.Run_All, .No_Result}}
	stops := Step{name = "stops", actions = slice_of(Task{"x", fake_task, "fail first of stops"}, Task{"y", fake_task, "never"}), marks = {.No_Result}}
	flaky := Step{name = "flaky", actions = slice_of(Task{"x", fake_task, "fail flaky"}), marks = {.Flaky, .No_Result}}
	table := []Step{both, stops, flaky}
	s := run_table(table)
	seen_second, seen_never := false, false
	for n in order {
		if n == "second" { seen_second = true }
		if n == "never" { seen_never = true }
	}
	testing.expect(t, seen_second, "with .Run_All the next action runs after a failure")
	testing.expect(t, !seen_never, "without it the step stops")
	testing.expect_value(t, status_of(s, "both"), Status.Fail)
	testing.expect_value(t, status_of(s, "flaky"), Status.Flaky)
}

// A task that stays until its scheduler tells it to stop.
@(private = "file")
stuck_task :: proc(task: ^Task_Run) -> bool {
	for !sync.atomic_load(&task.kill) { time.sleep(time.Millisecond) }
	return true
}

@(test)
a_stuck_task_is_told_to_stop_and_named :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	step := fake("stuck", task = stuck_task)
	step.limit = 1
	table := []Step{step}
	began := time.tick_now()
	s := run_table(table)
	testing.expect_value(t, s.runs[0].status, Status.Fail)
	testing.expect(t, strings.contains(s.runs[0].why, "stuck"), "it says it was stuck")
	testing.expect(t, time.tick_since(began) < STUCK_TEST_LIMIT, "it was stopped")
}
@(private = "file") STUCK_TEST_LIMIT :: 30 * time.Second

// One cause that makes every step hang costs TIMEOUTS_MOST limits, not one per step: the steps after them do not start.
@(test)
after_five_stuck_steps_no_step_starts :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	// (the two others are light steps with no light slot: they could start only once the stuck ones have ended, never beside them)
	table := make([]Step, TIMEOUTS_MOST + 2)
	for &step, i in table {
		if i < TIMEOUTS_MOST {
			step = fake("stuck", task = stuck_task)
			step.limit = 1
		} else {
			step = fake("waits", marks = {.Light})
		}
	}
	s := run_table(table, jobs = TIMEOUTS_MOST, light = 0)
	counts: [Status]int
	for &r in s.runs { counts[r.status] += 1 }
	testing.expect_value(t, counts[.Fail], TIMEOUTS_MOST)
	testing.expect_value(t, counts[.Not_Run], 2)
	for &r in s.runs { if r.status == .Not_Run { testing.expect(t, strings.contains(r.why, "ran out of time"), r.why) } }
}

// Past -RunTimeoutSec what runs is stopped, and what waits never starts: the run ends before the job's own limit, with its report.
@(test)
the_run_budget_stops_what_runs_and_what_waits :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	// ("after" is a light step with no light slot: it waits until the budget runs out)
	table := []Step{fake("long", task = stuck_task), fake("after", marks = {.Light})}
	s := table_scheduler(table, 1, 0)
	s.cfg.run_timeout = 1
	began := time.tick_now()
	schedule(s)
	testing.expect_value(t, status_of(s, "long"), Status.Fail)
	testing.expect_value(t, status_of(s, "after"), Status.Not_Run)
	testing.expect(t, time.tick_since(began) < STUCK_TEST_LIMIT, "the run was stopped")
}

// A limit from the last duration: a hang costs minutes; never under the floor, never over -StepTimeoutSec; what says by itself whether it has
// anything to do, or has a limit of its own, keeps it.
@(test)
a_step_is_limited_by_its_last_duration :: proc(t: ^testing.T) {
	cfg := Config{step_timeout = STEP_TIMEOUT_SECONDS}
	plain := Step{name = "plain"}
	testing.expect_value(t, step_limit(&cfg, &plain, -1), STEP_TIMEOUT_SECONDS)
	testing.expect_value(t, step_limit(&cfg, &plain, 30), LIMIT_FACTOR * 30)
	testing.expect_value(t, step_limit(&cfg, &plain, 1), LIMIT_FLOOR_SECONDS)
	testing.expect_value(t, step_limit(&cfg, &plain, 3600), STEP_TIMEOUT_SECONDS)
	build := Step{name = "build", marks = {.No_Result}}
	testing.expect_value(t, step_limit(&cfg, &build, 5), STEP_TIMEOUT_SECONDS)
	own := Step{name = "own", limit = 42}
	testing.expect_value(t, step_limit(&cfg, &own, 5), 42)
}

@(test)
checks_are_counted_from_what_a_step_says :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	log := "[Package: x] Finished 12 tests in 1ms. All tests were successful.\nPASS a thing\n  ok \n7 passed, 0 failure(s)\n880 tests in 48 folders, 8 at a time\nnothing here\n"
	testing.expect_value(t, count_checks(log), 12 + 1 + 1 + 7 + 880)
}

// A name cut short keeps what tells it apart: two steps on one log, the second removing it under the first, made a step that had passed a failure.
@(test)
two_steps_never_share_a_log :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	cfg := Config{}
	seen := make(map[string]string)
	for s in build_table(&cfg) {
		log := log_path_of(s.name)
		testing.expectf(t, log not_in seen, "%s and %s write the same log, %s", s.name, seen[log], log)
		seen[log] = s.name
	}
}

@(private = "file") E2E_HARNESS :: "web_harness.odin"

// A file of end-to-end tests belongs to a step: without one its tests compile, and nothing ever runs them (page_scrollbars.odin was one).
@(test)
every_file_of_end_to_end_tests_has_a_step :: proc(t: ^testing.T) {
	if ODIN_OS != .Windows { return }   // (Linux's table runs a part of them)
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	cfg := Config{perf = true}   // (the steps of -Perf too)
	seen := make(map[string]bool)
	seen[E2E_HARNESS] = true     // (its one test ends every process of web tests: Command.also)
	for s in build_table(&cfg) {
		for a in s.actions {
			if c, ok := a.(Command); ok && c.tests_of != "" { seen[filepath.base(c.tests_of)] = true }
		}
	}
	folder := #directory + "/../e2e"
	files, err := os.read_all_directory_by_path(folder, context.allocator)
	testing.expect_value(t, err, nil)
	for f in files {
		if !strings.has_suffix(f.name, ".odin") { continue }
		names, _ := declared_tests(f.fullpath)   // (none in the helpers of a test: it says so as `why`)
		testing.expectf(t, len(names) == 0 || f.name in seen, "%s has tests and no step", f.name)
	}
}
