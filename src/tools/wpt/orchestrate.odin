package wpt

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "wb:testserver"
import "wb:tools/tooling"

// What a run of the suite is around the tests: the pinned checkout (a partial sparse clone of WPT_COMMIT: the measured folders and the shared ones, verified file by file against wpt/MANIFEST.txt),
// the test server in this process (src/testserver: its WPT origin, on the block of ports it found free), the run, the second chance of what regressed. Outputs in build/wpt: report.md (pass rates per folder),
// results.txt (every test and subtest), children/ (logs). The exit status is 1 on a regression against the expectations.

WPT_COMMIT :: "4ad507b28db0a636f528def9161d109fe11b93a3"
WPT_REMOTE :: "https://github.com/web-platform-tests/wpt.git"
OUT_DIR :: "build/wpt"
CHECKOUT_DIR :: "build/wpt/wpt"
CHECKOUT_STAMP :: "build/wpt/CHECKOUT"
MANIFEST_FILE :: "wpt/MANIFEST.txt"
SUITES_FILE :: "wpt/suites.txt"
REPORT_MD :: "build/wpt/report.md"
RESULTS_TXT :: "build/wpt/results.txt"
EDGE_RESULTS :: "build/wpt/edge_results.txt"
AGAIN_TXT :: "build/wpt/again.txt"
AGAIN_MD :: "build/wpt/again.md"
TEST_CA_FILE :: "build/wpt/testca.pem"
// What the tests of the measured folders load from elsewhere in WPT.
SHARED_PATTERNS := []string{"/resources/", "/common/", "/interfaces/", "/images/", "/fonts/", "/dom/common.js", "/dom/events/resources/",
	"/html/resources/", "/fetch/api/resources/", "/fetch/resources/", "/xhr/resources/", "/encoding/resources/",
	"/service-workers/service-worker/resources/", "/workers/support/", "/webidl/resources/", "/dom/constants.js",
	"/trusted-types/support/", "/storage/buckets/resources/", "/loading/resources/", "/webrtc/RTCPeerConnection-helper.js",
	"/css/support/parsing-testcommon.js", "/html/webappapis/structured-clone/", "/css/support/computed-testcommon.js", "/css/support/shadow-helper.js", "/media/", "/wasm/resources/",
	"/css/support/inheritance-testcommon.js", "/css/support/interpolation-testcommon.js", "/css/support/shorthand-testcommon.js",
	"/css/css-conditional/container-queries/support/cq-testcommon.js", "/css/css-typed-om/resources/testhelper.js",
	"/css/css-transitions/support/helper.js", "/html/semantics/popovers/resources/popover-utils.js",
	"/web-animations/testcommon.js", "/web-animations/resources/", "/css/css-animations/support/", "/css/css-transitions/support/",
	"/css/reference/"}   // (the references reftests of many folders share)
// The base port's offset of the WPT origin (tools/testserver/ports.go).
WPT_PORT_OFFSET :: 3
// wptserve's host and the names under it and its alternate host (tools/testserver/wpt.go: WPTHostsPref), all this machine.
WPT_HOST :: "web-platform.test"
WPT_HOSTS :: "web-platform.test=127.0.0.1,not-web-platform.test=127.0.0.1"
EDGE_HOST_RULES :: "--host-resolver-rules=MAP web-platform.test 127.0.0.1, MAP *.web-platform.test 127.0.0.1, MAP not-web-platform.test 127.0.0.1, MAP *.not-web-platform.test 127.0.0.1"
// More tests than this regressing at once is no matter of load: no second chance. (With -fast-timeouts, a test expected to time out may just not have reached its subtests by the cap: those go too.)
SECOND_CHANCE_MOST :: 60
SECOND_CHANCE_MOST_FAST :: 600
// How many times its limit a test gets the second time (other steps of a run still go beside it), how many run at a time, and the engine's limit on one script: "Uncaught InternalError: interrupted" of a 5 s script on a loaded machine is no regression.
SECOND_CHANCE_TIME_FACTOR :: 4
SECOND_CHANCE_JOBS :: 2
SECOND_CHANCE_SCRIPT_MS :: 60000
// -fast-timeouts: 58 % of a full run's time goes to timeouts: a test expected to time out stops at this share of its limit, and a page that can do nothing more is given up on after this much instead of a second.
FAST_CAP_FACTOR :: 0.3
FAST_IDLE_MS :: 300
// Edge: a test's budget plus this, seconds; helper processes that may still hold their files, how long they are waited for, how often the run is looked at.
EDGE_MARGIN_SECONDS :: 60
EDGE_SWEEP_LIMIT :: 30 * time.Second
EDGE_TICK :: 100 * time.Millisecond
EDGE_KILL_WAIT :: 200 * time.Millisecond
EDGE_SWEEP_SLICE :: 500 * time.Millisecond
EDGE_PROGRAMS := []string{"C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe", "C:/Program Files/Microsoft/Edge/Application/msedge.exe"}
EDGE_RESULT_OPEN :: `<pre id="wren-wpt-result">`
EDGE_RESULT_CLOSE :: "</pre>"
HARNESS_STATUSES := []string{"OK", "ERROR", "TIMEOUT", "PRECONDITION_FAILED"}
SUBTEST_STATUSES := []string{"PASS", "FAIL", "TIMEOUT", "NOTRUN", "PRECONDITION_FAILED"}

