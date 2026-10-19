package wasm

// Pre-initialization (preinit.odin) and the WASI subset (wasi.odin).

import "core:testing"

@(private = "file")
PREINIT_WAT :: `(module
  (import "wasi_snapshot_preview1" "random_get" (func $random (param i32 i32) (result i32)))
  (memory (export "memory") 1 4)
  (global $counter (mut i32) (i32.const 5))
  (global $wide (mut i64) (i64.const 0))
  (global $f (mut f64) (f64.const 0))
  (global $answer i32 (i32.const 42))
  (data (i32.const 16) "abc")
  (func (export "init")
    ;; grow by one page, write past the old end, change the globals, read random bytes (WASI works during init)
    (drop (memory.grow (i32.const 1)))
    (i32.store (i32.const 70000) (i32.const 0x01020304))
    (i32.store8 (i32.const 17) (i32.const 0x7a))
    (global.set $counter (i32.add (global.get $counter) (i32.const 1)))
    (global.set $wide (i64.const 0x123456789))
    (global.set $f (f64.const 2.5))
    (drop (call $random (i32.const 100) (i32.const 8))))
  (func (export "counter") (result i32) (global.get $counter))
  (func (export "wide") (result i64) (global.get $wide))
  (func (export "f") (result f64) (global.get $f))
  (func (export "answer") (result i32) (global.get $answer))
  (func (export "load") (param i32) (result i32) (i32.load (local.get 0)))
  (func (export "pages") (result i32) (memory.size)))`

@(test)
preinit_snapshot :: proc(t: ^testing.T) {
	testing.expect(t, runtime_init())
	testing.expect(t, register_wasi())
	image, werr := wat_to_wasm(PREINIT_WAT, context.temp_allocator)
	if werr != "" { testing.fail_now(t, werr) }
	out, stats, err := preinitialize(image, {"init"}, allocator = context.temp_allocator)
	if err != "" { testing.fail_now(t, err) }
	testing.expect(t, stats.globals == 3)
	testing.expect(t, stats.memory_bytes == 2 * 65536)

	opt := options_default()
	inst, ierr := instance_create(out, nil, nil, opt, "preinit")
	if inst == nil { testing.fail_now(t, ierr) }
	defer destroy(inst)
	testing.expect(t, !has_export(inst, "init"))   // initialization does not run twice
	c, _ := call_i32(inst, "counter")
	testing.expect_value(t, c, 6)
	a, _ := call_i32(inst, "answer")
	testing.expect_value(t, a, 42)
	p, _ := call_i32(inst, "pages")
	testing.expect_value(t, p, 2)
	v, _ := call_i32(inst, "load", 70000)
	testing.expect_value(t, v, 0x01020304)
	b, _ := call_i32(inst, "load", 16)
	testing.expect_value(t, b & 0xffffff, 0x637a61)   // "aza": the data segment, then the change made by init
	argv := [2]u32{}
	testing.expect(t, call_raw(inst, "wide", argv[:], 2) == .Ok)
	testing.expect_value(t, u64(argv[0]) | u64(argv[1]) << 32, 0x123456789)
	testing.expect(t, call_raw(inst, "f", argv[:], 2) == .Ok)
	testing.expect_value(t, transmute(f64)(u64(argv[0]) | u64(argv[1]) << 32), 2.5)
}

@(test)
preinit_refuses :: proc(t: ^testing.T) {
	testing.expect(t, runtime_init())
	imported_memory, _ := wat_to_wasm(`(module (import "m" "mem" (memory 1)) (func (export "init")))`, context.temp_allocator)
	_, _, err := preinitialize(imported_memory, {"init"}, allocator = context.temp_allocator)
	testing.expect(t, err != "")
	failing, _ := wat_to_wasm(`(module (memory 1) (func (export "init") unreachable))`, context.temp_allocator)
	_, _, err2 := preinitialize(failing, {"init"}, allocator = context.temp_allocator)
	testing.expect(t, err2 != "")
	_, _, err3 := preinitialize({1, 2, 3}, {"init"}, allocator = context.temp_allocator)
	testing.expect(t, err3 != "")
}

@(private = "file")
WASI_WAT :: `(module
  (import "wasi_snapshot_preview1" "clock_time_get" (func $clock (param i32 i64 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "path_open" (func $open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (import "wasi_snapshot_preview1" "fd_prestat_get" (func $prestat (param i32 i32) (result i32)))
  (memory (export "memory") 1)
  (data (i32.const 0) "hello")
  (func (export "clock_ok") (result i32) (call $clock (i32.const 0) (i64.const 0) (i32.const 64)))
  (func (export "clock_bad_ptr") (result i32) (call $clock (i32.const 0) (i64.const 0) (i32.const 70000)))
  (func (export "now_nonzero") (result i32) (drop (call $clock (i32.const 1) (i64.const 0) (i32.const 64))) (i64.ne (i64.load (i32.const 64)) (i64.const 0)))
  (func (export "write_out") (result i32)
    (i32.store (i32.const 32) (i32.const 0)) (i32.store (i32.const 36) (i32.const 5))
    (drop (call $write (i32.const 1) (i32.const 32) (i32.const 1) (i32.const 48)))
    (i32.load (i32.const 48)))
  (func (export "write_file") (result i32) (call $write (i32.const 5) (i32.const 32) (i32.const 1) (i32.const 48)))
  (func (export "open") (result i32) (call $open (i32.const 3) (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 0) (i64.const 0) (i64.const 0) (i32.const 0) (i32.const 0)))
  (func (export "prestat") (result i32) (call $prestat (i32.const 3) (i32.const 0))))`

@(private = "file")
wasi_captured: [dynamic]u8

@(test)
wasi_subset :: proc(t: ^testing.T) {
	testing.expect(t, runtime_init())
	testing.expect(t, register_wasi())
	image, werr := wat_to_wasm(WASI_WAT, context.temp_allocator)
	if werr != "" { testing.fail_now(t, werr) }
	saved := wasi_output
	defer wasi_output = saved
	clear(&wasi_captured)
	wasi_output = proc(inst: ^Instance, fd: i32, text: []u8) { if fd == 1 { append(&wasi_captured, ..text) } }
	inst, err := instance_create(image, nil, nil, options_default(), "wasi")
	if inst == nil { testing.fail_now(t, err) }
	defer destroy(inst)
	r, _ := call_i32(inst, "clock_ok")
	testing.expect_value(t, r, 0)
	r, _ = call_i32(inst, "clock_bad_ptr")
	testing.expect_value(t, r, 21)   // EFAULT, no trap
	r, _ = call_i32(inst, "now_nonzero")
	testing.expect_value(t, r, 1)
	r, _ = call_i32(inst, "write_out")
	testing.expect_value(t, r, 5)
	testing.expect(t, string(wasi_captured[:]) == "hello")
	r, _ = call_i32(inst, "write_file")
	testing.expect_value(t, r, 8)    // EBADF: only the standard streams exist
	r, _ = call_i32(inst, "open")
	testing.expect_value(t, r, 76)   // ENOTCAPABLE: no file system
	r, _ = call_i32(inst, "prestat")
	testing.expect_value(t, r, 8)    // no preopened directory
	delete(wasi_captured)
	wasi_captured = nil
}
