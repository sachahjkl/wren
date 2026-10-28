package jsrt_judge

// judge fuzz <dir> [iterations] [seed]: mutation fuzzing of the bytecode reader and the interpreter.
// Every .js file under <dir> is compiled once (QuickJS-ng's compiler); each iteration takes one
// bytecode image, applies a few random mutations (byte flips, random bytes, truncation, duplicated or
// zeroed spans), loads it with read_object in a fresh runtime and, when the reader accepts it, runs it
// under a 20 ms interrupt budget. The image under test is written to build/fuzz/last.bin before it
// runs, so a crash leaves its reproducer behind. Exit 0 = no crash.

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:sys/windows"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import fe "wb:engine/frontend"
import js "wb:engine/jsrt"

@(private = "file")
Fuzz_Host :: struct {
	deadline: time.Tick,
}

@(private = "file")
fuzz_interrupt :: proc(rt: ^js.Runtime, user: rawptr) -> bool {
	h := cast(^Fuzz_Host)user
	return time.tick_since(h.deadline) > 0
}

@(private = "file")
collect_js :: proc(dir: string, out: ^[dynamic]string) {
	f, err := os.open(dir)
	if err != nil {return}
	defer os.close(f)
	infos, _ := os.read_dir(f, -1, context.allocator)
	for fi in infos {
		p := pjoin(dir, fi.name)
		if fi.type == .Directory {
			collect_js(p, out)
		} else if strings.has_suffix(fi.name, ".js") && !strings.contains(fi.name, "FIXTURE") {
			append(out, p)
		}
	}
}

fuzz_main :: proc(dir: string, iterations: int, seed: u64) -> int {
	if !load_compiler() {return 2}
	rand.reset(seed)
	files := make([dynamic]string)
	collect_js(dir, &files)
	if len(files) == 0 {
		fmt.eprintln("fuzz: no .js files under", dir)
		return 2
	}
	// compile the corpus once (in a throwaway runtime: compile only needs a context)
	corpus := make([dynamic][]u8)
	{
		cfgr := js.DEFAULT_CONFIG
		cfgr.compile = compile_hook()
		rt := js.engine_new(context.allocator, cfgr)
		ctx := js.context_new(rt)
		for p in files {
			data, err := os.read_entire_file(p, context.temp_allocator)
			if err != nil {continue}
			bc, ok := compile_to_bytes(string(data), p)
			if ok {append(&corpus, bc)}
			free_all(context.temp_allocator)
		}
		_ = ctx
		js.engine_free(rt)
	}
	run_mutants := os.get_env("JSRT_FUZZ_RUN", context.temp_allocator) == "1"
	fmt.eprintf("fuzz: %d files, %d bytecode images, %d iterations, seed %d%s\n", len(files), len(corpus), iterations, seed, run_mutants ? ", running the accepted mutants" : "")
	os.make_directory("build/fuzz")
	accepted, threw, completed := 0, 0, 0
	t0 := time.tick_now()
	for it in 0 ..< iterations {
		src := corpus[rand.int_max(len(corpus))]
		img := make([]u8, len(src), context.temp_allocator)
		copy(img, src)
		n := len(img)
		for _ in 0 ..< 1 + rand.int_max(4) {
			if n == 0 {break}
			switch rand.int_max(6) {
			case 0: img[rand.int_max(n)] ~= u8(1 << uint(rand.int_max(8)))
			case 1: img[rand.int_max(n)] = u8(rand.int_max(256))
			case 2: n = rand.int_max(n) + 1
			case 3:
				a := rand.int_max(n)
				l := min(1 + rand.int_max(16), n - a)
				for k in 0 ..< l {img[a + k] = 0}
			case 4:
				a := rand.int_max(n)
				b := rand.int_max(n)
				l := min(1 + rand.int_max(16), n - a, n - b)
				for k in 0 ..< l {img[b + k] = img[a + k]}
			case 5: img[rand.int_max(n)] = u8(rand.int_max(2) == 0 ? 0xff : 0x7f)
			}
		}
		img = img[:n]
		_ = os.write_entire_file("build/fuzz/last.bin", img)
		h := Fuzz_Host{deadline = time.tick_add(time.tick_now(), 20 * time.Millisecond)}
		cfgr := js.DEFAULT_CONFIG
		cfgr.interrupt = fuzz_interrupt
		cfgr.interrupt_user = &h
		cfgr.malloc_limit = 64 << 20
		rt := js.engine_new(context.allocator, cfgr)
		ctx := js.context_new(rt)
		v := js.read_object(ctx, img)
		if !js.is_exception(v) {
			accepted += 1
			// The interpreter trusts operand types (as QuickJS does: bytecode comes from the compiler), so a
			// mutant that survives the reader and the stack verifier can still be type-confused; running
			// them is opt-in (JSRT_FUZZ_RUN=1).
			if run_mutants {
				r := js.eval_bytecode(ctx, img)
				if js.is_exception(r) {threw += 1; js.pending_exception(ctx)} else {completed += 1}
			}
		} else {
			js.pending_exception(ctx)
		}
		js.engine_free(rt)
		free_all(context.temp_allocator)
		if (it + 1) % 1000 == 0 {
			fmt.eprintf("fuzz: %d/%d (accepted %d, threw %d, completed %d) %.0f s\n", it + 1, iterations, accepted, threw, completed, time.duration_seconds(time.tick_since(t0)))
		}
	}
	fmt.printf("fuzz: %d iterations without a crash; reader accepted %d mutants (%d threw, %d completed)\n", iterations, accepted, threw, completed)
	return 0
}

