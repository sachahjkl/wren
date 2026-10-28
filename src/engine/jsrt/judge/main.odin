package jsrt_judge

// The judge of the Odin JavaScript runtime: runs scripts and test262 on src/engine/jsrt.
//
//   judge eval <file.js>            run a script (print() available), show the completion value
//   judge test <test262 file>       run one test262 test, verbosely
//   judge test262 [options]         run the suite (test262.conf rules of QuickJS-ng), in worker
//                                   processes so a crash costs one test, not the run
//       -dir <run dir>   (default build/test262/run: test262/, test262.conf, test262_errors.txt)
//       -j <n>           worker processes (default: cores/2)
//       -filter <text>   only tests whose path contains text
//       -stride <k>      every k-th test
//       -out <dir>       results: errors.txt, table.md (default build/test262)
//   judge worker <list> internal: run the listed tests, one result line per test
//
// Front-end: source text is compiled by the engine's own Odin front-end (src/engine/frontend, through
// jsrt.frontend_compile). With JSRT_REFCOMPILER=1, QuickJS-ng's compiler loaded from
// build/jsrt_refcompiler.dll (tools/jsrt_refcompiler.c) is used instead, to tell a compiler bug from a
// runtime bug.

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import js "wb:engine/jsrt"
import jsdate "wb:engine/datetime"

// The judge is linked with a 64 MiB main-thread stack (/STACK, see tools/jsrt_test262.ps1); the engine may use 48 MiB of it.
JUDGE_STACK_BYTES :: 48 << 20

// Monotonic clock for GC statistics, wall clock for Date; local time is UTC in the judge.
set_host_hooks :: proc() {
	js.clock_hook = proc() -> i64 {return time.tick_now()._nsec}
	js.date_now_hook = proc() -> f64 {return f64(time.now()._nsec / 1_000_000)}
	jsdate.timezone_offset_proc = proc "contextless" (t: i64) -> int {return 0}
}

// --- the reference compiler DLL ---

QVarDef :: struct {
	name:                                                  cstring,
	scope_level, scope_next, var_kind, is_const, is_lexical: i32,
}

QClosureVar :: struct {
	name:                                                  cstring,
	var_idx, closure_type, is_const, is_lexical, var_kind:  i32,
}

QParent :: struct {
	arg_count, var_count, closure_var_count: i32,
	vardefs:                                 [^]QVarDef,
	closure_vars:                            [^]QClosureVar,
	is_strict, new_target_allowed, super_call_allowed, super_allowed, arguments_allowed: i32,
}

Compile_Fn :: #type proc "c" (src: [^]u8, src_len: uint, filename: cstring, kind: i32, strict: i32, parent: ^QParent, scope_idx: i32, out: ^[^]u8, out_len: ^uint, err: [^]u8, err_cap: uint, err_kind: ^i32) -> i32
Free_Fn :: #type proc "c" (p: rawptr)

qjsc_compile: Compile_Fn
qjsc_free: Free_Fn

pjoin :: proc(parts: ..string) -> string {
	s, _ := filepath.join(parts)
	return s
}

// The judge compiles with the engine's Odin front-end; JSRT_REFCOMPILER=1 in the environment (inherited
// by the workers) switches to the reference DLL to tell compiler bugs from runtime bugs.
use_reference_compiler: bool

compile_hook :: proc() -> proc(ctx: ^js.Context, req: ^js.Compile_Request) -> js.Value {
	return use_reference_compiler ? judge_compile : nil
}

load_compiler :: proc() -> bool {
	use_reference_compiler = os.get_env("JSRT_REFCOMPILER", context.temp_allocator) == "1"
	if !use_reference_compiler {return true}
	exe_dir := filepath.dir(os.args[0])
	candidates := []string{pjoin(exe_dir, "jsrt_refcompiler.dll"), "build/jsrt_refcompiler.dll"}
	for c in candidates {
		lib, ok := dynlib.load_library(c)
		if !ok {continue}
		p1, ok1 := dynlib.symbol_address(lib, "qjsc_compile")
		p2, ok2 := dynlib.symbol_address(lib, "qjsc_free")
		if ok1 && ok2 {
			qjsc_compile = cast(Compile_Fn)p1
			qjsc_free = cast(Free_Fn)p2
			return true
		}
	}
	fmt.eprintln("judge: cannot load jsrt_refcompiler.dll (run tools/jsrt_test262.ps1 -BuildOnly)")
	return false
}

// --- per-runtime host state ---

Host :: struct {
	test_path:     string,
	async_done:    int,
	async_failure: string,
	output:        strings.Builder,
	deadline:      time.Tick,
	timed_out:     bool,
	modules:       map[string]js.Value,
	can_block:     bool,
}

kind_code :: proc(k: js.Compile_Kind) -> i32 {
	switch k {
	case .script: return 0
	case .module: return 1
	case .eval_indirect: return 2
	case .function_ctor: return 3
	case .eval_direct: return 4
	}
	return 0
}

