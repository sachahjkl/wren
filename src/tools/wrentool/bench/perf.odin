package bench

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "wb:remote/api"
import "wb:testserver"
import "wb:tools/tooling"

// The browser on real pages with real input, through the channel. Needs the profile build: each scenario's report (per-phase statistics, CPU, sampling profile) is written by the browser at its
// end in build/perf/<scenario><tag>.txt and .csv (one row per frame). The table has what the channel says of each. -Url u -Action a: a scenario of your own.
// -Pref browser.frame.target_hz=60 -Tag _60 simulates another rate; -Pref canvas.gpu.enabled=false -Tag _sw the software rasterizer.
// Frame pacing against a real refresh needs a window: -Shown, on its own desktop.

PERF_DIR :: "build/perf"   // (about:demos links its pages from there)
SEED :: 42
WORDS := []string{"lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do", "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore", "magna", "aliqua"}
TYPED := "the quick brown fox jumps over the lazy dog "
BACKSPACE_EVERY :: 17
WHEEL_NOTCH_DOWN :: -1.0
// A high-resolution wheel, a touchpad: a quarter of a notch at a time.
TOUCHPAD_NOTCH :: -0.25
// The rate of the input: a headless Wren makes a frame for each as soon as it is asked, and a bench must not make the machine run flat out for nothing. What a scenario sends, as a hand or a mouse sends it.
HOVER_PERIOD_MS :: 8
SCROLL_PERIOD_MS :: 16
WHEEL_PERIOD_MS :: 4
KEY_PERIOD_MS :: 220
TYPING_PERIOD_MS :: 30
RESIZE_PERIOD_STEP_MS :: 16
// How long a wheel goes one way before it comes back: a long run never sits at an end of the page.
WHEEL_TURN :: 2 * time.Second
// The window moves between these parts of its width.
RESIZE_FROM :: 0.8
RESIZE_SWING :: 0.2
RESIZE_PERIOD_MS :: 400.0
// Where the pointer wanders, as parts of the client area.
HOVER_X, HOVER_X_SWING :: 0.5, 0.25
HOVER_Y, HOVER_Y_SWING :: 0.55, 0.30
HOVER_X_RATE, HOVER_Y_RATE :: 3.0, 1.7

// 8 s of input, or of watching, unless a scenario says otherwise.
MEASURE :: 8 * time.Second
// Navigate: the page loaded from about:blank (the process started already), timed from the navigation by the page's own
// Navigation and Paint Timing; the CPU and frames are those of the load until the page is quiet.
Action :: enum u8 { Load, Navigate, Idle, Hover, Scroll, Wheel, Touchpad, Keys, Typing, Resize, Fullscreen }

Scenario :: struct {
	name:   string,
	page:   string,        // gen:<generated page>, site:<examples/site>, jsb:<examples/jsbench>, perf:<tools/perf_pages>, srv:<path of the test server>; "": about:home
	action: Action,
	prefs:  []string,
}

// Scenarios about one element (a selector): it is scrolled into view first, and a Hover wanders over its box instead of the window.
SCENARIO_ELEMENT := [?][2]string{{"card_hover", "#lic"}, {"card_idle", "#lic"}}

FULL_LAYOUT := []string{"layout.incremental.enabled=false"}
FULL_STYLE := []string{"style.incremental.enabled=false"}
NO_COMPOSITOR := []string{"render.compositor.enabled=false"}
NO_JS := []string{"javascript.enabled=false"}
AT_180 := []string{"browser.frame.target_hz=180"}
AUTOPLAY := []string{"media.autoplay.policy=allow-all", "browser.profile.persist=false"}
NOT_PERSISTED := []string{"browser.profile.persist=false"}

