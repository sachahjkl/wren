// jspage: one page in Wren without a window (src/tools/headless): the document loaded as the browser loads it, its
// scripts run, its console on stdout. For the measuring scripts: the DOM micro-benchmarks (tools\js_bench.ps1 -Mode dom),
// the JavaScript errors of real sites (tools\compat_sweep.ps1), start-up and memory of a page (-stats).
//   jspage [-wait ms] [-until text] [-stats [-allocs]] [-pages n] [-init code] [-eval code] [-viewport WxH] [-image engine.wasm] [-profile out.json] [--pref name=value]... <url>
// Console lines: a log as it is, "warn: " / "error: " before the others. -until stops at the first console message that
// starts with `text` (else at -wait, 10 s by default). The exit status is 0 when the page loaded (and -until was seen),
// 1 otherwise. -stats then prints "STAT<TAB>name<TAB>value" lines:
//   first_script_ms        from the navigation to the first console message (fetch, parse, realm creation, script):
//                          the first page of the process (the engine's code is compiled, or read from the disk cache)
//   next_page_first_script_ms  the same for the next page
//   js_heap_kib            the realm's JavaScript heap at that point
//   js_memory_kib          the realm's linear memory (the engine's whole address space: heap, free space, stack)
//   private_per_page_kib   private memory per page, -pages more pages (20) open at once, each with its realm
// -eval runs code in the page once -wait is over (diagnostics: console.log what you want to know).
// -allocs (with -stats): then the live allocations of the window thread (Odin's context allocator) at that point,
// summed by the source line that made them: ALLOC<TAB>kib<TAB>count<TAB>file:line, the largest 30.
package jspage

import "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:os"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "wb:config"
import "wb:cookies"
import "wb:js"
import lay "wb:layout"
import "wb:page"
import "wb:tools/headless"
import "wb:tools/testenv"
import "wb:url"
import "wb:wasm"

until_text: string
wasm_cache_dir: string
hang_ms: int
hang_thread: win.HANDLE
profile_path: string        // -profile: a sampling profile of the page's engine (tools\wasm_profile.ps1)
profiled: ^wasm.Instance
seen_until: bool
allocs: bool
eval_code: string   // -eval: a script run in the page after -wait (its console.log lines are printed)
init_code: string   // -init: a script run in each realm before the page's own (to watch what they do)
viewport: [2]f64    // -viewport WxH: the size scripts see (innerWidth...); nothing is laid out
first_message_ms: f64 = -1
quiet: bool
started: time.Tick

on_console :: proc(d: ^headless.Doc, level: page.Log_Level, text: string) {
	if first_message_ms < 0 { first_message_ms = time.duration_milliseconds(time.tick_since(started)) }
	if until_text != "" && strings.has_prefix(text, until_text) { seen_until = true }
	if quiet { return }
	switch level {
	case .Log: fmt.println(text)
	case .Warn: fmt.printfln("warn: %s", text)
	case .Error: fmt.printfln("error: %s", text)
	}
}

done :: proc(d: ^headless.Doc) -> bool {
	if d.failed != "" { return true }
	return until_text != "" ? seen_until : false
}

foreign import psapi "system:Psapi.lib"
PROCESS_MEMORY_COUNTERS_EX :: struct {
	cb: u32, PageFaultCount: u32,
	PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage: uint,
	QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage, PrivateUsage: uint,
}
@(default_calling_convention = "system")
foreign psapi {
	GetProcessMemoryInfo :: proc(process: win.HANDLE, counters: ^PROCESS_MEMORY_COUNTERS_EX, cb: u32) -> win.BOOL ---
}

private_bytes :: proc() -> int {
	c: PROCESS_MEMORY_COUNTERS_EX
	c.cb = size_of(c)
	GetProcessMemoryInfo(win.GetCurrentProcess(), &c, c.cb)
	return int(c.PrivateUsage)
}

usage :: proc() -> ! {
	fmt.eprintln("usage: jspage [-wait ms] [-until text] [-stats [-allocs]] [-pages n] [-init code] [-eval code] [-viewport WxH] [-image engine.wasm] [-profile out.json] [-wasm-cache dir] [-cookie 'name=value; ...']... [--pref name=value]... <url>")
	os.exit(2)
}

