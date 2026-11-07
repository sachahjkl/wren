// `wrentool replay`: a load that can be measured to the percent. `record` keeps what a site served for one load, on a throwaway profile, in build/replay/<site>;
// `run` serves those bytes from this process (tools/testserver/replay.go) to a Wren whose page has a seeded random and a clock of its own (base/test_world.odin), arm
// after arm, the order turning, and says per load what docs/testing.md lists. Nothing of the machine is touched: every name reaches the server through network.hosts,
// its certificates through network.tls.extra_ca_file, and network.loopback_only keeps a load from leaving the machine.
package capture

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "wb:base"
import "wb:remote/api"
import "wb:testserver"
import "wb:tools/tooling"
import "wb:tools/wrentool/bench"
import "wb:tools/wrentool/measure"

REPLAY_FLAGS :: "-Urls= -Sites= -Dir= -Exe= -Arms= -ArmPref= -ListArms= -Runs= -Warmup= -Pref= -Lists= -Seed= -Out= -NoFrames -Loaded"
REPLAY_DIR :: "build/replay"
REPLAY_WORLD_FILE :: "world.txt"   // "<seed>,<unix ms>\n<url>\n"
REPLAY_SEED :: 51
REPLAY_RUNS :: 7
REPLAY_WARMUP :: 1
// What a load may take to reach its load event, and after it to settle: past that it says it did not.
REPLAY_LOAD_LIMIT :: 60 * time.Second
REPLAY_SETTLE_LIMIT :: 20 * time.Second
// What a recording keeps listening for once the thread has settled: what a page asks for a moment later is replayed then too.
REPLAY_RECORD_TAIL :: 10 * time.Second
// How often the window thread's counter is read, from outside it: the system's sleep rounds this up to its tick.
REPLAY_SAMPLE_EVERY :: 5 * time.Millisecond
REPLAY_SETTLE_LOOK_EVERY :: 100 * time.Millisecond
// No tool holds a lock, and agents and test runs share this machine: a load starts when at most REPLAY_QUIET_SHARE of the processors are at work, and one during which others took
// more than REPLAY_OTHERS_MOST of them is said, dropped and made again, at most REPLAY_RETRIES times. A loaded machine took a load of theverge.com from 3.5 s to 11.
// -Loaded measures all the same, every load with its `others`: for a machine that does not go quiet, and a floor that says so.
REPLAY_QUIET_SHARE :: 0.08
REPLAY_QUIET_LIMIT :: 5 * time.Minute
REPLAY_QUIET_LOOK :: time.Second
REPLAY_OTHERS_MOST :: 0.08
REPLAY_RETRIES :: 5
// The frames: scaled to this share of the viewport (1280 x 800 less the shell: about 160 by 90 cells), as many as a load can draw.
REPLAY_FRAME_SCALE :: 0.125
REPLAY_FRAMES_MOST :: 1500
// `lists`: how long the fetch and the compile of the lists may take, and how long the folder stays quiet before they are taken as done.
REPLAY_LISTS_LIMIT :: 5 * time.Minute
REPLAY_LISTS_LOOK_EVERY :: time.Second
REPLAY_LISTS_QUIET :: 15 * time.Second
// A load's numbers, one line each in <Out>.
REPLAY_HEADER :: "site\tarm\trun\tfcp\tready\tsettled\tcpu_settled\tload\tdcl\tcpu_load\tguest\tprocess_cpu\trequests\tfailed\texact\tnear\tunknown\tframes\tmoving\tothers\tpage_clock"

Replay_Load :: struct {
	fcp, ready, settled, cpu_settled, load, dcl, cpu_load, guest, process_cpu: f64,
	requests, failed, exact, near, unknown, frames: int,
	moving, others, page_clock: f64,   // page_clock: performance.now() at the end, against `settled`: how the test world's clock kept up
}

Replay_Arm :: struct { name, exe, lists: string, prefs: []string }