SCENARIOS := []Scenario{
	{"home_idle", "", .Idle, nil}, {"home_hover", "", .Hover, nil},
	{"config_scroll", "about:config", .Scroll, nil}, {"config_hover", "about:config", .Hover, nil},
	{"p1k_load", "gen:p1k", .Load, nil}, {"p1k_hover", "gen:p1k", .Hover, nil}, {"p1k_scroll", "gen:p1k", .Scroll, nil},
	{"p10k_load", "gen:p10k", .Load, nil}, {"p10k_idle", "gen:p10k", .Idle, nil}, {"p10k_hover", "gen:p10k", .Hover, nil}, {"p10k_scroll", "gen:p10k", .Scroll, nil}, {"p10k_resize", "gen:p10k", .Resize, nil},
	{"p10k_nav", "gen:p10k", .Navigate, nil},
	// the site's pages loaded from about:blank
	{"nav_index", "site:index.html", .Navigate, nil}, {"nav_about", "site:about.html", .Navigate, nil}, {"nav_layout", "site:layout.html", .Navigate, nil},
	{"nav_style", "site:style.html", .Navigate, nil}, {"nav_text", "site:text.html", .Navigate, nil}, {"nav_modern_css", "site:modern-css.html", .Navigate, nil},
	{"nav_grid", "site:grid.html", .Navigate, nil}, {"nav_forms", "site:forms.html", .Navigate, nil}, {"nav_js_dom", "site:js-dom.html", .Navigate, nil},
	{"nav_legacy", "site:legacy-html.html", .Navigate, nil}, {"nav_shadow_dom", "site:shadow-dom.html", .Navigate, nil}, {"nav_multicol", "site:multicol.html", .Navigate, nil},
	{"p10k_wheel", "gen:p10k", .Wheel, nil}, {"p10k_touchpad", "gen:p10k", .Touchpad, nil}, {"p10k_keys", "gen:p10k", .Keys, nil},
	{"p10k_mq_resize", "gen:p10k_mq", .Resize, nil},
	{"p10k_resize_full", "gen:p10k", .Resize, FULL_LAYOUT}, {"p10k_scroll_nocomp", "gen:p10k", .Scroll, NO_COMPOSITOR},
	{"p50k_load", "gen:p50k", .Load, nil}, {"p50k_scroll", "gen:p50k", .Scroll, nil}, {"p50k_wheel", "gen:p50k", .Wheel, nil}, {"p50k_resize", "gen:p50k", .Resize, nil},
	{"grid10k_load", "gen:grid10k", .Load, nil}, {"grid10k_resize", "gen:grid10k", .Resize, nil},
	{"flex10k_load", "gen:flex10k", .Load, nil}, {"flex10k_resize", "gen:flex10k", .Resize, nil},
	{"typing", "gen:typing", .Typing, nil},
	{"anim", "site:animations.html", .Idle, nil}, {"anim_full", "site:animations.html", .Idle, FULL_LAYOUT},
	{"transforms", "site:transforms.html", .Idle, nil}, {"transforms_nocomp", "site:transforms.html", .Idle, NO_COMPOSITOR}, {"transforms3d", "site:transforms-3d.html", .Idle, nil},
	{"effects", "site:effects.html", .Idle, nil}, {"effects_hover", "site:effects.html", .Hover, nil}, {"effects_wheel", "site:effects.html", .Wheel, nil},
	{"gradients", "site:gradients.html", .Idle, nil},
	// the licence card of about:wren (3D planes, shaders) under a moving pointer, and at rest
	{"card_hover", "about:wren?card=sample", .Hover, nil}, {"card_idle", "about:wren?card=sample", .Idle, nil},
	{"planes_nested", "perf:planes-nested.html", .Idle, nil}, {"planes_nested_merged", "perf:planes-nested.html", .Idle, {"paint.planes.detach_children=false"}},
	// a module changes one text of a page of ~17 000 nodes every 16 ms (examples/mutation), or toggles a class (examples/mutation_class)
	{"mutation", "site:mutation.html", .Idle, nil}, {"mutation_full", "site:mutation.html", .Idle, FULL_LAYOUT}, {"mutation_fullstyle", "site:mutation.html", .Idle, FULL_STYLE},
	{"mutation_class", "site:mutation_class.html", .Idle, nil}, {"mutation_class_fullstyle", "site:mutation_class.html", .Idle, FULL_STYLE},
	// pages driven by their scripts at 180 Hz
	{"js_anim1000", "jsb:anim1000.html", .Idle, AT_180}, {"js_nodes10k", "jsb:nodes10k.html", .Idle, AT_180}, {"js_qsa", "jsb:qsa_loop.html", .Idle, AT_180}, {"js_shadow1000", "jsb:shadow1000.html", .Idle, AT_180},
	{"js_canvas_anim", "jsb:canvas_anim.html?mode=anim", .Idle, AT_180}, {"js_canvas_big", "jsb:canvas_anim.html?mode=big", .Idle, AT_180}, {"js_canvas_idle", "jsb:canvas_anim.html?mode=idle", .Idle, nil},
	{"js_canvas_particles", "jsb:canvas_bench.html?mode=particles", .Idle, AT_180}, {"js_canvas_paths", "jsb:canvas_bench.html?mode=paths", .Idle, AT_180}, {"js_canvas_text", "jsb:canvas_bench.html?mode=text", .Idle, AT_180},
	{"js_canvas_gradients", "jsb:canvas_bench.html?mode=gradients", .Idle, AT_180}, {"js_canvas_game", "jsb:canvas_bench.html?mode=game", .Idle, AT_180}, {"js_canvas_trivial", "jsb:canvas_bench.html?mode=trivial", .Idle, AT_180},
	// without script: pages must cost what they cost before the engine existed
	{"nojs_p10k_load", "gen:p10k", .Load, NO_JS}, {"nojs_p10k_scroll", "gen:p10k", .Scroll, NO_JS}, {"nojs_anim", "site:animations.html", .Idle, NO_JS},
	// a paused video must not make the browser draw; a playing one draws at its picture rate
	{"video_none", "srv:/site/video-bench.html?mode=none", .Idle, nil}, {"video_idle", "srv:/site/video-bench.html?mode=idle", .Idle, nil}, {"video_play", "srv:/site/video-bench.html?mode=play", .Idle, nil}, {"video_mse", "srv:/site/video-bench.html?mode=mse", .Idle, nil},
	// a heavy player without the network (examples/site/yt-sim.html; wrentool gen perf-media makes its files, not committed)
	{"yt_h264_1080p60", "srv:/site/yt-sim.html?src=perf_h264_1080p60", .Idle, AUTOPLAY}, {"yt_h264_1080p60_prog", "srv:/site/yt-sim.html?src=perf_h264_1080p60&mse=0", .Idle, AUTOPLAY},
	{"yt_av1_1080p30", "srv:/site/yt-sim.html?src=perf_av1_1080p30&codecs=av01.0.08M.08", .Idle, AUTOPLAY}, {"yt_short", "srv:/site/yt-sim.html?src=perf_short_1080x1920", .Idle, AUTOPLAY},
	{"yt_h264_1080p60_task", "srv:/site/yt-sim.html?src=perf_h264_1080p60&task=80", .Idle, AUTOPLAY}, {"yt_h264_1080p60_wheel", "srv:/site/yt-sim.html?src=perf_h264_1080p60", .Wheel, AUTOPLAY},
	{"yt_h264_1080p60_fs", "srv:/site/yt-sim.html?src=perf_h264_1080p60&fs=1", .Fullscreen, AUTOPLAY}, {"yt_av1_1080p30_fs", "srv:/site/yt-sim.html?src=perf_av1_1080p30&codecs=av01.0.08M.08&fs=1", .Fullscreen, AUTOPLAY},
	{"yt_boot", "srv:/site/yt-boot.html?batches=14&cards=50", .Load, NOT_PERSISTED},
	// the developer tools at rest: frames must stop once the page has settled
	{"dt_closed_idle", "srv:/site/devtools/dt4.html", .Idle, nil},
	{"dt_console_idle", "gen:dt_static", .Idle, {"browser.devtools.visible=true", "browser.devtools.tab=console"}}, {"dt_elements_idle", "gen:dt_static", .Idle, {"browser.devtools.visible=true", "browser.devtools.tab=elements"}},
	{"dt_network_idle", "srv:/site/devtools/dt4.html", .Idle, {"browser.devtools.visible=true", "browser.devtools.tab=network"}}, {"dt_performance_idle", "gen:dt_static", .Idle, {"browser.devtools.visible=true", "browser.devtools.tab=performance"}},
	{"dt_console_100k_scroll", "gen:dt_console", .Scroll, {"browser.devtools.visible=true", "browser.devtools.tab=console"}},
}

