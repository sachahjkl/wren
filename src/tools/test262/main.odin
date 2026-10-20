// test262: the ECMAScript conformance suite (tc39/test262) in Wren's JavaScript engine compiled to Wasm, test by test
// as QuickJS-ng's own runner (run-test262.c, of the pinned engine release) runs it natively, so that the two results
// compare file by file and mode by mode. tools\test262.ps1 fetches the pinned suite, builds the test image of the
// engine (the shipped engine plus native/js/runtime/test262_host.c) and the native runner, and drives this tool.
//
//   test262 [-c file.conf]... [-a] [-image m.wasm] [-threads n] [-stride k] [-timeout ms] [-errors out.txt]
//           [-known failures.txt] [-native native_errors.txt] [-md table.md] [-v] [files...]
//
// Run from the directory of the configuration (test names are relative to it, as in run-test262's error files).
//   -c        a run-test262 configuration (test262.conf: features, excluded tests, harness and test directories);
//             several are merged in order, as run-test262 does
//   -a        both modes (strict and sloppy) for every script test, as `make test262` runs it (else the conf's mode)
//   -stride k a sample: every k-th test of the list (after exclusions), for quick runs
//   -errors   writes the failures in run-test262's error-file format ("<file>:<line>: [strict mode: ]<message>")
//   -known    the failures expected of the Wasm engine (same format): exit status 1 when a test fails that is not in it
//             (a regression); tests of it that pass are reported as fixed
//   -native   the failures of the native runner on the same list: the Markdown table compares both and lists the tests
//             that fail in Wasm only (bugs of the Wasm build or of the browser's patches) and natively only
// Each test runs in a fresh realm (a new instance of the engine image, no web interfaces), on `-threads` threads.
// A test that runs past -timeout is interrupted by the engine's own interrupt flag (it fails), a trap fails the test
// only: nothing stops the run.
package test262

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "wb:host"
import "wb:js"
import "wb:wasm"

Mode :: enum { Default_Nostrict, Default_Strict, Nostrict, Strict, All }

Config :: struct {
	tests:          [dynamic]string,
	excludes:       [dynamic]string,
	harness_dir:    string,
	features:       map[string]bool,   // true: enabled, false: skipped
	harness_exclude: [dynamic]string,
	mode:           Mode,
	skip_async:     bool,
	skip_module:    bool,
	excluded:       int,
}

cfg: Config

// ---- run-test262's configuration and name lists ----

compose_path :: proc(base, name: string) -> string {
	if base == "" || strings.has_prefix(name, "/") { return strings.clone(name) }
	if strings.has_suffix(base, "/") { return strings.concatenate({base, name}) }
	return strings.concatenate({base, "/", name})
}

get_basename :: proc(filename: string) -> string {
	i := strings.last_index_byte(filename, '/')
	return i < 0 ? "" : filename[:i]
}

is_digit :: #force_inline proc(c: u8) -> bool { return c >= '0' && c <= '9' }

// run-test262's namelist_cmp: lexicographic, runs of digits compared as numbers.
namelist_cmp :: proc(a, b: string) -> int {
	i, j := 0, 0
	at :: #force_inline proc(s: string, k: int) -> int { return k < len(s) ? int(s[k]) : 0 }
	for {
		ca := at(a, i); i += 1
		cb := at(b, j); j += 1
		if ca != 0 && cb != 0 && is_digit(u8(ca)) && is_digit(u8(cb)) {
			na := ca - '0'
			nb := cb - '0'
			for { ca = at(a, i); i += 1; if ca == 0 || !is_digit(u8(ca)) { break }; na = na * 10 + ca - '0' }
			for { cb = at(b, j); j += 1; if cb == 0 || !is_digit(u8(cb)) { break }; nb = nb * 10 + cb - '0' }
			if na < nb { return -1 }
			if na > nb { return 1 }
		}
		if ca < cb { return -1 }
		if ca > cb { return 1 }
		if ca == 0 { return 0 }
	}
}

namelist_sort :: proc(l: ^[dynamic]string) {
	slice.sort_by(l[:], proc(a, b: string) -> bool { return namelist_cmp(a, b) < 0 })
	if len(l) < 2 { return }
	n := 1
	for i in 1 ..< len(l) {
		if namelist_cmp(l[n - 1], l[i]) != 0 { l[n] = l[i]; n += 1 }
	}
	resize(l, n)
}

