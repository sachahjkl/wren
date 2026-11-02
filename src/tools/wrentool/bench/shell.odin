package bench

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:remote/api"

// The latency of the shell (tabs, address bar, menu, wheel, resizing) while a page loads or keeps the browser busy: input goes through the channel, each noted on the performance counter before it
// is sent; the browser notes each frame's input poll and present on the same clock (src/browser/shell_latency.odin, build.bat profile). The latency of an input is from there to the present of the first
// frame that polled after it. Windows' clock: on another system, nothing.

SHELL_DIR :: "build/bench/shell"
SHELL_TEXT :: "wren shell latency probe"
FRAME_BUDGET_MS :: 1000.0 / 180
// The chrome, at 100 %: the tab strip's line and the address bar's.
TAB_Y, TAB_X, TAB_SWING :: 21.0, 80.0, 200.0
TAB_RATE :: 4.0
ADDRESS_Y :: 63.0
MENU_FROM_RIGHT :: 27.0
TAB_HOVER_TIME :: 2 * time.Second
MENU_ROUNDS :: 4
WHEEL_ROUNDS :: 40
RESIZE_STEPS :: 20
RESIZE_BASE, RESIZE_STEP :: 0.85, 0.1

Shell_Note :: struct {
	at:    i64,
	kind:  string,
	width: int,    // of a resize: the frame it waits for has it
}

Shell_Scenario :: struct { name, page: string }
SHELL_SCENARIOS := []Shell_Scenario{
	{"blank", "about:blank"}, {"p50k_load", "gen:p50k"}, {"js_anim1000", "jsb:anim1000.html"}, {"js_nodes10k", "jsb:nodes10k.html"}, {"busy200", "gen:busy200"}, {"relayout", "gen:relayout"},
}

bench_shell :: proc(o: ^Options) -> int {
	when ODIN_OS != .Windows {
		fmt.eprintln("the latency of the shell is measured on Windows' clock")
		return 1
	}
	code: int
	if on_desktop(o.window != .Headless, &code) { return code }
	exe, has := program(o, WREN_PROF_EXE)
	if !has { return 1 }
	_ = os.make_directory_all(SHELL_DIR)
	_ = os.make_directory_all(PERF_DIR)
	r := report_begin("shell", "scenario", "inputs", "p50_ms", "p95_ms", "max_ms", "frames", "over", "gap_ms", "chrome", "tab_p95", "address_p95", "menu_p95", "wheel_p95", "resize_p95")
	for s in SHELL_SCENARIOS {
		if !chosen(o, s.name) { continue }
		if !shell_scenario(o, &r, exe, s) { return 1 }
	}
	report_end(&r, o)
	return 0
}

@(private)
shell_scenario :: proc(o: ^Options, r: ^Report, exe: string, s: Shell_Scenario) -> bool {
	url, ok := page_url(s.page)
	if !ok { return false }
	prefix := fmt.tprintf("%s/%s%s", SHELL_DIR, s.name, o.tag)
	cwd, _ := os.get_working_directory(context.temp_allocator)
	env := []string{fmt.tprintf("WREN_PROF=%s/%s", cwd, prefix), "WREN_SAMPLE=0"}
	notes := make([dynamic]Shell_Note, context.temp_allocator)
	w: Wren
	if !start(&w, {exe = exe, window = o.window, prefs = o.prefs, env = env, url = url}) { return false }
	first := shell_interact(&w, &notes)
	stop(&w)
	return shell_analyze(r, s.name, prefix, notes[:], first)
}

