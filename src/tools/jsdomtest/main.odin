// Headless end-to-end test of the DOM for JavaScript: every page of examples/jsdom runs in a page of its own, its
// checks report through the console (harness.js: "PASS name" / "FAIL name: why", "DONE" at the end), and this tool
// counts them. The pages are laid out by a layout embedder of this tool (page.set_layout_embedder) with fixed text
// metrics (every character 0.5 em wide), so geometry can be checked exactly. Then the checks that need the browser's
// side: nodes freed after a collection, the cost of layout readings, and the micro-benchmarks (bench.html reports
// "BENCH name ns"). No server, no window. Run from the repository root:
//   jsdomtest.exe [page.html...]
package jsdomtest

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:js"
import lay "wb:layout"
import "wb:net"
import "wb:page"
import "wb:wasm"
import "wb:tools/testenv"

PAGES_DIR :: "examples/jsdom"
VIEW_W :: 800
VIEW_H :: 600

failures: int
passes: int
logs: [dynamic]string
benches: [dynamic]string

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { passes += 1; fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

console :: proc(user: rawptr, level: page.Log_Level, message: string) {
	append(&logs, strings.clone(message))
	if level != .Log || !(strings.has_prefix(message, "PASS ") || strings.has_prefix(message, "BENCH ")) {
		fmt.printf("  [%v] %s\n", level, message)
	}
}

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings

// The layout embedder: the page's styles and a layout of the test viewport with fixed text metrics.
Layout_Host :: struct {
	l:        lay.Layout,
	set:      lay.Settings,
	scroll:   [2]f64,
}

fake_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> lay.Font { return lay.Font(1) }
fake_width :: proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(strings.rune_count(text)) }
fake_metrics :: proc(user: rawptr, f: lay.Font, size: f32) -> lay.Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

layout_update :: proc(user: rawptr, p: ^page.Page) -> ^lay.Layout {
	lh := (^Layout_Host)(user)
	st := page.styles(p, VIEW_W, VIEW_H, 1)
	lay.run(&lh.l, lay.Input{doc = p.doc, styled = st, settings = &lh.set, text = {font = fake_font, width = fake_width, metrics = fake_metrics}, viewport = {VIEW_W, VIEW_H}, scale = 1, band_h = 256})
	return &lh.l
}

layout_viewport :: proc(user: rawptr, p: ^page.Page) -> page.Viewport {
	lh := (^Layout_Host)(user)
	return page.Viewport{width = VIEW_W, height = VIEW_H, scale = 1, scroll_x = lh.scroll[0], scroll_y = lh.scroll[1]}
}

layout_scroll :: proc(user: rawptr, p: ^page.Page, x, y: f64, smooth: bool) {
	lh := (^Layout_Host)(user)
	max_y := max(0, f64(lh.l.height) - VIEW_H)
	lh.scroll = {0, clamp(y, 0, max_y)}
	_ = x
}

logged :: proc(text: string) -> bool {
	for l in logs { if l == text { return true } }
	return false
}

harness: string

// Loads a page with the harness and the layout embedder, runs its scripts, waits for "DONE" (the timeout only ends a
// page that fails: nothing checked depends on the machine's speed).
open_page :: proc(process: ^base.Scope, source: string, lh: ^Layout_Host, name: string, timeout_ms := 5000) -> ^page.Page {
	for l in logs { delete(l) }
	clear(&logs)
	p := page.page_create(&loop, &loader, &settings, process, fmt.tprintf("http://127.0.0.1:8765/jsdom/%s", name), console)
	page.set_layout_embedder(p, {user = lh, update = layout_update, viewport = layout_viewport, scroll_to = layout_scroll})
	page.load_html(p, transmute([]byte)source)
	page.js_run(p, transmute([]byte)harness, "harness.js")
	page.scripts_start(p)
	start := time.tick_now()
	for !logged("DONE") && time.duration_milliseconds(time.tick_since(start)) < f64(timeout_ms) {
		// rendering updates, as the shell runs them: animation frame callbacks, then intersection observations
		if page.wants_animation_frame(p) { page.run_animation_frames(p, f64(host.now_ns(&loop)) / 1e6) }
		host.loop_wait(&loop, 2)
	}
	return p
}

