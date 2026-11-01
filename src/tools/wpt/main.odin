// wpt: a pinned subset of web-platform-tests in Wren without a window: one page per test (the document loaded as the
// browser loads it, src/tools/headless), testharness.js and Wren's testharnessreport.js (wpt/), which hands the results
// to this tool as one console message. tools\wpt.ps1 fetches the pinned checkout and runs this tool against the test
// server (tools/testserver/wpt.go, http://127.0.0.1:8768/).
//
//   wpt [-root build/wpt/wpt] [-suites wpt/suites.txt] [-expect wpt/expectations] [-server http://127.0.0.1:8768]
//       [-timeout ms] [-timeout-cap ms] [-idle ms] [-jobs n] [-quick] [-update] [-md report.md] [-results results.txt] [-only prefix]
//       [-only-file list.txt] [-reference edge_results.txt] [-list] [--pref name=value]... [-reftests | -no-reftests] [-reftest-folder folder]...
//       [-dump dir] [-dump-all]
// WPT_CONSOLE=1 writes every console message of the tests to the children's logs (build/wpt/children/log_*.txt).
// -list prints the tests (path, long timeout, folder) and stops; -reference adds the subtests of a reference run in
// another browser to the table (tools\wpt.ps1 -Edge writes it in the format of the expectations).
//
// Isolation: the tests run in child processes (`wpt -child list out`), a few dozen each, `-jobs` at a time; a child
// that dies or stops answering loses only the test it was running (CRASH), the others go to a new child.
// Time: a test has -timeout (x6 with <meta name=timeout content=long>), then the runner calls testharness.js's
// timeout() and waits for the report a little longer; a page that can no longer do anything (loaded, no timer, no
// request, no animation frame, no worker for -idle ms) is timed out at once.
// Expectations: wpt/expectations/<folder>.txt, per test its status (OK, ERROR, TIMEOUT, CRASH, PRECONDITION_FAILED)
// and per subtest PASS, FAIL, TIMEOUT, NOTRUN, PRECONDITION_FAILED ("A|B" accepts either: flaky). The exit status is 1
// on a regression: an expected OK test that is not OK, an expected PASS subtest that does not pass. Improvements are
// listed (refresh with -update). -quick runs a fixed sample (a few tests per folder).
// Reference tests (reftest_run.odin, package reftest) run in the folders of REFTEST_FOLDERS (layout_host.odin), and of
// -reftest-folder for a checkout that has them: counted apart from testharness tests, their own table in the report, their
// own expectations (wpt/expectations/<folder>.reftest: PASS, FAIL, TIMEOUT, ERROR, CRASH per test), results in <results
// file stem>.reftest.txt. -reftests runs only them, -no-reftests none. -dump writes the pictures of what fails (test,
// reference, difference, PNG) to a directory outside the repository, also from the environment (WPT_REFTEST_DUMP);
// -dump-all those of what passes too. -update with -only of one whole folder rewrites only that folder.
package wpt

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "wb:config"
import "wb:desktop"
import "wb:fetch"
import "wb:host"
import "wb:js"
import "wb:page"
import "wb:wasm"
import "wb:tools/headless"
import "wb:tools/testenv"
import "wb:tools/wpt/reftest"

// A test with <meta name=timeout content=long> has this many times the time limit.
LONG_TIMEOUT_FACTOR :: 6
// What a hung child gets on top of the longest time a test may take, ms.
CHILD_HANG_MARGIN_MS :: 30_000

Test :: struct {
	folder: string,   // the suite folder it belongs to ("dom/nodes")
	path:   string,   // URL path with its variant ("/dom/nodes/x.any.html?a")
	long:   bool,     // <meta name=timeout content=long> / META: timeout=long
	is_reftest: bool, // compared with its references (else testharness.js reports)
	cap_ms: int,      // -timeout-cap: this test is expected to time out, it gets this much (0: its normal limit)
}

Sub :: struct { name, status, message: string }

Result :: struct {
	path:    string,
	status:  string,
	message: string,
	ms:      int,
	subs:    [dynamic]Sub,
}

Suite :: struct {
	folder: string,
	only:   [dynamic]string,   // sub-folders (relative to the folder; "." = its own files) when sampled
	reftests_only: bool,       // from -reftest-folder: not in the suites file, no testharness results of it
}

Options :: struct {
	root, suites, expect, server, md, results, only, only_file, self, reference, dump: string,
	timeout_ms, idle_ms, jobs, chunk, timeout_cap_ms: int,
	quick, update, list, reftests_only, no_reftests, dump_all: bool,
	reftest_folders: [dynamic]string,
	prefs_args: [dynamic]string,
}

opts: Options

main :: proc() {
	opts = {
		root = "build/wpt/wpt", suites = "wpt/suites.txt", expect = "wpt/expectations", server = testenv.url("http://127.0.0.1:8768"),
		timeout_ms = 10_000, idle_ms = 1000, jobs = max(1, host.processor_count() / 2), chunk = 25, self = os.args[0],
	}
	opts.dump = dump_dir_from_env()
	args := desktop.command_line_args(context.allocator)   // (os.args is the C runtime's ANSI: a folder may have accents)
	if len(args) >= 3 && args[0] == "-child" {
		parse_options(args[3:])
		os.exit(child_main(args[1], args[2]))
	}
	parse_options(args)
	os.exit(parent_main())
}

usage :: proc() -> ! {
	fmt.eprintln("usage: wpt [-root dir] [-suites file] [-expect dir] [-server url] [-timeout ms] [-idle ms] [-jobs n] [-quick] [-update] [-md file] [-results file] [-only prefix] [--pref name=value]... [-reftests | -no-reftests] [-reftest-folder folder]... [-dump dir] [-dump-all]")
	os.exit(2)
}

parse_options :: proc(args: []string) {
	for i := 0; i < len(args); i += 1 {
		need :: proc(args: []string, i: ^int) -> string { i^ += 1; if i^ >= len(args) { usage() }; return args[i^] }
		switch args[i] {
		case "-root": opts.root = need(args, &i)
		case "-suites": opts.suites = need(args, &i)
		case "-expect": opts.expect = need(args, &i)
		case "-server": opts.server = strings.trim_right(need(args, &i), "/")
		case "-timeout": opts.timeout_ms = max(500, atoi(need(args, &i)))
		case "-idle": opts.idle_ms = atoi(need(args, &i))
		case "-timeout-cap": opts.timeout_cap_ms = atoi(need(args, &i))
		case "-jobs": opts.jobs = max(1, atoi(need(args, &i)))
		case "-chunk": opts.chunk = max(1, atoi(need(args, &i)))
		case "-quick": opts.quick = true
		case "-update": opts.update = true
		case "-md": opts.md = need(args, &i)
		case "-results": opts.results = need(args, &i)
		case "-only": opts.only = need(args, &i)
		case "-only-file": opts.only_file = need(args, &i)
		case "-list": opts.list = true
		case "-reference": opts.reference = need(args, &i)
		case "--pref": append(&opts.prefs_args, "--pref", need(args, &i))
		case "-reftests": opts.reftests_only = true
		case "-no-reftests": opts.no_reftests = true
		case "-reftest-folder": append(&opts.reftest_folders, strings.trim(need(args, &i), "/"))
		case "-dump": opts.dump = need(args, &i)
		case "-dump-all": opts.dump_all = true
		case: usage()
		}
	}
}

