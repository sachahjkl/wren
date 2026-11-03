// endurance: the long-run memory test of the browser: tabs opened and closed by the hundred, pages navigated by the hundred (JavaScript, images, forms, animations, the back/forward cache, the HTTP cache), with
// the memory measured after every cycle: the tracker's live bytes (every Odin allocation, src/base/memory.odin), the process's private bytes and working set (the native libraries, Direct3D, DirectWrite, the arenas),
// its kernel, GDI and USER handles. Fails when, once the caches have filled (the first -warmup cycles), any of them still grows by more than its threshold, or when anything is left allocated at exit. A leak at
// exit is the check build's report; a growth here is memory that is freed at exit but not while the browser runs (a cache without a bound, a map never purged, a handle per page).
//   build/endurance [-cycles 40] [-tabs 10] [-warmup 20] [-no-native] [-out build/endurance] [-exe build/wren_check.exe] [-idle-ms 6500] [-timeout s] [--pref name=value]...
// After the last cycle the browser is left alone for -idle-ms (0: skipped): the "idle" row of the statistics is what it keeps once it has trimmed (browser.memory.trim_idle_ms, 5 s by default).
// Default: 400 tabs, 1 200 page loads and 800 back/forward steps; the native memory (Direct3D, the drivers, Wasmtime, the heap's own pages) settles after about 200 tabs, hence the long warm-up; the tracked memory
// and the handles are flat after the first cycles (a short run with -no-native checks them: test_all -CI). The native memory is compared by its highest value over 5 cycles (it drops when caches trim: every ~100
// tabs), the tracked bytes by their median. Writes <out>/stats.csv (one line per cycle), <out>/endurance.svg (the curves) and the places whose blocks grew after the warm-up (base.mem_snapshot). The check build drives
// itself (WREN_MEMCHECK_SCRIPT, src/browser/memcheck.odin). Build it first: test_all's step does, `build.bat check` by hand.
package endurance

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:testserver"
import "wb:tools/tooling"

Options :: struct {
	cycles, tabs, warmup, idle_ms, timeout_seconds: int,
	no_native: bool,
	out, exe:  string,
	prefs:     [dynamic]string,
}

CYCLES_DEFAULT :: 40
TABS_DEFAULT :: 10
WARMUP_DEFAULT :: 20
IDLE_MS_DEFAULT :: 6500
TIMEOUT_DEFAULT :: 3600
BYTES_PER_MB :: 1048576.0
GROWTH_LIVE_MB :: 0.5
GROWTH_PRIVATE_MB :: 64
GROWTH_HANDLES :: 100
GROWTH_GDI :: 30
GROWTH_USER :: 20
WINDOW_MOST :: 5
// Cycles after the warm-up, at least, for a comparison to mean something.
CYCLES_AFTER_WARMUP :: 4
// What of the check build's report is shown.
REPORT_LINES :: 80
GREW_SHOWN :: 25
GREW_MIN_BYTES :: 4096
CHECK_LEFT_ALLOCATED :: 3
FRAMES_AFTER_LOAD :: 3
FRAMES_AFTER_CLOSE :: 10
WAIT_AFTER_CLOSE_MS :: 200
PAGES := []string{"js.html", "images.html", "forms.html", "js-dom.html", "animations.html", "mutation.html", "shadow-dom.html", "layout.html", "media.html", "style.html", "text.html", "grid.html", "effects.html", "modern-css.html", "transforms.html", "interaction.html"}
// The third and second page of a tab, further on the list.
SECOND_PAGE_AFTER :: 5
THIRD_PAGE_AFTER :: 11
SVG_WIDTH :: 900
SVG_HEIGHT :: 360
SVG_PAD_LEFT :: 50
SVG_PAD_BOTTOM :: 30
SVG_PAD_RIGHT :: 10
SVG_PAD_TOP :: 30
SVG_RANGE_MIN_SHARE :: 0.05

usage :: proc() -> ! {
	fmt.eprintln("usage: endurance [-cycles n] [-tabs n] [-warmup n] [-no-native] [-out dir] [-exe program] [-idle-ms n] [-timeout s] [--pref name=value]...")
	os.exit(2)
}

