package page

// WREN_WASM_PROFILE=<prefix>: the measuring tools' sampling profile of the engine's code (wasm.profile_start) for the window
// realm of every page, written as <prefix>.<n>.json (Firefox Profiler format: open it with the Firefox Profiler) when the page
// closes. Function names need an engine built with src\tools\buildjs -names.
// WREN_JS_PROFILE=<prefix>: the page's own functions: the engine counts the frames of the stack every few interrupt checks
// (native/js/odin/qjs_realm.odin), written as <prefix>.<n>.js.txt when the page closes: the functions with the most samples of their
// own, and with the most on the stack.
// WREN_JS_PROFILE_FROM=<ms>: with WREN_JS_PROFILE, count only from that many ms after the realm was made.
// WREN_JS_PROFILE_TIME=1: with WREN_JS_PROFILE, a sample per tick of wasm.wasmtime.epoch_tick_ms, at the next interrupt check: time, where the default counts checks.
// WREN_JS_IMAGE=<file>: another engine image, for all the realms of the browser (buildjs -names for a readable WREN_WASM_PROFILE; an A/B of two engines with one browser).
// WREN_JS_PRELUDE=<file>: a script run in every window realm before the page's own scripts (a measure wraps the engine's
// functions with timers).

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:host"
import "wb:js"
import "wb:wasm"

// The buffer the engine's profile is dumped into, and how many frames each table of the report lists.
JS_PROFILE_DUMP_BYTES :: 4 << 20
JS_PROFILE_REPORT_ROWS :: 70
JS_PROFILE_JIT_MARK :: "jit: "
@(private = "file") BYTES_PER_KIB :: 1024.0
@(private = "file") NS_PER_MS :: 1e6

@(private = "file")
Js_Profile :: struct {
	inst:      ^wasm.Instance,
	path:      string,   // the engine's (wasm) profile, "" when not asked for
	js_path:   string,   // the page's functions, "" when not asked for
}


js_profile_begin :: proc(p: ^Page, inst: ^wasm.Instance) {
	if p.worker != nil { return }
	wasm_prefix := os.get_env("WREN_WASM_PROFILE", context.temp_allocator)
	js_prefix := os.get_env("WREN_JS_PROFILE", context.temp_allocator)
	if wasm_prefix == "" && js_prefix == "" { return }
	jp := new(Js_Profile)
	jp.inst = inst
	the_pages.profile_seq += 1
	if wasm_prefix != "" && wasm.profile_start(inst, js_engine_image()) { jp.path = fmt.aprintf("%s.%d.json", wasm_prefix, the_pages.profile_seq) }
	if js_prefix != "" {
		// WREN_JS_PROFILE_FROM=<ms>: the functions are counted from that long after the realm was made (a page that has settled: what
		// it does when nothing moves), not from its first script
		from_ms, _ := strconv.parse_f64(os.get_env("WREN_JS_PROFILE_FROM", context.temp_allocator))
		by_time := os.get_env("WREN_JS_PROFILE_TIME", context.temp_allocator) != ""
		argv := [1]u32{from_ms > 0 ? 0 : by_time ? 2 : 1}
		if wasm.call_raw(inst, "wj_profile_set", argv[:]) == .Ok {
			jp.js_path = fmt.aprintf("%s.%d.js.txt", js_prefix, the_pages.profile_seq)
			trace_on := [1]u32{1}
			wasm.call_raw(inst, "wj_jit_trace", trace_on[:])
			if from_ms > 0 {
				host.set_timer(p.loop, from_ms, 0, proc(data: rawptr) {
					jp := (^Js_Profile)(data)
					on := [1]u32{1}
					wasm.call_raw(jp.inst, "wj_profile_set", on[:])
				}, jp, p.scope)
			}
		}
	}
	if jp.path == "" && jp.js_path == "" { free(jp); return }
	base.on_close(p.scope, proc(data: rawptr) {
		jp := (^Js_Profile)(data)
		if jp.js_path != "" { js_profile_dump(jp.inst, jp.js_path) }
		if jp.path != "" {
			if err := wasm.profile_finish(jp.inst, jp.path); err != "" { fmt.eprintfln("WREN_WASM_PROFILE: %s: %s", jp.path, err) }
		}
		delete(jp.path)
		delete(jp.js_path)
		free(jp)
	}, jp)
}

