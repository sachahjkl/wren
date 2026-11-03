package bench

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:remote/api"
import "wb:tools/tooling"

BYTES_PER_MB :: 1024 * 1024

////////////////////////////////
// idle

IDLE_SECONDS :: 10
IDLE_PAGES := [][2]string{
	{"static", `<!doctype html><meta charset="utf-8"><title>static</title><h1>A page that changes nothing</h1><p>Some text.</p>`},
	{"field", `<!doctype html><meta charset="utf-8"><title>field</title><p>A focused field:</p><input id="f" autofocus value="text"><script>document.getElementById("f").focus()</script>`},
	{"anim", `<!doctype html><meta charset="utf-8"><title>anim</title><style>@keyframes m{from{transform:translateX(0)}to{transform:translateX(300px)}}#b{width:80px;height:80px;background:#06c;animation:m 2s linear infinite alternate}</style><div id="b"></div>`},
}
IDLE_VIDEO :: "examples/site/media/video/clip.mp4"

// What a Wren at rest costs: CPU time, wakes of its threads (the system's own count of context switches), frames, turns of its loop, over a period, for each way of having a window and each page.
bench_idle :: proc(o: ^Options) -> int {
	modes := tooling.flag_list(o.flags, "-Modes", {"headless"})
	shown_or_hidden := false
	for m in modes { if m != "headless" { shown_or_hidden = true } }
	code: int
	if on_desktop(shown_or_hidden, &code) { return code }
	exe, has := program(o, WREN_EXE)
	if !has { return 1 }
	pages := tooling.flag_list(o.flags, "-Pages", {"blank", "static", "field", "anim", "video"})
	period := time.Duration(tooling.flag_int(o.flags, "-Seconds", IDLE_SECONDS)) * time.Second
	dir := scratch("idle")
	defer base.remove_tree(dir)
	r := report_begin("idle", "window", "page", "cpu_ms_s", "wakes_s", "main_s", "frames", "fps", "turns", "turns_s", "barren")
	for mode in modes {
		window: api.Window_Mode
		switch mode {
		case "headless": window = .Headless
		case "hidden": window = .Hidden
		case "shown": window = .Visible
		case: fmt.eprintfln("no window mode %s", mode); return EXIT_USAGE
		}
		for page in pages {
			url := idle_page(dir, page)
			if url == "" { fmt.printfln("%s %s: no such page here", mode, page); continue }
			w: Wren
			if !start(&w, {exe = exe, window = window, prefs = o.prefs, url = url}) { return 1 }
			defer stop(&w)
			settle(&w)
			s0, e0 := api.stats(&w.session)
			if e0 != .None { fmt.eprintln(api.last_failure().message); return 1 }
			t0 := read_threads(s0.pid)
			began := time.tick_now()
			hold(&w, period)
			t1 := read_threads(s0.pid)
			took := time.duration_seconds(time.tick_since(began))
			s1, _ := api.stats(&w.session)
			cpu, wakes, main_wakes := thread_deltas(t0, t1, o, took)
			frames := s1.frames_drawn - s0.frames_drawn
			turns := s1.loop.turns - s0.loop.turns
			report_row(&r, mode, page, cpu / took, f64(wakes) / took, f64(main_wakes) / took, frames, f64(frames) / took, turns, f64(turns) / took, s1.loop.barren - s0.loop.barren)
			for reason in s1.loop.reasons { fmt.printfln("    %s by %s", reason.causes, reason.by) }
		}
	}
	report_end(&r, o)
	return 0
}

@(private)
idle_page :: proc(dir, page: string) -> string {
	if page == "blank" { return "about:blank" }
	html := ""
	for p in IDLE_PAGES { if p[0] == page { html = p[1] } }
	if page == "video" && os.exists(IDLE_VIDEO) {
		html = fmt.tprintf(`<!doctype html><meta charset="utf-8"><title>video</title><video src="%s" autoplay muted loop width="480"></video>`, file_url(IDLE_VIDEO))
	}
	if html == "" { return "" }
	path := fmt.tprintf("%s/%s.html", dir, page)
	_ = os.write_entire_file(path, html)
	return file_url(path)
}

