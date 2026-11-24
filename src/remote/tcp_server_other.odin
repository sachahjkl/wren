#+build !windows
#+build !linux
package remote

// Fallback stub for platforms without a native TCP server implementation (Windows uses tcp_server_windows.odin and
// Linux uses tcp_server_linux.odin). Keeps the package and its caller (src/browser/cdp.odin) compiling while reporting
// the channel as unavailable.

import "wb:host"

Tcp_Handler  :: proc(user: rawptr, conn: u64, data: []byte)
Tcp_On_Close :: proc(user: rawptr, conn: u64)

tcp_running :: proc() -> bool { return false }
tcp_port :: proc() -> int { return 0 }
tcp_client_count :: proc() -> int { return 0 }

tcp_start :: proc(loop: ^host.Loop, port, max_clients: int, handler: Tcp_Handler, on_close: Tcp_On_Close, user: rawptr) -> (err: string) {
	return "the CDP debugging channel over TCP is not available on this platform yet"
}

tcp_stop :: proc() {}
tcp_send :: proc(id: u64, data: []byte) -> bool { return false }
tcp_close_client :: proc(id: u64) {}
tcp_client_ids :: proc(allocator := context.temp_allocator) -> []u64 { return nil }
