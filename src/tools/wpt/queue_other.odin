#+build !windows
package wpt

import "core:os"

// (os.pipe opens both ends close-on-exec: a child gets only what it is given)
keep_from_children :: proc(f: ^os.File) {}
