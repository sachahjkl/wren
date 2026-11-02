#+build !windows
package deps

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "wb:base"
import "wb:tools/tooling"

// Sealed: the archive carries its own copy of Rust's standard library, and so does build/native-linux/libwren_native.a. GNU ld pulls members of both and stops on the symbols they share
// unmangled (rust_eh_personality, the allocator and panic shims); two standard libraries of different compilers must never call into each other anyway. So the archive is linked into one
// relocatable object and every symbol but `keep`'s is made local: the program sees the C API only, each Rust keeps its own runtime. (On Windows the MSVC toolchain has no such shared symbol.)
@(private)
seal_archive :: proc(o: Options, archive, work, out_archive: string, keep: []string) -> bool {
	object := fmt.tprintf("%s/sealed.o", work)
	if tooling.run({command = {"ld", "-r", "--force-group-allocation", "--whole-archive", archive, "-o", object}, log = o.log}) != 0 { return fail(o, "ld -r failed") }
	text, code := tooling.capture({"nm", "-g", "--defined-only", object}, allocator = context.temp_allocator)
	if code != 0 { return fail(o, "nm failed") }
	names := strings.builder_make(context.temp_allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) < 3 { continue }
		for prefix in keep { if strings.has_prefix(parts[2], prefix) { fmt.sbprintln(&names, parts[2]); break } }
	}
	keep_file := fmt.tprintf("%s/keep.txt", work)
	_ = os.write_entire_file(keep_file, strings.to_string(names))
	if tooling.run({command = {"objcopy", fmt.tprintf("--keep-global-symbols=%s", keep_file), object}, log = o.log}) != 0 { return fail(o, "objcopy failed") }
	_ = os.make_directory_all(filepath.dir(out_archive))
	_ = os.remove(out_archive)
	if tooling.run({command = {"ar", "rcs", out_archive, object}, log = o.log}) != 0 { return fail(o, "ar failed") }
	return true
}

fetch_wasmtime :: proc(o: Options) -> bool {
	out := "build/wasmtime-linux"
	stamp_text := fmt.tprintf("%s-%s-sealed", WASMTIME_VERSION, ARCH_NAME)
	stamp := fmt.tprintf("%s/VERSION", out)
	if !o.force && os.exists(fmt.tprintf("%s/lib/libwasmtime.a", out)) && read_stamp(stamp) == stamp_text {
		tooling.say(o.log, fmt.tprintfln("wasmtime %s already in %s", WASMTIME_VERSION, out))
		return true
	}
	name := fmt.tprintf("wasmtime-v%s-%s-linux-c-api", WASMTIME_VERSION, ARCH_NAME)
	tarball := fmt.tprintf("%s/%s.tar.xz", TEMP_DIR, name)
	if !tooling.download_pinned(fmt.tprintf("%s/v%s/%s.tar.xz", WASMTIME_RELEASES, WASMTIME_VERSION, name), tarball, WASMTIME_SHA256, o.log) { return false }
	x := work_folder("wasmtime")
	defer base.remove_tree(x)
	if !unpack(o, tarball, x) { return fail(o, "the Wasmtime archive cannot be unpacked") }
	from := fmt.tprintf("%s/%s", x, name)
	base.remove_tree(out)
	_ = os.make_directory_all(out)
	if os.copy_directory_all(fmt.tprintf("%s/include", out), fmt.tprintf("%s/include", from)) != nil { return fail(o, "the Wasmtime headers cannot be copied") }
	if !seal_archive(o, fmt.tprintf("%s/lib/libwasmtime.a", from), x, fmt.tprintf("%s/lib/libwasmtime.a", out), {"wasm_", "wasmtime_", "wasi_", "wat_"}) { return false }
	// (the licence text src/browser/third_party.odin bundles: the C API archive has none, the tag's file is the Windows archive's, at the place Windows puts it)
	if !tooling.download_pinned(fmt.tprintf("%s/v%s/LICENSE", WASMTIME_LICENSE_URL, WASMTIME_VERSION), "build/wasmtime/LICENSE", WASMTIME_LICENSE_SHA256, o.log) { return false }
	tooling.say(o.log, fmt.tprintfln("wasmtime %s (%s) in %s", WASMTIME_VERSION, ARCH_NAME, out))
	return write_stamp(stamp, stamp_text)
}

