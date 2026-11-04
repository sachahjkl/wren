// `wrentool sweep`: real pages visited as a person does, each in a Wren of its own with a throwaway profile (headless, nothing takes the focus): loaded, scrolled, the developer tools
// opened, a link followed, back, reload, opened again in a tab of its own and closed, loads cut short, then the browser closed. What it records is what a report needs: a crash and its report, a hang and
// its stacks, an unclean end, what the standard error said, the time of each step. One visit at a time per site: `-Shard i -Shards n` splits the list between runs.
package capture

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:remote/api"
import "wb:tools/tooling"
import "wb:tools/wrentool/bench"

SWEEP_FLAGS :: "-Urls= -List= -OutDir= -Exe= -Shard= -Shards= -Pref= -CloseMs= -PingMs= -Keep -OneProcess"
SWEEP_OUT :: "build/sweep"
SWEEP_SIZE :: [2]int{1280, 800}
// A page may take this long to load; past it the visit goes on with what is there (slow is not a failure).
SWEEP_LOAD_LIMIT :: 30 * time.Second
// How long a loaded page may take to calm down, a link to take us somewhere, a step's frames to be drawn.
SWEEP_SETTLE_LIMIT :: 4 * time.Second
SWEEP_LINK_LIMIT :: 6 * time.Second
// What a scrolled page gets to fetch what it shows late.
SWEEP_DWELL_LIMIT :: 2 * time.Second
SWEEP_FRAMES_LIMIT :: 10 * time.Second
// The interface must answer within this, twice: else the process is hung.
SWEEP_PING_MS :: 15_000
// A load interrupted this long after it began: a tab closed, another navigation, reload and back on top of it.
SWEEP_RACE_WAIT :: 300 * time.Millisecond
SWEEP_SCROLLS :: 6
SWEEP_NOTCHES :: 4.0
SWEEP_FRAMES :: 3
// What the standard error says when something went wrong.
SWEEP_ALARMS :: []string{"panic", "assertion", "Assertion", "bounds", "leak", "bad free", "double free", "use-after", "AddressSanitizer", "ERROR: ", "fatal"}
SWEEP_ALARM_LINES :: 6
SWEEP_DEVTOOLS_PANELS :: []string{"console", "elements", "network"}
SWEEP_LINE_MAX :: 200

// A link a person may follow: on this site, on screen, that signs no one in and starts no download. `x y address`, or "".
SWEEP_PICK_LINK :: `(()=>{const skip=/log.?(in|out)|sign.?(in|up|out)|regist|cart|checkout|subscri|download|account|\.(zip|exe|pdf|dmg|msi)/i;
for(const a of document.querySelectorAll('a[href]')){if(a.host!==location.host||!a.protocol.startsWith('http')||a.href.split('#')[0]===location.href.split('#')[0]||skip.test(a.href+' '+a.textContent))continue;
const r=a.getBoundingClientRect();if(r.width<4||r.height<4||r.top<0||r.top>innerHeight-4||r.left<0||r.left>innerWidth-4)continue;
return Math.round(r.left+r.width/2)+' '+Math.round(r.top+r.height/2)+' '+a.href}return ''})()`

Sweep_Step :: enum u8 { Start, Load, Scroll, Devtools, Link, Back, Reload, Tab, Race, Close }
Sweep_Verdict :: enum u8 { Passed, Crash, Hang, Unclean, No_Start }

SWEEP_STEP_NAMES := [Sweep_Step]string{.Start = "start", .Load = "load", .Scroll = "scroll", .Devtools = "devtools", .Link = "link", .Back = "back", .Reload = "reload", .Tab = "tab", .Race = "race", .Close = "close"}
SWEEP_VERDICT_NAMES := [Sweep_Verdict]string{.Passed = "passed", .Crash = "CRASH", .Hang = "HANG", .Unclean = "UNCLEAN", .No_Start = "NO-START"}

