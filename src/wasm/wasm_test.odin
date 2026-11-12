package wasm

// Calls, host functions (address checks, 64-bit and float values, traps raised by the host, nesting, memory64,
// multi-memory), unknown imports, the import filter, limits, interruption, and the disk cache of compiled code (hit,
// configuration change, corrupted or forged entries). The host functions here are written against the raw interface
// (host.odin) the way the generated trampolines are.
// The runtime is process-wide: run with -define:ODIN_TEST_THREADS=1 (src\tools\test_all does).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "wb:base"
import "wb:config"
import "wb:testenv"

// preemption: the call's deadline, the tick of the hook, what the hook takes in its first calls.
@(private = "file") PREEMPT_CALL_MS :: 150
@(private = "file") PREEMPT_TICK_MS :: 2
@(private = "file") PREEMPT_SLEEPING_CALLS :: 5
@(private = "file") PREEMPT_HOOK_SLEEP_MS :: 20
// interruption: the deadline and how much before it a stop still counts as the deadline's; when the flag is set.
@(private = "file") INTERRUPT_CALL_MS :: 100
@(private = "file") INTERRUPT_MIN_ELAPSED_MS :: 90
@(private = "file") STOP_FLAG_TICK_MS :: 1

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
	rs.test_shared_cache = false   // (these tests count what their own cache holds)
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
	o.max_call_ms = PREEMPT_CALL_MS
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
		// Stays a real sleep: what is checked is that the deadline of a guest call, on the real clock of the engine's ticker, is
		// moved by the real time the hook took. No other clock runs there.
		if p.calls <= PREEMPT_SLEEPING_CALLS { time.sleep(PREEMPT_HOOK_SLEEP_MS * time.Millisecond); p.slept_ms += PREEMPT_HOOK_SLEEP_MS }   // the hook's time is not the call's
	}, rawptr(&probe), tick_ms = PREEMPT_TICK_MS)   // (until the deferred reset)
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
	testing.expectf(t, dt >= PREEMPT_CALL_MS + probe.slept_ms * 0.9, "the hook's %.0f ms are given back to the deadline (%.0f ms)", probe.slept_ms, dt)
	r, res2 := call_i32(inst, "add", 1, 2)
	testing.expect(t, res2 == .Ok && r == 3, "calls run again once the hook returned")
}

