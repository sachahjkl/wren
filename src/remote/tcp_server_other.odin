#+build !windows
package remote

// The CDP / WebDriver-BiDi TCP adapter server is raw Winsock today (tcp_server_windows.odin). It is not ported off
// Windows yet, so this stub keeps the package and its only caller (src/browser/cdp.odin) compiling while reporting the
// channel as unavailable: tcp_start fails with a clear message (so --remote-debugging-port prints it and the browser
// runs on without the channel), and the rest are safe no-ops. A Linux port (a core:sys/linux socket with the event loop,
// or core:net) is a later chantier; the wren-ctl remote channel (a Unix socket, remote/server_linux.odin) already works.

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
