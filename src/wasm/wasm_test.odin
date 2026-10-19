package wasm

// Both engines, same expectations: calls, host functions (pointer checks, strings, 64-bit and float values, traps
// raised by the host, nesting), unknown imports, the import filter, limits, interruption, and the disk cache of
// compiled code (hit, configuration change, corrupted or forged entries).
// The runtime is process-wide: run with -define:ODIN_TEST_THREADS=1 (tools\test_all.ps1 does).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
wat :: proc(t: ^testing.T, text: string) -> []byte {
	if !engine_start(.Wasmtime) { testing.fail_now(t, "wasmtime does not start") }
	out: wt_byte_vec
	e := wasmtime_wat2wasm(raw_data(text), len(text), &out)
	if e != nil {
		msg := wt_error_text(e, context.temp_allocator)
		wasmtime_error_delete(e)
		testing.fail_now(t, msg)
	}
	b := make([]byte, int(out.size), context.temp_allocator)
	copy(b, out.data[:out.size])
	wasm_byte_vec_delete(&out)
	return b
}

@(private = "file")
t_sum :: proc "c" (env: Exec_Env, p: [^]u8, n: i32) -> i32 {
	s: i32
	for i in 0 ..< int(n) { s += i32(p[i]) }
	return s
}

@(private = "file")
t_strlen :: proc "c" (env: Exec_Env, s: cstring) -> i32 {
	n: i32
	p := ([^]u8)(s)
	for p[n] != 0 { n += 1 }
	return n
}

@(private = "file")
t_mix :: proc "c" (env: Exec_Env, a: i64, b: f64, c: f32, d: i32) -> f64 {
	return f64(a) + b + f64(c) + f64(d)
}

@(private = "file")
t_boom :: proc "c" (env: Exec_Env) -> i32 {
	context = default_context()
	trap(env, "boom from the host")
	return 7
}

// host -> guest -> host: calls the guest's table entry `fn` with `v`, returns its result + 1000
@(private = "file")
t_reenter :: proc "c" (env: Exec_Env, fn: i32, v: i32) -> i32 {
	context = default_context()
	inst := owner(env)
	argv := [1]u32{u32(v)}
	if call_indirect(inst, u32(fn), argv[:]) != .Ok { return -1 }
	return i32(argv[0]) + 1000
}

@(private = "file")
t_owner_user :: proc "c" (env: Exec_Env) -> i32 {
	return i32(uintptr(owner(env).user))
}

@(private = "file")
T_SYMBOLS := [?]Native_Symbol{
	{"sum", rawptr(t_sum), "(*~)i", nil},
	{"strlen", rawptr(t_strlen), "($)i", nil},
	{"mix", rawptr(t_mix), "(IFfi)F", nil},
	{"boom", rawptr(t_boom), "()i", nil},
	{"reenter", rawptr(t_reenter), "(ii)i", nil},
	{"user", rawptr(t_owner_user), "()i", nil},
}

@(private = "file")
MODULE :: `(module
  (import "t" "sum" (func $sum (param i32 i32) (result i32)))
  (import "t" "strlen" (func $strlen (param i32) (result i32)))
  (import "t" "mix" (func $mix (param i64 f64 f32 i32) (result f64)))
  (import "t" "boom" (func $boom (result i32)))
  (import "t" "reenter" (func $reenter (param i32 i32) (result i32)))
  (import "t" "user" (func $user (result i32)))
  (import "t" "missing" (func $missing (result i32)))
  (memory (export "memory") 1 1000)
  (data (i32.const 16) "\01\02\03\04hello\00")
  (table 4 funcref)
  (elem (i32.const 1) $double)
  (func $double (param i32) (result i32) local.get 0 i32.const 2 i32.mul)
  (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)
  (func (export "sum4") (result i32) i32.const 16 i32.const 4 call $sum)
  (func (export "sum_at") (param i32 i32) (result i32) local.get 0 local.get 1 call $sum)
  (func (export "hello_len") (result i32) i32.const 20 call $strlen)
  (func (export "strlen_at") (param i32) (result i32) local.get 0 call $strlen)
  (func (export "mix") (param i64 f64) (result f64) local.get 0 local.get 1 f32.const 0.5 i32.const 3 call $mix)
  (func (export "wide") (param i64) (result i64) local.get 0 i64.const 1 i64.add)
  (func (export "boom") (result i32) call $boom drop i32.const 1)
  (func (export "nested") (param i32) (result i32) i32.const 1 local.get 0 call $reenter)
  (func (export "user") (result i32) call $user)
  (func (export "missing") (result i32) call $missing)
  (func (export "spin") (loop $l br $l))
  (func $deep (export "deep") (param i32) (result i32) local.get 0 i32.const 1 i32.add call $deep)
  (func (export "grow") (param i32) (result i32) local.get 0 memory.grow)
  (func (export "unreachable") unreachable)
)`