@(test)
interruption :: proc(t: ^testing.T) {
	setup(t)
	o := options_default()
	o.max_call_ms = INTERRUPT_CALL_MS
	inst := make_instance(t, wat(t, MODULE), o)
	if inst != nil {
		t0 := time.tick_now()
		_, res := call_i32(inst, "spin")
		dt := time.duration_milliseconds(time.tick_since(t0))
		testing.expectf(t, res == .Trapped && dt >= INTERRUPT_MIN_ELAPSED_MS, "endless loop stopped by the deadline, not before it (%.0f ms; %s)", dt, inst.last_error)
		testing.expect(t, strings.contains(inst.last_error, "wasm.max_call_ms"), inst.last_error)
		r, res2 := call_i32(inst, "add", 1, 2)
		testing.expect(t, res2 == .Ok && r == 3, "usable after the deadline")
		destroy(inst)
	}

	// the stop flag, set from another thread, interrupts a call without deadline; that thread waits until the call runs
	// (the preempt hook only runs inside one)
	@(static) stop: b32
	@(static) running: sync.Sema
	sync.atomic_store(&stop, false)
	o.max_call_ms = -1
	o.stop = &stop
	inst = make_instance(t, wat(t, MODULE), o)
	if inst != nil {
		set_preempt_hook(proc(_: rawptr) { sync.sema_post(&running) }, nil, tick_ms = STOP_FLAG_TICK_MS)
		th := thread.create_and_start(proc() { sync.sema_wait(&running); sync.atomic_store(&stop, true) })
		t0 := time.tick_now()
		_, res := call_i32(inst, "spin")
		dt := time.duration_milliseconds(time.tick_since(t0))
		set_preempt_hook(nil, nil)
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
	root := base.temp_dir(context.temp_allocator)
	dir, _ := filepath.join({root, fmt.tprintf("wren-wasm-test-%s-%d", name, time.now()._nsec)}, context.temp_allocator)
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
	key_path, _ := filepath.join({dir, DISK_KEY_FILE}, context.temp_allocator)
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

// A folder of thousands of files takes seconds to read: once a run, not once a write (a closing window waited for it, and for the watchdog that ended it: the unclean exits of 0.6.24).
@(test)
disk_cache_reads_its_folder_once_a_run :: proc(t: ^testing.T) {
	dir := temp_dir(t, "scans")
	defer testenv.remove_tree(dir)
	setup(t, dir)
	destroy(make_instance(t, wat(t, MODULE)))
	cache_flush()
	destroy(make_instance(t, wat(t, NO_MEMORY_MODULE)))
	cache_flush()
	testing.expect_value(t, cache_stats().disk_writes, 2)
	testing.expect_value(t, sync.atomic_load(&cache.files.scans), 1)
	runtime_destroy()
}

// A cache at its limit: a trim leaves room, the writes after it read no folder (each one did, a second on a folder of thirty thousand files, and every close waited for what was queued).
@(test)
a_full_disk_cache_does_not_read_its_folder_at_each_write :: proc(t: ^testing.T) {
	ENTRY_BYTES :: 1024
	ENTRIES_THAT_FIT :: 32
	WRITES :: 200
	dir := temp_dir(t, "full")
	defer testenv.remove_tree(dir)
	d := Disk_Cache{magic = "test", ext = ".test", max_bytes = ENTRY_BYTES * ENTRIES_THAT_FIT}
	testing.expect(t, disk_start(&d, dir))
	for i in 0 ..< WRITES {
		key: Digest
		key[0], key[1] = u8(i), u8(i >> 8)
		disk_queue(&d, disk_path(&d, key), key, make([]byte, ENTRY_BYTES, base.process_allocator()))
		disk_flush(&d)
	}
	scans := sync.atomic_load(&d.scans)
	disk_stop(&d)
	testing.expectf(t, scans < WRITES / 2, "%d folder reads for %d writes", scans, WRITES)
}

// The read-ahead of a process's start (page.js_startup): on another thread, the module from the disk into memory; the
// instance made after it reads nothing from the disk. Nothing is compiled ahead when the disk has no entry.
@(test)
read_ahead_from_disk :: proc(t: ^testing.T) {
	dir := temp_dir(t, "ahead")
	defer testenv.remove_tree(dir)
	setup(t, dir)
	image := wat(t, MODULE)
	testing.expect(t, !read_ahead(image), "no entry on disk: nothing read")
	s := cache_stats()
	testing.expectf(t, s.compiles == 0 && s.entries == 0, "nothing compiled ahead: %v", s)
	destroy(make_instance(t, image))
	cache_flush()

	setup(t, dir)   // the next start
	Ahead :: struct { image: []byte, read: bool }
	ahead := Ahead{image = image}
	th := thread.create_and_start_with_data(&ahead, proc(data: rawptr) {
		a := (^Ahead)(data)
		a.read = read_ahead(a.image)
	})
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, ahead.read, "the entry read ahead")
	s = cache_stats()
	testing.expectf(t, s.disk_hits == 1 && s.entries == 1 && s.compiles == 0, "in memory from the disk: %v", s)
	inst := make_instance(t, image)
	if inst != nil {
		r, res := call_i32(inst, "sum4")
		testing.expect(t, res == .Ok && r == 10, "a module read ahead runs")
		destroy(inst)
	}
	s = cache_stats()
	testing.expectf(t, s.disk_hits == 1 && s.memory_hits == 1 && s.compiles == 0, "the instance read nothing from the disk: %v", s)
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

@(test)
user_module_description :: proc(t: ^testing.T) {
	setup(t)
	image := wat(t, `(module
		(import "env" "f" (func))
		(import "env" "t" (table 1 funcref))
		(import "env" "m" (memory 1))
		(import "env" "g" (global i32))
		(func (export "run"))
		(export "a\"b\n" (memory 0))
		(@custom "meta" "\01\02")
		(@custom "meta" (after last) "\03")
	)`)
	m, err := user_module_new(image)
	if m == nil { testing.fail_now(t, err) }
	defer user_module_delete(m)
	testing.expect_value(t, m.imports, `[{"module":"env","name":"f","kind":"function"},{"module":"env","name":"t","kind":"table"},{"module":"env","name":"m","kind":"memory"},{"module":"env","name":"g","kind":"global"}]`)
	testing.expect_value(t, m.exports, `[{"name":"run","kind":"function"},{"name":"a\"b\n","kind":"memory"}]`)
	testing.expect_value(t, len(m.sections), 2)
	testing.expect_value(t, m.sections[0].name, "meta")
	testing.expect_value(t, string(m.sections[0].data), "\x01\x02")
	testing.expect_value(t, string(m.sections[1].data), "\x03")

	none, why := user_module_new({0, 97, 115, 109, 9, 9, 9, 9})
	testing.expect(t, none == nil && why != "", "not a module: nil and a reason")
	testing.expect(t, !validate({1, 2, 3}), "validate: not a module")
	testing.expect(t, validate(image), "validate: a module")
}

// wasm.wasmtime.profiler: the preference gives the strategy, and Wasmtime's engine starts with it and runs code (VTune's agent
// with no VTune attached tells nobody).
@(test)
profiler_preference_reaches_wasmtime :: proc(t: ^testing.T) {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	rs := runtime_settings_from_prefs(&p, "")
	testing.expect_value(t, rs.profiler, Profiler.None)
	when ODIN_ARCH != .amd64 { return }
	_, errs := config.apply_args(&p, {"--pref", "wasm.wasmtime.profiler=vtune"}, context.temp_allocator)
	testing.expect_value(t, len(errs), 0)
	rs = runtime_settings_from_prefs(&p, "")
	testing.expect_value(t, rs.profiler, Profiler.Vtune)
	setup(t, tweak = proc(rs: ^Runtime_Settings) { rs.profiler = .Vtune })
	defer runtime_destroy()
	testing.expect_value(t, wt.rs.profiler, Profiler.Vtune)
	inst := make_instance(t, wat(t, MODULE))
	if inst == nil { return }
	defer destroy(inst)
	r, res := call_i32(inst, "add", 40, 2)
	testing.expectf(t, res == .Ok && r == 42, "a call under the VTune strategy -> %v %v", r, res)
}
// A module with polls: its loops carry them, the deadline and the embedder's hook come through them on the engine without epoch
// checks, and only an image the embedder calls its own runs there.
@(private = "file") POLL_WORD :: 1024
@(private = "file") POLL_CALL_MS :: 100
@(private = "file") POLL_TICK_MS :: 2
@(private = "file") POLL_MODULE :: `(module
	(import "wren" "poll" (func $poll))
	(memory (export "memory") 1)
	(func $spin (export "spin") (loop $l (br $l)))
	(func $counted (export "counted") (result i32)
		(local $n i32)
		(loop $l
			(local.set $n (i32.add (local.get $n) (i32.const 1)))
			(br_if $l (i32.lt_u (local.get $n) (i32.const 1000))))
		(local.get $n))
)`

@(test)
polls :: proc(t: ^testing.T) {
	setup(t)
	plain := wat(t, POLL_MODULE)
	_, _, missing := poll_instrument(plain, POLL_WORD, {"no_such_function"}, context.temp_allocator)
	testing.expect(t, missing != "", "a name of the list that is no function is an error")
	image, stats, err := poll_instrument(plain, POLL_WORD, {"counted"}, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, stats, Poll_Stats{functions = 2, loops = 2, polled = 1, exempt = 1})
	word, has := poll_word_of(image)
	testing.expect(t, has && word == POLL_WORD, "the section gives the word")
	_, none := poll_word_of(plain)
	testing.expect(t, !none, "a module without the section has no polls")
	audit, without, aerr := poll_audit(image, context.temp_allocator)
	testing.expect_value(t, aerr, "")
	testing.expect_value(t, audit.polled, 1)
	testing.expect_value(t, without["counted"], 1)
	testing.expect_value(t, len(without), 1)

	o := options_default()
	o.max_call_ms = POLL_CALL_MS
	o.polled = true
	inst := make_instance(t, image, o)
	if inst != nil {
		testing.expect(t, inst.wt.polled && inst.poll_word != nil, "the image runs on the engine without epoch checks")
		ran := 0
		set_preempt_hook(proc(user: rawptr) { (^int)(user)^ += 1 }, &ran, tick_ms = POLL_TICK_MS)
		_, res := call_i32(inst, "spin")
		set_preempt_hook(nil, nil)
		testing.expectf(t, res == .Trapped && strings.contains(inst.last_error, "wasm.max_call_ms"), "the deadline ends an endless loop through its poll (%s)", inst.last_error)
		testing.expect(t, ran > 0, "the hook ran under the loop")
		n, res2 := call_i32(inst, "counted")
		testing.expect(t, res2 == .Ok && n == 1000, "a loop without a poll runs, and the instance is usable after the trap")
		testing.expect(t, inst.poll_next == nil && inst.poll_prev == nil && wt.polls == nil, "no call in progress, no word on the ticker's list")
		destroy(inst)
	}

	// not its own: the epoch's checks stop them, whatever the module says or the embedder asks
	for c in ([]struct{ image: []byte, polled: bool }{{image, false}, {plain, true}}) {
		o.polled = c.polled
		other := make_instance(t, c.image, o)
		if other == nil { continue }
		testing.expect(t, !other.wt.polled && other.poll_word == nil, "it stays on the engine with epoch checks")
		_, res := call_i32(other, "spin")
		testing.expectf(t, res == .Trapped && strings.contains(other.last_error, "wasm.max_call_ms"), "the epoch ends it (%s)", other.last_error)
		destroy(other)
	}
}

// The code a program ships (shipped.odin): taken with nothing compiled and nothing read from the disk. It is the polled engine's, as the JavaScript engine's image is.
@(test)
shipped_code_is_taken_and_nothing_is_compiled :: proc(t: ^testing.T) {
	dir := temp_dir(t, "shipped")
	defer testenv.remove_tree(dir)
	defer shipped_set(nil)
	setup(t, dir)
	image, _, err := poll_instrument(wat(t, POLL_MODULE), POLL_WORD, {}, context.temp_allocator)
	testing.expect_value(t, err, "")
	blob, merr := shipped_make(image, true, allocator = context.temp_allocator)
	testing.expect_value(t, merr, "")

	setup(t, dir)   // a new install: the disk has nothing
	shipped_set(blob)
	testing.expect(t, read_ahead(image, nil, {polled = true}), "the shipped code read ahead")
	o := options_default()
	o.polled = true
	inst := make_instance(t, image, o)
	if inst != nil {
		testing.expect(t, inst.wt.polled, "on the engine without epoch checks")
		n, res := call_i32(inst, "counted")
		testing.expect(t, res == .Ok && n == 1000, "the shipped code runs")
		destroy(inst)
	}
	cache_flush()
	s := cache_stats()
	testing.expectf(t, s.shipped_hits == 1 && s.compiles == 0 && s.disk_hits == 0 && s.disk_writes == 0 && s.shipped_refused == 0, "from the program, nothing compiled, nothing written: %v", s)
	testing.expect_value(t, len(cache_files(dir)), 0)
	runtime_destroy()
}

@(private = "file")
run_add :: proc(t: ^testing.T, image: []byte) -> (i32, Call_Result) {
	inst := make_instance(t, image)
	if inst == nil { return 0, .Trapped }
	defer destroy(inst)
	return call_i32(inst, "add", 40, 2)
}

// Shipped code that does not fit: the module compiles and runs, and the next start finds it on the disk as before.
@(test)
refused_shipped_code_falls_back :: proc(t: ^testing.T) {
	dir := temp_dir(t, "refused")
	defer testenv.remove_tree(dir)
	defer shipped_set(nil)
	setup(t, dir)
	image := wat(t, MODULE)
	good, merr := shipped_make(image, false, allocator = context.temp_allocator)
	testing.expect_value(t, merr, "")

	// Wasmtime's own refusal: what follows the header is not what it wrote (another version comes to the same check)
	spoiled := slice.clone(good, context.temp_allocator)
	spoiled[size_of(Shipped_Header)] ~= 0xff
	setup(t, dir)
	shipped_set(spoiled)
	r, res := run_add(t, image)
	testing.expect(t, res == .Ok && r == 42, "it runs all the same")
	cache_flush()
	s := cache_stats()
	testing.expectf(t, s.shipped_refused == 1 && s.shipped_hits == 0 && s.compiles == 1 && s.disk_writes == 1, "refused, compiled, kept on the disk: %v", s)

	// the next start: refused again, the disk has it
	setup(t, dir)
	shipped_set(spoiled)
	r, res = run_add(t, image)
	s = cache_stats()
	testing.expectf(t, res == .Ok && s.shipped_refused == 1 && s.disk_hits == 1 && s.compiles == 0, "from the disk: %v", s)

	// another configuration (a wasm.wasmtime.* preference): the blob is passed by before Wasmtime sees it
	setup(t, "", proc(rs: ^Runtime_Settings) { rs.opt_level = .None })
	shipped_set(good)
	r, res = run_add(t, image)
	s = cache_stats()
	testing.expectf(t, res == .Ok && s.shipped_refused == 1 && s.compiles == 1, "another configuration compiles: %v", s)

	// the code of another image never runs, and that is no refusal: any other module of the runtime comes this way
	setup(t, "")
	shipped_set(good)
	destroy(make_instance(t, wat(t, NO_MEMORY_MODULE)))
	s = cache_stats()
	testing.expectf(t, s.shipped_hits == 0 && s.shipped_refused == 0 && s.compiles == 1, "another image compiles: %v", s)

	// refused, the read-ahead compiles: once, ahead of the instance, which finds the module in memory
	setup(t, "")
	shipped_set(spoiled)
	testing.expect(t, read_ahead(image), "compiled ahead")
	r, res = run_add(t, image)
	s = cache_stats()
	testing.expectf(t, res == .Ok && s.compiles == 1 && s.memory_hits == 1, "one compile, ahead of the instance: %v", s)
	runtime_destroy()
}