// The columns a series is summed up on: the first three decide (measure.verdict), the rest are said beside them.
Replay_Metric :: struct { name: string, of: proc(l: Replay_Load) -> f64 }
REPLAY_METRICS :: [?]Replay_Metric{
	{"visually ready", proc(l: Replay_Load) -> f64 { return l.ready }},
	{"settled", proc(l: Replay_Load) -> f64 { return l.settled }},
	{"CPU to settled", proc(l: Replay_Load) -> f64 { return l.cpu_settled }},
	{"FCP", proc(l: Replay_Load) -> f64 { return l.fcp }},
	{"load", proc(l: Replay_Load) -> f64 { return l.load }},
	{"DCL", proc(l: Replay_Load) -> f64 { return l.dcl }},
	{"CPU to load", proc(l: Replay_Load) -> f64 { return l.cpu_load }},
	{"Guest to load", proc(l: Replay_Load) -> f64 { return l.guest }},
}

run_replay :: proc(args: []string) -> int {
	if len(args) == 0 { return replay_usage() }
	f, ok := tooling.parse_flags(args[1:], REPLAY_FLAGS)
	if !ok { return EXIT_USAGE }
	switch args[0] {
	case "record": return replay_record(f)
	case "run":    return replay_run(f)
	case "lists":  return replay_lists(f)
	}
	return replay_usage()
}

@(private = "file")
replay_usage :: proc() -> int {
	fmt.eprintln("wrentool replay record -Urls a,b [-Dir d] [-Exe path] [-Seed n]")
	fmt.eprintln("wrentool replay lists [-Dir d] [-Exe path]")
	fmt.eprintln("wrentool replay run -Sites a,b [-Dir d] [-Arms x=path,y=path] [-ArmPref x:a=b,y:c=d] [-Runs n] [-Warmup n] [-Pref a=b] [-Lists folder [-ListArms x,y]] [-Out file] [-NoFrames] [-Loaded]")
	return EXIT_USAGE
}

// The window thread's counter, read from a thread of this program: nothing is asked of the browser.
@(private = "file")
Sampler :: struct {
	reader:  bench.Thread_Reader,
	started: time.Tick,
	samples: [dynamic]measure.Sample,
	lock:    sync.Mutex,
	stop:    bool,
	thread:  ^thread.Thread,
}

@(private = "file")
sampler_start :: proc(s: ^Sampler, window_thread: int) -> bool {
	s.reader = bench.thread_reader(window_thread)
	if !bench.thread_reader_ok(s.reader) { return false }
	s.started = time.tick_now()
	s.samples = make([dynamic]measure.Sample)
	s.thread = thread.create_and_start_with_data(s, proc(data: rawptr) {
		s := (^Sampler)(data)
		for !sync.atomic_load(&s.stop) {
			one := measure.Sample{time.duration_milliseconds(time.tick_since(s.started)), bench.thread_read(s.reader)}
			sync.lock(&s.lock)
			append(&s.samples, one)
			sync.unlock(&s.lock)
			time.sleep(REPLAY_SAMPLE_EVERY)
		}
	})
	return true
}

@(private = "file")
sampler_stop :: proc(s: ^Sampler) {
	sync.atomic_store(&s.stop, true)
	thread.join(s.thread)
	thread.destroy(s.thread)
	bench.thread_reader_close(s.reader)
	delete(s.samples)
}

// Until the thread has settled after `from_ms`, or the limit: the index of the moment, in the samples as they stand.
@(private = "file")
sampler_settled :: proc(s: ^Sampler, from_ms, cycles_per_ms: f64) -> (index: int, ok: bool) {
	limit := time.tick_now()
	for time.tick_since(limit) < REPLAY_SETTLE_LIMIT {
		sync.lock(&s.lock)
		index, ok = measure.settled_find(s.samples[:], from_ms, cycles_per_ms)
		sync.unlock(&s.lock)
		if ok { return }
		time.sleep(REPLAY_SETTLE_LOOK_EVERY)
	}
	return
}