judge_compile :: proc(ctx: ^js.Context, req: ^js.Compile_Request) -> js.Value {
	rt := ctx.rt
	parent: QParent
	pp: ^QParent
	if req.kind == .eval_direct && req.parent != nil {
		b := req.parent
		n := int(b.arg_count) + int(b.var_count)
		vds := make([]QVarDef, max(n, 1), context.temp_allocator)
		for i in 0 ..< n {
			vd := b.vardefs[i]
			vds[i] = QVarDef {
				name        = strings.clone_to_cstring(js.atom_utf8(rt, vd.name), context.temp_allocator),
				scope_level = vd.scope_level,
				scope_next  = vd.scope_next,
				var_kind    = i32(vd.var_kind),
				is_const    = i32(vd.is_const),
				is_lexical  = i32(vd.is_lexical),
			}
		}
		cvs := make([]QClosureVar, max(int(b.closure_var_count), 1), context.temp_allocator)
		for i in 0 ..< int(b.closure_var_count) {
			cv := b.closure_vars[i]
			cvs[i] = QClosureVar {
				name         = strings.clone_to_cstring(js.atom_utf8(rt, cv.name), context.temp_allocator),
				var_idx      = i32(cv.var_idx),
				closure_type = i32(cv.closure_type),
				is_const     = i32(cv.is_const),
				is_lexical   = i32(cv.is_lexical),
				var_kind     = i32(cv.var_kind),
			}
		}
		parent = QParent {
			arg_count          = i32(b.arg_count),
			var_count          = i32(b.var_count),
			closure_var_count  = i32(b.closure_var_count),
			vardefs            = raw_data(vds),
			closure_vars       = raw_data(cvs),
			is_strict          = i32(b.is_strict_mode),
			new_target_allowed = i32(b.new_target_allowed),
			super_call_allowed = i32(b.super_call_allowed),
			super_allowed      = i32(b.super_allowed),
			arguments_allowed  = i32(b.arguments_allowed),
		}
		pp = &parent
	}
	out: [^]u8
	out_len: uint
	err: [512]u8
	err_kind: i32
	fname := strings.clone_to_cstring(req.filename, context.temp_allocator)
	r := qjsc_compile(raw_data(req.source), len(req.source), fname, kind_code(req.kind), i32(req.strict), pp, i32(req.scope_idx), &out, &out_len, raw_data(err[:]), len(err), &err_kind)
	if r != 0 {
		msg := string(cstring(raw_data(err[:])))
		kind: js.Error_Kind = .syntax
		switch err_kind {
		case 2: kind = .reference
		case 3: kind = .range
		case 4: kind = .type
		case 1: kind = .internal
		}
		return js.throw_error(ctx, kind, msg)
	}
	v := js.read_object(ctx, out[:out_len])
	qjsc_free(out)
	return v
}

// A JavaScript string literal holding `text` (for the synthesized json/text modules).
js_string_literal :: proc(sb: ^strings.Builder, text: string) {
	strings.write_byte(sb, '"')
	for c in transmute([]u8)text {
		switch c {
		case '"': strings.write_string(sb, "\\\"")
		case '\\': strings.write_string(sb, "\\\\")
		case '\n': strings.write_string(sb, "\\n")
		case '\r': strings.write_string(sb, "\\r")
		case 0 ..< 0x20: fmt.sbprintf(sb, "\\x%02x", c)
		case: strings.write_byte(sb, c)
		}
	}
	strings.write_byte(sb, '"')
}

// Modules imported `with { type }`: json (JSON.parse of the file), text (the file as a string) and
// bytes (a Uint8Array over an immutable ArrayBuffer), compiled as tiny synthesized modules.
synth_module_source :: proc(attr_type: string, data: []u8) -> (string, bool) {
	sb := strings.builder_make(context.temp_allocator)
	switch attr_type {
	case "json":
		strings.write_string(&sb, "export default JSON.parse(")
		js_string_literal(&sb, string(data))
		strings.write_string(&sb, ");\n")
	case "text":
		strings.write_string(&sb, "export default ")
		js_string_literal(&sb, string(data))
		strings.write_string(&sb, ";\n")
	case "bytes":
		strings.write_string(&sb, "const b = new Uint8Array([")
		for x, i in data {
			if i > 0 {strings.write_byte(&sb, ',')}
			fmt.sbprintf(&sb, "%d", x)
		}
		strings.write_string(&sb, "]);\nexport default new Uint8Array(b.buffer.transferToImmutable());\n")
	case:
		return "", false
	}
	return strings.to_string(sb), true
}

judge_load_module :: proc(ctx: ^js.Context, referrer: string, specifier: string, attr_type: string, user: rawptr) -> js.Value {
	h := cast(^Host)user
	base := referrer
	if base == "" || !strings.has_suffix(base, ".js") && !strings.has_suffix(base, ".mjs") {base = h.test_path}
	dir := filepath.dir(base)
	path := pjoin(dir, specifier)
	path, _ = filepath.clean(path)
	path, _ = strings.replace_all(path, "\\", "/")
	key := attr_type == "" ? path : fmt.tprintf("%s#%s", path, attr_type)
	if v, ok := h.modules[key]; ok {return v}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return js.throw_error(ctx, .reference, fmt.tprintf("could not load module '%s'", specifier))
	}
	source := string(data)
	if attr_type != "" {
		s, ok := synth_module_source(attr_type, data)
		if !ok {return js.throw_error(ctx, .type, fmt.tprintf("unsupported module type '%s'", attr_type))}
		source = s
	}
	req := js.Compile_Request{kind = .module, source = source, filename = path}
	v := js.compile(ctx, &req)
	if js.is_exception(v) {return v}
	pk := strings.clone(key)
	h.modules[pk] = v
	js.persist(ctx.rt, v)
	return v
}

