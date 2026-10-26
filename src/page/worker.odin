package page

// Dedicated workers (HTML Living Standard §10): a page starts a Wasm module on a thread of its own and talks to it with
// messages. No memory is shared: text is copied, transferred buffers change owner (the sender's buffer is detached).
//
// The two halves:
//   * UI thread: a Worker object in the page (an EventTarget: message, messageerror, error) backed by a Worker_Host. The
//     host fetches the module (same origin or data:, application/wasm, CSP worker-src), starts the thread, makes the
//     worker's requests (the loader lives on this thread) with the worker's own Environment, and relays its console.
//   * Worker thread: a Page without a document (the realm: objects, promises, microtasks, timers, buffers, console,
//     fetch records), its own host.Loop and its own Wasm instance. Every import gets that Page as its Call's page, so
//     the asynchronous core works unchanged; imports that need a document answer with an error. A worker module may
//     only import what the API description exposes to workers ([Exposed=Worker] in api/*.widl), since host functions
//     are registered once for the whole process.
//
// Between them, a Worker_Link (heap, reference counted: the host and the thread each hold one, and so does every drain
// task posted on the UI loop) with two queues guarded by a mutex. The page side is woken with host.post, the worker side
// with host.signal on its loop. Nothing on one thread ever points into the other's memory.
//
// Termination: a stop flag checked before every task, callback and microtask of the worker. The same flag interrupts a
// task already running (epoch interruption, within wasm.wasmtime.epoch_tick_ms). Closing a
// page stops every worker and joins its thread; `Worker_terminate` and releasing the Worker object do not block the UI:
// the thread is joined when it reports its exit.

import "core:fmt"
import "core:strings"
import "core:sync"
import "wb:base"
import "wb:csp"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:http"
import "wb:js"
import "wb:url"

////////////////////////////////
// Messages between the two threads

Worker_Msg_Kind :: enum u8 {
	Message,        // both ways: text + transferred buffers
	Error,          // worker -> page: an uncaught error (text = message, text2 = script URL)
	Console,        // worker -> page: a console line (code = Log_Level)
	Closed,         // worker -> page: the worker called close()
	Exited,         // worker -> page: the thread is returning
	Fetch_Start,    // worker -> page: id, text = URL, text2 = method, text3 = headers, bytes = body, code = options
	Fetch_Cancel,   // worker -> page: id
	Fetch_Event,    // page -> worker: id, code = fetch.Event_Kind (see `relay_event`)
	Port_Wake,      // router -> worker: a message waits for the port end id (ports.odin)
	Sw_Event,       // page -> service worker: an event to fire (service_worker.odin)
	Sw_Reply,       // service worker -> page: what it did (service_worker.odin)
	Connect,        // page -> shared worker: a new connection, ports[0] is its port's end (shared_worker.odin)
	Sw_Client,      // page -> worker: a message of a service worker to it as a client (id = the version, bytes)
	Sw_Post,        // worker -> page: serviceWorker.postMessage from a worker client (id = the version, bytes)
	Child_Create,   // worker -> page: new Worker() in the worker (nested_workers.odin): id = the child's link (a reference)
	Child_Event,    // page -> worker: what its child sent (id = the child's link; code 0 message, 1 error, 2 gone)
	Child_Terminate,// worker -> page: terminate() of a child (id = its link; code 1: its Worker object is gone too)
}

Worker_Msg :: struct {
	kind:    Worker_Msg_Kind,
	id:      u64,
	code:    i64,
	code2:   i64,
	text:    string,
	text2:   string,
	text3:   string,
	bytes:   []byte,
	buffers: [dynamic][dynamic]byte,
	ports:   []u64,  // MessagePort ends travelling with a message (ports.odin); closed if never delivered
	size:    int,    // counted against workers.max_pending_bytes while queued
}

@(private)
msg_free :: proc(m: ^Worker_Msg) {
	if m.kind == .Child_Create && m.id != 0 { link_release((^Worker_Link)(uintptr(m.id))) }   // never delivered
	delete(m.text); delete(m.text2); delete(m.text3); delete(m.bytes)
	for b in m.buffers { delete(b) }
	delete(m.buffers)
	for x in m.ports { port_close_end(x) }
	delete(m.ports)
	free(m)
}

Worker_Link :: struct {
	refs:        i32,                    // atomic
	mu:          sync.Mutex,
	to_worker:   [dynamic]^Worker_Msg,
	to_page:     [dynamic]^Worker_Msg,
	worker_bytes: int,                   // queued sizes, per direction
	page_bytes:  int,
	page_wake:   bool,                   // a drain task is posted on the UI loop
	stop:        b32,                    // atomic: run nothing more (terminate, close(), page closed)
	loop:        host.Loop,              // the worker's event loop
	ui_loop:     ^host.Loop,
	host:        ^Worker_Host,           // UI thread only; nil once the page side is gone
	max_pending: int,
}

@(private)
link_make :: proc(ui_loop: ^host.Loop, max_pending: int) -> ^Worker_Link {
	l := new(Worker_Link)
	l.refs = 1
	l.ui_loop = ui_loop
	l.max_pending = max_pending
	host.loop_init(&l.loop)
	return l
}

@(private)
link_retain :: proc(l: ^Worker_Link) { sync.atomic_add(&l.refs, 1) }

@(private)
link_release :: proc(l: ^Worker_Link) {
	if sync.atomic_sub(&l.refs, 1) != 1 { return }
	for m in l.to_worker { msg_free(m) }
	for m in l.to_page { msg_free(m) }
	delete(l.to_worker)
	delete(l.to_page)
	host.loop_destroy(&l.loop)
	free(l)
}