@(private = "file")
cycles_per_ms :: proc() -> f64 {
	hz, _ := time.tsc_frequency()
	return f64(hz) / 1000
}

@(private = "file")
replay_record :: proc(f: tooling.Flags) -> int {
	urls := tooling.flag_list(f, "-Urls")
	if len(urls) == 0 { return replay_usage() }
	exe := tooling.flag(f, "-Exe", bench.WREN_EXE)
	dir := tooling.flag(f, "-Dir", REPLAY_DIR)
	seed := tooling.flag_int(f, "-Seed", REPLAY_SEED)
	rate := cycles_per_ms()
	for url in urls {
		site := fmt.tprintf("%s/%s", dir, compare_slug(url))
		base.remove_tree(site)
		_ = os.make_directory_all(site)
		start_ms := f64(time.to_unix_nanoseconds(time.now()) / 1_000_000)
		world := fmt.tprintf("%d,%.0f", seed, start_ms)
		profile := fmt.tprintf("%s_profile", site)
		base.remove_tree(profile)
		// (no blocker: the recording holds all a page asks for, whatever a list later refuses)
		prefs := []string{"blocker.enabled=false", "blocker.update.enabled=false", "blocker.welcome_toast=false"}
		env := []string{fmt.tprintf("%s=%s", base.TEST_WORLD_ENV, world), fmt.tprintf("WREN_TEST_RECORD=%s", site)}
		w: bench.Wren
		if !bench.start(&w, {exe = exe, profile = profile, window = .Headless, size = SWEEP_SIZE, prefs = prefs, env = env}) { return 1 }
		stats, _ := api.stats(&w.session)
		s: Sampler
		if !sampler_start(&s, stats.window_thread) { bench.stop(&w); fmt.eprintln("the window thread cannot be read"); return 1 }
		e := api.navigate(&w.session, url, .Load, REPLAY_LOAD_LIMIT)
		n, _ := api.network(&w.session)
		_, settled := sampler_settled(&s, n.doc.load, rate)
		time.sleep(REPLAY_RECORD_TAIL)
		sampler_stop(&s)
		bench.stop(&w)
		base.remove_tree(profile)
		_ = os.write_entire_file(fmt.tprintf("%s/%s", site, REPLAY_WORLD_FILE), fmt.tprintf("%s\n%s\n", world, url))
		fmt.printfln("%s: %d requests, load %.0f ms%s%s -> %s", url, len(n.requests), n.doc.load, e != .None ? " (no load event)" : "", settled ? "" : ", did not settle", site)
		free_all(context.temp_allocator)
	}
	return 0
}

// What a user has some seconds after a first start: the lists on by default, fetched and compiled, kept in <Dir>/lists for `run -Lists`. The newest of the folder's files
// says when: the compile writes the engine's key after the last list came.
@(private = "file")
replay_lists :: proc(f: tooling.Flags) -> int {
	dir := tooling.flag(f, "-Dir", REPLAY_DIR)
	profile := fmt.tprintf("%s/lists_profile", dir)
	base.remove_tree(profile)
	defer base.remove_tree(profile)
	prefs := []string{"blocker.update.enabled=true", "blocker.update.start_delay_s=1", "blocker.welcome_toast=false"}
	w: bench.Wren
	if !bench.start(&w, {exe = tooling.flag(f, "-Exe", bench.WREN_EXE), profile = profile, window = .Headless, size = SWEEP_SIZE, prefs = prefs}) { return 1 }
	key := fmt.tprintf("%s/blocker/cache/engine.key", profile)
	list_dir := fmt.tprintf("%s/blocker/lists", profile)
	started := time.tick_now()
	done := false
	for !done && time.tick_since(started) < REPLAY_LISTS_LIMIT {
		time.sleep(REPLAY_LISTS_LOOK_EVERY)
		lists, _ := os.read_all_directory_by_path(list_dir, context.temp_allocator)
		made, err := os.stat(key, context.temp_allocator)
		if len(lists) == 0 || err != nil { continue }
		newest := lists[0].modification_time
		for l in lists { if time.diff(newest, l.modification_time) > 0 { newest = l.modification_time } }
		// (quiet for a while, and compiled since: a list that comes later starts it again)
		done = time.diff(newest, made.modification_time) > 0 && time.since(made.modification_time) > REPLAY_LISTS_QUIET
	}
	bench.stop(&w)
	if !done { fmt.eprintln("the lists did not come"); return 1 }
	out := fmt.tprintf("%s/lists", dir)
	base.remove_tree(out)
	if err := os.copy_directory_all(out, fmt.tprintf("%s/blocker", profile)); err != nil { fmt.eprintfln("cannot copy to %s: %v", out, err); return 1 }
	lists, _ := os.read_all_directory_by_path(fmt.tprintf("%s/lists", out), context.temp_allocator)
	fmt.printfln("%d lists -> %s", len(lists), out)
	return 0
}

