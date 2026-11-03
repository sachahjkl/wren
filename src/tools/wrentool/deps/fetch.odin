package deps

@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "wb:base"   // (each of these is of one system: fetch_linux.odin has the other)
@(require) import "wb:tools/tooling"

// To move to another Wasmtime: change the version and the digests (GitHub shows them for each *-c-api asset), then WASMTIME_VERSION of src/wasm/wasmtime.odin (part of the compiled-code cache key).
WASMTIME_VERSION :: "49.0.3"
WASMTIME_SHA256_WINDOWS :: "f8dabbc1df2358f15effbd6e50c940c03df3836e13cbf4f09cdf6369057aed01"
WASMTIME_SHA256_LINUX_X64 :: "49c9641ac1f6158ed90404115315b36a9ae68338acda16fcf00f0819622ccd97"
WASMTIME_SHA256_LINUX_ARM64 :: "fb9c1a101c092cd3b4536ddb4c68ae31ad70d78bbdbc408d0e007f05a2fdd409"
WASMTIME_LICENSE_SHA256 :: "268872b9816f90fd8e85db5a28d33f8150ebb8dd016653fb39ef1f94f2686bc5"
WASMTIME_RELEASES :: "https://github.com/bytecodealliance/wasmtime/releases/download"
WASMTIME_LICENSE_URL :: "https://raw.githubusercontent.com/bytecodealliance/wasmtime"

// The release Odin's vendor:wgpu is written for (its vendor/wgpu/wgpu.odin names it). Linux, x86-64: where that package looks for it is $(odin root)/vendor/wgpu/lib.
WGPU_VERSION :: "v29.0.1.1"
WGPU_SHA256 :: "95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a"
WGPU_RELEASES :: "https://github.com/gfx-rs/wgpu-native/releases/download"

// Cisco's own binary: the patent licence covers only what it ships, never a build from source. Set the digests of the release page before fetching.
OPENH264_VERSION :: "2.4.1"
OPENH264_SHA256_LINUX_X64 :: ""
OPENH264_SHA256_LINUX_ARM64 :: ""
OPENH264_URL :: "http://ciscobinary.openh264.org"
OPENH264_SONAME :: "libopenh264.so.7"

EMOJI_DEST :: "build/emoji"
// (the toolkit's own tool: fetch_emoji, pinned by commit and SHA-256, belongs to the toolkit's repository)
TOOLKIT_TK :: "ext/gui_toolkit/tools/tk"
TOOLKIT_TK_EXE :: "-out:build/tk.exe"

when ODIN_ARCH == .amd64 {
	@(private) ARCH_NAME :: "x86_64"
	@(private) WASMTIME_SHA256 :: WASMTIME_SHA256_LINUX_X64
	@(private) OPENH264_ARCH :: "linux64"
	@(private) OPENH264_SHA256 :: OPENH264_SHA256_LINUX_X64
} else {
	@(private) ARCH_NAME :: "aarch64"
	@(private) WASMTIME_SHA256 :: WASMTIME_SHA256_LINUX_ARM64
	@(private) OPENH264_ARCH :: "linux-arm64"
	@(private) OPENH264_SHA256 :: OPENH264_SHA256_LINUX_ARM64
}

when ODIN_OS == .Windows {

fetch_wasmtime :: proc(o: Options) -> bool {
	out := "build/wasmtime"
	stamp := fmt.tprintf("%s/VERSION", out)
	if !o.force && os.exists(fmt.tprintf("%s/lib/wasmtime.lib", out)) && read_stamp(stamp) == WASMTIME_VERSION {
		tooling.say(o.log, fmt.tprintfln("wasmtime %s already in %s", WASMTIME_VERSION, out))
		return true
	}
	name := fmt.tprintf("wasmtime-v%s-x86_64-windows-c-api", WASMTIME_VERSION)
	zip := fmt.tprintf("%s/%s.zip", TEMP_DIR, name)
	if !tooling.download_pinned(fmt.tprintf("%s/v%s/%s.zip", WASMTIME_RELEASES, WASMTIME_VERSION, name), zip, WASMTIME_SHA256_WINDOWS, o.log) { return false }
	x := work_folder("wasmtime")
	defer base.remove_tree(x)
	if !unpack(o, zip, x) { return fail(o, "the Wasmtime archive cannot be unpacked") }
	from := fmt.tprintf("%s/%s", x, name)
	_ = os.make_directory_all(fmt.tprintf("%s/lib", out))
	base.remove_tree(fmt.tprintf("%s/include", out))
	if os.copy_directory_all(fmt.tprintf("%s/include", out), fmt.tprintf("%s/include", from)) != nil { return fail(o, "the Wasmtime headers cannot be copied") }
	if os.copy_file(fmt.tprintf("%s/lib/wasmtime.lib", out), fmt.tprintf("%s/lib/wasmtime.lib", from)) != nil { return fail(o, "wasmtime.lib cannot be copied") }
	if os.copy_file(fmt.tprintf("%s/LICENSE", out), fmt.tprintf("%s/LICENSE", from)) != nil { return fail(o, "the Wasmtime licence cannot be copied") }
	tooling.say(o.log, fmt.tprintfln("wasmtime %s installed in %s", WASMTIME_VERSION, out))
	return write_stamp(stamp, WASMTIME_VERSION)
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