namelist_find :: proc(l: []string, name: string) -> bool {
	a, b := 0, len(l)
	for a < b {
		m := a + (b - a) / 2
		c := namelist_cmp(l[m], name)
		if c < 0 { a = m + 1 } else if c > 0 { b = m } else { return true }
	}
	return false
}

find_test_files :: proc(path: string) {
	entries, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil { return }
	for e in entries {
		full := fmt.aprintf("%s/%s", strings.trim_right(path, "/\\"), e.name)
		if e.type == .Directory {
			find_test_files(full)
			delete(full)
		} else if strings.has_suffix(full, ".js") && !strings.has_suffix(full, "_FIXTURE.js") {
			append(&cfg.tests, full)
		} else {
			delete(full)
		}
	}
}

enumerate_tests :: proc(path: string) {
	start := len(cfg.tests)
	find_test_files(path)
	part := cfg.tests[start:]
	slice.sort_by(part, proc(a, b: string) -> bool { return namelist_cmp(a, b) < 0 })
}

str_strip :: proc(s: string) -> string { return strings.trim_space(s) }

load_config :: proc(filename: string, ignore: string) -> bool {
	data, err := os.read_entire_file(filename, context.allocator)
	if err != nil { fmt.eprintfln("test262: cannot read %s", filename); return false }
	base := get_basename(filename)
	Section :: enum { None, Config, Exclude, Features, Tests }
	section := Section.None
	for raw in strings.split_lines(string(data), context.temp_allocator) {
		p := str_strip(raw)
		if p == "" || p[0] == '#' || p[0] == ';' { continue }
		if p[0] == '[' {
			name := p[1:]
			if k := strings.index_byte(name, ']'); k >= 0 { name = name[:k] }
			switch name {
			case "config": section = .Config
			case "exclude": section = .Exclude
			case "features": section = .Features
			case "tests": section = .Tests
			case: section = .None
			}
			continue
		}
		key, value := p, ""
		has_value := false
		if k := strings.index_byte(p, '='); k >= 0 {
			key = str_strip(p[:k])
			value = str_strip(p[k + 1:])
			has_value = true
		}
		switch section {
		case .Config:
			if !has_value { fmt.eprintfln("%s: syntax error: %s", filename, p); continue }
			if ignore != "" && strings.contains(ignore, key) { continue }
			switch key {
			case "testdir": dir := compose_path(base, value); enumerate_tests(dir); delete(dir)
			case "harnessdir": cfg.harness_dir = compose_path(base, value)
			case "harnessexclude": for w in strings.fields(value, context.temp_allocator) { append(&cfg.harness_exclude, strings.clone(w)) }
			case "features": for w in strings.fields(value, context.temp_allocator) { cfg.features[strings.clone(w)] = true }
			case "skip-features": for w in strings.fields(value, context.temp_allocator) { cfg.features[strings.clone(w)] = false }
			case "mode":
				switch value {
				case "default", "default-nostrict": cfg.mode = .Default_Nostrict
				case "default-strict": cfg.mode = .Default_Strict
				case "nostrict": cfg.mode = .Nostrict
				case "strict": cfg.mode = .Strict
				case "all", "both": cfg.mode = .All
				case: fmt.eprintfln("test262: unknown test mode: %s", value); return false
				}
			case "strict": if value == "skip" || value == "no" { cfg.mode = .Nostrict }
			case "nostrict": if value == "skip" || value == "no" { cfg.mode = .Strict }
			case "async": cfg.skip_async = value != "yes"
			case "module": cfg.skip_module = value != "yes"
			case "excludefile":
				path := compose_path(base, value)
				if ex, e := os.read_entire_file(path, context.allocator); e == nil {
					eb := get_basename(path)
					for l in strings.split_lines(string(ex), context.temp_allocator) {
						t := str_strip(l)
						if t == "" || t[0] == '#' || t[0] == ';' { continue }
						append(&cfg.excludes, compose_path(eb, t))
					}
				}
			}
			// (local, verbose, errorfile: run-test262's own business; this tool has its options)
		case .Exclude:
			// (a "name=value" line keeps only its name, as run-test262's in-place split does)
			append(&cfg.excludes, compose_path(base, key))
		case .Features:
			// "name", "name=yes", "name=!tcc" (enabled: this is not tcc), anything else skipped
			cfg.features[strings.clone(key)] = !has_value || value == "yes" || value == "!tcc"
		case .Tests:
			append(&cfg.tests, compose_path(base, key))
		case .None:
		}
	}
	return true
}

