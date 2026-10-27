package net

// Minimal WinHTTP bindings (asynchronous mode). WinHTTP gives us, from the OS and with zero dependencies: TLS with
// the system trust store (and enterprise policy), HTTP/1.1 + HTTP/2 (+ HTTP/3 where available), proxy auto-detection,
// connection pooling and decompression. Everything below is `system:winhttp`.

import win "core:sys/windows"

foreign import winhttp "system:winhttp.lib"

HINTERNET :: distinct rawptr

Status_Callback :: #type proc "system" (h: HINTERNET, ctx: win.DWORD_PTR, status: win.DWORD, info: rawptr, info_len: win.DWORD)

Async_Result :: struct {
	result: win.DWORD_PTR,
	error:  win.DWORD,
}

WINHTTP_ACCESS_TYPE_NO_PROXY :: 1
WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY :: 4
WINHTTP_FLAG_ASYNC  :: 0x10000000
WINHTTP_FLAG_SECURE :: 0x00800000
WINHTTP_CALLBACK_FLAG_ALL_NOTIFICATIONS :: 0xFFFFFFFF

WINHTTP_CALLBACK_STATUS_RESOLVING_NAME        :: 0x00000001
WINHTTP_CALLBACK_STATUS_NAME_RESOLVED         :: 0x00000002
WINHTTP_CALLBACK_STATUS_CONNECTING_TO_SERVER  :: 0x00000004
WINHTTP_CALLBACK_STATUS_CONNECTED_TO_SERVER   :: 0x00000008
WINHTTP_CALLBACK_STATUS_SENDING_REQUEST       :: 0x00000010
WINHTTP_CALLBACK_STATUS_REQUEST_SENT          :: 0x00000020
WINHTTP_CALLBACK_STATUS_RECEIVING_RESPONSE    :: 0x00000040
WINHTTP_CALLBACK_STATUS_RESPONSE_RECEIVED     :: 0x00000080
WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING        :: 0x00000800
WINHTTP_CALLBACK_STATUS_SECURE_FAILURE        :: 0x00010000
WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE     :: 0x00020000
WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE        :: 0x00040000
WINHTTP_CALLBACK_STATUS_READ_COMPLETE         :: 0x00080000
WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE        :: 0x00100000
WINHTTP_CALLBACK_STATUS_REQUEST_ERROR         :: 0x00200000
WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE  :: 0x00400000

WINHTTP_OPTION_URL                   :: 34
WINHTTP_OPTION_CONTEXT_VALUE         :: 45
WINHTTP_OPTION_REDIRECT_POLICY       :: 88
WINHTTP_OPTION_AUTOLOGON_POLICY       :: 77
WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH :: 2   // never send ambient Windows credentials
WINHTTP_OPTION_REDIRECT_POLICY_NEVER :: 0
WINHTTP_OPTION_MAX_HTTP_AUTOMATIC_REDIRECTS :: 89
WINHTTP_OPTION_MAX_CONNS_PER_SERVER  :: 73
WINHTTP_OPTION_DISABLE_FEATURE       :: 63
WINHTTP_OPTION_DECOMPRESSION         :: 118
WINHTTP_OPTION_SECURE_PROTOCOLS      :: 84
WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2   :: 0x00000800
WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3   :: 0x00002000
WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL  :: 133
WINHTTP_OPTION_HTTP_PROTOCOL_USED    :: 134

WINHTTP_DISABLE_COOKIES              :: 0x00000001
WINHTTP_DECOMPRESSION_FLAG_ALL       :: 0x00000003
WINHTTP_PROTOCOL_FLAG_HTTP2          :: 0x1
WINHTTP_PROTOCOL_FLAG_HTTP3          :: 0x2
WINHTTP_OPTION_REDIRECT_POLICY_DISALLOW_HTTPS_TO_HTTP :: 1

WINHTTP_QUERY_RAW_HEADERS_CRLF :: 22
WINHTTP_QUERY_STATUS_CODE      :: 19
WINHTTP_QUERY_FLAG_NUMBER      :: 0x20000000

@(default_calling_convention = "system")
foreign winhttp {
	WinHttpOpen :: proc(agent: win.LPCWSTR, access_type: win.DWORD, proxy, bypass: win.LPCWSTR, flags: win.DWORD) -> HINTERNET ---
	WinHttpCloseHandle :: proc(h: HINTERNET) -> win.BOOL ---
	WinHttpSetStatusCallback :: proc(h: HINTERNET, cb: Status_Callback, flags: win.DWORD, reserved: win.DWORD_PTR) -> Status_Callback ---
	WinHttpSetTimeouts :: proc(h: HINTERNET, resolve, connect, send, receive: i32) -> win.BOOL ---
	WinHttpSetOption :: proc(h: HINTERNET, option: win.DWORD, buffer: rawptr, length: win.DWORD) -> win.BOOL ---
	WinHttpQueryOption :: proc(h: HINTERNET, option: win.DWORD, buffer: rawptr, length: ^win.DWORD) -> win.BOOL ---
	WinHttpConnect :: proc(session: HINTERNET, server: win.LPCWSTR, port: u16, reserved: win.DWORD) -> HINTERNET ---
	WinHttpOpenRequest :: proc(connect: HINTERNET, verb, object, version, referrer: win.LPCWSTR, accept_types: rawptr, flags: win.DWORD) -> HINTERNET ---
	WinHttpSendRequest :: proc(req: HINTERNET, headers: win.LPCWSTR, headers_len: win.DWORD, optional: rawptr, optional_len, total_len: win.DWORD, ctx: win.DWORD_PTR) -> win.BOOL ---
	WinHttpReceiveResponse :: proc(req: HINTERNET, reserved: rawptr) -> win.BOOL ---
	WinHttpQueryHeaders :: proc(req: HINTERNET, level: win.DWORD, name: win.LPCWSTR, buffer: rawptr, length: ^win.DWORD, index: ^win.DWORD) -> win.BOOL ---
	WinHttpQueryDataAvailable :: proc(req: HINTERNET, available: ^win.DWORD) -> win.BOOL ---
	WinHttpReadData :: proc(req: HINTERNET, buffer: rawptr, to_read: win.DWORD, read: ^win.DWORD) -> win.BOOL ---
}