main :: proc() {
	wait_ms := 10_000
	stats := false
	pages := 20
	url := ""
	pref_args := make([dynamic]string)
	cookie_args := make([dynamic]string)
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		need :: proc(args: []string, i: ^int) -> string { i^ += 1; if i^ >= len(args) { usage() }; return args[i^] }
		switch args[i] {
		case "-wait": wait_ms = parse_int(need(args, &i))
		case "-until": until_text = need(args, &i)
		case "-stats": stats = true
		case "-pages": pages = max(1, parse_int(need(args, &i)))
		case "--pref": append(&pref_args, "--pref", need(args, &i))
		case "-image":
			data, err := os.read_entire_file(need(args, &i), context.allocator)
			if err != nil { fmt.eprintln("jspage: cannot read the image"); os.exit(2) }
			page.js_image_override = data
		case "-profile": profile_path = need(args, &i)
		case "-cookie": append(&cookie_args, need(args, &i))
		case "-wasm-cache": wasm_cache_dir = need(args, &i)
		case "-allocs": allocs = true
		case "-eval": eval_code = need(args, &i)
		case "-init": init_code = need(args, &i)
		case "-viewport":
			v := need(args, &i)
			x := strings.index_byte(v, 'x')
			if x < 0 { usage() }
			viewport = {f64(parse_int(v[:x])), f64(parse_int(v[x + 1:]))}
		case:
			if strings.has_prefix(args[i], "-") || url != "" { usage() }
			url = args[i]
		}
	}
	if url == "" { usage() }
	// -allocs: what the window thread's allocations hold, by the line that made them (other threads use their own)
	tracker: mem.Tracking_Allocator
	if allocs {
		mem.tracking_allocator_init(&tracker, context.allocator)
		context.allocator = mem.tracking_allocator(&tracker)
	}
	prefs := config.prefs_make()
	page.register_prefs(&prefs)
	_, errs := config.apply_args(&prefs, pref_args[:])
	for e in errs { fmt.eprintln("jspage:", e) }
	// -wasm-cache dir: the authenticated disk cache of compiled modules (the engine, the JIT's functions) in dir, as a
	// browser profile has it: a second run compiles nothing it compiled before
	wasm.configure_from_args(pref_args[:], wasm_cache_dir)
	env: headless.Env
	if !headless.init(&env, &prefs, "build/jspage_profile") { fmt.eprintln("jspage: the page stack could not start"); os.exit(2) }
	js.cache_start({memory_bytes = 16 << 20, min_source_bytes = 0})
	// -cookie "name=value; Domain=.example.com; Path=/; Secure": a Set-Cookie of the page's site, stored before the load
	// (a consent cookie that keeps a site from redirecting to its consent page)
	if len(cookie_args) > 0 {
		if u, ok := url_parse(url); ok {
			for c in cookie_args {
				res := cookies.store(&env.profile.jar, c, cookies.Context{url = u, http_api = true, now_ms = cookies.now_ms()})
				if res != .Stored && res != .Replaced { fmt.eprintfln("jspage: cookie %q: %v", c, res) }
			}
		}
	}

	if init_code != "" || viewport != {} {
		page.js_on_realm_started = proc(p: ^page.Page) {
			if viewport != {} {
				page.set_layout_embedder(p, {
					update = proc(user: rawptr, p: ^page.Page) -> ^lay.Layout { return nil },
					viewport = proc(user: rawptr, p: ^page.Page) -> page.Viewport { return {width = viewport[0], height = viewport[1], scale = 1} },
				})
			}
			if init_code != "" { page.js_run(p, transmute([]byte)init_code, "jspage:init") }
		}
	}
	if profile_path != "" {
		page.js_on_realm = proc(p: ^page.Page, inst: ^wasm.Instance) {
			if profiled == nil && wasm.profile_start(inst, page.js_engine_image()) { profiled = inst }
		}
	}
	// WREN_HANG_DUMP_MS=n: the interface thread's stack after n ms, and every n ms after (finding where a page hangs)
	if v := os.get_env("WREN_HANG_DUMP_MS", context.temp_allocator); v != "" {
		hang_ms = parse_int(v)
		hang_thread = win.OpenThread(win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT, false, win.GetCurrentThreadId())
		win.CreateThread(nil, 0, proc "system" (data: rawptr) -> win.DWORD {
			context = testenv.context_of_process()
			for { win.Sleep(win.DWORD(hang_ms)); crashtrace.dump_thread(hang_thread, "the interface thread") }
		}, nil, 0, nil)
	}
	started = time.tick_now()
	d := headless.open(&env, url, on_console)
	headless.pump(d, f64(wait_ms), done)
	if eval_code != "" && d.page != nil && d.failed == "" {
		page.js_run(d.page, transmute([]byte)eval_code, "jspage:eval")
		headless.pump(d, 2000, nil)   // what it starts (timers, animation frames) has two seconds
		for n in d.navigations { fmt.printfln("NAVIGATE\t%s", n) }   // what the page asked for (not followed)
	}
	if profiled != nil {
		if err := wasm.profile_finish(profiled, profile_path); err != "" { fmt.eprintln("jspage: profile:", err) }
	}
	status := 0
	if d.failed != "" { fmt.eprintfln("jspage: %s: %s", url, d.failed); status = 1 }
	if until_text != "" && !seen_until { fmt.eprintfln("jspage: %q not seen in %d ms", until_text, wait_ms); status = 1 }
	if stats {
		fmt.printfln("STAT\tfirst_script_ms\t%.2f", first_message_ms)
		if d.page != nil && d.page.js != nil && d.page.js.inst != nil {
			fmt.printfln("STAT\tjs_heap_kib\t%.0f", js.heap_bytes(d.page.js.inst) / 1024)
			fmt.printfln("STAT\tjs_memory_kib\t%d", wasm.memory_bytes(d.page.js.inst) / 1024)
		}
		if d.page != nil {
			// what a window's first paint would still wait for (render_blocking.odin)
			st, why := page.first_paint_state(d.page)
			fmt.printfln("STAT\tfirst_paint\t%v %s", st, why)
		}
		if d.page != nil && d.page.engine != nil {
			// the style system's memory: parsed sheets, compiled rules, computed styles
			e := d.page.engine
			parsed, n := uint(0), 0
			for s in e.sheets { if s.sheet != nil { parsed += s.sheet.arena.total_used; n += 1 } }
			fmt.printfln("STAT\tstyle_sheets\t%d", n)
			fmt.printfln("STAT\tstyle_parsed_kib\t%d", parsed / 1024)
			fmt.printfln("STAT\tstyle_rules_kib\t%d", e.arena.total_used / 1024)
			if st := d.page.styled; st != nil {
				used := st.arena.total_used
				for ta in st.thread_arenas { used += ta.total_used }
				fmt.printfln("STAT\tstyle_computed_kib\t%d", used / 1024)
			}
		}
		// many pages at once: what one more page with a realm costs; the first of them is a page of a process whose
		// engine code is compiled already (the usual case)
		quiet = true
		before := private_bytes()
		more := make([dynamic]^headless.Doc)
		for i in 0 ..< pages {
			seen_until = false
			first_message_ms = -1
			started = time.tick_now()
			m := headless.open(&env, url, on_console)
			headless.pump(m, f64(wait_ms), done)
			if i == 0 { fmt.printfln("STAT\tnext_page_first_script_ms\t%.2f", first_message_ms) }
			append(&more, m)
		}
		after := private_bytes()
		fmt.printfln("STAT\tprivate_per_page_kib\t%.0f", f64(after - before) / f64(pages) / 1024)
		if allocs { alloc_report(&tracker) }
		for m in more { headless.close(m) }
	}
	headless.close(d)
	headless.destroy(&env)
	js.cache_stop()
	os.exit(status)
}

