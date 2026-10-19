// Compares the Wasm engines: instantiation (first load, memory cache, disk cache), compute kernels, host calls and
// memory per instance. Prints a Markdown table.
//   wasmbench build\wasmbench.wasm [more.wasm ...]    (the first module is examples/wasmbench; the others are only
//                                                      instantiated: page modules such as build\e2e.wasm)
package wasmbench

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "wb:page"
import "wb:wasm"

foreign import kernel32 "system:Kernel32.lib"

PROCESS_MEMORY_COUNTERS_EX :: struct {
	cb:                         u32,
	PageFaultCount:             u32,
	PeakWorkingSetSize:         uint,
	WorkingSetSize:             uint,
	QuotaPeakPagedPoolUsage:    uint,
	QuotaPagedPoolUsage:        uint,
	QuotaPeakNonPagedPoolUsage: uint,
	QuotaNonPagedPoolUsage:     uint,
	PagefileUsage:              uint,
	PeakPagefileUsage:          uint,
	PrivateUsage:               uint,
}

@(default_calling_convention = "system")
foreign kernel32 {
	GetCurrentProcess :: proc() -> rawptr ---
	K32GetProcessMemoryInfo :: proc(process: rawptr, counters: ^PROCESS_MEMORY_COUNTERS_EX, cb: u32) -> b32 ---
}

memory_now :: proc() -> (working_set, private: int) {
	c := PROCESS_MEMORY_COUNTERS_EX{cb = size_of(PROCESS_MEMORY_COUNTERS_EX)}
	K32GetProcessMemoryInfo(GetCurrentProcess(), &c, c.cb)
	return int(c.WorkingSetSize), int(c.PrivateUsage)
}

b_nop :: proc "c" (env: wasm.Exec_Env) {}
b_touch :: proc "c" (env: wasm.Exec_Env, p: [^]u8, n: i32) -> i32 { return i32(p[0]) + n }

BENCH_SYMBOLS := [?]wasm.Native_Symbol{
	{"nop", rawptr(b_nop), "()", nil},
	{"touch", rawptr(b_touch), "(*~)i", nil},
}

Config :: struct {
	name:     string,
	engine:   wasm.Engine_Kind,
	compiler: wasm.Compiler,
	opt:      wasm.Opt_Level,
}

CONFIGS := [?]Config{
	{"wamr (fast interpreter)", .Wamr, .Cranelift, .Speed},
	{"wasmtime cranelift speed", .Wasmtime, .Cranelift, .Speed},
	{"wasmtime cranelift none", .Wasmtime, .Cranelift, .None},
	{"wasmtime winch", .Wasmtime, .Winch, .Speed},
}

cache_dir: string

start :: proc(c: Config) {
	wasm.runtime_destroy()
	rs := wasm.runtime_settings_default()
	rs.engine = c.engine
	rs.compiler = c.compiler
	rs.opt_level = c.opt
	rs.cache_dir = cache_dir
	wasm.configure(rs)
	if !page.register_imports() || !wasm.register("bench", BENCH_SYMBOLS[:]) { fmt.eprintln("register failed"); os.exit(1) }
}

options :: proc() -> wasm.Options {
	o := wasm.options_default()
	o.budget = -1
	o.max_call_ms = -1
	return o
}

create :: proc(image: []byte) -> (^wasm.Instance, f64) {
	t0 := time.tick_now()
	inst, err := wasm.instance_create(image, nil, nil, options(), "bench")
	ms := time.duration_milliseconds(time.tick_since(t0))
	if inst == nil { fmt.eprintln(err); os.exit(1) }
	return inst, ms
}

median :: proc(xs: []f64) -> f64 {
	slice.sort(xs)
	return xs[len(xs) / 2]
}

timed :: proc(inst: ^wasm.Instance, name: cstring, arg: i32) -> f64 {
	runs: [3]f64
	for i in 0 ..< len(runs) {
		cells := [2]u32{u32(arg), 0}
		t0 := time.tick_now()
		res := wasm.call_raw(inst, name, cells[:])
		runs[i] = time.duration_milliseconds(time.tick_since(t0))
		if res != .Ok { fmt.eprintln(name, res, inst.last_error); os.exit(1) }
	}
	return median(runs[:])
}

Row :: struct { label: string, values: [len(CONFIGS)]string }

