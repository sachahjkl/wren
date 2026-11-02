package test_all

import "core:fmt"
import "core:os"
import "core:strings"
import "core:text/regex"
import "core:time"
import "wb:tools/tooling"

// The actions a program of their own would only wrap: done on a thread of this one.

task_js_engine :: proc(t: ^Task_Run) -> bool {
	return tooling.build_js_engine({log = t.log})
}

// build/wren.com, when a source is newer than it (a test that runs it holds the file: two steps must not both write it).
task_launcher :: proc(t: ^Task_Run) -> bool {
	OUT :: "build/wren.com"
	odin_source :: proc(path: string) -> bool { return strings.has_suffix(path, ".odin") }
	if built, ok := tooling.modified(OUT); ok && !tooling.any_newer("src/tools/wrencom", built, odin_source) { return true }
	return task_exec(t, {"odin", "build", "src/tools/wrencom", "-vet", "-subsystem:console", "-o:size", out_flag(OUT), "-extra-linker-flags:/NODEFAULTLIB:vcruntime.lib /DEFAULTLIB:libvcruntime.lib"}) == 0
}

// Is the program of this variant newer than everything it is built from? (The build takes a minute even when nothing changed: Odin compiles the whole program every time.) The sources of the browser and of the
// toolkit, not their tests; the libraries and the engine's image it links or embeds.
browser_fresh :: proc(program: string) -> bool {
	built, ok := tooling.modified(program)
	if !ok { return false }
	for f in ([]string{"build.bat", "odin.version", "build/js/wren_js.wasm", "build/lexbor/lexbor.lib", "build/native/wren_native.lib"}) {
		t, has := tooling.modified(f)
		if !has || time.diff(built, t) > 0 { return false }
	}
	keep :: proc(path: string) -> bool {
		if !tooling.is_source_of_a_program(path) { return false }
		p, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
		return !strings.contains(p, "/src/tools/e2e/") && !strings.contains(p, "/src/e2e/") && !strings.has_prefix(p, "src/tools/e2e/") && !strings.has_prefix(p, "src/e2e/")
	}
	for dir in ([]string{"src", "ext/gui_toolkit", "api", "sdk"}) {
		if tooling.any_newer(dir, built, keep) { return false }
	}
	return true
}

task_browser :: proc(t: ^Task_Run) -> bool {
	program := t.arg == "check" ? "build/wren_check.exe" : "build/wren.exe"
	if browser_fresh(program) { return true }
	return task_exec(t, {"cmd", "/c", ".\\build.bat", t.arg}) == 0   // (.\: with NoDefaultCurrentDirectoryInExePath in the environment cmd looks only on the PATH)
}

task_testserver :: proc(t: ^Task_Run) -> bool {
	return tooling.ensure_testserver(t.log)
}

// A runner of the suites, its compile kept while nothing changed (-Quick: one module per package, seconds instead of a minute; the whole-program build pays off on a full run). `arg`: its folder of src/tools, and "quick".
// (No linker flag for the stack: a runner runs its scripts on threads it makes with the stack they need, tooling.JS_THREAD_STACK_BYTES.)
task_runner :: proc(t: ^Task_Run) -> bool {
	fields := strings.fields(t.arg, context.temp_allocator)
	name := fields[0]
	quick := len(fields) > 1
	out := exe(fmt.tprintf("build/%s", name))
	flags := fmt.tprintf("%s %v own-stack", name, quick)
	cmd := join({tooling.odin_program(), "build", fmt.tprintf("src/tools/%s", name), WB, "-vet", "-o:speed", out_flag(out)}, quick ? []string{"-use-separate-modules"} : nil)
	return tooling.build_if_stale(out, flags, cmd, t.log)
}

// No runtime.default_context / heap_allocator / default_allocator outside src/base/memory.odin.
task_process_allocators :: proc(t: ^Task_Run) -> bool {
	PATTERNS := []string{"runtime.default_context()", "runtime.heap_allocator()", "runtime.default_allocator()"}   // memcheck: what it looks for
	hits := 0
	walk_odin :: proc(dir: string, patterns: []string, t: ^Task_Run, hits: ^int) {
		entries, err := os.read_all_directory_by_path(dir, context.allocator)
		if err != nil { return }
		defer os.file_info_slice_delete(entries, context.allocator)
		for e in entries {
			if e.type == .Directory { walk_odin(e.fullpath, patterns, t, hits); continue }
			if !strings.has_suffix(e.name, ".odin") || strings.has_suffix(e.name, "_test.odin") { continue }
			path, _ := strings.replace_all(e.fullpath, "\\", "/", context.temp_allocator)
			if strings.has_suffix(path, "src/base/memory.odin") { continue }
			data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
			if rerr != nil { continue }
			text := string(data)
			n := 0
			for line in strings.split_lines_iterator(&text) {
				n += 1
				for p in patterns {
					if strings.contains(line, p) && !strings.contains(line, "// memcheck: ") {
						task_say(t, "%s:%d: %s", path, n, strings.trim_space(line))
						hits^ += 1
						break
					}
				}
			}
			free_all(context.temp_allocator)
		}
	}
	walk_odin("src", PATTERNS, t, &hits)
	return hits == 0
}