// The script of a session: {o} is the test server's origin.
session_script :: proc(o: ^Options, origin: string) -> string {
	b := strings.builder_make()
	fmt.sbprintln(&b, "load\nstats start")
	k := 0
	for c in 1 ..= o.cycles {
		for _ in 0 ..< o.tabs {
			first := PAGES[k % len(PAGES)]
			second := PAGES[(k + SECOND_PAGE_AFTER) % len(PAGES)]
			third := PAGES[(k + THIRD_PAGE_AFTER) % len(PAGES)]
			k += 1
			fmt.sbprintfln(&b, "open %s/site/%s\nload", origin, first)
			fmt.sbprintfln(&b, "go %s/site/%s\nload", origin, second)
			fmt.sbprintfln(&b, "go %s/site/%s\nload\nframes %d", origin, third, FRAMES_AFTER_LOAD)
			fmt.sbprintln(&b, "command nav.back\nload")   // the back/forward cache
			fmt.sbprintfln(&b, "command nav.forward\nload\nframes %d", FRAMES_AFTER_LOAD)
		}
		for _ in 0 ..< o.tabs { fmt.sbprintln(&b, "command tab.close") }
		fmt.sbprintfln(&b, "frames %d\nwait %d\nstats cycle%d", FRAMES_AFTER_CLOSE, WAIT_AFTER_CLOSE_MS, c)
		if c == o.warmup || c == o.cycles { fmt.sbprintfln(&b, "snapshot %s/snapshot_%d.txt", o.out, c) }
		if c == 1 || c == o.cycles { fmt.sbprintfln(&b, "vmmap %s/vmmap_%d.txt", o.out, c) }   // the biggest private allocations (memory_map_report)
	}
	// left alone: the browser gives memory back (browser.memory.trim_idle_ms, memory_trim.odin); the row "idle" is what stays
	if o.idle_ms > 0 { fmt.sbprintfln(&b, "idle %d\nframes 2\nstats idle", o.idle_ms) }
	fmt.sbprintln(&b, "quit")
	return strings.to_string(b)
}

// Runs the check build on the script with a fresh profile: its exit code.
run_session :: proc(o: ^Options, stats: string) -> int {
	NAME :: "endurance"
	dir := fmt.tprintf("%s/%s", o.out, NAME)
	profile := fmt.tprintf("%s/profile", dir)
	_ = os.remove_all(profile)
	_ = os.make_directory_all(profile)
	base, why := testserver.start()
	if base == 0 { fmt.printfln("FAIL the test server: %s", why); return 1 }
	origin := fmt.tprintf("http://127.0.0.1:%d", base)
	script := fmt.tprintf("%s/session.txt", dir)
	if os.write_entire_file(script, session_script(o, origin)) != nil { fmt.printfln("FAIL cannot write %s", script); return 1 }
	command := make([dynamic]string, context.temp_allocator)
	// (no download of the blocker's lists in a session of the check build: one still in flight when the browser exits, or an engine being built from it, is memory left allocated at the exit test, which then depends on
	// how fast the network of the day is. The browsing history is the user's data, kept up to history.global.max_visits: at its least here, so that it is full before the warm-up ends and its growth is not taken for a leak.)
	append(&command, o.exe, "--profile", profile, "--pref", "blocker.update.enabled=false", "--pref", "blocker.welcome_toast=false", "--pref", "history.global.max_visits=10")
	for p in o.prefs { append(&command, "--pref", p) }
	append(&command, fmt.tprintf("%s/site/index.html", origin))
	p, spawn_why := tooling.spawn({command = command[:], env = {fmt.tprintf("WREN_MEMCHECK_SCRIPT=%s", script), "WREN_MEMTRACK_FAIL=1", fmt.tprintf("WREN_MEMCHECK_STATS=%s", stats)}})
	if spawn_why != "" { fmt.printfln("FAIL %s cannot start: %s", o.exe, spawn_why); return 1 }
	code, timed_out := tooling.wait(&p, time.Duration(o.timeout_seconds) * time.Second)
	tooling.release(&p)
	if timed_out { fmt.printfln("FAIL %s: the session did not end in %d s", NAME, o.timeout_seconds); return 1 }
	report := fmt.tprintf("%s/memtrack.txt", profile)
	if data, err := os.read_entire_file(report, context.temp_allocator); err == nil {
		lines := strings.split_lines(string(data), context.temp_allocator)
		for l in lines[:min(REPORT_LINES, len(lines))] { fmt.println(l) }
	}
	switch code {
	case 0: fmt.printfln("PASS %s: the check build exits clean (%s)", NAME, report)
	case CHECK_LEFT_ALLOCATED: fmt.printfln("FAIL %s: allocations left at exit (%s)", NAME, report)
	case: fmt.printfln("FAIL %s: the check build ended with code %d", NAME, code)
	}
	return code
}

