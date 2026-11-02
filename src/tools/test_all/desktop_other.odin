#+build linux
package test_all

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "wb:tools/tooling"

// What the steps of Linux run has no window: no desktop of its own.
on_own_desktop :: proc(code: ^int) -> bool { return false }

process_stacks_text :: proc(pid: int) -> string { return fmt.tprintfln("process %d: no stacks on this system", pid) }

warn_programs_running :: proc() {}

fetch_emoji_when_missing :: proc() {}

// What /STACK:33554432 is on Windows: Wasm calls run on the calling thread. Every child inherits it.
LINUX_STACK_BYTES :: 33554432

linux_raise_stack :: proc() {
	limit: linux.RLimit
	if linux.getrlimit(.STACK, &limit) != nil { return }
	limit.cur = min(LINUX_STACK_BYTES, limit.max)
	_ = linux.setrlimit(.STACK, &limit)
}

// libwgpu_native.a beside Odin's wgpu vendor package: present on the CI runner, maybe not in a bare WSL checkout. Without it the wgpu vendor panics at check time.
linux_has_wgpu_library :: proc() -> bool {
	root_text, code := tooling.capture({tooling.odin_program(), "root"})
	if code != 0 { return false }
	vendor := fmt.tprintf("%s/vendor/wgpu/lib", strings.trim_space(root_text))
	entries, err := os.read_all_directory_by_path(vendor, context.temp_allocator)
	if err != nil { return false }
	for e in entries {
		if strings.has_prefix(e.name, "wgpu-linux-") && os.exists(fmt.tprintf("%s/lib/libwgpu_native.a", e.fullpath)) { return true }
	}
	return false
}

// Package js_image #loads build/js/wren_js.wasm, which only a Windows build makes: an empty file lets odin check go through, and the tests that run the JS engine (page, blocker) are skipped while it
// is a stub. Package browser #loads the third-party licence texts bundled into the executable: the build fetches them with ./build.sh deps, empty stubs let the check go through when they are absent. True: the engine is a stub.
linux_prepare_stubs :: proc() -> (js_stub: bool) {
	_ = os.make_directory_all("build/linux")
	_ = os.make_directory_all("build/js")
	fi, err := os.stat("build/js/wren_js.wasm", context.temp_allocator)
	if err != nil || fi.size == 0 {
		_ = os.write_entire_file("build/js/wren_js.wasm", "")
		js_stub = true
	}
	for f in ([]string{"build/wasmtime/LICENSE", "ext/lexbor/LICENSE", "ext/lexbor/NOTICE"}) {
		if os.exists(f) { continue }
		_ = os.make_directory_all(f[:strings.last_index_byte(f, '/')])
		_ = os.write_entire_file(f, "")
	}
	return
}
