package test_all

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:text/regex"
import "core:thread"
import "core:time"
import "wb:tools/tooling"

// A run is one small state machine: every step goes Blocked (what it needs is not made yet) -> Ready (longest path first) -> Running (one action after the other) -> Done; a stuck one through
// Dumping on its way. One thread decides, each turn of the loop: what has ended, what that unblocks, what may start. A step's process writes straight into its log, nothing reads it while it runs,
// so nothing waits on a pipe; the only thing the loop waits for is its own tick.

Step_State :: enum { Blocked, Ready, Running, Dumping, Done }
Status :: enum { None, Pass, Fail, Flaky, Cached, Not_Run }
Slot :: enum { Heavy, Light, Asan, Build_Bat }

// How often the loop looks: at most this much of a step's slot goes idle between two steps.
TICK :: 10 * time.Millisecond
// A step with no duration of a last run and no weight is taken for this long, seconds.
DEFAULT_DURATION :: 60
// How long what a stuck step's threads are doing may take to read before it is killed anyway.
DUMP_LIMIT :: 60 * time.Second
ASAN_JOBS :: 3
SUCCESS_MANY :: "All tests were successful"
SUCCESS_ONE :: "The test was successful"

// A task's run on its thread. The loop only reads `done` and sets `kill`.
Task_Run :: struct {
	log, arg: string,
	cfg:      ^Config,
	run:      proc(t: ^Task_Run) -> bool,
	thread:   ^thread.Thread,
	ok:       bool,
	done:     bool,   // (atomic)
	kill:     bool,   // (atomic)
	usage:    tooling.Usage,
	port:     rawptr,   // the profiler's
}

Step_Run :: struct {
	step:     ^Step,
	state:    Step_State,
	status:   Status,
	rank:     f64,        // its own duration and the longest path of the steps that wait for it
	key:      string,     // its result's name in the cache
	log:      string,
	why:      string,     // what a step that did not pass says of itself: stuck, not run...
	action:   int,        // the action it is in
	failed:   bool,       // one of its actions has failed
	stuck:    bool,
	process:  tooling.Process,
	has_process: bool,
	offset:   i64,        // where what this command says begins in the log
	task:     ^Task_Run,
	dump:     ^thread.Thread,
	dump_done: bool,      // (atomic)
	dump_pids: []int,
	began:    time.Tick,
	dump_began: time.Tick,
	seconds, cpu: f64,
	processes, checks: int,
	skips:    []string,
	when_passed: string,  // a cached result: when it passed, and how long it took
	passed_seconds: int,
}

Scheduler :: struct {
	cfg:      ^Config,
	runs:     []Step_Run,
	limits:   [Slot]int,
	running:  [Slot]int,
	by_rank:  []^Step_Run,
	left:     int,          // steps not Done
	cache:    ^Cache,
	cache_dirty: bool,      // a step has ended since the files were last looked at
	began:    time.Tick,
	first_start: f64,       // seconds into the run the first process started
	key_seconds: f64,       // spent on the steps' inputs
	// Where the slots' time went (slot-seconds, of the -Jobs slots): used; free with nothing ready (what is blocked waits for a build); free for the lack of anything left.
	busy_slots, blocked_slots, idle_slots: f64,
	last_tick: time.Tick,
	profile:  ^Profile,
	quiet:    bool,         // (a test of this file: nothing printed)
}

slot_of :: proc(s: ^Step) -> Slot {
	if .Asan in s.marks { return .Asan }
	if .Build_Bat in s.marks { return .Build_Bat }
	return .Light in s.marks ? .Light : .Heavy
}

short_name :: proc(name: string) -> string {
	if i := strings.index(name, " ("); i >= 0 { return name[:i] }
	return name
}

log_path_of :: proc(name: string) -> string {
	SLUG_MOST :: 60
	b := strings.builder_make()
	gap := false
	for c in transmute([]u8)name {
		good := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if good {
			if gap { strings.write_byte(&b, '_') }
			gap = false
			strings.write_byte(&b, c)
		} else {
			gap = strings.builder_len(b) > 0
		}
	}
	slug := strings.to_string(b)
	return fmt.aprintf("%s/%s.log", LOG_DIR, slug[:min(SLUG_MOST, len(slug))])
}

// Whether the marks let it run here, saying so when not.
marks_allow :: proc(s: ^Step, cfg: ^Config, skipped_ci, skipped_ui: ^int) -> bool {
	if .No_CI in s.marks && cfg.on_ci {
		fmt.printfln("ci: skipped on the CI (it runs on a developer's machine): %s", short_name(s.name))
		skipped_ci^ += 1
		return false
	}
	if .Ui_Only in s.marks && !cfg.ui {
		fmt.printfln("ui: skipped, run with -Ui (test_all -Ui, or WREN_UI_TESTS=1): %s", short_name(s.name))
		skipped_ui^ += 1
		return false
	}
	return true
}

