// Package bench: what measures Wren, one family. `wrentool bench <name> [flags]`: a table of benches, each a Wren it starts itself with the typed API and no window of the system (-Hidden, -Shown:
// a real window, on a desktop of its own that nobody looks at), one table of results on the standard output and in build/bench/<name><tag>.tsv. A measure asserts nothing unless it says so.
// The driven Wren never touches the machine: no desktop integration, no sound, nobody's single instance. Nothing here sleeps or spins: a call waits for its answer, a barrier for a state; a measured
// period is a wait on the process that runs (it ends the wait if it dies).
package bench

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:remote/api"
import "wb:tools/tooling"

OUT_DIR :: "build/bench"
WASM_CACHE :: "build/wasm_cache"
// How long a Wren may take to answer: the first start of a build compiles the engine.
START_WAIT_MS :: 120_000
WREN_EXE :: "build/wren" + tooling.EXE_SUFFIX
WREN_PROF_EXE :: "build/wren_prof" + tooling.EXE_SUFFIX
EXIT_USAGE :: 2
DEFAULT_SIZE :: [2]int{1280, 800}
// What the Wren of a bench does not touch: the environment of src/e2e, here for another process.
QUIET_ENV := []string{"WREN_DESKTOP_INTEGRATION=off", "WREN_AUDIO_OUTPUT=null", "WREN_SINGLE_INSTANCE=off"}
// How long a page may take to settle before the measure goes on anyway (an animated page is never quiet).
SETTLE_LIMIT :: 15 * time.Second
FLAGS :: "-Exe= -Only= -Tag= -Pref= -Runs= -Seconds= -Shown -Hidden -Sample -GpuSteps= -Url= -Action= -Mode= -Benchmarks= -Engines= -Pages= -Modes= -Threads -Tabs= -Frames= -Perf -Profile= -Urls= -Out= -Software -List"

Bench :: struct {
	name, about: string,
	run:         proc(o: ^Options) -> int,
}

BENCHES := []Bench{
	{"perf", "real pages with real input, by scenario: frames, CPU, memory; the profile build's report per scenario (build.bat profile). -Only a,b -Sample -GpuSteps n -Url u -Action a -Seconds n -Runs n (each scenario n times, then the medians)", bench_perf},
	{"shell", "the latency of the shell while a page loads or keeps the browser busy (build.bat profile). -Only a,b", bench_shell},
	{"js", "Octane in Wren's engine against QuickJS and Edge, DOM micro-benchmarks, realm start-up. -Mode octane|dom|startup|all -Runs n -Benchmarks a,b -Engines wasm,native,edge", bench_js},
	{"idle", "what a Wren at rest costs: CPU, wakes, frames. -Modes headless,hidden,shown -Pages blank,static,field,anim,video -Seconds n -Threads", bench_idle},
	{"webgl", "what WebGL costs on this GPU: examples/site/webgl-stress.html, the demo's frame rate, memory. -Runs n -Software", bench_webgl},
	{"blocker", "each site's load report with and without the content blocker. -Profile dir -Urls a,b -Runs n", bench_blocker},
	{"sidebar", "the CPU of a frame with many tabs. -Tabs n -Frames n [-Perf: the 180 Hz budget is checked]", bench_sidebar},
	{"startup", "from the process start to the first present, single instance on and off, and a second start's hand-over (window on its own desktop; build.bat profile). -Runs n", bench_startup},
	{"cadence", "the frames while a splitter is dragged: in the Drag state of the cadence model, presented at once on a variable refresh screen. -Only devtools_right,devtools_bottom,sidebar", bench_cadence},
}

Options :: struct {
	flags: tooling.Flags,
	exe:   string,
	tag:   string,
	only:  []string,
	prefs: []string,
	runs:  int,
	window: api.Window_Mode,
}