// The Wasm guests of the mutation scenarios: built when a run needs them.
GUEST_FLAGS := []string{"-target:freestanding_wasm32", "-no-entry-point", "-default-to-nil-allocator", "-collection:wren=sdk/odin", "-o:size"}
ensure_guest :: proc(name: string) -> bool {
	wasm := fmt.tprintf("examples/site/%s.wasm", name)
	if os.exists(wasm) { return true }
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, tooling.odin_program(), "build", fmt.tprintf("examples/%s", name))
	append(&cmd, ..GUEST_FLAGS)
	append(&cmd, fmt.tprintf("-out:%s", wasm))
	return tooling.run({command = cmd[:]}) == 0
}

bench_perf :: proc(o: ^Options) -> int {
	code: int
	if on_desktop(o.window != .Headless, &code) { return code }
	exe, has := program(o, WREN_PROF_EXE)
	if !has { return 1 }
	_ = os.make_directory_all(PERF_DIR)
	seconds := tooling.flag_int(o.flags, "-Seconds", 0)
	measure := seconds > 0 ? time.Duration(seconds) * time.Second : MEASURE
	r := report_begin("perf", "scenario", "load_ms", "frames", "fps", "cpu_ms", "private_mb", "set_mb")
	own_url := tooling.flag(o.flags, "-Url")
	if own_url != "" {
		action := Action.Idle
		wanted := tooling.flag(o.flags, "-Action", "idle")
		for a in Action { if strings.equal_fold(fmt.tprint(a), wanted) { action = a } }
		if _, ok := perf_scenario(o, &r, exe, {o.tag != "" ? strings.trim_prefix(o.tag, "_") : "url", own_url, action, nil}, measure); !ok { return 1 }
		report_end(&r, o)
		return 0
	}
	if len(o.only) == 0 { fmt.eprintfln("the whole table is long: name scenarios with -Only (-List lists them)"); list_scenarios(); return EXIT_USAGE }
	// -Runs n: each scenario n times (reports <scenario><tag>_<i>), then a row of the medians: the machine's other programs move one run by a factor of 2
	runs := max(o.runs, 1)
	tag := o.tag
	for s in SCENARIOS {
		if !chosen(o, s.name) { continue }
		rows := make([dynamic]Perf_Row, context.temp_allocator)
		for i in 0 ..< runs {
			if runs > 1 { o.tag = fmt.tprintf("%s_%d", tag, i) }
			row, ok := perf_scenario(o, &r, exe, s, measure)
			if !ok { return 1 }
			append(&rows, row)
		}
		o.tag = tag
		if runs > 1 {
			m: Perf_Row
			for k in 0 ..< len(m) {
				col := make([]f64, runs, context.temp_allocator)
				for row, i in rows { col[i] = row[k] }
				slice.sort(col)
				m[k] = col[runs / 2]
			}
			report_row(&r, fmt.tprintf("%s (median of %d)", s.name, runs), m[0], int(m[1]), m[2], m[3], int(m[4]), int(m[5]))
		}
	}
	report_end(&r, o)
	return 0
}