@(private = "file")
NO_MEMORY_MODULE :: `(module (func (export "f") (result i32) i32.const 5))`

@(private = "file")
setup :: proc(t: ^testing.T, engine: Engine_Kind, cache_dir := "", tweak: proc(rs: ^Runtime_Settings) = nil) {
	runtime_destroy()
	rs := runtime_settings_default()
	rs.engine = engine
	rs.cache_dir = cache_dir
	if tweak != nil { tweak(&rs) }
	configure(rs)
	testing.expect(t, register("t", T_SYMBOLS[:]), "register")
	testing.expect(t, runtime_init(), "runtime_init")
}

@(private = "file")
make_instance :: proc(t: ^testing.T, engine: Engine_Kind, image: []byte, opt: Options = {}, filter: Import_Filter = nil) -> ^Instance {
	o := opt
	if o.stack_size == 0 { o = options_default() }
	o.engine = engine == .Wamr ? .Wamr : .Wasmtime
	inst, err := instance_create(image, rawptr(uintptr(42)), nil, o, "test", filter)
	testing.expectf(t, inst != nil, "instance_create (%v): %s", engine, err)
	delete(err)
	return inst
}

@(test)
calls_and_host_functions :: proc(t: ^testing.T) {
	for engine in Engine_Kind {
		setup(t, engine)
		image := wat(t, MODULE)
		inst := make_instance(t, engine, image)
		if inst == nil { continue }
		defer destroy(inst)
		r, res := call_i32(inst, "add", 40, 2)
		testing.expectf(t, res == .Ok && r == 42, "%v add -> %v %v", engine, r, res)
		r, res = call_i32(inst, "sum4")
		testing.expectf(t, res == .Ok && r == 10, "%v sum (pointer + length) -> %v %v", engine, r, res)
		r, res = call_i32(inst, "hello_len")
		testing.expectf(t, res == .Ok && r == 5, "%v strlen ($) -> %v %v", engine, r, res)
		r, res = call_i32(inst, "user")
		testing.expectf(t, res == .Ok && r == 42, "%v owner(env).user -> %v", engine, r)
		testing.expect(t, has_export(inst, "add") && !has_export(inst, "nope") && !has_export(inst, "memory"), "has_export")
		_, res = call_i32(inst, "nope")
		testing.expect_value(t, res, Call_Result.No_Such_Export)

		// i64 and f64 through raw cells (low half first), and a host function mixing every type
		x := i64(-5_000_000_000)
		cells := [4]u32{u32(u64(x)), u32(u64(x) >> 32), 0, 0}
		res = call_raw(inst, "wide", cells[:2])
		testing.expectf(t, res == .Ok && i64(u64(cells[0]) | u64(cells[1]) << 32) == x + 1, "%v i64 round trip", engine)
		b := f64(0.25)
		bb := transmute(u64)b
		cells = {u32(u64(x)), u32(u64(x) >> 32), u32(bb), u32(bb >> 32)}
		res = call_raw(inst, "mix", cells[:])
		got := transmute(f64)(u64(cells[0]) | u64(cells[1]) << 32)
		testing.expectf(t, res == .Ok && got == f64(x) + 0.25 + 0.5 + 3, "%v mixed types -> %v (%v)", engine, got, res)

		// guest_bytes sees the same memory, bounded
		gb := guest_bytes(inst, 16, 4)
		testing.expect(t, len(gb) == 4 && gb[3] == 4, "guest_bytes")
		testing.expect(t, guest_bytes(inst, 65530, 100) == nil, "guest_bytes out of bounds")
	}
	runtime_destroy()
}

@(test)
pointer_checks :: proc(t: ^testing.T) {
	for engine in Engine_Kind {
		setup(t, engine)
		inst := make_instance(t, engine, wat(t, MODULE))
		if inst == nil { continue }
		defer destroy(inst)
		size := i32(65536)
		cases := [?][2]i32{{size - 4, 4}, {size - 4, 5}, {size, 0}, {size, 1}, {16, -1}, {-1, 1}}
		want := [?]bool{true, false, true, false, false, false}
		for c, i in cases {
			_, res := call_i32(inst, "sum_at", c[0], c[1])
			testing.expectf(t, (res == .Ok) == want[i], "%v sum_at(%d, %d) -> %v", engine, c[0], c[1], res)
		}
		// a string must end inside the memory
		mem := guest_bytes(inst, u32(size - 3), 3)
		copy(mem, "abc")
		_, res := call_i32(inst, "strlen_at", size - 3)
		testing.expectf(t, res == .Trapped, "%v unterminated string at the end of memory -> %v", engine, res)
		r, res2 := call_i32(inst, "add", 1, 1)
		testing.expectf(t, res2 == .Ok && r == 2, "%v usable after the traps", engine)
	}
	runtime_destroy()
}

