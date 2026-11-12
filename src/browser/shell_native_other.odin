#+build !windows
package browser

// shell_native_windows.odin off Windows: the toolkit's window has no subclass to undo, a closed window leaves the screen
// when it is destroyed, its size arrives with its first configure event, and the compositor places it.

import "toolkit:platform"

Native_Hooks :: struct {}

native_hide_all :: proc(app: ^App) {}
native_size_now :: proc(w: ^platform.Window) {}
native_raise :: proc(w: ^platform.Window, placed: bool) {}