run :: proc(args: []string) -> int {
	if len(args) == 0 || args[0] == "help" {
		fmt.println("wrentool bench <name> [-Exe path] [-Tag suffix] [-Pref name=value] [-Runs n] [-Hidden | -Shown] ...")
		for b in BENCHES { fmt.printfln("  %-9s %s", b.name, b.about) }
		return len(args) == 0 ? EXIT_USAGE : 0
	}
	for &b in BENCHES {
		if b.name != args[0] { continue }
		o: Options
		ok: bool
		o.flags, ok = tooling.parse_flags(args[1:], FLAGS)
		if !ok { return EXIT_USAGE }
		o.exe = tooling.flag(o.flags, "-Exe")
		o.tag = tooling.flag(o.flags, "-Tag")
		o.only = tooling.flag_list(o.flags, "-Only")
		o.prefs = tooling.flag_list(o.flags, "-Pref")
		o.runs = tooling.flag_int(o.flags, "-Runs", 0)
		o.window = tooling.flag_has(o.flags, "-Shown") ? .Visible : tooling.flag_has(o.flags, "-Hidden") ? .Hidden : .Headless
		_ = os.make_directory_all(OUT_DIR)
		return b.run(&o)
	}
	fmt.eprintfln("no bench %s", args[0])
	return EXIT_USAGE
}

chosen :: proc(o: ^Options, name: string) -> bool { return len(o.only) == 0 || slice.contains(o.only, name) }

// The program measured: -Exe, or what it defaults to; it must exist.
program :: proc(o: ^Options, default_exe: string) -> (exe: string, ok: bool) {
	exe = o.exe != "" ? o.exe : default_exe
	if !os.exists(exe) { fmt.eprintfln("%s is missing (build.bat%s)", exe, default_exe == WREN_PROF_EXE ? " profile" : ""); return exe, false }
	return exe, true
}

// Anything with a window of the system goes on a desktop of its own: true, this process has run again there and `code` is its end.
on_desktop :: proc(needed: bool, code: ^int) -> bool {
	return needed && tooling.on_own_desktop(code, "build/tmp")
}

////////////////////////////////
// A Wren

Wren :: struct {
	session:  api.Session,
	launched: api.Launched,
}

Start :: struct {
	exe:     string,
	window:  api.Window_Mode,
	size:    [2]int,      // 0: DEFAULT_SIZE
	dpi:     f64,
	profile: string,      // "": a throwaway one
	prefs:   []string,
	extra:   []string,
	env:     []string,    // on top of QUIET_ENV
	stderr:  string,      // a file for its standard error
	url:     string,
	no_url:  bool,
}

// A Wren that answers. What it could not do is said on standard error.
start :: proc(w: ^Wren, o: Start) -> bool {
	env := make([dynamic]string, context.temp_allocator)
	append(&env, ..QUIET_ENV)
	append(&env, ..o.env)
	extra := make([dynamic]string, context.temp_allocator)
	append(&extra, ..o.extra)
	if o.url != "" { append(&extra, o.url) }
	// (the engine's compiled code shared on the disk, as a test's: a throwaway profile would compile it at each start, for half a minute under load)
	cwd, _ := os.get_working_directory(context.temp_allocator)
	append(&env, fmt.tprintf("WREN_TEST_WASM_CACHE=%s/%s", cwd, WASM_CACHE))
	opt := api.Launch_Options{exe = o.exe, profile = o.profile, window = o.window, dpi = o.dpi, prefs = o.prefs, extra = extra[:], no_address = o.url != "" || o.no_url,
		start = {env = env[:], stderr = {file = o.stderr}}}
	why: string
	w.launched, why = api.launch(opt, context.allocator)
	if why != "" { fmt.eprintfln("%s cannot start: %s", o.exe, why); return false }
	if api.connect_launched(&w.session, &w.launched, START_WAIT_MS) != .None {
		fmt.eprintfln("%s: %s", o.exe, api.last_failure().message)
		_, _ = api.finish(&w.session, &w.launched, false)
		return false
	}
	size := o.size.x > 0 ? o.size : DEFAULT_SIZE
	if _, e := api.set_window(&w.session, {size = size}); e != .None { fmt.eprintfln("the window: %s", api.last_failure().message) }
	return true
}

stop :: proc(w: ^Wren) { _, _ = api.finish(&w.session, &w.launched, true) }

// The page has loaded and what it does at first has calmed down, if it does.
settle :: proc(w: ^Wren) {
	_ = api.wait_load(&w.session)
	_ = api.wait_quiet(&w.session, deadline = SETTLE_LIMIT)
}