task_lint_globals :: proc(t: ^Task_Run) -> bool {
	return lint_globals(log = t.log)
}

// A licence issued with the development pair verifies; an altered one and one of another key do not; keygen refuses a path inside the repository.
task_license_tool :: proc(t: ^Task_Run) -> bool {
	LICENSE_FILE :: "build/tmp/license_tool_test.wrenlicense"
	PRIVATE_KEY :: "build/tmp/license_tool_private.key"
	OTHER_KEY :: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	VERDICT :: "VALID: Patron licence of Test Name"
	// (a byte of the signature, past the first dot)
	ALTERED_AT :: 12
	tool := exe("build/license")
	_ = os.remove(LICENSE_FILE)
	if task_exec(t, {tool, "issue", "-dev", "-name", "Test Name", "-email", "t@example.org", "-edition", "patron", "-order", "T-1", "-out", LICENSE_FILE}) != 0 { task_say(t, "issue failed"); return false }
	text, code := tooling.capture({tool, "verify", LICENSE_FILE, "-dev"})
	tooling.append_text(t.log, text)
	if code != 0 || !strings.contains(text, VERDICT) { task_say(t, "verify failed"); return false }
	data, err := os.read_entire_file(LICENSE_FILE, context.temp_allocator)
	if err != nil { task_say(t, "the licence was not written"); return false }
	body := strings.builder_make(context.temp_allocator)
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) { if !strings.has_prefix(line, "#") { strings.write_string(&body, strings.trim_right(line, "\r")) } }
	line := body.buf[:]
	dot := strings.index_byte(string(line), '.')
	if dot < 0 || dot + ALTERED_AT >= len(line) { task_say(t, "not a licence: %s", string(line)); return false }
	at := dot + ALTERED_AT
	line[at] = line[at] == 'A' ? 'B' : 'A'
	if task_exec(t, {tool, "verify", "-text", string(line), "-dev"}) == 0 { task_say(t, "an altered licence verified"); return false }
	if task_exec(t, {tool, "verify", LICENSE_FILE, "-public", OTHER_KEY}) == 0 { task_say(t, "a licence verified with another key"); return false }
	if task_exec(t, {tool, "keygen", "-private", PRIVATE_KEY}) == 0 { task_say(t, "keygen wrote a private key inside the repository"); _ = os.remove(PRIVATE_KEY); return false }
	return true
}

// licence/worker with node 22.18+ or bun; SKIP without either.
task_license_worker :: proc(t: ^Task_Run) -> bool {
	NODE_MAJOR :: 22
	NODE_MINOR :: 18
	has_node := false
	if text, code := tooling.capture({"node", "-p", "process.versions.node"}); code == 0 {
		parts := strings.split(strings.trim_space(text), ".", context.temp_allocator)
		if len(parts) >= 2 {
			major, minor := parse_or_zero(parts[0]), parse_or_zero(parts[1])
			has_node = major > NODE_MAJOR || (major == NODE_MAJOR && minor >= NODE_MINOR)
		}
	}
	_, bun_code := tooling.capture({"bun", "--version"})
	if !has_node && bun_code != 0 {
		task_say(t, "SKIP: neither node 22.18+ nor bun is installed")
		return true
	}
	env := []string{fmt.tprintf("WREN_LICENSE_EXE=%s", here(exe("build/license_worker")))}
	if has_node {
		// (the shell expands nothing here: node's own --test takes the pattern)
		return task_exec(t, {"node", "--test", "test/*.test.ts"}, env, "licence/worker") == 0
	}
	return task_exec(t, {"bun", "test", "test/"}, env, "licence/worker") == 0
}

parse_or_zero :: proc(s: string) -> int {
	v := 0
	for c in s { if c >= '0' && c <= '9' { v = v * 10 + int(c - '0') } }
	return v
}

// build/fetch against build/testserver: what a slow consumer, a cancel and queued streams do to memory and to what is in flight, on real sockets.
Stress_Case :: struct {
	title:   string,
	args:    []string,
	expect:  string,   // a regular expression its output must match
	peak_mb: int,      // the most its working set may reach (0: not checked)
}

// How long the server may take to listen.
SERVER_LISTEN_LIMIT :: 60 * time.Second
SERVER_POLL :: 20 * time.Millisecond
// The default first port the server tries when this run's block does not say otherwise.
FLAT_MEMORY_MB :: 60
QUEUED_MEMORY_MB :: 100
BYTES_PER_MB :: 1048576