atoi :: proc(s: string) -> int {
	v := 0
	for c in s { if c >= '0' && c <= '9' { v = v * 10 + int(c - '0') } }
	return v
}

////////////////////////////////
// Discovery

read_suites :: proc(path: string) -> (out: [dynamic]Suite, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { fmt.eprintfln("wpt: cannot read %s", path); return }
	for raw in strings.split_lines(string(data)) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' { continue }
		fields := strings.fields(line)
		s := Suite{folder = strings.trim(fields[0], "/")}
		for f in fields[1:] {
			if strings.has_prefix(f, "only=") {
				for part in strings.split(f[5:], ",") { append(&s.only, strings.trim(part, "/")) }
			}
		}
		append(&out, s)
	}
	return out, true
}

// Support folders and files are no tests (as in WPT's manifest).
is_support_dir :: proc(name: string) -> bool {
	switch name {
	case "resources", "support", "tools", "common", ".git", "crashtests", "reference", "references": return true
	}
	return false
}

has_testharness :: proc(text: string) -> bool { return strings.contains(text, "/resources/testharness.js") }

is_reftest :: proc(text: string) -> bool {
	return strings.contains(text, "rel=\"match\"") || strings.contains(text, "rel=match") || strings.contains(text, "rel='match'") ||
	       strings.contains(text, "rel=\"mismatch\"") || strings.contains(text, "rel=mismatch")
}

// <meta name="variant" content="?x"> of an HTML test, "// META: variant=?x" of a script test.
variants_html :: proc(text: string, out: ^[dynamic]string) {
	rest := text
	for {
		k := strings.index(rest, "name=\"variant\"")
		if k < 0 { k = strings.index(rest, "name=variant") }
		if k < 0 { return }
		// the content attribute of the same tag
		tag_start := strings.last_index_byte(rest[:k], '<')
		tag_end := strings.index_byte(rest[k:], '>')
		if tag_start < 0 || tag_end < 0 { return }
		tag := rest[tag_start:k + tag_end]
		if c := strings.index(tag, "content=\""); c >= 0 {
			v := tag[c + 9:]
			if e := strings.index_byte(v, '"'); e >= 0 { append(out, v[:e]) }
		}
		rest = rest[k + tag_end:]
	}
}

Script_Meta :: struct { globals: [dynamic]string, variants: [dynamic]string, long: bool }

script_meta :: proc(text: string) -> (m: Script_Meta) {
	m.globals = make([dynamic]string, context.temp_allocator)
	m.variants = make([dynamic]string, context.temp_allocator)
	for raw in strings.split_lines(text, context.temp_allocator) {
		l := strings.trim_space(raw)
		if !strings.has_prefix(l, "//") { if l == "" { continue }; break }
		l = strings.trim_space(l[2:])
		if !strings.has_prefix(l, "META:") { continue }
		kv := strings.trim_space(l[5:])
		eq := strings.index_byte(kv, '=')
		if eq < 0 { continue }
		key, value := strings.trim_space(kv[:eq]), strings.trim_space(kv[eq + 1:])
		switch key {
		case "global": for g in strings.split(value, ",", context.temp_allocator) { append(&m.globals, strings.trim_space(g)) }
		case "variant": append(&m.variants, value)
		case "timeout": m.long = value == "long"
		}
	}
	return
}

add_test :: proc(out: ^[dynamic]Test, folder, path: string, variants: []string, long: bool, is_reftest := false) {
	if len(variants) == 0 { append(out, Test{folder = folder, path = strings.clone(path), long = long, is_reftest = is_reftest}); return }
	for v in variants { append(out, Test{folder = folder, path = strings.concatenate({path, v}), long = long, is_reftest = is_reftest}) }
}

// A page with links to references is a reference test, unless WPT's names make it a reference, a print or a visual test.
add_reftest :: proc(out: ^[dynamic]Test, folder, url_path, text: string) {
	if reftest.is_reference_name(url_path) || reftest.is_unmeasured_name(url_path) { return }
	info := reftest.scan_page(text, url_path, context.temp_allocator)
	if len(info.refs) == 0 || info.paged { return }
	vars := make([dynamic]string, context.temp_allocator)
	variants_html(text, &vars)
	long := strings.contains(text, "name=\"timeout\" content=\"long\"") || strings.contains(text, "name=timeout content=long")
	add_test(out, folder, url_path, vars[:], long, true)
}

