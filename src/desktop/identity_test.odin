package wren_desktop

// Wren's identity in the toolkit's desktop package: the .desktop text and the marks an installed Wren carries, and
// NixOS's libraries against flake.nix.

import "core:os"
import "core:strings"
import "core:testing"
import tk "../../ext/gui_toolkit/src/desktop"

// The entry an installed Wren has on users' machines: the same text, so that it is still recognised and removed.
@(test)
desktop_entry_is_wrens :: proc(t: ^testing.T) {
	o := tk.Options{identity = identity("Wren", "A small browser where WebAssembly runs everything.", dev = false), exe = "/home/u/bin/wren", register_browser = true, file_types = {".html", ".htm", "svg", ".webp"}}
	want := `[Desktop Entry]
Type=Application
Version=1.0
Name=Wren
GenericName=Web Browser
Comment=A small browser where WebAssembly runs everything.
Exec=/home/u/bin/wren %U
TryExec=/home/u/bin/wren
Icon=wren
Terminal=false
StartupNotify=true
Categories=Network;WebBrowser;
Keywords=Internet;WWW;Browser;Web;WebAssembly;
MimeType=x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/wren-http;x-scheme-handler/wren-https;x-scheme-handler/wren-about;text/html;image/svg+xml;image/webp;
X-Wren-Integration=wren
`
	testing.expect_value(t, tk.desktop_entry_text(&o), want)
	o.register_browser = false
	text := tk.desktop_entry_text(&o)
	testing.expect(t, !strings.contains(text, "MimeType") && strings.contains(text, "Exec=/home/u/bin/wren %U\n"), text)
}

@(test)
identity_of_each_channel :: proc(t: ^testing.T) {
	release := identity("Wren", "", dev = false)
	dev := identity("Wren", "", dev = true)
	testing.expect_value(t, release.name, "Wren")
	testing.expect_value(t, release.aumid, "FromentSoftware.Wren")
	testing.expect_value(t, strings.join(release.url_schemes, " ", context.temp_allocator), strings.join(link_scheme_names(LINK_PREFIX), " ", context.temp_allocator))
	testing.expect_value(t, dev.name, "Wren Dev")
	testing.expect_value(t, dev.key, "WrenDev")
	testing.expect_value(t, dev.slug, "wren-dev")
	testing.expect_value(t, strings.join(dev.url_schemes, " ", context.temp_allocator), strings.join(link_scheme_names(DEV_LINK_PREFIX), " ", context.temp_allocator))
	// both pass the toolkit's checks: install goes as far as the executable, which does not exist (nothing is written)
	for id in ([]tk.Identity{release, dev}) {
		o := tk.Options{identity = id, exe = "/no/such/wren"}
		testing.expectf(t, tk.install(&o).error == .No_Executable, "%s is a valid identity", id.name)
	}
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