@(private)
link_stopping :: #force_inline proc "contextless" (l: ^Worker_Link) -> bool { return bool(sync.atomic_load(&l.stop)) }

@(private)
link_halt :: proc(l: ^Worker_Link) {
	sync.atomic_store(&l.stop, true)
	host.signal(&l.loop)
}

// Queues `m`. Guest messages (`limited`) are refused, and `m` is left to the caller, when the receiver already has
// workers.max_pending_bytes waiting.
@(private)
link_send :: proc(l: ^Worker_Link, to_worker: bool, m: ^Worker_Msg, limited := false) -> bool {
	post := false
	sync.mutex_lock(&l.mu)
	pending := to_worker ? &l.worker_bytes : &l.page_bytes
	if limited && pending^ + m.size > l.max_pending { sync.mutex_unlock(&l.mu); return false }
	pending^ += m.size
	if to_worker {
		append(&l.to_worker, m)
	} else {
		append(&l.to_page, m)
		if !l.page_wake { l.page_wake, post = true, true; link_retain(l) }
	}
	sync.mutex_unlock(&l.mu)
	if to_worker { host.signal(&l.loop) } else if post { host.post(l.ui_loop, link_page_drain, l) }
	return true
}

// Takes everything queued for one side.
@(private)
link_take :: proc(l: ^Worker_Link, to_worker: bool, into: ^[dynamic]^Worker_Msg) {
	sync.mutex_lock(&l.mu)
	if to_worker {
		l.to_worker, into^ = into^, l.to_worker
		l.worker_bytes = 0
	} else {
		l.to_page, into^ = into^, l.to_page
		l.page_bytes = 0
		l.page_wake = false
	}
	sync.mutex_unlock(&l.mu)
}

////////////////////////////////
// Page side

Worker_State :: enum u8 { Loading, Running, Closed, Exited }

Worker_Host :: struct {
	page:       ^Page,
	self:       u64,                    // the Worker object; 0 once the guest released it
	owner:      u32,                    // instance that created it
	link:       ^Worker_Link,
	thread:     ^host.Thread,
	url:        string,                 // the module's URL (the response URL once fetched)
	name:       string,
	env:        fetch.Environment,      // the worker's environment: its requests are made with it
	script:     base.Handle,            // the module's fetch, NIL when finished
	status:     int,                    // HTTP status of the module's response
	state:      Worker_State,
	terminated: bool,                   // no event reaches the page any more
	relays:     map[u64]^Relay,         // the worker's requests in flight, by the worker's fetch handle
	counted:    bool,                   // holds a slot of the process-wide count
	javascript: bool,                   // its script is JavaScript (js_workers.odin), not a Wasm module
	pins:       int,                    // being worked on (a message, an error event): not freed before it is unpinned
	sw:         ^Sw_Version,            // the service worker version this runs (service_worker.odin), nil for a Worker
	shared:     ^Shared_Worker,         // the shared worker this runs (shared_worker.odin), nil for a Worker
	module:     bool,                   // its script is a module ({type: "module"}): js_workers.odin
	storage_key: string,                // owned: the storage key of its realm when not its page's (a shared worker's)
	client_id:  u64,                    // its id as a service worker's client (service_worker.odin)
	parent:     ^Worker_Host,           // a nested worker's: the worker that made it (nested_workers.odin), nil else
	ref_held:   bool,                   // a nested worker's Worker object still exists in its parent's realm
	ref_id:     u64,                    // a nested worker's name in its parent's realm (its link's address)
	depth:      int,                    // 1 for a document's worker, its parent's + 1 for a nested one
}

Relay :: struct {
	host: ^Worker_Host,
	id:   u64,
	task: base.Handle,
	internal: bool,   // a script the browser runs (importScripts): its body goes to the worker even when opaque
}

// What a page keeps of its workers. Hosts stay listed until their thread is joined and their object released.
Page_Workers :: struct {
	hosts:      [dynamic]^Worker_Host,
	deliveries: [dynamic]Delivery,      // messages being dispatched (MessageEvent_transfer)
}

Delivery :: struct {
	first:   u64,     // Event_object of the message event
	buffers: []u64,
	ports:   []u64,   // MessagePort ends that came with it (ports.odin)
	ports_taken: bool,
}

// Workers running in the whole process (workers.max_total).
@(private)
worker_total: i32

// Worker clients' ids (SW_WORKER_CLIENT_BASE + n: above every page's id).
@(private)
worker_client_next: u64

worker_vt := Object_VTable{
	name = "Worker",
	destroy = proc(p: ^Page, data: rawptr) {
		h := (^Worker_Host)(data)
		h.self = 0
		if p.closed { return }   // workers_destroy stops and joins everything next
		worker_terminate(h)
		worker_maybe_free(h)
	},
}

// Workers holding a slot in the whole process (started or starting, not yet joined).
workers_running :: proc() -> int { return int(sync.atomic_load(&worker_total)) }

// Workers this page runs (not yet stopped).
@(private)
page_worker_count :: proc(p: ^Page) -> int {
	n := 0
	for h in p.workers.hosts { if !h.terminated && h.state != .Exited { n += 1 } }
	return n
}

