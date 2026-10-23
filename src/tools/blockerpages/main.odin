// What the content blocker does to real pages: each URL is loaded with and without it (a fresh stack each time, a cold
// HTTP cache, the real network) and the cost of the load is measured: time until the DOM is interactive and until the
// page is complete, requests made, bytes received, DOM nodes, process CPU time and memory.
//   blockerpages.exe -profile <dir with blocker\cache and blocker\lists> [-runs 3] [-timeout 40] [-md out.md] url...
package blockerpages

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "wb:base"
import "wb:blocker"
import "wb:config"
import "wb:fetch"
import "wb:tools/headless"
import "wb:host"
import "wb:page"
import "wb:tools/testenv"

Sample :: struct {
	interactive_ms, complete_ms: f64,
	requests, blocked: int,
	bytes:     i64,
	nodes:     int,
	cpu_ms:    f64,
	mem_mb:    f64,
	failed:    string,
	scripts:   int,
}

Counter :: struct {
	requests, blocked, scripts: int,
	bytes: i64,
}

observe :: proc(user: rawptr, ev: ^fetch.Observed) {
	c := (^Counter)(user)
	#partial switch ev.kind {
	case .Started: c.requests += 1; if ev.destination == .Script { c.scripts += 1 }
	case .Failed: if ev.error == .Blocked_By_Client { c.blocked += 1 }
	case .Done: c.bytes += i64(ev.bytes)
	}
}

proc_cpu_ms :: proc() -> f64 {
	c, e, k, u: win.FILETIME
	win.GetProcessTimes(win.GetCurrentProcess(), &c, &e, &k, &u)
	t := (u64(k.dwHighDateTime) << 32 | u64(k.dwLowDateTime)) + (u64(u.dwHighDateTime) << 32 | u64(u.dwLowDateTime))
	return f64(t) / 10000
}

working_set_mb :: proc() -> f64 {
	c: win.PROCESS_MEMORY_COUNTERS
	c.cb = size_of(c)
	win.GetProcessMemoryInfo(win.GetCurrentProcess(), &c, size_of(c))
	return f64(c.WorkingSetSize) / 1e6
}

measure :: proc(url, profile_dir: string, with_blocker: bool, timeout_s, settle_ms: f64) -> (s: Sample) {
	e: headless.Env
	if !headless.init(&e) { s.failed = "init"; return }
	defer headless.destroy(&e)
	counter: Counter
	e.loader.observer = {user = &counter, event = observe}
	prefs := config.prefs_make()
	defer config.prefs_destroy(&prefs)
	blocker.register_prefs(&prefs)
	b: blocker.Blocker
	if with_blocker {
		blocker.start(&b, &e.loop, &e.client, &e.loader, &prefs, profile_dir)
		blocker.tab_register(&b, 1, e.process)
	}
	mem0 := working_set_mb()
	cpu0 := proc_cpu_ms()
	t0 := time.tick_now()
	d := headless.open(&e, url)
	interactive := false
	until :: proc(d: ^headless.Doc) -> bool { return headless.loaded(d) }
	deadline := time.tick_now()
	_ = deadline
	for {
		headless.pump(d, 20)
		el := f64(time.tick_since(t0)) / 1e6
		if !interactive && d.page != nil && d.parsed && d.page.scripts != nil && d.page.scripts.ready_state != .Loading {
			interactive = true
			s.interactive_ms = el
		}
		if headless.loaded(d) { s.complete_ms = el; break }
		if el > timeout_s * 1000 { s.complete_ms = el; s.failed = "timeout"; break }
	}
	_ = until
	// let late requests settle a moment (images, beacons), counting them too
	headless.pump(d, settle_ms)
	s.cpu_ms = proc_cpu_ms() - cpu0
	s.mem_mb = working_set_mb() - mem0
	if d.failed != "" { s.failed = d.failed }
	if d.page != nil && d.page.doc != nil { s.nodes = d.page.doc.nodes.count }
	if s.interactive_ms == 0 { s.interactive_ms = s.complete_ms }
	s.requests, s.blocked, s.bytes, s.scripts = counter.requests, counter.blocked, counter.bytes, counter.scripts
	headless.close(d)
	if with_blocker { blocker.shutdown(&b, &e.loader) }
	return
}