discover_dir :: proc(out: ^[dynamic]Test, folder, dir_rel: string, recurse: bool) {
	full := filepath.join({opts.root, dir_rel}, context.temp_allocator) or_else ""
	entries, err := os.read_all_directory_by_path(full, context.temp_allocator)
	if err != nil { return }
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
	for e in entries {
		rel := strings.concatenate({dir_rel, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			if recurse && !is_support_dir(e.name) { discover_dir(out, folder, rel, true) }
			continue
		}
		name := e.name
		if strings.contains(name, "-manual.") || strings.contains(name, "-ref.") || strings.has_prefix(name, "ref-") { continue }
		url_path := strings.concatenate({"/", rel}, context.temp_allocator)
		switch {
		case strings.has_suffix(name, ".any.js"), strings.has_suffix(name, ".window.js"), strings.has_suffix(name, ".worker.js"):
			data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
			if rerr != nil { continue }
			m := script_meta(string(data))
			base := url_path[:len(url_path) - 3]   // without ".js"
			if strings.has_suffix(name, ".any.js") {
				window, worker := len(m.globals) == 0, len(m.globals) == 0
				for g in m.globals {
					switch g {
					case "window": window = true
					case "worker", "dedicatedworker": worker = true
					case "dedicatedworker-module": // (module workers: not generated by the server)
					}
				}
				if window { add_test(out, folder, strings.concatenate({base, ".html"}, context.temp_allocator), m.variants[:], m.long) }
				if worker { add_test(out, folder, strings.concatenate({base, ".worker.html"}, context.temp_allocator), m.variants[:], m.long) }
			} else {
				add_test(out, folder, strings.concatenate({base, ".html"}, context.temp_allocator), m.variants[:], m.long)
			}
		case strings.has_suffix(name, ".html"), strings.has_suffix(name, ".htm"), strings.has_suffix(name, ".xhtml"), strings.has_suffix(name, ".xht"):
			data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
			if rerr != nil { continue }
			text := string(data)
			// a page with both a harness and references is a testharness test (WPT's manifest): where reference tests do not
			// run such pages stay out, as they always have
			runs_reftests := wants_reftests(folder)
			harness := has_testharness(text)
			if !harness && runs_reftests { add_reftest(out, folder, url_path, text); continue }
			if !harness || (is_reftest(text) && !runs_reftests) { continue }
			vars := make([dynamic]string, context.temp_allocator)
			variants_html(text, &vars)
			long := strings.contains(text, "name=\"timeout\" content=\"long\"") || strings.contains(text, "name=timeout content=long")
			add_test(out, folder, url_path, vars[:], long)
		case strings.has_suffix(name, ".svg") && wants_reftests(folder):
			data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
			if rerr != nil { continue }
			if !has_testharness(string(data)) { add_reftest(out, folder, url_path, string(data)) }
		}
	}
}

discover :: proc(suites: []Suite) -> [dynamic]Test {
	out: [dynamic]Test
	for s in suites {
		if len(s.only) == 0 {
			discover_dir(&out, s.folder, s.folder, true)
		} else {
			for o in s.only {
				if o == "." || o == "" { discover_dir(&out, s.folder, s.folder, false) }
				else { discover_dir(&out, s.folder, strings.concatenate({s.folder, "/", o}, context.temp_allocator), true) }
			}
		}
	}
	return out
}

////////////////////////////////
// Results files: "path: STATUS" lines, subtests below them indented with a tab ("name: STATUS")

escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]byte)s {
		switch c {
		case '\\': strings.write_string(&b, "\\\\")
		case '\n': strings.write_string(&b, "\\n")
		case '\r': strings.write_string(&b, "\\r")
		case '\t': strings.write_string(&b, "\\t")
		case: strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

unescape :: proc(s: string) -> string {
	if strings.index_byte(s, '\\') < 0 { return s }
	b := strings.builder_make()
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 'n': strings.write_byte(&b, '\n')
			case 'r': strings.write_byte(&b, '\r')
			case 't': strings.write_byte(&b, '\t')
			case: strings.write_byte(&b, s[i])
			}
			continue
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

Expect :: struct {
	status: string,               // "OK" or "OK|TIMEOUT"...
	subs:   map[string]string,
}

read_expectations :: proc(path: string, into: ^map[string]Expect) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return false }
	cur := ""
	for raw in strings.split_lines(string(data)) {
		if raw == "" || raw[0] == '#' { continue }
		line := strings.trim_right(raw, "\r")
		sub := line[0] == '\t'
		body := sub ? line[1:] : line
		k := strings.last_index(body, ": ")
		if k < 0 { continue }
		name, status := unescape(body[:k]), body[k + 2:]
		if sub {
			if cur == "" { continue }
			e := &into[cur]
			e.subs[name] = status
		} else {
			cur = name
			into[name] = Expect{status = status}
		}
	}
	return true
}

status_ok :: proc(expected, got: string) -> bool {
	for alt in strings.split(expected, "|", context.temp_allocator) { if alt == got { return true } }
	return false
}

// `messages`: what did not pass is followed by its message (results.txt, for whoever looks into a failure).
write_results :: proc(b: ^strings.Builder, results: []^Result, messages := false) {
	for r in results {
		if messages && r.status != "OK" && r.message != "" { fmt.sbprintfln(b, "%s: %s  # %s", escape(r.path), r.status, escape(r.message)) } else { fmt.sbprintfln(b, "%s: %s", escape(r.path), r.status) }
		subs := slice.clone(r.subs[:], context.temp_allocator)
		slice.sort_by(subs, proc(a, b: Sub) -> bool { return a.name < b.name })
		for s, i in subs {
			if i > 0 && subs[i - 1].name == s.name { continue }   // duplicate names: the first
			if messages && s.status != "PASS" && s.message != "" { fmt.sbprintfln(b, "\t%s: %s  # %s", escape(s.name), s.status, escape(s.message)) } else { fmt.sbprintfln(b, "\t%s: %s", escape(s.name), s.status) }
		}
	}
}

expect_file :: proc(folder: string) -> string {
	return filepath.join({opts.expect, strings.concatenate({folder, ".txt"}, context.temp_allocator)}, context.temp_allocator) or_else ""
}

reftest_expect_file :: proc(folder: string) -> string {
	return filepath.join({opts.expect, strings.concatenate({folder, ".reftest"}, context.temp_allocator)}, context.temp_allocator) or_else ""
}

// The results of reference tests beside those of testharness tests: "results.txt" -> "results.reftest.txt".
reftest_results_file :: proc(path: string) -> string {
	stem := strings.trim_suffix(path, filepath.ext(path))
	return strings.concatenate({stem, ".reftest.txt"})
}

////////////////////////////////
// Parent: children, aggregation, comparison

Child :: struct {
	process:  os.Process,
	tests:    []Test,
	list:     string,
	out:      string,
	started:  time.Tick,
	last_size: i64,
	last_grow: time.Tick,
	alive:    bool,
}

// The ports the expectations were recorded on (tools\wpt.ps1 on its default port): subtest names that print a URL
// ("Fetch http://127.0.0.1:8778/...") are compared under these ports whatever port this run's server has, so that
// runs on per-worktree ports (tools\test_all.ps1) and on the shared server match the same expectations.
WPT_RECORDED_PORT :: 8778

// A clone of `name` with the server's http and https ports (":N", ":N+1", not part of a longer number) written as the
// recorded ones.
canonical_ports :: proc(name: string) -> string {
	server_port := 0
	if i := strings.last_index_byte(opts.server, ':'); i >= 0 { server_port = atoi(opts.server[i + 1:]) }
	if server_port <= 0 || server_port == WPT_RECORDED_PORT || !strings.contains_rune(name, ':') { return strings.clone(name) }
	from := [2]string{fmt.tprintf(":%d", server_port), fmt.tprintf(":%d", server_port + 1)}
	to := [2]string{fmt.tprintf(":%d", WPT_RECORDED_PORT), fmt.tprintf(":%d", WPT_RECORDED_PORT + 1)}
	b := strings.builder_make()
	outer: for i := 0; i < len(name); {
		for f, k in from {
			end := i + len(f)
			if strings.has_prefix(name[i:], f) && (end == len(name) || name[end] < '0' || name[end] > '9') {
				strings.write_string(&b, to[k])
				i = end
				continue outer
			}
		}
		strings.write_byte(&b, name[i])
		i += 1
	}
	return strings.to_string(b)
}

