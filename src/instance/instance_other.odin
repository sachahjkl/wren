#+build !windows
package instance

// Other platforms: no hand-over yet (a Unix socket in the runtime directory, locked by flock, would be the way; Wren does
// not run there yet). Every start owns its profile, as it did before this package.

Owner :: struct {
	key:     string,
	exe:     string,
	closing: bool,
}

Reply :: enum u8 { No_Window, Accepted, Other_Copy, Refused, Timeout }

forward_once :: proc(key: string, m: Message, timeout_ms: int) -> Reply { return .No_Window }

acquire :: proc(key: string, own_exe: string, msg: Message, wait_ms: int) -> (Outcome, Owner) { return .Other_Copy, {} }

owner_start :: proc(o: ^Owner, handler: Handler, user: rawptr) -> bool { return false }

owner_closing :: proc(o: ^Owner) {}

owner_stop :: proc(o: ^Owner) {}

focus :: proc(hwnd: rawptr) {}

pump_messages :: proc() {}
