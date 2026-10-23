package fetch

// What the browser's other parts see of the loader: one call per step of a request (started, sent, redirected, answered,
// a piece of the body, done, failed), from the loop thread, whatever asked (the document, a script, an image, a font, a
// worker). The developer tools (`Loader.observer`) turn them into the Network panel's rows and details; the pages
// (`observer_add`) into Resource Timing entries. Nothing here changes what a request does; with no observer it costs a
// test, and the pieces of the body are only passed on while the observer asks for them (`body_limit` > 0).

import "wb:base"
import "wb:net"

Observed_Kind :: enum u8 {
	Started,    // the request was made (method, URL, destination, who made it)
	Request,    // the request goes out: its header block and body (once per hop of a redirect chain)
	Redirect,   // an answer that sends the request on (status, where it was, `detail`: where it goes)
	Response,   // the answer's head arrived (status, type, headers, where it came from, the URL after redirects, timing)
	Body,       // a piece of the body (`data`, valid during the call); the whole body at once for a request that collects it
	Done,       // the body is complete (bytes, timing)
	Failed,     // the request failed or was blocked (error, detail), or was cancelled by its owner (Aborted)
	Ws_Started,   // a WebSocket was made: url, initiator, scope, headers (the handshake request), detail (the subprotocols asked)
	Ws_Response,  // the handshake was answered: status, headers, protocol (the subprotocol chosen)
	Ws_Frame,     // a message: data, binary, outgoing; or the peer's close frame (detail: "close 1000 reason", no data)
	Ws_Closed,    // the socket ended: status (the close code), detail (the reason), clean; a failure is Failed with the error
}

Observed :: struct {
	kind:        Observed_Kind,
	id:          u64,               // the request: unique in the loader's life
	scope:       ^base.Scope,       // the scope it runs in (Started only; nil: none); valid during the call only
	initiator:   ^Environment,      // Started: the document that asked (nil: the browser itself, a navigation)
	method:      string,            // Started
	url:         string,            // the URL the request has now (the final one after redirects, on Response); valid during the call
	destination: Destination,
	mode:        Mode,              // Started
	navigate:    bool,              // Started: a navigation (the document itself, a frame)
	parser:      bool,              // Started: inserted by the HTML parser (a <script>, <link>, <img> of the markup)
	initiator_url: string,          // Started: the URL of the document that asked ("" for the address bar)
	status:      int,               // Response, Redirect
	status_text: string,            // Response: "OK", "Not Found" (what the server wrote)
	mime:        string,            // Response: the essence of the Content-Type ("" when none); valid during the call
	cache:       Cache_Outcome,     // Response
	redirected:  bool,              // Response
	redirects:   int,               // Response: how many redirects the request followed
	protocol:    string,            // Response: "http/1.1", "h2", "h3" ("" when it did not come over the network)
	remote:      string,            // Response: "ip:port" of the server
	headers:     string,            // Request: the header block sent; Response: the one received (status line first)
	request_body: []byte,           // Request
	data:        []byte,            // Body
	bytes:       int,               // Done: the body's size; Response / Failed: what arrived so far
	error:       Error_Kind,        // Failed
	detail:      string,            // Failed: valid during the call; Redirect: the target
	timing:      net.Timing,        // Response, Done
	has_timing:  bool,
	outgoing:    bool,              // Ws_Frame: sent by the page
	binary:      bool,              // Ws_Frame
	clean:       bool,              // Ws_Closed
}

Observer :: struct {
	user:  rawptr,
	event: proc(user: rawptr, ev: ^Observed),
	no_cache: bool,      // requests that ask for the default cache mode go to the network and leave the cache alone (Disable cache)
	body_limit: int,    // bytes of body the observer wants of a request (0: none: no piece of a body is passed on)
	block: proc(user: rawptr, scope: ^base.Scope, url: string) -> bool,   // true: the request for this URL is stopped before it is made (nil: none is)
	throttle: proc(user: rawptr, scope: ^base.Scope) -> ^net.Throttle_Link,   // the link the requests (and sockets) of this scope go through (nil: none)
}

// Adds an observer besides the developer tools' one (a page's timeline). The same `user` is removed by observer_remove.
observer_add :: proc(l: ^Loader, o: Observer) {
	if o.event == nil { return }
	// (the process's allocator: a page's timeline observes a loader for the process's life, and not for a test's)
	if l.observers == nil { l.observers = make([dynamic]Observer, 0, 2, base.process_allocator()) }
	append(&l.observers, o)
}

observer_remove :: proc(l: ^Loader, user: rawptr) {
	for i := len(l.observers) - 1; i >= 0; i -= 1 { if l.observers[i].user == user { ordered_remove(&l.observers, i) } }
	if len(l.observers) == 0 { delete(l.observers); l.observers = nil }   // (a loader nobody observes holds nothing)
}

// Whether anything watches (the steps are only described to someone who looks).
@(private)
observing :: #force_inline proc(l: ^Loader) -> bool { return l != nil && (l.observer.event != nil || len(l.observers) > 0) }

@(private)
observe :: proc(t: ^Task, ev: Observed) {
	l := t.loader
	if !observing(l) { return }
	e := ev
	e.id = t.obs_id
	if l.observer.event != nil { l.observer.event(l.observer.user, &e) }
	for i := 0; i < len(l.observers); i += 1 {
		o := l.observers[i]
		o.event(o.user, &e)
	}
}

// The same for a WebSocket: id is the socket's.
@(private)
observe_id :: proc(l: ^Loader, id: u64, ev: Observed) {
	if l == nil || l.observer.event == nil || id == 0 { return }
	e := ev
	e.id = id
	l.observer.event(l.observer.user, &e)
}

// The link a request or socket of scope goes through.
@(private)
link_of :: proc(l: ^Loader, scope: ^base.Scope) -> ^net.Throttle_Link {
	if l.observer.throttle == nil { return nil }
	return l.observer.throttle(l.observer.user, scope)
}

@(private)
protocol_name :: proc(p: u8) -> string {
	switch p {
	case 1: return "h2"
	case 2: return "h3"
	}
	return "http/1.1"
}

// The reason phrase of a raw header block ("HTTP/1.1 404 Not Found\r\n..." -> "Not Found").
@(private)
status_text_of :: proc(block: string) -> string {
	end := len(block)
	for i in 0 ..< len(block) { if block[i] == '\r' || block[i] == '\n' { end = i; break } }
	line := block[:end]
	sp := -1
	for i in 0 ..< len(line) { if line[i] == ' ' { sp = i; break } }
	if sp < 0 { return "" }
	rest := line[sp + 1:]
	for i in 0 ..< len(rest) { if rest[i] == ' ' { return rest[i + 1:] } }
	return ""
}