// -Only, -Except, -Failed, -Changed: what they leave of the table; a step left brings the steps that make what it needs.
Selection :: struct {
	only, except: regex.Regular_Expression,
	has_only, has_except: bool,
	failed:  map[string]bool,
	changed: []string,
}

read_selection :: proc(cfg: ^Config) -> (sel: Selection) {
	bad :: proc(what, pattern: string, err: regex.Error) -> ! {
		fmt.eprintfln("%s: %s is no regular expression (%v)", what, pattern, err)
		os.exit(EXIT_USAGE)
	}
	if cfg.only != "" {
		r, err := regex.create(cfg.only)
		if err != nil { bad("-Only", cfg.only, err) }
		sel.only, sel.has_only = r, true
	}
	if cfg.except != "" {
		r, err := regex.create(cfg.except)
		if err != nil { bad("-Except", cfg.except, err) }
		sel.except, sel.has_except = r, true
	}
	if cfg.failed {
		data, _ := os.read_entire_file(FAILED_FILE, context.allocator)
		for line in strings.split_lines(string(data)) { if line != "" { sel.failed[line] = true } }
		fmt.printfln("-Failed: %d step(s) of the last run", len(sel.failed))
	}
	if cfg.changed { sel.changed = changed_files(cfg) }
	return
}

matches :: proc(r: regex.Regular_Expression, s: string) -> bool {
	cap, ok := regex.match_and_allocate_capture(r, s)
	regex.destroy_capture(cap)
	return ok
}

// What git says changed since -Base (default: where this branch left master), the working tree's changes included.
changed_files :: proc(cfg: ^Config) -> []string {
	base := cfg.base
	if base == "" {
		text, code := tooling.capture({"git", "merge-base", "HEAD", "master"})
		if code == 0 { base = strings.trim_space(text) }
	}
	if base == "" {
		fmt.println("no -Base and no merge base with master: every step is chosen")
		base = "HEAD"
	}
	seen: map[string]bool
	out: [dynamic]string
	add :: proc(seen: ^map[string]bool, out: ^[dynamic]string, path: string) {
		p, _ := strings.replace_all(path, "\\", "/")
		if p != "" && p not_in seen^ { seen[p] = true; append(out, p) }
	}
	diff, _ := tooling.capture({"git", "diff", "--name-only", base, "--"})
	for l in strings.split_lines(diff) { add(&seen, &out, strings.trim_space(l)) }
	status, _ := tooling.capture({"git", "status", "--porcelain", "--untracked-files=all"})
	PORCELAIN_NAME_AT :: 3
	for l in strings.split_lines(status) { if len(l) > PORCELAIN_NAME_AT { add(&seen, &out, strings.trim(l[PORCELAIN_NAME_AT:], "\" ")) } }
	toolkit, _ := tooling.capture({"git", "-C", "ext/gui_toolkit", "status", "--porcelain", "--untracked-files=all"})
	for l in strings.split_lines(toolkit) { if len(l) > PORCELAIN_NAME_AT { add(&seen, &out, strings.concatenate({"ext/gui_toolkit/", strings.trim(l[PORCELAIN_NAME_AT:], "\" ")})) } }
	fmt.printfln("-Changed: %d file(s) changed since %s", len(out), base)
	return out[:]
}

is_chosen :: proc(s: ^Step, sel: ^Selection, cfg: ^Config, c: ^Cache) -> bool {
	if sel.has_only && !matches(sel.only, s.name) { return false }
	if sel.has_except && matches(sel.except, s.name) { return false }
	if cfg.failed && s.name not_in sel.failed { return false }
	if cfg.changed {
		inputs := step_inputs(c, s)
		set := make(map[string]bool, len(inputs), context.temp_allocator)
		for f in inputs { set[strings.to_lower(f, context.temp_allocator)] = true }
		for changed in sel.changed {
			if strings.to_lower(changed, context.temp_allocator) in set { return true }
			// (a submodule's new commit is one line: everything in it)
			if changed == "ext/gui_toolkit" || changed == "ext/lexbor" {
				for f in inputs { if strings.has_prefix(f, strings.concatenate({changed, "/"}, context.temp_allocator)) { return true } }
			}
		}
		return false
	}
	return true
}