Thread_Count :: struct { id: u64, switches, cpu_100ns: i64 }

@(private)
thread_deltas :: proc(t0, t1: []Thread_Count, o: ^Options, took: f64) -> (cpu_ms: f64, wakes, main_wakes: i64) {
	found_main := false
	for x in t1 {
		before: Thread_Count
		for b in t0 { if b.id == x.id { before = b; break } }
		d_w := x.switches - before.switches
		d_c := f64(x.cpu_100ns - before.cpu_100ns) / 10_000
		cpu_ms += d_c
		wakes += d_w
		if !found_main && before.id != 0 { main_wakes = d_w; found_main = true }
		if tooling.flag_has(o.flags, "-Threads") && (d_w > 0 || d_c > 0) { fmt.printfln("    %-28s %8.1f wakes/s %8.1f ms", thread_name(x.id), f64(d_w) / took, d_c) }
	}
	return
}

////////////////////////////////
// webgl

WEBGL_FPS_MS :: 4000
WEBGL_SIZE :: [2]int{1300, 900}
WEBGL_SETTLE_FRAMES :: 30
WEBGL_RUNS :: 3
WEBGL_SECONDS :: 120 * time.Second
WEBGL_MEASURES := []string{"fps", "scriptMsPerFrame", "firstContextMs", "getErrorUs", "readPixelMs", "readCanvasMs", "uploadMs", "bufferMs", "linkMs"}

bench_webgl :: proc(o: ^Options) -> int {
	code: int
	if on_desktop(o.window != .Headless, &code) { return code }
	exe, has := program(o, WREN_EXE)
	if !has { return 1 }
	prefs := make([dynamic]string, context.temp_allocator)
	append(&prefs, ..o.prefs)
	if tooling.flag_has(o.flags, "-Software") { append(&prefs, "webgl.force_software=true") }
	r := report_begin("webgl", "run", "cold_context_ms", "demo_fps", "fps", "script_ms_frame", "first_context_ms", "get_error_us", "read_pixel_ms", "read_canvas_ms", "upload_ms", "buffer_ms", "link_ms", "browser_mb", "gpu_mb")
	runs := o.runs > 0 ? o.runs : WEBGL_RUNS
	for run_index in 0 ..< runs {
		w: Wren
		if !start(&w, {exe = exe, window = o.window, size = WEBGL_SIZE, prefs = prefs[:], url = file_url("examples/site/about.html")}) { return 1 }
		defer stop(&w)
		ses := &w.session
		_ = api.wait_load(ses)
		number :: proc(ses: ^api.Session, script: string, await := false) -> f64 {
			text, e := api.eval(ses, script, await, WEBGL_SECONDS)
			if e != .None { fmt.eprintln(api.last_failure().message); return 0 }
			v, _ := strconv.parse_f64(text)
			return v
		}
		cold := number(ses, "(function () { const t = performance.now(); document.createElement('canvas').getContext('webgl'); return performance.now() - t; })()")
		_ = api.navigate(ses, file_url("examples/site/webgl.html"))
		_ = api.wait_frames(ses, WEBGL_SETTLE_FRAMES)
		demo := number(ses, fmt.tprintf("new Promise(ok => {{ let n = 0; const s = performance.now(); const f = () => {{ n++; const e = performance.now() - s; if (e >= %d) ok(n / e * 1000); else requestAnimationFrame(f); }}; requestAnimationFrame(f); }})", WEBGL_FPS_MS), true)
		_ = api.navigate(ses, file_url("examples/site/webgl-stress.html"))
		_ = api.wait_frames(ses, WEBGL_SETTLE_FRAMES)
		values := make([]f64, len(WEBGL_MEASURES), context.temp_allocator)
		said, said_e := api.eval(ses, "measure()", true, WEBGL_SECONDS)   // (it answers JSON)
		if said_e != .None { fmt.eprintln(api.last_failure().message); return 1 }
		for name, i in WEBGL_MEASURES { values[i] = json_number(said, name) }
		st, _ := api.stats(ses)
		report_row(&r, run_index, cold, demo, values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7], values[8], st.working_set_bytes / BYTES_PER_MB, process_working_set(st.gpu_process_id) / BYTES_PER_MB)
	}
	report_end(&r, o)
	return 0
}