// run-test262's update_exclude_dirs + the per-file exclusion: what remains to run.
apply_excludes :: proc() {
	dirs := make([dynamic]string, context.temp_allocator)
	files := make([dynamic]string, context.temp_allocator)
	for e in cfg.excludes {
		if strings.has_suffix(e, "/") { append(&dirs, e) } else { append(&files, e) }
	}
	namelist_sort(&dirs)
	namelist_sort(&cfg.tests)
	namelist_sort(&files)
	kept := make([dynamic]string)
	for name in cfg.tests {
		include, exclude := 0, 0
		for path in dirs {
			if strings.has_prefix(name, path) { exclude = len(path) }
			if len(path) > 0 && path[0] == '!' && strings.has_prefix(name, path[1:]) { include = len(path) - 1 }
		}
		if exclude > include || namelist_find(files[:], name) { cfg.excluded += 1; continue }
		append(&kept, name)
	}
	delete(cfg.tests)
	cfg.tests = kept
}

// ---- a test's front matter (run-test262's extract_desc, find_tag, get_option) ----

// The first "/*-" comment not followed by '/' (run-test262 reads from there to the next "*/").
extract_desc :: proc(buf: string) -> (string, bool) {
	for i := 0; i + 3 < len(buf); i += 1 {
		if buf[i] == '/' && buf[i + 1] == '*' && buf[i + 2] == '-' && buf[i + 3] != '/' {
			start := i + 3
			end := strings.index(buf[start:], "*/")
			if end < 0 { return "", false }
			return buf[start:start + end], true
		}
	}
	return "", false
}

// The options after `tag` (a YAML flow list or a block list), as run-test262 reads them.
get_options :: proc(desc, tag: string, out: ^[dynamic]string) -> bool {
	k := strings.index(desc, tag)
	if k < 0 { return false }
	p := k + len(tag)
	state := 0
	for {
		if p >= len(desc) { return true }
		c := desc[p]
		switch c {
		case '[': state += 1; p += 1; continue
		case ']':
			state -= 1
			if state > 0 { p += 1; continue }
			return true
		case ' ', '\t', '\r', ',', '-': p += 1; continue
		case '\n':
			if state > 0 || (p + 1 < len(desc) && desc[p + 1] == ' ') { p += 1; continue }
			return true
		case:
			q := p
			for q < len(desc) && strings.index_byte(" \t\r\n,]", desc[q]) < 0 { q += 1 }
			append(out, desc[p:q])
			p = q
		}
	}
}

Test_Info :: struct {
	name:        string,
	includes:    [dynamic]string,
	negative:    bool,
	error_type:  string,
	nostrict, onlystrict, is_async, is_module, can_block: bool,
	skip:        bool,
	uses_agent:  bool,
}

parse_test :: proc(name, buf: string) -> (t: Test_Info) {
	t.name = name
	t.can_block = true
	t.includes = make([dynamic]string, context.temp_allocator)
	append(&t.includes, "sta.js", "assert.js")
	opts := make([dynamic]string, context.temp_allocator)
	if desc, ok := extract_desc(buf); ok {
		clear(&opts)
		if get_options(desc, "includes:", &opts) {
			for f in opts {
				skip_it := false
				for x in cfg.harness_exclude { if x == f { skip_it = true } }
				if skip_it { t.skip = true } else { append(&t.includes, f) }
			}
		}
		clear(&opts)
		if get_options(desc, "flags:", &opts) {
			for o in opts {
				switch o {
				case "noStrict", "raw": t.nostrict = true; t.skip ||= cfg.mode == .Strict
				case "onlyStrict": t.onlystrict = true; t.skip ||= cfg.mode == .Nostrict
				case "async": t.is_async = true; t.skip ||= cfg.skip_async
				case "module": t.is_module = true; t.skip ||= cfg.skip_module
				case "CanBlockIsFalse": t.can_block = false
				}
			}
		}
		if k := strings.index(desc, "negative:"); k >= 0 {
			t.negative = true
			rest := desc[k + len("negative:"):]
			if j := strings.index(rest, "type:"); j >= 0 {
				q := strings.trim_left(rest[j + 5:], " \t\r\n")
				e := 0
				for e < len(q) && strings.index_byte(" \r\n", q[e]) < 0 { e += 1 }
				t.error_type = q[:e]
			}
		}
		clear(&opts)
		if get_options(desc, "features:", &opts) {
			for f in opts {
				enabled, known := cfg.features[f]
				if !known || !enabled { t.skip = true }
			}
		}
	}
	if t.is_async { append(&t.includes, "doneprintHandle.js") }
	t.uses_agent = strings.contains(buf, "$262.agent")
	return
}

