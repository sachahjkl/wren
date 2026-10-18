package net

// WinHTTP's WebSocket API (Windows 8+): the handshake is an ordinary request upgraded with
// WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, then WinHttpWebSocketCompleteUpgrade turns it into a WebSocket handle. The OS does
// the framing, masking, ping/pong, the Sec-WebSocket-Key / Accept check and TLS; we keep the policy and the reassembly.

import win "core:sys/windows"

foreign import winhttp_ws "system:winhttp.lib"

WINHTTP_OPTION_SEND_TIMEOUT                   :: 5
WINHTTP_OPTION_RECEIVE_TIMEOUT                :: 6
WINHTTP_OPTION_RECEIVE_RESPONSE_TIMEOUT       :: 7
WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET          :: 114
WINHTTP_OPTION_WEB_SOCKET_CLOSE_TIMEOUT       :: 115
WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL  :: 116
WINHTTP_OPTION_WEB_SOCKET_RECEIVE_BUFFER_SIZE :: 122
WINHTTP_OPTION_WEB_SOCKET_SEND_BUFFER_SIZE    :: 123

WINHTTP_CALLBACK_STATUS_CLOSE_COMPLETE        :: 0x02000000
WINHTTP_CALLBACK_STATUS_SHUTDOWN_COMPLETE     :: 0x04000000

WINHTTP_INVALID_STATUS_CALLBACK :: ~uintptr(0)

Web_Socket_Buffer_Type :: enum u32 {
	Binary_Message  = 0,
	Binary_Fragment = 1,
	Utf8_Message    = 2,
	Utf8_Fragment   = 3,
	Close           = 4,
}

Web_Socket_Operation :: enum u32 { Send = 0, Receive = 1, Close = 2, Shutdown = 3 }

// `info` of READ_COMPLETE / WRITE_COMPLETE on a WebSocket handle.
Web_Socket_Status :: struct {
	bytes_transferred: win.DWORD,
	buffer_type:       Web_Socket_Buffer_Type,
}

// `info` of REQUEST_ERROR on a WebSocket handle. Starts with the ordinary Async_Result.
Web_Socket_Async_Result :: struct {
	result:    Async_Result,
	operation: Web_Socket_Operation,
}

WINHTTP_WEB_SOCKET_EMPTY_CLOSE_STATUS :: 1005
WINHTTP_WEB_SOCKET_MAX_CLOSE_REASON   :: 123

ERROR_INVALID_OPERATION :: 4317
ERROR_IO_PENDING        :: 997
ERROR_WINHTTP_OPERATION_CANCELLED :: 12017

@(default_calling_convention = "system")
foreign winhttp_ws {
	WinHttpWebSocketCompleteUpgrade :: proc(request: HINTERNET, ctx: win.DWORD_PTR) -> HINTERNET ---
	WinHttpWebSocketSend :: proc(ws: HINTERNET, type: Web_Socket_Buffer_Type, buffer: rawptr, length: win.DWORD) -> win.DWORD ---
	WinHttpWebSocketReceive :: proc(ws: HINTERNET, buffer: rawptr, length: win.DWORD, read: ^win.DWORD, type: ^Web_Socket_Buffer_Type) -> win.DWORD ---
	WinHttpWebSocketClose :: proc(ws: HINTERNET, status: u16, reason: rawptr, reason_len: win.DWORD) -> win.DWORD ---
	WinHttpWebSocketShutdown :: proc(ws: HINTERNET, status: u16, reason: rawptr, reason_len: win.DWORD) -> win.DWORD ---
	WinHttpWebSocketQueryCloseStatus :: proc(ws: HINTERNET, status: ^u16, reason: rawptr, reason_len: win.DWORD, consumed: ^win.DWORD) -> win.DWORD ---
}
