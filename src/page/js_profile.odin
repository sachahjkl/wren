package page

// WREN_WASM_PROFILE=<prefix>: the measuring tools' sampling profile of the engine's code (wasm.profile_start) for the window
// realm of every page, written as <prefix>.<n>.json (Firefox Profiler format; tools\wasm_profile.ps1 sums it up) when the page
// closes. Function names need an engine built with tools\build_js.ps1 -Names.
// WREN_JS_PROFILE=<prefix>: the page's own functions: the engine counts the frames of the stack every few interrupt checks
// (native/js/odin/qjs_realm.odin), written as <prefix>.<n>.js.txt when the page closes: the functions with the most samples of their
// own, and with the most on the stack.
// WREN_JS_PROFILE_FROM=<ms>: with WREN_JS_PROFILE, count only from that many ms after the realm was made.
// WREN_JS_PRELUDE=<file>: a script run in every window realm before the page's own scripts (the measuring tools wrap the engine's
// functions with timers: tools\js_prelude\*.js).

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:host"
import "wb:wasm"

@(private = "file")
Js_Profile :: struct {
	inst:      ^wasm.Instance,
	path:      string,   // the engine's (wasm) profile, "" when not asked for
	js_path:   string,   // the page's functions, "" when not asked for
}

@(private = "file")
profile_seq: int

js_profile_begin :: proc(p: ^Page, inst: ^wasm.Instance) {
	if p.worker != nil { return }
	wasm_prefix := os.get_env("WREN_WASM_PROFILE", context.temp_allocator)
	js_prefix := os.get_env("WREN_JS_PROFILE", context.temp_allocator)
	if wasm_prefix == "" && js_prefix == "" { return }
	jp := new(Js_Profile)
	jp.inst = inst
	profile_seq += 1
	if wasm_prefix != "" && wasm.profile_start(inst, js_engine_image()) { jp.path = fmt.aprintf("%s.%d.json", wasm_prefix, profile_seq) }
	if js_prefix != "" {
		// WREN_JS_PROFILE_FROM=<ms>: the functions are counted from that long after the realm was made (a page that has settled: what
		// it does when nothing moves), not from its first script
		from_ms, _ := strconv.parse_f64(os.get_env("WREN_JS_PROFILE_FROM", context.temp_allocator))
		argv := [1]u32{from_ms > 0 ? 0 : 1}
		if wasm.call_raw(inst, "wj_profile_set", argv[:]) == .Ok {
			jp.js_path = fmt.aprintf("%s.%d.js.txt", js_prefix, profile_seq)
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
	SIZE :: 4 << 20
	r, res := wasm.call_i32(inst, "wj_alloc", i32(SIZE))
	if res != .Ok || r == 0 { return }
	ptr := u32(r)
	defer { fa := [1]u32{ptr}; wasm.call_raw(inst, "wj_dealloc", fa[:]) }
	argv := [2]u32{ptr, SIZE}
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
	total := 0
	for r in rows { total += r.self }
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "the page's functions (samples every few interrupt checks of the interpreter: calls and loop iterations; %d samples)\n%s\n", total, header)
	slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.self > b.self })
	fmt.sbprintf(&sb, "\n-- most samples of their own (%%, frame)\n")
	for r, k in rows { if k >= 70 || r.self == 0 { break }; fmt.sbprintf(&sb, "%6.2f %%  %6d  %s\n", f64(r.self) * 100 / f64(max(total, 1)), r.self, r.frame) }
	slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.incl > b.incl })
	fmt.sbprintf(&sb, "\n-- most samples with them on the stack (%%, frame)\n")
	for r, k in rows { if k >= 70 { break }; fmt.sbprintf(&sb, "%6.2f %%  %6d  %s\n", f64(r.incl) * 100 / f64(max(total, 1)), r.incl, r.frame) }
	_ = os.write_entire_file(path, transmute([]byte)strings.to_string(sb))
}

js_prelude :: proc(p: ^Page) {
	path := os.get_env("WREN_JS_PRELUDE", context.temp_allocator)
	if path == "" || p.worker != nil { return }
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { fmt.eprintfln("WREN_JS_PRELUDE: cannot read %s", path); return }
	js_run(p, data, "wren:prelude")
}