// A recording's folder: its world and its address.
@(private = "file")
replay_site :: proc(folder: string) -> (world, url: string, ok: bool) {
	data, err := os.read_entire_file(fmt.tprintf("%s/%s", folder, REPLAY_WORLD_FILE), context.temp_allocator)
	if err != nil { return }
	lines := strings.split_lines(string(data), context.temp_allocator)
	if len(lines) < 2 { return }
	return lines[0], lines[1], true
}

@(private = "file")
replay_arms :: proc(f: tooling.Flags) -> []Replay_Arm {
	arms := make([dynamic]Replay_Arm)
	list := tooling.flag_list(f, "-Arms")
	for spec in list {
		eq := strings.index_byte(spec, '=')
		if eq > 0 { append(&arms, Replay_Arm{name = spec[:eq], exe = spec[eq + 1:]}) }
	}
	if len(arms) == 0 { append(&arms, Replay_Arm{name = "a", exe = bench.WREN_EXE}, Replay_Arm{name = "b", exe = bench.WREN_EXE}) }
	for &arm in arms {
		mine := make([dynamic]string)
		for spec in tooling.flag_list(f, "-ArmPref") {
			if strings.has_prefix(spec, fmt.tprintf("%s:", arm.name)) { append(&mine, spec[len(arm.name) + 1:]) }
		}
		arm.prefs = mine[:]
		chosen := tooling.flag_list(f, "-ListArms")
		if len(chosen) == 0 || slice.contains(chosen, arm.name) { arm.lists = tooling.flag(f, "-Lists") }
	}
	return arms[:]
}