// What a run of a scenario measured: load ms, frames, frames/s, CPU ms, private and working set MB.
Perf_Row :: [6]f64

list_scenarios :: proc() { for s in SCENARIOS { fmt.printfln("  %-28s %s %v", s.name, s.page, s.action) } }

@(private)
page_url :: proc(page: string) -> (url: string, ok: bool) {
	switch {
	case page == "": return "about:home", true
	case strings.has_prefix(page, "gen:"): return file_url(generated_page(page[len("gen:"):])), true
	case strings.has_prefix(page, "site:"):
		rest := page[len("site:"):]
		if strings.has_prefix(rest, "mutation") && !ensure_guest(rest[:strings.index_byte(rest, '.')]) { return "", false }
		return file_url(fmt.tprintf("examples/site/%s", rest)), true
	case strings.has_prefix(page, "jsb:"):
		rest := page[len("jsb:"):]
		q := strings.index_byte(rest, '?')
		return q < 0 ? file_url(fmt.tprintf("examples/jsbench/%s", rest)) : fmt.tprintf("%s%s", file_url(fmt.tprintf("examples/jsbench/%s", rest[:q])), rest[q:]), true
	case strings.has_prefix(page, "perf:"): return file_url(fmt.tprintf("tools/perf_pages/%s", page[len("perf:"):])), true
	case strings.has_prefix(page, "srv:"):
		if !tooling.ensure_testserver() { return "", false }
		base_port, why := testserver.start()
		if base_port == 0 { fmt.eprintln(why); return "", false }
		return fmt.tprintf("http://127.0.0.1:%d%s", base_port, page[len("srv:"):]), true
	}
	return page, true
}

