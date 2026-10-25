package wasm

// Calls, host functions (address checks, 64-bit and float values, traps raised by the host, nesting, memory64,
// multi-memory), unknown imports, the import filter, limits, interruption, and the disk cache of compiled code (hit,
// configuration change, corrupted or forged entries). The host functions here are written against the raw interface
// (host.odin) the way the generated trampolines are.
// The runtime is process-wide: run with -define:ODIN_TEST_THREADS=1 (tools\test_all.ps1 does).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "wb:base"
import "wb:tools/testenv"

@(private = "file")
wat :: proc(t: ^testing.T, text: string) -> []byte {
	b, err := wat_to_wasm(text, context.temp_allocator)
	if err != "" { testing.fail_now(t, err) }
	return b
}

// sum(ptr, len) -> i32: the bytes added up
@(private = "file")
t_sum :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	f := frame(env, caller)
	n := addr(&f, a[1])
	p, ok := span(&f, addr(&f, a[0]), n)
	if !ok { context = default_context(); return trap_bounds(&f, "t.sum", "data") }
	s: i32
	for i in 0 ..< int(n) { s += i32(p[i]) }
	a[0] = {}
	a[0].i32 = s
	return nil
}

@(private = "file")
t_mix :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	r := f64(a[0].i64) + a[1].f64 + f64(a[2].f32) + f64(a[3].i32)
	a[0] = {}
	a[0].f64 = r
	return nil
}

@(private = "file")
t_boom :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	context = default_context()
	f := frame(env, caller)
	trap(f.inst, "boom from the host")
	a[0] = {}
	a[0].i32 = 7
	return take_trap(f.inst)
}

// host -> guest -> host: calls the guest's table entry `fn` with `v`, returns its result + 1000
@(private = "file")
t_reenter :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	context = default_context()
	f := frame(env, caller)
	argv := [1]u32{u32(a[1].i32)}
	r: i32 = -1
	if call_indirect(f.inst, u32(a[0].i32), argv[:]) == .Ok { r = i32(argv[0]) + 1000 }
	a[0] = {}
	a[0].i32 = r
	return nil
}

@(private = "file")
t_user :: proc "c" (env: rawptr, caller: Caller, a: [^]Raw, _: uint) -> Trap {
	f := frame(env, caller)
	a[0] = {}
	a[0].i32 = i32(uintptr(f.inst.user))
	return nil
}

@(private = "file")
T_IMPORTS := [?]Import{
	{module = "t", name = "sum", fn = t_sum, params = {.I32, .I32}, results = {.I32}, wide_params = {.I64, .I64}, wide_results = {.I32}},
	{module = "t", name = "mix", fn = t_mix, params = {.I64, .F64, .F32, .I32}, results = {.F64}},
	{module = "t", name = "boom", fn = t_boom, results = {.I32}},
	{module = "t", name = "reenter", fn = t_reenter, params = {.I32, .I32}, results = {.I32}},
	{module = "t", name = "user", fn = t_user, results = {.I32}, realms = 3},
}