// Starts a dedicated worker running the module at `src` (resolved against the document). Returns the Worker object,
// or 0 when the browser refuses (workers disabled, too many, invalid or cross-origin URL); the reason is logged.
// `image`: the script the browser already has (a service worker's stored version): it starts at once, nothing is fetched.
worker_create :: proc(p: ^Page, src: string, name: string, owner: u32, javascript := false, module := false, image: []byte = nil, sw: ^Sw_Version = nil, shared: ^Shared_Worker = nil) -> u64 {
	// in a worker: a nested worker, started by the interface thread for this realm (nested_workers.odin)
	if p.worker != nil { return nested_worker_request(p, src, name, owner, javascript, module, image) }
	ws := &p.settings.workers
	if why := worker_refused(p, javascript); why != "" { log(p, .Error, why); return 0 }
	u, ok := url.parse(src, &p.env.location, context.temp_allocator)
	if !ok { log(p, .Error, fmt.tprintf("Worker: invalid URL %q", src)); return 0 }
	if u.scheme != "data" {
		o := url.origin_of(u, context.temp_allocator)
		if !url.same_origin(o, p.env.origin) {
			log(p, .Error, fmt.tprintf("Worker: %s is not same-origin with the document (SecurityError)", u.href)); return 0
		}
	}
	if !worker_take_slot(ws) {
		log(p, .Error, fmt.tprintf("Worker: the browser already runs %d workers (workers.max_total)", ws.max_total)); return 0
	}
	h := worker_host_new(p, u, name, javascript, module, link_make(p.loop, ws.max_pending_bytes), &p.env)
	h.owner, h.sw, h.shared = owner, sw, shared
	if shared != nil { h.storage_key = strings.clone(shared.key) }   // (a shared worker's realm: its documents' storage key)
	h.self = object_create(p, &worker_vt, h, owner)
	worker_host_load(h, image, &p.env)
	return h.self
}

// Why page `p` may not start one more worker ("" when it may).
@(private)
worker_refused :: proc(p: ^Page, javascript: bool) -> string {
	ws := &p.settings.workers
	if p.loader == nil { return "Worker: this page cannot load anything" }
	if !ws.enabled { return "Worker: workers are disabled (workers.enabled)" }
	if javascript && !p.settings.js.workers { return "Worker: JavaScript workers are disabled (javascript.workers.enabled)" }
	if page_worker_count(p) >= ws.max_per_page { return fmt.tprintf("Worker: this page already runs %d workers (workers.max_per_page)", ws.max_per_page) }
	return ""
}

// A slot of workers.max_total (false: none left).
@(private)
worker_take_slot :: proc(ws: ^Worker_Settings) -> bool {
	if int(sync.atomic_add(&worker_total, 1)) >= ws.max_total { sync.atomic_sub(&worker_total, 1); return false }
	return true
}

// A host for a worker of page `p` running `u` over `link` (the host takes that reference), listed in the page.
// `creator`: the environment of whoever made it (a data: worker inherits its policies).
@(private)
worker_host_new :: proc(p: ^Page, u: url.URL, name: string, javascript, module: bool, link: ^Worker_Link, creator: ^fetch.Environment) -> ^Worker_Host {
	h := new(Worker_Host)
	h.page, h.counted, h.javascript, h.module, h.depth = p, true, javascript, javascript && module, 1
	h.url, h.name = strings.clone(u.href), strings.clone(name)
	worker_client_next += 1
	h.client_id = SW_WORKER_CLIENT_BASE + worker_client_next
	h.link = link
	h.link.host = h
	h.env = fetch.environment_make(u, creator.referrer_policy)
	h.env.on_violation = worker_csp_violation
	h.env.violation_user = h
	if u.scheme == "data" {
		// a data: worker has an opaque origin and inherits the policies of its creator
		for pol in creator.policies.policies { append(&h.env.policies.policies, csp.parse_policy(pol.raw, pol.disposition)) }
	}
	h.relays = make(map[u64]^Relay)
	append(&p.workers.hosts, h)
	return h
}

// Starts the worker of `h`: at once with `image` (the script the browser already has), else once its script is
// fetched for `initiator`.
@(private)
worker_host_load :: proc(h: ^Worker_Host, image: []byte, initiator: ^fetch.Environment) {
	p := h.page
	if image != nil {
		h.status = 200
		worker_spawn(h, image)
		return
	}
	// (a module worker's script must have a JavaScript MIME type: HTML "fetch a module worker script graph")
	h.script = fetch.start(p.loader, {
		request = {url = h.url, mode = .Same_Origin, credentials = .Same_Origin, destination = .Worker, initiator = initiator,
			script = h.module ? .Module : (h.javascript ? .Classic : .Wasm)},
		on_event = worker_script_event, user = h, scope = p.scope, collect = true,
	})
}

@(private)
worker_csp_violation :: proc(user: rawptr, v: csp.Violation) {
	h := (^Worker_Host)(user)
	if h.page != nil { csp_violation(h.page, v) }
}

@(private)
worker_script_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	h := (^Worker_Host)(user)
	p := h.page
	#partial switch ev.kind {
	case .Response:
		r := ev.response
		h.status = r.status
		if r.url != "" && r.url != h.url { delete(h.url); h.url = strings.clone(r.url) }
		if !h.env.origin.opaque && csp_on(p) {
			// the worker's own policy comes from its script's response (HTML: "initialize worker policy container")
			for v in http.get_all(r.headers, "content-security-policy") { csp.parse_header(&h.env.policies, v, .Enforce) }
			for v in http.get_all(r.headers, "content-security-policy-report-only") { csp.parse_header(&h.env.policies, v, .Report_Only) }
		}
	case .Failed:
		h.script = base.NIL_HANDLE
		worker_failed(h, fmt.tprintf("Worker: %s: %s", h.url, ev.detail))
	case .Done:
		h.script = base.NIL_HANDLE
		if h.status < 200 || h.status >= 300 { worker_failed(h, fmt.tprintf("Worker: %s: HTTP %d", h.url, h.status)); return }
		worker_spawn(h, ev.data)
	}
	_ = p
}

