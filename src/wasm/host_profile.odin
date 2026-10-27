package wasm

// WREN_HOST_PROFILE=<file>: the time each host function (an import of the engine: a DOM call, a style or layout read, a timer...)
// takes, for the measuring tools. The callbacks of the imports defined while it is set go through one that reads the clock; the
// table is written to <file> when the runtime ends: calls, time with and without what the function itself caused below it (a host
// function that calls into Wasm again, which calls others), the longest call. tools\wasm_profile.ps1 says where the guest spent its
// time; this says what the host spent on the guest's behalf. Off, an import costs nothing more than before.

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

@(private = "file")
Timed :: struct {
	module, name: string,
	fn:           Host_Fn,
	env:          rawptr,
	calls:        u64,
	total_ns:     u64,
	self_ns:      u64,
	max_ns:       u64,
}

@(private = "file")
timed: [dynamic]^Timed
@(private = "file")
host_profile_path: string
@(private = "file")
host_profile_known: bool
@(private = "file", thread_local)
child_ns: u64

@(private)
host_profile_enabled :: proc() -> bool {
	if !host_profile_known {
		host_profile_known = true
		host_profile_path = os.get_env("WREN_HOST_PROFILE", context.allocator)
	}
	return host_profile_path != ""
}

// The callback and env to define for `im` (the originals when the profile is off).
@(private)
host_profile_wrap :: proc(im: ^Import, env: rawptr) -> (Host_Fn, rawptr) {
	if !host_profile_enabled() { return im.fn, env }
	t := new(Timed, context.allocator)
	t.module, t.name, t.fn, t.env = im.module, im.name, im.fn, env
	append(&timed, t)
	return host_timed, rawptr(t)
}

@(private = "file")
now_ns :: #force_inline proc "contextless" () -> u64 {
	return u64(time.tick_now()._nsec)   // QueryPerformanceCounter, CLOCK_MONOTONIC
}

@(private = "file")
host_timed :: proc "c" (env: rawptr, caller: wt_caller, args: [^]wt_val_raw, n: uint) -> wt_trap {
	t := (^Timed)(env)
	outer := child_ns
	child_ns = 0
	t0 := now_ns()
	r := t.fn(t.env, caller, args, n)
	d := now_ns() - t0
	intrinsics.atomic_add(&t.calls, 1)
	intrinsics.atomic_add(&t.total_ns, d)
	intrinsics.atomic_add(&t.self_ns, d - min(child_ns, d))
	if d > intrinsics.atomic_load(&t.max_ns) { intrinsics.atomic_store(&t.max_ns, d) }
	child_ns = outer + d
	return r
}

host_profile_write :: proc() {
	if host_profile_path == "" || len(timed) == 0 { return }
	context = runtime.default_context()   // memcheck: a report of the measuring tools
	sorted := slice.clone(timed[:], context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: ^Timed) -> bool { return a.self_ns > b.self_ns })
	sb := strings.builder_make(context.temp_allocator)
	total_self: u64
	for t in sorted { total_self += t.self_ns }
	fmt.sbprintf(&sb, "host functions: %.0f ms of own time in %d imports\n", f64(total_self) / 1e6, len(sorted))
	fmt.sbprintf(&sb, "%10s %10s %9s %9s %9s  %s\n", "self ms", "total ms", "calls", "us/call", "max ms", "import")
	for t, i in sorted {
		if i >= 60 || t.calls == 0 { break }
		fmt.sbprintf(&sb, "%10.1f %10.1f %9d %9.2f %9.2f  %s.%s\n", f64(t.self_ns) / 1e6, f64(t.total_ns) / 1e6, t.calls, f64(t.self_ns) / 1e3 / f64(t.calls), f64(t.max_ns) / 1e6, t.module, t.name)
	}
	_ = os.write_entire_file(host_profile_path, transmute([]byte)strings.to_string(sb))
}