// The flags of a whole run, as opposed to those of one pass over the tests (`Options`).
Run_Flags :: struct {
	fetch_only, update_manifest, no_server, edge, fast_timeouts, no_fast_timeouts: bool,
	other_root: string,   // -root: another checkout, not verified
	jobs_set:   bool,
}
flags: Run_Flags

@(private = "file")
checkout_patterns :: proc(allocator := context.temp_allocator) -> (patterns: []string, ok: bool) {
	suites, good := read_suites(SUITES_FILE)
	if !good { return nil, false }
	out := make([dynamic]string, allocator)
	append(&out, ..SHARED_PATTERNS)
	for s in suites { append(&out, fmt.aprintf("/%s/", s.folder, allocator = allocator)) }
	return out[:], true
}

@(private = "file")
tree_hashes :: proc(dir: string, out: ^[dynamic]string, prefix: int) {
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil { return }
	defer os.file_info_slice_delete(entries, context.allocator)
	for e in entries {
		if e.name == ".git" { continue }
		if e.type == .Directory { tree_hashes(e.fullpath, out, prefix); continue }
		digest, ok := tooling.sha256_of_file(e.fullpath, context.temp_allocator)
		if !ok { digest = "unreadable" }
		rel, _ := strings.replace_all(e.fullpath[prefix:], "\\", "/", context.temp_allocator)
		append(out, fmt.aprintf("%s  %s", digest, rel))
		free_all(context.temp_allocator)
	}
}

@(private = "file")
checkout_hashes :: proc() -> []string {
	full, _ := filepath.abs(CHECKOUT_DIR)
	out: [dynamic]string
	tree_hashes(full, &out, len(full) + 1)
	slice.sort(out[:])
	return out[:]
}

@(private = "file")
write_manifest :: proc(lines: []string) -> bool {
	b := strings.builder_make()
	fmt.sbprintfln(&b, "# web-platform-tests %s: SHA-256 of every file fetched by build/wpt -fetch", WPT_COMMIT)
	for l in lines { fmt.sbprintln(&b, l) }
	if os.write_entire_file(MANIFEST_FILE, strings.to_string(b)) != nil { return false }
	fmt.printfln("%s rewritten (%d files)", MANIFEST_FILE, len(lines))
	return true
}