// The worker could not start: an `error` event at the Worker object, and the slot is given back.
@(private)
worker_failed :: proc(h: ^Worker_Host, message: string) {
	h.state = .Exited
	worker_uncount(h)
	if h.sw != nil { sw_instance_error(h, message); return }   // service_worker.odin
	if h.shared != nil { shared_failed(h, message); return }   // shared_worker.odin
	if h.parent != nil || h.ref_id != 0 { nested_failed(h, message); return }   // nested_workers.odin
	worker_fire_error(h, message, h.url)
}

@(private)
worker_uncount :: proc(h: ^Worker_Host) {
	if h.counted { h.counted = false; sync.atomic_sub(&worker_total, 1) }
}

@(private)
worker_spawn :: proc(h: ^Worker_Host, image: []byte) {
	p := h.page
	g := new(Worker_Global)
	g.link = h.link
	g.settings = p.settings^
	g.settings.html, g.settings.style = {}, {}   // owned by the shell and changed under its feet: a worker needs neither
	g.settings.wasm = p.settings.workers.wasm
	g.javascript = h.javascript
	g.storage = p.web.embedder.storage
	g.storage_key = strings.clone(h.storage_key != "" ? h.storage_key : storage_origin_key(p))
	// the JavaScript settings' lists are the shell's, changed under the worker's feet: a copy of its own
	if g.javascript { g.settings.js = js.settings_clone(p.settings.js) } else { g.settings.js = {} }
	// the other strings the shell owns (freed when its preferences change): copies, or nothing a worker reads
	g.settings.js_web.platform = strings.clone(p.settings.js_web.platform)
	g.settings.js_web.vendor = strings.clone(p.settings.js_web.vendor)
	g.settings.forms.password_mask = ""
	g.settings.sw.fs_permission = ""
	g.url, g.name = strings.clone(h.url), strings.clone(h.name)
	g.module, g.shared, g.depth = h.module, h.shared != nil, h.depth
	// service_worker.odin: a service worker's instance, or another worker's view as a client of its document's controller
	if h.sw != nil { sw_global_init(&g.sw, h.sw) } else { sw_client_init(g, p) }
	g.image = make([]byte, len(image))
	copy(g.image, image)
	link_retain(h.link)
	h.state = .Running
	h.thread = host.thread_start(worker_main, g, p.settings.workers.thread_stack_bytes, p.settings.workers.priority, "wren-js-worker")
	if h.thread == nil {
		worker_global_free(g)
		link_release(h.link)
		worker_failed(h, "Worker: could not start a thread")
	}
}

// Stops the worker without waiting for it: nothing it does reaches the page any more.
@(private)
worker_terminate :: proc(h: ^Worker_Host) {
	if h.terminated { return }
	h.terminated = true
	link_halt(h.link)
	nested_terminate_children(h)   // nested_workers.odin
	if h.script != base.NIL_HANDLE { fetch.cancel(h.page.loader, h.script); h.script = base.NIL_HANDLE }
	relays_cancel(h)
	if h.thread == nil && h.state != .Running { h.state = .Exited; worker_uncount(h) }
}

@(private)
relays_cancel :: proc(h: ^Worker_Host) {
	for _, r in h.relays {
		if r.task != base.NIL_HANDLE { fetch.cancel(h.page.loader, r.task) }
		free(r)
	}
	clear(&h.relays)
}

// Frees the host once nothing refers to it: the guest released the object and the thread (if any) was joined.
@(private)
worker_maybe_free :: proc(h: ^Worker_Host) {
	if h.self != 0 || h.ref_held || h.thread != nil || h.state == .Running || h.pins > 0 { return }
	worker_free(h)
}

@(private)
worker_free :: proc(h: ^Worker_Host) {
	p := h.page
	for x, i in p.workers.hosts { if x == h { ordered_remove(&p.workers.hosts, i); break } }
	nested_orphan(h)   // its children lose their parent (nested_workers.odin)
	if h.script != base.NIL_HANDLE { fetch.cancel(p.loader, h.script) }
	relays_cancel(h)
	delete(h.relays)
	worker_uncount(h)
	fetch.environment_destroy(&h.env)
	delete(h.url)
	delete(h.name)
	delete(h.storage_key)
	h.link.host = nil
	link_release(h.link)
	free(h)
}

// Page closing: every worker stops, every thread is joined, nothing is left behind.
@(private)
workers_destroy :: proc(p: ^Page) {
	for h in p.workers.hosts { worker_terminate(h) }
	for len(p.workers.hosts) > 0 {
		h := p.workers.hosts[len(p.workers.hosts) - 1]
		if h.thread != nil { host.thread_join(h.thread); h.thread = nil }
		h.state = .Exited
		worker_free(h)
	}
	delete(p.workers.hosts)
	delete(p.workers.deliveries)
}

// UI loop: what the worker sent.
@(private)
link_page_drain :: proc(data: rawptr) {
	l := (^Worker_Link)(data)
	batch: [dynamic]^Worker_Msg   // swapped with the queue: its storage becomes the link's, so not temporary memory
	defer delete(batch)
	link_take(l, false, &batch)
	for m in batch {
		// pinned while its message is handled: a listener or the JavaScript collector may release the Worker object
		if h := l.host; h != nil {
			h.pins += 1
			page_receive(h, m)
			if l.host == h { h.pins -= 1; worker_maybe_free(h) }   // else the page closed meanwhile and freed it
		}
		msg_free(m)
	}
	link_release(l)
}