// Counts the page's PASS / FAIL lines.
report_page :: proc(name: string) {
	pass, fail := 0, 0
	for l in logs {
		switch {
		case strings.has_prefix(l, "PASS "): pass += 1
		case strings.has_prefix(l, "FAIL "): fail += 1; fmt.printf("FAIL %s: %s\n", name, l[5:])
		case strings.has_prefix(l, "Uncaught"): fail += 1; fmt.printf("FAIL %s: %s\n", name, l)
		case strings.has_prefix(l, "BENCH "): append(&benches, strings.clone(l[6:]))
		}
	}
	passes += pass
	failures += fail
	if !logged("DONE") { fmt.printf("FAIL %s: did not finish (no DONE)\n", name); failures += 1 }
	fmt.printf("%s %s: %d checks passed, %d failed\n", fail == 0 && logged("DONE") ? "PASS" : "FAIL", name, pass, fail)
}

main :: proc() {
	context = testenv.context_of_process()
	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	wasm.configure_from_args(os.args[1:])
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }
	js.cache_start({memory_bytes = 16 << 20, min_source_bytes = 0})
	process := base.scope_make("process")

	h, herr := os.read_entire_file(filepath.join({PAGES_DIR, "harness.js"}, context.temp_allocator) or_else "", context.allocator)
	if herr != nil { fmt.eprintln("cannot read examples/jsdom/harness.js (run from the repository root)"); os.exit(2) }
	harness = string(h)

	// the pages named on the command line, or every page of the folder
	names := make([dynamic]string)
	for a in os.args[1:] { if strings.has_suffix(a, ".html") { append(&names, strings.clone(filepath.base(a))) } }
	if len(names) == 0 {
		infos, err := os.read_all_directory_by_path(PAGES_DIR, context.allocator)
		if err != nil { fmt.eprintln("cannot read", PAGES_DIR); os.exit(2) }
		for fi in infos { if strings.has_suffix(fi.name, ".html") && fi.name != "bench.html" && fi.name != "leaks.html" { append(&names, strings.clone(fi.name)) } }
		os.file_info_slice_delete(infos, context.allocator)
		slice.sort(names[:])
		append(&names, strings.clone("leaks.html"), strings.clone("bench.html"))
	}

	for name in names {
		fmt.printf("-- %s\n", name)
		src, rerr := os.read_entire_file(filepath.join({PAGES_DIR, name}, context.temp_allocator) or_else "", context.allocator)
		if rerr != nil { fmt.printf("FAIL cannot read %s\n", name); failures += 1; continue }
		lh := new(Layout_Host)
		lh.set = lay.settings_default()
		t0 := time.tick_now()
		p := open_page(process, string(src), lh, name, name == "bench.html" ? 600_000 : 120_000)
		ms := time.duration_milliseconds(time.tick_since(t0))
		report_page(name)
		switch name {
		case "leaks.html": leak_checks(p)
		case "layout.html": layout_cost_checks(p)
		case "events.html": browser_event_checks(p)
		}
		fmt.printf("  (%.0f ms)\n", ms)
		page.page_close(p)
		lay.destroy(&lh.l)
		free(lh)
		delete(src)
	}

	if len(benches) > 0 {
		fmt.println("-- micro-benchmarks (ns per operation)")
		for b in benches { fmt.printf("  %s\n", b) }
	}
	base.scope_close(process)
	host.blocking_settle(&blocking)
	page.process_shutdown()
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	host.loop_destroy(&loop)
	page.settings_destroy(&settings)
	for s in names { delete(s) }
	delete(names)
	for s in logs { delete(s) }
	delete(logs)
	for s in benches { delete(s) }
	delete(benches)
	delete(h)
	failures += testenv.mem_check("jsdomtest")
	fmt.printf("\n%d checks passed, %d failure(s)\n", passes, failures)
	os.exit(failures > 0 ? 1 : 0)
}