////////////////////////////////
// blocker

BLOCKER_REPORT :: "build/bench/blocker_load.tsv"
BLOCKER_SETTLE_MS :: 12_000
BLOCKER_LIMIT_MS :: 180_000
BLOCKER_LOOK_MS :: 200
BLOCKER_RUNS :: 2

// Each site with and without the content blocker: the browser appends its load report (src/browser/blocker_measure.odin) to WREN_LOAD_REPORT `settle` after the load. -Profile: a folder with the
// blocker's lists and cache, copied fresh for each run. The table is the report's file.
bench_blocker :: proc(o: ^Options) -> int {
	exe, has := program(o, WREN_EXE)
	if !has { return 1 }
	from := tooling.flag(o.flags, "-Profile")
	urls := tooling.flag_list(o.flags, "-Urls")
	for u in urls { if !strings.has_prefix(u, "http") { fmt.eprintfln("%s: the load report is of pages over http", u); return EXIT_USAGE } }
	if from == "" || len(urls) == 0 { fmt.eprintln("wrentool bench blocker -Profile <folder with blocker lists> -Urls a,b [-Runs n]"); return EXIT_USAGE }
	report := tooling_abs(BLOCKER_REPORT)
	_ = os.remove(report)
	work := "build/bench/blocker_profile"
	runs := o.runs > 0 ? o.runs : BLOCKER_RUNS
	for url in urls {
		for run_index in 0 ..< runs {
			// (the two ways interleaved: the first of a pair is not always the same)
			for way in 0 ..< 2 {
				on := (way + run_index) % 2 == 1
				base.remove_tree(work)
				if os.copy_directory_all(work, from) != nil { fmt.eprintfln("%s cannot be copied", from); return 1 }
				before := tooling.file_size(report)
				w: Wren
				env := []string{fmt.tprintf("WREN_LOAD_REPORT=%s", report), fmt.tprintf("WREN_LOAD_REPORT_MS=%d", BLOCKER_SETTLE_MS)}
				if !start(&w, {exe = exe, profile = work, env = env, url = url, prefs = {"blocker.update.enabled=false", fmt.tprintf("blocker.enabled=%v", on)}}) { return 1 }
				end := time.tick_add(time.tick_now(), BLOCKER_LIMIT_MS * time.Millisecond)
				for tooling.file_size(report) == before && time.tick_diff(time.tick_now(), end) > 0 {
					if api.process_wait(&w.launched.process, BLOCKER_LOOK_MS) { break }
				}
				stop(&w)
				fmt.printfln("%s blocker %v", url, on)
			}
		}
	}
	base.remove_tree(work)
	fmt.printfln("\n%s", report)
	return 0
}

////////////////////////////////
// sidebar

SIDEBAR_TABS :: 1000
SIDEBAR_FEW :: 10
SIDEBAR_FRAMES :: 240
SIDEBAR_WARM_FRAMES :: 30
SIDEBAR_BUDGET_MS :: 5.5
SIDEBAR_GROUP_EVERY :: 20
SIDEBAR_GROUPED_RUN :: 10