@(private)
page_receive :: proc(h: ^Worker_Host, m: ^Worker_Msg) {
	p := h.page
	switch m.kind {
	case .Message:
		if h.terminated { return }
		if h.ref_id != 0 { nested_forward(h, m, NESTED_MESSAGE); return }   // to its parent worker
		if h.self == 0 { return }
		deliver_message(p, h.self, m, h.owner)
	case .Error:
		if h.terminated { return }
		if h.ref_id != 0 { nested_forward(h, m, NESTED_ERROR); return }
		if h.sw != nil { sw_instance_error(h, m.text); return }   // service_worker.odin
		if h.shared != nil && m.code == 1 { shared_failed(h, m.text); return }   // its script does not parse
		if h.shared != nil { log(p, .Error, fmt.tprintf("uncaught error: %s", m.text)); return }   // its clients' consoles
		worker_fire_error(h, m.text, m.text2)
	case .Console:
		log(p, Log_Level(m.code), fmt.tprintf("[worker %s] %s", worker_label(h), m.text))
	case .Closed:
		h.state = .Closed
		if h.shared != nil { shared_gone(h) }   // shared_worker.odin: a new SharedWorker() starts another one
	case .Exited:
		if h.thread != nil { host.thread_join(h.thread); h.thread = nil }
		h.state = .Exited
		if h.shared != nil { shared_gone(h) }
		if h.javascript && h.self != 0 { js_worker_gone(p, h.self) }   // its Worker object may be collected now
		if h.ref_id != 0 { nested_forward(h, m, NESTED_GONE) }   // the same in its parent worker
		relays_cancel(h)
		worker_uncount(h)
		nested_orphan(h)   // HTML: a worker that ends ends its own workers
		worker_maybe_free(h)
	case .Fetch_Start:
		if h.terminated || h.state != .Running { return }
		relay_start(h, m)
	case .Fetch_Cancel:
		if r, ok := h.relays[m.id]; ok {
			if r.task != base.NIL_HANDLE { fetch.cancel(p.loader, r.task) }
			delete_key(&h.relays, m.id)
			free(r)
		}
	case .Sw_Reply:
		if !h.terminated { sw_page_reply(h, m) }   // service_worker.odin
	case .Sw_Post:
		if !h.terminated { sw_client_post(h, m) }   // service_worker.odin
	case .Child_Create:
		nested_host_create(h, m)   // nested_workers.odin
	case .Child_Terminate:
		nested_terminate_child(h, m.id, m.code == 1)
	case .Fetch_Event, .Port_Wake, .Sw_Event, .Connect, .Sw_Client, .Child_Event:
	}
}

// How the console names a worker: its name, else its URL (shortened: a data: URL holds the whole module).
@(private)
worker_label :: proc(h: ^Worker_Host) -> string {
	if h.name != "" { return h.name }
	return len(h.url) <= 80 ? h.url : fmt.tprintf("%s...", h.url[:77])
}

@(private)
worker_fire_error :: proc(h: ^Worker_Host, message, file: string) {
	p := h.page
	allowed := true
	h.pins += 1   // a listener may release the Worker object
	if h.self != 0 { allowed = object_dispatch(p, h.self, dom.Event{type = "error", cancelable = true, data = message, text = file}) }
	if allowed {
		// HTML "run a worker": an error the Worker's error event did not cancel is reported in the owner's global (its
		// error event, window.onerror); the engine says it on the console when nobody cancels that one either
		// (an exception its script threw, "Uncaught ...": not a script that could not be fetched or parsed, which is only
		// the Worker's error)
		runtime := strings.has_prefix(message, "Uncaught") && !strings.has_prefix(message, "Uncaught SyntaxError")
		if r := p.js; h.javascript && runtime && r != nil && !r.failed && r.inst != nil && !r.inst.dead {
			worker_error_text = fmt.tprintf("%s\t%s", message, file)
			js_call(p, r.inst, "wj_worker_error_to_global", nil)
			worker_error_text = ""
		} else {
			log(p, .Error, fmt.tprintf("[worker %s] uncaught error: %s", worker_label(h), message))
		}
	}
	h.pins -= 1
	worker_maybe_free(h)
}

// A request of the worker, made here with the worker's environment; every event goes back to the worker.
@(private)
relay_start :: proc(h: ^Worker_Host, m: ^Worker_Msg) {
	r := new(Relay)
	r.host, r.id = h, m.id
	r.internal = u32(m.code) & FETCH_OPTION_CLASSIC_SCRIPT != 0
	h.relays[m.id] = r
	r.task = fetch.start(h.page.loader, {
		request = guest_request(m.text, m.text2, m.text3, m.bytes, u32(m.code), &h.env),
		on_event = relay_event, user = r, scope = h.page.scope, collect = false,
	})
}

@(private)
relay_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	r := (^Relay)(user)
	h := r.host
	m := new(Worker_Msg)
	m.kind, m.id, m.code = .Fetch_Event, r.id, i64(ev.kind)
	switch ev.kind {
	case .Response:
		res := ev.response
		m.code2 = i64(res.status) | i64(res.type) << 32 | (res.redirected ? 1 << 40 : 0) | (res.body_usable || r.internal ? 1 << 41 : 0)
		m.text = strings.clone(res.url)
		m.text2 = serialize_headers(res.headers.list[:], context.allocator)
	case .Data, .Done:
		if len(ev.data) > 0 { m.bytes = make([]byte, len(ev.data)); copy(m.bytes, ev.data) }
	case .Failed:
		m.code2 = i64(ev.error)
		m.text = strings.clone(ev.detail)
	}
	m.size = len(m.bytes)
	finished := ev.kind == .Done || ev.kind == .Failed
	if !link_send(h.link, true, m, limited = ev.kind == .Data) {
		// the worker does not keep up: stop the request rather than queue without bound
		msg_free(m)
		fetch.cancel(h.page.loader, r.task)
		fail := new(Worker_Msg)
		fail.kind, fail.id, fail.code, fail.code2 = .Fetch_Event, r.id, i64(fetch.Event_Kind.Failed), i64(fetch.Error_Kind.Body_Too_Large)
		fail.text = strings.clone("the worker is not reading its responses fast enough (workers.max_pending_bytes)")
		link_send(h.link, true, fail)
		finished = true
	}
	if finished {
		delete_key(&h.relays, r.id)
		free(r)
	}
}