// ---- the engine ----

T262_EVAL_MODULE :: 1
T262_EVAL_STRICT :: 2
T262_EVAL_ASYNC :: 4

harness_files: map[string][]byte   // read before the threads start

Worker_State :: struct {
	failures: [dynamic]Failure,
}

Failure :: struct {
	name:    string,
	strict:  bool,
	message: string,
	agent:   bool,   // the test uses $262.agent (threads)
	trap:    bool,
}

Result :: struct {
	runs:     int,
	skipped:  int,
	failures: [dynamic]Failure,
}

image: []byte
timeout_ms: i64 = 20_000
verbose: bool

guest_string :: proc(f: ^wasm.Frame, p, n: wasm.Raw) -> (string, bool) {
	ptr, ok := wasm.span(f, u64(u32(p.i32)), u64(u32(n.i32)))
	if !ok { return "", false }
	return string(ptr[:u32(n.i32)]), true
}

engine_console :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	context = runtime.default_context()
	if verbose {
		f := wasm.frame(env, caller)
		if text, ok := guest_string(&f, a[1], a[2]); ok { fmt.eprintln(text) }
	}
	return nil
}

engine_ignore :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap { return nil }

engine_tz :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	r := js.timezone_offset(a[0].f64)
	a[0] = {}
	a[0].i32 = r
	return nil
}

exception_message :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	a[0] = {}
	return nil
}

origin_tick: time.Tick

performance_now :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	d := time.tick_since(origin_tick)
	a[0] = {}
	a[0].f64 = f64(d) / 1e6
	return nil
}

// test262.fileSize(path) -> size or -1; test262.readFile(path, out, cap) -> bytes read or -1 (modules and fixtures)
file_size :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	context = runtime.default_context()
	f := wasm.frame(env, caller)
	path, ok := guest_string(&f, a[0], a[1])
	r: i32 = -1
	if ok {
		if fi, err := os.stat(path, context.temp_allocator); err == nil && fi.type != .Directory { r = i32(min(fi.size, i64(max(i32)))) }
	}
	a[0] = {}
	a[0].i32 = r
	return nil
}

read_file :: proc "c" (env: rawptr, caller: wasm.Caller, a: [^]wasm.Raw, _: uint) -> wasm.Trap {
	context = runtime.default_context()
	f := wasm.frame(env, caller)
	path, ok := guest_string(&f, a[0], a[1])
	r: i32 = -1
	if ok {
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
			cap := u64(u32(a[3].i32))
			if out, okb := wasm.span(&f, u64(u32(a[2].i32)), cap); okb && u64(len(data)) <= cap {
				copy(out[:cap], data)
				r = i32(len(data))
			}
		}
	}
	a[0] = {}
	a[0].i32 = r
	return nil
}

IMPORTS := [?]wasm.Import{
	{module = "js", name = "Engine_console", fn = engine_console, params = {.I32, .I32, .I32}},
	{module = "js", name = "Engine_reportException", fn = engine_ignore, params = {.I32, .I32, .I32, .I32, .I32, .I32, .I32, .I32}},
	{module = "js", name = "Engine_storeBytecode", fn = engine_ignore, params = {.I32, .I32}},
	{module = "js", name = "Engine_timezoneOffset", fn = engine_tz, params = {.F64}, results = {.I32}},
	{module = "web", name = "Exception_message", fn = exception_message, params = {.I32, .I32}, results = {.I32}},
	{module = "performance", name = "Performance_now", fn = performance_now, params = {}, results = {.F64}},
	{module = "test262", name = "fileSize", fn = file_size, params = {.I32, .I32}, results = {.I32}},
	{module = "test262", name = "readFile", fn = read_file, params = {.I32, .I32, .I32, .I32}, results = {.I32}},
}