@(test)
traps_reentrance_and_imports :: proc(t: ^testing.T) {
	for engine in Engine_Kind {
		setup(t, engine)
		inst := make_instance(t, engine, wat(t, MODULE))
		if inst == nil { continue }
		defer destroy(inst)
		_, res := call_i32(inst, "boom")
		testing.expectf(t, res == .Trapped && strings.contains(inst.last_error, "boom from the host"), "%v trap from the host: %q", engine, inst.last_error)
		r, res2 := call_i32(inst, "nested", 21)
		testing.expectf(t, res2 == .Ok && r == 1042, "%v host -> guest -> host -> guest -> %v %v (%s)", engine, r, res2, inst.last_error)
		_, res = call_i32(inst, "missing")
		testing.expectf(t, res == .Trapped, "%v an import the browser lacks traps when called (%s)", engine, inst.last_error)
		_, res = call_i32(inst, "unreachable")
		testing.expectf(t, res == .Trapped && strings.contains(inst.last_error, "unreachable"), "%v unreachable: %q", engine, inst.last_error)
		if engine == .Wasmtime { testing.expectf(t, strings.contains(inst.last_error, "\n    at "), "the wasm stack follows the reason: %q", inst.last_error) }
		_, res = call_i32(inst, "deep", 0)
		testing.expectf(t, res == .Trapped, "%v endless recursion traps (%s)", engine, inst.last_error)
		argv := [1]u32{5}
		testing.expect_value(t, call_indirect(inst, 1, argv[:]), Call_Result.Ok)
		testing.expect_value(t, argv[0], u32(10))
		testing.expect_value(t, call_indirect(inst, 0, argv[:]), Call_Result.Trapped)
		testing.expect_value(t, call_indirect(inst, 99, argv[:]), Call_Result.Trapped)
		r, res2 = call_i32(inst, "add", 2, 3)
		testing.expectf(t, res2 == .Ok && r == 5, "%v usable after every trap", engine)

		refuse := proc(m, f: string) -> bool { return f != "boom" }
		o := options_default()
		o.engine = engine == .Wamr ? .Wamr : .Wasmtime
		bad, err := instance_create(wat(t, MODULE), nil, nil, o, "filtered", refuse)
		testing.expectf(t, bad == nil && strings.contains(err, "t.boom"), "%v filter: %q", engine, err)
		delete(err)

		plain := make_instance(t, engine, wat(t, NO_MEMORY_MODULE))
		if plain != nil {
			r, res2 = call_i32(plain, "f")
			testing.expect(t, res2 == .Ok && r == 5, "module without memory")
			destroy(plain)
		}
		garbage := []byte{0, 'a', 's', 'm', 1, 0, 0, 0, 0xff}
		g, gerr := instance_create(garbage, nil, nil, o, "garbage")
		testing.expectf(t, g == nil && gerr != "", "%v malformed module refused: %q", engine, gerr)
		delete(gerr)
	}
	runtime_destroy()
}

@(test)
memory_limit :: proc(t: ^testing.T) {
	for engine in Engine_Kind {
		setup(t, engine)
		o := options_default()
		o.max_pages = 10
		inst := make_instance(t, engine, wat(t, MODULE), o)
		if inst == nil { continue }
		defer destroy(inst)
		r, res := call_i32(inst, "grow", 5)
		testing.expectf(t, res == .Ok && r == 1, "%v grow within the limit -> %v", engine, r)
		r, res = call_i32(inst, "grow", 100)
		testing.expectf(t, res == .Ok && r == -1, "%v grow past wasm.max_memory_pages fails -> %v", engine, r)
	}
	runtime_destroy()
}

