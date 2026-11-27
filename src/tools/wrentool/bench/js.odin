package bench

// The JavaScript benchmarks: Octane in Wren's engine (QuickJS-ng compiled to Wasm, under Wasmtime) against the same engine compiled natively (qjs.exe of the release the engine is built from)
// and against Microsoft Edge (V8); the DOM and binding micro-benchmarks of examples/jsbench/dom.html in Wren (build/jspage.exe, a page without a window) and in Edge; realm start-up and memory.
// Octane is pinned: a commit of github.com/chromium/octane, every file by its SHA-256 (src/tools/tooling/octane.odin). Edge is the installed one (its version is printed), headless, with a profile of its own.
// Each figure is the median of -Runs runs, a fresh realm or process each; Octane's scores are its own (higher is better).

import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:tools/tooling"

JS_RUNS :: 3
// What one run of anything may take: a whole Octane benchmark in the slowest engine.
RUN_LIMIT :: 15 * time.Minute
// (Octane's pins and its folder, build/bench/octane, are tooling's: the cost gate of test_all fetches the same files)
OCTANE_COMMIT_SHOWN :: 12
// qjs.exe of the QuickJS-ng release the engine is built from (the version is tooling.QJS_VERSION).
QJS_EXE_SHA256 :: "2aeabf0092c3262d6b2609824418f7dd7ed1f1df939f73b2b15645230cac0d77"
QJS_URL :: "https://github.com/quickjs-ng/quickjs/releases/download/v" + tooling.QJS_VERSION + "/qjs-windows-x86_64.exe"
QJS_FILE :: "build/tools/qjs-" + tooling.QJS_VERSION + "-windows-x86_64.exe"
// build/jsengine bench: one realm per run, the median of -iterations (one: the runs are taken one by one here to keep them all).
WASM_ITERATIONS :: "1"
DOM_PAGE :: "examples/jsbench/dom.html"
STARTUP_PAGE :: "examples/jsbench/startup.html"
DOM_WAIT_MS :: "60000"
STARTUP_WAIT_MS :: "10000"
DOM_DONE :: "DONE"
STARTUP_REALMS :: "50"
STARTUP_RAW_REALMS :: "10"
WASMBENCH_WASM :: "build/wasmbench.wasm"
WASMBENCH_ROW :: "| 1 M host calls () (ns/call) |"
// Edge, headless and quiet: its own profile is added by the caller.
EDGE_ARGS := []string{"--headless=new", "--disable-gpu", "--no-first-run", "--disable-extensions"}
EDGE_REL :: `\Microsoft\Edge\Application\msedge.exe`
EDGE_ROOTS := []string{"ProgramFiles(x86)", "ProgramFiles"}
EDGE_RESULTS_OPEN :: `<pre id="results">`
EDGE_RESULTS_CLOSE :: "</pre>"

// What the shells of Octane run after the suite's files. zlib's Emscripten code takes a shell without a window for d8 and assigns its read(): qjs has none.
OCTANE_RUNNER :: `BenchmarkSuite.RunSuites({ NotifyResult: function(n, r) {}, NotifyError: function(n, e) { print("ERROR " + n + " " + e); }, NotifyScore: function(s) { print("SCORE " + s); } });`
NATIVE_PRELUDE :: "if (typeof read === 'undefined') { var read = function (f) { throw new Error('read() is not available: ' + f); }; }\n"
// Synchronous, like the shells: base.js steps through setTimeout only when window.setTimeout exists.
EDGE_OCTANE_PAGE :: `<!doctype html><meta charset=utf-8><title>Octane %s</title><pre id="results"></pre>
<script>var __st = window.setTimeout; window.setTimeout = undefined; var __out = []; function print(s) { __out.push(s); }</script>
%s
<script>%s window.setTimeout = __st; document.getElementById('results').textContent = __out.join('\n');</script>
`
SCORE_PREFIX :: "SCORE "

Engine :: enum { Wasm, Native, Edge }

ENGINE_NAMES := [Engine]string{.Wasm = "wasm", .Native = "native", .Edge = "edge"}
ENGINE_LABELS := [Engine]string{.Wasm = "Wren (Wasm)", .Native = "QuickJS native", .Edge = "Edge (V8)"}

