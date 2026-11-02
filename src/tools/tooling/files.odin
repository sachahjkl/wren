package tooling

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

EXE_SUFFIX :: ".exe" when ODIN_OS == .Windows else ""
// What programs that run Wasm are linked with: 32 MiB of thread stack (wasm.wasmtime.max_stack_bytes). On Linux, `ulimit -s` of test_all.
STACK_FLAGS :: []string{"-extra-linker-flags:/STACK:33554432"} when ODIN_OS == .Windows else []string{}
// The stack of a thread a tool makes to run JavaScript on (what the browser's workers get, workers.thread_stack_bytes): a tool that runs its scripts on such a thread works whatever linked it.
JS_THREAD_STACK_BYTES :: 32 << 20
// What makes every Wren a test starts keep its connections on this machine (src/net/settings.odin: network.loopback_only).
LOOPBACK_ONLY_ENV :: "WREN_NETWORK_LOOPBACK_ONLY"
SHA256_BYTES :: 32
NATIVE_LIBRARY :: "build/native/wren_native.lib" when ODIN_OS == .Windows else "build/native-linux/libwren_native.a"

// The repository of the program that runs: its executable is in <repository>/build; WREN_REPO says otherwise.
repo_root :: proc(allocator := context.allocator) -> string {
	if r, ok := os.lookup_env("WREN_REPO", context.temp_allocator); ok && r != "" { return strings.clone(r, allocator) }
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil { return strings.clone(".", allocator) }
	return strings.clone(filepath.dir(filepath.dir(exe)), allocator)
}

// `odin`, as a path: the real compiler rather than a shim in front of it (a shim is a process for each compile). `-Odin` of test_all, or WREN_ODIN, chooses another.
odin_override: string
odin_program :: proc() -> string {
	@(static) found: string
	if odin_override != "" { return odin_override }
	if found != "" { return found }
	found = "odin"
	if v, ok := os.lookup_env("WREN_ODIN", context.allocator); ok && v != "" { found = v; return found }
	text, code := capture({"odin", "root"})
	if code == 0 {
		candidate, _ := filepath.join({strings.trim_space(text), strings.concatenate({"odin", EXE_SUFFIX})})
		// (it must run: the flake's root on a Windows drive holds a copy with no execute bit)
		if os.is_file(candidate) { if _, runs := capture({candidate, "version"}, allocator = context.temp_allocator); runs == 0 { found = candidate } }
	}
	return found
}

sha256_of_file :: proc(path: string, allocator := context.allocator) -> (digest: string, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return "", false }
	return sha256_of(data, allocator), true
}

sha256_of :: proc(data: []u8, allocator := context.allocator) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	out: [SHA256_BYTES]u8
	sha2.final(&ctx, out[:])
	return string(hex.encode(out[:], allocator))
}

modified :: proc(path: string) -> (t: time.Time, ok: bool) {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil { return {}, false }
	return fi.modification_time, true
}

// Whether a file under `dir` (recursively), that `keep` lets through, is newer than `built`.
any_newer :: proc(dir: string, built: time.Time, keep: proc(path: string) -> bool) -> bool {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return false }
	for e in entries {
		if e.type == .Directory {
			if e.name == ".git" { continue }
			if any_newer(e.fullpath, built, keep) { return true }
			continue
		}
		if time.diff(built, e.modification_time) > 0 && keep(e.fullpath) { return true }
	}
	return false
}

// What a build of the browser or a tool does not read: the tests of packages, the documentation.
is_source_of_a_program :: proc(path: string) -> bool {
	p, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	return !strings.has_suffix(p, "_test.odin") && !strings.contains(p, "/tests/") && !strings.has_suffix(p, ".md")
}

// Odin compiles a whole program every time (no incremental build): a tool already built is not built again. Builds `output` with `command` unless it is newer than every
// source of src and ext/gui_toolkit (tests aside) and the engine's image, and was built with the same `flags` (written beside it, <output>.flags).
build_if_stale :: proc(output, flags: string, command: []string, log := "") -> bool {
	stamp := strings.concatenate({output, ".flags"}, context.temp_allocator)
	if built, ok := modified(output); ok {
		text, err := os.read_entire_file(stamp, context.temp_allocator)
		if err == nil && string(text) == flags {
			fresh := !any_newer("src", built, is_source_of_a_program) && !any_newer("ext/gui_toolkit", built, is_source_of_a_program)
			if image, has := modified("build/js/wren_js.wasm"); has && time.diff(built, image) > 0 { fresh = false }
			// (the Rust library a program links: the network stack's settings are in it)
			if native, has := modified(NATIVE_LIBRARY); has && time.diff(built, native) > 0 { fresh = false }
			if fresh { return true }
		}
	}
	if run({command = command, log = log}) != 0 { return false }
	return os.write_entire_file(stamp, flags) == nil
}

// A pinned download: `file` when it has the digest, fetched otherwise (curl comes with Windows and with every Linux of the CI). The digest is checked, always.
download_pinned :: proc(url, file, sha: string, log := "") -> bool {
	if got, ok := sha256_of_file(file, context.temp_allocator); ok && got == sha { return true }
	_ = os.make_directory_all(filepath.dir(file))
	say(log, fmt.tprintfln("downloading %s", url))
	if run({command = {"curl", "-fsSL", "-o", file, url}, log = log}) != 0 {
		say(log, fmt.tprintfln("the download of %s failed", url))
		return false
	}
	got, ok := sha256_of_file(file, context.temp_allocator)
	if !ok || got != sha {
		_ = os.remove(file)
		say(log, fmt.tprintfln("SHA-256 mismatch for %s: expected %s, got %s", url, sha, got))
		return false
	}
	return true
}

say :: proc(log, text: string) {
	if log != "" { append_text(log, text) } else { fmt.print(text) }
}

// The test server's two forms, built from tools/testserver when missing or older than one of its sources: build/testserver.exe, the thin main of what is not Odin, and
// build/testserver.dll, the library the Odin tests load. (A program that runs holds its file: the build then fails to replace it, and that one stays.)
TESTSERVER_EXE :: "build/testserver" + EXE_SUFFIX
TESTSERVER_LIBRARY :: "build/testserver.dll" when ODIN_OS == .Windows else "build/testserver.so"

ensure_testserver :: proc(log := "") -> bool {
	stale :: proc(output: string) -> bool {
		built, ok := modified(output)
		if !ok { return true }
		go_source :: proc(path: string) -> bool { return strings.has_suffix(path, ".go") || strings.has_suffix(path, "go.mod") || strings.has_suffix(path, "go.sum") }
		return any_newer("tools/testserver", built, go_source)
	}
	abs_of :: proc(path: string) -> string { full, _ := filepath.abs(path, context.temp_allocator); return full }
	good := true
	if stale(TESTSERVER_EXE) {
		if run({command = {"go", "build", "-o", abs_of(TESTSERVER_EXE), "./cmd/testserver"}, dir = "tools/testserver", log = log}) != 0 { good = false }
	}
	if stale(TESTSERVER_LIBRARY) {
		// (c-shared calls a C compiler; stripped, or the linker of an old MinGW makes a file Windows will not load)
		code := run({command = {"go", "build", "-buildmode=c-shared", "-ldflags=-s -w", "-o", abs_of(TESTSERVER_LIBRARY), "./cdll"}, dir = "tools/testserver", env = {"CGO_ENABLED=1"}, log = log})
		_ = os.remove(strings.concatenate({strings.trim_suffix(TESTSERVER_LIBRARY, filepath.ext(TESTSERVER_LIBRARY)), ".h"}, context.temp_allocator))
		if code != 0 { good = false }
	}
	return good
}