// The steps of this run: what the marks and the selection leave, and what they need.
choose_steps :: proc(cfg: ^Config, table: []Step, c: ^Cache, skipped_ci, skipped_ui, left_out: ^int) -> []^Step {
	allowed: [dynamic]^Step
	for &s in table { if marks_allow(&s, cfg, skipped_ci, skipped_ui) { append(&allowed, &s) } }
	selecting := cfg.only != "" || cfg.except != "" || cfg.failed || cfg.changed
	if !selecting { return allowed[:] }
	sel := read_selection(cfg)
	chosen := make(map[^Step]bool)
	queue: [dynamic]^Step
	for s in allowed {
		if is_chosen(s, &sel, cfg, c) { chosen[s] = true; append(&queue, s) }
		free_all(context.temp_allocator)
	}
	for len(queue) > 0 {
		s := pop(&queue)
		for other in allowed {
			if other not_in chosen && other.makes & s.needs != {} { chosen[other] = true; append(&queue, other) }
		}
	}
	out: [dynamic]^Step
	for s in allowed { if s in chosen { append(&out, s) } }
	left_out^ = len(allowed) - len(out)
	return out[:]
}

scheduler_make :: proc(cfg: ^Config, steps: []^Step, durations: ^map[string]int, c: ^Cache) -> ^Scheduler {
	s := new(Scheduler)
	s.cfg, s.cache = cfg, c
	s.limits = {.Heavy = cfg.jobs, .Light = cfg.light_jobs, .Asan = ASAN_JOBS, .Build_Bat = 1}
	s.runs = make([]Step_Run, len(steps))
	s.by_rank = make([]^Step_Run, len(steps))
	for st, i in steps {
		s.runs[i] = {step = st, log = log_path_of(st.name)}
		s.by_rank[i] = &s.runs[i]
	}
	own := make([]f64, len(steps), context.temp_allocator)
	for st, i in steps {
		own[i] = DEFAULT_DURATION
		if d, ok := durations[st.name]; ok { own[i] = f64(d) } else if st.weight > 0 { own[i] = f64(st.weight) }
	}
	// its duration and that of the longest chain below it: what makes something others wait for starts first
	rank_of :: proc(s: ^Scheduler, own: []f64, i: int) -> f64 {
		if s.runs[i].rank > 0 { return s.runs[i].rank }
		below := 0.0
		for &r, j in s.runs { if r.step.needs & s.runs[i].step.makes != {} { below = max(below, rank_of(s, own, j)) } }
		s.runs[i].rank = own[i] + below + 1
		return s.runs[i].rank
	}
	for i in 0 ..< len(s.runs) { rank_of(s, own, i) }
	slice.sort_by(s.by_rank, proc(a, b: ^Step_Run) -> bool { return a.rank > b.rank })
	s.left = len(steps)
	s.began = time.tick_now()
	s.last_tick = s.began
	s.cache_dirty = true
	return s
}

// One turn after the other until every step is Done.
schedule :: proc(s: ^Scheduler) {
	for s.left > 0 {
		schedule_turn(s)
		time.sleep(TICK)
		free_all(context.temp_allocator)
	}
}

schedule_turn :: proc(s: ^Scheduler) {
	for &r in s.runs {
		switch r.state {
		case .Running: advance(s, &r)
		case .Dumping: advance_dump(s, &r)
		case .Blocked, .Ready, .Done:
		}
	}
	unblock(s)
	admit(s)
	account(s)
}

// A step whose makers have ended is Ready; if one of them did not pass it will not run.
unblock :: proc(s: ^Scheduler) {
	for &r in s.runs {
		if r.state != .Blocked { continue }
		ready := true
		blocker := ""
		for &m in s.runs {
			if m.step.makes & r.step.needs == {} { continue }
			if m.state != .Done { ready = false; break }
			if m.status == .Fail || m.status == .Not_Run { blocker = m.step.name }
		}
		if !ready { continue }
		if blocker != "" {
			r.why = fmt.aprintf("not run: %s did not pass", short_name(blocker))
			finish(s, &r, .Not_Run)
			continue
		}
		r.state = .Ready
	}
}