@(private = "file")
replay_run :: proc(f: tooling.Flags) -> int {
	sites := tooling.flag_list(f, "-Sites")
	if len(sites) == 0 { return replay_usage() }
	dir := tooling.flag(f, "-Dir", REPLAY_DIR)
	arms := replay_arms(f)
	runs := tooling.flag_int(f, "-Runs", REPLAY_RUNS)
	warmup := tooling.flag_int(f, "-Warmup", REPLAY_WARMUP)
	frames := !tooling.flag_has(f, "-NoFrames")
	rate := cycles_per_ms()
	if _, why := testserver.start(); why != "" { fmt.eprintln(why); return 1 }
	out_dir, _ := filepath.abs(fmt.tprintf("%s/out", dir), context.allocator)
	_ = os.make_directory_all(out_dir)
	ca := fmt.aprintf("%s/testca.pem", out_dir)
	if os.write_entire_file(ca, testserver.ca_pem(context.temp_allocator)) != nil { fmt.eprintfln("cannot write %s", ca); return 1 }
	table := strings.builder_make()
	fmt.sbprintln(&table, REPLAY_HEADER)
	fmt.println(REPLAY_HEADER)
	summary := strings.builder_make()
	for spec in sites {
		folder := fmt.aprintf("%s/%s", dir, compare_slug(spec))
		abs_folder, _ := filepath.abs(folder, context.allocator)
		world, url, ok := replay_site(folder)
		if !ok { fmt.eprintfln("%s holds no recording (wrentool replay record -Urls ...)", folder); return 1 }
		world, url = strings.clone(world), strings.clone(url)
		port, why := testserver.replay_start(abs_folder)
		if port == 0 { fmt.eprintln(why); return 1 }
		common := make([dynamic]string)
		append(&common, fmt.aprintf("network.hosts=*=127.0.0.1:%d", port), fmt.aprintf("network.tls.extra_ca_file=%s", ca), "network.loopback_only=true", "network.http3.enabled=false", "network.proxy.mode=none", "blocker.update.enabled=false", "blocker.welcome_toast=false")
		for p in tooling.flag_list(f, "-Pref") { append(&common, p) }
		results := make([][dynamic]Replay_Load, len(arms))
		for run in -warmup ..< runs {
			for i in 0 ..< len(arms) {
				// (the order turns: what the machine does in the first half of a pair falls on each arm in turn)
				at := (i + max(run, 0)) % len(arms)
				arm := arms[at]
				prefs := make([dynamic]string, context.temp_allocator)
				append(&prefs, ..common[:])
				append(&prefs, ..arm.prefs)
				l, loaded := replay_watched(arm, out_dir, url, world, prefs[:], rate, spec, tooling.flag_has(f, "-Loaded"))
				if !loaded { fmt.eprintfln("%s %s run %d: no load", spec, arm.name, run); continue }
				if frames { replay_frames(&l, arm.exe, out_dir, url, world, prefs[:], arm.lists) }
				line := fmt.tprintf("%s\t%s\t%d\t%.0f\t%.0f\t%.0f\t%.1f\t%.0f\t%.0f\t%.1f\t%.1f\t%.0f\t%d\t%d\t%d\t%d\t%d\t%d\t%.3f", spec, arm.name, run, l.fcp, l.ready, l.settled, l.cpu_settled, l.load, l.dcl, l.cpu_load, l.guest, l.process_cpu, l.requests, l.failed, l.exact, l.near, l.unknown, l.frames, l.moving, l.others, l.page_clock)
				fmt.println(line)
				if run >= 0 {
					fmt.sbprintln(&table, line)
					append(&results[at], l)
				}
				free_all(context.temp_allocator)
			}
		}
		replay_summary(&summary, spec, arms, results)
	}
	fmt.print(strings.to_string(summary))
	if out := tooling.flag(f, "-Out"); out != "" {
		_ = os.write_entire_file(out, strings.to_string(table))
		_ = os.write_entire_file(fmt.tprintf("%s.summary.txt", out), strings.to_string(summary))
	}
	return 0
}

// A Wren of its own for one load, on a profile with nothing in it but the lists it is given.
@(private = "file")
replay_open :: proc(w: ^bench.Wren, exe, profile, world: string, prefs: []string, lists: string) -> bool {
	base.remove_tree(profile)
	if lists != "" {
		_ = os.make_directory_all(profile)
		if err := os.copy_directory_all(fmt.tprintf("%s/blocker", profile), lists); err != nil { fmt.eprintfln("cannot copy %s: %v", lists, err); return false }
	}
	testserver.replay_rewind()
	env := []string{fmt.tprintf("%s=%s", base.TEST_WORLD_ENV, world)}
	return bench.start(w, {exe = exe, profile = profile, window = .Headless, size = SWEEP_SIZE, prefs = prefs, env = env})
}

