package deps

import "core:fmt"
import "core:os"
@(require) import "core:strings"   // (these two: Windows)
@(require) import "wb:base"
import "wb:tools/tooling"

// Wren's Rust code (the native/ workspace) as the one Rust static library linked into the program: the image decoders and WOFF2 (native/media), the network stack (native/net), the toolkit's
// text backend and accessibility adapter, picked by the assembly crate native/wren_native. -Profile: Cargo's (native/Cargo.toml): `release` is fat LTO, what is shipped; `quick` has no LTO, so that a
// change in one crate rebuilds that crate only. Pinned: every crate in native/Cargo.lock (--locked), NASM (rav1d's assembly kernels) below, fetched once into build/tools.

NATIVE_THIS :: "src/tools/wrentool/deps/native.odin"
// the static C runtime on Windows (crt-static), for the Rust code and the C it compiles
CARGO_CONFIG :: ".cargo/config.toml"
NASM_VERSION :: "2.16.03"
NASM_SHA256 :: "3ee4782247bcb874378d02f7eab4e294a84d3d15f3f6ee2de2f47a46aa7226e6"
NASM_RELEASES :: "https://www.nasm.us/pub/nasm/releasebuilds"
TOOLS_DIR :: "build/tools"
BYTES_PER_MB :: 1024 * 1024

when ODIN_OS == .Windows {

// WREN_TEXT=dwrite: a build that shapes with DirectWrite, without the text backend.
build_native :: proc(o: Options) -> bool {
	out := "build/native"
	lib := fmt.tprintf("%s/wren_native.lib", out)
	stamp_file := fmt.tprintf("%s/STAMP", out)
	text_env, _ := os.lookup_env("WREN_TEXT", context.temp_allocator)
	text := text_env != "dwrite"
	features := text ? "text,a11y" : "a11y"

	// what the library is made of: change any of it and it is built again
	crates := make([dynamic]string, context.temp_allocator)
	append(&crates, "native/crypto", "native/media", "native/net", "native/webgl", "native/wren_native", "ext/gui_toolkit/native/a11y")
	if text { append(&crates, "ext/gui_toolkit/native/text") }
	inputs := make([dynamic]string, context.temp_allocator)
	for c in crates { files_under(fmt.tprintf("%s/src", c), &inputs) }
	for c in crates { append(&inputs, fmt.tprintf("%s/Cargo.toml", c)) }
	append(&inputs, "native/Cargo.toml", "native/Cargo.lock", CARGO_CONFIG, NATIVE_THIS)
	stamp := stamp_of(fmt.tprintf("profile=%s features=%s\n", o.profile, features), inputs[:])
	if !o.force && os.exists(lib) && read_stamp(stamp_file) == stamp {
		tooling.say(o.log, fmt.tprintfln("wren_native (%s) up to date in %s", o.profile, out))
		return true
	}

	nasm_dir := fmt.tprintf("%s/nasm-%s", TOOLS_DIR, NASM_VERSION)
	nasm := fmt.tprintf("%s/nasm.exe", nasm_dir)
	if !os.exists(nasm) {
		zip := fmt.tprintf("%s/nasm-%s-win64.zip", TOOLS_DIR, NASM_VERSION)
		url := fmt.tprintf("%s/%s/win64/nasm-%s-win64.zip", NASM_RELEASES, NASM_VERSION, NASM_VERSION)
		if !tooling.download_pinned(url, zip, NASM_SHA256, o.log) { return false }
		if !unpack(o, zip, TOOLS_DIR) || !os.exists(nasm) { return fail(o, fmt.tprintf("nasm.exe is not in %s", nasm_dir)) }
	}
	path, _ := os.lookup_env("PATH", context.temp_allocator)
	env := make([dynamic]string, context.temp_allocator)
	append(&env, ..msvc_environment())
	for e, i in env { if strings.has_prefix(strings.to_upper(e, context.temp_allocator), "PATH=") { path = e[len("PATH="):]; unordered_remove(&env, i); break } }
	append(&env, fmt.tprintf("PATH=%s;%s", full_path(nasm_dir), path), fmt.tprintf("NASM=%s", full_path(nasm)))

	target := fmt.tprintf("%s/target", out)
	cargo := []string{"cargo", "build", "--profile", o.profile, "--locked", "--manifest-path", "native/Cargo.toml", "--target-dir", target, "-p", "wren_native", "--features", features}
	if tooling.run({command = cargo, env = env[:], log = o.log}) != 0 { return fail(o, "cargo build failed") }
	_ = os.make_directory_all(out)
	_ = os.remove(stamp_file)   // (a library half replaced is never taken for a built one)
	if os.copy_file(lib, fmt.tprintf("%s/%s/wren_native.lib", target, o.profile)) != nil { return fail(o, "the library cannot be copied") }
	if !rename_personality(o, lib, out) { return false }
	if !write_stamp(stamp_file, stamp) { return fail(o, "the stamp cannot be written") }
	fi, _ := os.stat(lib, context.temp_allocator)
	tooling.say(o.log, fmt.tprintfln("built %s (%s, %d MB)", lib, o.profile, fi.size / BYTES_PER_MB))
	return true
}

// Wasmtime's library carries its own Rust standard library (another compiler's: its mangled symbols differ), and both define the unmangled rust_eh_personality (a no-op on MSVC, where unwinding
// goes through __CxxFrameHandler3). Ours is renamed in the object that defines it so that the two link together: the only symbol renamed, this workspace's libraries share one standard library.
@(private)
rename_personality :: proc(o: Options, lib, out: string) -> bool {
	sysroot, code := tooling.capture({"rustc", "--print", "sysroot"}, allocator = context.temp_allocator)
	if code != 0 { return fail(o, "rustc --print sysroot failed") }
	bin := fmt.tprintf("%s/lib/rustlib/x86_64-pc-windows-msvc/bin", strings.trim_space(sysroot))
	objcopy := fmt.tprintf("%s/llvm-objcopy.exe", bin)
	if !os.exists(objcopy) && tooling.run({command = {"rustup", "component", "add", "llvm-tools"}, log = o.log}) != 0 { return fail(o, "rustup component add llvm-tools failed") }
	listing, nm := tooling.capture({fmt.tprintf("%s/llvm-nm.exe", bin), "--defined-only", "--print-file-name", lib}, allocator = context.temp_allocator)
	if nm != 0 { return fail(o, "llvm-nm failed") }
	member, found := "", 0
	for line in strings.split_lines(listing, context.temp_allocator) {
		if !strings.has_suffix(strings.trim_right_space(line), " T rust_eh_personality") { continue }
		// <lib>:<member>.o: <address> T rust_eh_personality
		start := strings.index(line, ".lib:")
		stop := strings.last_index(line, ".o:")
		if start < 0 || stop < start { continue }
		member = line[start + len(".lib:"):stop + len(".o")]
		found += 1
	}
	if found != 1 { return fail(o, fmt.tprintf("wren_native.lib: expected one object defining rust_eh_personality, found %d", found)) }
	work := fmt.tprintf("%s/rename", out)
	base.remove_tree(work)
	_ = os.make_directory_all(work)
	defer base.remove_tree(work)
	ar := fmt.tprintf("%s/llvm-ar.exe", bin)
	whole := full_path(lib)
	if tooling.run({command = {ar, "x", whole, member}, dir = work, log = o.log}) != 0 { return fail(o, "llvm-ar x failed") }
	if tooling.run({command = {objcopy, "--redefine-sym=rust_eh_personality=wren_native_rust_eh_personality", member}, dir = work, log = o.log}) != 0 { return fail(o, "llvm-objcopy failed") }
	if tooling.run({command = {ar, "r", whole, member}, dir = work, log = o.log}) != 0 { return fail(o, "llvm-ar r failed") }
	return true
}

VSWHERE :: "Microsoft Visual Studio/Installer/vswhere.exe"

// What vcvars64.bat sets, for a program that needs MSVC's tools (nothing when they are set: a developer prompt, the CI).
msvc_environment :: proc() -> []string {
	if found, _ := os.lookup_env("VCINSTALLDIR", context.temp_allocator); found != "" { return nil }
	programs, _ := os.lookup_env("ProgramFiles(x86)", context.temp_allocator)
	vs, code := tooling.capture({fmt.tprintf("%s/%s", programs, VSWHERE), "-latest", "-products", "*", "-property", "installationPath"}, allocator = context.temp_allocator)
	if code != 0 { return nil }
	// (through a file: cmd reads quotes its own way)
	_ = os.make_directory_all(TEMP_DIR)
	bat := fmt.tprintf("%s/vcvars_%d.bat", TEMP_DIR, os.get_pid())
	defer os.remove(bat)
	_ = os.write_entire_file(bat, fmt.tprintf("@call \"%s\\VC\\Auxiliary\\Build\\vcvars64.bat\" >nul\r\n@set\r\n", strings.trim_space(vs)))
	text, ok := tooling.capture({"cmd", "/c", full_path(bat)}, allocator = context.temp_allocator)
	if ok != 0 { return nil }
	env := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		l := strings.trim_right(line, "\r")
		if strings.index_byte(l, '=') > 0 { append(&env, l) }
	}
	return env[:]
}

