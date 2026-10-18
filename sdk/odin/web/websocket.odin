package web

// WebSocket, import module "websocket". Listen with add_listener(ws, "open" | "message" | "error" | "close", ...).
// A text message is event_data; a binary one is Event_object (a buffer you own: Object_release it). A close event has
// Event_code, the reason in event_text and CloseEvent_wasClean. Release the socket with Object_release.

Web_Socket_State :: enum i32 { Connecting = 0, Open = 1, Closing = 2, Closed = 3 }

// DOMException codes, negated.
Net_Api_Error :: enum i32 {
	None           = 0,
	Invalid_Handle = -1,
	Not_Supported  = -9,
	Invalid_State  = -11,
	Syntax         = -12,
	Invalid_Access = -15,
}

foreign import websocket_mod "websocket"

@(default_calling_convention = "contextless")
foreign websocket_mod {
	@(link_name = "WebSocket_create") raw_webSocketCreate :: proc(url: [^]u8, ul: i32, protocols: [^]u8, pl: i32) -> Handle ---
	WebSocket_readyState :: proc(ws: Handle) -> Web_Socket_State ---
	@(link_name = "WebSocket_url") raw_webSocketUrl :: proc(ws: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "WebSocket_protocol") raw_webSocketProtocol :: proc(ws: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "WebSocket_extensions") raw_webSocketExtensions :: proc(ws: Handle, buf: [^]u8, cap: i32) -> i32 ---
	WebSocket_bufferedAmount :: proc(ws: Handle) -> i64 ---
	WebSocket_binaryType :: proc(ws: Handle) -> i32 ---
	WebSocket_setBinaryType :: proc(ws: Handle, type: i32) -> Net_Api_Error ---
	@(link_name = "WebSocket_send") raw_webSocketSend :: proc(ws: Handle, data: [^]u8, n: i32) -> Net_Api_Error ---
	WebSocket_sendBuffer :: proc(ws: Handle, buffer: Handle) -> Net_Api_Error ---
	@(link_name = "WebSocket_close") raw_webSocketClose :: proc(ws: Handle, code: i32, reason: [^]u8, rl: i32) -> Net_Api_Error ---
	CloseEvent_wasClean :: proc(ev: Handle) -> i32 ---
}

// `protocols` is a comma-separated list ("" = none). NIL on a SyntaxError.
web_socket :: proc "contextless" (url: string, protocols := "") -> Handle {
	return raw_webSocketCreate(raw_data(url), i32(len(url)), raw_data(protocols), i32(len(protocols)))
}

web_socket_send :: proc "contextless" (ws: Handle, text: string) -> Net_Api_Error {
	return raw_webSocketSend(ws, raw_data(text), i32(len(text)))
}

// code < 0: no code.
web_socket_close :: proc "contextless" (ws: Handle, code: i32 = -1, reason := "") -> Net_Api_Error {
	return raw_webSocketClose(ws, code, raw_data(reason), i32(len(reason)))
}

web_socket_protocol :: proc "contextless" (ws: Handle, buf: []u8) -> string {
	n := raw_webSocketProtocol(ws, raw_data(buf), i32(len(buf)))
	return string(buf[:min(int(max(n, 0)), len(buf))])
}

web_socket_url :: proc "contextless" (ws: Handle, buf: []u8) -> string {
	n := raw_webSocketUrl(ws, raw_data(buf), i32(len(buf)))
	return string(buf[:min(int(max(n, 0)), len(buf))])
}