judge_interrupt :: proc(rt: ^js.Runtime, user: rawptr) -> bool {
	h := cast(^Host)user
	if time.tick_since(h.deadline) > 0 {
		h.timed_out = true
		return true
	}
	return false
}

// --- helpers installed in each realm ---

host_of :: proc(ctx: ^js.Context) -> ^Host {return cast(^Host)ctx.rt.host_data}

js_print :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	h := host_of(ctx)
	for a, i in args {
		s, ok := js.to_utf8(ctx, a, context.temp_allocator)
		if !ok {return js.EXCEPTION}
		if i > 0 {strings.write_byte(&h.output, ' ')}
		strings.write_string(&h.output, s)
		if s == "Test262:AsyncTestComplete" {
			h.async_done += 1
		} else if strings.has_prefix(s, "Test262:AsyncTestFailure") {
			h.async_failure = strings.clone(s)
		}
	}
	strings.write_byte(&h.output, '\n')
	return js.UNDEFINED
}

js_gc :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	js.gc_collect(ctx.rt)
	return js.UNDEFINED
}

js_eval_script :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	s, ok := js.to_utf8(ctx, js.arg(args, 0), context.temp_allocator)
	if !ok {return js.EXCEPTION}
	return js.eval_script(ctx, s, "<evalScript>")
}

js_create_realm :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	c2 := js.context_new(ctx.rt)
	return install_helpers(c2)
}

js_detach :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	return js.detach_array_buffer_value(ctx, js.arg(args, 0))
}

js_html_dda :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	return js.NULL
}

js_agent_unsupported :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	return js.throw_type_error(ctx, "$262.agent is not supported")
}

js_monotonic_now :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	return js.mk_number(f64(time.tick_now()._nsec) / 1e6)
}

js_sleep :: proc(ctx: ^js.Context, this: js.Value, args: []js.Value, magic: i32) -> js.Value {
	d, _ := js.to_number(ctx, js.arg(args, 0))
	time.sleep(time.Duration(d * f64(time.Millisecond)))
	return js.UNDEFINED
}

install_helpers :: proc(ctx: ^js.Context) -> js.Value {
	g := ctx.global_obj
	js.def_method(ctx, g, "print", js_print, 1)
	obj := js.new_plain_object(ctx)
	js.def_method(ctx, obj, "createRealm", js_create_realm, 0)
	js.def_method(ctx, obj, "detachArrayBuffer", js_detach, 1)
	js.def_method(ctx, obj, "evalScript", js_eval_script, 1)
	js.def_method(ctx, obj, "gc", js_gc, 0)
	dda := js.fn_obj(ctx, "IsHTMLDDA", js_html_dda, 0)
	dda.is_htmldda = true
	js.def_value(ctx, obj, "IsHTMLDDA", js.mk_obj(dda))
	js.def_value(ctx, obj, "global", js.mk_obj(g))
	agent := js.new_plain_object(ctx)
	for name in ([]string{"start", "broadcast", "getReport", "receiveBroadcast", "report", "leaving"}) {
		js.def_method(ctx, agent, name, js_agent_unsupported, 1)
	}
	js.def_method(ctx, agent, "sleep", js_sleep, 1)
	js.def_method(ctx, agent, "monotonicNow", js_monotonic_now, 0)
	js.def_value(ctx, obj, "agent", js.mk_obj(agent))
	js.def_value(ctx, g, "$262", js.mk_obj(obj))
	return js.mk_obj(obj)
}

// --- test262 metadata ---

Test_Meta :: struct {
	includes:     [dynamic]string,
	flags:        [dynamic]string,
	features:     [dynamic]string,
	negative:     bool,
	neg_phase:    string,
	neg_type:     string,
}

