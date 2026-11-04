package deps

import "core:fmt"
import "core:os"
@(require) import "wb:base"   // (Windows)
import "wb:tools/tooling"

// Tracy (github.com/wolfpld/tracy), a pinned release, for the builds that ask for it (WREN_TRACY=1 wrentool build <variant>:
// package trace). Its client is one C++ file built as a static library: it records only while a viewer is connected
// (TRACY_ON_DEMAND), answers on this machine only (TRACY_ONLY_LOCALHOST), and leaves crashes to Wren's own handler. Its viewer
// is the release's Windows build.
//   wrentool build tracy    build/tracy/tracy.lib from the source release (nothing to do when the stamp matches)
//   wrentool fetch tracy    the viewer, the command-line capture and export: build/tracy/tracy-profiler.exe, tracy-capture.exe, tracy-csvexport.exe
// To move to another release: the version and the two digests (the source archive's, the Windows zip's: GitHub shows the
// latter on the release page), then Tracy_Location and Tracy_Ctx of src/trace/tracy.odin against public/tracy/TracyC.h.

TRACY_VERSION :: "0.14.1"
TRACY_SOURCE_SHA256 :: "bf4af567e9c7524d07f3caa745fad02fb33bd5694f11910750382d1efbb251c1"
TRACY_VIEWER_SHA256 :: "f7499d74914aa3ba94a2c1ce72f36477d7b61d9d0f7c9790e05274c258c97fb5"
TRACY_ARCHIVES :: "https://github.com/wolfpld/tracy/archive/refs/tags"
TRACY_RELEASES :: "https://github.com/wolfpld/tracy/releases/download"
TRACY_OUT :: "build/tracy"
TRACY_LIB :: "build/tracy/tracy.lib"
TRACY_THIS :: "src/tools/wrentool/deps/tracy.odin"
// what the client is compiled with (src/trace/tracy.odin's Tracy_Ctx has the connection id TRACY_ON_DEMAND adds)
TRACY_DEFINES :: [?]string{"TRACY_ENABLE", "TRACY_ON_DEMAND", "TRACY_ONLY_LOCALHOST", "TRACY_NO_CRASH_HANDLER"}
// the viewer's programs taken from the release
TRACY_PROGRAMS :: [?]string{"tracy-profiler.exe", "tracy-capture.exe", "tracy-csvexport.exe"}

when ODIN_OS == .Windows {

build_tracy :: proc(o: Options) -> bool {
	stamp_file := fmt.tprintf("%s/STAMP", TRACY_OUT)
	defines := TRACY_DEFINES
	stamp := stamp_of(fmt.tprintf("tracy %s %v", TRACY_VERSION, defines), {TRACY_THIS})
	if !o.force && os.exists(TRACY_LIB) && read_stamp(stamp_file) == stamp {
		tooling.say(o.log, fmt.tprintfln("tracy %s up to date in %s", TRACY_VERSION, TRACY_OUT))
		return true
	}
	archive := fmt.tprintf("%s/tracy-%s.tar.gz", TEMP_DIR, TRACY_VERSION)
	if !tooling.download_pinned(fmt.tprintf("%s/v%s.tar.gz", TRACY_ARCHIVES, TRACY_VERSION), archive, TRACY_SOURCE_SHA256, o.log) { return false }
	x := work_folder("tracy")
	defer base.remove_tree(x)
	if !unpack(o, archive, x) { return fail(o, "the Tracy archive cannot be unpacked") }
	source := fmt.tprintf("%s/tracy-%s", x, TRACY_VERSION)
	objects := fmt.tprintf("%s/obj", x)
	_ = os.make_directory_all(objects)
	_ = os.make_directory_all(TRACY_OUT)
	env := msvc_environment()
	// /Z7: its debug information goes into the program's PDB (the profilers and crash reports name its functions)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, msvc_tool(env, "cl.exe"), "/nologo", "/c", "/O2", "/MT", "/EHsc", "/std:c++17", "/Z7", "/W0", "/DNDEBUG")
	for d in defines { append(&cmd, fmt.tprintf("/D%s", d)) }
	append(&cmd, fmt.tprintf("/Fo%s/", objects), fmt.tprintf("%s/public/TracyClient.cpp", source))
	if tooling.run({command = cmd[:], env = env, log = o.log}) != 0 { return fail(o, "the Tracy client does not compile") }
	_ = os.remove(stamp_file)
	if tooling.run({command = {msvc_tool(env, "lib.exe"), "/nologo", fmt.tprintf("/OUT:%s", TRACY_LIB), fmt.tprintf("%s/TracyClient.obj", objects)}, env = env, log = o.log}) != 0 { return fail(o, "lib failed") }
	if os.copy_file(fmt.tprintf("%s/LICENSE", TRACY_OUT), fmt.tprintf("%s/LICENSE", source)) != nil { return fail(o, "the Tracy licence cannot be copied") }
	if !write_stamp(stamp_file, stamp) { return fail(o, "the stamp cannot be written") }
	tooling.say(o.log, fmt.tprintfln("built %s (Tracy %s)", TRACY_LIB, TRACY_VERSION))
	return true
}

fetch_tracy :: proc(o: Options) -> bool {
	stamp_file := fmt.tprintf("%s/VIEWER", TRACY_OUT)
	programs := TRACY_PROGRAMS
	if !o.force && os.exists(fmt.tprintf("%s/%s", TRACY_OUT, programs[0])) && read_stamp(stamp_file) == TRACY_VERSION {
		tooling.say(o.log, fmt.tprintfln("the Tracy %s viewer is already in %s", TRACY_VERSION, TRACY_OUT))
		return true
	}
	zip := fmt.tprintf("%s/tracy-windows-%s.zip", TEMP_DIR, TRACY_VERSION)
	if !tooling.download_pinned(fmt.tprintf("%s/v%s/windows-%s.zip", TRACY_RELEASES, TRACY_VERSION, TRACY_VERSION), zip, TRACY_VIEWER_SHA256, o.log) { return false }
	x := work_folder("tracy-viewer")
	defer base.remove_tree(x)
	if !unpack(o, zip, x) { return fail(o, "the Tracy viewer cannot be unpacked") }
	_ = os.make_directory_all(TRACY_OUT)
	for p in programs {
		if os.copy_file(fmt.tprintf("%s/%s", TRACY_OUT, p), fmt.tprintf("%s/%s", x, p)) != nil { return fail(o, fmt.tprintf("%s is not in the release", p)) }
	}
	tooling.say(o.log, fmt.tprintfln("the Tracy %s viewer is in %s (docs/performance.md, Profilers)", TRACY_VERSION, TRACY_OUT))
	return write_stamp(stamp_file, TRACY_VERSION)
}

} else {

build_tracy :: proc(o: Options) -> bool { return fail(o, "the Tracy client is built on Windows") }
fetch_tracy :: proc(o: Options) -> bool { return fail(o, "the Tracy viewer is fetched on Windows") }

}