main :: proc() {
	if len(os.args) < 2 { fmt.eprintln("usage: wasmbench wasmbench.wasm [module.wasm ...]"); os.exit(2) }
	images := make([dynamic][]byte)
	names := make([dynamic]string)
	for a in os.args[1:] {
		data, err := os.read_entire_file(a, context.allocator)
		if err != nil { fmt.eprintln("cannot read", a); os.exit(2) }
		append(&images, data)
		append(&names, filepath.base(a))
	}
	// a large synthetic module: compile time dominates its first load
	{
		b := strings.builder_make()
		strings.write_string(&b, "(module (memory (export \"memory\") 1)\n")
		for i in 0 ..< 3000 {
			fmt.sbprintf(&b, "(func $f%d (export \"f%d\") (param i32 i32) (result i32) (local i32)\n", i, i)
			for k in 0 ..< 12 { fmt.sbprintf(&b, " local.get 0 local.get 1 i32.mul i32.const %d i32.add local.get 2 i32.xor local.set 2\n", k * 7 + i) }
			strings.write_string(&b, " local.get 2 i32.const 4 i32.and if (result i32) local.get 2 else local.get 0 i32.load end)\n")
		}
		strings.write_string(&b, ")")
		bin, err := wasm.wat_to_wasm(strings.to_string(b))
		if err != "" { fmt.eprintln(err); os.exit(1) }
		append(&images, bin)
		append(&names, "synthetic (3000 functions)")
	}
	tmp := os.get_env("TEMP", context.allocator)
	cache_dir, _ = filepath.join({tmp, fmt.tprintf("wren-wasmbench-%d", time.now()._nsec)})
	defer os.remove_all(cache_dir)

	rows := make([dynamic]Row)
	row :: proc(rows: ^[dynamic]Row, label: string) -> int {
		for r, i in rows { if r.label == label { return i } }
		append(rows, Row{label = strings.clone(label)})
		return len(rows) - 1
	}
	set :: proc(rows: ^[dynamic]Row, label: string, c: int, v: string) { i := row(rows, label); rows[i].values[c] = strings.clone(v) }

	for cfg, ci in CONFIGS {
		_ = os.remove_all(cache_dir)
		starts: [3]f64
		for k in 0 ..< len(starts) {
			wasm.runtime_destroy()
			t0 := time.tick_now()
			start(cfg)
			starts[k] = time.duration_milliseconds(time.tick_since(t0))
		}
		set(&rows, "engine start + every import registered (ms)", ci, fmt.tprintf("%.2f", median(starts[:])))
		for image, mi in images {
			// first load: nothing cached (median of 3, caches emptied in between)
			firsts: [3]f64
			for k in 0 ..< len(firsts) {
				if cfg.engine == .Wasmtime { wasm.cache_flush(); wasm.cache_clear_memory(); _ = os.remove_all(cache_dir); start(cfg) }
				inst, ms := create(image)
				firsts[k] = ms
				wasm.destroy(inst)
			}
			set(&rows, fmt.tprintf("instantiate %s: first load (ms)", names[mi]), ci, fmt.tprintf("%.2f", median(firsts[:])))
			again: [5]f64
			for k in 0 ..< len(again) { inst, ms := create(image); again[k] = ms; wasm.destroy(inst) }
			set(&rows, fmt.tprintf("instantiate %s: compiled module in memory (ms)", names[mi]), ci, fmt.tprintf("%.3f", median(again[:])))
			if cfg.engine == .Wasmtime {
				wasm.cache_flush()
				disk: [3]f64
				for k in 0 ..< len(disk) { start(cfg); inst, ms := create(image); disk[k] = ms; wasm.destroy(inst) }
				set(&rows, fmt.tprintf("instantiate %s: next start, disk cache (ms)", names[mi]), ci, fmt.tprintf("%.2f", median(disk[:])))
			} else {
				set(&rows, fmt.tprintf("instantiate %s: next start, disk cache (ms)", names[mi]), ci, "n/a")
			}
		}

		inst, _ := create(images[0])
		set(&rows, "numeric loop, 50 M iterations (ms)", ci, fmt.tprintf("%.1f", timed(inst, "numeric", 50_000_000)))
		set(&rows, "heap sort, 1 M words (ms)", ci, fmt.tprintf("%.1f", timed(inst, "sort", 1 << 20)))
		set(&rows, "FNV-1a hash, 16 MiB (ms)", ci, fmt.tprintf("%.1f", timed(inst, "hash", 4)))
		n :: 1_000_000
		set(&rows, "1 M host calls () (ns/call)", ci, fmt.tprintf("%.1f", timed(inst, "calls_nop", n) * 1e6 / n))
		set(&rows, "1 M host calls (ptr, len) (ns/call)", ci, fmt.tprintf("%.1f", timed(inst, "calls_bytes", n) * 1e6 / n))
		wasm.destroy(inst)

		// memory per instance: 32 instances of the second module (a page module) when given, else the bench module
		img := len(os.args) > 2 ? images[1] : images[0]
		ws0, pv0 := memory_now()
		list: [32]^wasm.Instance
		for &x in list { x, _ = create(img) }
		ws1, pv1 := memory_now()
		for x in list { wasm.destroy(x) }
		set(&rows, fmt.tprintf("memory per instance of %s: working set / private (KiB)", len(os.args) > 2 ? names[1] : names[0]), ci,
			fmt.tprintf("%d / %d", (ws1 - ws0) / len(list) / 1024, (pv1 - pv0) / len(list) / 1024))
		fmt.eprintfln("done: %s", cfg.name)
	}
	wasm.runtime_destroy()

	fmt.print("| measure |")
	for c in CONFIGS { fmt.printf(" %s |", c.name) }
	fmt.print("\n|---|")
	for _ in CONFIGS { fmt.print("---:|") }
	fmt.println()
	for r in rows {
		fmt.printf("| %s |", r.label)
		for v in r.values { fmt.printf(" %s |", v) }
		fmt.println()
	}
}
