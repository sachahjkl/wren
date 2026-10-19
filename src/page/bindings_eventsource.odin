package page

// Module "eventsource": EventSource and the MessageEvent members that are not plain event payload. See eventsource.odin
// for the semantics.

EventSource_create :: proc(c: ^Call, target: string, with_credentials: bool) -> (u64, Api_Error) {
	h := eventsource_create(c.page, c.owner, target, with_credentials)
	if h == 0 { return 0, fail(c, .Syntax, "SyntaxError: invalid URL") }
	return h, .None
}

EventSource_readyState :: proc(c: ^Call, source: Api_EventSource) -> Api_EventSourceState { return Api_EventSourceState(source.data.state) }
EventSource_url :: proc(c: ^Call, source: Api_EventSource) -> string { return source.data.href }
EventSource_withCredentials :: proc(c: ^Call, source: Api_EventSource) -> bool { return source.data.with_credentials }
EventSource_close :: proc(c: ^Call, source: Api_EventSource) { eventsource_close(source.data) }

MessageEvent_origin :: proc(c: ^Call, event: Api_Event) -> string { return message_event_origin(c.page, event.data) }

MessageEvent_lastEventId :: proc(c: ^Call, event: Api_Event) -> string {
	if eventsource_get(c.page, u64(event.data.target)) == nil { return "" }
	return event.data.text
}