// The YAML front matter /*--- ... ---*/, parsed the way run-test262.c does (lists in [] or "- " lines).
parse_meta :: proc(src: string) -> Test_Meta {
	m: Test_Meta
	start := strings.index(src, "/*---")
	if start < 0 {return m}
	end := strings.index(src[start:], "---*/")
	if end < 0 {return m}
	desc := src[start + 5:start + end]
	get_list :: proc(desc: string, tag: string, out: ^[dynamic]string) {
		p := strings.index(desc, tag)
		if p < 0 {return}
		rest := desc[p + len(tag):]
		// inline [a, b]
		i := 0
		for i < len(rest) && (rest[i] == ' ' || rest[i] == '\t') {i += 1}
		if i < len(rest) && rest[i] == '[' {
			e := strings.index_byte(rest[i:], ']')
			if e < 0 {return}
			items := rest[i + 1:i + e]
			for it in strings.split(items, ",", context.temp_allocator) {
				t := strings.trim_space(it)
				if t != "" {append(out, t)}
			}
			return
		}
		// block list of "  - item" lines
		lines := strings.split_lines(rest, context.temp_allocator)
		for ln, k in lines {
			if k == 0 {continue}
			t := strings.trim_space(ln)
			if strings.has_prefix(t, "- ") {
				append(out, strings.trim_space(t[2:]))
			} else if t == "" {
				continue
			} else {
				break
			}
		}
	}
	get_list(desc, "includes:", &m.includes)
	get_list(desc, "flags:", &m.flags)
	get_list(desc, "features:", &m.features)
	if p := strings.index(desc, "negative:"); p >= 0 {
		m.negative = true
		rest := desc[p:]
		if q := strings.index(rest, "type:"); q >= 0 {
			t := strings.trim_left_space(rest[q + 5:])
			e := 0
			for e < len(t) && t[e] != ' ' && t[e] != '\r' && t[e] != '\n' {e += 1}
			m.neg_type = t[:e]
		}
		if q := strings.index(rest, "phase:"); q >= 0 {
			t := strings.trim_left_space(rest[q + 6:])
			e := 0
			for e < len(t) && t[e] != ' ' && t[e] != '\r' && t[e] != '\n' {e += 1}
			m.neg_phase = t[:e]
		}
	}
	return m
}

has_flag :: proc(m: ^Test_Meta, f: string) -> bool {
	for x in m.flags {if x == f {return true}}
	return false
}

// --- configuration (test262.conf) ---

Config :: struct {
	run_dir:        string,
	features_on:    map[string]bool,
	features_skip:  map[string]bool,
	excludes:       [dynamic]string,
	reexcludes:     [dynamic]string, // "!path" re-inclusions
	quickjs_errors: map[string]bool,
}

load_config :: proc(dir: string) -> (cfg: Config, ok: bool) {
	cfg.run_dir = dir
	path := pjoin(dir, "test262.conf")
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("judge: cannot read", path)
		return
	}
	section := ""
	for raw in strings.split_lines(string(data)) {
		line := raw
		if h := strings.index_byte(line, '#'); h >= 0 {line = line[:h]}
		line = strings.trim_space(line)
		if line == "" {continue}
		if line[0] == '[' {section = line; continue}
		switch section {
		case "[features]":
			name := line
			val := ""
			if e := strings.index_byte(line, '='); e >= 0 {
				name = strings.trim_space(line[:e])
				val = strings.trim_space(line[e + 1:])
			}
			if val == "skip" {cfg.features_skip[name] = true} else {cfg.features_on[name] = true}
		case "[exclude]":
			if line[0] == '!' {append(&cfg.reexcludes, line[1:])} else {append(&cfg.excludes, line)}
		}
	}
	edata, eerr := os.read_entire_file(pjoin(dir, "test262_errors.txt"), context.allocator)
	if eerr == nil {
		for line in strings.split_lines(string(edata)) {
			if c := strings.index(line, ".js:"); c >= 0 {
				cfg.quickjs_errors[line[:c + 3]] = true
			}
		}
	}
	ok = true
	return
}

is_excluded :: proc(cfg: ^Config, rel: string) -> bool {
	for r in cfg.reexcludes {if strings.has_prefix(rel, r) {return false}}
	for e in cfg.excludes {if strings.has_prefix(rel, e) {return true}}
	return false
}

// --- running one test ---

Outcome :: enum u8 {pass, fail, skip, crash, timeout}

Result :: struct {
	path:    string,
	outcome: Outcome,
	msg:     string,
	ms:      f64,
}

Harness_Cache :: struct {
	files: map[string]string,
}

harness_source :: proc(hc: ^Harness_Cache, dir: string, name: string) -> (string, bool) {
	if s, ok := hc.files[name]; ok {return s, true}
	data, err := os.read_entire_file(pjoin(dir, "test262/harness", name), context.allocator)
	if err != nil {return "", false}
	hc.files[strings.clone(name)] = string(data)
	return string(data), true
}

exception_text :: proc(ctx: ^js.Context, e: js.Value) -> string {
	s, ok := js.to_utf8(ctx, e, context.allocator)
	if !ok {
		js.pending_exception(ctx)
		return "<exception while converting the exception>"
	}
	return s
}