// A tool of MSVC: on that environment's PATH (a program is looked for on this process's, which does not have it).
msvc_tool :: proc(env: []string, name: string) -> string {
	for e in env {
		if !strings.has_prefix(strings.to_upper(e, context.temp_allocator), "PATH=") { continue }
		for dir in strings.split(e[len("PATH="):], ";", context.temp_allocator) {
			candidate := fmt.tprintf("%s/%s", dir, name)
			if os.exists(candidate) { return candidate }
		}
	}
	return name
}

} else {

build_native :: proc(o: Options) -> bool {
	profile := o.profile
	out := "build/native-linux"
	target, _ := os.lookup_env("CARGO_TARGET_DIR", context.temp_allocator)
	if target == "" { target = fmt.tprintf("%s/target", out) }
	_ = os.make_directory_all(out)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "cargo", "build", "--profile", profile, "--locked", "--manifest-path", "native/Cargo.toml", "--target-dir", target, "-p", "wren_native")
	if o.features != "" { append(&cmd, "--features", o.features) }
	if tooling.run({command = cmd[:], log = o.log}) != 0 { return fail(o, "cargo build failed") }
	lib := fmt.tprintf("%s/libwren_native.a", out)
	if os.copy_file(lib, fmt.tprintf("%s/%s/libwren_native.a", target, profile)) != nil { return fail(o, "the library cannot be copied") }
	tooling.say(o.log, fmt.tprintfln("built %s (%s%s%s)", lib, profile, o.features != "" ? ", " : "", o.features))
	return true
}

msvc_environment :: proc() -> []string { return nil }

}
