// wpt: a pinned subset of web-platform-tests in Wren without a window: one page per test (the document loaded as the
// browser loads it, src/tools/headless), testharness.js and Wren's testharnessreport.js (wpt/), which hands the results
// to this tool as one console message. tools\wpt.ps1 fetches the pinned checkout and runs this tool against the test
// server (tools/testserver/wpt.go, http://127.0.0.1:8768/).
//
//   wpt [-root build/wpt/wpt] [-suites wpt/suites.txt] [-expect wpt/expectations] [-server http://127.0.0.1:8768]
//       [-timeout ms] [-idle ms] [-jobs n] [-quick] [-update] [-md report.md] [-results results.txt] [-only prefix]
//       [-reference edge_results.txt] [-list] [--pref name=value]...
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
package wpt

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "wb:config"
import "wb:host"
import "wb:js"
import "wb:page"
import "wb:wasm"
import "wb:tools/headless"

Test :: struct {
	folder: string,   // the suite folder it belongs to ("dom/nodes")
	path:   string,   // URL path with its variant ("/dom/nodes/x.any.html?a")
	long:   bool,     // <meta name=timeout content=long> / META: timeout=long
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
}

Options :: struct {
	root, suites, expect, server, md, results, only, self, reference: string,
	timeout_ms, idle_ms, jobs, chunk: int,
	quick, update, list: bool,
	prefs_args: [dynamic]string,
}

opts: Options

main :: proc() {
	opts = {
		root = "build/wpt/wpt", suites = "wpt/suites.txt", expect = "wpt/expectations", server = "http://127.0.0.1:8768",
		timeout_ms = 10_000, idle_ms = 1000, jobs = max(1, host.processor_count() / 2), chunk = 25, self = os.args[0],
	}
	args := os.args[1:]
	if len(args) >= 3 && args[0] == "-child" {
		parse_options(args[3:])
		os.exit(child_main(args[1], args[2]))
	}
	parse_options(args)
	os.exit(parent_main())
}

