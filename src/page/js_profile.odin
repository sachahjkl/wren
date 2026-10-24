package page

// WREN_WASM_PROFILE=<prefix>: the measuring tools' sampling profile of the engine's code (wasm.profile_start) for the window
// realm of every page, written as <prefix>.<n>.json (Firefox Profiler format; tools\wasm_profile.ps1 sums it up) when the page
// closes. Function names need an engine built with tools\build_js.ps1 -Names.
// WREN_JS_PRELUDE=<file>: a script run in every window realm before the page's own scripts (the measuring tools wrap the engine's
// functions with timers: tools\js_prelude\*.js).

import "core:fmt"
import "core:os"
import "wb:base"
import "wb:wasm"

@(private = "file")
Js_Profile :: struct {
	inst: ^wasm.Instance,
	path: string,
}

@(private = "file")
profile_seq: int

js_profile_begin :: proc(p: ^Page, inst: ^wasm.Instance) {
	prefix := os.get_env("WREN_WASM_PROFILE", context.temp_allocator)
	if prefix == "" || p.worker != nil { return }
	if !wasm.profile_start(inst, js_engine_image()) { return }
	profile_seq += 1
	jp := new(Js_Profile)
	jp.inst = inst
	jp.path = fmt.aprintf("%s.%d.json", prefix, profile_seq)
	base.on_close(p.scope, proc(data: rawptr) {
		jp := (^Js_Profile)(data)
		if err := wasm.profile_finish(jp.inst, jp.path); err != "" { fmt.eprintfln("WREN_WASM_PROFILE: %s: %s", jp.path, err) }
		delete(jp.path)
		free(jp)
	}, jp)
}
js_prelude :: proc(p: ^Page) {
	path := os.get_env("WREN_JS_PRELUDE", context.temp_allocator)
	if path == "" || p.worker != nil { return }
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { fmt.eprintfln("WREN_JS_PRELUDE: cannot read %s", path); return }
	js_run(p, data, "wren:prelude")
}