// The longest first: what has passed with these inputs does not take a slot, what has a slot free starts.
admit :: proc(s: ^Scheduler) {
	for r in s.by_rank {
		if r.state != .Ready { continue }
		if s.cfg.use_cache && .No_Result not_in r.step.marks && r.key == "" {
			clock := time.tick_now()
			if s.cache_dirty { cache_look_again(s.cache); s.cache_dirty = false }
			r.key = step_key(s.cache, r.step)
			hit, found := result_of(s.cache, r.key, r.step)
			s.key_seconds += time.duration_seconds(time.tick_since(clock))
			if found {
				r.when_passed, r.passed_seconds, r.checks = hit.when_, hit.seconds, hit.checks
				finish(s, r, .Cached)
				continue
			}
		}
		if .Alone in r.step.marks {
			others := 0
			for &o in s.runs { if &o != r && o.state != .Done { others += 1 } }
			if others > 0 { continue }
		}
		slot := slot_of(r.step)
		if s.running[slot] >= s.limits[slot] { continue }
		s.running[slot] += 1
		r.state = .Running
		r.began = time.tick_now()
		if s.first_start == 0 { s.first_start = max(time.duration_seconds(time.tick_since(s.began)), 0.001) }
		_ = os.remove(r.log)
		start_action(s, r)
	}
}

// Starts the action the step is at; an action that cannot start has failed.
start_action :: proc(s: ^Scheduler, r: ^Step_Run) {
	switch a in r.step.actions[r.action] {
	case Command:
		argv := a.argv
		if a.tests_of != "" {
			names, why := declared_tests(a.tests_of)
			if why != "" {
				tooling.append_text(r.log, fmt.tprintln(why))
				action_ended(s, r, false)
				return
			}
			if a.also != "" { append(&names, a.also) }
			argv = join(a.argv, {fmt.aprintf("-tests:%s", strings.join(names[:], ",", context.temp_allocator))})
		}
		r.offset = file_size(r.log)
		spawn_argv := slice.clone(argv, context.temp_allocator)
		if spawn_argv[0] == "odin" { spawn_argv[0] = tooling.odin_program() }
		p, why := tooling.spawn(s.profile != nil ? profile_spawn(s.profile, r, spawn_argv, a) : tooling.Spawn{command = spawn_argv, env = a.env, dir = a.dir, log = r.log})
		if why != "" {
			tooling.append_text(r.log, fmt.tprintfln("%s cannot start: %s", argv[0], why))
			action_ended(s, r, false)
			return
		}
		r.process, r.has_process = p, true
	case Task:
		tr := new(Task_Run)
		tr.log, tr.arg, tr.cfg, tr.run = r.log, a.arg, s.cfg, a.run
		if s.profile != nil { tr.port = profile_port(s.profile) }
		r.task = tr
		tr.thread = thread.create_and_start_with_poly_data(tr, task_thread, context)
	}
}

task_thread :: proc(t: ^Task_Run) {
	tooling.task_usage = &t.usage
	tooling.task_port = t.port
	t.ok = t.run(t)
	sync.atomic_store(&t.done, true)
}

// A command for a task, under the task's kill. Its exit code.
task_exec :: proc(t: ^Task_Run, command: []string, env: []string = nil, dir := "") -> int {
	argv := slice.clone(command, context.temp_allocator)
	if argv[0] == "odin" { argv[0] = tooling.odin_program() }
	p, why := tooling.spawn({command = argv, env = env, dir = dir, log = t.log})
	if why != "" {
		tooling.append_text(t.log, fmt.tprintfln("%s cannot start: %s", command[0], why))
		return -1
	}
	code := 0
	for {
		done, c := tooling.poll(&p)
		if done { code = c; break }
		if sync.atomic_load(&t.kill) { tooling.kill_tree(&p) }
		time.sleep(tooling.WAIT_SLICE)
	}
	tooling.count_usage(&p)
	tooling.release(&p)
	return code
}

task_say :: proc(t: ^Task_Run, format: string, args: ..any) {
	tooling.append_text(t.log, fmt.tprintfln(format, ..args))
}

// What a running step's action has come to.
advance :: proc(s: ^Scheduler, r: ^Step_Run) {
	limit := r.step.limit > 0 ? r.step.limit : s.cfg.step_timeout
	if time.duration_seconds(time.tick_since(r.began)) > f64(limit) && !r.stuck {
		r.stuck = true
		r.why = fmt.aprintf("stuck: killed after %d s", limit)
		tooling.append_text(r.log, fmt.tprintfln("\n%s", r.why))
		print_line(s, fmt.tprintfln("watchdog: %s has run for %d s: what it is doing goes to its log, then it is killed", short_name(r.step.name), limit))
		if r.has_process {
			begin_dump(r)
		} else if r.task != nil {
			sync.atomic_store(&r.task.kill, true)
		}
		return
	}
	if r.has_process {
		done, code := tooling.poll(&r.process)
		if !done { return }
		command := r.step.actions[r.action].(Command)
		ok := code == 0
		if ok && command.rule == .Says_Successful { ok = log_says_successful(r.log, r.offset) }
		if code != 0 { tooling.append_text(r.log, fmt.tprintfln("(exit code %d: 0x%8X)", code, u32(i32(code)))) }
		collect_process(s, r)
		action_ended(s, r, ok)
		return
	}
	if r.task != nil && sync.atomic_load(&r.task.done) {
		thread.join(r.task.thread)
		thread.destroy(r.task.thread)
		ok := r.task.ok
		r.cpu += r.task.usage.cpu_seconds
		r.processes += r.task.usage.processes
		r.task = nil
		action_ended(s, r, ok)
	}
}