bench_js :: proc(o: ^Options) -> int {
	when ODIN_OS != .Windows {
		fmt.eprintln("bench js is not available here (jspage, qjs.exe and Edge are Windows programs)")
		return 1
	} else {
		mode := tooling.flag(o.flags, "-Mode", "all")
		if mode != "octane" && mode != "dom" && mode != "startup" && mode != "all" { fmt.eprintfln("no mode %s (octane, dom, startup, all)", mode); return EXIT_USAGE }
		engines: bit_set[Engine]
		for name in tooling.flag_list(o.flags, "-Engines", {"wasm", "native", "edge"}) {
			found := false
			for n, e in ENGINE_NAMES { if n == name { engines += {e}; found = true } }
			if !found { fmt.eprintfln("no engine %s (wasm, native, edge)", name); return EXIT_USAGE }
		}
		if o.runs <= 0 { o.runs = JS_RUNS }
		code := 0
		if mode == "octane" || mode == "all" { code = max(code, js_octane(o, engines)) }
		if mode == "dom" || mode == "all" { code = max(code, js_dom(o, engines)) }
		if mode == "startup" || mode == "all" { code = max(code, js_startup(o)) }
		return code
	}
}

////////////////////////////////
// What runs

// A program run to its end, what it printed (both streams): ok false when it could not start or passed `limit` (the tree is killed). Waits on the process.
run_text :: proc(command: []string, limit := time.Duration(RUN_LIMIT)) -> (text: string, ok: bool) {
	_ = os.make_directory_all(OUT_DIR)   // (a fresh checkout has no build/bench)
	log := fmt.tprintf("%s/run-%s.log", OUT_DIR, base.unique_name(context.temp_allocator))
	p, why := tooling.spawn({command = command, log = log})
	if why != "" { fmt.eprintfln("%s cannot start: %s", command[0], why); return "", false }
	_, timed_out := tooling.wait(&p, limit)
	tooling.release(&p)   // (what it started dies with it)
	data, _ := os.read_entire_file(log, context.temp_allocator)
	_ = os.remove(log)
	if timed_out { fmt.eprintfln("%s did not finish in %v", command[0], limit) }
	return string(data), !timed_out
}

// A tool of src/tools, built unless it is up to date.
build_tool :: proc(name: string) -> (exe: string, ok: bool) {
	exe = fmt.tprintf("build/%s%s", name, tooling.EXE_SUFFIX)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, tooling.odin_program(), "build", fmt.tprintf("src/tools/%s", name), "-collection:wb=src", "-collection:toolkit=ext/gui_toolkit/src", "-vet", "-o:speed", fmt.tprintf("-out:%s", exe))
	append(&cmd, ..tooling.STACK_FLAGS)
	return exe, tooling.build_if_stale(exe, name, cmd[:])
}

// Microsoft Edge, "" when it is not installed.
edge_exe :: proc() -> string {
	when ODIN_OS == .Windows {
		for name in EDGE_ROOTS {
			root, found := os.lookup_env(name, context.temp_allocator)
			if !found { continue }
			path := strings.concatenate({root, EDGE_REL}, context.temp_allocator)
			if os.exists(path) { return path }
		}
	}
	return ""
}

// The folder of Edge's version is named by it, beside msedge.exe.
edge_version :: proc() -> string {
	exe := edge_exe()
	if exe == "" { return "not installed" }
	entries, err := os.read_all_directory_by_path(filepath.dir(exe), context.temp_allocator)
	if err == nil {
		for e in entries { if e.type == .Directory && len(e.name) > 0 && e.name[0] >= '0' && e.name[0] <= '9' && strings.contains(e.name, ".") { return e.name } }
	}
	return "unknown version"
}