// The checkout: a partial clone (blobs of the sparse set only), bytes as committed (no CRLF conversion), verified against the pinned list; nothing to do when its stamp says it is this commit and these folders.
@(private = "file")
ensure_checkout :: proc() -> bool {
	_ = os.make_directory_all(OUT_DIR)
	patterns, good := checkout_patterns()
	if !good { return false }
	want := fmt.tprintf("%s\n%s", WPT_COMMIT, strings.join(patterns, "\n", context.temp_allocator))
	if known, err := os.read_entire_file(CHECKOUT_STAMP, context.temp_allocator); err == nil && string(known) == want {
		if flags.update_manifest { return write_manifest(checkout_hashes()) }
		return true
	}
	git :: proc(args: ..string) -> bool {
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "git", "-C", CHECKOUT_DIR)
		append(&cmd, ..args)
		return tooling.run({command = cmd[:], env = {fmt.tprintf("GIT_CEILING_DIRECTORIES=%s", abs_path(OUT_DIR))}}) == 0
	}
	if !os.exists(fmt.tprintf("%s/.git", CHECKOUT_DIR)) {
		_ = os.make_directory_all(CHECKOUT_DIR)
		if !git("init", "-q") || !git("remote", "add", "origin", WPT_REMOTE) { return false }
	}
	git("config", "core.autocrlf", "false")
	git("config", "core.eol", "lf")
	git("sparse-checkout", "init", "--no-cone")
	sparse := fmt.tprintf("%s\n", strings.join(patterns, "\n", context.temp_allocator))
	if os.write_entire_file(fmt.tprintf("%s/.git/info/sparse-checkout", CHECKOUT_DIR), sparse) != nil { return false }
	fmt.printfln("fetching web-platform-tests %s", WPT_COMMIT)
	if !git("fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", WPT_COMMIT) { fmt.eprintln("wpt: git fetch of the WPT commit failed"); return false }
	if !git("-c", "core.autocrlf=false", "checkout", "-q", "-f", "FETCH_HEAD") { fmt.eprintln("wpt: git checkout of the WPT commit failed"); return false }
	// (files of an earlier sparse set or converted line endings: the index decides)
	git("-c", "core.autocrlf=false", "read-tree", "-mu", "HEAD")
	git("-c", "core.autocrlf=false", "reset", "-q", "--hard", "HEAD")
	head, _ := tooling.capture({"git", "-C", CHECKOUT_DIR, "rev-parse", "HEAD"})
	if strings.trim_space(head) != WPT_COMMIT { fmt.eprintfln("wpt: the checkout is at %s, not %s", head, WPT_COMMIT); return false }
	lines := checkout_hashes()
	if flags.update_manifest {
		if !write_manifest(lines) { return false }
	} else {
		data, err := os.read_entire_file(MANIFEST_FILE, context.allocator)
		if err != nil { fmt.eprintfln("wpt: %s is missing: run wpt -update-manifest", MANIFEST_FILE); return false }
		pinned: map[string]bool
		first := true
		text := string(data)
		for raw in strings.split_lines_iterator(&text) {
			l := strings.trim_right(raw, "\r")
			if first && !strings.contains(l, WPT_COMMIT) { fmt.eprintfln("wpt: %s is for another commit: run wpt -update-manifest", MANIFEST_FILE); return false }
			first = false
			if l != "" && l[0] != '#' { pinned[l] = true }
		}
		differences := 0
		MANIFEST_DIFFERENCES_SHOWN :: 10
		for l in lines {
			if l in pinned { delete_key(&pinned, l); continue }
			differences += 1
			if differences <= MANIFEST_DIFFERENCES_SHOWN { fmt.eprintfln("  not in the manifest: %s", l) }
		}
		for l in pinned {
			differences += 1
			if differences <= MANIFEST_DIFFERENCES_SHOWN { fmt.eprintfln("  not in the checkout: %s", l) }
		}
		if differences > 0 { fmt.eprintfln("wpt: the WPT checkout does not match %s (%d differences)", MANIFEST_FILE, differences); return false }
		fmt.printfln("verified %d files against %s", len(lines), MANIFEST_FILE)
	}
	return os.write_entire_file(CHECKOUT_STAMP, want) == nil
}

abs_path :: proc(path: string) -> string {
	full, _ := filepath.abs(path, context.temp_allocator)
	return full
}