url_parse :: proc(s: string) -> (url.URL, bool) {
	return url.parse_absolute(s, context.temp_allocator)
}

parse_int :: proc(s: string) -> int {
	v := 0
	for c in s { if c >= '0' && c <= '9' { v = v * 10 + int(c - '0') } }
	return v
}

alloc_report :: proc(t: ^mem.Tracking_Allocator) {
	Site :: struct { loc: string, bytes: int, count: int }
	sites := make(map[string]Site, allocator = context.temp_allocator)
	for _, e in t.allocation_map {
		key := fmt.tprintf("%s:%d", e.location.file_path, e.location.line)
		s := sites[key]
		s.loc = key
		s.bytes += e.size
		s.count += 1
		sites[key] = s
	}
	list := make([dynamic]Site, 0, len(sites), context.temp_allocator)
	total := 0
	for _, s in sites { append(&list, s); total += s.bytes }
	slice.sort_by(list[:], proc(a, b: Site) -> bool { return a.bytes > b.bytes })
	fmt.printfln("ALLOC\t%d\t%d\ttotal", total / 1024, len(t.allocation_map))
	for s, i in list {
		if i >= 30 { break }
		fmt.printfln("ALLOC\t%d\t%d\t%s", s.bytes / 1024, s.count, s.loc)
	}
}