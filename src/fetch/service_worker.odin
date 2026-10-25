package fetch

// Service workers' interception point (Fetch Standard "HTTP fetch", step "if request's service-workers mode is all"):
// before an http(s) request goes to the network, the page package (src/page/service_worker.odin) may take it and
// answer later with a response its service worker made (respond) or let it go on to the network (fall_back).
//
// Zero cost when no service worker can answer: one load of a counter the page package keeps (registrations with an
// active worker in this process); the hook is not even called while it is 0.

import "core:fmt"
import "wb:base"
import "wb:http"

Sw_Hook :: struct {
	// true: the hook took the task (it calls respond or fall_back later, on this thread)
	intercept: proc(t: ^Task) -> bool,
	active:    ^int,   // registrations that can answer (nil or 0: the hook is never asked)
}

sw_hook: Sw_Hook

// (run_hop) whether a service worker takes this hop.
@(private)
sw_takes :: #force_inline proc(t: ^Task) -> bool {
	if sw_hook.intercept == nil || sw_hook.active == nil || sw_hook.active^ == 0 { return false }
	if t.skip_service_worker || t.redirect_count > 0 { return false }
	if t.target.scheme != "http" && t.target.scheme != "https" { return false }
	if !sw_hook.intercept(t) { return false }
	t.stage = .Local
	return true
}

// The service worker answered: the response the page's script made goes to the task as if it came from the network
// (a basic response: the worker's own fetches already applied CORS). `headers`: "Name: value\r\n" lines.
sw_respond :: proc(l: ^Loader, h: base.Handle, status: int, headers: string, body: []byte) {
	t := base.pool_get(&l.tasks, h)
	if t == nil { return }
	raw := http.headers_make(context.temp_allocator)
	rest := headers
	for len(rest) > 0 {
		end := 0
		for end < len(rest) && rest[end] != '\n' { end += 1 }
		line := rest[:end]
		rest = rest[min(end + 1, len(rest)):]
		if len(line) > 0 && line[len(line) - 1] == '\r' { line = line[:len(line) - 1] }
		colon := -1
		for c, i in line { if c == ':' { colon = i; break } }
		if colon <= 0 { continue }
		v := line[colon + 1:]
		for len(v) > 0 && v[0] == ' ' { v = v[1:] }
		http.append_header(&raw, line[:colon], v)
	}
	ct, _ := http.get_header(raw, "content-type")
	m, has := http.parse_mime(ct, context.temp_allocator)
	if why, ok := check_task_mime(t, m, has, false); !ok { fail(t, .Bad_Mime, why); return }
	t.taint = .Basic
	send_response(t, status, raw, m, has)
	cur := base.pool_get(&l.tasks, h)
	if cur == nil { return }
	if cur.collect {
		append(&cur.collected, ..body)
	} else if len(body) > 0 {
		ev := Event{kind = .Data, data = body}
		deliver(cur, &ev)
		if cur = base.pool_get(&l.tasks, h); cur == nil { return }
	}
	done := Event{kind = .Done}
	if cur.collect { done.data = cur.collected[:] }
	deliver(cur, &done)
	release(l, h)
}

// The service worker did not answer (no respondWith, or it gave up): the request goes on to the network.
sw_fall_back :: proc(l: ^Loader, h: base.Handle) {
	t := base.pool_get(&l.tasks, h)
	if t == nil { return }
	t.stage = .Created
	t.skip_service_worker = true
	http_hop(t)
}

// The service worker failed the request (respondWith rejected, or a Response.error()): a network error.
sw_fail :: proc(l: ^Loader, h: base.Handle, why: string) {
	t := base.pool_get(&l.tasks, h)
	if t == nil { return }
	fail(t, .Transport, fmt.tprintf("the service worker failed the request: %s", why))
}