// The whole of a run: a run of the tests, under what the flags ask, and of what regressed in it.
run_main :: proc() -> int {
	if flags.update_manifest && opts.update { fmt.eprintln("wpt: -update-manifest and -update are two runs"); return 2 }
	if flags.other_root == "" {
		if !ensure_checkout() { return 1 }
		if flags.fetch_only { return 0 }
	}
	if !flags.no_server {
		if !tooling.ensure_testserver() { fmt.eprintln("wpt: building the test server failed"); return 1 }
		if flags.other_root != "" { os.set_env("WREN_WPT_ROOT", abs_path(flags.other_root)) }
		base, why := testserver.start()
		if base == 0 { fmt.eprintfln("wpt: %s", why); return 1 }
		opts.server = fmt.aprintf("http://%s:%d", WPT_HOST, base + WPT_PORT_OFFSET)
		// the authority of its https origin, trusted by the children only (as wptrunner hands its browsers WPT's own)
		if os.write_entire_file(TEST_CA_FILE, testserver.ca_pem(context.temp_allocator)) != nil { fmt.eprintfln("wpt: cannot write %s", TEST_CA_FILE); return 1 }
		append(&opts.prefs_args, "--pref", fmt.aprintf("network.tls.extra_ca_file=%s", abs_path(TEST_CA_FILE)))
	}
	// wptserve's names, resolved by the browser itself to the server on this machine, and nothing else reached (tools/testserver/wpt.go)
	append(&opts.prefs_args, "--pref", "network.hosts=" + WPT_HOSTS, "--pref", "network.loopback_only=true")
	if opts.md == "" { opts.md = REPORT_MD }
	if opts.results == "" { opts.results = RESULTS_TXT }
	// media tests call play() without a gesture (the harness of other browsers runs with autoplay allowed too)
	append(&opts.prefs_args, "--pref", "media.autoplay.policy=allow-all")
	if os.exists(EDGE_RESULTS) && !flags.edge && opts.reference == "" { opts.reference = EDGE_RESULTS }
	if flags.edge { return edge_main() }

	// -fast-timeouts (always with -quick): what a test that fails for it needs goes through the second chance below, with neither: it can only cost time. What it does not see is a test that has begun to pass: a
	// full run without it and -update do. -update never uses it, nor does -only (someone looking at tests).
	fast := (opts.quick || flags.fast_timeouts) && !opts.update && opts.only == "" && !flags.no_fast_timeouts
	if fast {
		opts.timeout_cap_ms = int(FAST_CAP_FACTOR * f64(opts.timeout_ms))
		opts.idle_ms = FAST_IDLE_MS
	}
	status := parent_main()
	if status != 1 || opts.update { return status }

	// A second chance for a test that failed among the others (out of time, or its script stopped by a time limit): it runs again with more time, and only a test that regresses twice counts.
	// (Which tests time out under load changes from one run to the next.)
	// (one that ran out of its limit from history is not counted against the most: that limit was this run's choice, the test gets its whole limit again)
	paths := slice.clone(regressed_paths[:])
	most := (opts.quick || flags.fast_timeouts) ? SECOND_CHANCE_MOST_FAST : SECOND_CHANCE_MOST
	not_cut := 0
	for p in paths {
		if p in cut_short { retimed[p] = true } else { not_cut += 1 }
	}
	if len(paths) == 0 || not_cut > most { return status }
	opts.quick = false
	opts.timeout_cap_ms = 0
	opts.history_limits = false
	opts.idle_ms = IDLE_MS_DEFAULT
	opts.timeout_ms *= SECOND_CHANCE_TIME_FACTOR
	opts.jobs = SECOND_CHANCE_JOBS
	opts.results, opts.md = AGAIN_TXT, AGAIN_MD
	opts.quiet = true
	append(&opts.prefs_args, "--pref", fmt.aprintf("javascript.slow_script_ms=%d", SECOND_CHANCE_SCRIPT_MS))
	again := proc(list: []string) -> int {
		clear(&opts.only_paths)
		for p in list { opts.only_paths[p] = true }
		clear(&regressed_paths)
		return parent_main()
	}
	status = again(paths)
	still := slice.clone(regressed_paths[:])
	fmt.printfln("again, two at a time: %d of %d tests pass (a timeout under load, -fast-timeouts or a limit from history)", len(paths) - len(still), len(paths))
	// (what is left truly alone: a script stopped by a wall-clock limit of the engine, with the other test beside it)
	if status != 0 && len(still) > 0 && len(still) <= most {
		opts.jobs = 1
		status = again(still)
		fmt.printfln("again, alone: %d test(s), %s", len(still), status == 0 ? "they pass" : "still failing")
	}
	if status != 0 { fmt.print(last_regressions) }
	return status
}

// The reference run in Edge (-edge): the same tests, the same server, testharnessreport.js puts its JSON in the document (<pre id="wren-wpt-result">), read with --dump-dom after a virtual time budget of the test's
// timeout. Written to build/wpt/edge_results.txt (the expectations' format), which later runs of Wren add to their table.
@(private = "file")
Edge_Run :: struct {
	process:       tooling.Process,
	test:          Test,
	dom, profile:  string,
	limit_seconds: f64,
	alive:         bool,
}