Row :: map[string]string

read_csv :: proc(path: string) -> (rows: []Row, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return nil, false }
	lines := strings.split_lines(string(data))
	if len(lines) == 0 { return nil, false }
	header := strings.split(strings.trim_right(lines[0], "\r"), ",")
	out: [dynamic]Row
	for raw in lines[1:] {
		line := strings.trim_right(raw, "\r")
		if line == "" { continue }
		r := make(Row)
		for v, i in strings.split(line, ",") { if i < len(header) { r[header[i]] = v } }
		append(&out, r)
	}
	return out[:], true
}

value :: proc(r: Row, column: string) -> f64 {
	v, _ := strconv.parse_f64(r[column])
	return v
}

median :: proc(rows: []Row, column: string) -> f64 {
	v := make([]f64, len(rows), context.temp_allocator)
	for r, i in rows { v[i] = value(r, column) }
	return tooling.median(v)
}

highest :: proc(rows: []Row, column: string) -> f64 {
	most := 0.0
	for r in rows { most = max(most, value(r, column)) }
	return most
}

Growth_Check :: struct {
	name, column: string,
	most, unit:   f64,
	suffix:       string,
	use_median, native: bool,
}

// What grew between the end of the warm-up and the end, by place of allocation.
print_snapshot_growth :: proc(o: ^Options) {
	read_snapshot :: proc(path: string) -> (lines: []string) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil { return nil }
		return strings.split_lines(string(data), context.temp_allocator)
	}
	before := read_snapshot(fmt.tprintf("%s/snapshot_%d.txt", o.out, o.warmup))
	after := read_snapshot(fmt.tprintf("%s/snapshot_%d.txt", o.out, o.cycles))
	if before == nil || after == nil { return }
	Count :: struct { blocks, bytes: i64 }
	Grew :: struct { blocks, bytes: i64, place: string }
	old := make(map[string]Count, 256, context.temp_allocator)
	for l in before {
		f := strings.split_n(strings.trim_right(l, "\r"), "\t", 3, context.temp_allocator)
		if len(f) < 3 { continue }
		a, _ := strconv.parse_i64(f[0])
		b, _ := strconv.parse_i64(f[1])
		old[f[2]] = {a, b}
	}
	grew := make([dynamic]Grew, context.temp_allocator)
	for l in after {
		f := strings.split_n(strings.trim_right(l, "\r"), "\t", 3, context.temp_allocator)
		if len(f) < 3 { continue }
		a, _ := strconv.parse_i64(f[0])
		b, _ := strconv.parse_i64(f[1])
		was := old[f[2]]
		if a - was.blocks > 0 || b - was.bytes > GREW_MIN_BYTES { append(&grew, Grew{a - was.blocks, b - was.bytes, f[2]}) }
	}
	if len(grew) == 0 { return }
	slice.sort_by(grew[:], proc(x, y: Grew) -> bool { return x.bytes > y.bytes })
	fmt.println("grew after the warm-up (blocks, bytes, place):")
	for g, i in grew {
		if i >= GREW_SHOWN { break }
		fmt.printfln("  %v %v %s", g.blocks, g.bytes, g.place)
	}
}