parse_child_output :: proc(path: string, into: ^map[string]^Result) -> int {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return 0 }
	finished := 0
	cur: ^Result
	for raw in strings.split_lines(string(data)) {
		if raw == "" { continue }
		parts := strings.split(raw, "\t")
		switch parts[0] {
		case "T":
			if len(parts) < 5 { continue }
			cur = new(Result)
			cur.path = strings.clone(unescape(parts[1]))
			cur.status = strings.clone(parts[2])
			cur.ms = atoi(parts[3])
			cur.message = strings.clone(unescape(parts[4]))
		case "S":
			if cur == nil || len(parts) < 4 { continue }
			append(&cur.subs, Sub{canonical_ports(unescape(parts[1])), strings.clone(parts[2]), strings.clone(unescape(parts[3]))})
		case "E":
			if cur != nil { into[cur.path] = cur; finished += 1 }
			cur = nil
		}
	}
	return finished
}

child_start :: proc(c: ^Child, index: int, tests: []Test) -> bool {
	c.tests = tests
	logs := filepath.join({filepath.dir(opts.md != "" ? opts.md : "build/wpt/x"), "children"}, context.temp_allocator) or_else "children"
	os.make_directory_all(logs)
	c.list = fmt.aprintf("%s/list_%d.txt", logs, index)
	c.out = fmt.aprintf("%s/out_%d.txt", logs, index)
	b := strings.builder_make(context.temp_allocator)
	for t in tests { fmt.sbprintfln(&b, "%s\t%d\t%d\t%d", t.path, t.long ? 1 : 0, t.is_reftest ? 1 : 0, t.cap_ms) }
	_ = os.write_entire_file(c.list, strings.to_string(b))
	_ = os.write_entire_file(c.out, "")
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, opts.self, "-child", c.list, c.out, "-server", opts.server, "-timeout", fmt.tprint(opts.timeout_ms), "-idle", fmt.tprint(opts.idle_ms), "-root", opts.root)
	if opts.dump != "" { append(&cmd, "-dump", opts.dump) }
	if opts.dump_all { append(&cmd, "-dump-all") }
	append(&cmd, ..opts.prefs_args[:])
	logf, _ := os.create(fmt.tprintf("%s/log_%d.txt", logs, index))
	p, err := os.process_start({command = cmd[:], stdout = logf, stderr = logf})
	if logf != nil { os.close(logf) }
	if err != nil { fmt.eprintfln("wpt: cannot start a child: %v", err); return false }
	c.process = p
	c.started = time.tick_now()
	c.last_grow = c.started
	c.last_size = 0
	c.alive = true
	return true
}

