// The host runner for the generic-ABI benchmark: it registers the URL domain's serialised boundary, instantiates the
// wasm32 guest (build/abi_bench.wasm), and times 1 M calls of two shapes over a real Wasmtime instance. The numbers
// are compared in the design note against the current wr_* scalar ABI (the wasmbench "ns/call" rows), which this runs
// alongside for a same-machine reading. Build + run:
//   odin build native/js/odin_abi/bench_guest -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator \
//       -collection:wb=src -out:build/abi_bench.wasm -o:size
//   odin run native/js/odin_abi/bench -collection:wb=src -collection:toolkit=ext/gui_toolkit -out:build/abi_bench_host.exe -- build/abi_bench.wasm
package abi_bench

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"
import "../abi_host"
import "../abi_url"
import "wb:wasm"

reg: abi_url.Registry

median :: proc(xs: []f64) -> f64 { slice.sort(xs); return xs[len(xs) / 2] }

call1 :: proc(inst: ^wasm.Instance, name: cstring, arg: i32) -> (i32, wasm.Call_Result) {
	return wasm.call_i32(inst, name, arg)
}

timed :: proc(inst: ^wasm.Instance, name: cstring, arg: i32) -> (ns_per: f64, result: i32) {
	runs: [3]f64
	r: i32
	for i in 0 ..< len(runs) {
		t0 := time.tick_now()
		res: wasm.Call_Result
		r, res = wasm.call_i32(inst, name, arg)
		runs[i] = f64(time.duration_nanoseconds(time.tick_since(t0)))
		if res != .Ok { fmt.eprintln(name, res, inst.last_error); os.exit(1) }
	}
	return median(runs[:]) / f64(arg), r
}

main :: proc() {
	if len(os.args) < 2 { fmt.eprintln("usage: abi_bench build/abi_bench.wasm"); os.exit(2) }
	image, rerr := os.read_entire_file_from_path(os.args[1], context.allocator)
	if rerr != nil { fmt.eprintln("cannot read", os.args[1]); os.exit(2) }

	// A modest native stack for the engine: this guest does not recurse, so it needs far less than the browser's
	// default (which sizes for deep script recursion). Keeps the main thread's stack enough.
	rs := wasm.runtime_settings_default()
	rs.max_stack_bytes = 512 << 10
	rs.host_stack_reserve = 64 << 10
	wasm.configure(rs)

	// Register the serialised boundary (the single host_call import under module "url_abi") plus WASI (the guest has
	// none, but the engine shape is the same as the browser).
	reg = abi_url.build_registry()
	imp := abi_host.install(&reg)
	imps := []wasm.Import{imp}
	if !wasm.register(imps) { fmt.eprintln("register failed"); os.exit(1) }
	if !wasm.register(scalar_imports[:]) { fmt.eprintln("scalar register failed"); os.exit(1) }

	// The comptime-built scalar bridge (abi_host.register_scalar_*): the same shape as url_scalar, but the trampoline
	// is instantiated by the compiler from the signature, not hand-written. Registered under module "url_cm".
	cfg := abi_url.config()
	cm := [2]wasm.Import{
		abi_host.register_scalar_i32("url_cm", "size", cfg, abi_url.URLSearchParams_size),
		abi_host.register_scalar_string("url_cm", "get", cfg, abi_url.URL_get),
	}
	if !wasm.register(cm[:]) { fmt.eprintln("comptime scalar register failed"); os.exit(1) }
	defer abi_url.host_destroy()

	o := wasm.options_default()
	o.budget = -1
	o.max_call_ms = -1
	inst, err := wasm.instance_create(image, nil, nil, o, "abi_bench")
	if inst == nil { fmt.eprintln(err); os.exit(1) }
	defer wasm.destroy(inst)

	if _, r := wasm.call_i32(inst, "setup"); r != .Ok { fmt.eprintln("setup", r); os.exit(1) }
	if p, r := wasm.call_i32(inst, "prepare"); r != .Ok || p < 0 { fmt.eprintln("prepare failed", r, p); os.exit(1) }

	N :: 1_000_000
	size_ns, size_r := timed(inst, "calls_size", N)
	get_ns, get_r := timed(inst, "calls_get", N)
	ssize_ns, ssize_r := timed(inst, "scalar_calls_size", N)
	sget_ns, sget_r := timed(inst, "scalar_calls_get", N)
	csize_ns, csize_r := timed(inst, "cm_calls_size", N)
	cget_ns, cget_r := timed(inst, "cm_calls_get", N)

	fmt.println("| shape | wr_* scalar (hand-written) | scalar bridge (comptime) | serialised host_call (comptime) |")
	fmt.println("|---|---:|---:|---:|")
	fmt.printfln("| URLSearchParams_size (handle -> i32) | %.1f | %.1f | %.1f ns/call |", ssize_ns, csize_ns, size_ns)
	fmt.printfln("| URL_get .Pathname (handle,enum -> string) | %.1f | %.1f | %.1f ns/call |", sget_ns, cget_ns, get_ns)
	fmt.printfln("(checksums size %d/%d/%d, get %d/%d/%d)", ssize_r, csize_r, size_r, sget_r, cget_r, get_r)
	wasm.runtime_destroy()
}