// A session of N tabs (restored, not loaded: as after a restart), in groups of ten every other ten: frames are made (the toolkit rebuilds the tab bar each one) and the CPU of a frame read.
bench_sidebar :: proc(o: ^Options) -> int {
	exe, has := program(o, WREN_EXE)
	if !has { return 1 }
	tabs := tooling.flag_int(o.flags, "-Tabs", SIDEBAR_TABS)
	frames := tooling.flag_int(o.flags, "-Frames", SIDEBAR_FRAMES)
	strict := tooling.flag_has(o.flags, "-Perf") && !env_is_set("CI")
	r := report_begin("sidebar", "tabs", "position", "cpu_ms", "cpu_p95_ms", "cpu_max_ms", "frames")
	failed := 0
	for position in ([]string{"top", "left"}) {
		for n in ([]int{SIDEBAR_FEW, tabs}) {
			dir := scratch("sidebar")
			defer base.remove_tree(dir)
			page := file_url(fmt.tprintf("%s/p.html", dir))
			_ = os.write_entire_file(fmt.tprintf("%s/p.html", dir), "<!doctype html><title>p</title>p")
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "wren-session 2\ncurrent 0\n")
			for g in 1 ..= (n + SIDEBAR_GROUP_EVERY - 1) / SIDEBAR_GROUP_EVERY { fmt.sbprintf(&b, "tgroup\t%d\tblue\t0\tGroup %d\n", g, g) }
			for i in 0 ..< n {
				fmt.sbprintf(&b, "tab %s?n=%d\n", page, i)
				if (i / SIDEBAR_GROUPED_RUN) % 2 == 0 { fmt.sbprintf(&b, "group %d\n", i / SIDEBAR_GROUP_EVERY + 1) }
			}
			_ = os.write_entire_file(fmt.tprintf("%s/session.txt", dir), strings.to_string(b))
			w: Wren
			prefs := []string{fmt.tprintf("browser.tabs.position=%s", position), "browser.session.restore=true", fmt.tprintf("browser.session.max_tabs=%d", max(n, 100))}
			if !start(&w, {exe = exe, profile = dir, prefs = prefs, no_url = true}) { return 1 }
			_ = api.wait_frames(&w.session, SIDEBAR_WARM_FRAMES)
			list, _ := api.targets(&w.session)
			_, _ = api.stats(&w.session, reset_frames = true)
			_ = api.wait_frames(&w.session, frames)
			st, _ := api.stats(&w.session)
			cpu := result_number(&w.session, "cpuMs")
			report_row(&r, len(list.tabs), position, cpu, result_number(&w.session, "cpuP95Ms"), result_number(&w.session, "cpuMaxMs"), st.frames_drawn)
			stop(&w)
			if strict && cpu > SIDEBAR_BUDGET_MS { fmt.printfln("FAIL  %d tabs, %s: %.1f ms of CPU a frame (the 180 Hz budget is %.1f)", n, position, cpu, SIDEBAR_BUDGET_MS); failed += 1 }
		}
	}
	report_end(&r, o)
	return failed > 0 ? 1 : 0
}

@(private)
env_is_set :: proc(name: string) -> bool {
	v, _ := os.lookup_env(name, context.temp_allocator)
	return v != ""
}

////////////////////////////////
// startup

STARTUP_RUNS :: 9
STARTUP_SECOND_STARTS :: 5
STARTUP_LOOK_MS :: 20
STARTUP_LIMIT :: 30 * time.Second
STARTUP_MARK :: "first present "