// judge fuzzsrc <dir> [iterations] [seed]: the same for source text. Each iteration mutates one .js file
// (byte flips, deleted/duplicated spans, spliced tokens, truncation), compiles it with the Odin front-end and
// runs it in a fresh runtime under a 20 ms interrupt budget. The compiler only emits well-formed bytecode, so
// any crash is a bug in the front-end or the runtime; the text under test is written to build/fuzz/last.js.
fuzz_src_main :: proc(dir: string, iterations: int, seed: u64) -> int {
	if !load_compiler() {return 2}
	rand.reset(seed)
	files := make([dynamic]string)
	collect_js(dir, &files)
	if len(files) == 0 {
		fmt.eprintln("fuzzsrc: no .js files under", dir)
		return 2
	}
	corpus := make([dynamic]string)
	for p in files {
		data, err := os.read_entire_file(p, context.allocator)
		if err == nil && len(data) < 64 << 10 {append(&corpus, string(data))}
	}
	tokens := []string{"{", "}", "(", ")", "[", "]", ";", ",", "=>", "...", "**", "?.", "??", "yield", "await", "class", "#x", "async", "function*", "\\u", "`${", "/", "/*", "super", "new.target", "import(", "let", "static", "get ", "0n", "\"", "'", "\n"}
	// the test262 harness, when <dir> sits inside a test262 checkout
	harness_names := []string{"assert.js", "sta.js", "compareArray.js", "propertyHelper.js"}
	harness := make([dynamic]string)
	for up := dir; len(up) > 3; up = filepath.dir(up) {
		hd := pjoin(up, "harness")
		if os.exists(pjoin(hd, "assert.js")) {
			for n in harness_names {
				data, err := os.read_entire_file(pjoin(hd, n), context.allocator)
				if err == nil {append(&harness, string(data))}
			}
			break
		}
	}
	if len(harness) != len(harness_names) {clear(&harness)}
	os.make_directory("build/fuzz")
	t0 := time.tick_now()
	compiled, threw := 0, 0
	for it in 0 ..< iterations {
		src := corpus[rand.int_max(len(corpus))]
		buf := make([dynamic]u8, 0, len(src) + 64, context.temp_allocator)
		append(&buf, src)
		for _ in 0 ..< 1 + rand.int_max(3) {
			n := len(buf)
			if n == 0 {break}
			switch rand.int_max(6) {
			case 0: buf[rand.int_max(n)] ~= u8(1 << uint(rand.int_max(8)))
			case 1: buf[rand.int_max(n)] = u8(32 + rand.int_max(95))
			case 2: resize(&buf, rand.int_max(n) + 1)
			case 3:
				a := rand.int_max(n)
				l := min(1 + rand.int_max(24), n - a)
				remove_range(&buf, a, a + l)
			case 4:
				a := rand.int_max(n)
				l := min(1 + rand.int_max(40), n - a)
				chunk := make([]u8, l, context.temp_allocator)
				copy(chunk, buf[a:a + l])
				inject_at(&buf, rand.int_max(n), ..chunk)
			case 5:
				t := tokens[rand.int_max(len(tokens))]
				inject_at(&buf, rand.int_max(n), ..transmute([]u8)t)
			}
		}
		_ = os.write_entire_file("build/fuzz/last.js", buf[:])
		h := Fuzz_Host{deadline = time.tick_add(time.tick_now(), 20 * time.Millisecond)}
		cfgr := js.DEFAULT_CONFIG
		cfgr.compile = compile_hook()
		cfgr.interrupt = fuzz_interrupt
		cfgr.interrupt_user = &h
		cfgr.malloc_limit = 64 << 20
		cfgr.max_stack_bytes = 512 << 10
		rt := js.engine_new(context.allocator, cfgr)
		ctx := js.context_new(rt)
		for hs, i in harness {
			js.eval_source(ctx, hs, harness_names[i])
			js.pending_exception(ctx)
		}
		r := js.eval_source(ctx, string(buf[:]), "fuzz.js")
		if js.is_exception(r) {threw += 1; js.pending_exception(ctx)} else {compiled += 1}
		js.run_jobs(rt)
		js.engine_free(rt)
		free_all(context.temp_allocator)
		if (it + 1) % 2000 == 0 {
			fmt.eprintf("fuzzsrc: %d/%d (ran %d, threw or failed to compile %d) %.0f s\n", it + 1, iterations, compiled, threw, time.duration_seconds(time.tick_since(t0)))
		}
	}
	fmt.printf("fuzzsrc: %d iterations without a crash (%d ran to completion, %d threw or failed to compile)\n", iterations, compiled, threw)
	return 0
}