// The load that is measured: nothing watches it but the sampler, which asks nothing of the browser.
@(private = "file")
replay_load :: proc(exe, out_dir, url, world: string, prefs: []string, lists: string, rate: f64, site: string) -> (l: Replay_Load, ok: bool) {
	profile := fmt.tprintf("%s/profile", out_dir)
	defer base.remove_tree(profile)
	w: bench.Wren
	if !replay_open(&w, exe, profile, world, prefs, lists) { return }
	defer bench.stop(&w)
	session := &w.session
	before, _ := api.stats(session)
	s: Sampler
	if !sampler_start(&s, before.window_thread) { fmt.eprintln("the window thread cannot be read"); return }
	defer sampler_stop(&s)
	if api.navigate(session, url, .Load, REPLAY_LOAD_LIMIT) != .None { return }
	n, e := api.network(session)
	if e != .None { return }
	index, settled := sampler_settled(&s, n.doc.load, rate)
	if settled {
		sync.lock(&s.lock)
		l.settled = s.samples[index].ms
		l.cpu_settled = f64(s.samples[index].cycles - s.samples[0].cycles) / rate
		sync.unlock(&s.lock)
	}
	n, _ = api.network(session)
	samples_dump(&s, out_dir, site, rate)
	after, _ := api.stats(session)
	l.page_clock, _ = api.eval_f64(session, "performance.now()")
	l.fcp, l.load, l.dcl = n.doc.contentful, n.doc.load, n.doc.dcl
	l.cpu_load, l.guest = n.doc.load_cycles / rate, n.doc.load_guest
	l.process_cpu = after.cpu_time_ms - before.cpu_time_ms
	for q in n.requests {
		l.requests += 1
		if q.failed { l.failed += 1 }
	}
	exact, near, unknown, missed := testserver.replay_counts(context.temp_allocator)
	l.exact, l.near, l.unknown = exact, near, unknown
	_ = os.write_entire_file(fmt.tprintf("%s/missed_%s.txt", out_dir, compare_slug(site)), missed)
	return l, true
}

// The same load again with its frames kept, for as long as the measured one took to settle. Apart: a copy of each frame costs the window thread about a ms, which would
// show in its CPU and, on a page that draws all the time, keep it from ever looking idle.
@(private = "file")
replay_frames :: proc(l: ^Replay_Load, exe, out_dir, url, world: string, prefs: []string, lists: string) {
	profile := fmt.tprintf("%s/profile", out_dir)
	defer base.remove_tree(profile)
	w: bench.Wren
	if !replay_open(&w, exe, profile, world, prefs, lists) { return }
	defer bench.stop(&w)
	session := &w.session
	if api.timeline_start(session, REPLAY_FRAME_SCALE, REPLAY_FRAMES_MOST, page = true) != .None { return }
	started := time.tick_now()
	if api.navigate(session, url, .Load, REPLAY_LOAD_LIMIT) != .None { return }
	until := time.Duration(max(l.settled, l.load)) * time.Millisecond
	if left := until - time.tick_since(started); left > 0 { time.sleep(left) }
	file := fmt.tprintf("%s/frames.bin", out_dir)
	defer os.remove(file)
	if api.timeline_frames(session, file) != .None { return }
	list := read_frames(file)
	l.frames = len(list)
	l.ready, l.moving = measure.visual_ready(list, l.load)
}

// What control_timeline_frames wrote. (The timeline drops a frame of another size only by never making one: the page rectangle is fixed for a load.)
@(private = "file")
read_frames :: proc(file: string) -> []measure.Frame {
	data, err := os.read_entire_file(file, context.temp_allocator)
	if err != nil { return nil }
	out := make([dynamic]measure.Frame, context.temp_allocator)
	HEAD :: size_of(f64) + 2 * size_of(i32)
	for at := 0; at + HEAD <= len(data); {
		ms := (^f64)(&data[at])^
		size := (^[2]i32)(&data[at + size_of(f64)])^
		bytes := int(size.x) * int(size.y) * 4
		at += HEAD
		if at + bytes > len(data) { break }
		append(&out, measure.Frame{ms, data[at:at + bytes]})
		at += bytes
	}
	return out[:]
}