// From the process start to the first present (TOOLKIT_RENDER_TRACE) with the single instance on and off, interleaved, and the time a second start takes to hand its address over and end. A present needs a window.
bench_startup :: proc(o: ^Options) -> int {
	code: int
	if on_desktop(true, &code) { return code }
	exe, has := program(o, WREN_PROF_EXE)
	if !has { return 1 }
	runs := o.runs > 0 ? o.runs : STARTUP_RUNS
	dir := scratch("startup")
	defer base.remove_tree(dir)
	times: [2][dynamic]f64
	second := make([dynamic]f64, context.temp_allocator)
	for i in 0 ..< runs {
		for on, mode in ([]bool{false, true}) {
			err_file := fmt.tprintf("%s/err_%d_%d.txt", dir, mode, i)
			profile := fmt.tprintf("%s/p_%d_%d", dir, mode, i)
			env := []string{"TOOLKIT_RENDER_TRACE=1", fmt.tprintf("WREN_SINGLE_INSTANCE=%s", on ? "on" : "off")}
			_ = os.make_directory_all(profile)
			p, _, why := api.process_start({exe, "--hidden", "--profile", profile, "about:home"}, {env = env, stderr = {file = err_file}})
			if why != "" { fmt.eprintln(why); return 1 }
			ms, found := wait_first_present(&p, err_file)
			if found { append(&times[mode], ms) }
			if on && i < STARTUP_SECOND_STARTS {
				begun := time.tick_now()
				q, _, why2 := api.process_start({exe, "--hidden", "--profile", profile, "about:wren"}, {env = env})
				if why2 == "" {
					_ = api.process_wait(&q, int(time.duration_milliseconds(STARTUP_LIMIT)))
					append(&second, time.duration_milliseconds(time.tick_since(begun)))
					api.process_release(&q)
				}
			}
			api.process_kill(&p)
			_ = api.process_wait(&p, api.KILL_WAIT_MS)
			api.process_release(&p)
		}
	}
	r := report_begin("startup", "what", "median_ms", "runs")
	report_row(&r, "first present, single instance off", median(times[0][:]), len(times[0]))
	report_row(&r, "first present, single instance on", median(times[1][:]), len(times[1]))
	report_row(&r, "a second start (hand over and end)", median(second[:]), len(second))
	report_end(&r, o)
	return 0
}

@(private)
wait_first_present :: proc(p: ^api.Process, err_file: string) -> (ms: f64, found: bool) {
	end := time.tick_add(time.tick_now(), STARTUP_LIMIT)
	for time.tick_diff(time.tick_now(), end) > 0 {
		data, err := os.read_entire_file(err_file, context.temp_allocator)
		if err == nil {
			if i := strings.index(string(data), STARTUP_MARK); i >= 0 {
				rest := string(data)[i + len(STARTUP_MARK):]
				if sp := strings.index_byte(rest, ' '); sp > 0 { return strconv.parse_f64(rest[:sp]) }
			}
		}
		if api.process_wait(p, STARTUP_LOOK_MS) { return 0, false }
	}
	return 0, false
}

////////////////////////////////
// cadence

CADENCE_DPI :: 144.0
CADENCE_SIZE :: [2]int{1400, 900}
CADENCE_DRAG_STEPS :: 90
CADENCE_WARM_FRAMES :: 6
CADENCE_AMPLITUDE :: 120.0
CADENCE_DOCK_MARGIN :: 2.5
CADENCE_SIDEBAR_WIDTH :: 240.0
CADENCE_BAR_ABOVE :: 300.0
CADENCE_HEIGHT_PART :: 0.6
CADENCE_DRAG_SHARE :: 0.5
CADENCE_AT_ONCE_SHARE :: 0.8
CADENCE_PAGE :: `<!doctype html><meta charset=utf-8><title>p</title><style>html,body{margin:0;background:#fff}p{font:16px sans-serif;margin:8px}</style><body><p>Text that wraps at every width, as a page's does.</p>`

Cadence_Scenario :: struct {
	name:    string,
	prefs:   []string,
	along_x: bool,
}

CADENCE_SCENARIOS := []Cadence_Scenario{
	{"devtools_right", {"browser.devtools.visible=true", "browser.devtools.dock=right", "browser.devtools.size=300", "browser.devtools.tab=console"}, true},
	{"devtools_bottom", {"browser.devtools.visible=true", "browser.devtools.dock=bottom", "browser.devtools.size=300", "browser.devtools.tab=console"}, false},
	{"sidebar", {"browser.tabs.position=left"}, true},
}