@(test)
interruption :: proc(t: ^testing.T) {
	// wasmtime: a wall-clock deadline
	setup(t, .Wasmtime)
	o := options_default()
	o.max_call_ms = 100
	inst := make_instance(t, .Wasmtime, wat(t, MODULE), o)
	if inst != nil {
		t0 := time.tick_now()
		_, res := call_i32(inst, "spin")
		dt := time.duration_milliseconds(time.tick_since(t0))
		testing.expectf(t, res == .Trapped && dt >= 90 && dt < 1000, "endless loop stopped by the deadline after %.0f ms (%s)", dt, inst.last_error)
		testing.expect(t, strings.contains(inst.last_error, "wasm.max_call_ms"), inst.last_error)
		r, res2 := call_i32(inst, "add", 1, 2)
		testing.expect(t, res2 == .Ok && r == 3, "usable after the deadline")
		destroy(inst)
	}

	// wasmtime: the stop flag, set from another thread, interrupts a call without deadline
	@(static) stop: b32
	sync.atomic_store(&stop, false)
	o.max_call_ms = -1
	o.stop = &stop
	inst = make_instance(t, .Wasmtime, wat(t, MODULE), o)
	if inst != nil {
		th := thread.create_and_start(proc() { time.sleep(80 * time.Millisecond); sync.atomic_store(&stop, true) })
		t0 := time.tick_now()
		_, res := call_i32(inst, "spin")
		dt := time.duration_milliseconds(time.tick_since(t0))
		thread.join(th)
		thread.destroy(th)
		testing.expectf(t, res == .Trapped && dt < 1000, "stop flag interrupts a running call after %.0f ms", dt)
		_, res = call_i32(inst, "add", 1, 2)
		testing.expect(t, res == .Trapped, "nothing runs once the flag is set")
		destroy(inst)
	}

	// wamr: the instruction budget
	setup(t, .Wamr)
	o = options_default()
	o.budget = 5_000_000
	inst = make_instance(t, .Wamr, wat(t, MODULE), o)
	if inst != nil {
		_, res := call_i32(inst, "spin")
		testing.expect(t, res == .Trapped, "wamr: the budget stops an endless loop")
		r, res2 := call_i32(inst, "add", 1, 2)
		testing.expect(t, res2 == .Ok && r == 3, "wamr: usable after the budget")
		destroy(inst)
	}
	runtime_destroy()
}

@(test)
instance_limit :: proc(t: ^testing.T) {
	setup(t, .Wasmtime, tweak = proc(rs: ^Runtime_Settings) { rs.max_instances = 2 })
	image := wat(t, NO_MEMORY_MODULE)
	a := make_instance(t, .Wasmtime, image)
	b := make_instance(t, .Wasmtime, image)
	o := options_default()
	c, err := instance_create(image, nil, nil, o, "third")
	testing.expectf(t, c == nil && strings.contains(err, "wasm.max_instances"), "third instance refused: %q", err)
	delete(err)
	destroy(a)
	c, err = instance_create(image, nil, nil, o, "third")
	testing.expect(t, c != nil, "a slot freed by destroy is usable")
	delete(err)
	destroy(b)
	destroy(c)
	runtime_destroy()
}

