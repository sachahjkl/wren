package wasm

// The machine code of the program's own image, made at build time and shipped inside the program. Without it a profile's
// first script compiles the whole engine with Cranelift (docs/performance.md, round 37), after every install and every
// update. It comes from the same file as the program, so it needs no MAC as the disk cache's files do (module_cache.odin);
// what it needs is to fit:
//
//   * the image's digest and the configuration's fingerprint in its header: the code of another image never runs, and
//     a changed wasm.wasmtime.* preference passes it by;
//   * Wasmtime's own check of the rest: its version, the settings it compiles for, the CPU features the code uses.
//
// A blob that does not fit is passed by, counted (Cache_Stats.shipped_refused), and the module takes the disk cache's path:
// nothing else depends on it.

import "core:fmt"
import "core:mem"
import "core:sync"

@(private) SHIPPED_MAGIC :: "WRENCODE"

// What a blob starts with. The code follows.
@(private)
Shipped_Header :: struct #packed {
	magic:       [len(SHIPPED_MAGIC)]u8,
	image:       Digest,   // of the module, as `digest` gives it
	fingerprint: Digest,   // of the configuration: config_text
}

when ODIN_OS == .Windows {
	@(private) SHIPPED_TARGET :: "x86_64-pc-windows-msvc"
} else when ODIN_ARCH == .arm64 {
	@(private) SHIPPED_TARGET :: "aarch64-unknown-linux-gnu"
} else {
	@(private) SHIPPED_TARGET :: "x86_64-unknown-linux-gnu"
}

// The blob of this program, when it has one.
@(private)
shipped_code: []byte

// `blob` (shipped_make) is what a module looks at from now on: before the runtime's first module. It stays the caller's.
shipped_set :: proc(blob: []byte) { shipped_code = blob }

// The module of `image` from the shipped code, or nil: there is none, it is another image's or another configuration's,
// or Wasmtime refuses it.
@(private)
shipped_load :: proc(image: Digest, polled: bool) -> wt_module {
	blob := shipped_code
	if len(blob) == 0 { return nil }
	if len(blob) <= size_of(Shipped_Header) { return shipped_refuse() }
	h := (^Shipped_Header)(raw_data(blob))
	fingerprint := polled ? wt.polled_fingerprint : wt.fingerprint
	if string(h.magic[:]) != SHIPPED_MAGIC { return shipped_refuse() }
	if h.image != image { return nil }   // (no refusal: any other module of this runtime, a page's, a compiled function's)
	if h.fingerprint != fingerprint { return shipped_refuse() }
	code := blob[size_of(Shipped_Header):]
	m: wt_module
	if e := wasmtime_module_deserialize(polled ? wt.polled_engine : wt.engine, raw_data(code), len(code), &m); e != nil {
		wasmtime_error_delete(e)
		return shipped_refuse()
	}
	shipped_pages_drop(code)
	return m
}

@(private = "file")
shipped_refuse :: proc() -> wt_module {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	cache.stats.shipped_refused += 1
	return nil
}

// The blob of `image` for an engine of the runtime's configuration (`polled`: the one without epoch checks), for the
// target's baseline CPU, which any x86-64 runs: the features of a newer one gave the engine nothing (docs/performance.md, round 37). `features`: those
// too; `native`: this machine's instead. Both for a measure. After runtime_init.
shipped_make :: proc(image: []byte, polled: bool, features: []string = nil, native := false, allocator := context.allocator) -> (blob: []byte, err: string) {
	info, aerr := analyze_image(image)
	if aerr != "" { return nil, aerr }
	engine := wt_engine_new(wt.rs, !polled, native ? "" : SHIPPED_TARGET, features)
	if engine == nil { return nil, "the engine could not start" }
	defer wasm_engine_delete(engine)
	patched, copied := patch_image(image, info)
	defer if copied { delete(patched) }
	module: wt_module
	if e := wasmtime_module_new(engine, raw_data(patched), len(patched), &module); e != nil {
		text := fmt.tprintf("compile failed: %s", wt_error_text(e, context.temp_allocator))
		wasmtime_error_delete(e)
		return nil, text
	}
	defer wasmtime_module_delete(module)
	v: wt_byte_vec
	if e := wasmtime_module_serialize(module, &v); e != nil {
		wasmtime_error_delete(e)
		return nil, "the module cannot be serialized"
	}
	defer wasm_byte_vec_delete(&v)

	h: Shipped_Header
	copy(h.magic[:], SHIPPED_MAGIC)
	h.image, _ = sha256(image)
	h.fingerprint = polled ? wt.polled_fingerprint : wt.fingerprint
	blob = make([]byte, size_of(h) + int(v.size), allocator)
	mem.copy(raw_data(blob), &h, size_of(h))
	copy(blob[size_of(h):], v.data[:v.size])
	return blob, ""
}
