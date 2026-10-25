package page

// Dedicated workers whose script is JavaScript (HTML "workers"). The machinery is worker.odin's (a thread, a realm
// Page without a document, the link and its two queues, the requests relayed to the UI thread); here:
//   * new Worker(url) from a page's JavaScript: the script is fetched as a classic script (HTML's MIME rules), and
//     the worker's thread starts an engine instance as a Worker realm (DedicatedWorkerGlobalScope) and runs it;
//   * messages are structured-clone bytes (native/js/runtime/clone.c) carried as the message's text;
//   * importScripts(url): fetched through the UI thread like the worker's other requests, but synchronously: the
//     worker waits for that request alone (its other messages and its timers wait their turn), as HTML requires.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import "wb:base"
import "wb:host"
import "wb:http"
import "wb:url"

Worker_createScript :: proc(c: ^Call, u: string, name: string, type: Api_WorkerType) -> (u64, Api_Error) {
	p := c.page
	if p.worker != nil { return 0, fail(c, .Not_Supported, "NotSupportedError: nested workers are not supported") }
	if _, ok := url.parse(u, &p.env.location, context.temp_allocator); !ok {
		return 0, fail(c, .Syntax, fmt.tprintf("SyntaxError: %q is not a valid URL", u))
	}
	h := worker_create(p, u, name, c.owner, javascript = true, module = type == .Module)
	if h == 0 { return 0, fail(c, .Not_Allowed, "the worker was refused (see the console)") }
	return h, .None
}

Worker_postSerialized :: proc(c: ^Call, worker: u64, data: []u8) -> Api_Error {
	p := c.page
	if p.worker != nil { return fail(c, .Invalid_Argument, "a worker posts with DedicatedWorkerGlobalScope_postSerialized") }
	return dom_error(worker_post(p, worker, string(data), nil))
}

DedicatedWorkerGlobalScope_postSerialized :: proc(c: ^Call, data: []u8) -> Api_Error {
	if c.page.worker == nil { return fail(c, .Invalid_Argument, "not in a worker") }
	return dom_error(worker_post_to_page(c.page, string(data), nil))
}

// The worker's thread: its realm, then its script. False when the realm could not start.
js_worker_start :: proc(p: ^Page, g: ^Worker_Global) -> bool {
	r := js_realm(p)
	if r == nil {
		if !realm_halted(p) { worker_send_error(g, "Worker: JavaScript could not start in the worker") }
		return false
	}
	if g.module {
		g.waiting = true
		js_worker_module_start(p, g.url, g.image)   // js_load_modules.odin: runs once its imports arrived
		return true
	}
	st := js_run(p, g.image, g.url)
	if st == .Syntax_Error && g.shared {
		// HTML: a shared worker's script that does not parse fires a plain error event at its SharedWorker objects
		m := new(Worker_Msg)
		m.kind, m.code = .Error, 1
		m.text, m.text2 = strings.clone("the shared worker's script does not parse"), strings.clone(g.url)
		link_send(g.link, false, m)
	}
	sw_script_ran(p)   // service_worker.odin: a service worker's events may come now
	return true
}

WorkerGlobalScope_isModule :: proc(c: ^Call) -> bool { return c.page.worker != nil && c.page.worker.module }

// UI thread: the worker of Worker object `w` is gone; the realm may let go of the object.
js_worker_gone :: proc(p: ^Page, w: u64) {
	r := p.js
	if r == nil || r.failed || r.inst == nil || r.inst.dead { return }
	argv := [2]u32{u32(w), u32(w >> 32)}
	js_call(p, r.inst, "wj_worker_gone", argv[:])
}

////////////////////////////////
// importScripts

WorkerGlobalScope_importScript :: proc(c: ^Call, u: string) -> (string, Api_Error) {
	p := c.page
	g := p.worker
	if g == nil { return "", fail(c, .Invalid_Argument, "not in a worker") }
	if g.module { return "", fail(c, .Type, "TypeError: importScripts() is not allowed in module workers (use import)") }
	resolved, ok := url.parse(u, &p.env.location, context.temp_allocator)
	if !ok { return "", fail(c, .Syntax, fmt.tprintf("SyntaxError: %q is not a valid URL", u)) }
	final_url, body, why := worker_fetch_sync(p, resolved.href)
	if why != "" { return "", fail(c, .Network, fmt.tprintf("NetworkError: importScripts(%q): %s", resolved.href, why)) }
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, final_url)
	strings.write_byte(&sb, 0)
	strings.write_string(&sb, string(body))
	return strings.to_string(sb), .None
}