// Calls `wj_t262_eval` on `source`: (code, message). code: 0 completed, 1 threw, 2 threw without a string, -1 trap.
eval_in :: proc(inst: ^wasm.Instance, source: []byte, name: string, flags: i32) -> (code: i32, message: string) {
	src := js.guest_copy(inst, source)
	if src == 0 { return -1, "could not copy the source into the engine" }
	defer js.guest_free(inst, src)
	nm := js.guest_copy(inst, transmute([]byte)name, false)
	defer js.guest_free(inst, nm)
	argv := [5]u32{src, u32(len(source)), nm, u32(len(name)), u32(flags)}
	if wasm.call_raw(inst, "wj_t262_eval", argv[:]) != .Ok {
		return -1, fmt.tprintf("trap: %s", inst.last_error)
	}
	code = i32(argv[0])
	if code != 0 {
		p, r1 := wasm.call_i32(inst, "wj_t262_message")
		n, r2 := wasm.call_i32(inst, "wj_t262_message_len")
		if r1 == .Ok && r2 == .Ok {
			if b := wasm.guest_bytes(inst, u64(u32(p)), u64(u32(n))); b != nil { message = strings.clone(string(b), context.temp_allocator) }
		}
	}
	return
}

// One run of a test in one mode (run-test262's run_test_buf + eval_buf): "" when it passed, else why it failed.
run_one :: proc(t: ^Test_Info, buf: []byte, strict: bool) -> (failure: string, trapped: bool) {
	opt := wasm.options_default()
	opt.max_call_ms = timeout_ms * 2
	opt.soft_call_ms = timeout_ms
	inst, err := wasm.instance_create(image, nil, nil, opt, "test262")
	if inst == nil { return fmt.tprintf("the engine did not start: %s", err), true }
	defer wasm.destroy(inst)
	inst.lenient = true
	seed: u64 = 0x9e3779b97f4a7c15
	// kind 0: no web interfaces on the global, ECMAScript only
	if !js.realm_start(inst, {kind = js.Realm_Kind(0), seed = seed, max_heap_bytes = 1 << 30, gc_threshold = 2 << 20}) {
		return fmt.tprintf("the realm did not start: %s", inst.last_error), true
	}
	if addr := js.interrupt_address(inst); addr != 0 {
		if b := wasm.guest_bytes(inst, u64(addr), 4); b != nil { inst.soft_flag = (^i32)(raw_data(b)) }
	}
	nm := js.guest_copy(inst, transmute([]byte)t.name, false)
	argv := [3]u32{nm, u32(len(t.name)), u32(t.can_block ? 1 : 0)}
	res := wasm.call_raw(inst, "wj_t262_setup", argv[:])
	js.guest_free(inst, nm)
	if res != .Ok || i32(argv[0]) != 0 { return "wj_t262_setup failed (is this the test image of the engine?)", true }
	for inc in t.includes {
		data, found := harness_files[inc]
		if !found { return fmt.tprintf("missing harness file %s", inc), false }
		path := fmt.tprintf("%s/%s", cfg.harness_dir, inc)
		code, msg := eval_in(inst, data, path, 0)
		if code == -1 { return msg, true }
		if code != 0 { return fmt.tprintf("error including %s: %s", inc, msg), false }
	}
	flags: i32 = 0
	if t.is_module { flags |= T262_EVAL_MODULE }
	if strict { flags |= T262_EVAL_STRICT }
	if t.is_async { flags |= T262_EVAL_ASYNC }
	code, msg := eval_in(inst, buf, t.name, flags)
	switch code {
	case -1: return msg, true
	case 0: return t.negative ? "expected error" : "", false
	case 1:
		if !t.negative { return msg, false }
		if t.error_type != "" {
			k := strings.index_byte(msg, ':')
			class := k < 0 ? msg : msg[:k]
			if class != t.error_type { return fmt.tprintf("unexpected error type: %s", msg), false }
		}
		return "", false
	case:
		return t.negative ? "unexpected error type: (an exception that has no string)" : msg, false
	}
}

