// `wrentool waterfall`: where a first load's time goes. Each page in a Wren of its own, headless, a throwaway profile (no cache, no connection), navigated from the blank page; then what the
// browser knows of each request: the wait for a slot, the name, the connection, the handshake, the server, the body. One line per load on the standard output, the requests in <OutDir>/<slug>_<run>.tsv.
// What is not the network shows in `gaps`: the time before the load event when no request of the page was in flight.
// -Cold: without the disk cache of compiled modules the measuring tools share: the empty cache of a new profile, or of a profile after an update.
// -Warm: the page loaded once in a Wren of its own first, on the same profile: the load measured is the second, a new process with the disk caches (HTTP, bytecode) of the first.
package capture

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:remote/api"
import "wb:tools/tooling"
import "wb:tools/wrentool/bench"

WATERFALL_FLAGS :: "-Urls= -List= -OutDir= -Exe= -Runs= -Pref= -LimitMs= -AfterMs= -Idle -Stderr= -Cold -Warm"
WATERFALL_OUT :: "build/waterfall"
WATERFALL_RUNS :: 1
WATERFALL_LIMIT_MS :: 30_000
// What the page gets after the load event to finish the requests it has going, before the list is read (-AfterMs n: what a trace of WREN_SPANS needs to see the thread settle, `wrentool threadtime`).
WATERFALL_AFTER_MS :: 500
// -Idle: the list is read when the network has been quiet, at the latest after this. The load event says little of a page whose embeds start while it is awaited: what comes after it is the same work.
WATERFALL_IDLE_LIMIT :: 45 * time.Second
WATERFALL_HEADER :: "idle_ms\trun\tload_api_ms\tpaint\tcontentful\tinteractive\tdcl\tload\trequests\th1\th2\th3\tcached\tfailed\thosts\tkb\tqueued\tmax_queued\tdns\tconnect\ttls\twait\tbody\tlast_end\tgaps\tcpu_ms\tstart_ms\tcpu_total_ms\tprivate_mb\tworking_set_mb\twasm_compiles\twasm_shipped_hits\twasm_shipped_refused\tfirst_realm_ms\tpages_mb\turl\tcpu_after_ms"

// The phases of a load's requests, summed: they overlap, a sum says where requests spent their time, not the page.
Waterfall_Sums :: struct {
	count, h1, h2, h3, cached, failed, hosts, bytes:              int,
	queued, max_queued, dns, connect, tls, wait, body, last_end, gaps: f64,
}

run_waterfall :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, WATERFALL_FLAGS)
	if !ok { return EXIT_USAGE }
	urls := make([dynamic]string)
	for u in tooling.flag_list(f, "-Urls") { if u != "" { append(&urls, strings.clone(u)) } }
	if list := tooling.flag(f, "-List"); list != "" {
		data, err := os.read_entire_file(list, context.allocator)
		if err != nil { fmt.eprintfln("cannot read %s", list); return EXIT_USAGE }
		for raw in strings.split_lines(string(data)) {
			line := strings.trim_space(raw)
			if line != "" && !strings.has_prefix(line, "#") { append(&urls, line) }
		}
	}
	if len(urls) == 0 { fmt.eprintln("wrentool waterfall -Urls a,b | -List file [-OutDir dir] [-Exe path] [-Runs n] [-Pref a=b] [-LimitMs n] [-Cold] [-Warm]"); return EXIT_USAGE }
	exe := tooling.flag(f, "-Exe", bench.WREN_EXE)
	if !os.exists(exe) { fmt.eprintfln("%s is missing (build.bat)", exe); return 1 }
	dir := tooling.flag(f, "-OutDir", WATERFALL_OUT)
	_ = os.make_directory_all(dir)
	out, _ := filepath.abs(dir, context.allocator)
	limit := time.Duration(tooling.flag_int(f, "-LimitMs", WATERFALL_LIMIT_MS)) * time.Millisecond
	linger := time.Duration(tooling.flag_int(f, "-AfterMs", WATERFALL_AFTER_MS)) * time.Millisecond
	prefs := make([dynamic]string)
	append(&prefs, "blocker.update.enabled=false", "blocker.welcome_toast=false")
	for p in tooling.flag_list(f, "-Pref") { if p != "" { append(&prefs, strings.clone(p)) } }

	fmt.println(WATERFALL_HEADER)
	for url in urls {
		for run in 0 ..< tooling.flag_int(f, "-Runs", WATERFALL_RUNS) {
			waterfall_load(exe, out, url, run, prefs[:], limit, linger, tooling.flag_has(f, "-Idle"), tooling.flag(f, "-Stderr"), tooling.flag_has(f, "-Cold"), tooling.flag_has(f, "-Warm"))
			free_all(context.temp_allocator)
		}
	}
	return 0
}