parent_main :: proc() -> int {
	suites, ok := read_suites(opts.suites)
	if !ok { return 2 }
	if !os.exists(opts.root) { fmt.eprintfln("wpt: no checkout at %s (tools\\wpt.ps1 -Fetch)", opts.root); return 2 }
	if opts.reftests_only && opts.no_reftests { usage() }
	if opts.dump != "" && !dump_dir_allowed(opts.dump) { fmt.printfln("wpt: %s is inside a repository: pictures go elsewhere", opts.dump); return 2 }
	for f in opts.reftest_folders {
		known := false
		for s in suites { if s.folder == f { known = true } }
		if !known { append(&suites, Suite{folder = f, reftests_only = true}) }
	}
	all_tests := discover(suites[:])
	tests := make([dynamic]Test, 0, len(all_tests))
	extra := make(map[string]bool)
	for s in suites { if s.reftests_only { extra[s.folder] = true } }
	for t in all_tests {
		if t.is_reftest ? opts.no_reftests : (opts.reftests_only || t.folder in extra) { continue }
		append(&tests, t)
	}
	if opts.only != "" {
		kept := make([dynamic]Test)
		for t in tests { if strings.has_prefix(t.path, opts.only) || strings.has_prefix(t.path[1:], opts.only) { append(&kept, t) } }
		tests = kept
	}
	expected := make(map[string]Expect)
	for s in suites {
		read_expectations(expect_file(s.folder), &expected)
		read_expectations(reftest_expect_file(s.folder), &expected)
	}
	if opts.only_file != "" {
		// (the tests of the second chance of tools\wpt.ps1, all at once: looking for the tests takes seconds, for each)
		data, ferr := os.read_entire_file(opts.only_file, context.allocator)
		if ferr != nil { fmt.eprintfln("wpt: cannot read %s", opts.only_file); return 2 }
		wanted := make(map[string]bool)
		for line in strings.split_lines(string(data)) { if l := strings.trim_space(line); l != "" { wanted[l] = true } }
		kept := make([dynamic]Test)
		for t in tests { if t.path in wanted { append(&kept, t) } }
		tests = kept
	}
	if opts.quick {
		// a fixed sample: per folder, the first QUICK_PER_FOLDER tests (in path order), those not expected to time out
		// first (they say the most for the time they take)
		QUICK_PER_FOLDER :: 2
		kept := make([dynamic]Test)
		per := make(map[string]int)   // (by folder, and apart for its reference tests)
		taken := make(map[string]bool)
		for pass in 0 ..< 2 {
			for t in tests {
				key := t.is_reftest ? strings.concatenate({t.folder, " reftest"}) : t.folder
				if per[key] >= QUICK_PER_FOLDER || taken[t.path] { continue }
				if e, found := expected[t.path]; pass == 0 && found && (strings.contains(e.status, "TIMEOUT") || strings.contains(e.status, "CRASH")) { continue }
				append(&kept, t)
				taken[t.path] = true
				per[key] += 1
			}
		}
		slice.sort_by(kept[:], proc(a, b: Test) -> bool { return a.path < b.path })
		tests = kept
	}
	// (-only of one whole folder: that folder's expectations are rewritten)
	whole_folder := false
	for s in suites { if strings.trim(opts.only, "/") == s.folder { whole_folder = true } }
	if opts.update && (opts.quick || (opts.only != "" && !whole_folder)) { fmt.eprintln("wpt: -update needs a full run (no -quick, -only of one whole folder at most)"); return 2 }
	if opts.update && opts.timeout_cap_ms > 0 { fmt.eprintln("wpt: -update needs every test's whole time limit (no -timeout-cap)"); return 2 }
	if len(tests) == 0 { fmt.eprintln("wpt: no test"); return 2 }
	// A test expected to time out spends its whole limit waiting for what will not come (58 % of the time of a full run: 1300 tests, 50 of them
	// 60 s each), and what its expectations check came early if it came: it gets -timeout-cap ms. A subtest expected to pass that it has not
	// reached by then is a regression of this run, which tools\wpt.ps1 runs again with the whole limit: only a real regression counts. What
	// this does not see is a test that has begun to pass: -update and a run without the cap do.
	capped := 0
	if opts.timeout_cap_ms > 0 {
		for &t in tests {
			if e, found := expected[t.path]; found && strings.contains(e.status, "TIMEOUT") { t.cap_ms = opts.timeout_cap_ms; capped += 1 }
		}
	}
	if opts.list {
		// what a reference run in another browser needs: path, long timeout, folder
		// (testharness tests: that browser's reference run has no use for the others)
		for t in tests { if !t.is_reftest { fmt.printfln("%s\t%d\t%s", t.path, t.long ? 1 : 0, t.folder) } }
		return 0
	}
	fmt.printfln("%d tests in %d folders, %d at a time", len(tests), len(suites), opts.jobs)
	if capped > 0 { fmt.printfln("%d of them expected to time out: at most %d ms each (-timeout-cap)", capped, opts.timeout_cap_ms) }

	results := make(map[string]^Result)
	queue := make([dynamic][]Test)
	for i := 0; i < len(tests); i += opts.chunk { append(&queue, tests[i:min(i + opts.chunk, len(tests))]) }
	children := make([]Child, opts.jobs)
	next_index := 0
	t0 := time.tick_now()
	// A first child with no test: it compiles the engine and writes the disk cache (and its key) alone, the others read it.
	if opts.jobs > 1 {
		warm: Child
		if child_start(&warm, next_index, nil) { _, _ = os.process_wait(warm.process) }
		next_index += 1
	}
	hang_ms := f64(opts.timeout_ms) * LONG_TIMEOUT_FACTOR + CHILD_HANG_MARGIN_MS   // longer than any one test may take
	done_tests := 0
	for {
		running := 0
		for &c in children {
			if c.alive {
				state, werr := os.process_wait(c.process, 0)
				exited := werr == nil && state.exited
				if !exited {
					// a child hung (no result for longer than a test may take): killed, its test is a CRASH
					size: i64
					if fi, serr := os.stat(c.out, context.temp_allocator); serr == nil { size = fi.size }
					if size != c.last_size { c.last_size = size; c.last_grow = time.tick_now() }
					if time.duration_milliseconds(time.tick_since(c.last_grow)) > hang_ms {
						_ = os.process_kill(c.process)
						_, _ = os.process_wait(c.process)
						exited = true
					}
				}
				if exited {
					c.alive = false
					got := make(map[string]^Result, context.temp_allocator)
					n := parse_child_output(c.out, &got)
					for _, r in got { results[r.path] = r }
					done_tests += n
					rest := make([dynamic]Test)
					lost := false
					for t in c.tests {
						if t.path in got { continue }
						if !lost {
							// the test the child was running when it died
							lost = true
							r := new(Result)
							r.path = t.path
							r.status = "CRASH"
							r.message = fmt.aprintf("the test process ended (exit code %d) or stopped answering", state.exit_code)
							results[t.path] = r
							done_tests += 1
							continue
						}
						append(&rest, t)
					}
					if len(rest) > 0 { append(&queue, rest[:]) }
				}
			}
			if !c.alive && len(queue) > 0 {
				work := pop_front(&queue)
				if !child_start(&c, next_index, work) {
					for t in work {
						r := new(Result)
						r.path, r.status, r.message = t.path, "CRASH", "the test process could not start"
						results[t.path] = r
					}
					continue
				}
				next_index += 1
			}
			if c.alive { running += 1 }
		}
		if running == 0 && len(queue) == 0 { break }
		fmt.eprintf("%d/%d\r", done_tests, len(tests))
		time.sleep(50 * time.Millisecond)
	}
	elapsed := time.duration_seconds(time.tick_since(t0))
	return report(suites[:], tests[:], results, expected, elapsed)
}

Folder_Stats :: struct {
	files, files_ok, files_timeout, files_error, files_crash: int,
	subs, pass: int,
	regressions, improvements, new_tests: int,
	ref_subs, ref_pass, both_pass: int,   // the reference run (Edge): its subtests, its passes, those Wren passes too
}

// Reference tests of a folder: one result each, counted apart.
Reftest_Stats :: struct {
	tests, pass, fail, timeout, error, crash: int,
	regressions, improvements, new_tests: int,
}