usage :: proc() -> ! {
	fmt.eprintln("usage: wpt [-root dir] [-suites file] [-expect dir] [-server url] [-timeout ms] [-idle ms] [-jobs n] [-quick] [-update] [-md file] [-results file] [-only prefix] [--pref name=value]...")
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
		case "-jobs": opts.jobs = max(1, atoi(need(args, &i)))
		case "-chunk": opts.chunk = max(1, atoi(need(args, &i)))
		case "-quick": opts.quick = true
		case "-update": opts.update = true
		case "-md": opts.md = need(args, &i)
		case "-results": opts.results = need(args, &i)
		case "-only": opts.only = need(args, &i)
		case "-list": opts.list = true
		case "-reference": opts.reference = need(args, &i)
		case "--pref": append(&opts.prefs_args, "--pref", need(args, &i))
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

add_test :: proc(out: ^[dynamic]Test, folder, path: string, variants: []string, long: bool) {
	if len(variants) == 0 { append(out, Test{folder, strings.clone(path), long}); return }
	for v in variants { append(out, Test{folder, strings.concatenate({path, v}), long}) }
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
			if !has_testharness(text) || is_reftest(text) { continue }
			vars := make([dynamic]string, context.temp_allocator)
			variants_html(text, &vars)
			long := strings.contains(text, "name=\"timeout\" content=\"long\"") || strings.contains(text, "name=timeout content=long")
			add_test(out, folder, url_path, vars[:], long)
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

write_results :: proc(b: ^strings.Builder, results: []^Result) {
	for r in results {
		fmt.sbprintfln(b, "%s: %s", escape(r.path), r.status)
		subs := slice.clone(r.subs[:], context.temp_allocator)
		slice.sort_by(subs, proc(a, b: Sub) -> bool { return a.name < b.name })
		for s, i in subs {
			if i > 0 && subs[i - 1].name == s.name { continue }   // duplicate names: the first
			fmt.sbprintfln(b, "\t%s: %s", escape(s.name), s.status)
		}
	}
}

expect_file :: proc(folder: string) -> string {
	return filepath.join({opts.expect, strings.concatenate({folder, ".txt"}, context.temp_allocator)}, context.temp_allocator) or_else ""
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
			append(&cur.subs, Sub{strings.clone(unescape(parts[1])), strings.clone(parts[2]), strings.clone(unescape(parts[3]))})
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
	for t in tests { fmt.sbprintfln(&b, "%s\t%d", t.path, t.long ? 1 : 0) }
	_ = os.write_entire_file(c.list, strings.to_string(b))
	_ = os.write_entire_file(c.out, "")
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, opts.self, "-child", c.list, c.out, "-server", opts.server, "-timeout", fmt.tprint(opts.timeout_ms), "-idle", fmt.tprint(opts.idle_ms))
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
	tests := discover(suites[:])
	if opts.only != "" {
		kept := make([dynamic]Test)
		for t in tests { if strings.has_prefix(t.path, opts.only) || strings.has_prefix(t.path[1:], opts.only) { append(&kept, t) } }
		tests = kept
	}
	expected := make(map[string]Expect)
	for s in suites { read_expectations(expect_file(s.folder), &expected) }
	if opts.quick {
		// a fixed sample: per folder, the first QUICK_PER_FOLDER tests (in path order), those not expected to time out
		// first (they say the most for the time they take)
		QUICK_PER_FOLDER :: 2
		kept := make([dynamic]Test)
		per := make(map[string]int)
		taken := make(map[string]bool)
		for pass in 0 ..< 2 {
			for t in tests {
				if per[t.folder] >= QUICK_PER_FOLDER || taken[t.path] { continue }
				if e, found := expected[t.path]; pass == 0 && found && (strings.contains(e.status, "TIMEOUT") || strings.contains(e.status, "CRASH")) { continue }
				append(&kept, t)
				taken[t.path] = true
				per[t.folder] += 1
			}
		}
		slice.sort_by(kept[:], proc(a, b: Test) -> bool { return a.path < b.path })
		tests = kept
	}
	if opts.update && (opts.quick || opts.only != "") { fmt.eprintln("wpt: -update needs a full run (no -quick, no -only)"); return 2 }
	if len(tests) == 0 { fmt.eprintln("wpt: no test"); return 2 }
	if opts.list {
		// what a reference run in another browser needs: path, long timeout, folder
		for t in tests { fmt.printfln("%s\t%d\t%s", t.path, t.long ? 1 : 0, t.folder) }
		return 0
	}
	fmt.printfln("%d tests in %d folders, %d at a time", len(tests), len(suites), opts.jobs)

	results := make(map[string]^Result)
	queue := make([dynamic][]Test)
	for i := 0; i < len(tests); i += opts.chunk { append(&queue, tests[i:min(i + opts.chunk, len(tests))]) }
	children := make([]Child, opts.jobs)
	next_index := 0
	t0 := time.tick_now()
	hang_ms := f64(opts.timeout_ms) * 6 + 30_000   // longer than any one test may take
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

report :: proc(suites: []Suite, tests: []Test, results: map[string]^Result, expected: map[string]Expect, elapsed: f64) -> int {
	stats := make(map[string]Folder_Stats)
	reference := make(map[string]Expect)
	have_ref := opts.reference != "" && read_expectations(opts.reference, &reference)
	regress := strings.builder_make()
	better := strings.builder_make()
	by_folder := make(map[string][dynamic]^Result)
	for t in tests {
		r, found := results[t.path]
		if !found { continue }
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
			if status_ok(e.status, "OK") && r.status != "OK" {
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

	// the table
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
		if st.files == 0 && opts.only != "" { continue }
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
	fmt.sbprintfln(&md, "\n%d tests in %.0f s (%d at a time, -timeout %d ms); %d improvement(s) over the expectations, %d test(s) without expectations.",
		total.files, elapsed, opts.jobs, opts.timeout_ms, total.improvements, total.new_tests)
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
			write_results(&b, list[:])
		}
		_ = os.write_entire_file(opts.results, strings.to_string(b))
	}
	if opts.update {
		for s in suites {
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
	fmt.printfln("%d regression(s)", total.regressions)
	return total.regressions > 0 ? 1 : 0
}

////////////////////////////////
// Child: the tests of a list, one page each

Child_State :: struct {
	result_json: string,   // the WPTRESULT payload, owned
	got:         bool,
	forced:      bool,     // the runner's timeout() call returned (WPTFORCED)
	first_error: string,   // owned: the first error the console showed (the reason when there is no result)
}

child_on_console :: proc(d: ^headless.Doc, level: page.Log_Level, text: string) {
	cs := (^Child_State)(d.user)
	if strings.has_prefix(text, "WPTRESULT ") && !cs.got {
		cs.result_json = strings.clone(text[len("WPTRESULT "):])
		cs.got = true
		return
	}
	if text == "WPTFORCED" { cs.forced = true; return }
	if level == .Error && cs.first_error == "" { cs.first_error = strings.clone(text) }
}

got_result :: proc(d: ^headless.Doc) -> bool { return (^Child_State)(d.user).got }

FORCE_TIMEOUT :: `(function () { try { if (typeof timeout === "function") { timeout(); } } catch (e) {} console.log("WPTFORCED"); })();`

// Whether the page can still do anything by itself: false once loaded with no timer, request, frame, worker or
// background job.
page_busy :: proc(p: ^page.Page) -> bool {
	if p == nil || p.closed { return false }
	if p.scripts != nil && p.scripts.ready_state != .Complete { return true }
	return p.timers.count > 0 || p.fetches.count > 0 || page.wants_animation_frame(p) || len(p.workers.hosts) > 0 || len(p.offthread.jobs) > 0
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

child_main :: proc(list_path, out_path: string) -> int {
	prefs := config.prefs_make()
	page.register_prefs(&prefs)
	rest, errs := config.apply_args(&prefs, opts.prefs_args[:])
	for e in errs { fmt.eprintln("wpt:", e) }
	_ = rest
	wasm.configure_from_args(opts.prefs_args[:])
	env: headless.Env
	if !headless.init(&env, &prefs, fmt.tprintf("%s.profile", out_path)) { fmt.eprintln("wpt: the page stack could not start"); return 2 }
	js.cache_start({memory_bytes = 64 << 20, min_source_bytes = 0})
	data, err := os.read_entire_file(list_path, context.allocator)
	if err != nil { return 2 }
	out, oerr := os.open(out_path, {.Write, .Append, .Create})
	if oerr != nil { return 2 }
	for line in strings.split_lines(string(data)) {
		if line == "" { continue }
		parts := strings.split(line, "\t", context.temp_allocator)
		path := parts[0]
		long := len(parts) > 1 && parts[1] == "1"
		limit := f64(opts.timeout_ms) * (long ? 6 : 1)
		cs: Child_State
		t0 := time.tick_now()
		d := headless.open(&env, strings.concatenate({opts.server, path}, context.temp_allocator), child_on_console, &cs)
		// until the report, the time limit, or a page that can no longer do anything
		idle_since: time.Tick
		idle := false
		for !cs.got {
			headless.pump(d, 20, got_result)
			if cs.got || d.failed != "" { break }
			ms := time.duration_milliseconds(time.tick_since(t0))
			if ms >= limit { break }
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
	return 0
}
