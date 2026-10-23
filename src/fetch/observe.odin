package fetch

// What the browser's other parts see of the loader: one call per step of a request (started, answered, done, failed),
// from the loop thread, whatever asked (the document, a script, an image, a font, a worker). The developer tools
// (`Loader.observer`) turn them into the Network panel's rows; the pages (`observer_add`) into Resource Timing entries.
// Nothing here changes what a request does; with no observer it costs a test.

import "wb:base"

Observed_Kind :: enum u8 {
	Started,    // the request was made (method, URL, destination)
	Response,   // the answer's head arrived (status, type, where it came from, the URL after redirects)
	Done,       // the body is complete (bytes)
	Failed,     // the request failed or was blocked (error, detail), or was cancelled by its owner (Aborted)
}

Observed :: struct {
	kind:        Observed_Kind,
	id:          u64,               // the request: unique in the loader's life
	scope:       ^base.Scope,       // the scope it runs in (Started only; nil: none); valid during the call only
	initiator:   ^Environment,      // Started: the document that asked (nil: the browser itself, a navigation)
	method:      string,            // Started
	url:         string,            // the URL the request has now (the final one after redirects, on Response); valid during the call
	destination: Destination,
	status:      int,               // Response
	mime:        string,            // Response: the essence of the Content-Type ("" when none); valid during the call
	cache:       Cache_Outcome,     // Response
	redirected:  bool,              // Response
	redirects:   int,               // Response: how many redirects the request followed
	bytes:       int,               // Done: the body's size; Response / Failed: what arrived so far
	error:       Error_Kind,        // Failed
	detail:      string,            // Failed: valid during the call
}

Observer :: struct {
	user:  rawptr,
	event: proc(user: rawptr, ev: ^Observed),
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
