package wasm

// Sampling profiler of guest code (Wasmtime's GuestProfiler), for the measuring tools (jsengine profile). While a
// profile runs on an instance, every epoch tick (wasm.wasmtime.epoch_tick_ms, the ticker runs while a call is in
// progress) records the instance's Wasm call stack. `profile_finish` writes the samples in the Firefox Profiler's format
// (profiler.firefox.com opens it; tools\wasm_profile.ps1 sums it up). Function names come from the module's name
// section: build the engine with tools\build_js.ps1 -Names for a readable profile.

import "core:os"
import "core:time"

// Starts sampling `inst`, created from `image`. False when the image is not in the code cache or a profile runs.
profile_start :: proc(inst: ^Instance, image: []byte) -> bool {
	if inst == nil || inst.wt.profiler != nil { return false }
	c, err := cache_acquire(image)
	delete(err)
	if c == nil { return false }
	defer cache_release(c)
	name := wt_byte_vec{size = uint(len(inst.name)), data = raw_data(inst.name)}
	mods := [1]wt_profiler_module{{name = &name, mod = c.module}}
	interval := u64(max(wt.rs.epoch_tick_ms, 1)) * 1_000_000
	inst.wt.profiler = wasmtime_guestprofiler_new(wt.engine, &name, interval, &mods[0], 1)
	inst.wt.profile_last = time.tick_now()
	return inst.wt.profiler != nil
}

// Writes the profile to `path` and stops sampling. "" when written, else why not.
profile_finish :: proc(inst: ^Instance, path: string) -> string {
	g := inst.wt.profiler
	if g == nil { return "no profile is running" }
	inst.wt.profiler = nil
	out: wt_byte_vec
	if e := wasmtime_guestprofiler_finish(g, &out); e != nil { return wt_error_text(e) }
	defer wasm_byte_vec_delete(&out)
	if werr := os.write_entire_file(path, out.data[:out.size]); werr != nil { return "cannot write the profile" }
	return ""
}

// From the epoch callback: one sample with the CPU time since the previous one.
@(private)
profile_sample :: proc "contextless" (inst: ^Instance) {
	now := time.tick_now()
	delta := time.tick_diff(inst.wt.profile_last, now)
	inst.wt.profile_last = now
	wasmtime_guestprofiler_sample(inst.wt.profiler, inst.wt.store, u64(max(i64(delta), 0)))
}