////////////////////////////////
// Messages: both sides

// postMessage(text, transfer): the buffers in `transfer` move to the other side and are detached here. Fails without
// side effects when a handle is not a transferable buffer (or appears twice), the message is larger than
// workers.max_message_bytes, or the receiver has too much waiting already.
@(private)
post_message :: proc(p: ^Page, l: ^Worker_Link, to_worker: bool, text: string, transfer: []u64, ports: []u64 = nil) -> dom.Error {
	size := len(text)
	for h, i in transfer {
		b := buffer_get(p, h)
		if b == nil || b.detached { return .Invalid_Argument }
		for k in transfer[:i] { if k == h { return .Invalid_Argument } }
		size += len(b.bytes)
	}
	if size > p.settings.workers.max_message_bytes {
		log(p, .Error, fmt.tprintf("postMessage: %d bytes exceed workers.max_message_bytes", size))
		return .Invalid_Argument
	}
	m := new(Worker_Msg)
	m.kind, m.size = .Message, size
	m.text = strings.clone(text)
	sync.mutex_lock(&l.mu)
	pending := to_worker ? l.worker_bytes : l.page_bytes
	sync.mutex_unlock(&l.mu)
	if pending + size > l.max_pending {
		msg_free(m)
		log(p, .Error, "postMessage: the receiver has too many messages waiting (workers.max_pending_bytes)")
		return .Invalid_Argument
	}
	for h in transfer {
		bytes, _ := buffer_detach(p, h)
		append(&m.buffers, bytes)
	}
	if len(ports) > 0 { m.ports = make([]u64, len(ports)); copy(m.ports, ports) }
	link_send(l, to_worker, m)   // the check above stands in for the limit: the transfer cannot be undone any more
	return .None
}

// Fires `message` (or `messageerror` when the buffers do not fit in this side's memory ceiling) at `target`. The
// buffers become objects of this side, owned by `owner`; nobody listening means nobody can ever release them, so they
// are released at once.
@(private)
deliver_message :: proc(p: ^Page, target: u64, m: ^Worker_Msg, owner: u32) {
	total := 0
	for b in m.buffers { total += len(b) }
	if p.held + total > p.settings.max_fetch_bytes {
		object_dispatch(p, target, dom.Event{type = "messageerror", data = m.text})
		return
	}
	handles := make([]u64, len(m.buffers), context.temp_allocator)
	for b, i in m.buffers { handles[i] = buffer_adopt(p, b, owner) }
	clear(&m.buffers)   // moved
	first := len(handles) > 0 ? handles[0] : 0
	listened := object_has_listener(p, target, "message")
	append(&p.workers.deliveries, Delivery{first = first, buffers = handles, ports = m.ports})
	ports := m.ports
	m.ports = nil   // moved: the engine binds them (MessageEvent_portEnds), else they are closed below
	object_dispatch(p, target, dom.Event{type = "message", data = m.text, object = first, code = i64(len(handles))})
	for d, i in p.workers.deliveries {
		if d.first == first && raw_data(d.buffers) == raw_data(handles) {
			if !d.ports_taken { for x in d.ports { port_close_end(x) } }
			ordered_remove(&p.workers.deliveries, i)
			break
		}
	}
	delete(ports)
	if !listened { for h in handles { object_release(p, h) } }
}

// The i-th buffer transferred with the message event being dispatched (Event_object is the first, Event_code the count).
message_transfer :: proc(p: ^Page, ev: u64, index: int) -> u64 {
	e := base.pool_get(&p.dp.events, base.Handle(ev))
	if e == nil || e.object == 0 { return 0 }
	for i := len(p.workers.deliveries) - 1; i >= 0; i -= 1 {
		d := p.workers.deliveries[i]
		if d.first == e.object { return index >= 0 && index < len(d.buffers) ? d.buffers[index] : 0 }
	}
	return 0
}

// The delivery of the message event being dispatched (its buffers and ports), nil when none.
message_delivery :: proc(p: ^Page, ev: u64) -> ^Delivery {
	e := base.pool_get(&p.dp.events, base.Handle(ev))
	if e == nil { return nil }
	for i := len(p.workers.deliveries) - 1; i >= 0; i -= 1 {
		if p.workers.deliveries[i].first == e.object { return &p.workers.deliveries[i] }
	}
	return nil
}

// From the page: Worker.postMessage. Silently ignored once the worker is terminated or closed, as in browsers.
worker_post :: proc(p: ^Page, w: u64, text: string, transfer: []u64, ports: []u64 = nil) -> dom.Error {
	if n := nested_of(p, w); n != nil {   // a worker's own Worker object (nested_workers.odin)
		if n.terminated || n.gone { return .None }
		return post_message(p, n.link, true, text, transfer, ports)
	}
	h := (^Worker_Host)(object_data(p, w, &worker_vt))
	if h == nil { return .Invalid_Handle }
	if h.terminated || h.state == .Closed || h.state == .Exited { return .None }
	return post_message(p, h.link, true, text, transfer, ports)
}

