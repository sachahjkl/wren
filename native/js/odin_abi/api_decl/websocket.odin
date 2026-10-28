// Modules websocket and eventsource (api/websocket.widl, api/eventsource.widl): WebSocket and CloseEvent, EventSource,
// and the members of MessageEvent that are not plain payload. The engine side is native/js/odin/web_socket.odin.
package api_decl

import "../abi"

WebSocket   :: distinct abi.Handle
EventSource :: distinct abi.Handle

// WebSocket.readyState
WebSocketState :: enum i32 { Connecting, Open, Closing, Closed }
// EventSource.readyState
EventSourceState :: enum i32 { Connecting, Open, Closed }

// new WebSocket(url, protocols): `protocols` is a comma-separated list ("" = none). Syntax for an invalid URL or
// protocol list.
WebSocket_create     :: #type proc(url: string, protocols: string) -> (WebSocket, abi.Api_Error)
WebSocket_readyState :: #type proc(socket: WebSocket) -> WebSocketState
// socket.send(text). Invalid_State while connecting.
WebSocket_send       :: #type proc(socket: WebSocket, text: string) -> abi.Api_Error
// socket.send(buffer): a binary message.
WebSocket_sendBuffer :: #type proc(socket: WebSocket, data: Buffer) -> abi.Api_Error
// socket.close(code, reason): code < 0 means absent. Invalid_Access for a code that is not 1000 or 3000-4999, Syntax
// for a reason over 123 bytes.
WebSocket_close      :: #type proc(socket: WebSocket, code: i32, reason: string) -> abi.Api_Error
// The buffer of a binary "message" event (module dom: Event_object; 0 for a text message).
WebSocket_messageBuffer :: #type proc(event: Event) -> Buffer
// CloseEvent.wasClean
CloseEvent_wasClean  :: #type proc(event: Event) -> bool

// new EventSource(url, {withCredentials}). Syntax for an invalid URL.
EventSource_create     :: #type proc(url: string, with_credentials: bool) -> (EventSource, abi.Api_Error)
EventSource_readyState :: #type proc(source: EventSource) -> EventSourceState
EventSource_close      :: #type proc(source: EventSource)

// MessageEvent.origin and lastEventId ("" for messages that do not come from an EventSource); the ends of the ports
// that came with a worker's message (packed, 8 bytes each).
MessageEvent_origin      :: #type proc(event: Event) -> string
MessageEvent_lastEventId :: #type proc(event: Event) -> string
MessageEvent_portEnds    :: #type proc(event: Event) -> abi.Bytes
