package deps

@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "wb:base"   // (each of these is of one system: fetch_linux.odin has the other)
@(require) import "wb:tools/tooling"

// Wasmtime is built from source inside native/wasmtime_capi (version must match WASMTIME_VERSION in src/wasm/wasmtime.odin).
WASMTIME_VERSION :: "49.0.3"

// The release Odin's vendor:wgpu is written for (its vendor/wgpu/wgpu.odin names it).
WGPU_VERSION :: "v29.0.1.1"

// Cisco's own binary: the patent licence covers only what it ships, never a build from source. The digests are of the .bz2 files, whose
// contents match the MD5 Cisco signs beside them (libopenh264-<version>-<arch>.7.so.signed.md5.txt).
OPENH264_VERSION :: "2.4.1"
OPENH264_SHA256_LINUX_X64 :: "ca413853d99d960ebcd5ae5b4c65a85bb2b5598e9042e64700a9f4b737ca3a3f"
OPENH264_SHA256_LINUX_ARM64 :: "cf37063a9f77cf343153e41ef73d3ac05d4825ac6099cd862b1b7799eabf74f2"
OPENH264_URL :: "https://ciscobinary.openh264.org"
OPENH264_SONAME :: "libopenh264.so.7"

EMOJI_DEST :: "build/emoji"
// (the toolkit's own tool: fetch_emoji, pinned by commit and SHA-256, belongs to the toolkit's repository)
TOOLKIT_TK :: "ext/gui_toolkit/tools/tk"
TOOLKIT_TK_EXE :: "-out:build/tk.exe"

when ODIN_ARCH == .amd64 {
	@(private) ARCH_NAME :: "x86_64"
	@(private) OPENH264_ARCH :: "linux64"
	@(private) OPENH264_SHA256 :: OPENH264_SHA256_LINUX_X64
} else {
	@(private) ARCH_NAME :: "aarch64"
	@(private) OPENH264_ARCH :: "linux-arm64"
	@(private) OPENH264_SHA256 :: OPENH264_SHA256_LINUX_ARM64
}

when ODIN_OS == .Windows {

// Wasmtime is built from source inside native/wasmtime_capi (linked into build/native/wren_native.lib);
// this step only copies its license file where src/browser/third_party.odin embeds it.
fetch_wasmtime :: proc(o: Options) -> bool {
	dest := "build/wasmtime/LICENSE"
	if !o.force && os.exists(dest) {
		tooling.say(o.log, fmt.tprintfln("wasmtime %s license already in %s", WASMTIME_VERSION, dest))
		return true
	}
	_ = os.make_directory_all("build/wasmtime")
	if os.copy_file(dest, "native/wasmtime_capi/LICENSE") != nil { return fail(o, "the Wasmtime license cannot be copied from native/wasmtime_capi/LICENSE") }
	tooling.say(o.log, fmt.tprintfln("wasmtime %s license copied to %s (runtime built into wren_native.lib)", WASMTIME_VERSION, dest))
	return true
}

fetch_wgpu :: proc(o: Options) -> bool { return fail(o, "wgpu-native is fetched this way on Linux: on Windows, ext/gui_toolkit/tools/tk fetch_wgpu (wrentool build, WREN_RENDER=wgpu)") }
fetch_openh264 :: proc(o: Options) -> bool { return fail(o, "OpenH264 is fetched on Linux: Windows decodes H.264 through Media Foundation") }

}

// Noto Color Emoji (COLR v1) for the built-in emoji: compiled into wren.exe (src/browser/font_settings.odin); -Unicode: Unicode's emoji data too (the toolkit's tests/colr).
fetch_emoji :: proc(o: Options) -> bool {
	when ODIN_OS == .Windows {
		dest := o.dest != "" ? o.dest : EMOJI_DEST
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, tooling.odin_program(), "run", TOOLKIT_TK, TOOLKIT_TK_EXE, "--", "fetch_emoji", fmt.tprintf("-dest:%s", dest))
		if o.unicode { append(&cmd, "-unicode") }
		return tooling.run({command = cmd[:], log = o.log}) == 0
	} else {
		return fail(o, "the emoji font is fetched on Windows")
	}
}
