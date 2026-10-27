#+build linux, darwin, freebsd, openbsd, netbsd
package remote

import "core:path/filepath"

// The full path of `p` (relative to the current folder, `.` and `..` resolved), or `p` itself.
full_path :: proc(p: string) -> string {
	abs, err := filepath.abs(p, context.temp_allocator)
	return err == nil ? abs : p
}