@(private)
perf_scenario :: proc(o: ^Options, r: ^Report, exe: string, s: Scenario, measure: time.Duration) -> (row: Perf_Row, ok: bool) {
	url: string
	url, ok = page_url(s.page)
	if !ok { return }
	ok = false
	prefix := fmt.tprintf("%s/%s%s", PERF_DIR, s.name, o.tag)
	cwd, _ := os.get_working_directory(context.temp_allocator)
	env := []string{fmt.tprintf("WREN_PROF=%s/%s", cwd, prefix), fmt.tprintf("WREN_SAMPLE=%d", tooling.flag_has(o.flags, "-Sample") ? 1 : 0), fmt.tprintf("WREN_GPU_STEPS=%s", tooling.flag(o.flags, "-GpuSteps", "0"))}
	prefs := make([dynamic]string, context.temp_allocator)
	append(&prefs, ..s.prefs)
	append(&prefs, ..o.prefs)
	w: Wren
	began := time.tick_now()
	if !start(&w, {exe = exe, window = o.window, prefs = prefs[:], env = env, url = s.action == .Navigate ? "about:blank" : url}) { return }
	defer stop(&w)
	ses := &w.session
	if e := api.wait_load(ses); e != .None { fmt.eprintfln("%s: %s", s.name, api.last_failure().message); return }
	load_ms := time.duration_milliseconds(time.tick_since(began))
	if s.action != .Load { settle(&w) }
	_, _ = api.stats(ses, reset_frames = true)
	before := time.tick_now()
	if s.action == .Navigate {
		load_ms, ok = perf_navigate(&w, s.name, url)
		if !ok { return }
		ok = false
	} else {
		perf_action(&w, s, measure)
	}
	took := time.duration_seconds(time.tick_since(before))
	st, e := api.stats(ses)
	if e != .None { fmt.eprintfln("%s: %s", s.name, api.last_failure().message); return }
	row = {load_ms, f64(st.frames_drawn), f64(st.frames_drawn) / max(took, 0.001), st.cpu_time_ms, f64(st.private_bytes / tooling_mb), f64(st.working_set_bytes / tooling_mb)}
	fmt.printfln("%s: frame gaps p50 %.1f, p95 %.1f, p99 %.1f, max %.1f ms; CPU of a frame %.2f ms (p95 %.2f), GPU %.2f ms", s.name, st.frame_gap_p50_ms, st.frame_gap_p95_ms, st.frame_gap_p99_ms, st.frame_gap_max_ms, st.cpu_ms, st.cpu_p95_ms, st.gpu_ms)
	report_row(r, s.name, row[0], st.frames_drawn, row[2], row[3], st.private_bytes / tooling_mb, st.working_set_bytes / tooling_mb)
	return row, true
}

@(private) tooling_mb :: 1024 * 1024

