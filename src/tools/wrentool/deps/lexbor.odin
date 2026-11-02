package deps

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "wb:tools/tooling"

// Lexbor (ext/lexbor, a pinned release) and our shims (src/shim/*.c) as one static library: the HTML5 tree builder, the CSS parser, selectors. No CMake. Nothing happens when the
// stamp matches the Lexbor commit, the shims and this file.

LEXBOR_SOURCE :: "ext/lexbor/source"
LEXBOR_SHIMS :: "src/shim"
LEXBOR_THIS :: "src/tools/wrentool/deps/lexbor.odin"
// Compilers at once on Linux (MSVC's /MP chooses for itself).
LEXBOR_JOBS :: 16

when ODIN_OS == .Windows {
	@(private) LEXBOR_OUT :: "build/lexbor"
	@(private) LEXBOR_LIB :: "build/lexbor/lexbor.lib"
	@(private) LEXBOR_OTHER_PORT :: "ports/posix"
} else {
	@(private) LEXBOR_OUT :: "build/lexbor-linux"
	@(private) LEXBOR_LIB :: "build/lexbor-linux/liblexbor.a"
	@(private) LEXBOR_OTHER_PORT :: "ports/windows_nt"
}

// The C sources under `dir`, those of the other system's port left out.
@(private)
c_sources :: proc(dir: string) -> []string {
	all := make([dynamic]string, context.temp_allocator)
	files_under(dir, &all)
	kept := make([dynamic]string, context.temp_allocator)
	for f in all {
		p, _ := strings.replace_all(f, "\\", "/", context.temp_allocator)
		if strings.has_suffix(p, ".c") && !strings.contains(p, LEXBOR_OTHER_PORT) { append(&kept, p) }
	}
	return kept[:]
}

build_lexbor :: proc(o: Options) -> bool {
	if !os.exists(fmt.tprintf("%s/lexbor", LEXBOR_SOURCE)) { return fail(o, "ext/lexbor is empty: run  git submodule update --init") }
	stamp_file := fmt.tprintf("%s/STAMP", LEXBOR_OUT)
	commit_text, code := tooling.capture({"git", "-C", "ext/lexbor", "rev-parse", "HEAD"}, allocator = context.temp_allocator)
	commit := code == 0 ? strings.trim_space(commit_text) : ""   // (without git, a source archive: always rebuilt)
	files := make([dynamic]string, context.temp_allocator)
	files_under(LEXBOR_SHIMS, &files)
	append(&files, LEXBOR_THIS)
	stamp := stamp_of(commit, files[:])
	if !o.force && commit != "" && os.exists(LEXBOR_LIB) && read_stamp(stamp_file) == stamp {
		tooling.say(o.log, fmt.tprintfln("lexbor up to date in %s", LEXBOR_OUT))
		return true
	}
	objects := fmt.tprintf("%s/obj", LEXBOR_OUT)
	_ = os.remove_all(objects)
	_ = os.make_directory_all(objects)
	if !lexbor_compile(o, objects) { return false }
	if !write_stamp(stamp_file, stamp) { return fail(o, "the stamp cannot be written") }
	tooling.say(o.log, fmt.tprintfln("built %s", LEXBOR_LIB))
	return true
}

when ODIN_OS == .Windows {

@(private)
lexbor_compile :: proc(o: Options, objects: string) -> bool {
	env := msvc_environment()
	log := fmt.tprintf("%s/build.log", LEXBOR_OUT)
	_ = os.remove(log)
	flags := []string{"/nologo", "/c", "/MP", "/O2", "/DNDEBUG", "/MD", "/W1", "/wd4100", "/wd4255", "/wd4820", "/wd4668",
		"/D_CRT_SECURE_NO_WARNINGS", "/DLEXBOR_STATIC", fmt.tprintf("/I%s", LEXBOR_SOURCE), fmt.tprintf("/I%s/lexbor/ports/windows_nt", LEXBOR_SOURCE)}
	// same file names exist in several folders (state.c, res.c...): one object folder per source folder
	groups := make(map[string][dynamic]string, context.temp_allocator)
	for f in c_sources(fmt.tprintf("%s/lexbor", LEXBOR_SOURCE)) {
		dir := filepath.dir(f)
		g := groups[dir]
		append(&g, f)
		groups[dir] = g
	}
	shims := make([dynamic]string, context.temp_allocator)
	for f in c_sources(LEXBOR_SHIMS) { append(&shims, f) }
	groups["shim"] = shims
	i := 0
	for _, list in groups {
		dir := fmt.tprintf("%s/d%d", objects, i)
		i += 1
		_ = os.make_directory_all(dir)
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, "cl")
		append(&cmd, ..flags)
		append(&cmd, fmt.tprintf("/Fo%s/", dir))
		append(&cmd, ..list[:])
		if tooling.run({command = cmd[:], env = env, log = log}) != 0 { return fail(o, fmt.tprintf("the compile failed: read %s", log)) }
	}
	all := make([dynamic]string, context.temp_allocator)
	files_under(objects, &all)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "lib", "/nologo", fmt.tprintf("/OUT:%s", LEXBOR_LIB))
	append(&cmd, ..all[:])
	if tooling.run({command = cmd[:], env = env, log = log}) != 0 { return fail(o, fmt.tprintf("lib failed: read %s", log)) }
	return true
}

} else {

@(private)
lexbor_compile :: proc(o: Options, objects: string) -> bool {
	cc, _ := os.lookup_env("CC", context.temp_allocator)
	if cc == "" { cc = "cc" }
	flags := []string{"-c", "-O2", "-DNDEBUG", "-fPIC", "-w", "-DLEXBOR_STATIC", fmt.tprintf("-I%s", LEXBOR_SOURCE), fmt.tprintf("-I%s/lexbor/ports/posix", LEXBOR_SOURCE)}
	sources := make([dynamic]string, context.temp_allocator)
	append(&sources, ..c_sources(fmt.tprintf("%s/lexbor", LEXBOR_SOURCE)))
	append(&sources, ..c_sources(LEXBOR_SHIMS))
	running := make([dynamic]tooling.Process, context.temp_allocator)
	good := true
	join :: proc(running: ^[dynamic]tooling.Process) -> bool {
		good := true
		for &p in running { c, _ := tooling.wait(&p); tooling.release(&p); if c != 0 { good = false } }
		clear(running)
		return good
	}
	object_list := make([dynamic]string, context.temp_allocator)
	for f in sources {
		// (same file names in several folders: an object is named after its path)
		named, _ := strings.replace_all(f, "/", "_", context.temp_allocator)
		obj := fmt.tprintf("%s/%s.o", objects, named)
		append(&object_list, obj)
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, cc)
		append(&cmd, ..flags)
		append(&cmd, f, "-o", obj)
		p, why := tooling.spawn({command = cmd[:], log = o.log})
		if why != "" { return fail(o, fmt.tprintf("%s cannot start: %s", cc, why)) }
		append(&running, p)
		if len(running) >= LEXBOR_JOBS { good = join(&running) && good }
	}
	good = join(&running) && good
	if !good { return fail(o, "the compile failed") }
	_ = os.remove(LEXBOR_LIB)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "ar", "rcs", LEXBOR_LIB)
	append(&cmd, ..object_list[:])
	return tooling.run({command = cmd[:], log = o.log}) == 0
}

}