@(private = "file")
replay_summary :: proc(b: ^strings.Builder, site: string, arms: []Replay_Arm, results: [][dynamic]Replay_Load) {
	of :: proc(loads: []Replay_Load, m: Replay_Metric) -> measure.Spread {
		v := make([]f64, len(loads), context.temp_allocator)
		for l, i in loads { v[i] = m.of(l) }
		return measure.spread(v)
	}
	fmt.sbprintfln(b, "%s (median, range; floor: %% of the median, measure.noise_floor between the first two arms)", site)
	metrics := REPLAY_METRICS
	for m in metrics {
		fmt.sbprintf(b, "  %-15s", m.name)
		for arm, i in arms {
			s := of(results[i][:], m)
			fmt.sbprintf(b, "  %s %.0f (%.0f-%.0f)", arm.name, s.median, s.least, s.most)
		}
		if len(arms) >= 2 {
			a, c := of(results[0][:], m), of(results[1][:], m)
			fmt.sbprintf(b, "  medians %+.1f %%  floor %.1f %%", a.median > 0 ? 100 * (c.median - a.median) / a.median : 0, measure.noise_floor(a, c))
		}
		fmt.sbprintln(b)
	}
	if len(arms) >= 2 {
		a, c := results[0][:], results[1][:]
		v := measure.verdict(of(a, metrics[0]), of(c, metrics[0]), of(a, metrics[1]), of(c, metrics[1]), of(a, metrics[2]), of(c, metrics[2]))
		fmt.sbprintfln(b, "  %s against %s: %v", arms[1].name, arms[0].name, v)
	}
}


// The last load's counter, as a curve: `settled` is read from it.
@(private = "file")
samples_dump :: proc(s: ^Sampler, out_dir, site: string, rate: f64) {
	b := strings.builder_make(context.temp_allocator)
	sync.lock(&s.lock)
	for x in s.samples { fmt.sbprintfln(&b, "%.1f\t%.3f", x.ms, f64(x.cycles - s.samples[0].cycles) / rate) }
	sync.unlock(&s.lock)
	_ = os.write_entire_file(fmt.tprintf("%s/samples_%s.tsv", out_dir, compare_slug(site)), strings.to_string(b))
}

@(private = "file")
machine_share :: proc(busy0, total0, busy1, total1: i64) -> f64 { return f64(busy1 - busy0) / f64(max(total1 - total0, 1)) }

// Until the machine is quiet, or the limit: a measure goes on then, with its `others` column to say so.
@(private = "file")
replay_wait_quiet :: proc() {
	started := time.tick_now()
	for time.tick_since(started) < REPLAY_QUIET_LIMIT {
		busy0, total0 := bench.machine_times()
		time.sleep(REPLAY_QUIET_LOOK)
		busy1, total1 := bench.machine_times()
		if machine_share(busy0, total0, busy1, total1) <= REPLAY_QUIET_SHARE { return }
	}
	fmt.eprintln("the machine did not go quiet")
}

// The measured load, made again when others took the machine during it.
@(private = "file")
replay_watched :: proc(arm: Replay_Arm, out_dir, url, world: string, prefs: []string, rate: f64, site: string, loaded: bool) -> (l: Replay_Load, ok: bool) {
	for try in 0 ..= REPLAY_RETRIES {
		if !loaded { replay_wait_quiet() }
		busy0, total0 := bench.machine_times()
		l, ok = replay_load(arm.exe, out_dir, url, world, prefs, arm.lists, rate, site)
		busy1, total1 := bench.machine_times()
		// (a tick of the system is 100 ns: process_cpu is in ms)
		own := l.process_cpu * 10_000 / f64(max(total1 - total0, 1))
		l.others = max(machine_share(busy0, total0, busy1, total1) - own, 0)
		if !ok || loaded || l.others <= REPLAY_OTHERS_MOST { return }
		ok = false
		fmt.eprintfln("%s %s: others took %.0f %% of the machine, try %d", site, arm.name, 100 * l.others, try)
	}
	return
}