run_test262_file :: proc(cfg: ^Config, hc: ^Harness_Cache, rel: string, verbose: bool) -> (res: Result) {
	res.path = rel
	full := pjoin(cfg.run_dir, rel)
	data, err := os.read_entire_file(full, context.allocator)
	if err != nil {
		res.outcome = .fail
		res.msg = "cannot read test file"
		return res
	}
	src := string(data)
	meta := parse_meta(src)
	for f in meta.features {
		if cfg.features_on[f] {continue}
		res.outcome = .skip
		res.msg = fmt.aprintf("feature %s", f)
		return res
	}
	is_module := has_flag(&meta, "module")
	is_async := has_flag(&meta, "async")
	strict := has_flag(&meta, "onlyStrict")
	raw := has_flag(&meta, "raw")
	can_block := !has_flag(&meta, "CanBlockIsFalse")

	h := new(Host)
	h.test_path, _ = strings.replace_all(full, "\\", "/")
	h.deadline = time.tick_add(time.tick_now(), 20 * time.Second)
	h.can_block = can_block
	strings.builder_init(&h.output)
	cfgr := js.DEFAULT_CONFIG
	cfgr.compile = compile_hook()
	cfgr.max_stack_bytes = JUDGE_STACK_BYTES
	cfgr.load_module = judge_load_module
	cfgr.load_user = h
	cfgr.interrupt = judge_interrupt
	cfgr.interrupt_user = h
	cfgr.can_block = can_block
	cfgr.malloc_limit = 1 << 30
	rt := js.engine_new(context.allocator, cfgr)
	rt.host_data = h
	set_host_hooks()
	ctx := js.context_new(rt)
	install_helpers(ctx)
	t0 := time.tick_now()
	defer {
		res.ms = time.duration_milliseconds(time.tick_since(t0))
		js.engine_free(rt)
		strings.builder_destroy(&h.output)
		delete(h.modules)
		free(h)
	}
	includes := make([dynamic]string, context.temp_allocator)
	if !raw {
		append(&includes, "assert.js")
		append(&includes, "sta.js")
	}
	for inc in meta.includes {append(&includes, inc)}
	if is_async {append(&includes, "doneprintHandle.js")}
	for inc in includes {
		hs, ok := harness_source(hc, cfg.run_dir, inc)
		if !ok {
			res.outcome = .fail
			res.msg = fmt.aprintf("missing harness file %s", inc)
			return res
		}
		r := js.eval_source(ctx, hs, inc)
		if js.is_exception(r) {
			e := js.pending_exception(ctx)
			res.outcome = .fail
			res.msg = fmt.aprintf("error in harness %s: %s", inc, exception_text(ctx, e))
			return res
		}
	}
	test_src := src
	if strict && !is_module {test_src = strings.concatenate({"'use strict';\n", src})}
	failure := ""
	threw := false
	thrown := js.UNDEFINED
	result: js.Value
	{
		req := js.Compile_Request{kind = is_module ? .module : .script, source = test_src, filename = h.test_path, strict = strict}
		m := js.host_enter(rt)
		fb := js.compile(ctx, &req)
		if js.is_exception(fb) {
			result = fb
		} else if fb.tag == .module {
			mod := cast(^js.Module)fb.u.ptr
			h.modules[strings.clone(h.test_path)] = fb
			js.persist(rt, fb)
			result = js.module_run(ctx, mod)
		} else {
			result = js.run_function_bc(ctx, fb)
		}
		js.host_exit(rt, m, result)
	}
	if js.is_exception(result) {
		threw = true
		thrown = js.pending_exception(ctx)
		js.persist(rt, thrown)
	} else {
		js.persist(rt, result)
		if is_async || is_module {
			if !js.run_jobs(rt) {
				threw = true
				thrown = js.pending_exception(ctx)
				js.persist(rt, thrown)
			}
		}
		if !threw && is_module {
			pd := js.promise_data(result)
			if pd != nil {
				switch pd.state {
				case .fulfilled:
				case .rejected:
					threw = true
					thrown = pd.result
				case .pending:
					failure = "module evaluation promise is pending"
				}
			}
		}
		if !threw && is_async && failure == "" {
			if h.async_failure != "" {
				failure = h.async_failure
			} else if h.async_done != 1 {
				failure = "$DONE() not called"
			}
		}
	}
	if h.timed_out {
		res.outcome = .timeout
		res.msg = "timeout"
		return res
	}
	if meta.negative {
		if !threw {
			res.outcome = .fail
			res.msg = fmt.aprintf("expected error %s", meta.neg_type)
			return res
		}
		txt := exception_text(ctx, thrown)
		cls := txt
		if c := strings.index_byte(txt, ':'); c >= 0 {cls = txt[:c]}
		if meta.neg_type != "" && cls != meta.neg_type {
			res.outcome = .fail
			res.msg = fmt.aprintf("unexpected error type: %s", txt)
			return res
		}
		res.outcome = .pass
		return res
	}
	if threw {
		res.outcome = .fail
		res.msg = exception_text(ctx, thrown)
		if verbose {
			st := js.get_property_str(ctx, thrown, "stack")
			if st.tag == .string {
				s, _ := js.to_utf8(ctx, st, context.allocator)
				res.msg = strings.concatenate({res.msg, "\n", s})
			}
		}
		return res
	}
	if failure != "" {
		res.outcome = .fail
		res.msg = failure
		return res
	}
	res.outcome = .pass
	if verbose && strings.builder_len(h.output) > 0 {
		fmt.print(strings.to_string(h.output))
	}
	return res
}

// --- test list ---