// From the page: Worker.terminate.
worker_terminate_object :: proc(p: ^Page, w: u64) -> dom.Error {
	if n := nested_of(p, w); n != nil { nested_terminate(p, n, false); return .None }
	h := (^Worker_Host)(object_data(p, w, &worker_vt))
	if h == nil { return .Invalid_Handle }
	worker_terminate(h)
	return .None
}

////////////////////////////////
// Worker side

Worker_Global :: struct {
	link:     ^Worker_Link,
	settings: Settings,           // the worker's own copy (no html/style)
	url:      string,
	name:     string,
	image:    []byte,
	page:     ^Page,              // the worker's realm (this thread)
	self:     u64,                // the DedicatedWorkerGlobalScope object
	closing:  bool,
	inbox:    [dynamic]^Worker_Msg,
	javascript: bool,             // `image` is a JavaScript classic script (js_workers.odin)
	storage:  ^Storage_Manager,   // the creator's profile storage (IndexedDB: idb_host.odin)
	storage_key: string,         // the creator's storage key (origin, and the top-level site of a partitioned frame)
	idb_wake: b32,              // atomic: the IndexedDB manager has an event for this realm (any thread sets it)
	sw:       Sw_Global,        // a service worker's realm: what it is and the events it has to fire (service_worker.odin)
	shared:   bool,             // a shared worker's realm (SharedWorkerGlobalScope)
	module:   bool,             // `image` is the root of a module graph
	connects: [dynamic]u64,     // a shared worker's connections waiting for their connect event: their port ends
	waiting:  bool,             // a module graph is still loading: the page's messages wait (held) until it ran
	held:     [dynamic]^Worker_Msg,
	client_sw_reg: u64,         // a worker client's controller's registration (0: none)
	client_sw: string,          // a worker client's view of its controller's registration (ServiceWorkerRegistration_info), "" when none
	client_inbox: [dynamic][]byte,   // service workers' messages to it: the version's id (8 bytes) then the data
	children: [dynamic]^Nested_Worker,   // the Worker objects of its realm (nested_workers.odin)
	depth:    int,                       // how deep it is nested (1: a document's worker)
}

@(private)
worker_global_vt := Object_VTable{name = "DedicatedWorkerGlobalScope"}

@(private)
worker_global_free :: proc(g: ^Worker_Global) {
	if g.javascript { js.settings_destroy(&g.settings.js) }
	js_web_settings_destroy(&g.settings.js_web)
	delete(g.url); delete(g.name); delete(g.image); delete(g.storage_key)
	sw_global_free(&g.sw)
	delete(g.client_sw)
	for m in g.client_inbox { delete(m) }
	delete(g.client_inbox)
	delete(g.children)   // (their objects went with the realm)
	for e in g.connects { port_close_end(e) }
	delete(g.connects)
	for m in g.inbox { msg_free(m) }
	delete(g.inbox)
	for m in g.held { msg_free(m) }
	delete(g.held)
	free(g)
}

// True when the realm is a worker that must run nothing more.
@(private)
realm_halted :: #force_inline proc "contextless" (p: ^Page) -> bool {
	return p.worker != nil && link_stopping(p.worker.link)
}

@(private)
worker_main :: proc(data: rawptr) {
	g := (^Worker_Global)(data)
	l := g.link
	defer {
		m := new(Worker_Msg)
		m.kind = .Exited
		link_send(l, false, m)
		ports_link_closed(l)   // the MessagePort ends of its realm (ports.odin)
		worker_global_free(g)
		link_release(l)
	}
	p := worker_realm_create(g)
	g.page = p
	g.settings.wasm.stop = &l.stop   // terminate interrupts the module's running task
	ok: bool
	if g.javascript {
		g.settings.workers.wasm.stop = &l.stop
		ok = js_worker_start(p, g)   // js_workers.odin
	} else {
		err: string
		_, ok, err = instantiate(p, g.image, g.url, g.settings.wasm, worker_import_filter)
		if err != "" {
			if !realm_halted(p) { worker_send_error(g, err) }
			delete(err)
		}
	}
	delete(g.image)
	g.image = nil
	if ok || len(p.instances) > 0 {
		// a module whose wb_main trapped keeps running: what it registered before the error still works
		for !link_stopping(l) {
			worker_run_inbox(g)
			if link_stopping(l) { break }
			if sync.atomic_exchange(&g.idb_wake, false) { idb_worker_wake(p) }   // IndexedDB events (idb_host.odin)
			host.loop_wait(&l.loop)
			free_all(context.temp_allocator)
		}
	}
	page_close(p)
}

@(private)
worker_realm_create :: proc(g: ^Worker_Global) -> ^Page {
	p := new(Page)
	p.scope = base.scope_make("worker")
	p.loop = &g.link.loop
	p.settings = &g.settings
	p.console = worker_console
	p.console_user = g
	p.worker = g
	base.on_close(p.scope, page_cleanup, p)
	u, ok := url.parse_absolute(g.url, context.temp_allocator)
	if !ok { u, _ = url.parse_absolute("about:blank", context.temp_allocator) }
	p.env = fetch.environment_make(u)
	p.doc = dom.document_create(p.scope)   // never exposed: holds the listener id counter of the realm's objects
	p.dp.invoke = invoke_listener
	p.dp.user = p
	web_init(p, live = false)   // timers (nesting clamp), performance, encoding work the same in a worker
	p.web.embedder.storage = g.storage
	g.self = object_create(p, &worker_global_vt, g, 0)
	return p
}

