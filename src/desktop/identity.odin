// Package wren_desktop: what Wren is to the toolkit's desktop package (toolkit:desktop, ext/gui_toolkit/docs/desktop.md),
// which adds, checks and removes the integration and the installed copy. Wren keeps here its names and marks (identity),
// the links that open in it (links.odin) and its preferences (settings.odin). The marks are what an installed Wren already
// carries on users' machines: changing one leaves those files and keys behind, unrecognised.
package wren_desktop

import "core:strings"
import tk "toolkit:desktop"

VENDOR          :: "Froment Software"
// tk.identity_of derives the same key from VENDOR (identity_of_each_channel checks it): the profile's folder
// (src/browser/profile_folder.odin, APP_FOLDER) is a constant, so it cannot read the identity's.
VENDOR_KEY      :: "FromentSoftware"
MANIFEST_HEADER :: "# Written by Wren Setup: the files it placed in this folder. Uninstalling removes exactly these."
// Said by every message of the console launcher (src/tools/wrencom/plan.odin, MARK), so that a file of the same name made
// by something else is told from it. Keep the two equal.
LAUNCHER_MARK   :: "(Wren console launcher)"
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

// What Wren is called on the desktop. The strings are allocated in `allocator`, for as long as the identity is used (the
// options' copies share them): the program makes it once and keeps it (src/browser/desktop_shell.odin, desktop_identity).
// A development build has its own entries (name, keys, AppUserModelID, link schemes), so it never takes over those of the
// release; its marks (X-Wren-Integration, WrenIntegration, wren_install.txt, WREN_DESKTOP_) are the release's, as installed
// copies already carry them.
identity :: proc(app_name: string, description: string, dev: bool, allocator := context.allocator) -> tk.Identity {
	id := tk.identity_of(VENDOR, app_name, "wren", allocator)
	id.aumid = "FromentSoftware.Wren"
	id.exe_name = "wren.exe"
	id.description = description
	id.manifest_header = MANIFEST_HEADER
	id.launcher_mark = LAUNCHER_MARK
	id.url_schemes = RELEASE_SCHEMES[:]
	id.url_flag = LINK_FLAG
	id.uninstall_arguments = "--setup"   // (the Setup dialog, whose Uninstall button does the work)
	id.generic_name = "Web Browser"
	id.categories = "Network;WebBrowser;"
	id.keywords = "Internet;WWW;Browser;Web;WebAssembly;"
	id.nix_runtime_name = "wren-runtime"
	id.nixos_libraries = NIXOS_LIBRARIES[:]
	id.watch_thread_name = "wren-desktop-watch"
	id.cleanup_name = "wren_cleanup"
	id.scratch_roots = SCRATCH_ROOTS[:]
	id.actions = DESKTOP_ACTIONS[:]
	if dev {
		id.name = strings.concatenate({app_name, " Dev"}, allocator)
		id.key = strings.concatenate({id.key, "Dev"}, allocator)
		id.slug = "wren-dev"
		id.aumid = "FromentSoftware.Wren.Dev"
		id.url_schemes = DEV_SCHEMES[:]
	}
	return id
}

// The prefix of the links a channel opens (links_in_args takes both: a development build opens the release's links too).
link_prefix :: proc(dev: bool) -> string { return dev ? DEV_LINK_PREFIX : LINK_PREFIX }