// A request of the worker waited for synchronously: its final URL and body (temporary), or why it failed. Only the
// events of this request are taken from the worker's queue meanwhile; the rest stays there, in order.
@(private)
worker_fetch_sync :: proc(p: ^Page, target: string) -> (final_url: string, body: []byte, why: string) {
	g := p.worker
	l := g.link
	h, f := base.pool_insert(&p.fetches, Fetch{page = p, instance = max(u32)})
	f.self = h
	defer {
		if rec := base.pool_get(&p.fetches, h); rec != nil {
			fetch_abort(p, rec)
			p.held -= len(rec.body)
			removed, _ := base.pool_remove(&p.fetches, h)
			free_fetch(&removed)
		}
	}
	// HTML "fetch a classic worker-imported script": destination script, mode no-cors, credentials include (a script
	// of another origin is imported as a page's classic script is: opaque, run all the same)
	worker_fetch_start(p, f, target, "GET", "", nil, 2 | 2 << 2 | FETCH_OPTION_CLASSIC_SCRIPT)
	limit := p.settings.js_load.import_scripts_ms
	start := time.tick_now()
	for {
		rec := base.pool_get(&p.fetches, h)
		if rec == nil || rec.state >= 2 { break }
		if link_stopping(l) { return "", nil, "the worker is stopping" }
		if limit >= 0 && i64(time.duration_milliseconds(time.tick_since(start))) > limit {
			return "", nil, "timed out (javascript.workers.import_scripts_timeout_ms)"
		}
		sync.atomic_store(&l.loop.pending, false)
		mine := make([dynamic]^Worker_Msg, context.temp_allocator)
		sync.mutex_lock(&l.mu)
		rest := make([dynamic]^Worker_Msg, 0, len(l.to_worker))
		for m in l.to_worker {
			if m.kind == .Fetch_Event && m.id == u64(h) { append(&mine, m); l.worker_bytes -= m.size } else { append(&rest, m) }
		}
		delete(l.to_worker)
		l.to_worker = rest
		sync.mutex_unlock(&l.mu)
		for m in mine { worker_fetch_event(p, m); msg_free(m) }
		if rec = base.pool_get(&p.fetches, h); rec == nil || rec.state >= 2 { break }
		sync.sema_wait_with_timeout(&l.loop.sema, 50 * time.Millisecond)
	}
	host_signal_after_wait(p)
	rec := base.pool_get(&p.fetches, h)
	if rec == nil { return "", nil, "the request was lost" }
	if rec.state == 3 { return "", nil, strings.clone(rec.error, context.temp_allocator) }
	if rec.type != .Opaque && (rec.status < 200 || rec.status >= 300) { return "", nil, fmt.tprintf("HTTP %d", rec.status) }
	// a classic script's MIME rules (the request itself is a plain fetch)
	mime := header_value(rec.headers, "content-type")
	nosniff := strings.equal_fold(strings.trim_space(header_value(rec.headers, "x-content-type-options")), "nosniff")
	if m, okm := http.parse_mime(mime, context.temp_allocator); okm {
		js_type := false
		for t in js_mime_types { if strings.concatenate({m.type, "/", m.subtype}, context.temp_allocator) == t { js_type = true } }
		if m.type == "audio" || m.type == "image" || m.type == "video" || (m.type == "text" && m.subtype == "csv") || (nosniff && !js_type) {
			return "", nil, fmt.tprintf("its MIME type %s/%s is not a script's", m.type, m.subtype)
		}
	} else if nosniff {
		return "", nil, "nosniff without a JavaScript MIME type"
	}
	body = make([]byte, len(rec.body), context.temp_allocator)
	copy(body, rec.body[:])
	return strings.clone(rec.final_url != "" ? rec.final_url : target, context.temp_allocator), body, ""
}

// What the wait swallowed (a wake) is given back: the worker's loop looks at its queues again. Always: the wait also
// consumed the wakes of tasks posted to the loop itself (rejection checks, decoded images), not only of the link's queue.
@(private)
host_signal_after_wait :: proc(p: ^Page) {
	g := p.worker
	sync.atomic_store(&g.link.loop.pending, false)
	host.signal(&g.link.loop)
}

// The value of a header in "Name: value" CR LF lines ("" when absent).
@(private)
header_value :: proc(lines: string, name: string) -> string {
	text := lines
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_right(line, "\r")
		colon := strings.index_byte(l, ':')
		if colon <= 0 { continue }
		if strings.equal_fold(strings.trim_space(l[:colon]), name) { return strings.trim_space(l[colon + 1:]) }
	}
	return ""
}