// The cadence of the frames while a splitter is dragged, with the screen said to have a variable refresh rate. The rates are printed, never checked (nothing here is timed): the checks are that the frames of the
// drag are in the Drag state of the cadence model (platform/pacing.odin) and presented at once on such a screen, as a resize's are. A hidden window, on its own desktop.
bench_cadence :: proc(o: ^Options) -> int {
	code: int
	if on_desktop(true, &code) { return code }
	exe, has := program(o, WREN_EXE)
	if !has { return 1 }
	dir := scratch("cadence")
	defer base.remove_tree(dir)
	page := fmt.tprintf("%s/p.html", dir)
	_ = os.write_entire_file(page, CADENCE_PAGE)
	r := report_begin("cadence", "scenario", "presented", "gap_p50", "gap_p95", "at_once", "drag", "made")
	failed := 0
	check :: proc(failed: ^int, ok: bool, what: string) {
		fmt.printfln("%s  %s", ok ? "PASS" : "FAIL", what)
		if !ok { failed^ += 1 }
	}
	scale := CADENCE_DPI / api.DPI_ONE
	for s in CADENCE_SCENARIOS {
		if !chosen(o, s.name) { continue }
		prefs := make([dynamic]string, context.temp_allocator)
		append(&prefs, ..s.prefs)
		append(&prefs, "browser.frame.variable_refresh=on")
		append(&prefs, ..o.prefs)
		w: Wren
		if !start(&w, {exe = exe, window = .Hidden, size = CADENCE_SIZE, dpi = CADENCE_DPI, prefs = prefs[:], url = file_url(page)}) { return 1 }
		defer stop(&w)
		ses := &w.session
		_ = api.wait_load(ses)
		_ = api.wait_frames(ses, CADENCE_WARM_FRAMES)
		width, height := f64(CADENCE_SIZE.x), f64(CADENCE_SIZE.y)
		from: api.Point
		switch s.name {
		case "devtools_right":
			inner, _ := api.eval(ses, "innerWidth")
			v, _ := strconv.parse_f64(inner)
			from = {(v + CADENCE_DOCK_MARGIN) * scale, height * CADENCE_HEIGHT_PART}
		case "devtools_bottom": from = {width / 2, height - CADENCE_BAR_ABOVE * scale}
		case "sidebar": from = {CADENCE_SIDEBAR_WIDTH * scale - 2, height * CADENCE_HEIGHT_PART}
		}
		amplitude := CADENCE_AMPLITUDE * scale
		to := s.along_x ? api.Point{from.x - amplitude, from.y} : api.Point{from.x, from.y - amplitude}
		_, _ = api.stats(ses, reset_frames = true)
		before := parse_states(result_text(ses, "frameStates"))
		if api.drag(ses, from, to, {space = .Window, steps = CADENCE_DRAG_STEPS, via = {s.along_x ? api.Point{from.x + amplitude, from.y} : api.Point{from.x, from.y + amplitude}}}) != .None { fmt.eprintln(api.last_failure().message); return 1 }
		_, _ = api.stats(ses)
		after := parse_states(result_text(ses, "frameStates"))
		made, drag := 0, 0
		for name, n in after {
			d := n - before[name]
			if d > 0 { made += d; if name == "Drag" { drag = d } }
		}
		presented := result_number(ses, "framesPresented")
		at_once := result_number(ses, "framesAtOnce")
		report_row(&r, s.name, int(presented), result_number(ses, "frameGapP50Ms"), result_number(ses, "frameGapP95Ms"), int(at_once), drag, made)
		check(&failed, made > 0 && f64(drag) >= f64(made) * CADENCE_DRAG_SHARE, fmt.tprintf("%s: %d of %d frames of the drag in the Drag state", s.name, drag, made))
		variable := strings.contains(ses.result, `"variableRefresh":true`)
		if variable { check(&failed, at_once >= presented * CADENCE_AT_ONCE_SHARE, fmt.tprintf("%s: %d of %d frames presented at once", s.name, int(at_once), int(presented))) }
	}
	report_end(&r, o)
	return failed > 0 ? 1 : 0
}

// "Drag=3 Idle=5"
@(private)
parse_states :: proc(s: string) -> map[string]int {
	out := make(map[string]int, context.temp_allocator)
	for kv in strings.fields(s, context.temp_allocator) {
		i := strings.index_byte(kv, '=')
		if i > 0 { v, _ := strconv.parse_int(kv[i + 1:]); out[kv[:i]] = v }
	}
	return out
}
