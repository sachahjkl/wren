package net

// What both stacks share: the WinHTTP backend's handle type (nil on a system without it) and the WebSocket vocabulary
// the Rust stack reports in too (its frame types, operations and error codes are WinHTTP's numbers, so fetch and page read
// one set whichever stack ran the socket).

HINTERNET :: distinct rawptr

Web_Socket_Buffer_Type :: enum u32 {
	Binary_Message  = 0,
	Binary_Fragment = 1,
	Utf8_Message    = 2,
	Utf8_Fragment   = 3,
	Close           = 4,
}

Web_Socket_Operation :: enum u32 { Send = 0, Receive = 1, Close = 2, Shutdown = 3 }

WINHTTP_WEB_SOCKET_EMPTY_CLOSE_STATUS :: 1005
WINHTTP_WEB_SOCKET_MAX_CLOSE_REASON   :: 123

ERROR_INVALID_OPERATION :: 4317
ERROR_IO_PENDING        :: 997
ERROR_WINHTTP_OPERATION_CANCELLED :: 12017