// The page's own timings of a navigation, in ms from its start: the response's end, the DOM interactive, the
// DOMContentLoaded handlers' end, the first contentful paint (-1: none), the load handlers' end.
@(private) NAV_TIMING :: "(function(){var n=performance.getEntriesByType('navigation')[0]||{};var p=performance.getEntriesByName('first-contentful-paint')[0];" +
	"return JSON.stringify({response:n.responseEnd,interactive:n.domInteractive,dcl:n.domContentLoadedEventEnd,fcp:p?p.startTime:-1,load:n.loadEventEnd})})()"

// The Navigate action: `url` loaded from the page already open, then the page's timings printed. load_ms: from the
// navigation's start to the end of the load handlers, as the page measured it.
@(private)
perf_navigate :: proc(w: ^Wren, name, url: string) -> (load_ms: f64, ok: bool) {
	ses := &w.session
	if e := api.navigate(ses, url); e != .None { fmt.eprintfln("%s: %s", name, api.last_failure().message); return }
	settle(w)
	text, e := api.eval(ses, NAV_TIMING)
	if e != .None { fmt.eprintfln("%s: %s", name, api.last_failure().message); return }
	fmt.printfln("%s: response %.1f, interactive %.1f, DOMContentLoaded %.1f, first contentful paint %.1f, load %.1f ms", name,
		json_number(text, "response"), json_number(text, "interactive"), json_number(text, "dcl"), json_number(text, "fcp"), json_number(text, "load"))
	return json_number(text, "load"), true
}

// `measure` of input of this kind, or of nothing. Each call waits for the browser's answer: the rate of the input is the rate it takes it at.
@(private)
perf_action :: proc(w: ^Wren, s: Scenario, measure: time.Duration) {
	ses := &w.session
	action := s.action
	bounds, _ := api.window_bounds(ses)
	width, height := f64(bounds.width), f64(bounds.height)
	// where the pointer wanders: the window, or the element named
	area := api.Rect{0, 0, width, height}
	for o in SCENARIO_ELEMENT {
		if o[0] != s.name { continue }
		_, _ = api.eval(ses, fmt.tprintf("document.querySelector(%q).scrollIntoView({{block: 'center'}})", o[1]))
		settle(w)
		_, _ = api.stats(ses, reset_frames = true)
		if b, e := api.box_model(ses, o[1]); e == .None && b.visible { area = b.window } else { fmt.eprintfln("%s: no box for %q", s.name, o[1]) }
	}
	begin := time.tick_now()
	left :: proc(begin: time.Tick, measure: time.Duration) -> bool { return time.tick_since(begin) < measure }
	switch action {
	case .Load, .Navigate:
	case .Idle: hold(w, measure)
	case .Hover:
		for left(begin, measure) {
			t := time.duration_seconds(time.tick_since(begin))
			at := api.Point{area.x + area.w * (HOVER_X + HOVER_X_SWING * math.sin(t * HOVER_X_RATE)), area.y + area.h * (HOVER_Y + HOVER_Y_SWING * math.sin(t * HOVER_Y_RATE))}
			if api.hover(ses, at, .Window) != .None { return }
			pace(w, HOVER_PERIOD_MS)
		}
	case .Scroll:
		for left(begin, measure) { if api.scroll(ses, 3 * WHEEL_NOTCH_DOWN, {width / 2, height / 2}) != .None { return }; pace(w, SCROLL_PERIOD_MS) }
	case .Wheel, .Touchpad:
		notch := action == .Wheel ? WHEEL_NOTCH_DOWN : TOUCHPAD_NOTCH
		for left(begin, measure) {
			back := int(time.tick_since(begin) / WHEEL_TURN) % 2 == 1
			if api.scroll(ses, back ? -notch : notch, {width / 2, height / 2}) != .None { return }
			pace(w, WHEEL_PERIOD_MS)
		}
	case .Keys:
		KEYS := []string{"PageDown", "PageDown", "PageDown", "PageDown", "PageUp", "PageUp", "PageUp", "PageUp", "Down", "Down", "Down", "Down", "Space", "End", "Home"}
		for i := 0; left(begin, measure); i += 1 { if api.key(ses, KEYS[i % len(KEYS)]) != .None { return }; pace(w, KEY_PERIOD_MS) }
	case .Typing:
		for i := 0; left(begin, measure); i += 1 {
			c := TYPED[i % len(TYPED)]
			if api.type_text(ses, fmt.tprintf("%c", c)) != .None { return }
			if i % BACKSPACE_EVERY == 0 { _ = api.key(ses, "Backspace") }
			pace(w, TYPING_PERIOD_MS)
		}
	case .Resize:
		for left(begin, measure) {
			ms := time.duration_milliseconds(time.tick_since(begin))
			w_now := int(width * (RESIZE_FROM + RESIZE_SWING * math.sin(ms / RESIZE_PERIOD_MS)))
			if _, e := api.set_window(ses, {size = [2]int{w_now, int(height)}}); e != .None { return }
			pace(w, RESIZE_PERIOD_STEP_MS)
		}
		_, _ = api.set_window(ses, {size = [2]int{int(width), int(height)}})
	case .Fullscreen:
		_ = api.key(ses, "F11")
		settle(w)
		_, _ = api.stats(ses, reset_frames = true)
		hold(w, measure)
	}
}