// One page's visit: the step it is at, what each took, how it ended.
Sweep_Visit :: struct {
	url, slug:  string,
	step:       Sweep_Step,
	verdict:    Sweep_Verdict,
	ms:         [Sweep_Step]int,
	slow:       bit_set[Sweep_Step],   // ran out of its limit
	link:       string,                // where the link went
	note:       string,                // the first thing worth a look
	js_errors:  int,
	nodes:      int,
	memory_mb:  int,
	exit_code:  int,
}

// A run: what stays from page to page.
Sweep_Run :: struct {
	exe, out:  string,
	prefs:     []string,
	keep:      bool,   // the profile stays when a page passed too
	one:       bool,   // one Wren for every page, until it dies: what a long session does
	close_ms:  int,    // how long a close may take (0: what api.finish gives; a sanitizer build needs more)
	ping_ms:   int,    // how long the interface may take to answer, twice
	wren:      bench.Wren,
	running:   bool,
	profile, stderr: string,
}

run_sweep :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, SWEEP_FLAGS)
	if !ok { return EXIT_USAGE }
	urls := make([dynamic]string)
	for u in tooling.flag_list(f, "-Urls") { if u != "" { append(&urls, strings.clone(u)) } }
	for list in tooling.flag_list(f, "-List") {
		data, err := os.read_entire_file(list, context.allocator)
		if err != nil { fmt.eprintfln("cannot read %s", list); return EXIT_USAGE }
		for raw in strings.split_lines(string(data)) {
			line := strings.trim_space(raw)
			if line != "" && !strings.has_prefix(line, "#") { append(&urls, line) }
		}
	}
	if len(urls) == 0 { fmt.eprintln("wrentool sweep -Urls a,b | -List file[,file] [-OutDir dir] [-Exe path] [-Shard i -Shards n] [-Pref a=b] [-Keep] [-OneProcess]"); return EXIT_USAGE }
	r := Sweep_Run{exe = strings.clone(tooling.flag(f, "-Exe", bench.WREN_EXE)), keep = tooling.flag_has(f, "-Keep"), one = tooling.flag_has(f, "-OneProcess"), close_ms = tooling.flag_int(f, "-CloseMs", 0), ping_ms = tooling.flag_int(f, "-PingMs", SWEEP_PING_MS)}
	if !os.exists(r.exe) { fmt.eprintfln("%s is missing (build.bat)", r.exe); return 1 }
	out := tooling.flag(f, "-OutDir", SWEEP_OUT)
	_ = os.make_directory_all(out)   // (before abs: on Linux it asks the system, for what exists)
	r.out, _ = filepath.abs(out, context.allocator)
	prefs := make([dynamic]string)
	append(&prefs, "blocker.update.enabled=false", "blocker.welcome_toast=false")
	for p in tooling.flag_list(f, "-Pref") { if p != "" { append(&prefs, strings.clone(p)) } }
	r.prefs = prefs[:]
	shard, shards := tooling.flag_int(f, "-Shard", 0), max(tooling.flag_int(f, "-Shards", 1), 1)

	summary, err := os.open(fmt.tprintf("%s/summary_%d.tsv", r.out, shard), {.Write, .Create, .Trunc})
	if err != nil { fmt.eprintfln("cannot write in %s", r.out); return 1 }
	defer os.close(summary)
	fmt.fprint(summary, "verdict\turl\tstep")
	for name in SWEEP_STEP_NAMES { fmt.fprintf(summary, "\t%s_ms", name) }
	fmt.fprintln(summary, "\tslow\tjs_errors\tnodes\tmemory_mb\texit\tnote")

	failed, pages := 0, 0
	for url, i in urls {
		if i % shards != shard { continue }
		v := Sweep_Visit{url = url, slug = compare_slug(url)}
		sweep_visit(&r, &v)
		pages += 1
		if v.verdict != .Passed { failed += 1 }
		sweep_write(summary, &v)
		fmt.printfln("%-9s %-60s %-8s load %6d ms  %s", SWEEP_VERDICT_NAMES[v.verdict], url, SWEEP_STEP_NAMES[v.step], v.ms[.Load], v.note)
		free_all(context.temp_allocator)
	}
	if r.running {
		v := Sweep_Visit{url = "(the end of the session)", slug = "session_end"}
		sweep_close(&r, &v)
		sweep_write(summary, &v)
		if v.verdict != .Passed { failed += 1 }
	}
	fmt.printfln("%d pages, %d with a failure: %s/summary_%d.tsv", pages, failed, r.out, shard)
	return failed > 0 ? 1 : 0
}

