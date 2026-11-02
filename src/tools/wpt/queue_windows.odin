package wpt

import "core:os"
import win "core:sys/windows"

// A handle of this process that no child inherits (os.pipe makes both ends inheritable).
keep_from_children :: proc(f: ^os.File) {
	win.SetHandleInformation(win.HANDLE(os.fd(f)), win.HANDLE_FLAG_INHERIT, 0)
}