median :: proc(xs: []f64) -> f64 {
	if len(xs) == 0 { return 0 }
	c := slice.clone(xs, context.temp_allocator)
	slice.sort(c)
	return c[len(c) / 2]
}

main :: proc() {
	context = testenv.context_of_process()
	profile := ""
	runs := 3
	timeout := 40.0
	settle := 3000.0
	md := ""
	urls := make([dynamic]string)
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-profile": i += 1; profile = args[i]
		case "-runs": i += 1; runs = int(parse(args[i]))
		case "-timeout": i += 1; timeout = parse(args[i])
		case "-settle": i += 1; settle = parse(args[i])
		case "-md": i += 1; md = args[i]
		case: append(&urls, args[i])
		}
	}
	if len(urls) == 0 || profile == "" { fmt.eprintln("usage: blockerpages -profile dir [-runs n] [-timeout s] [-md file] url..."); os.exit(2) }
	out := strings.builder_make()
	fmt.sbprintln(&out, "| site | blocker | interactive ms | complete ms | requests | blocked | MB received | DOM nodes | CPU ms | memory MB | scripts |")
	fmt.sbprintln(&out, "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
	for url in urls {
		results: [2][dynamic]Sample
		_ = measure(url, profile, false, timeout, 500)   // warm-up: the process-wide caches (modules, bytecode) are filled, not counted
		for r in 0 ..< runs {
			for mode in 0 ..< 2 {
				m := (mode + r) % 2   // alternate which one goes first
				s := measure(url, profile, m == 1, timeout, settle)
				append(&results[m], s)
				fmt.eprintfln("%s %s run %d: interactive %.0f ms, complete %.0f ms, %d requests (%d blocked), %.2f MB%s", url, m == 1 ? "on " : "off", r, s.interactive_ms, s.complete_ms, s.requests, s.blocked, f64(s.bytes) / 1e6, s.failed != "" ? fmt.tprintf(" [%s]", s.failed) : "")
			}
		}
		for m in 0 ..< 2 {
			col :: proc(l: []Sample, f: proc(s: Sample) -> f64) -> f64 {
				v := make([dynamic]f64, context.temp_allocator)
				for s in l { if s.failed == "" || s.failed == "timeout" { append(&v, f(s)) } }
				return median(v[:])
			}
			l := results[m][:]
			fmt.sbprintfln(&out, "| %s | %s | %.0f | %.0f | %.0f | %.0f | %.2f | %.0f | %.0f | %.0f | %.0f |", url, m == 1 ? "on" : "off",
				col(l, proc(s: Sample) -> f64 { return s.interactive_ms }), col(l, proc(s: Sample) -> f64 { return s.complete_ms }),
				col(l, proc(s: Sample) -> f64 { return f64(s.requests) }), col(l, proc(s: Sample) -> f64 { return f64(s.blocked) }),
				col(l, proc(s: Sample) -> f64 { return f64(s.bytes) / 1e6 }), col(l, proc(s: Sample) -> f64 { return f64(s.nodes) }),
				col(l, proc(s: Sample) -> f64 { return s.cpu_ms }), col(l, proc(s: Sample) -> f64 { return s.mem_mb }),
				col(l, proc(s: Sample) -> f64 { return f64(s.scripts) }))
		}
	}
	fmt.println(strings.to_string(out))
	if md != "" { _ = os.write_entire_file(md, strings.to_string(out)) }
}

parse :: proc(s: string) -> f64 {
	n, frac, div := 0.0, false, 1.0
	for c in s {
		if c == '.' { frac = true; continue }
		if c < '0' || c > '9' { continue }
		if frac { div *= 10; n += f64(c - '0') / div } else { n = n * 10 + f64(c - '0') }
	}
	return n
}

_ :: base
_ :: host
_ :: page