@(private = "file")
sweep_write :: proc(out: ^os.File, v: ^Sweep_Visit) {
	fmt.fprintf(out, "%s\t%s\t%s", SWEEP_VERDICT_NAMES[v.verdict], v.url, SWEEP_STEP_NAMES[v.step])
	for ms in v.ms { fmt.fprintf(out, "\t%d", ms) }
	fmt.fprint(out, "\t")
	for s in Sweep_Step { if s in v.slow { fmt.fprintf(out, "%s ", SWEEP_STEP_NAMES[s]) } }
	fmt.fprintfln(out, "\t%d\t%d\t%d\t%d\t%s", v.js_errors, v.nodes, v.memory_mb, v.exit_code, v.note)
}

// Every step of a page, one after the other, as long as the browser lives and answers.
@(private = "file")
sweep_visit :: proc(r: ^Sweep_Run, v: ^Sweep_Visit) {
	if !sweep_start(r, v) { return }
	for step in Sweep_Step.Load ..= Sweep_Step.Race {
		v.step = step
		at := time.tick_now()
		sweep_do(r, v, step)
		v.ms[step] = int(time.duration_milliseconds(time.tick_since(at)))
		if !sweep_alive(r, v) { return }
	}
	sweep_measure(r, v)
	if !r.one { sweep_close(r, v) }
}

@(private = "file")
sweep_start :: proc(r: ^Sweep_Run, v: ^Sweep_Visit) -> bool {
	if r.running { return true }
	v.step = .Start
	at := time.tick_now()
	r.profile = strings.clone(fmt.tprintf("%s/profile_%s", r.out, v.slug))
	r.stderr = strings.clone(fmt.tprintf("%s/%s.stderr.txt", r.out, v.slug))
	base.remove_tree(r.profile)
	r.wren = {}
	if !bench.start(&r.wren, {exe = r.exe, profile = r.profile, window = .Headless, size = SWEEP_SIZE, prefs = r.prefs, stderr = r.stderr, no_url = false}) {
		v.verdict, v.note = .No_Start, "it did not start"
		return false
	}
	r.running = true
	v.ms[.Start] = int(time.duration_milliseconds(time.tick_since(at)))
	return true
}

@(private = "file")
sweep_do :: proc(r: ^Sweep_Run, v: ^Sweep_Visit, step: Sweep_Step) {
	s := &r.wren.session
	#partial switch step {
	case .Load:
		sweep_limit(v, step, api.navigate(s, v.url, .Load, SWEEP_LOAD_LIMIT))
		_ = api.wait_quiet(s, deadline = SWEEP_SETTLE_LIMIT)
	case .Scroll:
		for _ in 0 ..< SWEEP_SCROLLS {
			if api.scroll(s, SWEEP_NOTCHES) != .None { break }
			_ = api.wait_frames(s, SWEEP_FRAMES, SWEEP_FRAMES_LIMIT)
		}
		_ = api.wait_quiet(s, deadline = SWEEP_DWELL_LIMIT)
		_ = api.key(s, "End")
		_ = api.wait_frames(s, SWEEP_FRAMES, SWEEP_FRAMES_LIMIT)
		_ = api.key(s, "Home")
		_ = api.wait_frames(s, SWEEP_FRAMES, SWEEP_FRAMES_LIMIT)
	case .Devtools:
		for panel in SWEEP_DEVTOOLS_PANELS {
			_ = api.open_devtools(s, panel)
			_ = api.wait_frames(s, SWEEP_FRAMES, SWEEP_FRAMES_LIMIT)
		}
		_ = api.run_command(s, "view.devtools")
		_ = api.wait_frames(s, SWEEP_FRAMES, SWEEP_FRAMES_LIMIT)
	case .Link:   sweep_follow_link(r, v)
	case .Back:   sweep_limit(v, step, api.go_back(s, .Load, SWEEP_LOAD_LIMIT))
	case .Reload: sweep_limit(v, step, api.reload(s, .Load, deadline = SWEEP_LOAD_LIMIT))
	case .Tab:
		id, e := api.new_tab(s, v.url, .Load, deadline = SWEEP_LOAD_LIMIT)
		sweep_limit(v, step, e)
		if id != 0 {
			_ = api.scroll(s, SWEEP_NOTCHES)
			_ = api.close_tab(s, id)
		}
	case .Race:
		if id, e := api.new_tab(s, v.url, .None); e == .None {
			time.sleep(SWEEP_RACE_WAIT)
			_ = api.close_tab(s, id)
		}
		if id, e := api.new_tab(s, v.url, .None); e == .None {
			time.sleep(SWEEP_RACE_WAIT)
			_ = api.navigate(s, "about:blank", .None)
			_ = api.go_back(s, .None)
			time.sleep(SWEEP_RACE_WAIT)
			_ = api.reload(s, .None)
			time.sleep(SWEEP_RACE_WAIT)
			_ = api.close_tab(s, id)
		}
	}
}