edge_main :: proc() -> int {
	edge := ""
	for candidate in EDGE_PROGRAMS { if os.exists(candidate) { edge = candidate; break } }
	if edge == "" { fmt.eprintln("wpt: Microsoft Edge not found"); return 1 }
	suites, ok := read_suites(opts.suites)
	if !ok { return 2 }
	tests := make([dynamic]Test)
	for t in discover(suites[:]) { if !t.is_reftest && (opts.only == "" || strings.has_prefix(t.path, opts.only) || strings.has_prefix(t.path[1:], opts.only)) { append(&tests, t) } }
	slots := opts.jobs
	folder := fmt.aprintf("%s/wren_wpt_edge_%d", tooling_temp(), os.get_pid())
	_ = os.make_directory_all(folder)
	running := make([]Edge_Run, slots)
	results := make(map[string]string)
	pending: [dynamic]string   // throwaway profiles and outputs, removed once Edge's helper processes let go of them
	sweep :: proc(pending: ^[dynamic]string) {
		for i := len(pending) - 1; i >= 0; i -= 1 {
			if os.remove_all(pending[i]) == nil && !os.exists(pending[i]) { unordered_remove(pending, i) }
		}
	}
	next, started := 0, 0
	for next < len(tests) || slice.any_of_proc(running, proc(r: Edge_Run) -> bool { return r.alive }) {
		for &r in running {
			if !r.alive { continue }
			done, _ := tooling.poll(&r.process)
			if !done && time.duration_seconds(time.tick_since(r.process.began)) > r.limit_seconds {
				tooling.kill_tree(&r.process)
				time.sleep(EDGE_KILL_WAIT)
				done = true
			}
			if !done { continue }
			results[r.test.path] = edge_result(r.test.path, r.dom)
			tooling.release(&r.process)
			append(&pending, r.profile, r.dom)
			r.alive = false
		}
		for &r in running {
			if r.alive || next >= len(tests) { continue }
			t := tests[next]
			next += 1
			started += 1
			budget := opts.timeout_ms * (t.long ? LONG_TIMEOUT_FACTOR : 1)
			r.test = t
			r.profile = fmt.aprintf("%s/p%d", folder, started)
			r.dom = fmt.aprintf("%s/d%d.html", folder, started)
			r.limit_seconds = f64(budget) / 1000 + EDGE_MARGIN_SECONDS
			p, why := tooling.spawn({command = {edge, "--headless=new", "--disable-gpu", "--no-first-run", "--disable-extensions", EDGE_HOST_RULES, "--ignore-certificate-errors", fmt.tprintf("--user-data-dir=%s", r.profile), fmt.tprintf("--virtual-time-budget=%d", budget), "--dump-dom", test_url(t.path)}, log = r.dom})
			if why != "" { fmt.eprintfln("wpt: Edge does not start: %s", why); return 1 }
			r.process, r.alive = p, true
		}
		fmt.eprintf("%d/%d\r", started, len(tests))
		if len(pending) > 4 * slots { sweep(&pending) }
		time.sleep(EDGE_TICK)
		free_all(context.temp_allocator)
	}
	sweep_began := time.tick_now()
	for len(pending) > 0 && time.tick_since(sweep_began) < EDGE_SWEEP_LIMIT {
		sweep(&pending)
		time.sleep(EDGE_SWEEP_SLICE)
	}
	_ = os.remove_all(folder)
	names := make([dynamic]string)
	for k in results { append(&names, k) }
	slice.sort(names[:])
	b := strings.builder_make()
	fmt.sbprintln(&b, "# web-platform-tests in Edge (build/wpt -edge): the reference of the table")
	for k in names { fmt.sbprintln(&b, results[k]) }
	if os.write_entire_file(EDGE_RESULTS, strings.to_string(b)) != nil { return 1 }
	fmt.printfln("Edge results: %s (%d tests)", EDGE_RESULTS, len(tests))
	return 0
}

@(private = "file")
tooling_temp :: proc() -> string {
	d, _ := os.temp_directory(context.allocator)
	return d
}

// A test's lines in the expectations' format, from what Edge dumped. (Its helper processes inherit its standard output and may still hold the file: reading shares it.)
@(private = "file")
edge_result :: proc(path, dom: string) -> string {
	data, _ := os.read_entire_file(dom, context.temp_allocator)
	html := string(data)
	b := strings.builder_make()
	if open := strings.index(html, EDGE_RESULT_OPEN); open >= 0 {
		rest := html[open + len(EDGE_RESULT_OPEN):]
		if close := strings.index(rest, EDGE_RESULT_CLOSE); close >= 0 {
			text := html_decoded(rest[:close])
			Report :: struct { status: int, tests: []struct { name: string, status: int } }
			report: Report
			if json.unmarshal_string(text, &report, allocator = context.temp_allocator) == nil && report.status >= 0 && report.status < len(HARNESS_STATUSES) {
				fmt.sbprintf(&b, "%s: %s", path, HARNESS_STATUSES[report.status])
				slice.sort_by(report.tests, proc(x, y: struct { name: string, status: int }) -> bool { return x.name < y.name })
				for t, i in report.tests {
					if i > 0 && report.tests[i - 1].name == t.name { continue }
					status := t.status >= 0 && t.status < len(SUBTEST_STATUSES) ? SUBTEST_STATUSES[t.status] : "FAIL"
					fmt.sbprintf(&b, "\n\t%s: %s", escape(t.name), status)
				}
				return strings.to_string(b)
			}
		}
	}
	return fmt.aprintf("%s: TIMEOUT", path)
}

@(private = "file")
html_decoded :: proc(s: string) -> string {
	out := s
	for pair in ([][2]string{{"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&#39;", "'"}, {"&amp;", "&"}}) {
		out, _ = strings.replace_all(out, pair[0], pair[1], context.temp_allocator)
	}
	return out
}