@(private = "file")
waterfall_load :: proc(exe, out, url: string, run: int, prefs: []string, limit, linger: time.Duration, idle: bool, stderr: string, cold, warm: bool) {
	slug := compare_slug(url)
	profile := fmt.tprintf("%s/profile_%s", out, slug)
	base.remove_tree(profile)
	defer base.remove_tree(profile)
	if warm {
		first: bench.Wren
		if !bench.start(&first, {exe = exe, profile = profile, window = .Headless, size = SWEEP_SIZE, prefs = prefs, stderr = stderr, cold = cold}) { return }
		_ = api.navigate(&first.session, url, .Load, limit)
		time.sleep(linger)
		bench.stop(&first)
	}
	w: bench.Wren
	started := time.tick_now()
	if !bench.start(&w, {exe = exe, profile = profile, window = .Headless, size = SWEEP_SIZE, prefs = prefs, stderr = stderr, cold = cold}) { return }
	start_ms := time.duration_milliseconds(time.tick_since(started))
	defer bench.stop(&w)
	s := &w.session
	before, _ := api.stats(s)
	at := time.tick_now()
	e := api.navigate(s, url, .Load, limit)
	took := time.duration_milliseconds(time.tick_since(at))
	after, _ := api.stats(s)
	idle_ms := 0.0
	if idle {
		_ = api.wait_idle(s, WATERFALL_IDLE_LIMIT)
		idle_ms = time.duration_milliseconds(time.tick_since(at))
	} else {
		time.sleep(linger)
	}
	end, _ := api.stats(s)
	n, ne := api.network(s)
	if ne != .None { fmt.printfln("0\t%d\tno answer: %v\t%s", run, ne, url); return }
	m := waterfall_sums(&n)
	fmt.printfln("%.0f\t%d\t%.0f%s\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%d\t%d\t%d\t%d\t%d\t%.0f\t%d\t%s\t%.0f", idle_ms, run, took, e == .Timeout ? "!" : "",
		n.doc.paint, n.doc.contentful, n.doc.interactive, n.doc.dcl, n.doc.load, m.count, m.h1, m.h2, m.h3, m.cached, m.failed, m.hosts, m.bytes >> 10,
		m.queued, m.max_queued, m.dns, m.connect, m.tls, m.wait, m.body, m.last_end, m.gaps, after.cpu_time_ms - before.cpu_time_ms, start_ms, after.cpu_time_ms, after.private_bytes >> 20, after.working_set_bytes >> 20, after.memory.wasm_compiles, after.memory.wasm_shipped_hits, after.memory.wasm_shipped_refused, after.js_first_realm_ms, after.memory.pages_bytes >> 20, url, end.cpu_time_ms - before.cpu_time_ms)
	waterfall_write(fmt.tprintf("%s/%s_%d.tsv", out, slug, run), &n)
}

@(private = "file")
waterfall_sums :: proc(n: ^api.Network) -> (r: Waterfall_Sums) {
	spans := make([][2]f64, len(n.requests), context.temp_allocator)
	hosts := make(map[string]bool, allocator = context.temp_allocator)
	for q, i in n.requests {
		end := q.start_ms + (q.has_ms ? q.ms : 0)
		spans[i] = {q.start_ms, end}
		r.count += 1
		r.bytes += q.bytes
		if q.failed { r.failed += 1 }
		if !q.has_timing { r.cached += 1; continue }
		switch q.protocol {
		case "h2": r.h2 += 1
		case "h3": r.h3 += 1
		case:      r.h1 += 1
		}
		if scheme := strings.index(q.url, "://"); scheme >= 0 {
			path := strings.index_byte(q.url[scheme + 3:], '/')
			hosts[path < 0 ? q.url : q.url[:scheme + 3 + path]] = true
		}
		r.queued += q.queued
		r.max_queued = max(r.max_queued, q.queued)
		if q.dns_start >= 0 { r.dns += q.dns_end - q.dns_start }
		if q.connect_start >= 0 { r.connect += q.connect_end - q.connect_start }
		if q.connect_end >= 0 && q.sending > q.connect_end { r.tls += q.sending - q.connect_end }
		r.wait += max(q.response - max(q.sending, q.queued), 0)
		if q.done > q.response { r.body += q.done - q.response }
		if q.has_ms { r.last_end = max(r.last_end, end) }
	}
	r.hosts = len(hosts)
	slice.sort_by(spans, proc(a, b: [2]f64) -> bool { return a[0] < b[0] })
	covered := 0.0
	load := n.doc.load > 0 ? n.doc.load : r.last_end
	for sp in spans {
		if sp[0] >= load { break }
		if sp[0] > covered { r.gaps += sp[0] - covered }
		covered = max(covered, sp[1])
	}
	if covered < load { r.gaps += load - covered }
	return
}

@(private = "file")
waterfall_write :: proc(path: string, n: ^api.Network) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "start\tqueued\tdns\tconnect\ttls\tsending\tresponse\tdone\tms\tstatus\tprotocol\tcache\tdestination\tbytes\turl")
	for q in n.requests {
		tls := q.connect_end >= 0 && q.sending > q.connect_end ? q.sending - q.connect_end : 0
		fmt.sbprintfln(&b, "%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%d\t%s\t%s\t%s\t%d\t%s", q.start_ms, q.queued, q.dns_start >= 0 ? q.dns_end - q.dns_start : 0, q.connect_start >= 0 ? q.connect_end - q.connect_start : 0, tls,
			q.sending, q.response, q.done, q.ms, q.status, q.protocol, q.cache, q.destination, q.bytes, q.url)
	}
	_ = os.write_entire_file(path, strings.to_string(b))
}