// Compile source to a QuickJS-ng bytecode image (the Odin front-end, or the reference compiler DLL).
@(private = "file")
compile_to_bytes :: proc(source: string, filename: string) -> ([]u8, bool) {
	if !use_reference_compiler {
		res := fe.compile_program(source, .script, context.temp_allocator, {filename = filename})
		if fe.is_err(res.err) {return nil, false}
		bc := fe.write_object_of(res, context.temp_allocator)
		b := make([]u8, len(bc))
		copy(b, bc)
		return b, true
	}
	out: [^]u8
	out_len: uint
	err: [512]u8
	err_kind: i32
	fname := strings.clone_to_cstring(filename, context.temp_allocator)
	r := qjsc_compile(raw_data(source), len(source), fname, 0, 0, nil, 0, &out, &out_len, raw_data(err[:]), len(err), &err_kind)
	if r != 0 {return nil, false}
	b := make([]u8, int(out_len))
	copy(b, out[:out_len])
	qjsc_free(out)
	return b, true
}

@(private = "file")
crash_handler :: proc "system" (info: ^windows.EXCEPTION_POINTERS) -> windows.LONG {
	context = runtime.default_context()
	when js.JSRT_TRACE_LAST_OP {
		name := "?"
		if js.trace_last_bc != nil {name = fmt.tprint(js.trace_last_bc.func_name)}
		nname := "?"
		if o := js.trace_native_obj; o != nil {
			i := js.shape_find(o.shape, js.pa(.A_name))
			if i >= 0 && o.slots[i].value.tag == .string {
				s := js.as_str(o.slots[i].value)
				if !s.is_wide && !s.is_rope {nname = string(js.str_u8(s)[:s.len])}
			}
		}
		fmt.eprintf("crash 0x%x after %v in function atom %s (last native %s)\n", info.ExceptionRecord.ExceptionCode, js.trace_last_op, name, nname)
		for a, i in js.trace_native_args {fmt.eprintf("  arg %d: %v %p\n", i, a.tag, a.u.ptr)}
	} else {
		fmt.eprintf("crash 0x%x (build with -define:JSRT_TRACE_LAST_OP=true for the last instruction)\n", info.ExceptionRecord.ExceptionCode)
	}
	return 0 // EXCEPTION_CONTINUE_SEARCH
}

// judge fuzzrun <image>: load and run one bytecode image (a fuzz reproducer).
fuzz_run_one :: proc(path: string) -> int {
	windows.AddVectoredExceptionHandler(1, crash_handler)
	img, err := os.read_entire_file(path, context.allocator)
	if err != nil {return 2}
	h := Fuzz_Host{deadline = time.tick_add(time.tick_now(), 200 * time.Millisecond)}
	cfgr := js.DEFAULT_CONFIG
	cfgr.interrupt = fuzz_interrupt
	cfgr.interrupt_user = &h
	rt := js.engine_new(context.allocator, cfgr)
	ctx := js.context_new(rt)
	r := js.eval_bytecode(ctx, img)
	if js.is_exception(r) {
		e := js.pending_exception(ctx)
		s, _ := js.to_utf8(ctx, e, context.allocator)
		fmt.println("threw:", s)
	} else {
		fmt.println("completed")
	}
	js.engine_free(rt)
	return 0
}

fuzz_args :: proc(args: []string) -> int {
	if len(args) >= 3 && args[1] == "fuzzrun" {return fuzz_run_one(args[2])}
	if len(args) >= 4 && args[1] == "compile" {
		// judge compile <file.js> <out.bin>: the bytecode image a host would hand to jsrt_eval
		if !load_compiler() {return 2}
		data, err := os.read_entire_file(args[2], context.allocator)
		if err != nil {return 2}
		bc, ok := compile_to_bytes(string(data), args[2])
		if !ok {return 1}
		return os.write_entire_file(args[3], bc) == nil ? 0 : 2
	}
	if len(args) < 3 {return 2}
	iters := 10000
	seed: u64 = 1
	if len(args) > 3 {iters, _ = strconv.parse_int(args[3])}
	if len(args) > 4 {
		s, _ := strconv.parse_u64(args[4])
		seed = s
	}
	d, _ := filepath.abs(args[2])
	if args[1] == "fuzzsrc" {return fuzz_src_main(d, iters, seed)}
	return fuzz_main(d, iters, seed)
}