// The curves: every series scaled to its own range, one line each.
write_svg :: proc(o: ^Options, rows: []Row) {
	Series :: struct { column, color, name: string, bytes: bool }
	SERIES := []Series{{"live_bytes", "#d33", "tracked live bytes", true}, {"private_bytes", "#36c", "private bytes", true}, {"working_set", "#9a3", "working set", true}, {"handles", "#a5c", "handles", false}, {"gdi", "#e90", "GDI", false}}
	W, H := f64(SVG_WIDTH), f64(SVG_HEIGHT)
	left, bottom := f64(SVG_PAD_LEFT), f64(SVG_PAD_BOTTOM)
	plot := W - left - SVG_PAD_RIGHT
	b := strings.builder_make()
	fmt.sbprintf(&b, "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' font-family='Segoe UI' font-size='12'><rect width='100%%' height='100%%' fill='white'/>", SVG_WIDTH, SVG_HEIGHT)
	fmt.sbprintf(&b, "<line x1='%d' y1='%d' x2='%d' y2='%d' stroke='#888'/><text x='%d' y='%d'>cycle 1</text><text x='%d' y='%d'>cycle %d</text>", SVG_PAD_LEFT, SVG_HEIGHT - SVG_PAD_BOTTOM, SVG_WIDTH - SVG_PAD_RIGHT, SVG_HEIGHT - SVG_PAD_BOTTOM, SVG_PAD_LEFT, SVG_HEIGHT - 8, SVG_WIDTH - 70, SVG_HEIGHT - 8, len(rows))
	x_warm := left + plot * f64(o.warmup) / f64(max(1, len(rows) - 1))
	fmt.sbprintf(&b, "<line x1='%.1f' y1='10' x2='%.1f' y2='%d' stroke='#bbb' stroke-dasharray='4'/><text x='%.1f' y='22' fill='#888'>warm-up</text>", x_warm, x_warm, SVG_HEIGHT - SVG_PAD_BOTTOM, x_warm + 4)
	label_y := 40
	for s in SERIES {
		lowest, most := max(f64), 0.0
		for r in rows { v := value(r, s.column); lowest = min(lowest, v); most = max(most, v) }
		span := max(most - lowest, max(1, most * SVG_RANGE_MIN_SHARE))
		fmt.sbprintf(&b, "<polyline fill='none' stroke='%s' stroke-width='2' points='", s.color)
		for r, i in rows {
			x := left + plot * f64(i) / f64(max(1, len(rows) - 1))
			y := (H - bottom - 10) - (H - bottom - SVG_PAD_TOP) * (value(r, s.column) - lowest) / span
			fmt.sbprintf(&b, "%.1f,%.1f ", x, y)
		}
		strings.write_string(&b, "'/>")
		if s.bytes {
			fmt.sbprintf(&b, "<text x='%d' y='%d' fill='%s'>%s: %.1f - %.1f MB</text>", SVG_WIDTH - 300, label_y, s.color, s.name, lowest / BYTES_PER_MB, most / BYTES_PER_MB)
		} else {
			fmt.sbprintf(&b, "<text x='%d' y='%d' fill='%s'>%s: %.0f - %.0f</text>", SVG_WIDTH - 300, label_y, s.color, s.name, lowest, most)
		}
		label_y += 16
	}
	strings.write_string(&b, "</svg>")
	_ = os.write_entire_file(fmt.tprintf("%s/endurance.svg", o.out), strings.to_string(b))
}

