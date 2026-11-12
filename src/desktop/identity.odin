// Package wren_desktop: what Wren is to the toolkit's desktop package (toolkit:desktop, ext/gui_toolkit/docs/desktop.md),
// which adds, checks and removes the integration and the installed copy. Wren keeps here its names and marks (identity),
// the links that open in it (links.odin) and its preferences (settings.odin). The marks are what an installed Wren already
// carries on users' machines: changing one leaves those files and keys behind, unrecognised.
package wren_desktop

import tk "../../ext/gui_toolkit/src/desktop"

ENTRY_MARKER    :: "X-Wren-Integration"
REGISTRY_MARK   :: "WrenIntegration"
VENDOR_KEY      :: "FromentSoftware"
MANIFEST_NAME   :: "wren_install.txt"
MANIFEST_HEADER :: "# Written by Wren Setup: the files it placed in this folder. Uninstalling removes exactly these."
// Said by every message of the console launcher (src/tools/wrencom/plan.odin, MARK), so that a file of the same name made
// by something else is told from it. Keep the two equal.
LAUNCHER_MARK   :: "(Wren console launcher)"
CLI_FLAG        :: "--desktop-integration"
// The roots of the tests and of a dry run: WREN_DESKTOP_MENU_DIR, WREN_DESKTOP_BIN_DIR... (tk.ROOT_NAMES).
ENV_PREFIX      :: "WREN_DESKTOP_"
// The development build's prefix of links (the release's is LINK_PREFIX, links.odin).
DEV_LINK_PREFIX :: "wren-dev-"

// What the program needs from the system on NixOS, by nixpkgs attribute: what it links (glibc, libgcc_s, fontconfig, opus,
// ALSA) and what it opens with dlopen (Wayland, X11, Vulkan, EGL, libfido2 for security keys). The same list as `runtimeLibs` in flake.nix, which the
// test nixos_libraries_follow_the_flake keeps in step.
NIXOS_LIBRARIES := [?]string{
	"glibc", "stdenv.cc.cc", "alsa-lib", "fontconfig", "freetype", "libopus", "libxkbcommon", "vulkan-loader",
	"wayland", "libxcb", "libxcb-cursor", "libglvnd", "libfido2",
}

// The URL schemes each channel registers: its prefix before each of LINK_SCHEMES (links.odin).
RELEASE_SCHEMES := [?]string{LINK_PREFIX + "http", LINK_PREFIX + "https", LINK_PREFIX + "about"}
DEV_SCHEMES     := [?]string{DEV_LINK_PREFIX + "http", DEV_LINK_PREFIX + "https", DEV_LINK_PREFIX + "about"}

// The registry keys a test may delete: the desktop tests' and Setup's.
SCRATCH_ROOTS := [?]string{`Software\WrenTest_`, `Software\WrenSetupTest\`}

// What a launcher's right click on Wren offers (the desktop entry's actions, Linux): a new window of the Wren that runs, or
// a private one (private_browsing.odin).
DESKTOP_ACTIONS := [?]tk.Desktop_Action{
	{id = "new-window", name = "New Window", arguments = "--new-window"},
	{id = "new-private-window", name = "New Private Window", arguments = "--private"},
}

// What Wren is called on the desktop (`app_name` is a constant: the identity's strings are the program's, shared by every copy
// of the options). A development build has its own entries (name, keys, AppUserModelID, link schemes),
// so it never takes over those of the release.
identity :: proc($app_name: string, description: string, dev: bool) -> tk.Identity {
	id := tk.Identity{
		name = app_name, key = app_name, slug = "wren", aumid = "FromentSoftware.Wren", description = description,
		vendor = "Froment Software", exe_name = "wren.exe",
		entry_marker = ENTRY_MARKER, registry_mark = REGISTRY_MARK, vendor_key = VENDOR_KEY,
		manifest_name = MANIFEST_NAME, manifest_header = MANIFEST_HEADER, launcher_mark = LAUNCHER_MARK,
		cli_flag = CLI_FLAG, env_prefix = ENV_PREFIX, url_schemes = RELEASE_SCHEMES[:], url_flag = LINK_FLAG,
		uninstall_arguments = "--setup",   // (the Setup dialog, whose Uninstall button does the work)
		generic_name = "Web Browser", categories = "Network;WebBrowser;", keywords = "Internet;WWW;Browser;Web;WebAssembly;",
		nix_runtime_name = "wren-runtime", nixos_libraries = NIXOS_LIBRARIES[:],
		watch_thread_name = "wren-desktop-watch", cleanup_name = "wren_cleanup", scratch_roots = SCRATCH_ROOTS[:],
		actions = DESKTOP_ACTIONS[:],
	}
	if dev {
		id.name = app_name + " Dev"
		id.key = app_name + "Dev"
		id.slug = "wren-dev"
		id.aumid = "FromentSoftware.Wren.Dev"
		id.url_schemes = DEV_SCHEMES[:]
	}
	return id
}

// The prefix of the links a channel opens (links_in_args takes both: a development build opens the release's links too).
link_prefix :: proc(dev: bool) -> string { return dev ? DEV_LINK_PREFIX : LINK_PREFIX }
