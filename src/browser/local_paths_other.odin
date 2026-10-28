#+build !windows
package browser

// POSIX systems: a local path is absolute (`/home/user/page.html`), `~` (the user's $HOME), or `~/...`. There is no
// drive letter and `/` is the only separator. The toolkit's drag-and-drop carries file drops on Linux (Wayland
// wl_data_device, X11 XDND) through dnd_shell.odin, so there is no extra window hook here: the drop_files_platform_*
// procedures are no-ops (the Windows WM_DROPFILES path is only for the elevated browser, which UIPI shuts out there).

import "core:os"
import "core:strings"
import "wb:fetch"

// The file: URL of a local path, or ok = false when `input` is not one (a URL, words, a relative path).
local_path_url :: proc(input: string, allocator := context.temp_allocator) -> (address: string, ok: bool) {
	s := strings.trim_space(input)
	if len(s) >= 2 && s[0] == '"' && s[len(s) - 1] == '"' { s = strings.trim_space(s[1:len(s) - 1]) }
	switch {
	case strings.has_prefix(s, "/"):                                          // /abs/path
	case s == "~" || strings.has_prefix(s, "~/"):
		home := user_home()
		if home == "" { return "", false }
		s = strings.concatenate({home, "/", s[min(2, len(s)):]}, context.temp_allocator)
	case:
		return "", false
	}
	if strings.contains_rune(s, 0) { return "", false }   // a NUL cannot be in a POSIX path
	directory := strings.has_suffix(s, "/")
	return fetch.file_url_from_path(s, directory, allocator), true
}

// The address given on the command line: a relative path that names an existing file or folder (`wren demos`,
// `wren page.html`) is taken from the current folder, as other browsers do; anything else is an address. A leading
// scheme (`https:`, `about:`) is left alone; a bare path is resolved against the working directory.
command_line_address :: proc(arg: string) -> string {
	s := strings.trim_space(arg)
	if s == "" { return s }
	// a scheme like `https:` or `about:` is an address; a Windows-style drive is not meaningful here, so `:` alone does
	// not disqualify a POSIX path (a file may contain a colon), but a real scheme prefix before any slash does.
	if i := strings.index_byte(s, ':'); i > 0 {
		slash := strings.index_byte(s, '/')
		if slash < 0 || slash > i { return s }   // scheme: ... (no '/' before the ':')
	}
	if !os.exists(s) { return s }
	full := s
	if !strings.has_prefix(s, "/") {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		if cwd != "" { full = strings.concatenate({strings.trim_right(cwd, "/"), "/", s}, context.temp_allocator) }
	}
	return fetch.file_url_from_path(full, false, context.temp_allocator)
}

// $HOME, without a final separator ("" when unknown).
@(private = "file")
user_home :: proc() -> string {
	h := os.get_env("HOME", context.temp_allocator)
	if h == "" { return "" }
	return strings.trim_right(h, "/")
}

drop_files_platform_init :: proc(app: ^App) {}
drop_files_platform_destroy :: proc(app: ^App) {}
drop_files_platform_apply :: proc(app: ^App) {}