collect_tests :: proc(cfg: ^Config, filter: string, stride: int) -> [dynamic]string {
	list := make([dynamic]string)
	root := pjoin(cfg.run_dir, "test262/test")
	walk :: proc(dir: string, rel_prefix: string, cfg: ^Config, filter: string, list: ^[dynamic]string) {
		entries, err := os.read_all_directory_by_path(dir, context.allocator)
		if err != nil {return}
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for e in entries {
			rel := strings.concatenate({rel_prefix, e.name})
			if e.type == .Directory {
				if is_excluded(cfg, strings.concatenate({rel, "/"})) {continue}
				walk(e.fullpath, strings.concatenate({rel, "/"}), cfg, filter, list)
				continue
			}
			if !strings.has_suffix(e.name, ".js") || strings.contains(e.name, "_FIXTURE") {continue}
			if is_excluded(cfg, rel) {continue}
			if filter != "" && !strings.contains(rel, filter) {continue}
			append(list, rel)
		}
	}
	walk(root, "test262/test/", cfg, filter, &list)
	if stride > 1 {
		out := make([dynamic]string)
		for t, i in list {if i % stride == 0 {append(&out, t)}}
		return out
	}
	return list
}

// --- worker / supervisor ---

worker_main :: proc(list_path: string, run_dir: string, out_path: string) -> int {
	if !load_compiler() {return 2}
	cfg, ok := load_config(run_dir)
	if !ok {return 2}
	data, err := os.read_entire_file(list_path, context.allocator)
	if err != nil {return 2}
	out, oerr := os.open(out_path, {.Write, .Create, .Trunc})
	if oerr != nil {return 2}
	defer os.close(out)
	hc: Harness_Cache
	for line in strings.split_lines(string(data)) {
		t := strings.trim_space(line)
		if t == "" {continue}
		_, _ = os.write_string(out, fmt.tprintf("T %s\n", t))
		os.flush(out)
		r := run_test262_file(&cfg, &hc, t, false)
		msg, _ := strings.replace_all(r.msg, "\n", " ")
		msg, _ = strings.replace_all(msg, "\r", " ")
		_, _ = os.write_string(out, fmt.tprintf("R %s %v %.1f %s\n", r.path, r.outcome, r.ms, msg))
		os.flush(out)
		free_all(context.temp_allocator)
	}
	return 0
}

Worker :: struct {
	tests:     []string,
	next:      int,
	process:   os.Process,
	running:   bool,
	out_path:  string,
	list_path: string,
	started:   time.Tick,
	last_size: i64,
	last_progress: time.Tick,
}

supervise :: proc(cfg: ^Config, tests: []string, jobs: int, out_dir: string) -> map[string]Result {
	results := make(map[string]Result)
	n := min(jobs, max(len(tests), 1))
	workers := make([]Worker, n)
	for i in 0 ..< n {
		w := &workers[i]
		chunk := make([dynamic]string)
		for j := i; j < len(tests); j += n {append(&chunk, tests[j])}
		w.tests = chunk[:]
		w.out_path = fmt.aprintf("%s/worker%d.out", out_dir, i)
		w.list_path = fmt.aprintf("%s/worker%d.list", out_dir, i)
	}
	exe := os.args[0]
	start_worker :: proc(w: ^Worker, exe: string, run_dir: string) {
		sb := strings.builder_make()
		for t in w.tests[w.next:] {strings.write_string(&sb, t); strings.write_byte(&sb, '\n')}
		_ = os.write_entire_file(w.list_path, sb.buf[:])
		p, err := os.process_start(os.Process_Desc{command = {exe, "worker", w.list_path, run_dir, w.out_path}})
		if err != nil {
			fmt.eprintln("judge: cannot start worker:", err)
			w.running = false
			return
		}
		w.process = p
		w.running = true
		w.started = time.tick_now()
		w.last_progress = w.started
		w.last_size = 0
	}
	harvest :: proc(w: ^Worker, results: ^map[string]Result, crashed: bool) {
		data, err := os.read_entire_file(w.out_path, context.allocator)
		if err != nil {return}
		last_started := ""
		for line in strings.split_lines(string(data)) {
			if strings.has_prefix(line, "T ") {
				last_started = line[2:]
			} else if strings.has_prefix(line, "R ") {
				rest := line[2:]
				sp1 := strings.index_byte(rest, ' ')
				if sp1 < 0 {continue}
				path := rest[:sp1]
				rest = rest[sp1 + 1:]
				sp2 := strings.index_byte(rest, ' ')
				if sp2 < 0 {continue}
				oc := rest[:sp2]
				rest = rest[sp2 + 1:]
				sp3 := strings.index_byte(rest, ' ')
				ms := 0.0
				msg := ""
				if sp3 >= 0 {
					ms, _ = strconv.parse_f64(rest[:sp3])
					msg = rest[sp3 + 1:]
				} else {
					ms, _ = strconv.parse_f64(rest)
				}
				o: Outcome
				switch oc {
				case "pass": o = .pass
				case "fail": o = .fail
				case "skip": o = .skip
				case "timeout": o = .timeout
				case: o = .crash
				}
				results[strings.clone(path)] = Result{path = strings.clone(path), outcome = o, msg = strings.clone(msg), ms = ms}
				if path == last_started {last_started = ""}
				w.next += 1
			}
		}
		if crashed && last_started != "" {
			results[strings.clone(last_started)] = Result{path = strings.clone(last_started), outcome = .crash, msg = "worker crashed or hung"}
			w.next += 1
		}
	}
	for &w in workers {start_worker(&w, exe, cfg.run_dir)}
	total := len(tests)
	last_report := time.tick_now()
	for {
		active := 0
		for &w in workers {
			if !w.running {continue}
			active += 1
			st, err := os.process_wait(w.process, 0)
			if err == nil && st.exited {
				w.running = false
				before := w.next
				if os.get_env("JUDGE_DEBUG", context.temp_allocator) != "" {
					fmt.eprintf("judge: worker exited with %d (%d tests left)\n", st.exit_code, len(w.tests) - w.next)
				}
				harvest(&w, &results, st.exit_code != 0)
				if w.next < len(w.tests) {
					if w.next == before {w.next += 1} // no progress: skip the culprit
					start_worker(&w, exe, cfg.run_dir)
				}
				continue
			}
			// hang detection: no output growth for 90 s
			fi, ferr := os.stat(w.out_path, context.allocator)
			if ferr == nil {
				if fi.size != w.last_size {
					w.last_size = fi.size
					w.last_progress = time.tick_now()
				} else if time.tick_since(w.last_progress) > 90 * time.Second {
					_ = os.process_kill(w.process)
					_, _ = os.process_wait(w.process)
					w.running = false
					harvest(&w, &results, true)
					if w.next < len(w.tests) {start_worker(&w, exe, cfg.run_dir)}
				}
			}
		}
		if active == 0 {break}
		if time.tick_since(last_report) > 10 * time.Second {
			done := 0
			for &w in workers {done += w.next}
			fmt.eprintf("judge: ~%d/%d tests\n", done, total)
			last_report = time.tick_now()
		}
		time.sleep(50 * time.Millisecond)
	}
	return results
}