// Runs the messages and request events the page sent, one task each, until the queue is empty or the worker stops.
@(private)
worker_run_inbox :: proc(g: ^Worker_Global) {
	l := g.link
	p := g.page
	link_take(l, true, &g.inbox)
	for m, i in g.inbox {
		if g.waiting && (m.kind == .Message || m.kind == .Connect) {
			// HTML: a module worker's port message queue is enabled once its graph ran
			append(&g.held, m)
			g.inbox[i] = nil
			continue
		}
		if !link_stopping(l) {
			switch m.kind {
			case .Message:     deliver_message(p, g.self, m, 0)
			case .Fetch_Event: worker_fetch_event(p, m)
			case .Port_Wake:   ports_wake_worker(p, m.id)   // ports.odin
			case .Sw_Event:    sw_worker_event(p, m); continue   // service_worker.odin (keeps the message)
			case .Connect:     shared_connect_event(p, m)   // shared_worker.odin (takes the port end)
			case .Sw_Client:   sw_client_message(p, m)   // service_worker.odin
			case .Child_Event: nested_event(p, m)   // nested_workers.odin
			case .Error, .Console, .Closed, .Exited, .Fetch_Start, .Fetch_Cancel, .Sw_Reply, .Sw_Post, .Child_Create, .Child_Terminate:
			}
		}
		msg_free(m)
		g.inbox[i] = nil
		free_all(context.temp_allocator)
	}
	clear(&g.inbox)
}

// A module worker's graph ran (or failed): the messages held meanwhile are delivered, in order, from a task.
worker_release_held :: proc(p: ^Page) {
	g := p.worker
	if g == nil || !g.waiting { return }
	g.waiting = false
	if len(g.held) == 0 { return }
	sync.mutex_lock(&g.link.mu)
	rest := make([dynamic]^Worker_Msg, 0, len(g.held) + len(g.link.to_worker))
	append(&rest, ..g.held[:])
	append(&rest, ..g.link.to_worker[:])
	delete(g.link.to_worker)
	g.link.to_worker = rest
	sync.mutex_unlock(&g.link.mu)
	clear(&g.held)
	host.signal(&g.link.loop)
}

@(private)
worker_console :: proc(user: rawptr, level: Log_Level, message: string) {
	g := (^Worker_Global)(user)
	m := new(Worker_Msg)
	m.kind, m.code, m.text = .Console, i64(level), strings.clone(message)
	link_send(g.link, false, m)
}

@(private)
// `code` 1: its script could not start (not fetched, not parsed): a shared worker's SharedWorker objects get an error
worker_send_error :: proc(g: ^Worker_Global, message: string, code := 0) {
	m := new(Worker_Msg)
	m.kind, m.code, m.text, m.text2 = .Error, i64(code), strings.clone(message), strings.clone(g.url)
	link_send(g.link, false, m)
}

// A task of the worker trapped: an `error` event at the Worker object (and the page's console unless prevented).
@(private)
worker_report_error :: proc(p: ^Page, message: string) {
	if realm_halted(p) { return }   // stopped by terminate: not an error of the script
	worker_send_error(p.worker, message)
}

// DedicatedWorkerGlobalScope.close(): the worker finishes the current task and stops; the page is told.
worker_close :: proc(p: ^Page) {
	g := p.worker
	if g == nil || g.closing { return }
	g.closing = true
	m := new(Worker_Msg)
	m.kind = .Closed
	link_send(g.link, false, m)
	sync.atomic_store(&g.link.stop, true)
}

worker_post_to_page :: proc(p: ^Page, text: string, transfer: []u64) -> dom.Error {
	g := p.worker
	if g == nil { return .Invalid_Argument }
	return post_message(p, g.link, false, text, transfer)   // still delivered after close(), until the task ends
}

@(private)
worker_fetch_start :: proc(p: ^Page, f: ^Fetch, abs, method, headers: string, body: []byte, options: u32) {
	m := new(Worker_Msg)
	m.kind, m.id, m.code = .Fetch_Start, u64(f.self), i64(options)
	m.text, m.text2, m.text3 = strings.clone(abs), strings.clone(method), strings.clone(headers)
	if len(body) > 0 { m.bytes = make([]byte, len(body)); copy(m.bytes, body) }
	f.task = f.self   // in flight; the record's own handle names the request on both sides
	link_send(p.worker.link, false, m)
}

@(private)
worker_fetch_cancel :: proc(p: ^Page, f: ^Fetch) {
	m := new(Worker_Msg)
	m.kind, m.id = .Fetch_Cancel, u64(f.self)
	link_send(p.worker.link, false, m)
}

@(private)
worker_fetch_event :: proc(p: ^Page, m: ^Worker_Msg) {
	f := base.pool_get(&p.fetches, base.Handle(m.id))
	if f == nil || f.task == base.NIL_HANDLE { return }   // released or aborted meanwhile
	u := Fetch_Update{kind = fetch.Event_Kind(m.code), data = m.bytes}
	switch u.kind {
	case .Response:
		u.status = int(m.code2 & 0xFFFF_FFFF)
		u.type = fetch.Response_Type((m.code2 >> 32) & 0xFF)
		u.redirected = m.code2 & (1 << 40) != 0
		u.usable = m.code2 & (1 << 41) != 0
		u.url, u.headers = m.text, m.text2
	case .Failed:
		u.error, u.detail = fetch.Error_Kind(m.code2), m.text
	case .Data, .Done:
	}
	if f.ext != nil { fetch_ext_event(f, u); return }   // promise / stream / abort signal, as on the page's thread
	fetch_update(f, u)
	if f.module != nil && f.state >= 2 { module_worker_fetched(p, f) }   // a module of the realm's graph (js_load_modules.odin)
}