@(private = "file")
MODULE :: `(module
  (import "t" "sum" (func $sum (param i32 i32) (result i32)))
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

// memory64: the same import takes 64-bit addresses; a second (32-bit) memory is not what addresses refer to
@(private = "file")
MODULE64 :: `(module
  (import "t" "sum" (func $sum (param i64 i64) (result i32)))
  (memory (export "memory") i64 1)
  (memory $other 1)
  (data (i64.const 32) "\05\06\07")
  (data (memory $other) (i32.const 32) "\09\09\09")
  (func (export "sum3") (result i32) i64.const 32 i64.const 3 call $sum)
  (func (export "sum_far") (result i32) i64.const 0x100000000 i64.const 1 call $sum)
)`

@(private = "file")
WRONG_TYPE_MODULE :: `(module (import "t" "sum" (func (param i64) (result i32))) (func (export "f") (result i32) i64.const 0 call 0))`

@(private = "file")
NO_MEMORY_MODULE :: `(module (func (export "f") (result i32) i32.const 5))`

@(private = "file")
setup :: proc(t: ^testing.T, cache_dir := "", tweak: proc(rs: ^Runtime_Settings) = nil) {
	runtime_destroy()
	rs := runtime_settings_default()
	rs.cache_dir = cache_dir
	rs.features.memory64 = true
	if tweak != nil { tweak(&rs) }
	configure(rs)
	testing.expect(t, register(T_IMPORTS[:]), "register")
	testing.expect(t, runtime_init(), "runtime_init")
}

@(private = "file")
make_instance :: proc(t: ^testing.T, image: []byte, opt: Options = {}, filter: Import_Filter = nil) -> ^Instance {
	o := opt
	if o.max_pages == 0 { o = options_default() }
	inst, err := instance_create(image, rawptr(uintptr(42)), nil, o, "test", filter)
	testing.expectf(t, inst != nil, "instance_create: %s", err)
	delete(err)
	return inst
}

@(test)
calls_and_host_functions :: proc(t: ^testing.T) {
	setup(t)
	inst := make_instance(t, wat(t, MODULE))
	if inst == nil { return }
	defer destroy(inst)
	r, res := call_i32(inst, "add", 40, 2)
	testing.expectf(t, res == .Ok && r == 42, "add -> %v %v", r, res)
	r, res = call_i32(inst, "sum4")
	testing.expectf(t, res == .Ok && r == 10, "sum (address + length) -> %v %v", r, res)
	r, res = call_i32(inst, "user")
	testing.expectf(t, res == .Ok && r == 42, "frame(...).inst.user -> %v", r)
	testing.expect(t, has_export(inst, "add") && !has_export(inst, "nope") && !has_export(inst, "memory"), "has_export")
	_, res = call_i32(inst, "nope")
	testing.expect_value(t, res, Call_Result.No_Such_Export)

	// i64 and f64 through raw cells (low half first), and a host function mixing every type
	x := i64(-5_000_000_000)
	cells := [4]u32{u32(u64(x)), u32(u64(x) >> 32), 0, 0}
	res = call_raw(inst, "wide", cells[:2])
	testing.expect(t, res == .Ok && i64(u64(cells[0]) | u64(cells[1]) << 32) == x + 1, "i64 round trip")
	b := f64(0.25)
	bb := transmute(u64)b
	cells = {u32(u64(x)), u32(u64(x) >> 32), u32(bb), u32(bb >> 32)}
	res = call_raw(inst, "mix", cells[:])
	got := transmute(f64)(u64(cells[0]) | u64(cells[1]) << 32)
	testing.expectf(t, res == .Ok && got == f64(x) + 0.25 + 0.5 + 3, "mixed types -> %v (%v)", got, res)

	// guest_bytes sees the same memory, bounded
	gb := guest_bytes(inst, 16, 4)
	testing.expect(t, len(gb) == 4 && gb[3] == 4, "guest_bytes")
	testing.expect(t, guest_bytes(inst, 65530, 100) == nil, "guest_bytes out of bounds")
	realms, found := import_realms("t", "user")
	testing.expect(t, found && realms == 3, "import_realms")
	_, found = import_realms("t", "nope")
	testing.expect(t, !found, "import_realms of an unknown import")
	runtime_destroy()
}

@(test)
address_checks :: proc(t: ^testing.T) {
	setup(t)
	inst := make_instance(t, wat(t, MODULE))
	if inst == nil { return }
	defer destroy(inst)
	size := i32(65536)
	cases := [?][2]i32{{size - 4, 4}, {size - 4, 5}, {size, 0}, {size, 1}, {16, -1}, {-1, 1}, {-1, 0}}
	want := [?]bool{true, false, true, false, false, false, false}
	for c, i in cases {
		_, res := call_i32(inst, "sum_at", c[0], c[1])
		testing.expectf(t, (res == .Ok) == want[i], "sum_at(%d, %d) -> %v", c[0], c[1], res)
	}
	testing.expectf(t, strings.contains(inst.last_error, "out of bounds"), "the trap says why: %q", inst.last_error)
	// the memory grows: an address past the old end becomes valid (the cached size is refreshed)
	r, res := call_i32(inst, "grow", 1)
	testing.expect(t, res == .Ok && r == 1, "grow")
	_, res = call_i32(inst, "sum_at", size + 100, 4)
	testing.expect(t, res == .Ok, "an address in the grown memory is accepted")
	r, res = call_i32(inst, "add", 1, 1)
	testing.expect(t, res == .Ok && r == 2, "usable after the traps")
	runtime_destroy()
}

@(test)
memory64 :: proc(t: ^testing.T) {
	setup(t)
	inst := make_instance(t, wat(t, MODULE64))
	if inst == nil { return }
	defer destroy(inst)
	testing.expect(t, inst.memory64, "memory 0 is 64-bit")
	r, res := call_i32(inst, "sum3")
	testing.expectf(t, res == .Ok && r == 18, "a host function with 64-bit addresses reads memory 0 -> %v %v (%s)", r, res, inst.last_error)
	_, res = call_i32(inst, "sum_far")
	testing.expectf(t, res == .Trapped && strings.contains(inst.last_error, "out of bounds"), "a 64-bit address past the end traps: %q", inst.last_error)
	// the same compiled host function still serves 32-bit modules
	plain := make_instance(t, wat(t, MODULE))
	if plain != nil {
		r, res = call_i32(plain, "sum4")
		testing.expect(t, res == .Ok && r == 10, "32-bit module after a memory64 one")
		destroy(plain)
	}
	runtime_destroy()
}

@(test)
traps_reentrance_and_imports :: proc(t: ^testing.T) {
	setup(t)
	inst := make_instance(t, wat(t, MODULE))
	if inst == nil { return }
	defer destroy(inst)
	_, res := call_i32(inst, "boom")
	testing.expectf(t, res == .Trapped && strings.contains(inst.last_error, "boom from the host"), "trap from the host: %q", inst.last_error)
	r, res2 := call_i32(inst, "nested", 21)
	testing.expectf(t, res2 == .Ok && r == 1042, "host -> guest -> host -> guest -> %v %v (%s)", r, res2, inst.last_error)
	_, res = call_i32(inst, "missing")
	testing.expectf(t, res == .Trapped && strings.contains(inst.last_error, "does not provide"), "an import the browser lacks traps when called (%s)", inst.last_error)
	if wrong := make_instance(t, wat(t, WRONG_TYPE_MODULE)); wrong != nil {
		_, res = call_i32(wrong, "f")
		testing.expectf(t, res == .Trapped && strings.contains(wrong.last_error, "does not match"), "an import of another type traps when called (%s)", wrong.last_error)
		destroy(wrong)
	}
	_, res = call_i32(inst, "unreachable")
	testing.expectf(t, res == .Trapped && strings.contains(inst.last_error, "unreachable"), "unreachable: %q", inst.last_error)
	testing.expectf(t, strings.contains(inst.last_error, "\n    at "), "the wasm stack follows the reason: %q", inst.last_error)
	_, res = call_i32(inst, "deep", 0)
	testing.expectf(t, res == .Trapped, "endless recursion traps (%s)", inst.last_error)
	argv := [1]u32{5}
	testing.expect_value(t, call_indirect(inst, 1, argv[:]), Call_Result.Ok)
	testing.expect_value(t, argv[0], u32(10))
	testing.expect_value(t, call_indirect(inst, 0, argv[:]), Call_Result.Trapped)
	testing.expect_value(t, call_indirect(inst, 99, argv[:]), Call_Result.Trapped)
	r, res2 = call_i32(inst, "add", 2, 3)
	testing.expect(t, res2 == .Ok && r == 5, "usable after every trap")

	refuse := proc(m, f: string) -> bool { return f != "boom" }
	bad, err := instance_create(wat(t, MODULE), nil, nil, options_default(), "filtered", refuse)
	testing.expectf(t, bad == nil && strings.contains(err, "t.boom"), "filter: %q", err)
	delete(err)

	plain := make_instance(t, wat(t, NO_MEMORY_MODULE))
	if plain != nil {
		r, res2 = call_i32(plain, "f")
		testing.expect(t, res2 == .Ok && r == 5, "module without memory")
		destroy(plain)
	}
	garbage := []byte{0, 'a', 's', 'm', 1, 0, 0, 0, 0xff}
	g, gerr := instance_create(garbage, nil, nil, options_default(), "garbage")
	testing.expectf(t, g == nil && gerr != "", "malformed module refused: %q", gerr)
	delete(gerr)
	runtime_destroy()
}

@(test)
registration :: proc(t: ^testing.T) {
	setup(t)
	testing.expect(t, register(T_IMPORTS[:]), "registering the same set again is a no-op")
	other := [?]Import{{module = "t", name = "sum", fn = t_mix, params = {.I32, .I32}, results = {.I32}}}
	testing.expect(t, !register(other[:]), "another function under a registered name is refused")
	dup := [?]Import{{module = "u", name = "f", fn = t_mix}, {module = "u", name = "f", fn = t_mix}}
	testing.expect(t, !register(dup[:]), "a duplicate within a set is refused")
	_, found := import_realms("u", "f")
	testing.expect(t, !found, "nothing of a refused set is registered")
	bad := [?]Import{{module = "u", name = "g", fn = t_mix, params = {.I32}, wide_params = {.I64, .I64}, wide_results = {}}}
	testing.expect(t, !register(bad[:]), "a memory64 shape of another arity is refused")
	runtime_destroy()
}

@(test)
memory_limit :: proc(t: ^testing.T) {
	setup(t)
	o := options_default()
	o.max_pages = 10
	inst := make_instance(t, wat(t, MODULE), o)
	if inst == nil { return }
	defer destroy(inst)
	r, res := call_i32(inst, "grow", 5)
	testing.expectf(t, res == .Ok && r == 1, "grow within the limit -> %v", r)
	r, res = call_i32(inst, "grow", 100)
	testing.expectf(t, res == .Ok && r == -1, "grow past wasm.max_memory_pages fails -> %v", r)
	runtime_destroy()
}

// The embedder's preemption hook (preempt.odin): called during a long call of its thread, refusing guest calls meanwhile,
// and its time given back to the call's deadline.
@(test)
preemption :: proc(t: ^testing.T) {
	setup(t)
	o := options_default()
	o.max_call_ms = 150
	inst := make_instance(t, wat(t, MODULE), o)
	if inst == nil { return }
	defer destroy(inst)
	Probe :: struct { inst: ^Instance, calls: int, refused: bool, slept_ms: f64 }
	probe := Probe{inst = inst}
	set_preempt_hook(proc(user: rawptr) {
		p := (^Probe)(user)
		p.calls += 1
		_, res := call_i32(p.inst, "add", 1, 2)   // a guest call from the hook: refused
		if res != .Ok { p.refused = true }
		if p.calls <= 5 { time.sleep(20 * time.Millisecond); p.slept_ms += 20 }   // the hook's time is not the call's
	}, &probe, tick_ms = 2)
	defer set_preempt_hook(nil, nil)
	t0 := time.tick_now()
	_, res := call_i32(inst, "spin")
	dt := time.duration_milliseconds(time.tick_since(t0))
	testing.expectf(t, res == .Trapped && strings.contains(inst.last_error, "wasm.max_call_ms"), "the deadline still ends the call (%s)", inst.last_error)
	// the hook is called at every tick (2 ms) of the call: how many ticks a loaded machine gets in the time depends on it, so the
	// count is a performance measure (-Perf); that it ran at all and was given its time back is the correctness
	if base.perf_enabled() {
		testing.expectf(t, probe.calls >= 10, "the hook ran at every tick of the call (%d times in %.0f ms)", probe.calls, dt)
	} else {
		testing.expectf(t, probe.calls >= 2, "the hook ran during the call (%d times in %.0f ms; the tick rate is checked with -Perf)", probe.calls, dt)
	}
	testing.expect(t, probe.refused, "a guest call from the hook is refused")
	testing.expectf(t, dt >= 150 + probe.slept_ms * 0.9, "the hook's %.0f ms are given back to the deadline (%.0f ms)", probe.slept_ms, dt)
	r, res2 := call_i32(inst, "add", 1, 2)
	testing.expect(t, res2 == .Ok && r == 3, "calls run again once the hook returned")
}

@(test)
interruption :: proc(t: ^testing.T) {
	setup(t)
	o := options_default()
	o.max_call_ms = 100
	inst := make_instance(t, wat(t, MODULE), o)
	if inst != nil {
		t0 := time.tick_now()
		_, res := call_i32(inst, "spin")
		dt := time.duration_milliseconds(time.tick_since(t0))
		testing.expectf(t, res == .Trapped && dt >= 90, "endless loop stopped by the deadline, not before it (%.0f ms; %s)", dt, inst.last_error)
		testing.expect(t, strings.contains(inst.last_error, "wasm.max_call_ms"), inst.last_error)
		r, res2 := call_i32(inst, "add", 1, 2)
		testing.expect(t, res2 == .Ok && r == 3, "usable after the deadline")
		destroy(inst)
	}

	// the stop flag, set from another thread, interrupts a call without deadline
	@(static) stop: b32
	sync.atomic_store(&stop, false)
	o.max_call_ms = -1
	o.stop = &stop
	inst = make_instance(t, wat(t, MODULE), o)
	if inst != nil {
		th := thread.create_and_start(proc() { time.sleep(80 * time.Millisecond); sync.atomic_store(&stop, true) })
		t0 := time.tick_now()
		_, res := call_i32(inst, "spin")
		dt := time.duration_milliseconds(time.tick_since(t0))
		thread.join(th)
		thread.destroy(th)
		testing.expectf(t, res == .Trapped, "stop flag interrupts a running call (%.0f ms)", dt)
		_, res = call_i32(inst, "add", 1, 2)
		testing.expect(t, res == .Trapped, "nothing runs once the flag is set")
		destroy(inst)
	}

	// fuel: a deterministic instruction budget
	setup(t, tweak = proc(rs: ^Runtime_Settings) { rs.fuel = true })
	o = options_default()
	o.budget = 5_000_000
	o.max_call_ms = -1
	inst = make_instance(t, wat(t, MODULE), o)
	if inst != nil {
		_, res := call_i32(inst, "spin")
		testing.expect(t, res == .Trapped, "fuel stops an endless loop")
		r, res2 := call_i32(inst, "add", 1, 2)
		testing.expect(t, res2 == .Ok && r == 3, "usable after the budget")
		destroy(inst)
	}
	runtime_destroy()
}

@(test)
instance_limit :: proc(t: ^testing.T) {
	setup(t, tweak = proc(rs: ^Runtime_Settings) { rs.max_instances = 2 })
	image := wat(t, NO_MEMORY_MODULE)
	a := make_instance(t, image)
	b := make_instance(t, image)
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
	defer testenv.remove_tree(dir)
	setup(t, dir)
	image := wat(t, MODULE)

	inst := make_instance(t, image)
	destroy(inst)
	cache_flush()
	s := cache_stats()
	testing.expectf(t, s.compiles == 1 && s.disk_writes == 1, "first load compiles and writes: %v", s)
	inst = make_instance(t, image)
	destroy(inst)
	s = cache_stats()
	testing.expectf(t, s.memory_hits == 1 && s.compiles == 1, "second load hits the memory cache: %v", s)
	files := cache_files(dir)
	testing.expect_value(t, len(files), 1)

	// next start: from the disk
	setup(t, dir)
	inst = make_instance(t, image)
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
	setup(t, dir)
	inst = make_instance(t, image)
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
	setup(t, dir)
	inst = make_instance(t, image)
	destroy(inst)
	cache_flush()
	s = cache_stats()
	testing.expectf(t, s.disk_rejects == 1 && s.compiles == 1, "entry of another key rejected: %v", s)

	// a different configuration uses other entries (fingerprint)
	setup(t, dir, proc(rs: ^Runtime_Settings) { rs.opt_level = .None })
	inst = make_instance(t, image)
	destroy(inst)
	cache_flush()
	s = cache_stats()
	testing.expectf(t, s.compiles == 1 && s.disk_rejects == 0, "another configuration compiles its own entry: %v", s)
	testing.expect_value(t, len(cache_files(dir)), 2)

	// the size limit evicts the least recently used entries
	setup(t, dir, proc(rs: ^Runtime_Settings) { rs.cache_disk_max_bytes = 1 })
	inst = make_instance(t, wat(t, NO_MEMORY_MODULE))
	destroy(inst)
	cache_flush()
	testing.expect(t, len(cache_files(dir)) <= 1, "disk cache trimmed to its maximum")
	runtime_destroy()
}

@(test)
memory_cache_limit :: proc(t: ^testing.T) {
	setup(t, tweak = proc(rs: ^Runtime_Settings) { rs.cache_memory_bytes = 0 })
	image := wat(t, NO_MEMORY_MODULE)
	a := make_instance(t, image)
	b := make_instance(t, image)
	s := cache_stats()
	testing.expectf(t, s.compiles == 2 && s.memory_hits == 0, "no memory cache: %v", s)
	destroy(a)
	destroy(b)
	runtime_destroy()
}

@(test)
binary_patch :: proc(t: ^testing.T) {
	setup(t)
	image := wat(t, MODULE)
	info, err := analyze_image(image)
	testing.expect_value(t, err, "")
	testing.expect(t, info.has_memory && info.memory_export == "memory" && !info.add_memory && !info.memory64, "exported memory found")
	testing.expect(t, info.has_table && info.add_table, "unexported table gets an export")
	patched, copied := patch_image(image, info, context.temp_allocator)
	testing.expect(t, copied, "patched")
	info2, _ := analyze_image(patched)
	testing.expect(t, info2.table_export == info.table_export && !info2.add_table, "the patched module exports table 0")
	none, _ := analyze_image(wat(t, NO_MEMORY_MODULE))
	testing.expect(t, !none.has_memory && !none.has_table, "nothing to export")
	m64, _ := analyze_image(wat(t, MODULE64))
	testing.expect(t, m64.memory64, "memory64 detected")
	runtime_destroy()
}
