package fetch

// What the browser's developer tools see of the loader: one call per step of a request (started, answered, done,
// failed), from the loop thread, whatever asked (the document, a script, an image, a font, a worker). The shell turns
// them into the Network panel's rows. Nothing here changes what a request does; with no observer it costs a test.

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
	method:      string,            // Started
	url:         string,            // the URL the request has now (the final one after redirects, on Response); valid during the call
	destination: Destination,
	status:      int,               // Response
	mime:        string,            // Response: the essence of the Content-Type ("" when none); valid during the call
	cache:       Cache_Outcome,     // Response
	redirected:  bool,              // Response
	bytes:       int,               // Done: the body's size; Response / Failed: what arrived so far
	error:       Error_Kind,        // Failed
	detail:      string,            // Failed: valid during the call
}

Observer :: struct {
	user:  rawptr,
	event: proc(user: rawptr, ev: ^Observed),
}

@(private)
observe :: proc(t: ^Task, ev: Observed) {
	l := t.loader
	if l == nil || l.observer.event == nil { return }
	e := ev
	e.id = t.obs_id
	l.observer.event(l.observer.user, &e)
}