// About as long as the loads it is made to meet: the pointer over the tab strip, the address bar typed in, the menu, the wheel, the window's width.
@(private)
shell_interact :: proc(w: ^Wren, notes: ^[dynamic]Shell_Note) -> (first: i64) {
	ses := &w.session
	note :: proc(notes: ^[dynamic]Shell_Note, kind: string, width := 0) { append(notes, Shell_Note{qpc_now(), kind, width}) }
	b, _ := api.window_bounds(ses)
	width, height := b.width, b.height
	first = qpc_now()
	begin := time.tick_now()
	for time.tick_since(begin) < TAB_HOVER_TIME {
		t := time.duration_seconds(time.tick_since(begin))
		note(notes, "tab")
		_ = api.hover(ses, {TAB_X + TAB_SWING * (0.5 + 0.5 * math.sin(t * TAB_RATE)), TAB_Y}, .Window)
	}
	note(notes, "address")
	_ = api.click_at(ses, {f64(width) / 2, ADDRESS_Y}, .Window)
	for c in SHELL_TEXT {
		note(notes, "address")
		_ = api.type_text(ses, fmt.tprintf("%c", c))
	}
	for _ in 0 ..< 2 { note(notes, "address"); _ = api.key(ses, "Escape") }
	for _ in 0 ..< MENU_ROUNDS {
		note(notes, "menu")
		_ = api.click_at(ses, {f64(width) - MENU_FROM_RIGHT, ADDRESS_Y}, .Window)
		note(notes, "menu")
		_ = api.key(ses, "Escape")
	}
	for i in 0 ..< WHEEL_ROUNDS {
		note(notes, "wheel")
		_ = api.scroll(ses, i < WHEEL_ROUNDS / 2 ? -1 : 1, {f64(width) / 2, f64(height) / 2})
	}
	for i in 0 ..< RESIZE_STEPS {
		w_now := int(f64(width) * (RESIZE_BASE + RESIZE_STEP * f64(i % 2))) - i
		note(notes, "resize", w_now)
		_, _ = api.set_window(ses, {size = [2]int{w_now, height}})
	}
	note(notes, "resize", width)
	_, _ = api.set_window(ses, {size = [2]int{width, height}})
	return
}

// freq on the first line, a header, then polled,presented,events,width,?,kind per frame.
@(private)
shell_analyze :: proc(r: ^Report, name, prefix: string, notes: []Shell_Note, first: i64) -> bool {
	data, err := os.read_entire_file(fmt.tprintf("%s.latency.txt", prefix), context.temp_allocator)
	if err != nil { fmt.eprintfln("%s.latency.txt is missing: is this the profile build?", prefix); return false }
	lines := strings.split_lines(string(data), context.temp_allocator)
	head := strings.split(lines[0], ",", context.temp_allocator)
	freq, _ := strconv.parse_f64(strings.trim_space(head[len(head) - 1]))
	Frame :: struct { polled, presented: i64, width, kind: int }
	frames := make([dynamic]Frame, context.temp_allocator)
	for l in lines[min(2, len(lines)):] {
		f := strings.split(strings.trim_space(l), ",", context.temp_allocator)
		if len(f) < 6 { continue }
		polled, _ := strconv.parse_i64(f[0])
		presented, _ := strconv.parse_i64(f[1])
		w, _ := strconv.parse_int(f[3])
		kind, _ := strconv.parse_int(f[5])
		append(&frames, Frame{polled, presented, w, kind})
	}
	ms_of :: proc(ticks: i64, freq: f64) -> f64 { return f64(ticks) * 1000 / freq }
	all := make([dynamic]f64, context.temp_allocator)
	KINDS := []string{"tab", "address", "menu", "wheel", "resize"}
	by_kind := make([][dynamic]f64, len(KINDS), context.temp_allocator)
	j := 0
	for n in notes {
		for j < len(frames) && frames[j].polled < n.at { j += 1 }
		k := j
		if n.kind == "resize" { for k < len(frames) && frames[k].width != n.width { k += 1 } }
		if k >= len(frames) { continue }
		ms := ms_of(frames[k].presented - n.at, freq)
		append(&all, ms)
		for name_, i in KINDS { if name_ == n.kind { append(&by_kind[i], ms) } }
	}
	last := notes[len(notes) - 1].at
	over, count, chrome_only := 0, 0, 0
	gap, previous := 0.0, i64(0)
	for f in frames {
		if f.polled < first || f.polled > last { continue }
		count += 1
		if ms_of(f.presented - f.polled, freq) > FRAME_BUDGET_MS { over += 1 }
		if previous != 0 { gap = max(gap, ms_of(f.presented - previous, freq)) }
		previous = f.presented
		if f.kind == 1 { chrome_only += 1 }
	}
	report_row(r, name, len(all), percentile(all[:], 50), percentile(all[:], 95), percentile(all[:], 100), count, over, gap, chrome_only,
		percentile(by_kind[0][:], 95), percentile(by_kind[1][:], 95), percentile(by_kind[2][:], 95), percentile(by_kind[3][:], 95), percentile(by_kind[4][:], 95))
	return true
}
