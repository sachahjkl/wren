// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=websocket order=74 exposed=Window
/// WebSocket and CloseEvent. Messages arrive as "message" events: text in Event_data, or a buffer in Event_object.
package api_websocket

//@wb handle parent=Object host=Web_Socket lookup=lookup_WebSocket
WebSocket :: distinct Handle

/// WebSocket.readyState
WebSocketState :: enum i32 {
	Connecting,
	Open,
	Closing,
	Closed,
}

/// new WebSocket(url, protocols): `protocols` is a comma-separated list ("" = none). Syntax for an invalid URL or
/// protocol list.
//@wb fn raises
WebSocket_create :: proc(url: string, protocols: string = "") -> WebSocket

//@wb fn
WebSocket_readyState :: proc(socket: WebSocket) -> WebSocketState

//@wb fn
WebSocket_url :: proc(socket: WebSocket) -> string

//@wb fn
WebSocket_protocol :: proc(socket: WebSocket) -> string

//@wb fn
WebSocket_extensions :: proc(socket: WebSocket) -> string

//@wb fn
WebSocket_bufferedAmount :: proc(socket: WebSocket) -> i64

/// 0 = "arraybuffer" (buffer handles), the only binary type of this platform.
//@wb fn
WebSocket_binaryType :: proc(socket: WebSocket) -> i32

/// Not_Supported for anything but 0.
//@wb fn raises
WebSocket_setBinaryType :: proc(socket: WebSocket, binary_type: i32)

/// socket.send(text). Invalid_State while connecting.
//@wb fn raises
WebSocket_send :: proc(socket: WebSocket, text: usvstring)

/// socket.send(buffer): a binary message.
//@wb fn raises
WebSocket_sendBuffer :: proc(socket: WebSocket, data: Buffer)

/// socket.close(code, reason): code < 0 means absent. Invalid_Access for a code that is not 1000 or 3000-4999,
/// Syntax for a reason over 123 bytes.
//@wb fn raises
WebSocket_close :: proc(socket: WebSocket, code: i32 = -1, reason: string = "")

/// CloseEvent.wasClean
//@wb fn
CloseEvent_wasClean :: proc(event: Event) -> bool

