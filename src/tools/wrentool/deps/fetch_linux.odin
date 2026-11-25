#+build !windows
package deps

import "core:fmt"
import "core:os"
import "core:strings"
import "wb:tools/tooling"

// Wasmtime is built from source inside native/wasmtime_capi (linked into build/native-linux/libwren_native.a);
// this step only copies its license file where src/browser/third_party.odin embeds it.
fetch_wasmtime :: proc(o: Options) -> bool {
	dest := "build/wasmtime/LICENSE"
	if !o.force && os.exists(dest) {
		tooling.say(o.log, fmt.tprintfln("wasmtime %s license already in %s", WASMTIME_VERSION, dest))
		return true
	}
	_ = os.make_directory_all("build/wasmtime")
	if os.copy_file(dest, "native/wasmtime_capi/LICENSE") != nil { return fail(o, "the Wasmtime license cannot be copied from native/wasmtime_capi/LICENSE") }
	tooling.say(o.log, fmt.tprintfln("wasmtime %s license copied to %s (runtime built into libwren_native.a)", WASMTIME_VERSION, dest))
	return true
}

// wgpu-native (v29.0.1.1 ABI) is built from source inside native/wgpu_capi (linked into build/native-linux/libwren_native.a,
// sharing wgpu-core/naga/ash with native/webgl). Odin's vendor:wgpu still checks #exists(libwgpu_native.a) and lists it in
// its foreign import, so we place an empty archive there while libwren_native.a supplies all wgpu* symbols.
fetch_wgpu :: proc(o: Options) -> bool {
	when ODIN_ARCH != .amd64 { return fail(o, "no wgpu-native stub configured for this processor") }
	root_text, code := tooling.capture({tooling.odin_program(), "root"}, allocator = context.temp_allocator)
	if code != 0 { return fail(o, "odin root failed") }
	root := strings.trim_space(root_text)
	dest := fmt.tprintf("%s/vendor/wgpu/lib/wgpu-linux-%s-release/lib", root, ARCH_NAME)
	if vendor, err := os.read_entire_file(fmt.tprintf("%s/vendor/wgpu/wgpu.odin", root), context.temp_allocator); err != nil || !strings.contains(string(vendor), fmt.tprintf("releases/tag/%s", WGPU_VERSION)) {
		fmt.eprintfln("warning: Odin's vendor/wgpu does not name wgpu-native %s: check the version it expects", WGPU_VERSION)
	}
	stamp_text := fmt.tprintf("%s-stub-v1", WGPU_VERSION)
	stamp := fmt.tprintf("%s/VERSION", dest)
	lib := fmt.tprintf("%s/libwgpu_native.a", dest)
	if !o.force && os.exists(lib) && read_stamp(stamp) == stamp_text {
		tooling.say(o.log, fmt.tprintfln("wgpu-native %s stub already in %s", WGPU_VERSION, dest))
		return true
	}
	_ = os.make_directory_all(dest)
	_ = os.remove(lib)
	if tooling.run({command = {"ar", "rcs", lib}, log = o.log}) != 0 { return fail(o, "ar failed creating empty libwgpu_native.a stub") }
	tooling.say(o.log, fmt.tprintfln("wgpu-native %s empty stub in %s (symbols supplied by libwren_native.a)", WGPU_VERSION, dest))
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
