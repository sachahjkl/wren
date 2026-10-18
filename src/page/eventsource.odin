package page

// EventSource (HTML §9.2): a host object and EventTarget that reads a text/event-stream through the page's fetch path
// (the document's Environment: CORS, cookies per withCredentials, CSP connect-src, mixed content, HSTS).
//
// States: CONNECTING (0) -> OPEN (1) on a 200 text/event-stream response; the end of the stream or a network error
// reconnects (event "error" while CONNECTING, then the reconnection time, with a bounded back-off) and sends the last
// event ID as Last-Event-ID; any other status or type, a policy refusal or an oversized event fails it (CLOSED (2) +
// "error", no reconnection). close() stops everything at once. The object dies with the page or on Object_release.
//
// Events: "open", "error", "message" and any name the stream gives with `event:`. MessageEvent.data is Event_data,
// lastEventId is Event_text, origin is MessageEvent_origin (the origin of the response URL).

import "core:math"
import "core:strings"
import "wb:base"
import "wb:config"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:http"
import "wb:url"

Eventsource_Settings :: struct {
	default_retry_ms: int,
	min_retry_ms:     int,
	max_retry_ms:     int,
	backoff_factor:   f64,
	max_attempts:     int,   // 0 = unlimited
	max_event_bytes:  int,
}

