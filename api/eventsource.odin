// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=eventsource order=13 exposed=Window
/// Server-sent events (HTML EventSource) and the MessageEvent members that are not plain payload. Messages arrive as
/// "message" (or named) events: data in Event_data, the last event id in Event_text.
package api_eventsource

//@wb handle parent=Object host=Event_Source lookup=lookup_EventSource
EventSource :: distinct Handle

/// EventSource.readyState
EventSourceState :: enum i32 {
	Connecting,
	Open,
	Closed,
}

/// new EventSource(url, {withCredentials}). Syntax for an invalid URL.
//@wb fn raises
EventSource_create :: proc(url: string, with_credentials: bool = false) -> EventSource

//@wb fn
EventSource_readyState :: proc(source: EventSource) -> EventSourceState

//@wb fn
EventSource_url :: proc(source: EventSource) -> string

//@wb fn
EventSource_withCredentials :: proc(source: EventSource) -> bool

/// source.close()
//@wb fn
EventSource_close :: proc(source: EventSource)

/// MessageEvent.origin
//@wb fn
MessageEvent_origin :: proc(event: Event) -> string

/// MessageEvent.lastEventId ("" for messages that do not come from an EventSource).
//@wb fn
MessageEvent_lastEventId :: proc(event: Event) -> string

