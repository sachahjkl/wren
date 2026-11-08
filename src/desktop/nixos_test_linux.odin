package desktop

// NixOS: the installed copy runs by itself (nixos_linux.odin). The last test builds the runtime with Nix and runs a
// patched copy: it runs on NixOS only.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
os_release_names_nixos :: proc(t: ^testing.T) {
	testing.expect(t, os_release_is_nixos("NAME=NixOS\nID=nixos\nVERSION_ID=\"26.05\"\n"))
	testing.expect(t, os_release_is_nixos("ID=\"nixos\"\n"))
	testing.expect(t, !os_release_is_nixos("NAME=\"Ubuntu\"\nID=ubuntu\nID_LIKE=debian\n"))
	testing.expect(t, !os_release_is_nixos("ID_LIKE=nixos\nID=other\n"))
	testing.expect(t, !os_release_is_nixos(""))
	testing.expect(t, in_nix_store("/nix/store/abc-wren-0.6.32/lib/wren/wren"))
	testing.expect(t, !in_nix_store("/home/u/.local/share/wren/wren"))
}

// A library that flake.nix gives the package and the installed copy lacks is a window that never opens on NixOS.
@(test)
nixos_libraries_follow_the_flake :: proc(t: ^testing.T) {
	data, err := os.read_entire_file(#directory + "/../../flake.nix", context.temp_allocator)
	if !testing.expect(t, err == nil, "flake.nix is readable") { return }
	text := string(data)
	start := strings.index(text, "runtimeLibs = with pkgs; [")
	if !testing.expect(t, start >= 0, "flake.nix has runtimeLibs") { return }
	body := text[start + len("runtimeLibs = with pkgs; ["):]
	body = body[:strings.index_byte(body, ']')]
	flake := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(body, context.temp_allocator) {
		name := strings.trim_space(line)
		if name != "" && name[0] != '#' { append(&flake, name) }
	}
	ours := NIXOS_LIBRARIES[2:]   // (glibc and libgcc_s: the package has them from stdenv)
	testing.expect_value(t, NIXOS_LIBRARIES[0], "glibc")
	testing.expect_value(t, NIXOS_LIBRARIES[1], "stdenv.cc.cc")
	testing.expectf(t, len(flake) == len(ours), "flake.nix runtimeLibs %v, NIXOS_LIBRARIES %v", flake[:], ours)
	for name in flake {
		found := false
		for o in ours { if o == name { found = true } }
		testing.expectf(t, found, "%s is in flake.nix runtimeLibs and not in NIXOS_LIBRARIES", name)
	}
}

// Day one on NixOS: the installed copy starts from the menu, without steam-run. A program of the system stands for Wren
// (its loader is moved to the runtime's like Wren's); it must run after the install and leave nothing after removal. The
// system's own: the runtime comes from the system's nixpkgs, so its glibc is the one this program was built with.
@(test)
nixos_installed_copy_runs_by_itself :: proc(t: ^testing.T) {
	if !is_nixos() { return }
	program := "/run/current-system/sw/bin/bash"   // (not coreutils: it picks its program by its name)
	if !testing.expect(t, os.is_file(program), "the system has bash") { return }
	tr := tree_make()
	defer tree_destroy(&tr)
	src := fmt.tprintf("%s/wren", tr.src)
	if !testing.expect(t, os.copy_file(src, program) == nil, "copy true") { return }
	tr.opts.identity.exe_name = "wren"
	plan := Install_Plan{src_exe = src, dir = tr.dst, exe_name = "wren", version = "0.3.0", channel = "release", adapt = true}
	r := files_install(plan)
	if !testing.expectf(t, r.error == .None, "%v: %s", r.error, r.detail) { return }

	exe := fmt.tprintf("%s/wren", tr.dst)
	runtime := fmt.tprintf("%s/%s", tr.dst, NIX_RUNTIME_NAME)
	state, _, said, err := os.process_exec(os.Process_Desc{command = {exe, "-c", "exit 0"}}, context.temp_allocator)
	testing.expectf(t, err == nil && state.success, "the patched copy runs: %v %s", err, said)
	_, interp, _, _ := os.process_exec(os.Process_Desc{command = {fmt.tprintf("%s/bin/patchelf", runtime), "--print-interpreter", exe}}, context.temp_allocator)
	testing.expect_value(t, strings.trim_space(string(interp)), fmt.tprintf("%s/lib/ld-linux-x86-64.so.2", runtime))
	// what the release links, and what it opens for a window (Wayland or X11, Vulkan or EGL)
	for so in ([]string{"libc.so.6", "libm.so.6", "libgcc_s.so.1", "libfontconfig.so.1", "libopus.so.0", "libasound.so.2",
		"libwayland-client.so.0", "libwayland-cursor.so.0", "libxkbcommon.so.0", "libxkbcommon-x11.so.0", "libxcb.so.1",
		"libxcb-cursor.so.0", "libvulkan.so.1", "libEGL.so.1"}) {
		testing.expectf(t, os.exists(fmt.tprintf("%s/lib/%s", runtime, so)), "the runtime has %s", so)
	}
	info := installed_info(&tr.opts, tr.dst, context.temp_allocator)
	testing.expect_value(t, info.missing, 0)
	testing.expect(t, strings.contains(read_text(fmt.tprintf("%s/%s", tr.dst, MANIFEST_NAME)), "file=" + NIX_RUNTIME_NAME + "\n"))

	rm := files_remove(&tr.opts, tr.dst)
	testing.expect_value(t, rm.result.error, Error.None)
	testing.expect(t, rm.folder, "the install folder is gone, the runtime's link with it")
}

@(private = "file")
read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : ""
}