report :: proc(suites: []Suite, tests: []Test, results: map[string]^Result, expected: map[string]Expect, elapsed: f64) -> int {
	stats := make(map[string]Folder_Stats)
	reference := make(map[string]Expect)
	have_ref := opts.reference != "" && read_expectations(opts.reference, &reference)
	regress := strings.builder_make()
	better := strings.builder_make()
	by_folder := make(map[string][dynamic]^Result)
	ref_stats := make(map[string]Reftest_Stats)
	ref_by_folder := make(map[string][dynamic]^Result)
	for t in tests {
		r, found := results[t.path]
		if !found { continue }
		if t.is_reftest {
			rs := ref_stats[t.folder]
			rs.tests += 1
			switch r.status {
			case STATUS_PASS: rs.pass += 1
			case STATUS_FAIL: rs.fail += 1
			case STATUS_TIMEOUT: rs.timeout += 1
			case "CRASH": rs.crash += 1
			case: rs.error += 1
			}
			if e, has := expected[t.path]; has {
				if status_ok(e.status, STATUS_PASS) && !status_ok(e.status, r.status) {
					rs.regressions += 1
					fmt.sbprintfln(&regress, "REGRESSION %s: %s (expected %s) %s", t.path, r.status, e.status, r.message)
				} else if r.status == STATUS_PASS && !status_ok(e.status, STATUS_PASS) {
					rs.improvements += 1
					fmt.sbprintfln(&better, "better %s: PASS (expected %s)", t.path, e.status)
				}
			} else {
				rs.new_tests += 1
			}
			ref_stats[t.folder] = rs
			list := ref_by_folder[t.folder]
			append(&list, r)
			ref_by_folder[t.folder] = list
			continue
		}
		st := stats[t.folder]
		st.files += 1
		switch r.status {
		case "OK": st.files_ok += 1
		case "TIMEOUT": st.files_timeout += 1
		case "CRASH": st.files_crash += 1
		case: st.files_error += 1
		}
		seen := make(map[string]string, context.temp_allocator)
		for s in r.subs {
			if s.name in seen { continue }
			seen[s.name] = s.status
			st.subs += 1
			if s.status == "PASS" { st.pass += 1 }
		}
		if ref, has_ref := reference[t.path]; has_ref {
			for name, s in ref.subs {
				st.ref_subs += 1
				if s == "PASS" {
					st.ref_pass += 1
					if seen[name] == "PASS" { st.both_pass += 1 }
				}
			}
		}
		if e, has := expected[t.path]; has {
			if status_ok(e.status, "OK") && !status_ok(e.status, r.status) {
				st.regressions += 1
				fmt.sbprintfln(&regress, "REGRESSION %s: %s (expected %s) %s", t.path, r.status, e.status, r.message)
			} else if !status_ok(e.status, r.status) && r.status == "OK" {
				st.improvements += 1
				fmt.sbprintfln(&better, "better %s: %s (expected %s)", t.path, r.status, e.status)
			}
			for name, want in e.subs {
				got, present := seen[name]
				if !present { got = "MISSING" }
				if status_ok(want, "PASS") && got != "PASS" && !status_ok(want, got) {
					st.regressions += 1
					fmt.sbprintfln(&regress, "REGRESSION %s | %s: %s (expected %s)", t.path, name, got, want)
				}
			}
			for name, got in seen {
				want, known := e.subs[name]
				if got == "PASS" && (!known || !status_ok(want, "PASS")) {
					st.improvements += 1
					fmt.sbprintfln(&better, "better %s | %s: PASS (expected %s)", t.path, name, known ? want : "nothing")
				}
			}
		} else {
			st.new_tests += 1
		}
		stats[t.folder] = st
		list := by_folder[t.folder]
		append(&list, r)
		by_folder[t.folder] = list
	}

	// the tables: testharness tests, then reference tests, which never count together
	md := strings.builder_make()
	if have_ref {
		fmt.sbprintln(&md, "| folder | tests | OK | TIMEOUT | ERROR | CRASH | subtests | PASS | pass rate | Edge subtests | Edge PASS | Wren PASS / Edge PASS | regressions |")
		fmt.sbprintln(&md, "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
	} else {
		fmt.sbprintln(&md, "| folder | tests | OK | TIMEOUT | ERROR | CRASH | subtests | PASS | pass rate | regressions |")
		fmt.sbprintln(&md, "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
	}
	total: Folder_Stats
	for s in suites {
		st := stats[s.folder]
		if st.files == 0 && (opts.only != "" || opts.reftests_only || s.reftests_only) { continue }
		rate := st.subs > 0 ? 100 * f64(st.pass) / f64(st.subs) : 0
		if have_ref {
			rr := st.ref_pass > 0 ? 100 * f64(st.both_pass) / f64(st.ref_pass) : 0
			fmt.sbprintfln(&md, "| %s | %d | %d | %d | %d | %d | %d | %d | %.1f %% | %d | %d | %.1f %% | %d |", s.folder, st.files, st.files_ok, st.files_timeout, st.files_error, st.files_crash, st.subs, st.pass, rate, st.ref_subs, st.ref_pass, rr, st.regressions)
		} else {
			fmt.sbprintfln(&md, "| %s | %d | %d | %d | %d | %d | %d | %d | %.1f %% | %d |", s.folder, st.files, st.files_ok, st.files_timeout, st.files_error, st.files_crash, st.subs, st.pass, rate, st.regressions)
		}
		total.files += st.files; total.files_ok += st.files_ok; total.files_timeout += st.files_timeout; total.files_error += st.files_error
		total.files_crash += st.files_crash; total.subs += st.subs; total.pass += st.pass; total.regressions += st.regressions
		total.improvements += st.improvements; total.new_tests += st.new_tests
		total.ref_subs += st.ref_subs; total.ref_pass += st.ref_pass; total.both_pass += st.both_pass
	}
	trate := total.subs > 0 ? 100 * f64(total.pass) / f64(total.subs) : 0
	if have_ref {
		trr := total.ref_pass > 0 ? 100 * f64(total.both_pass) / f64(total.ref_pass) : 0
		fmt.sbprintfln(&md, "| **total** | **%d** | **%d** | **%d** | **%d** | **%d** | **%d** | **%d** | **%.1f %%** | **%d** | **%d** | **%.1f %%** | **%d** |", total.files, total.files_ok, total.files_timeout, total.files_error, total.files_crash, total.subs, total.pass, trate, total.ref_subs, total.ref_pass, trr, total.regressions)
	} else {
		fmt.sbprintfln(&md, "| **total** | **%d** | **%d** | **%d** | **%d** | **%d** | **%d** | **%d** | **%.1f %%** | **%d** |", total.files, total.files_ok, total.files_timeout, total.files_error, total.files_crash, total.subs, total.pass, trate, total.regressions)
	}
	// (no testharness test ran, as with -reftests: its table says nothing)
	if total.files == 0 { strings.builder_reset(&md) }
	fmt.sbprintfln(&md, "\n%d testharness tests in %.0f s (%d at a time, -timeout %d ms); %d improvement(s) over the expectations, %d test(s) without expectations.",
		total.files, elapsed, opts.jobs, opts.timeout_ms, total.improvements, total.new_tests)
	ref_total: Reftest_Stats
	for s in suites {
		rs := ref_stats[s.folder]
		if rs.tests == 0 { continue }
		if ref_total.tests == 0 {
			fmt.sbprintln(&md, "\n| folder (reference tests) | tests | PASS | FAIL | TIMEOUT | ERROR | CRASH | pass rate | regressions |")
			fmt.sbprintln(&md, "|---|---:|---:|---:|---:|---:|---:|---:|---:|")
		}
		fmt.sbprintfln(&md, "| %s | %d | %d | %d | %d | %d | %d | %.1f %% | %d |", s.folder, rs.tests, rs.pass, rs.fail, rs.timeout, rs.error, rs.crash, 100 * f64(rs.pass) / f64(rs.tests), rs.regressions)
		ref_total.tests += rs.tests; ref_total.pass += rs.pass; ref_total.fail += rs.fail; ref_total.timeout += rs.timeout; ref_total.error += rs.error; ref_total.crash += rs.crash
		ref_total.regressions += rs.regressions; ref_total.improvements += rs.improvements; ref_total.new_tests += rs.new_tests
	}
	if ref_total.tests > 0 {
		fmt.sbprintfln(&md, "| **total** | **%d** | **%d** | **%d** | **%d** | **%d** | **%d** | **%.1f %%** | **%d** |", ref_total.tests, ref_total.pass, ref_total.fail, ref_total.timeout, ref_total.error, ref_total.crash, 100 * f64(ref_total.pass) / f64(ref_total.tests), ref_total.regressions)
	}
	fmt.sbprintfln(&md, "\n%d reference tests: %d PASS, %d not; %d improvement(s) over the expectations, %d test(s) without expectations.",
		ref_total.tests, ref_total.pass, ref_total.tests - ref_total.pass, ref_total.improvements, ref_total.new_tests)
	fmt.print(strings.to_string(md))
	if opts.md != "" { _ = os.write_entire_file(opts.md, strings.to_string(md)) }
	if strings.builder_len(regress) > 0 { fmt.print(strings.to_string(regress)) }
	if strings.builder_len(better) > 0 {
		lines := strings.split_lines(strings.to_string(better), context.temp_allocator)
		for l, i in lines { if i < 40 && l != "" { fmt.println(l) } }
		if len(lines) > 41 { fmt.printfln("... and %d more improvements", len(lines) - 41) }
	}

	if opts.results != "" {
		b := strings.builder_make()
		for s in suites {
			list := by_folder[s.folder]
			slice.sort_by(list[:], proc(a, b: ^Result) -> bool { return a.path < b.path })
			write_results(&b, list[:], messages = true)
		}
		_ = os.write_entire_file(opts.results, strings.to_string(b))
		rb := strings.builder_make()
		for s in suites {
			list := ref_by_folder[s.folder]
			slice.sort_by(list[:], proc(a, b: ^Result) -> bool { return a.path < b.path })
			write_results(&rb, list[:], messages = true)
		}
		if ref_total.tests > 0 { _ = os.write_entire_file(reftest_results_file(opts.results), strings.to_string(rb)) }
	}
	if opts.update {
		for s in suites {
			if opts.only != "" && strings.trim(opts.only, "/") != s.folder { continue }
			if len(ref_by_folder[s.folder]) > 0 {
				list := ref_by_folder[s.folder]
				slice.sort_by(list[:], proc(a, b: ^Result) -> bool { return a.path < b.path })
				b := strings.builder_make()
				fmt.sbprintfln(&b, "# web-platform-tests reference tests of Wren for %s, written by tools\\wpt.ps1 -Update", s.folder)
				fmt.sbprintln(&b, "# <test>: PASS|FAIL|TIMEOUT|ERROR|CRASH; \"A|B\" accepts either")
				write_results(&b, list[:])
				path := reftest_expect_file(s.folder)
				_ = os.make_directory_all(filepath.dir(path))
				_ = os.write_entire_file(path, strings.to_string(b))
			}
			if opts.reftests_only || s.reftests_only { continue }
			list := by_folder[s.folder]
			slice.sort_by(list[:], proc(a, b: ^Result) -> bool { return a.path < b.path })
			b := strings.builder_make()
			fmt.sbprintfln(&b, "# web-platform-tests expectations of Wren for %s, written by tools\\wpt.ps1 -Update", s.folder)
			fmt.sbprintln(&b, "# <test>: OK|ERROR|TIMEOUT|CRASH|PRECONDITION_FAILED, then its subtests (tab): PASS|FAIL|TIMEOUT|NOTRUN|PRECONDITION_FAILED; \"A|B\" accepts either")
			write_results(&b, list[:])
			path := expect_file(s.folder)
			_ = os.make_directory_all(filepath.dir(path))
			_ = os.write_entire_file(path, strings.to_string(b))
		}
		fmt.printfln("expectations written in %s", opts.expect)
		return 0
	}
	fmt.printfln("%d regression(s)", total.regressions + ref_total.regressions)
	return total.regressions + ref_total.regressions > 0 ? 1 : 0
}

////////////////////////////////
// Child: the tests of a list, one page each

Child_State :: struct {
	result_json: string,   // the WPTRESULT payload, owned
	got:         bool,
	forced:      bool,     // the runner's timeout() call returned (WPTFORCED)
	first_error: string,   // owned: the first error the console showed (the reason when there is no result)
	layout:      ^Layout_Host,   // tests that read geometry (layout_host.odin), nil: no layout
}

child_on_console :: proc(d: ^headless.Doc, level: page.Log_Level, text: string) {
	cs := (^Child_State)(d.user)
	if strings.has_prefix(text, "WPTRESULT ") && !cs.got {
		cs.result_json = strings.clone(text[len("WPTRESULT "):])
		cs.got = true
		return
	}
	if text == "WPTFORCED" { cs.forced = true; return }
	// WPT_CONSOLE=1: every console message of the tests on stderr (to see why one times out)
	if os.get_env("WPT_CONSOLE", context.temp_allocator) != "" { fmt.eprintfln("console %v: %s", level, text) }
	if level == .Error && cs.first_error == "" { cs.first_error = strings.clone(text) }
}

got_result :: proc(d: ^headless.Doc) -> bool { return (^Child_State)(d.user).got }

PUMP_SLICE_MS :: 20
PUMP_BUSY_MS :: 200

FORCE_TIMEOUT :: `(function () { try { if (typeof timeout === "function") { timeout(); } } catch (e) {} console.log("WPTFORCED"); })();`

// Whether the page can still do anything by itself: false once loaded with no timer, request (any load of the page's: a module or
// a stylesheet that takes more than the idle time is no idle page), frame, worker, background
// job or media playing / loading.
page_busy :: proc(p: ^page.Page) -> bool {
	if p == nil || p.closed { return false }
	if p.scripts != nil && p.scripts.ready_state != .Complete { return true }
	return p.timers.count > 0 || p.fetches.count > 0 || fetch.in_flight(p.loader) > 0 || page.wants_animation_frame(p) || len(p.workers.hosts) > 0 || page.shared_workers_live() > 0 || len(p.offthread.jobs) > 0 || p.crypto_jobs > 0 || page.media_busy(p) || page.idb_busy(p)
}

HARNESS_STATUS := [?]string{"OK", "ERROR", "TIMEOUT", "PRECONDITION_FAILED"}
TEST_STATUS := [?]string{"PASS", "FAIL", "TIMEOUT", "NOTRUN", "PRECONDITION_FAILED"}

json_int :: proc(v: json.Value) -> int {
	#partial switch x in v {
	case json.Integer: return int(x)
	case json.Float: return int(x)
	}
	return -1
}

json_str :: proc(v: json.Value) -> string {
	#partial switch x in v {
	case json.String: return string(x)
	}
	return ""
}