EVENTSOURCE_PREFS := [?]config.Def{
	{name = "eventsource.default_retry_ms", kind = .Int, default = {i = 3000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "Reconnection time of an EventSource until the server sends a retry: field."},
	{name = "eventsource.min_retry_ms", kind = .Int, default = {i = 250}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "Shortest wait before reconnecting, whatever the server asks: a stream that ends at once cannot hammer the server."},
	{name = "eventsource.max_retry_ms", kind = .Int, default = {i = 300_000}, bounded = true, min = 0, max = 86_400_000, unit = "ms",
		description = "Longest wait before reconnecting (caps the server's retry: field and the back-off)."},
	{name = "eventsource.backoff_factor", kind = .Float, default = {f = 2}, bounded = true, min = 1, max = 16,
		description = "Each consecutive failed reconnection multiplies the wait by this factor (1 = no back-off). A successful connection resets it."},
	{name = "eventsource.max_reconnect_attempts", kind = .Int, default = {i = 0}, bounded = true, min = 0, max = 1_000_000,
		description = "Consecutive reconnections without success before the EventSource gives up (readyState CLOSED). 0 = never gives up."},
	{name = "eventsource.max_event_bytes", kind = .Int, default = {i = 16 << 20}, bounded = true, min = 1024, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Largest event (data of one event, or one line of the stream). A stream exceeding it fails the EventSource."},
}

eventsource_settings_from_prefs :: proc(p: ^config.Prefs) -> Eventsource_Settings {
	s := Eventsource_Settings{
		default_retry_ms = int(config.int_of(p, "eventsource.default_retry_ms")),
		min_retry_ms = int(config.int_of(p, "eventsource.min_retry_ms")),
		max_retry_ms = int(config.int_of(p, "eventsource.max_retry_ms")),
		backoff_factor = config.float_of(p, "eventsource.backoff_factor"),
		max_attempts = int(config.int_of(p, "eventsource.max_reconnect_attempts")),
		max_event_bytes = int(config.int_of(p, "eventsource.max_event_bytes")),
	}
	s.max_retry_ms = max(s.max_retry_ms, s.min_retry_ms)
	return s
}

ES_CONNECTING :: 0
ES_OPEN       :: 1
ES_CLOSED     :: 2

Event_Source :: struct {
	page:             ^Page,
	self:             u64,
	owner:            u32,
	href:             string,   // owned
	with_credentials: bool,
	state:            i32,
	task:             base.Handle,
	timer:            base.Handle,
	parser:           fetch.Sse_Parser,
	origin:           string,   // owned: serialized origin of the response URL
	reconnect_ms:     int,
	attempts:         int,
}

eventsource_vt := Object_VTable{name = "EventSource", destroy = eventsource_destroy}

@(private)
eventsource_destroy :: proc(p: ^Page, data: rawptr) {
	es := (^Event_Source)(data)
	if es.task != base.NIL_HANDLE { fetch.cancel(p.loader, es.task) }
	if es.timer != base.NIL_HANDLE { host.clear_timer(p.loop, es.timer) }
	fetch.sse_parser_destroy(&es.parser)
	delete(es.href)
	delete(es.origin)
	free(es)
}

eventsource_get :: proc(p: ^Page, h: u64) -> ^Event_Source { return (^Event_Source)(object_data(p, h, &eventsource_vt)) }

// new EventSource(url, {withCredentials}). 0 = SyntaxError (the URL does not parse against the document).
eventsource_create :: proc(p: ^Page, owner: u32, input: string, with_credentials: bool) -> u64 {
	u, ok := url.parse(input, &p.env.location, context.temp_allocator)
	if !ok { return 0 }
	es := new(Event_Source)
	es.page, es.owner = p, owner
	es.href = strings.clone(u.href)
	es.with_credentials = with_credentials
	es.reconnect_ms = p.settings.eventsource.default_retry_ms
	fetch.sse_parser_init(&es.parser, p.settings.eventsource.max_event_bytes)
	es.self = object_create(p, &eventsource_vt, es, owner)
	eventsource_connect(es)
	return es.self
}

eventsource_close :: proc(es: ^Event_Source) {
	if es.state == ES_CLOSED { return }
	es.state = ES_CLOSED
	eventsource_stop(es)
}

@(private)
eventsource_stop :: proc(es: ^Event_Source) {
	p := es.page
	if es.task != base.NIL_HANDLE { fetch.cancel(p.loader, es.task); es.task = base.NIL_HANDLE }
	if es.timer != base.NIL_HANDLE { host.clear_timer(p.loop, es.timer); es.timer = base.NIL_HANDLE }
}

@(private)
eventsource_alive :: proc(p: ^Page, self: u64, es: ^Event_Source) -> bool { return eventsource_get(p, self) == es }

@(private)
eventsource_connect :: proc(es: ^Event_Source) {
	p := es.page
	headers := make([dynamic]fetch.Header_Pair, context.temp_allocator)
	append(&headers, fetch.Header_Pair{"Accept", "text/event-stream"})
	// The cache mode is no-store. Our stack has no HTTP cache, so the header only matters to intermediaries; it is not
	// CORS-safelisted, and the specification adds it below the CORS check: sent same-origin only, so that a
	// cross-origin stream does not need a preflight the server never expected.
	if t, ok := url.parse_absolute(es.href, context.temp_allocator); ok && url.same_origin(url.origin_of(t, context.temp_allocator), p.env.origin) {
		append(&headers, fetch.Header_Pair{"Cache-Control", "no-store"})
	}
	if es.parser.last_event_id != "" { append(&headers, fetch.Header_Pair{"Last-Event-ID", es.parser.last_event_id}) }
	es.task = fetch.start(p.loader, {
		request = {
			url = es.href, headers = headers[:], mode = .Cors, credentials = es.with_credentials ? .Include : .Same_Origin,
			destination = .Empty, initiator = &p.env, guard = .None, max_body = max(int),   // a stream has no length
		},
		on_event = eventsource_fetch_event, user = es, scope = p.scope, collect = false,
	})
}

@(private)
eventsource_fire :: proc(p: ^Page, self: u64, type: string, data := "", last_id := "") {
	object_dispatch(p, self, dom.Event{type = type, data = data, text = last_id})
}

// "Fail the connection": CLOSED, then "error". No reconnection.
@(private)
eventsource_fail :: proc(es: ^Event_Source, why: string) {
	p, self := es.page, es.self
	if why != "" { log(p, .Error, strings.concatenate({"EventSource ", es.href, ": ", why}, context.temp_allocator)) }
	es.state = ES_CLOSED
	eventsource_stop(es)
	eventsource_fire(p, self, "error")
}

// "Reestablish the connection": CONNECTING, "error", then a new request after the reconnection time.
@(private)
eventsource_reestablish :: proc(es: ^Event_Source) {
	if es.state == ES_CLOSED { return }
	p, self := es.page, es.self
	s := &p.settings.eventsource
	es.state = ES_CONNECTING
	es.attempts += 1
	if s.max_attempts > 0 && es.attempts > s.max_attempts {
		eventsource_fail(es, "too many reconnection attempts")
		return
	}
	delay := f64(es.reconnect_ms) * math.pow(s.backoff_factor, f64(es.attempts - 1))
	delay = clamp(delay, f64(s.min_retry_ms), f64(s.max_retry_ms))
	es.timer = host.set_timer(p.loop, delay, 0, eventsource_timer, es, p.scope)
	eventsource_fire(p, self, "error")
}

@(private)
eventsource_timer :: proc(data: rawptr) {
	es := (^Event_Source)(data)
	es.timer = base.NIL_HANDLE
	if es.state == ES_CONNECTING && !es.page.closed { eventsource_connect(es) }
}

@(private)
eventsource_fetch_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	es := (^Event_Source)(user)
	p, self := es.page, es.self
	switch ev.kind {
	case .Response:
		r := ev.response
		if r.status != 200 {
			eventsource_fail(es, strings.concatenate({"the response status is ", status_text(r.status), ", not 200"}, context.temp_allocator))
			return
		}
		if !r.has_mime || http.mime_essence(r.mime) != "text/event-stream" {
			eventsource_fail(es, "the response is not text/event-stream")
			return
		}
		delete(es.origin)
		if ru, ok := url.parse_absolute(r.url, context.temp_allocator); ok {
			es.origin = url.origin_serialize(url.origin_of(ru, context.temp_allocator))
		} else {
			es.origin = strings.clone("null")
		}
		fetch.sse_reset_stream(&es.parser)
		es.state = ES_OPEN
		es.attempts = 0
		eventsource_fire(p, self, "open")

	case .Data:
		if es.state != ES_OPEN { return }
		events := make([dynamic]fetch.Sse_Event, context.temp_allocator)
		ok := fetch.sse_feed(&es.parser, ev.data, &events)
		if es.parser.retry_changed {
			es.parser.retry_changed = false
			es.reconnect_ms = es.parser.retry_ms
		}
		for e in events {
			eventsource_fire(p, self, e.type, e.data, e.last_event_id)
			if !eventsource_alive(p, self, es) || es.state != ES_OPEN { return }   // released or closed by a listener
		}
		if !ok { eventsource_fail(es, "an event exceeds eventsource.max_event_bytes") }

	case .Done:
		es.task = base.NIL_HANDLE
		fetch.sse_end(&es.parser)
		eventsource_reestablish(es)

	case .Failed:
		es.task = base.NIL_HANDLE
		fetch.sse_end(&es.parser)
		#partial switch ev.error {
		case .Transport, .Body_Too_Large:
			eventsource_reestablish(es)   // the network, not a policy: worth another try
		case:
			eventsource_fail(es, ev.detail)   // refused by policy: retrying is futile
		}
	}
}

@(private)
status_text :: proc(n: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_int(&sb, n)
	return strings.to_string(sb)
}

// MessageEvent.origin of an event fired by an EventSource or a WebSocket ("" for other targets).
message_event_origin :: proc(p: ^Page, ev: ^dom.Event) -> string {
	target := u64(ev.target)
	if es := eventsource_get(p, target); es != nil { return es.origin }
	if ws := websocket_get(p, target); ws != nil { return ws.origin }
	return ""
}