fetch_wgpu :: proc(o: Options) -> bool {
	when ODIN_ARCH != .amd64 { return fail(o, "no wgpu-native release pinned for this processor") }
	root_text, code := tooling.capture({tooling.odin_program(), "root"}, allocator = context.temp_allocator)
	if code != 0 { return fail(o, "odin root failed") }
	root := strings.trim_space(root_text)
	dest := fmt.tprintf("%s/vendor/wgpu/lib/wgpu-linux-%s-release/lib", root, ARCH_NAME)
	if vendor, err := os.read_entire_file(fmt.tprintf("%s/vendor/wgpu/wgpu.odin", root), context.temp_allocator); err != nil || !strings.contains(string(vendor), fmt.tprintf("releases/tag/%s", WGPU_VERSION)) {
		fmt.eprintfln("warning: Odin's vendor/wgpu does not name wgpu-native %s: check the version it expects", WGPU_VERSION)
	}
	stamp_text := fmt.tprintf("%s-sealed", WGPU_VERSION)
	stamp := fmt.tprintf("%s/VERSION", dest)
	if !o.force && os.exists(fmt.tprintf("%s/libwgpu_native.a", dest)) && read_stamp(stamp) == stamp_text {
		tooling.say(o.log, fmt.tprintfln("wgpu-native %s already in %s", WGPU_VERSION, dest))
		return true
	}
	asset := fmt.tprintf("wgpu-linux-%s-release.zip", ARCH_NAME)
	zip := fmt.tprintf("%s/%s", TEMP_DIR, asset)
	if !tooling.download_pinned(fmt.tprintf("%s/%s/%s", WGPU_RELEASES, WGPU_VERSION, asset), zip, WGPU_SHA256, o.log) { return false }
	x := work_folder("wgpu")
	defer base.remove_tree(x)
	if tooling.run({command = {"unzip", "-q", zip, "-d", x}, log = o.log}) != 0 { return fail(o, "the wgpu-native archive cannot be unpacked") }
	if !seal_archive(o, fmt.tprintf("%s/lib/libwgpu_native.a", x), x, fmt.tprintf("%s/libwgpu_native.a", dest), {"wgpu"}) { return false }
	tooling.say(o.log, fmt.tprintfln("wgpu-native %s (%s) in %s", WGPU_VERSION, ARCH_NAME, dest))
	return write_stamp(stamp, stamp_text)
}

fetch_openh264 :: proc(o: Options) -> bool {
	out := "build/openh264-linux"
	so := fmt.tprintf("%s/%s", out, OPENH264_SONAME)
	stamp := fmt.tprintf("%s/VERSION", out)
	if !o.force && os.exists(so) && read_stamp(stamp) == OPENH264_VERSION {
		tooling.say(o.log, fmt.tprintfln("openh264 %s already in %s", OPENH264_VERSION, out))
		return true
	}
	asset := fmt.tprintf("libopenh264-%s-%s.7.so.bz2", OPENH264_VERSION, OPENH264_ARCH)
	if len(OPENH264_SHA256) == 0 { return fail(o, fmt.tprintf("set the SHA-256 of %s in src/tools/wrentool/deps/fetch.odin before fetching", asset)) }
	file := fmt.tprintf("%s/%s", TEMP_DIR, asset)
	if !tooling.download_pinned(fmt.tprintf("%s/%s", OPENH264_URL, asset), file, OPENH264_SHA256, o.log) { return false }
	_ = os.make_directory_all(out)
	if tooling.run({command = {"sh", "-c", fmt.tprintf(`bunzip2 -c '%s' > '%s' && chmod 0644 '%s' && ln -sf %s '%s/libopenh264.so'`, file, so, so, OPENH264_SONAME, out)}, log = o.log}) != 0 { return fail(o, "the OpenH264 file cannot be unpacked") }
	tooling.say(o.log, fmt.tprintfln("openh264 %s in %s (set media.h264.openh264_path to %s, or add %s to the library path)", OPENH264_VERSION, out, so, out))
	return write_stamp(stamp, OPENH264_VERSION)
}