// The JavaScript engine compiled and started once before the first test's time limit starts: measured in a full run, the first test
// of a child took 5.9 s (median; p90 13 s, past the 10 s limit) and the others 58 ms, so a child's first test timed out under load
// whatever it tested.
warm_up :: proc(env: ^headless.Env) {
	p := page.page_create(&env.loop, &env.loader, &env.settings, env.process, "about:blank", proc(user: rawptr, level: page.Log_Level, message: string) {})
	page.js_run(p, nil, "wpt-warm-up.js")
	page.page_close(p)
}

child_main :: proc(list_path, out_path: string) -> int {
	prefs := config.prefs_make()
	page.register_prefs(&prefs)
	rest, errs := config.apply_args(&prefs, opts.prefs_args[:])
	for e in errs { fmt.eprintln("wpt:", e) }
	_ = rest
	// The engine's compiled code on disk, shared by the children of a run (and the next run): compiling it takes a child 6 s, 13 s
	// under load, a good part of a full run with 350 children.
	wasm.configure_from_args(opts.prefs_args[:], filepath.dir(out_path))
	env: headless.Env
	if !headless.init(&env, &prefs, fmt.tprintf("%s.profile", out_path)) { fmt.eprintln("wpt: the page stack could not start"); return 2 }
	// A script gets the time its test gets: wpt.ps1's second chance gives more of it, and a harness running one long task (idlharness)
	// was stopped at 10 s whatever the limit, and regressed twice.
	env.settings.js.slow_script_ms = i64(opts.timeout_ms)
	js.cache_start({memory_bytes = 64 << 20, min_source_bytes = 0})
	warm_up(&env)
	data, err := os.read_entire_file(list_path, context.allocator)
	if err != nil { return 2 }
	out, oerr := os.open(out_path, {.Write, .Append, .Create})
	if oerr != nil { return 2 }
	reftests_child_begin(&env)
	for line in strings.split_lines(string(data)) {
		if line == "" { continue }
		parts := strings.split(line, "\t", context.temp_allocator)
		path := parts[0]
		long := len(parts) > 1 && parts[1] == "1"
		if len(parts) > 2 && parts[2] == "1" { reftest_one(out, path, long); continue }
		limit := f64(opts.timeout_ms) * (long ? LONG_TIMEOUT_FACTOR : 1)
		if len(parts) > 3 && atoi(parts[3]) > 0 { limit = min(limit, f64(atoi(parts[3]))) }
		cs: Child_State
		t0 := time.tick_now()
		if wants_layout(path) { cs.layout = host_make() }
		defer host_destroy(cs.layout)
		d := headless.open(&env, strings.concatenate({opts.server, path}, context.temp_allocator), child_on_console, &cs)
		d.on_parsed = host_attach
		// until the report, the time limit, or a page that can no longer do anything
		idle_since: time.Tick
		idle := false
		for !cs.got {
			slice_start := time.tick_now()
			headless.pump(d, PUMP_SLICE_MS, got_result)
			if cs.got || d.failed != "" { break }
			ms := time.duration_milliseconds(time.tick_since(t0))
			if ms >= limit { break }
			// a slice that took far longer than asked ran something, however idle the page looks now: a long chain of microtasks
			// (dynamic-import/microtasks/basic.any.html, 1e6 of them) leaves no timer nor request, and the module it awaits had
			// not been asked for yet: it was taken for an idle page and stopped as soon as its chain ended
			if time.duration_milliseconds(time.tick_since(slice_start)) > PUMP_BUSY_MS { idle = false; continue }
			if opts.idle_ms > 0 && headless.loaded(d) && !page_busy(d.page) {
				if !idle { idle = true; idle_since = time.tick_now() }
				if time.duration_milliseconds(time.tick_since(idle_since)) >= f64(opts.idle_ms) { break }
			} else {
				idle = false
			}
		}
		forced := false
		if !cs.got && d.failed == "" && d.page != nil && !d.page.closed {
			// testharness.js's timeout(): the harness reports what it has, as wptrunner's timeout does
			forced = true
			page.js_run(d.page, transmute([]byte)string(FORCE_TIMEOUT), "wpt-runner.js")
			// the report comes from timeout() itself, or from a task or microtask it queued; nothing comes when the
			// harness never started (an API it needs is missing)
			headless.pump(d, cs.forced ? 500 : 2000, got_result)
		}
		ms := int(time.duration_milliseconds(time.tick_since(t0)))
		b := strings.builder_make(context.temp_allocator)
		if cs.got {
			v, jerr := json.parse_string(cs.result_json, allocator = context.temp_allocator)
			if jerr != nil {
				fmt.sbprintfln(&b, "T\t%s\tERROR\t%d\t%s", escape(path), ms, escape("the report is not JSON"))
			} else {
				obj, _ := v.(json.Object)
				hs := json_int(obj["status"])
				status := hs >= 0 && hs < len(HARNESS_STATUS) ? HARNESS_STATUS[hs] : "ERROR"
				if forced && status == "OK" { status = "TIMEOUT" }
				fmt.sbprintfln(&b, "T\t%s\t%s\t%d\t%s", escape(path), status, ms, escape(json_str(obj["message"])))
				if arr, isarr := obj["tests"].(json.Array); isarr {
					for tv in arr {
						to, _ := tv.(json.Object)
						ts := json_int(to["status"])
						tstatus := ts >= 0 && ts < len(TEST_STATUS) ? TEST_STATUS[ts] : "FAIL"
						fmt.sbprintfln(&b, "S\t%s\t%s\t%s", escape(json_str(to["name"])), tstatus, escape(json_str(to["message"])))
					}
				}
			}
		} else if d.failed != "" {
			fmt.sbprintfln(&b, "T\t%s\tERROR\t%d\t%s", escape(path), ms, escape(fmt.tprintf("the page did not load: %s", d.failed)))
		} else {
			why := cs.first_error != "" ? cs.first_error : "no result from testharness.js"
			fmt.sbprintfln(&b, "T\t%s\tTIMEOUT\t%d\t%s", escape(path), ms, escape(why))
		}
		fmt.sbprintln(&b, "E")
		os.write_string(out, strings.to_string(b))
		os.flush(out)
		headless.close(d)
		delete(cs.result_json)
		delete(cs.first_error)
		free_all(context.temp_allocator)
	}
	os.close(out)
	headless.destroy(&env)
	js.cache_stop()
	wasm.runtime_destroy()   // (waits for the disk cache's writer)
	return 0
}