// A measured period: nothing is asked of the Wren, nothing runs here.
hold :: proc(w: ^Wren, d: time.Duration) { _ = api.process_wait(&w.launched.process, int(time.duration_milliseconds(d))) }

// A number of the answer of the last call (`Session.result`: all that a stats call says, api.Stats has what tests read). 0 when it is not there.
result_number :: proc(s: ^api.Session, name: string) -> f64 { return json_number(s.result, name) }

// A number of a JSON object's text. 0 when it is not there.
json_number :: proc(text, name: string) -> f64 {
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil { return 0 }
	o, is_object := v.(json.Object)
	if !is_object { return 0 }
	#partial switch n in o[name] {
	case json.Float: return f64(n)
	case json.Integer: return f64(n)
	}
	return 0
}

result_text :: proc(s: ^api.Session, name: string) -> string {
	v, err := json.parse_string(s.result, allocator = context.temp_allocator)
	if err != nil { return "" }
	o, is_object := v.(json.Object)
	if !is_object { return "" }
	text, _ := o[name].(json.String)
	return text
}

// A folder for one bench's scratch files; `base.remove_tree` ends it.
scratch :: proc(name: string) -> string {
	dir := fmt.tprintf("%s/%s/wren-%s-%s", base.temp_dir(context.temp_allocator), "bench", name, base.unique_name(context.temp_allocator))
	_ = os.make_directory_all(dir)
	return dir
}

file_url :: proc(path: string) -> string {
	p, _ := strings.replace_all(tooling_abs(path), `\`, "/", context.temp_allocator)
	return strings.has_prefix(p, "/") ? fmt.tprintf("file://%s", p) : fmt.tprintf("file:///%s", p)
}

@(private)
tooling_abs :: proc(path: string) -> string {
	if strings.contains(path, ":") || strings.has_prefix(path, "/") { return path }
	cwd, _ := os.get_working_directory(context.temp_allocator)
	return fmt.tprintf("%s/%s", cwd, path)
}

////////////////////////////////
// The results

Report :: struct {
	name:    string,
	columns: []string,
	rows:    [dynamic][]string,
}

report_begin :: proc(name: string, columns: ..string) -> Report {
	return {name = name, columns = slice.clone(columns)}
}

report_row :: proc(r: ^Report, values: ..any) {
	row := make([]string, len(values))
	for v, i in values {
		switch x in v {
		case f64: row[i] = fmt.aprintf("%.1f", x)
		case: row[i] = fmt.aprint(v)
		}
	}
	append(&r.rows, row)
	fmt.println(strings.join(row, "  ", context.temp_allocator))
}

// The table, aligned, and its .tsv.
report_end :: proc(r: ^Report, o: ^Options) {
	widths := make([]int, len(r.columns), context.temp_allocator)
	for c, i in r.columns { widths[i] = len(c) }
	for row in r.rows { for v, i in row { widths[i] = max(widths[i], len(v)) } }
	tsv := strings.builder_make(context.temp_allocator)
	line :: proc(values: []string, widths: []int, tsv: ^strings.Builder) {
		for v, i in values {
			fmt.printf("%-*s  ", widths[i], v)
			if i > 0 { strings.write_byte(tsv, '\t') }
			strings.write_string(tsv, v)
		}
		fmt.println()
		strings.write_byte(tsv, '\n')
	}
	fmt.println()
	line(r.columns, widths, &tsv)
	for row in r.rows { line(row, widths, &tsv) }
	path := fmt.tprintf("%s/%s%s.tsv", OUT_DIR, r.name, o.tag)
	_ = os.write_entire_file(path, strings.to_string(tsv))
	fmt.printfln("\n%s", path)
}

median :: proc(values: []f64) -> f64 {
	return percentile(values, 50)
}

// The value at that percentile of the values (0 for none).
percentile :: proc(values: []f64, p: f64) -> f64 {
	if len(values) == 0 { return 0 }
	sorted := slice.clone(values, context.temp_allocator)
	slice.sort(sorted)
	at := int(f64(len(sorted)) * p / 100 + 0.999999) - 1
	return sorted[clamp(at, 0, len(sorted) - 1)]
}
