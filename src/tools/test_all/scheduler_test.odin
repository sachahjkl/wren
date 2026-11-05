package test_all

import "base:runtime"
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

@(test)
a_stuck_task_is_told_to_stop_and_named :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (what a run keeps until it ends)
	stuck_task :: proc(task: ^Task_Run) -> bool {
		for !sync.atomic_load(&task.kill) { time.sleep(time.Millisecond) }
		return true
	}
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