// What Edge's --dump-dom of a page made of scripts says in <pre id="results"> (the page writes it before the load event).
edge_dump :: proc(page: string) -> (results: string, ok: bool) {
	profile := scratch("edge")
	defer base.remove_tree(profile)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, edge_exe())
	append(&cmd, ..EDGE_ARGS)
	append(&cmd, "--allow-file-access-from-files", fmt.tprintf("--user-data-dir=%s", profile), "--dump-dom", file_url(page))
	text, finished := run_text(cmd[:])
	if !finished { return "", false }
	start := strings.index(text, EDGE_RESULTS_OPEN)
	if start < 0 { return "", false }
	rest := text[start + len(EDGE_RESULTS_OPEN):]
	end := strings.index(rest, EDGE_RESULTS_CLOSE)
	if end < 0 { return "", false }
	return html_decode(rest[:end]), true
}

@(private = "file")
html_decode :: proc(s: string) -> string {
	out := s
	for pair in ([][2]string{{"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", `"`}, {"&#39;", "'"}, {"&amp;", "&"}}) { out, _ = strings.replace_all(out, pair[0], pair[1], context.temp_allocator) }
	return out
}

////////////////////////////////
// Figures

figure :: proc(x: f64, decimals: int) -> string { return math.is_nan(x) ? "n/a" : fmt.tprintf("%.*f", decimals, x) }

ratio :: proc(a, b: f64, decimals: int) -> string { return math.is_nan(a) || math.is_nan(b) || b == 0 ? "n/a" : figure(a / b, decimals) }

// n/a (NaN) for no figure.
median_of :: proc(values: []f64) -> f64 { return len(values) == 0 ? math.nan_f64() : median(values) }

geomean :: proc(values: []f64) -> f64 {
	sum, n := 0.0, 0
	for v in values { if v > 0 && !math.is_nan(v) { sum += math.ln(v); n += 1 } }
	return n == 0 ? math.nan_f64() : math.exp(sum / f64(n))
}

// The numbers of a line, in order.
numbers_in :: proc(line: string) -> []f64 {
	out := make([dynamic]f64, context.temp_allocator)
	for i := 0; i < len(line); {
		if line[i] < '0' || line[i] > '9' { i += 1; continue }
		j := i
		for j < len(line) && (line[j] >= '0' && line[j] <= '9' || line[j] == '.') { j += 1 }
		if v, ok := strconv.parse_f64(line[i:j]); ok { append(&out, v) }
		i = j
	}
	return out[:]
}

flat :: proc(text: string) -> string {
	lines, _ := strings.split_lines(strings.trim_space(text), context.temp_allocator)
	return strings.join(lines, " / ", context.temp_allocator)
}

////////////////////////////////
// Octane

Octane_Tools :: struct { jsengine, qjs: string }

js_octane :: proc(o: ^Options, engines: bit_set[Engine]) -> int {
	suite := make([dynamic]tooling.Octane_Benchmark, context.temp_allocator)
	for name in tooling.flag_list(o.flags, "-Benchmarks", nil) {
		b, found := tooling.octane_benchmark(name)
		if !found { fmt.eprintfln("no Octane benchmark %s", name); return EXIT_USAGE }
		append(&suite, b)
	}
	if len(suite) == 0 { append(&suite, ..tooling.OCTANE_SUITE) }
	if !tooling.octane_fetch(tooling.OCTANE_DIR, nil) { return 1 }
	tools: Octane_Tools
	if .Wasm in engines {
		_ = tooling.build_js_engine({})
		good: bool
		if tools.jsengine, good = build_tool("jsengine"); !good { fmt.eprintln("building src/tools/jsengine failed"); return 1 }
	}
	if .Native in engines {
		if !tooling.download_pinned(QJS_URL, QJS_FILE, QJS_EXE_SHA256) { return 1 }
		tools.qjs = QJS_FILE
	}
	if .Edge in engines && edge_exe() == "" { fmt.eprintln("Microsoft Edge is not installed"); return 1 }

	log := OUT_DIR + "/octane.log"
	_ = os.write_entire_file(log, "")
	scores: [Engine][][dynamic]f64
	for e in Engine {
		if e not_in engines { continue }
		scores[e] = make([][dynamic]f64, len(suite), context.temp_allocator)
		for b, i in suite {
			for _ in 0 ..< o.runs {
				out, score, has := octane_once(e, b, tools)
				tooling.append_text(log, fmt.tprintfln("%s %s %s", ENGINE_NAMES[e], b.name, flat(out)))
				if has { append(&scores[e][i], score) }
			}
			fmt.printfln("%-6s %-14s %v", ENGINE_NAMES[e], b.name, scores[e][i][:])
		}
	}

	columns := make([dynamic]string, context.temp_allocator)
	append(&columns, "benchmark")
	for e in Engine { if e in engines { append(&columns, ENGINE_LABELS[e]) } }
	if engines >= {.Wasm, .Native} { append(&columns, "Wasm / native") }
	if engines >= {.Wasm, .Edge} { append(&columns, "Wasm / Edge") }
	r := report_begin("js_octane", ..columns[:])
	medians: [Engine][]f64
	for e in Engine { medians[e] = make([]f64, len(suite), context.temp_allocator) }
	for _, i in suite {
		for e in Engine { if e in engines { medians[e][i] = median_of(scores[e][i][:]) } }
	}
	for b, i in suite {
		values: [Engine]f64
		for e in Engine { values[e] = medians[e][i] }
		octane_row(&r, b.name, engines, values)
	}
	total: [Engine]f64
	for e in Engine { total[e] = geomean(medians[e]) }
	octane_row(&r, "score (geometric mean)", engines, total)
	report_end(&r, o)
	fmt.printfln("Octane %s, median of %d runs (a fresh realm or process each); Edge %s headless. A benchmark that fails shows n/a.", tooling.OCTANE_COMMIT[:OCTANE_COMMIT_SHOWN], o.runs, edge_version())
	return 0
}

