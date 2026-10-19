package page

// Module "websocket": WebSocket and CloseEvent. See websocket.odin for the semantics; its errors (Net_Api_Error) map to
// the API's codes.

import "wb:fetch"

@(private)
ws_error :: proc(c: ^Call, e: i32) -> Api_Error {
	switch Net_Api_Error(e) {
	case .Not_Supported:  return fail(c, .Not_Supported, "NotSupportedError")
	case .Invalid_State:  return fail(c, .Invalid_State, "InvalidStateError: the socket is not open")
	case .Syntax:         return fail(c, .Syntax, "SyntaxError")
	case .Invalid_Access: return fail(c, .Invalid_Access, "InvalidAccessError: the close code must be 1000 or 3000-4999")
	}
	return e == 0 ? .None : Api_Error(e)
}

WebSocket_create :: proc(c: ^Call, target: string, protocols: string) -> (u64, Api_Error) {
	h := websocket_create(c.page, c.owner, target, fetch.websocket_split_protocols(protocols))
	if h == 0 { return 0, fail(c, .Syntax, "SyntaxError: invalid URL or protocols") }
	return h, .None
}

WebSocket_readyState :: proc(c: ^Call, socket: Api_WebSocket) -> i32 { return socket.data.state }
WebSocket_url :: proc(c: ^Call, socket: Api_WebSocket) -> string { return socket.data.href }
WebSocket_protocol :: proc(c: ^Call, socket: Api_WebSocket) -> string { return socket.data.protocol }
WebSocket_extensions :: proc(c: ^Call, socket: Api_WebSocket) -> string { return socket.data.extensions }
WebSocket_bufferedAmount :: proc(c: ^Call, socket: Api_WebSocket) -> i64 { return socket.data.buffered }

// 0 = "arraybuffer" (buffer handles), the only type this platform has.
WebSocket_binaryType :: proc(c: ^Call, socket: Api_WebSocket) -> i32 { return 0 }

WebSocket_setBinaryType :: proc(c: ^Call, socket: Api_WebSocket, binary_type: i32) -> Api_Error {
	return binary_type == 0 ? .None : fail(c, .Not_Supported, "NotSupportedError: only \"arraybuffer\" (0) is supported")
}

WebSocket_send :: proc(c: ^Call, socket: Api_WebSocket, text: string) -> Api_Error {
	return ws_error(c, websocket_send(socket.data, transmute([]u8)text, false))
}

WebSocket_sendBuffer :: proc(c: ^Call, socket: Api_WebSocket, data: Api_Buffer) -> Api_Error {
	return ws_error(c, websocket_send(socket.data, data.data.bytes[:], true))
}

WebSocket_close :: proc(c: ^Call, socket: Api_WebSocket, code: i32, reason: string) -> Api_Error {
	return ws_error(c, websocket_close(socket.data, int(code), reason))
}

CloseEvent_wasClean :: proc(c: ^Call, event: Api_Event) -> bool {
	e := event.data
	if w := websocket_get(c.page, u64(e.target)); w != nil && e.type == "close" { return w.was_clean }
	return false
}