// The next input is due then: a wait on the process, which ends it if the Wren dies.
pace :: proc(w: ^Wren, ms: int) { _ = api.process_wait(&w.launched.process, ms) }

////////////////////////////////
// The generated pages (build/bench/perf, made once)

// A page's path, made when it is not there.
generated_page :: proc(name: string) -> string {
	path := fmt.tprintf("%s/%s.html", PERF_DIR, name)
	if os.exists(path) { return path }
	text: string
	switch name {
	case "p1k": text = page_of_sections(name, 1000, 300)
	case "p10k": text = page_of_sections(name, 10_000, 2000)
	case "p50k": text = page_of_sections(name, 50_000, 5000)
	case "p10k_mq":
		text, _ = strings.replace(page_of_sections(name, 10_000, 2000), "</style>", "@media (max-width: 400px) { h3 { font-size: 14px } }</style>", 1, context.temp_allocator)
	case "grid10k": text = page_of_items(name, "display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:6px", "", 10_000)
	case "flex10k": text = page_of_items(name, "display:flex;flex-wrap:wrap;gap:6px", "flex:1 1 140px", 10_000)
	case "typing": text = page_of_typing(name)
	case "dt_static": text = "<!doctype html><meta charset=utf-8><title>dt_static</title><h1>Nothing moves</h1><p>A static page for the panel at rest.</p>"
	case "dt_console": text = "<!doctype html><meta charset=utf-8><title>dt_console</title><script>for (var i = 0; i < 100000; i++) console.log('line', i, {a: i, b: [1, 2, 3]});</script><p>100 000 console lines</p>"
	case "busy200": text = page_busy(name, 400, "var n=0,s=document.getElementById('s');setInterval(function(){var e=performance.now()+200;while(performance.now()<e){}s.textContent=++n},250)")
	case "relayout": text = page_busy(name, 12_000, "var n=0;setInterval(function(){n++;document.body.style.width=(900+n%2*40)+'px'},150)")
	}
	_ = os.write_entire_file(path, text)
	return path
}

@(private)
lorem :: proc(b: ^strings.Builder, n: int) {
	for i in 0 ..< n {
		fmt.sbprintfln(b, "<p>Paragraph %d %s %s %s lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor.</p>", i, WORDS[i % len(WORDS)], WORDS[(i * 7) % len(WORDS)], WORDS[(i * 3) % len(WORDS)])
	}
}

@(private)
page_busy :: proc(name: string, paragraphs: int, script: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "<!doctype html><meta charset=utf-8><title>%s</title><style>body{{font:15px sans-serif;margin:16px}} p{{margin:4px 0}}</style><p id=s>0</p>", name)
	lorem(&b, paragraphs)
	fmt.sbprintf(&b, "<script>%s</script>", script)
	return strings.to_string(b)
}