Shared :: struct {
	next:    int,   // atomic
	done:    int,   // atomic
	results: []Result,
	list:    []string,
	mutex:   sync.Mutex,
}

shared: Shared

worker_main :: proc(data: rawptr) {
	res := (^Result)(data)
	for {
		i := sync.atomic_add(&shared.next, 1)
		if i >= len(shared.list) { break }
		name := shared.list[i]
		buf, err := os.read_entire_file(name, context.allocator)
		if err != nil {
			append(&res.failures, Failure{name = name, message = strings.clone("cannot read the test")})
			sync.atomic_add(&shared.done, 1)
			continue
		}
		t := parse_test(name, string(buf))
		use_strict, use_nostrict := false, false
		switch cfg.mode {
		case .Default_Nostrict: if t.onlystrict { use_strict = true } else { use_nostrict = true }
		case .Default_Strict: if t.nostrict { use_nostrict = true } else { use_strict = true }
		case .Nostrict: use_nostrict = !t.onlystrict
		case .Strict: use_strict = !t.nostrict
		case .All:
			if t.is_module { use_nostrict = true } else { use_strict = !t.nostrict; use_nostrict = !t.onlystrict }
		}
		if t.skip || (!use_strict && !use_nostrict) {
			res.skipped += 1
		} else {
			for strict in ([2]bool{false, true}) {
				if strict ? !use_strict : !use_nostrict { continue }
				res.runs += 1
				msg, trapped := run_one(&t, buf, strict)
				if msg != "" || trapped {
					append(&res.failures, Failure{name = name, strict = strict, message = strings.clone(msg), agent = t.uses_agent, trap = trapped})
				}
			}
		}
		delete(buf)
		free_all(context.temp_allocator)
		sync.atomic_add(&shared.done, 1)
	}
}

// ---- error files ----

Key :: struct { name: string, strict: bool }

// The (file, mode) pairs of an error file in run-test262's format.
read_error_file :: proc(path: string) -> (m: map[Key]string, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return }
	for line in strings.split_lines(string(data)) {
		k := strings.index(line, ".js:")
		if k < 0 { continue }
		name := line[:k + 3]
		rest := line[k + 4:]
		if j := strings.index_byte(rest, ':'); j >= 0 { rest = rest[j + 1:] }
		rest = strings.trim_left(rest, " ")
		strict := strings.has_prefix(rest, "strict mode: ")
		if strict { rest = rest[len("strict mode: "):] }
		m[Key{name, strict}] = rest
	}
	return m, true
}

usage :: proc() -> ! {
	fmt.eprintln("usage: test262 [-c file.conf]... [-a] [-image m.wasm] [-threads n] [-stride k] [-timeout ms] [-errors out.txt] [-known failures.txt] [-native errors.txt] [-md table.md] [-v] [files...]")
	os.exit(2)
}

