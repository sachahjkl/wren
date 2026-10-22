package desktop

// Linux: the freedesktop.org way (XDG), all under the user's data directory.
//
//   $XDG_DATA_HOME/applications/<slug>.desktop       the desktop entry (desktop_entry.odin): name, Exec, Icon, the
//                                                    categories of a web browser and MimeType= for http, https and the
//                                                    configured file types, so that "open with" and the default
//                                                    browser setting of the desktop list the program
//   $XDG_DATA_HOME/icons/hicolor/<n>x<n>/apps/<slug>.png   the icons, one per size the program embeds
//
// $XDG_DATA_HOME defaults to ~/.local/share (and must be an absolute path, as the specification says). After a change
// `update-desktop-database <applications>` rebuilds the MIME cache when that tool is installed.
//
// The mark of the program in a desktop entry is its X-Wren-Integration line (or an Exec that runs the executable).

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"

@(private = "file")
LINUX_BACKEND := Backend{
	name = "linux",
	targets = "application menu, default browser",
	parts = {.Launcher, .Icons},
	status = linux_status,
	install = linux_install,
	remove = linux_remove,
	open_defaults = nil,   // each desktop has its own settings program; there is no portable address for it
}

@(private)
platform_backend :: proc() -> ^Backend { return &LINUX_BACKEND }

// The window class and application id belong to the toolkit's window on this platform.
set_process_identity :: proc(id: Identity) {}

// Sizes the theme directories are named after: what is looked for, to remove icons of an older set.
@(private = "file")
ICON_SIZES := [?]int{16, 22, 24, 32, 48, 64, 96, 128, 256, 512}

@(private = "file")
Layout :: struct {
	applications: string,
	icons:        string,   // the hicolor directory
	entry:        string,   // the .desktop file
}

@(private = "file")
layout_of :: proc(o: ^Options) -> (l: Layout, ok: bool) {
	data_home := ""
	if o.applications_dir == "" || o.icons_dir == "" {
		data_home = xdg_data_home()
		if data_home == "" { return {}, false }
	}
	l.applications = o.applications_dir != "" ? o.applications_dir : strings.concatenate({data_home, "/applications"}, context.temp_allocator)
	l.icons = o.icons_dir != "" ? o.icons_dir : strings.concatenate({data_home, "/icons/hicolor"}, context.temp_allocator)
	l.entry = strings.concatenate({l.applications, "/", o.identity.slug, ".desktop"}, context.temp_allocator)
	return l, true
}

@(private = "file")
xdg_data_home :: proc() -> string {
	if v, ok := os.lookup_env("XDG_DATA_HOME", context.temp_allocator); ok && filepath.is_abs(v) { return v }
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil || home == "" { return "" }
	return strings.concatenate({home, "/.local/share"}, context.temp_allocator)
}

@(private = "file")
icon_path :: proc(l: Layout, slug: string, size: int) -> string {
	return strings.concatenate({l.icons, "/", itoa(size), "x", itoa(size), "/apps/", slug, ".png"}, context.temp_allocator)
}