@(private = "file")
sweep_limit :: proc(v: ^Sweep_Visit, step: Sweep_Step, e: api.Error) {
	if e == .Timeout { v.slow += {step} }
}

// A click on a link of the page; when that goes nowhere (something covers it, a script takes it), the address.
@(private = "file")
sweep_follow_link :: proc(r: ^Sweep_Run, v: ^Sweep_Visit) {
	s := &r.wren.session
	before, e := api.location(s)
	if e != .None { return }
	picked, pe := api.eval(s, SWEEP_PICK_LINK, deadline = SWEEP_SETTLE_LIMIT)
	if pe != .None || picked == "" { return }
	parts := strings.split_n(picked, " ", 3, context.temp_allocator)
	if len(parts) != 3 { return }
	v.link = strings.clone(parts[2])
	x, _ := strconv.parse_f64(parts[0])
	y, _ := strconv.parse_f64(parts[1])
	_ = api.click_at(s, {x, y})
	moved := api.wait_js(s, fmt.tprintf("location.href !== %q", before), SWEEP_LINK_LIMIT)
	if moved != .None { sweep_limit(v, .Link, api.navigate(s, parts[2], .Load, SWEEP_LOAD_LIMIT)); return }
	sweep_limit(v, .Link, api.wait_load(s, SWEEP_LOAD_LIMIT))
	_ = api.wait_quiet(s, deadline = SWEEP_DWELL_LIMIT)
}

// Whether the process goes on and its interface answers. When not, the visit says why and what it left.
@(private = "file")
sweep_alive :: proc(r: ^Sweep_Run, v: ^Sweep_Visit) -> bool {
	s := &r.wren.session
	l := &r.wren.launched
	if !api.process_alive(&l.process) {
		sweep_died(r, v)
		return false
	}
	limit := s.timeout_ms
	defer s.timeout_ms = limit
	s.timeout_ms = r.ping_ms
	_, e := api.ping(s)
	if e == .Timeout { _, e = api.ping(s) }
	if e == .None { return true }
	// (a channel that closes is a process that ends: its crash report is being written)
	if e == .Closed { api.process_wait(&l.process, r.ping_ms) }
	if !api.process_alive(&l.process) {
		sweep_died(r, v)
		return false
	}
	v.verdict, v.note = .Hang, strings.clone(fmt.tprintf("no answer after %s (%v)", SWEEP_STEP_NAMES[v.step], e))
	if text, ok := api.process_stacks(l.pid); ok { _ = os.write_entire_file(fmt.tprintf("%s/%s.stacks.txt", r.out, v.slug), transmute([]byte)text) }
	v.exit_code, _ = api.finish(s, l, false)
	r.running = false
	sweep_leftovers(r, v)
	return false
}