// --- reporting ---

Bucket :: struct {
	total, pass, fail, skip, qjs_pass, both_pass: int,
}

group_of :: proc(path: string) -> string {
	// test262/test/<top>/<sub>/...
	p := strings.trim_prefix(path, "test262/test/")
	parts := strings.split(p, "/", context.temp_allocator)
	if len(parts) >= 3 {return fmt.tprintf("%s/%s", parts[0], parts[1])}
	if len(parts) >= 2 {return parts[0]}
	return p
}

report :: proc(cfg: ^Config, results: ^map[string]Result, out_dir: string) {
	buckets := make(map[string]Bucket)
	tops := make(map[string]Bucket)
	all: Bucket
	keys := make([dynamic]string)
	for k, _ in results {append(&keys, k)}
	slice.sort(keys[:])
	errs := strings.builder_make()
	for k in keys {
		r := results[k]
		g := group_of(k)
		top := g
		if s := strings.index_byte(g, '/'); s >= 0 {top = g[:s]}
		upd :: proc(b: ^Bucket, r: Result, qjs_fails: bool) {
			if r.outcome == .skip {b.skip += 1; return}
			b.total += 1
			if r.outcome == .pass {b.pass += 1} else {b.fail += 1}
			if !qjs_fails {
				b.qjs_pass += 1
				if r.outcome == .pass {b.both_pass += 1}
			}
		}
		qf := cfg.quickjs_errors[k]
		b := buckets[g]
		upd(&b, r, qf)
		buckets[g] = b
		t := tops[top]
		upd(&t, r, qf)
		tops[top] = t
		upd(&all, r, qf)
		if r.outcome != .pass && r.outcome != .skip {
			fmt.sbprintf(&errs, "%s: %v: %s\n", k, r.outcome, r.msg)
		}
	}
	_ = os.write_entire_file(fmt.tprintf("%s/jsrt_errors.txt", out_dir), errs.buf[:])
	md := strings.builder_make()
	pct :: proc(a, b: int) -> f64 {return b == 0 ? 100 : 100 * f64(a) / f64(b)}
	fmt.sbprintf(&md, "# test262 on the Odin runtime (src/engine/jsrt)\n\n")
	fmt.sbprintf(&md, "Overall: %d/%d passed (%.2f %%); of the tests QuickJS-ng passes: %d/%d (%.2f %%); skipped %d\n\n", all.pass, all.total, pct(all.pass, all.total), all.both_pass, all.qjs_pass, pct(all.both_pass, all.qjs_pass), all.skip)
	write_table :: proc(md: ^strings.Builder, m: map[string]Bucket, title: string) {
		names := make([dynamic]string, context.temp_allocator)
		for k, _ in m {append(&names, k)}
		slice.sort(names[:])
		fmt.sbprintf(md, "## %s\n\n| directory | passed | total | %% | %% of QuickJS |\n|---|---:|---:|---:|---:|\n", title)
		for n in names {
			b := m[n]
			fmt.sbprintf(md, "| %s | %d | %d | %.1f | %.1f |\n", n, b.pass, b.total, pct(b.pass, b.total), pct(b.both_pass, b.qjs_pass))
		}
		fmt.sbprintf(md, "\n")
	}
	write_table(&md, tops, "By top-level directory")
	write_table(&md, buckets, "By directory")
	_ = os.write_entire_file(fmt.tprintf("%s/jsrt_table.md", out_dir), md.buf[:])
	fmt.printf("test262: %d/%d passed (%.2f %%), %.2f %% of QuickJS-ng's passes, %d skipped\n", all.pass, all.total, pct(all.pass, all.total), pct(all.both_pass, all.qjs_pass), all.skip)
	for n, b in tops {
		fmt.printf("  %-12s %6d/%6d  %.1f %%  (%.1f %% of QuickJS)\n", n, b.pass, b.total, pct(b.pass, b.total), pct(b.both_pass, b.qjs_pass))
	}
}