main :: proc() {
	o := Options{cycles = CYCLES_DEFAULT, tabs = TABS_DEFAULT, warmup = WARMUP_DEFAULT, idle_ms = IDLE_MS_DEFAULT, timeout_seconds = TIMEOUT_DEFAULT}
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		need :: proc(args: []string, i: ^int) -> string { i^ += 1; if i^ >= len(args) { usage() }; return args[i^] }
		number :: proc(s: string) -> int { v, ok := strconv.parse_int(s); if !ok { usage() }; return v }
		switch args[i] {
		case "-cycles": o.cycles = number(need(args, &i))
		case "-tabs": o.tabs = number(need(args, &i))
		case "-warmup": o.warmup = number(need(args, &i))
		case "-idle-ms": o.idle_ms = number(need(args, &i))
		case "-timeout": o.timeout_seconds = number(need(args, &i))
		case "-no-native": o.no_native = true
		case "-out": o.out = need(args, &i)
		case "-exe": o.exe = need(args, &i)
		case "--pref": append(&o.prefs, need(args, &i))
		case: usage()
		}
	}
	root := tooling.repo_root()
	if os.set_working_directory(root) != nil { fmt.eprintfln("endurance: cannot work in %s", root); os.exit(2) }
	if o.out == "" { o.out = fmt.aprintf("%s/build/endurance", root) }
	if o.exe == "" { o.exe = fmt.aprintf("build/wren_check%s", tooling.EXE_SUFFIX) }
	_ = os.make_directory_all(fmt.tprintf("%s/endurance", o.out))
	if !tooling.ensure_testserver() { fmt.println("FAIL building the test server"); os.exit(1) }
	stats := fmt.aprintf("%s/stats.csv", o.out)
	_ = os.remove(stats)
	code := run_session(&o, stats)
	all, read_ok := read_csv(stats)
	if !read_ok { fmt.println("FAIL no statistics written"); os.exit(1) }
	rows_list: [dynamic]Row
	for r in all {
		if strings.has_prefix(r["label"], "cycle") { append(&rows_list, r) }
		if r["label"] == "idle" {
			fmt.printfln("after %d ms left alone: private %.1f MB, working set %.1f MB (heap used %.1f MB)", o.idle_ms, value(r, "private_bytes") / BYTES_PER_MB, value(r, "working_set") / BYTES_PER_MB, value(r, "heap_allocated") / BYTES_PER_MB)
		}
	}
	rows := rows_list[:]
	fmt.printfln("cycles measured: %d", len(rows))
	fmt.println("label\tlive MB\tblocks\tprivate MB\tWS MB\thandles\tgdi\tuser\ttabs\theap used\theap committed\tvm rw\tvm exec\twasm modules\tjs bytecode\timages\tfonts")
	for r in rows {
		fmt.printfln("%s\t%.2f\t%s\t%.1f\t%.1f\t%s\t%s\t%s\t%s\t%.1f\t%.1f\t%.1f\t%.1f\t%s\t%s\t%s\t%s", r["label"], value(r, "live_bytes") / BYTES_PER_MB, r["live_blocks"], value(r, "private_bytes") / BYTES_PER_MB, value(r, "working_set") / BYTES_PER_MB, r["handles"], r["gdi"], r["user"], r["tabs"],
			value(r, "heap_allocated") / BYTES_PER_MB, value(r, "heap_committed") / BYTES_PER_MB, value(r, "vm_rw") / BYTES_PER_MB, value(r, "vm_exec") / BYTES_PER_MB, r["wasm_modules"], r["js_entries"], r["img_entries"], r["font_entries"])
	}
	failed := code != 0
	if len(rows) < o.warmup + CYCLES_AFTER_WARMUP { fmt.printfln("FAIL too few cycles after the warm-up (%d)", len(rows)); os.exit(1) }
	window := clamp((len(rows) - o.warmup) / 2, 1, WINDOW_MOST)
	base := rows[o.warmup:o.warmup + window]
	last := rows[len(rows) - window:]
	checks := []Growth_Check{
		{"tracked live bytes", "live_bytes", GROWTH_LIVE_MB * BYTES_PER_MB, BYTES_PER_MB, "MB", true, false},
		{"private bytes", "private_bytes", GROWTH_PRIVATE_MB * BYTES_PER_MB, BYTES_PER_MB, "MB", false, true},
		{"kernel handles", "handles", GROWTH_HANDLES, 1, "", false, false},
		{"GDI objects", "gdi", GROWTH_GDI, 1, "", false, false},
		{"USER objects", "user", GROWTH_USER, 1, "", false, false},
	}
	for c in checks {
		b0 := c.use_median ? median(base, c.column) : highest(base, c.column)
		b1 := c.use_median ? median(last, c.column) : highest(last, c.column)
		growth := b1 - b0
		if c.native && o.no_native {
			fmt.printfln("INFO %s: %.1f MB after the warm-up, %.1f MB at the end (not checked: -no-native)", c.name, b0 / BYTES_PER_MB, b1 / BYTES_PER_MB)
			continue
		}
		good := growth <= c.most
		if !good { failed = true }
		fmt.printfln("%s %s: %.2f%s after the warm-up, %.2f%s at the end (growth %.2f%s, at most %.2f%s)", good ? "PASS" : "FAIL", c.name, b0 / c.unit, c.suffix, b1 / c.unit, c.suffix, growth / c.unit, c.suffix, c.most / c.unit, c.suffix)
	}
	print_snapshot_growth(&o)
	write_svg(&o, rows)
	fmt.printfln("curves: %s/endurance.svg, statistics: %s", o.out, stats)
	fmt.println(failed ? "FAIL endurance" : "PASS endurance")
	os.exit(failed ? 1 : 0)
}