@(private)
page_of_typing :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "<!doctype html><html><head><meta charset=utf-8><title>%s</title><style>body{{margin:0;font:15px sans-serif}} input,textarea{{display:block;margin:12px;width:600px;font-size:16px}} p{{margin:4px 12px}}</style></head><body>", name)
	strings.write_string(&b, "<input autofocus value='start '><textarea rows=4>notes</textarea>\n")
	lorem(&b, 2000)
	strings.write_string(&b, "</body></html>\n")
	return strings.to_string(b)
}

@(private)
page_of_items :: proc(name, container, item: string, count: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "<!doctype html><html><head><meta charset=utf-8><title>%s</title><style>body{{margin:0;font-size:14px;background:#f4f6fb}} .c{{%s;padding:8px}} .it{{%s;background:#fff;border:1px solid #ccd;border-radius:6px;padding:6px}} .it b{{display:block}}</style></head><body><div class=c>", name, container, item)
	for i in 0 ..< count { fmt.sbprintf(&b, "<div class=it><b>Item %d</b>%s %s %s</div>", i, WORDS[i % len(WORDS)], WORDS[(i * 7) % len(WORDS)], WORDS[(i * 3) % len(WORDS)]) }
	strings.write_string(&b, "</div></body></html>\n")
	return strings.to_string(b)
}

// Sections of articles under `rules` rules of every kind a real sheet has.
@(private)
page_of_sections :: proc(name: string, elements, rules: int) -> string {
	state := rand.create(SEED)
	gen := rand.default_random_generator(&state)
	context.random_generator = gen
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<!doctype html><html><head><meta charset=utf-8><title>%s</title><style>body{{margin:0;font-size:15px;color:#223;background:#fafbff}} .sec{{margin:8px 16px;padding:8px;border:1px solid #ccd}} article{{padding:6px;margin:4px 0;background:#fff}} h3{{margin:0 0 4px;font-size:16px}} p{{margin:2px 0}}\n", name)
	for i in 0 ..< rules {
		c := 0x222222 + rand.int_max(0xdddddd - 0x222222)
		switch i % 7 {
		case 0: fmt.sbprintfln(&b, ".c%d {{ color: #%06x }}", i, c)
		case 1: fmt.sbprintfln(&b, ".sec .c%d p {{ padding: %dpx }}", i, i % 5)
		case 2: fmt.sbprintfln(&b, "article > p.c%d {{ margin-left: %dpx }}", i, i % 9)
		case 3: fmt.sbprintfln(&b, "[data-k='%d'] {{ border-left: 2px solid #%06x }}", i, c)
		case 4: fmt.sbprintfln(&b, "article:nth-child(3n+%d) span.c%d {{ font-weight: bold }}", i % 3, i)
		case 5: fmt.sbprintfln(&b, "section article span.c%d, h3.c%d {{ text-decoration: underline }}", i, i)
		case 6: fmt.sbprintfln(&b, ".c%d:hover {{ background: #%06x }}", i, c)
		}
	}
	strings.write_string(&b, "</style></head><body><main>\n")
	made, k := 0, 0
	for made < elements {
		fmt.sbprintf(&b, "<section class='sec c%d'>", k % rules)
		made += 1
		for _ in 0 ..< 5 {
			fmt.sbprintf(&b, "<article data-k='%d'><h3 class='c%d'>Title %d</h3><p class='c%d'>", k % rules, (k * 3) % rules, k, (k * 7) % rules)
			made += 3
			for s in 0 ..< 3 {
				fmt.sbprintf(&b, "<span class='c%d'>", (k * 11 + s) % rules)
				for _ in 0 ..< 8 { fmt.sbprintf(&b, "%s ", WORDS[rand.int_max(len(WORDS))]) }
				strings.write_string(&b, "</span>")
				made += 1
			}
			strings.write_string(&b, "</p></article>")
			k += 1
		}
		strings.write_string(&b, "</section>\n")
	}
	strings.write_string(&b, "</main></body></html>\n")
	return strings.to_string(b)
}