@(private = "file")
octane_row :: proc(r: ^Report, name: string, engines: bit_set[Engine], v: [Engine]f64) {
	cells := make([dynamic]any, context.temp_allocator)
	append(&cells, name)
	for e in Engine { if e in engines { append(&cells, figure(v[e], 0)) } }
	if engines >= {.Wasm, .Native} { append(&cells, ratio(v[.Wasm], v[.Native], 2)) }
	if engines >= {.Wasm, .Edge} { append(&cells, ratio(v[.Wasm], v[.Edge], 3)) }
	report_row(r, ..cells[:])
}

// One run of one benchmark in one engine: what it printed and its score.
@(private = "file")
octane_once :: proc(e: Engine, b: tooling.Octane_Benchmark, tools: Octane_Tools) -> (out: string, score: f64, has: bool) {
	switch e {
	case .Wasm:
		text, _ := run_text({tools.jsengine, "bench", "-iterations", WASM_ITERATIONS, tooling.OCTANE_DIR, b.name})
		for line in strings.split_lines(text, context.temp_allocator) {
			fields := strings.fields(line, context.temp_allocator)
			if len(fields) >= 2 && fields[0] == b.name { score, has = strconv.parse_f64(fields[1]) }
		}
		return text, score, has
	case .Native:
		script := fmt.tprintf("%s/native_%s.js", OUT_DIR, b.name)
		text := strings.builder_make(context.temp_allocator)
		strings.write_string(&text, NATIVE_PRELUDE)
		write_octane_file(&text, "base.js")
		for file in b.files { write_octane_file(&text, file) }
		strings.write_string(&text, OCTANE_RUNNER)
		_ = os.write_entire_file(script, strings.to_string(text))
		printed, _ := run_text({tools.qjs, "--script", script})
		score, has = last_score(printed)
		return printed, score, has
	case .Edge:
		tags := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&tags, `<script src="octane/base.js"></script>`)
		for file in b.files { fmt.sbprintf(&tags, "\n<script src=\"octane/%s\"></script>", file) }
		page := fmt.tprintf("%s/edge_%s.html", OUT_DIR, b.name)
		_ = os.write_entire_file(page, fmt.tprintf(EDGE_OCTANE_PAGE, b.name, strings.to_string(tags), OCTANE_RUNNER))
		printed, _ := edge_dump(page)
		score, has = last_score(printed)
		return printed, score, has
	}
	return
}

@(private = "file")
write_octane_file :: proc(b: ^strings.Builder, file: string) {
	data, _ := os.read_entire_file(fmt.tprintf("%s/%s", tooling.OCTANE_DIR, file), context.temp_allocator)
	strings.write_string(b, string(data))
	strings.write_byte(b, '\n')
}