main :: proc() {
	args := os.args[1:]
	confs := make([dynamic]string)
	files := make([dynamic]string)
	image_path := ""
	threads := max(1, host.processor_count() - 1)
	stride := 1
	errors_out, known_path, native_path, md_out := "", "", "", ""
	force_all := false
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		need :: proc(args: []string, i: ^int) -> string { i^ += 1; if i^ >= len(args) { usage() }; return args[i^] }
		switch a {
		case "-c": append(&confs, need(args, &i))
		case "-a": force_all = true
		case "-image": image_path = need(args, &i)
		case "-threads": threads = max(1, parse_int(need(args, &i)))
		case "-stride": stride = max(1, parse_int(need(args, &i)))
		case "-timeout": timeout_ms = i64(max(100, parse_int(need(args, &i))))
		case "-errors": errors_out = need(args, &i)
		case "-known": known_path = need(args, &i)
		case "-native": native_path = need(args, &i)
		case "-md": md_out = need(args, &i)
		case "-v": verbose = true
		case "--pref": i += 1
		case:
			if strings.has_prefix(a, "-") { usage() }
			append(&files, a)
		}
	}
	if image_path == "" { fmt.eprintln("test262: -image is required (the test image: build\\js-test262\\wren_js.wasm)"); os.exit(2) }
	ignore := len(files) > 0 ? "testdir" : ""
	for c in confs { if !load_config(c, ignore) { os.exit(2) } }
	for f in files { append(&cfg.tests, strings.clone(f)) }
	if force_all { cfg.mode = .All }
	apply_excludes()
	if len(cfg.tests) == 0 { fmt.eprintln("test262: no test to run"); os.exit(2) }

	// the sample: every stride-th test
	list := make([dynamic]string)
	for t, i in cfg.tests { if i % stride == 0 { append(&list, t) } }

	// harness files, read once
	if entries, err := os.read_all_directory_by_path(cfg.harness_dir, context.allocator); err == nil {
		for e in entries {
			if e.type == .Directory { continue }
			if data, rerr := os.read_entire_file(e.fullpath, context.allocator); rerr == nil { harness_files[strings.clone(e.name)] = data }
		}
	} else {
		fmt.eprintfln("test262: cannot read the harness directory %s", cfg.harness_dir); os.exit(2)
	}

	data, ierr := os.read_entire_file(image_path, context.allocator)
	if ierr != nil { fmt.eprintfln("test262: cannot read %s", image_path); os.exit(2) }
	image = data
	origin_tick = time.tick_now()
	wasm.configure_from_args(os.args[1:])
	if !wasm.runtime_init() || !wasm.register_wasi() || !wasm.register(IMPORTS[:]) { fmt.eprintln("test262: the Wasm engine could not start"); os.exit(1) }
	wasm.wasi_output = proc(inst: ^wasm.Instance, fd: i32, text: []u8) { if verbose { os.write(os.stderr, text) } }

	t0 := time.tick_now()
	shared.list = list[:]
	shared.results = make([]Result, threads)
	ths := make([dynamic]^host.Thread)
	for i in 0 ..< threads {
		// Wasm calls run on the thread's own stack: room for wasm.wasmtime.max_stack_bytes
		th := host.thread_start(worker_main, &shared.results[i], 32 << 20)
		if th == nil { fmt.eprintln("test262: cannot start a thread"); os.exit(1) }
		append(&ths, th)
	}
	last := -1
	for {
		finished := true
		for th in ths { if !host.thread_finished(th) { finished = false } }
		if finished { break }
		d := sync.atomic_load(&shared.done)
		if d / 1000 != last / 1000 { last = d; fmt.eprintf("%d/%d\r", d, len(list)) }
		time.sleep(100 * time.Millisecond)
	}
	for th in ths { host.thread_join(th) }
	elapsed := time.duration_seconds(time.tick_since(t0))

	runs, skipped := 0, 0
	all := make([dynamic]Failure)
	for r in shared.results {
		runs += r.runs
		skipped += r.skipped
		append(&all, ..r.failures[:])
	}
	slice.sort_by(all[:], proc(a, b: Failure) -> bool {
		c := namelist_cmp(a.name, b.name)
		return c < 0 || (c == 0 && !a.strict && b.strict)
	})
	fmt.printfln("Result: %d/%d errors, %d excluded, %d skipped (%d tests of %d, stride %d, %d threads, %.1f s)",
		len(all), runs, cfg.excluded, skipped, len(list), len(cfg.tests), stride, threads, elapsed)

	if errors_out != "" {
		b := strings.builder_make()
		for f in all {
			msg, _ := strings.replace_all(f.message, "\n", " ", context.temp_allocator)
			fmt.sbprintf(&b, "%s:0: %s%s\n", f.name, f.strict ? "strict mode: " : "", msg)
		}
		if err := os.write_entire_file(errors_out, strings.to_string(b)); err != nil { fmt.eprintfln("test262: cannot write %s", errors_out) }
	}

	status := 0
	in_list := make(map[string]bool)
	for t in list { in_list[t] = true }
	if known_path != "" {
		known, ok := read_error_file(known_path)
		if !ok { fmt.eprintfln("test262: cannot read %s", known_path); os.exit(2) }
		regressions, fixed := 0, 0
		failed := make(map[Key]bool)
		for f in all {
			failed[Key{f.name, f.strict}] = true
			if (Key{f.name, f.strict}) not_in known {
				regressions += 1
				fmt.printfln("REGRESSION %s%s: %s", f.name, f.strict ? " (strict)" : "", f.message)
			}
		}
		for k in known {
			if in_list[k.name] && k not_in failed { fixed += 1; if verbose { fmt.printfln("fixed %s%s", k.name, k.strict ? " (strict)" : "") } }
		}
		fmt.printfln("%d regression(s), %d known failure(s) now passing (refresh %s)", regressions, fixed, known_path)
		if regressions > 0 { status = 1 }
	}

	if md_out != "" {
		write_markdown(md_out, all[:], runs, skipped, len(list), native_path, in_list, elapsed, threads)
	}
	os.exit(status)
}