@(private = "file")
itoa :: proc(n: int) -> string {
	buf: [20]u8
	i := len(buf)
	v := n
	if v == 0 { return "0" }
	for v > 0 { i -= 1; buf[i] = u8('0' + v % 10); v /= 10 }
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

////////////////////////////////
// Status

@(private = "file")
linux_status :: proc(o: ^Options, allocator: runtime.Allocator) -> Status {
	s: Status
	l, ok := layout_of(o)
	if !ok { s.error = .System; return s }

	if text, err := os.read_entire_file(l.entry, context.temp_allocator); err == nil {
		content := string(text)
		mark, _ := entry_value(content, ENTRY_MARKER)
		exec, _ := entry_value(content, "Exec")
		target := exec_program(exec)
		if mark == o.identity.slug || same_path(target, o.exe) {
			ps := &s.parts[.Launcher]
			ps.present = true
			ps.target = clone_or_empty(target, allocator)
			ps.stale = !same_path(target, o.exe)
			if o.register_browser {
				mime, _ := entry_value(content, "MimeType")
				ps.partial = !strings.contains(mime, "x-scheme-handler/https")
			}
		}
	}

	have := 0
	for ic in o.icons { if os.is_file(icon_path(l, o.identity.slug, ic.size)) { have += 1 } }
	if have > 0 {
		s.parts[.Icons].present = true
		s.parts[.Icons].partial = have < len(o.icons)
	} else if len(o.icons) == 0 {
		for size in ICON_SIZES { if os.is_file(icon_path(l, o.identity.slug, size)) { s.parts[.Icons].present = true; break } }
	}
	return s
}

////////////////////////////////
// Install

@(private = "file")
linux_install :: proc(o: ^Options) -> Result {
	l, ok := layout_of(o)
	if !ok { return {.System, "neither $XDG_DATA_HOME nor the home directory is known"} }
	if !ensure_dir(l.applications) { return {.Io, strings.concatenate({"cannot create ", l.applications}, context.temp_allocator)} }

	for ic in o.icons {
		path := icon_path(l, o.identity.slug, ic.size)
		if !ensure_dir(filepath.dir(path)) { return {.Io, strings.concatenate({"cannot create the directory of ", path}, context.temp_allocator)} }
		if r := write_atomic(path, ic.png); r.error != .None { return r }
	}
	if r := write_atomic(l.entry, transmute([]byte)desktop_entry_text(o)); r.error != .None { return r }

	// (the icon theme's cache is checked against the directories' times: there is nothing to run for the icons)
	if o.notify_system { run_tool("update-desktop-database", {l.applications}) }
	return {}
}

// A file is written beside its place and renamed over it, so a reader never sees half of it.
@(private = "file")
write_atomic :: proc(path: string, data: []byte) -> Result {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, data); err != nil { return {.Io, strings.concatenate({"cannot write ", tmp}, context.temp_allocator)} }
	if err := os.rename(tmp, path); err != nil {
		_ = os.remove(tmp)
		return {.Io, strings.concatenate({"cannot rename onto ", path}, context.temp_allocator)}
	}
	return {}
}

////////////////////////////////
// Remove

@(private = "file")
linux_remove :: proc(o: ^Options) -> Result {
	l, ok := layout_of(o)
	if !ok { return {.System, "neither $XDG_DATA_HOME nor the home directory is known"} }
	res: Result
	if text, err := os.read_entire_file(l.entry, context.temp_allocator); err == nil {
		content := string(text)
		mark, _ := entry_value(content, ENTRY_MARKER)
		exec, _ := entry_value(content, "Exec")
		if mark == o.identity.slug || same_path(exec_program(exec), o.exe) {
			if rerr := os.remove(l.entry); rerr != nil { res = {.Io, strings.concatenate({"cannot delete ", l.entry}, context.temp_allocator)} }
		}
	}
	// the icons are named after the identity's slug: this program's own namespace
	for size in ICON_SIZES {
		path := icon_path(l, o.identity.slug, size)
		if os.is_file(path) {
			if rerr := os.remove(path); rerr != nil && res.error == .None { res = {.Io, strings.concatenate({"cannot delete ", path}, context.temp_allocator)} }
		}
	}
	for ic in o.icons {
		path := icon_path(l, o.identity.slug, ic.size)
		if os.is_file(path) { _ = os.remove(path) }
	}
	if o.notify_system { run_tool("update-desktop-database", {l.applications}) }
	return res
}

////////////////////////////////
// Tools of the desktop

// Runs `tool` with `args` when it is on the PATH, silently, and waits for it. False when it is not there or failed.
@(private = "file")
run_tool :: proc(tool: string, args: []string) -> bool {
	path, found := find_on_path(tool)
	if !found { return false }
	command := make([dynamic]string, context.temp_allocator)
	append(&command, path)
	for a in args { append(&command, a) }
	p, err := os.process_start(os.Process_Desc{command = command[:]})
	if err != nil { return false }
	state, werr := os.process_wait(p)
	return werr == nil && state.success
}

@(private = "file")
find_on_path :: proc(tool: string) -> (path: string, found: bool) {
	paths, ok := os.lookup_env("PATH", context.temp_allocator)
	if !ok { return }
	for dir in strings.split(paths, ":", context.temp_allocator) {
		if dir == "" { continue }
		candidate := strings.concatenate({dir, "/", tool}, context.temp_allocator)
		if os.is_file(candidate) { return candidate, true }
	}
	return
}
