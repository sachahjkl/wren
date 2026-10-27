package remote

import "core:fmt"
import "core:strings"

// Where a Wren listens. The pipe is \\.\pipe\wren-remote-<name>. The name is given (`--remote=<name>`, WREN_REMOTE,
// browser.remote.name) or, by default, derived from the profile folder: the same folder always gives the same name (so
// `wren ctl --profile <folder> ...` finds the instance without being told) and two instances with different profiles never
// meet. The name is written with the pid in <profile>\remote.json when the channel starts and removed when it ends.

PROTOCOL_VERSION :: 1
PIPE_PREFIX :: `\\.\pipe\wren-remote-`

pipe_path :: proc(name: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({PIPE_PREFIX, name}, allocator)
}

// A name made of letters, digits, '-', '_' and '.', short enough for a pipe name. Anything else would be a path.
valid_name :: proc(name: string) -> bool {
	if name == "" || len(name) > 64 || name[0] == '.' { return false }
	for c in transmute([]byte)name {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.':
		case: return false
		}
	}
	return true
}

// FNV-1a of the profile folder as the system spells it most plainly: full path, no trailing separator; on Windows with
// backslashes and in lower case (its paths do not care), elsewhere as it is (case matters there).
profile_name :: proc(profile_dir: string, allocator := context.temp_allocator) -> string {
	p := full_path(profile_dir)
	when ODIN_OS == .Windows {
		p, _ = strings.replace_all(p, "/", "\\", context.temp_allocator)
		for len(p) > 3 && p[len(p) - 1] == '\\' { p = p[:len(p) - 1] }
		p = strings.to_lower(p, context.temp_allocator)
	} else {
		for len(p) > 1 && p[len(p) - 1] == '/' { p = p[:len(p) - 1] }
	}
	h := u64(0xcbf29ce484222325)
	for c in transmute([]byte)p { h = (h ~ u64(c)) * 0x100000001b3 }
	return fmt.aprintf("p%012x", h & 0xffff_ffff_ffff, allocator = allocator)
}

info_path :: proc(profile_dir: string) -> string {
	return strings.concatenate({profile_dir, "/remote.json"}, context.temp_allocator)
}