// --- eval mode ---

eval_main :: proc(path: string) -> int {
	if !load_compiler() {return 2}
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", path)
		return 2
	}
	h := new(Host)
	h.test_path = path
	h.deadline = time.tick_add(time.tick_now(), 3600 * time.Second)
	strings.builder_init(&h.output)
	cfgr := js.DEFAULT_CONFIG
	cfgr.compile = compile_hook()
	cfgr.max_stack_bytes = JUDGE_STACK_BYTES
	cfgr.load_module = judge_load_module
	cfgr.load_user = h
	cfgr.interrupt = judge_interrupt
	cfgr.interrupt_user = h
	rt := js.engine_new(context.allocator, cfgr)
	rt.host_data = h
	set_host_hooks()
	ctx := js.context_new(rt)
	install_helpers(ctx)
	console := js.new_plain_object(ctx)
	js.def_method(ctx, console, "log", js_print, 1)
	js.def_value(ctx, ctx.global_obj, "console", js.mk_obj(console))
	t0 := time.tick_now()
	kind: js.Compile_Kind = strings.has_suffix(path, ".mjs") ? .module : .script
	r := js.eval_source(ctx, string(data), path, kind)
	code := 0
	if js.is_exception(r) {
		e := js.pending_exception(ctx)
		fmt.print(strings.to_string(h.output))
		fmt.println("Uncaught", exception_text(ctx, e))
		st := js.get_property_str(ctx, e, "stack")
		if st.tag == .string {
			s, _ := js.to_utf8(ctx, st, context.allocator)
			fmt.println(s)
		}
		code = 1
	} else {
		js.persist(rt, r)
		if !js.run_jobs(rt) {
			e := js.pending_exception(ctx)
			fmt.println("Uncaught (job)", exception_text(ctx, e))
			code = 1
		}
		fmt.print(strings.to_string(h.output))
		if !js.is_undefined(r) && r.tag != .object {
			s, _ := js.to_utf8(ctx, r, context.allocator)
			fmt.println("=>", s)
		}
	}
	dt := time.tick_since(t0)
	st := js.heap_stats(rt)
	fmt.eprintf("[%.1f ms, heap %d KiB (peak %d KiB), %d GCs, max pause %.2f ms]\n", time.duration_milliseconds(dt), st.heap_bytes / 1024, st.peak_heap_bytes / 1024, st.gc_count, f64(st.gc_max_pause_ns) / 1e6)
	js.engine_free(rt)
	return code
}

main :: proc() {
	args := os.args
	if len(args) < 2 {
		fmt.eprintln("usage: judge eval <file.js> | test <test262 path> | test262 [options] | worker <list> <dir>")
		os.exit(2)
	}
	switch args[1] {
	case "eval":
		if len(args) < 3 {os.exit(2)}
		os.exit(eval_main(args[2]))
	case "fuzz", "fuzzrun", "compile":
		os.exit(fuzz_args(args))
	case "worker":
		if len(args) < 5 {os.exit(2)}
		os.exit(worker_main(args[2], args[3], args[4]))
	case "test":
		if len(args) < 3 {os.exit(2)}
		if !load_compiler() {os.exit(2)}
		dir := len(args) > 3 ? args[3] : "build/test262/run"
		cfg, ok := load_config(dir)
		if !ok {os.exit(2)}
		hc: Harness_Cache
		rel := args[2]
		if !strings.has_prefix(rel, "test262/") {rel = strings.concatenate({"test262/test/", rel})}
		r := run_test262_file(&cfg, &hc, rel, true)
		fmt.printf("%s: %v %s (%.1f ms)\n", r.path, r.outcome, r.msg, r.ms)
		os.exit(r.outcome == .pass ? 0 : 1)
	case "test262":
		dir := "build/test262/run"
		out := "build/test262"
		jobs := max(os.get_processor_core_count() / 2, 1)
		filter := ""
		stride := 1
		for i := 2; i < len(args); i += 1 {
			switch args[i] {
			case "-dir": i += 1; dir = args[i]
			case "-out": i += 1; out = args[i]
			case "-j": i += 1; jobs, _ = strconv.parse_int(args[i])
			case "-filter": i += 1; filter = args[i]
			case "-stride": i += 1; stride, _ = strconv.parse_int(args[i])
			}
		}
		cfg, ok := load_config(dir)
		if !ok {os.exit(2)}
		tests := collect_tests(&cfg, filter, stride)
		fmt.eprintf("judge: %d tests, %d workers\n", len(tests), jobs)
		t0 := time.tick_now()
		results := supervise(&cfg, tests[:], jobs, out)
		report(&cfg, &results, out)
		fmt.eprintf("judge: %.1f s\n", time.duration_seconds(time.tick_since(t0)))
	case:
		fmt.eprintln("unknown mode", args[1])
		os.exit(2)
	}
	_ = runtime.Allocator{}
	_ = sync.Mutex{}
}
