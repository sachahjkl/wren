package fetch

// A content blocker's view of the loader: the browser installs one `Interceptor` on the Loader and every request is
// offered to it before anything leaves the machine (before DNS, before the connection), at the first hop and again after
// each redirect; the answer's headers are offered too (for `$header` filters and policies a filter adds). With no
// interceptor the cost is one pointer test per hop.
//
// The interceptor is the only thing here that knows about filters: the loader just carries out the decision (an error
// the page sees as a network error and the DevTools as net::ERR_BLOCKED_BY_CLIENT, a neutral stand-in answer, another
// URL). The same interface is what a future extension API (webRequest, declarativeNetRequest) plugs into.

import "wb:base"
import "wb:http"
import "wb:url"

Intercept_Action :: enum u8 {
	Allow,
	Block,     // fail the request: Error_Kind.Blocked_By_Client
	Replace,   // answer with `status`, `mime`, `body` instead of the network
	Rewrite,   // continue with `new_url`
}

// What the interceptor is told about a request. Strings are valid during the call.
Intercept_Query :: struct {
	id:          u64,             // the request's id as the observer reports it (0: a WebSocket)
	url:         string,
	method:      string,
	destination: Destination,
	mode:        Mode,
	initiator:   ^Environment,    // the document asking (nil: the browser UI)
	scope:       ^base.Scope,     // the scope the request runs in (a document's, or a navigation's): lets the blocker find the tab
	redirected:  bool,            // this URL is the target of a redirect
	ping:        bool,            // a beacon / hyperlink ping
	websocket:   bool,
}

Intercept_Result :: struct {
	action:   Intercept_Action,
	reason:   string,             // Block / Replace / Rewrite: the rule responsible, for the console and the DevTools
	status:   int,                // Replace
	mime:     string,             // Replace
	body:     []byte,             // Replace (read during the call; copied)
	new_url:  string,             // Rewrite
	csp:      []string,           // response: policies to add to the document's answer (`$csp`)
}

Interceptor :: struct {
	user:     rawptr,
	request:  proc(user: rawptr, q: ^Intercept_Query, r: ^Intercept_Result),
	response: proc(user: rawptr, q: ^Intercept_Query, headers: http.Headers, r: ^Intercept_Result),
	// A document (or frame) exists: `env` is its Environment (valid until `document_end`), `scope` its scope. The
	// scope's parents lead to the frame's parent document and to the tab.
	document_begin: proc(user: rawptr, env: ^Environment, scope: ^base.Scope),
	document_end:   proc(user: rawptr, env: ^Environment),
}

document_begin :: proc(l: ^Loader, env: ^Environment, scope: ^base.Scope) {
	if l != nil && l.interceptor.document_begin != nil { l.interceptor.document_begin(l.interceptor.user, env, scope) }
}

document_end :: proc(l: ^Loader, env: ^Environment) {
	if l != nil && l.interceptor.document_end != nil { l.interceptor.document_end(l.interceptor.user, env) }
}

@(private)
intercept_query :: proc(t: ^Task) -> Intercept_Query {
	return Intercept_Query{
		id = t.obs_id, url = t.target.href, method = t.method, destination = t.destination, mode = t.mode,
		initiator = t.initiator, scope = t.scope, redirected = t.redirected, ping = t.ping,
	}
}

// Offers the current URL of the task to the interceptor. False when the task was failed, answered or is being redirected
// to another URL (the caller must stop: `run_hop` has been taken over); true to carry on.
@(private)
intercept_hop :: proc(t: ^Task) -> bool {
	l := t.loader
	if l.interceptor.request == nil { return true }
	t_scheme := t.target.scheme
	if t_scheme != "http" && t_scheme != "https" { return true }
	q := intercept_query(t)
	r: Intercept_Result
	l.interceptor.request(l.interceptor.user, &q, &r)
	switch r.action {
	case .Allow: return true
	case .Block:
		fail(t, .Blocked_By_Client, r.reason != "" ? r.reason : "blocked by the content blocker")
		return false
	case .Replace:
		t.taint = .Basic
		synthetic(t, r.status == 0 ? 200 : r.status, r.mime, r.body)
		return false
	case .Rewrite:
		if next, ok := url.parse_absolute(r.new_url); ok {
			url.destroy(&t.target)
			t.target = next
			t.rewritten = true
		}
		return true
	}
	return true
}

// The answer's headers, for the interceptor: false when the task was failed. Adds the policies it asks for to `raw`.
@(private)
intercept_response :: proc(t: ^Task) -> bool {
	l := t.loader
	if l.interceptor.response == nil || (t.target.scheme != "http" && t.target.scheme != "https") { return true }
	q := intercept_query(t)
	r: Intercept_Result
	l.interceptor.response(l.interceptor.user, &q, t.raw_headers, &r)
	if r.action == .Block {
		fail(t, .Blocked_By_Client, r.reason != "" ? r.reason : "blocked by the content blocker")
		return false
	}
	for p in r.csp { http.append_header(&t.raw_headers, "Content-Security-Policy", p) }
	return true
}