write_markdown :: proc(path: string, all: []Failure, runs, skipped, tests: int, native_path: string, in_list: map[string]bool, elapsed: f64, threads: int) {
	b := strings.builder_make()
	wasm_failed := make(map[Key]^Failure)
	for &f in all { wasm_failed[Key{f.name, f.strict}] = &f }
	native: map[Key]string
	have_native := false
	if native_path != "" {
		n, ok := read_error_file(native_path)
		if ok {
			have_native = true
			for k, v in n { if in_list[k.name] { native[k] = v } }
		}
	}
	pct :: proc(pass, total: int) -> f64 { return total == 0 ? 0 : 100 * f64(pass) / f64(total) }
	fmt.sbprintln(&b, "| engine | runs (test x mode) | pass | fail | pass rate |")
	fmt.sbprintln(&b, "|---|---:|---:|---:|---:|")
	fmt.sbprintfln(&b, "| QuickJS-ng 0.17.0, Wasm (Wren, Wasmtime) | %d | %d | %d | %.2f %% |", runs, runs - len(all), len(all), pct(runs - len(all), runs))
	if have_native {
		fmt.sbprintfln(&b, "| QuickJS-ng 0.17.0, native (run-test262, x86-64) | %d | %d | %d | %.2f %% |", runs, runs - len(native), len(native), pct(runs - len(native), runs))
	}
	fmt.sbprintfln(&b, "\n%d test files, %d skipped (features off in test262.conf), %d s on %d threads.", tests, skipped, int(elapsed), threads)
	if have_native {
		only_wasm := make([dynamic]^Failure, context.temp_allocator)
		for &f in all { if (Key{f.name, f.strict}) not_in native { append(&only_wasm, &f) } }
		only_native := make([dynamic]Key, context.temp_allocator)
		for k in native { if k not_in wasm_failed { append(&only_native, k) } }
		slice.sort_by(only_native[:], proc(a, b: Key) -> bool { return namelist_cmp(a.name, b.name) < 0 })
		agent, trap, timeout, other := 0, 0, 0, 0
		for f in only_wasm {
			switch {
			case f.agent: agent += 1
			case f.trap: trap += 1
			case strings.contains(f.message, "interrupted"): timeout += 1
			case: other += 1
			}
		}
		fmt.sbprintfln(&b, "\nFailing in Wasm only: %d (uses $262.agent, no threads in the Wasm engine: %d; trap: %d; past the time limit: %d; other: %d). Failing natively only: %d.\n",
			len(only_wasm), agent, trap, timeout, other, len(only_native))
		if len(only_wasm) > 0 {
			fmt.sbprintln(&b, "| failing in Wasm only | mode | why |")
			fmt.sbprintln(&b, "|---|---|---|")
			for f in only_wasm {
				why := f.agent ? "$262.agent (threads)" : f.trap ? "trap" : ""
				msg, _ := strings.replace_all(f.message, "|", "\\|", context.temp_allocator)
				msg, _ = strings.replace_all(msg, "\n", " ", context.temp_allocator)
				if len(msg) > 160 { msg = msg[:160] }
				fmt.sbprintfln(&b, "| `%s` | %s | %s %s |", f.name, f.strict ? "strict" : "sloppy", why, msg)
			}
		}
		if len(only_native) > 0 {
			fmt.sbprintln(&b, "\n| failing natively only | mode |")
			fmt.sbprintln(&b, "|---|---|")
			for k in only_native { fmt.sbprintfln(&b, "| `%s` | %s |", k.name, k.strict ? "strict" : "sloppy") }
		}
	}
	if err := os.write_entire_file(path, strings.to_string(b)); err != nil { fmt.eprintfln("test262: cannot write %s", path) }
}

parse_int :: proc(s: string) -> int {
	v := 0
	for ch in s { if ch >= '0' && ch <= '9' { v = v * 10 + int(ch - '0') } }
	return v
}