@(private = "file")
js_profile_dump :: proc(inst: ^wasm.Instance, path: string) {
	r, res := wasm.call_i32(inst, "wj_alloc", i32(JS_PROFILE_DUMP_BYTES))
	if res != .Ok || r == 0 { return }
	ptr := u32(r)
	defer { fa := [1]u32{ptr}; wasm.call_raw(inst, "wj_dealloc", fa[:]) }
	argv := [2]u32{ptr, JS_PROFILE_DUMP_BYTES}
	if wasm.call_raw(inst, "wj_profile_dump", argv[:], 1) != .Ok { return }
	n := argv[0]
	b := wasm.guest_bytes(inst, u64(ptr), u64(n))
	if b == nil || n == 0 { return }
	Row :: struct { self, incl: int, frame: string }
	rows := make([dynamic]Row, context.temp_allocator)
	header := ""
	for line in strings.split_lines(string(b), context.temp_allocator) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) >= 3 && f[0] != "samples" {
			s, _ := strconv.parse_int(f[0])
			i, _ := strconv.parse_int(f[1])
			append(&rows, Row{s, i, strings.join(f[2:], "\t", context.temp_allocator)})
		} else if len(f) >= 3 { header = line }
	}
	// (what the JIT said is not a sample: wj_jit_trace)
	notes := make([dynamic]Row, context.temp_allocator)
	kept := 0
	for r in rows {
		if strings.has_prefix(r.frame, JS_PROFILE_JIT_MARK) { append(&notes, r) } else { rows[kept] = r; kept += 1 }
	}
	resize(&rows, kept)
	total := 0
	for r in rows { total += r.self }
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "the page's functions (samples every few interrupt checks of the interpreter: calls and loop iterations; %d samples)\n%s\n", total, header)
	slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.self > b.self })
	fmt.sbprintf(&sb, "\n-- most samples of their own (%%, frame)\n")
	for r, k in rows { if k >= JS_PROFILE_REPORT_ROWS || r.self == 0 { break }; fmt.sbprintf(&sb, "%6.2f %%  %6d  %s\n", f64(r.self) * 100 / f64(max(total, 1)), r.self, r.frame) }
	slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.incl > b.incl })
	fmt.sbprintf(&sb, "\n-- most samples with them on the stack (%%, frame)\n")
	for r, k in rows { if k >= JS_PROFILE_REPORT_ROWS { break }; fmt.sbprintf(&sb, "%6.2f %%  %6d  %s\n", f64(r.incl) * 100 / f64(max(total, 1)), r.incl, r.frame) }
	slice.sort_by(notes[:], proc(a, b: Row) -> bool { return a.self > b.self })
	fmt.sbprintf(&sb, "\n-- what the JIT refused and left (count, what)\n")
	if st, ok := js.jit_stats(inst); ok {
		a := wasm.attach_stats()
		fmt.sbprintf(&sb, "%.0f translated, %.0f refused, %.0f KiB of modules for %.0f KiB of bytecode, %.0f entries, %.0f deopts; the process: Cranelift %.0f ms, link %.0f ms\n",
			st.compiled, st.refused, st.module_bytes / BYTES_PER_KIB, st.bytecode_bytes / BYTES_PER_KIB, st.entries, st.exits_deopt, f64(a.compile_ns) / NS_PER_MS, f64(a.link_ns) / NS_PER_MS)
	}
	for r in notes { fmt.sbprintf(&sb, "%6d  %s\n", r.self, r.frame) }
	_ = os.write_entire_file(path, transmute([]byte)strings.to_string(sb))
}

// WREN_JS_IMAGE=<file>: another engine image (one that keeps its names: buildjs -names), for WREN_WASM_PROFILE in the browser itself.
js_image_from_env :: proc() {
	path := os.get_env("WREN_JS_IMAGE", context.temp_allocator)
	if path == "" { return }
	data, err := os.read_entire_file(path, base.process_allocator())
	if err != nil { fmt.eprintfln("WREN_JS_IMAGE: cannot read %s", path); return }
	js_image_override = data
}

// WREN_JS_CODE=<file>: other machine code for the engine's image in place of the program's (jsengine precompile): an A/B of CPU features with one browser. Never
// in a release: an address in the environment is not where machine code comes from.
js_code_from_env :: proc() {
	when #config(WREN_CHANNEL, "dev") != "release" {
		path := os.get_env("WREN_JS_CODE", context.temp_allocator)
		if path == "" { return }
		data, err := os.read_entire_file(path, base.process_allocator())
		if err != nil { fmt.eprintfln("WREN_JS_CODE: cannot read %s", path); return }
		wasm.shipped_set(data)
	}
}

// WREN_JS_PROFILE_TIME, a realm that has started: its epoch ticks ask for samples.
js_profile_ticks :: proc(inst: ^wasm.Instance) {
	if os.get_env("WREN_JS_PROFILE_TIME", context.temp_allocator) == "" { return }
	tick, res := wasm.call_i32(inst, "wj_profile_tick_address")
	counter, res2 := wasm.call_i32(inst, "wj_profile_counter_address")
	if res != .Ok || res2 != .Ok { return }
	inst.poll_tick = (^i32)(raw_data(wasm.guest_bytes(inst, u64(u32(tick)), 4)))
	inst.poll_counter = (^i32)(raw_data(wasm.guest_bytes(inst, u64(u32(counter)), 4)))
}

js_prelude :: proc(p: ^Page) {
	path := os.get_env("WREN_JS_PRELUDE", context.temp_allocator)
	if path == "" || p.worker != nil { return }
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { fmt.eprintfln("WREN_JS_PRELUDE: cannot read %s", path); return }
	js_run(p, data, "wren:prelude")
}
