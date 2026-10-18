package web

// EventSource (server-sent events), import module "eventsource". Listen with add_listener(es, "open" | "message" |
// "error" | <event name>, ...). In a message listener: event_data = data, event_text / message_event_last_id =
// lastEventId, message_event_origin = origin. Release with Object_release.

Event_Source_State :: enum i32 { Connecting = 0, Open = 1, Closed = 2 }

foreign import eventsource_mod "eventsource"

@(default_calling_convention = "contextless")
foreign eventsource_mod {
	@(link_name = "EventSource_create") raw_eventSourceCreate :: proc(url: [^]u8, ul: i32, with_credentials: i32) -> Handle ---
	EventSource_readyState :: proc(es: Handle) -> Event_Source_State ---
	@(link_name = "EventSource_url") raw_eventSourceUrl :: proc(es: Handle, buf: [^]u8, cap: i32) -> i32 ---
	EventSource_withCredentials :: proc(es: Handle) -> i32 ---
	EventSource_close :: proc(es: Handle) -> Error ---
	@(link_name = "MessageEvent_origin") raw_messageEventOrigin :: proc(ev: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "MessageEvent_lastEventId") raw_messageEventLastId :: proc(ev: Handle, buf: [^]u8, cap: i32) -> i32 ---
}

// NIL when the URL does not parse (SyntaxError).
event_source :: proc "contextless" (url: string, with_credentials := false) -> Handle {
	return raw_eventSourceCreate(raw_data(url), i32(len(url)), with_credentials ? 1 : 0)
}

event_source_url :: proc "contextless" (es: Handle, buf: []u8) -> string {
	n := raw_eventSourceUrl(es, raw_data(buf), i32(len(buf)))
	return string(buf[:min(int(max(n, 0)), len(buf))])
}

message_event_origin :: proc "contextless" (ev: Handle, buf: []u8) -> string {
	n := raw_messageEventOrigin(ev, raw_data(buf), i32(len(buf)))
	return string(buf[:min(int(max(n, 0)), len(buf))])
}

message_event_last_id :: proc "contextless" (ev: Handle, buf: []u8) -> string {
	n := raw_messageEventLastId(ev, raw_data(buf), i32(len(buf)))
	return string(buf[:min(int(max(n, 0)), len(buf))])
}