@(private = "file")
last_score :: proc(text: string) -> (score: f64, has: bool) {
	for line in strings.split_lines(text, context.temp_allocator) {
		if strings.has_prefix(line, SCORE_PREFIX) { score, has = strconv.parse_f64(strings.trim_space(line[len(SCORE_PREFIX):])) }
	}
	return
}

////////////////////////////////
// DOM and binding micro-benchmarks

js_dom :: proc(o: ^Options, engines: bit_set[Engine]) -> int {
	use := engines - {.Native}
	log := OUT_DIR + "/dom.log"
	_ = os.write_entire_file(log, "")
	jspage: string
	if .Wasm in use {
		good: bool
		if jspage, good = build_tool("jspage"); !good { fmt.eprintln("building src/tools/jspage failed"); return 1 }
	}
	if .Edge in use && edge_exe() == "" { fmt.eprintln("Microsoft Edge is not installed"); return 1 }
	order := make([dynamic]string, context.temp_allocator)
	values: [Engine]map[string][dynamic]string
	for e in use { values[e] = make(map[string][dynamic]string, context.temp_allocator) }
	for e in use {
		for i in 0 ..< o.runs {
			text: string
			if e == .Wasm {
				cmd := make([dynamic]string, context.temp_allocator)
				append(&cmd, jspage, "-wait", DOM_WAIT_MS, "-until", DOM_DONE)
				for p in o.prefs { append(&cmd, "--pref", p) }
				append(&cmd, file_url(DOM_PAGE))
				text, _ = run_text(cmd[:])
			} else {
				text, _ = edge_dump(DOM_PAGE)
			}
			tooling.append_text(log, fmt.tprintfln("%s run %d\n%s", ENGINE_NAMES[e], i, text))
			for line in strings.split_lines(text, context.temp_allocator) {
				fields := strings.split(strings.trim_right(line, "\r"), "\t", context.temp_allocator)
				if len(fields) < 3 || fields[0] != "CASE" { continue }
				if !slice_has(order[:], fields[1]) { append(&order, fields[1]) }
				cases := &values[e]
				list := cases[fields[1]]
				append(&list, fields[2])
				cases[fields[1]] = list
			}
		}
	}

	r := report_begin("js_dom", "case", "Wren", "Edge", "Wren / Edge")
	for name in order {
		wren_text, wren_ns := dom_cell(values[.Wasm][name])
		edge_text, edge_ns := dom_cell(values[.Edge][name])
		report_row(&r, name, wren_text, edge_text, wren_ns > 0 && edge_ns > 0 ? figure(wren_ns / edge_ns, 1) : "")
	}
	// The floor of a call from Wasm to the browser, without JavaScript (src/tools/wasmbench, Cranelift).
	if .Wasm in use {
		if floor, has := wasm_call_floor(); has { report_row(&r, "raw call Wasm -> browser, no argument (src/tools/wasmbench)", fmt.tprintf("%s ns", floor), "", "") }
	}
	report_end(&r, o)
	fmt.printfln("Time per operation (median of %d runs). Wren: build/jspage (the page loaded as in the browser, without a window); Edge %s headless. A case whose API Wren lacks shows the error it threw.", o.runs, edge_version())
	return 0
}

@(private = "file")
slice_has :: proc(list: []string, s: string) -> bool {
	for x in list { if x == s { return true } }
	return false
}

// The median of the numbers a case gave, in ns; a case that gave none shows its first answer (an error), or n/a.
@(private = "file")
dom_cell :: proc(answers: [dynamic]string) -> (text: string, ns: f64) {
	numbers := make([dynamic]f64, context.temp_allocator)
	for a in answers { if v, ok := strconv.parse_f64(a); ok { append(&numbers, v) } }
	if len(numbers) > 0 {
		ns = median(numbers[:])
		return fmt.tprintf("%s ns", figure(ns, 1)), ns
	}
	return len(answers) > 0 ? answers[0] : "n/a", 0
}

