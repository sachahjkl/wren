#+build linux
package test_all

import "core:fmt"
import "core:os"
import "core:strings"
import "wb:tools/tooling"

// What the steps of Linux run has no window: no desktop of its own.
on_own_desktop :: proc(code: ^int) -> bool { return false }

process_stacks_text :: proc(pid: int) -> string { return fmt.tprintfln("process %d: no stacks on this system", pid) }

warn_programs_running :: proc() {}

fetch_emoji_when_missing :: proc() {}

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

// Package js_image #loads build/js/wren_js.wasm, which ./build.sh deps makes (buildjs): an empty file lets odin check go through, and the tests that run the JS engine (page, blocker) are skipped while it
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

// An Odin root under which `odin check -target:windows_amd64` goes through on Linux (build/odin-windows-check): links to
// the real root's folders (one path for every file: a package is never read twice), but vendor/wgpu is a folder of its own
// with a copy of its .odin files and an empty wgpu_native.lib, so that the vendor's check for the Windows library passes.
// Nothing is linked from it: it is for type checks only. "" when it cannot be made. Remade when the real root changes.
linux_windows_check_root :: proc() -> string {
	root_text, code := tooling.capture({tooling.odin_program(), "root"})
	if code != 0 { return "" }
	real := strings.trim_right(strings.trim_space(root_text), "/")
	dir := "build/odin-windows-check"
	stamp := fmt.tprintf("%s/.root", dir)
	if data, err := os.read_entire_file(stamp, context.temp_allocator); err == nil && string(data) == real { return dir }
	_ = os.remove_all(dir)
	if os.make_directory_all(fmt.tprintf("%s/vendor/wgpu/lib/wgpu-windows-x86_64-msvc-release/lib", dir)) != nil { return "" }
	link_all :: proc(from, to: string, except: string) -> bool {
		entries, err := os.read_all_directory_by_path(from, context.temp_allocator)
		if err != nil { return false }
		for e in entries {
			if e.name == except || e.name == "vendor" && except == "" { continue }
			if os.symlink(e.fullpath, fmt.tprintf("%s/%s", to, e.name)) != nil { return false }
		}
		return true
	}
	if !link_all(real, dir, "vendor") { return "" }
	if !link_all(fmt.tprintf("%s/vendor", real), fmt.tprintf("%s/vendor", dir), "wgpu") { return "" }
	wgpu := fmt.tprintf("%s/vendor/wgpu", real)
	entries, err := os.read_all_directory_by_path(wgpu, context.temp_allocator)
	if err != nil { return "" }
	for e in entries {
		if e.type == .Directory {
			if e.name == "lib" { continue }
			if os.symlink(e.fullpath, fmt.tprintf("%s/vendor/wgpu/%s", dir, e.name)) != nil { return "" }
		} else if os.copy_file(fmt.tprintf("%s/vendor/wgpu/%s", dir, e.name), e.fullpath) != nil { return "" }
	}
	if os.write_entire_file(fmt.tprintf("%s/vendor/wgpu/lib/wgpu-windows-x86_64-msvc-release/lib/wgpu_native.lib", dir), "") != nil { return "" }
	if os.write_entire_file(stamp, real) != nil { return "" }
	return dir
}
