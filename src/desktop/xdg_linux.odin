package desktop

// The XDG Base Directory directories, in one place (freedesktop.org "basedir-spec"). Every XDG_* variable is used only
// when it is an absolute path (the specification says a relative value is ignored and the default used); the defaults
// are under the user's home. These are where the program's own files live and where its desktop integration is read
// and written, so the launcher entry, the icons, the config, the cache, the state and the user's data all have one
// source of truth here.

import "core:os"
import "core:path/filepath"
import "core:strings"

// Returns $VAR when it is an absolute path, else `home`/`fallback` (fallback is relative to the home directory).
@(private = "file")
xdg_dir :: proc(variable, fallback: string, allocator := context.temp_allocator) -> string {
	if v, ok := os.lookup_env(variable, allocator); ok && filepath.is_abs(v) { return v }
	home, err := os.user_home_dir(allocator)
	if err != nil || home == "" { return "" }
	return strings.concatenate({home, "/", fallback}, allocator)
}

// $XDG_DATA_HOME, default ~/.local/share: the launcher entry, icons, the installed copy, the user's data (history...).
xdg_data_home :: proc(allocator := context.temp_allocator) -> string { return xdg_dir("XDG_DATA_HOME", ".local/share", allocator) }

// $XDG_CONFIG_HOME, default ~/.config: the preferences (about:config).
xdg_config_home :: proc(allocator := context.temp_allocator) -> string { return xdg_dir("XDG_CONFIG_HOME", ".config", allocator) }

// $XDG_CACHE_HOME, default ~/.cache: the HTTP cache, the compiled-Wasm cache, thumbnails.
xdg_cache_home :: proc(allocator := context.temp_allocator) -> string { return xdg_dir("XDG_CACHE_HOME", ".cache", allocator) }

// $XDG_STATE_HOME, default ~/.local/state: logs, the last session, recently-closed tabs.
xdg_state_home :: proc(allocator := context.temp_allocator) -> string { return xdg_dir("XDG_STATE_HOME", ".local/state", allocator) }

// Where a user's executables go so the launcher and the shell find them by name (~/.local/bin, on the default PATH of
// systemd and most distributions). The "Add to PATH" of Linux: a symlink to the program here (install.odin).
xdg_bin_dir :: proc(allocator := context.temp_allocator) -> string {
	home, err := os.user_home_dir(allocator)
	if err != nil || home == "" { return "" }
	return strings.concatenate({home, "/.local/bin"}, allocator)
}

// $XDG_RUNTIME_DIR: the per-session runtime directory (the instance lock and the control socket live there, not here).
// "" when the session has none.
xdg_runtime_dir :: proc(allocator := context.temp_allocator) -> string {
	if v, ok := os.lookup_env("XDG_RUNTIME_DIR", allocator); ok && filepath.is_abs(v) { return v }
	return ""
}

// The well-known user directory for finished downloads: $XDG_DOWNLOAD_DIR (from user-dirs.dirs), then ~/Downloads. The
// value in user-dirs.dirs is written as $HOME/... so the leading $HOME is expanded.
xdg_download_dir :: proc(allocator := context.temp_allocator) -> string {
	if d := read_user_dir("XDG_DOWNLOAD_DIR", allocator); d != "" { return d }
	home, err := os.user_home_dir(allocator)
	if err != nil || home == "" { return "" }
	return strings.concatenate({home, "/Downloads"}, allocator)
}

// Reads one entry of $XDG_CONFIG_HOME/user-dirs.dirs (XDG_DOWNLOAD_DIR="$HOME/Downloads"). "" when the file or the key
// is absent. $HOME at the start is expanded; a relative value is ignored.
@(private = "file")
read_user_dir :: proc(key: string, allocator := context.temp_allocator) -> string {
	config := xdg_config_home(allocator)
	if config == "" { return "" }
	path := strings.concatenate({config, "/user-dirs.dirs"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return "" }
	content := string(data)
	for line in strings.split_lines_iterator(&content) {
		l := strings.trim_space(line)
		if len(l) == 0 || l[0] == '#' { continue }
		eq := strings.index_byte(l, '=')
		if eq < 0 { continue }
		if strings.trim_space(l[:eq]) != key { continue }
		val := strings.trim_space(l[eq + 1:])
		val = strings.trim(val, "\"")
		if strings.has_prefix(val, "$HOME/") {
			home, herr := os.user_home_dir(allocator)
			if herr != nil || home == "" { return "" }
			return strings.concatenate({home, val[len("$HOME"):]}, allocator)
		}
		if strings.has_prefix(val, "/") { return strings.clone(val, allocator) }
		return ""
	}
	return ""
}