// The tree's account, and what it left running: nothing of a step outlives it, it would hold its program against the next build.
collect_process :: proc(s: ^Scheduler, r: ^Step_Run) {
	u := tooling.usage(&r.process)
	r.cpu += u.cpu_seconds
	r.processes += u.processes
	if left := tooling.tree_active(&r.process); left > 0 {
		print_line(s, fmt.tprintfln("left running by a step: %d process(es) of %s: stopped", left, short_name(r.step.name)))
		tooling.append_text(r.log, fmt.tprintfln("(%d process(es) left running: stopped)", left))
	}
	tooling.release(&r.process)
	r.has_process = false
}

begin_dump :: proc(r: ^Step_Run) {
	r.state = .Dumping
	r.dump_began = time.tick_now()
	r.dump_pids = slice.clone(tooling.tree_pids(&r.process))
	r.dump = thread.create_and_start_with_poly_data(r, dump_thread, context)
}

// What the threads of a stuck tree are doing (wren ctl stacks needs no Wren: this is the same code), on a thread of its own: reading the symbols takes seconds.
dump_thread :: proc(r: ^Step_Run) {
	for pid in r.dump_pids {
		tooling.append_text(r.log, process_stacks_text(pid))
		free_all(context.temp_allocator)
	}
	sync.atomic_store(&r.dump_done, true)
}

advance_dump :: proc(s: ^Scheduler, r: ^Step_Run) {
	if !sync.atomic_load(&r.dump_done) && time.tick_since(r.dump_began) < DUMP_LIMIT { return }
	tooling.kill_tree(&r.process)
	if done, _ := tooling.poll(&r.process); !done { return }
	collect_process(s, r)
	r.state = .Running
	r.failed = true
	r.action = len(r.step.actions) - 1
	action_ended(s, r, false)
}

action_ended :: proc(s: ^Scheduler, r: ^Step_Run, ok: bool) {
	s.cache_dirty = true
	if !ok || r.stuck { r.failed = true }
	r.action += 1
	if r.action < len(r.step.actions) && !r.stuck && (ok || .Run_All in r.step.marks) {
		start_action(s, r)
		return
	}
	r.seconds = time.duration_seconds(time.tick_since(r.began))
	s.running[slot_of(r.step)] -= 1
	status := Status.Pass
	if r.failed { status = .Flaky in r.step.marks ? .Flaky : .Fail }
	finish(s, r, status)
}

log_says_successful :: proc(log: string, offset: i64) -> bool {
	data, err := os.read_entire_file(log, context.temp_allocator)
	if err != nil || offset > i64(len(data)) { return false }
	text := string(data[offset:])
	return strings.contains(text, SUCCESS_MANY) || strings.contains(text, SUCCESS_ONE)
}

file_size :: proc(path: string) -> i64 {
	fi, err := os.stat(path, context.temp_allocator)
	return err == nil ? fi.size : 0
}

finish :: proc(s: ^Scheduler, r: ^Step_Run, status: Status) {
	r.state = .Done
	r.status = status
	s.left -= 1
	if status == .Pass || status == .Fail || status == .Flaky { read_log_facts(r) }
	if status == .Pass && s.cfg.use_cache && r.key != "" && .No_Result not_in r.step.marks {
		// (a source edited while it ran: another run's)
		cache_look_again(s.cache)
		if step_key(s.cache, r.step) == r.key { result_save(s.cache, r.key, r.step, int(r.seconds), r.checks) }
	}
	print_step(s, r)
}

print_line :: proc(s: ^Scheduler, text: string) {
	if !s.quiet { fmt.print(text) }
}

// Where the time of the slots goes.
account :: proc(s: ^Scheduler) {
	dt := time.duration_seconds(time.tick_since(s.last_tick))
	s.last_tick = time.tick_now()
	free_slots := max(s.limits[.Heavy] - s.running[.Heavy], 0)
	s.busy_slots += dt * f64(s.running[.Heavy])
	blocked := false
	for &r in s.runs { if r.state == .Blocked { blocked = true; break } }
	if blocked { s.blocked_slots += dt * f64(free_slots) } else { s.idle_slots += dt * f64(free_slots) }
}