task_net_stress :: proc(t: ^Task_Run) -> bool {
	port_file := fmt.tprintf("%s/net_stress_%d.port", TEMP_DIR, os.get_pid())
	_ = os.remove(port_file)
	server, why := tooling.spawn({command = {tooling.TESTSERVER_EXE, "-scan", "-port-file", port_file, "-parent-pid", fmt.tprint(os.get_pid())}, log = t.log})
	if why != "" { task_say(t, "the test server cannot start: %s", why); return false }
	defer tooling.release(&server)
	base := 0
	began := time.tick_now()
	for base <= 0 {
		if data, err := os.read_entire_file(port_file, context.temp_allocator); err == nil { base = parse_or_zero(string(data)) }
		if done, _ := tooling.poll(&server); done { task_say(t, "the test server stopped at once"); return false }
		if time.tick_since(began) > SERVER_LISTEN_LIMIT { task_say(t, "the test server did not listen"); return false }
		if base <= 0 { time.sleep(SERVER_POLL) }
	}
	_ = os.remove(port_file)
	h := fmt.tprintf("http://127.0.0.1:%d", base)
	escaped := regex_escaped(h)
	big := fmt.tprintf("%s/big?mb=%d", h, NET_STRESS_MB)
	whole := fmt.tprintf("done: %d bytes", NET_STRESS_MB * BYTES_PER_MB)
	cases := []Stress_Case{
		{"hello over http", {fmt.tprintf("%s/", h), "--print"}, "hello</h1>", 0},
		{"gzip is decompressed", {fmt.tprintf("%s/gzip", h), "--collect"}, "done: 130000 bytes", 0},
		{"redirect chain is followed", {fmt.tprintf("%s/redirect?n=4", h)}, fmt.tprintf("final=%s/\\s", escaped), 0},
		{"404 is a response, not an error", {fmt.tprintf("%s/status/404", h)}, "404", 0},
		{"POST with body and header", {fmt.tprintf("%s/echo", h), "--method", "POST", "--body", "abcdef", "--header", "X-Test: yes", "--print"}, `POST 6 bytes, X-Test="yes"`, 0},
		{"self-signed https is rejected", {fmt.tprintf("https://127.0.0.1:%d/", base + 1)}, "FAILED: secure connection failed", 0},
		{"bad URL fails cleanly", {"http://"}, "invalid URL", 0},
		{"unreachable port fails cleanly", {"http://127.0.0.1:12345/"}, "FAILED: could not connect", 0},
		{"real https (example.com)", {"https://example.com/"}, "done:", 0},
		{fmt.tprintf("stream %d MB with a slow consumer: memory stays flat", NET_STRESS_MB), {"--slow-ms", "2", big}, whole, FLAT_MEMORY_MB},
		{fmt.tprintf("collect %d MB", NET_STRESS_MB), {"--collect", big}, whole, 0},
		{"max-body 10 MB fails early", {"--max-body", "10000000", big}, "response body too large", FLAT_MEMORY_MB},
		{"cancel mid-stream leaves nothing in flight", {"--cancel-ms", "50", fmt.tprintf("%s/slow", h)}, "cancel -> true, in flight now: 0", 0},
		{"cancel a big download", {"--cancel-ms", "30", big}, "after scope close: in_flight=0", FLAT_MEMORY_MB},
		{"200 concurrent requests", {"--many", "200", fmt.tprintf("%s/", h)}, "pending=0 in_flight=0 failures=0", 0},
		{"24 queued 10 MB streams (6 per host at a time, none may time out)", {"--many", "24", "--slow-ms", "1", fmt.tprintf("%s/big?mb=10", h)}, "pending=0 in_flight=0 failures=0", QUEUED_MEMORY_MB},
	}
	failed := 0
	for c in cases {
		output := fmt.tprintf("%s/net_stress_%d.txt", TEMP_DIR, os.get_pid())
		_ = os.remove(output)
		p, spawn_why := tooling.spawn({command = join({exe("build/fetch")}, c.args), log = output})
		if spawn_why != "" { task_say(t, "build/fetch cannot start: %s", spawn_why); return false }
		code, _ := tooling.wait(&p)
		u := tooling.usage(&p)
		tooling.release(&p)
		data, _ := os.read_entire_file(output, context.temp_allocator)
		_ = os.remove(output)
		good := true
		r, err := regex.create(c.expect)
		if err != nil || !matches(r, string(data)) { good = false }
		peak := int(u.peak_bytes / BYTES_PER_MB)
		if c.peak_mb > 0 && peak > c.peak_mb { good = false }
		if !good { failed += 1 }
		task_say(t, "%s %s  (exit %d, peak %d MB)", good ? "PASS" : "FAIL", c.title, code, peak)
		if !good { tooling.append_text(t.log, fmt.tprintln(string(data))) }
	}
	task_say(t, "failed: %d", failed)
	return failed == 0
}