@(private = "file")
temp_dir :: proc(t: ^testing.T, name: string) -> string {
	base := os.get_env("TEMP", context.temp_allocator)
	dir, _ := filepath.join({base, fmt.tprintf("wren-wasm-test-%s-%d", name, time.now()._nsec)}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	return dir
}

@(private = "file")
cache_files :: proc(dir: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	infos, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for fi in infos { if strings.has_suffix(fi.name, DISK_EXT) { append(&out, fi.fullpath) } }
	return out
}

@(test)
disk_cache :: proc(t: ^testing.T) {
	dir := temp_dir(t, "cache")
	defer os.remove_all(dir)
	setup(t, .Wasmtime, dir)
	image := wat(t, MODULE)

	inst := make_instance(t, .Wasmtime, image)
	destroy(inst)
	cache_flush()
	s := cache_stats()
	testing.expectf(t, s.compiles == 1 && s.disk_writes == 1, "first load compiles and writes: %v", s)
	inst = make_instance(t, .Wasmtime, image)
	destroy(inst)
	s = cache_stats()
	testing.expectf(t, s.memory_hits == 1 && s.compiles == 1, "second load hits the memory cache: %v", s)
	files := cache_files(dir)
	testing.expect_value(t, len(files), 1)

	// next start: from the disk
	setup(t, .Wasmtime, dir)
	inst = make_instance(t, .Wasmtime, image)
	if inst != nil {
		r, res := call_i32(inst, "sum4")
		testing.expect(t, res == .Ok && r == 10, "a module from the disk cache runs")
		destroy(inst)
	}
	s = cache_stats()
	testing.expectf(t, s.disk_hits == 1 && s.compiles == 0, "next start reads the disk cache: %v", s)

	// a corrupted entry is refused (MAC), deleted, and the module compiled again
	if len(files) == 1 {
		data, _ := os.read_entire_file(files[0], context.temp_allocator)
		data[len(data) - 10] ~= 0xff
		_ = os.write_entire_file(files[0], data)
	}
	setup(t, .Wasmtime, dir)
	inst = make_instance(t, .Wasmtime, image)
	if inst != nil {
		r, res := call_i32(inst, "add", 3, 4)
		testing.expect(t, res == .Ok && r == 7, "runs after a corrupted cache entry")
		destroy(inst)
	}
	cache_flush()
	s = cache_stats()
	testing.expectf(t, s.disk_rejects == 1 && s.compiles == 1 && s.disk_writes == 1, "corrupted entry rejected and rewritten: %v", s)

	// an entry forged with another key (a new profile key: the old MAC no longer matches)
	key_path, _ := filepath.join({dir, KEY_FILE}, context.temp_allocator)
	_ = os.remove(key_path)
	setup(t, .Wasmtime, dir)
	inst = make_instance(t, .Wasmtime, image)
	destroy(inst)
	cache_flush()
	s = cache_stats()
	testing.expectf(t, s.disk_rejects == 1 && s.compiles == 1, "entry of another key rejected: %v", s)

	// a different configuration uses other entries (fingerprint)
	setup(t, .Wasmtime, dir, proc(rs: ^Runtime_Settings) { rs.opt_level = .None })
	inst = make_instance(t, .Wasmtime, image)
	destroy(inst)
	cache_flush()
	s = cache_stats()
	testing.expectf(t, s.compiles == 1 && s.disk_rejects == 0, "another configuration compiles its own entry: %v", s)
	testing.expect_value(t, len(cache_files(dir)), 2)

	// the size limit evicts the least recently used entries
	setup(t, .Wasmtime, dir, proc(rs: ^Runtime_Settings) { rs.cache_disk_max_bytes = 1 })
	inst = make_instance(t, .Wasmtime, wat(t, NO_MEMORY_MODULE))
	destroy(inst)
	cache_flush()
	testing.expect(t, len(cache_files(dir)) <= 1, "disk cache trimmed to its maximum")
	runtime_destroy()
}

@(test)
memory_cache_limit :: proc(t: ^testing.T) {
	setup(t, .Wasmtime, tweak = proc(rs: ^Runtime_Settings) { rs.cache_memory_bytes = 0 })
	image := wat(t, NO_MEMORY_MODULE)
	a := make_instance(t, .Wasmtime, image)
	b := make_instance(t, .Wasmtime, image)
	s := cache_stats()
	testing.expectf(t, s.compiles == 2 && s.memory_hits == 0, "no memory cache: %v", s)
	destroy(a)
	destroy(b)
	runtime_destroy()
}

@(test)
binary_patch :: proc(t: ^testing.T) {
	setup(t, .Wasmtime)
	image := wat(t, MODULE)
	info, err := analyze_image(image)
	testing.expect_value(t, err, "")
	testing.expect(t, info.has_memory && info.memory_export == "memory" && !info.add_memory, "exported memory found")
	testing.expect(t, info.has_table && info.add_table, "unexported table gets an export")
	patched, copied := patch_image(image, info, context.temp_allocator)
	testing.expect(t, copied, "patched")
	info2, _ := analyze_image(patched)
	testing.expect(t, info2.table_export == info.table_export && !info2.add_table, "the patched module exports table 0")
	none, _ := analyze_image(wat(t, NO_MEMORY_MODULE))
	testing.expect(t, !none.has_memory && !none.has_table, "nothing to export")
	runtime_destroy()
}

@(test)
signatures :: proc(t: ^testing.T) {
	params, result, ok := parse_signature("(i*~$IfF)I", context.temp_allocator)
	testing.expect(t, ok && len(params) == 7 && result == .I64, "parse")
	testing.expect_value(t, shape_of(params, result), "ipipIfF_I")
	_, _, ok = parse_signature("(i~)i", context.temp_allocator)
	testing.expect(t, !ok, "a length without its pointer")
	_, _, ok = parse_signature("(x)i", context.temp_allocator)
	testing.expect(t, !ok, "unknown letter")
	_, _, ok = parse_signature("(i)ii", context.temp_allocator)
	testing.expect(t, !ok, "two results")
	for s in T_SYMBOLS { testing.expect(t, signature_supported(string(s.signature)), string(s.signature)) }
	runtime_destroy()
}