// leaks.html made many detached nodes, observers, lists and wrappers and dropped them: after a collection the
// browser's side must be back near where it started.
leak_checks :: proc(p: ^page.Page) {
	before := p.doc.nodes.count
	js.collect(p.js.inst)
	js.collect(p.js.inst)
	after := p.doc.nodes.count
	fmt.printf("  nodes before collection %d, after %d\n", before, after)
	// (collections also run while the page makes them: `before` is only informative)
	check(after < 500, "detached nodes, records and lists are freed once their wrappers are collected")
	objects := p.objects.pool.count
	fmt.printf("  host objects after collection %d\n", objects)
	check(objects < 50, "live collections and observers release their host objects with their wrappers")
	pinned := 0
	it: u32
	for _, n in base.pool_next(&p.doc.nodes, &it) { pinned += int(n.pins) }
	page.js_run(p, transmute([]byte)string(`console.log("kept " + window.keep.childNodes.length + " " + window.keepList.length)`), "probe.js")
	check(logged("kept 3 2"), "what JavaScript still references stays whole")
	_ = dom.NS_HTML
	_ = pinned
}

// Runs `probe` in the page and counts the harness's verdicts it logs.
probe_checks :: proc(p: ^page.Page, probe: string, what: string) {
	from := len(logs)
	page.js_run(p, transmute([]byte)probe, "probe.js")
	pass, fail := 0, 0
	for l in logs[from:] {
		if strings.has_prefix(l, "PASS ") { pass += 1 }
		if strings.has_prefix(l, "FAIL ") || strings.has_prefix(l, "Uncaught") { fail += 1; fmt.printf("FAIL %s: %s\n", what, l) }
	}
	passes += pass
	failures += fail
	if pass + fail == 0 { fmt.printf("FAIL %s: the probe reported nothing\n", what); failures += 1 }
}

// Events the browser dispatches (as the shell does from the mouse and the keyboard): trusted, with their details,
// readable after the dispatch, through the Window.
browser_event_checks :: proc(p: ^page.Page) {
	b := dom.find_by_id(p.doc, "b")
	page.dispatch_event(p, b, dom.Event{type = "click", bubbles = true, cancelable = true, x = 15, y = 30, button = 0, mods = dom.MOD_CTRL})
	page.dispatch_event(p, p.body, dom.Event{type = "keydown", bubbles = true, cancelable = true, key = 65, text = "A", mods = dom.MOD_SHIFT})
	probe_checks(p, `
const b = document.getElementById("b"), r = b.getBoundingClientRect();
const offx = 15 - r.left - b.clientLeft, offy = 30 - r.top - b.clientTop;
eq("a browser click: trusted MouseEvent with its details", window.seen.click, ["true,true,15,30,15", offx, offy, "0,0,true,1,true"].join(","));
eq("its details stay readable after the dispatch", window.seen.clickEvent.clientX + "," + window.seen.clickEvent.target.id, "15,b");
eq("a browser keydown reaches the window: key, code, keyCode", window.seen.key, "true,A,KeyA,65,65,true");
`, "browser events")
}

// Repeated readings of layout without mutations in between must not lay the page out again.
layout_cost_checks :: proc(p: ^page.Page) {
	n0 := page.layout_updates(p)
	page.js_run(p, transmute([]byte)string(`
const el = document.getElementById("box");
let s = 0;
for (let i = 0; i < 2000; i++) { s += el.offsetWidth + el.getBoundingClientRect().height; }
console.log("reads " + s);`), "probe.js")
	n1 := page.layout_updates(p)
	fmt.printf("  layout updates for 4000 readings without mutation: %d\n", n1 - n0)
	check(n1 - n0 <= 1, "readings without mutation reuse the layout")
	page.js_run(p, transmute([]byte)string(`
const e2 = document.getElementById("box");
for (let i = 0; i < 50; i++) { e2.style.width = (100 + i) + "px"; void e2.offsetWidth; }`), "probe.js")
	n2 := page.layout_updates(p)
	fmt.printf("  layout updates for 50 mutations each followed by a reading: %d\n", n2 - n1)
	check(n2 - n1 == 50, "a reading after a mutation brings the layout up to date")
}