@(private = "file")
wasm_call_floor :: proc() -> (ns: string, has: bool) {
	build := []string{tooling.odin_program(), "build", "examples/wasmbench", "-target:freestanding_wasm32", "-no-entry-point", "-default-to-nil-allocator", "-collection:wren=sdk/odin", fmt.tprintf("-out:%s", WASMBENCH_WASM), "-o:speed"}
	if tooling.run({command = build}) != 0 { return }
	exe, good := build_tool("wasmbench")
	if !good { return }
	text, _ := run_text({exe, WASMBENCH_WASM})
	for line in strings.split_lines(text, context.temp_allocator) {
		if !strings.contains(line, WASMBENCH_ROW) { continue }
		cells := strings.split(line, "|", context.temp_allocator)
		if len(cells) > 2 { return strings.trim_space(cells[2]), true }
	}
	return
}

////////////////////////////////
// Realm start-up and memory

Startup_Stat :: struct { name, label, unit: string }

STARTUP_STATS := []Startup_Stat{
	{"first_script_ms", "first page of the process: from the navigation to its first script's output (fetch, parse, realm created on first use, engine code compiled or read from the cache)", "ms"},
	{"next_page_first_script_ms", "next page: the same", "ms"},
	{"js_heap_kib", "page: JavaScript heap after a small script", "KiB"},
	{"private_per_page_kib", "page: private memory per page with a realm (20 pages alive)", "KiB"},
}

js_startup :: proc(o: ^Options) -> int {
	_ = tooling.build_js_engine({})
	engine, good := build_tool("jsengine")
	if !good { fmt.eprintln("building src/tools/jsengine failed"); return 1 }
	r := report_begin("js_startup", "measure", "value")
	text, _ := run_text({engine, "startup", "-n", STARTUP_REALMS})
	tooling.append_text(OUT_DIR + "/startup.log", fmt.tprintfln("startup\n%s", text))
	for line in strings.split_lines(text, context.temp_allocator) {
		n := numbers_in(line)
		switch {
		case strings.has_prefix(line, "first realm") && len(n) >= 1:
			report_row(&r, "first realm of the process (compiles or reads the code cache)", fmt.tprintf("%s ms", figure(n[0], 2)))
		case strings.has_prefix(line, "realm creation:") && len(n) >= 4:
			report_row(&r, fmt.tprintf("realm creation (instantiate the pre-initialized image + wj_realm_start), median of %d", int(n[3])), fmt.tprintf("%s ms (min %s, max %s)", figure(n[0], 3), figure(n[1], 3), figure(n[2], 3)))
		case strings.has_prefix(line, "private memory per realm:") && len(n) >= 2:
			report_row(&r, fmt.tprintf("private memory per realm (process, %s realms alive)", STARTUP_REALMS), fmt.tprintf("%s KiB", figure(n[0], 0)))
			report_row(&r, "JavaScript heap of a fresh realm", fmt.tprintf("%s KiB", figure(n[1], 0)))
		}
	}
	raw, _ := run_text({engine, "startup", "-raw", "-n", STARTUP_RAW_REALMS})
	tooling.append_text(OUT_DIR + "/startup.log", fmt.tprintfln("startup -raw\n%s", raw))
	for line in strings.split_lines(raw, context.temp_allocator) {
		n := numbers_in(line)
		if strings.has_prefix(line, "realm creation:") && len(n) >= 1 { report_row(&r, "realm creation without the pre-initialized image (-raw: the engine's start-up runs per realm)", fmt.tprintf("%s ms", figure(n[0], 3))) }
	}
	if jspage, built := build_tool("jspage"); built {
		page, _ := run_text({jspage, "-wait", STARTUP_WAIT_MS, "-until", DOM_DONE, "-stats", file_url(STARTUP_PAGE)})
		tooling.append_text(OUT_DIR + "/startup.log", fmt.tprintfln("jspage -stats\n%s", page))
		for line in strings.split_lines(page, context.temp_allocator) {
			fields := strings.split(strings.trim_right(line, "\r"), "\t", context.temp_allocator)
			if len(fields) < 3 || fields[0] != "STAT" { continue }
			for s in STARTUP_STATS { if s.name == fields[1] { report_row(&r, s.label, fmt.tprintf("%s %s", fields[2], s.unit)) } }
		}
	}
	report_end(&r, o)
	return 0
}
