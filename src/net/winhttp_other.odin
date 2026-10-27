#+build !windows
package net

// No WinHTTP on this system: the built-in stack (rust.odin) is the only backend, client_init picks it whatever
// network.backend says. These stand in for client_winhttp_windows.odin and websocket_winhttp_windows.odin; no handle of
// theirs is ever opened, so the ones that would act on one are never reached.

import "wb:base"
import "wb:url"

WINHTTP_AVAILABLE :: false

system_proxy_uses_pac :: proc() -> bool { return false }

@(private) winhttp_open :: proc(c: ^Client) -> bool { return false }
@(private) winhttp_apply_timeouts :: proc(c: ^Client) {}
@(private) winhttp_close :: proc(h: HINTERNET) {}
@(private) winhttp_prepare :: proc(job: ^Job, u: url.URL, method, headers: string) {}
@(private) winhttp_begin :: proc(c: ^Client, r: ^Request) -> u32 { return ERROR_START_FAILED }
@(private) winhttp_resume :: proc(r: ^Request) -> u32 { return ERROR_START_FAILED }

@(private) winhttp_ws_prepare :: proc(job: ^Ws_Job, u: url.URL, headers: string) {}
@(private) winhttp_ws_handshake :: proc(m: ^Ws_Manager, s: ^Socket) -> u32 { return ERROR_START_FAILED }
@(private) winhttp_ws_receive :: proc(job: ^Ws_Job, hws: HINTERNET) -> u32 { return ERROR_START_FAILED }

@(private)
winhttp_ws_accept :: proc(m: ^Ws_Manager, h: base.Handle, s: ^Socket) -> bool {
	ws_push(m, Raw{kind = .Handshake_Failed, sock = h, error = ERROR_START_FAILED})
	return false
}

@(private)
winhttp_ws_send :: proc(m: ^Ws_Manager, h: base.Handle, s: ^Socket, buf: []byte, rest: int) {
	ws_push(m, Raw{kind = .Error, sock = h, error = ERROR_WINHTTP_OPERATION_CANCELLED, op = .Send})
}

@(private)
winhttp_ws_shutdown :: proc(m: ^Ws_Manager, h: base.Handle, s: ^Socket) {
	ws_push(m, Raw{kind = .Error, sock = h, error = ERROR_WINHTTP_OPERATION_CANCELLED, op = .Shutdown})
}