@(private = "file")
sweep_died :: proc(r: ^Sweep_Run, v: ^Sweep_Visit) {
	v.verdict = .Crash
	v.exit_code, _ = api.finish(&r.wren.session, &r.wren.launched, false)
	r.running = false
	v.note = strings.clone(fmt.tprintf("it ended during %s (exit %d)", SWEEP_STEP_NAMES[v.step], v.exit_code))
	sweep_leftovers(r, v)
}

// What the last moments of a page say about it: read before the browser goes.
@(private = "file")
sweep_measure :: proc(r: ^Sweep_Run, v: ^Sweep_Visit) {
	s := &r.wren.session
	if lines, e := api.console(s); e == .None { for l in lines { if l.level == "error" { v.js_errors += 1 } } }
	if st, e := api.stats(s); e == .None { v.nodes, v.memory_mb = st.nodes, st.private_bytes >> 20 }
}

@(private = "file")
sweep_close :: proc(r: ^Sweep_Run, v: ^Sweep_Visit) {
	v.step = .Close
	at := time.tick_now()
	forced: bool
	if r.close_ms > 0 && api.browser_close(&r.wren.session) == .None { api.process_wait(&r.wren.launched.process, r.close_ms) }
	v.exit_code, forced = api.finish(&r.wren.session, &r.wren.launched, true)
	v.ms[.Close] = int(time.duration_milliseconds(time.tick_since(at)))
	r.running = false
	session_left := os.exists(fmt.tprintf("%s/crashes/session.txt", r.profile))
	switch {
	case forced:           v.verdict, v.note = .Hang, "it had to be killed at the close"
	case v.exit_code != 0: v.verdict, v.note = .Crash, strings.clone(fmt.tprintf("exit %d at the close", v.exit_code))
	case session_left:     v.verdict, v.note = .Unclean, "a session left behind (a watchdog's exit)"
	}
	sweep_leftovers(r, v)
}

// The crash report, the shutdown log and the alarming lines of the standard error are kept beside the summary; a profile with nothing to say goes.
@(private = "file")
sweep_leftovers :: proc(r: ^Sweep_Run, v: ^Sweep_Visit) {
	if infos, err := os.read_all_directory_by_path(fmt.tprintf("%s/crashes", r.profile), context.temp_allocator); err == nil {
		for fi in infos {
			if !strings.has_suffix(fi.name, ".txt") || fi.name == "session.txt" { continue }
			if v.verdict == .Passed { v.verdict = .Crash }
			if data, re := os.read_entire_file(fi.fullpath, context.temp_allocator); re == nil { _ = os.write_entire_file(fmt.tprintf("%s/%s.%s", r.out, v.slug, fi.name), data) }
		}
	}
	if data, re := os.read_entire_file(fmt.tprintf("%s/shutdown.log", r.profile), context.temp_allocator); re == nil {
		_ = os.write_entire_file(fmt.tprintf("%s/%s.shutdown.log", r.out, v.slug), data)
		if v.note == "" { v.note = "slow close: see its shutdown.log" }
	}
	alarms := sweep_alarms(r.stderr)
	if alarms != "" {
		if v.note == "" { v.note = strings.clone(alarms) }
		if v.verdict == .Passed { v.verdict = .Unclean }
	}
	if v.verdict == .Passed && !r.keep { _ = os.remove(r.stderr) }
	if !r.keep { base.remove_tree(r.profile) }
}

// The first lines of a standard error that sound the alarm, on one line.
@(private = "file")
sweep_alarms :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return "" }
	b := strings.builder_make(context.temp_allocator)
	count := 0
	for line in strings.split_lines(string(data), context.temp_allocator) {
		for word in SWEEP_ALARMS {
			if !strings.contains(line, word) { continue }
			strings.write_string(&b, line[:min(len(line), SWEEP_LINE_MAX)])
			strings.write_string(&b, " | ")
			count += 1
			break
		}
		if count == SWEEP_ALARM_LINES { break }
	}
	return strings.to_string(b)
}
