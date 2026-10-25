package page

// Service workers (W3C Service Workers), the browser's side. Our own approach, given that every realm is an engine
// instance and requests go through one native loader:
//
//   * Registrations live here (UI thread), kept in the profile (<profile>/service_workers.txt): scope, script, state.
//   * A registration's worker runs as a JavaScript worker (worker.odin, js_workers.odin) hosted by a page of its own
//     that shows nothing (its "host": same origin as the scope, no document anyone sees), so one instance serves every
//     client of the registration whatever pages open and close. Started when needed (registration, the first request a
//     worker must answer after the browser starts), stopped when unregistered or when the profile closes.
//   * Requests are intercepted in the loader (fetch/service_worker.odin) before they reach the network: navigations
//     whose URL is in an active registration's scope, and the requests of controlled pages. While no registration has
//     an active worker, the loader does not even ask (one counter).
//   * A controlled page: in an active registration's scope and created after the registration became active (it was
//     loaded under it), or claimed (clients.claim()). The page that registered is not, until it reloads or is claimed.
//   * Events go to the worker as Sw_Event messages (install, activate, fetch, message); it answers with Sw_Reply
//     messages (install / activate done, respond, fall back, fail, skipWaiting, claim, a message to a client, the
//     script ran). A fetch that gets no answer within service_workers.fetch_timeout_ms goes to the network.
//
// Limits: one version at a time (an update replaces the worker when the new one installed), no navigation preload,
// no Background Sync / Push, Client.navigate / focus / openWindow are not offered; a worker is not stopped when idle.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:url"

Sw_State :: enum u8 { Parsed, Installing, Installed, Activating, Activated, Redundant }
SW_STATE_NAMES := [Sw_State]string{.Parsed = "parsed", .Installing = "installing", .Installed = "installed", .Activating = "activating", .Activated = "activated", .Redundant = "redundant"}

Sw_Event_Kind :: enum i64 { None, Install, Activate, Fetch, Message }
Sw_Reply_Kind :: enum i64 { None, Install_Done, Activate_Done, Respond, Fall_Back, Fail, Skip_Waiting, Claim, Post_Client, Script_Ran }

@(private)
Sw_Waiter :: struct { page: u64, promise: u64 }

Sw_Registration :: struct {
	id:          u64,
	origin:      string,
	scope:       string,
	script:      string,
	via_cache:   string,
	state:       Sw_State,       // the version's
	activated:   bool,           // counted in sw_registry.active
	after_page:  u64,            // pages with a larger id were created after it became active: they are controlled
	claimed:     map[u64]bool,   // pages claimed (clients.claim)
	skip_waiting: bool,
	claim_pending: bool,         // clients.claim() came before the version was active
	host:        ^Page,          // the page hosting the running worker
	worker:      ^Worker_Host,
	running:     bool,           // its script ran: events go now
	queue:       [dynamic]^Worker_Msg,   // events waiting for the script
	registering: [dynamic]Sw_Waiter,     // register() promises
	dir:         string,         // the profile directory it is kept in
}

@(private)
Sw_Fetch :: struct {
	loader: ^fetch.Loader,
	task:   base.Handle,
	timer:  base.Handle,
	loop:   ^host.Loop,
	id:     u64,
}

@(private)
Sw_Registry :: struct {
	regs:      [dynamic]^Sw_Registration,
	next:      u64,
	active:    int,                  // registrations with an active worker (the loader's counter)
	fetches:   map[u64]^Sw_Fetch,
	next_fetch: u64,
	ready:     [dynamic]Sw_Waiter,   // navigator.serviceWorker.ready
	scope:     ^base.Scope,          // the host pages' parent
	inbox:     map[u64][dynamic][]byte,   // messages from workers waiting for their page's engine (by page id)
}

@(private) sw_registry: Sw_Registry

////////////////////////////////
// Registry and persistence

@(private)
sw_file :: proc(dir: string) -> string { return strings.concatenate({dir, "/service_workers.txt"}, context.temp_allocator) }

// Loads the registrations of the profile (storage_manager_init) and installs the loader's hook.
sw_registry_load :: proc(dir: string) {
	fetch.sw_hook = {intercept = sw_intercept, active = &sw_registry.active}
	if dir == "" { return }
	data, err := os.read_entire_file(sw_file(dir), context.temp_allocator)
	if err != nil { return }
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 6 { continue }
		r := new(Sw_Registration)
		id, _ := strconv.parse_u64(f[0])
		r.id, r.origin, r.scope, r.script, r.via_cache = id, strings.clone(f[1]), strings.clone(f[2]), strings.clone(f[3]), strings.clone(f[4])
		r.dir = strings.clone(dir)
		if f[5] == "activated" {
			r.state, r.activated = .Activated, true
			sw_registry.active += 1
		} else {
			r.state = .Redundant   // a version that never finished installing is dropped
		}
		sw_registry.next = max(sw_registry.next, id)
		if r.activated { append(&sw_registry.regs, r) } else { sw_reg_free(r) }
	}
}

@(private)
sw_save :: proc(dir: string) {
	if dir == "" { return }
	b := strings.builder_make(context.temp_allocator)
	for r in sw_registry.regs {
		if r.dir != dir || r.state == .Redundant { continue }
		fmt.sbprintf(&b, "%d\t%s\t%s\t%s\t%s\t%s\n", r.id, r.origin, r.scope, r.script, r.via_cache, r.activated ? "activated" : SW_STATE_NAMES[r.state])
	}
	_ = os.write_entire_file(sw_file(dir), transmute([]byte)strings.to_string(b))
}

@(private)
sw_reg_free :: proc(r: ^Sw_Registration) {
	for m in r.queue { msg_free(m) }
	delete(r.queue); delete(r.registering); delete(r.claimed)
	delete(r.origin); delete(r.scope); delete(r.script); delete(r.via_cache); delete(r.dir)
	free(r)
}

// Stops every worker and forgets the registrations of the profile (storage_manager_destroy; pages are closed).
sw_registry_shutdown :: proc() {
	for r in sw_registry.regs { sw_stop(r); sw_reg_free(r) }
	delete(sw_registry.regs)
	for _, f in sw_registry.fetches { if f.timer != base.NIL_HANDLE { host.clear_timer(f.loop, f.timer) }; free(f) }
	delete(sw_registry.fetches)
	for _, q in sw_registry.inbox { for m in q { delete(m) }; delete(q) }
	delete(sw_registry.inbox)
	delete(sw_registry.ready)
	if sw_registry.scope != nil { base.scope_close(sw_registry.scope) }
	sw_registry = {}
	fetch.sw_hook = {}
}

// The registration whose scope is the longest prefix of `u` (Service Workers "match service worker registration").
sw_match :: proc(u: string, active_only: bool) -> ^Sw_Registration {
	best: ^Sw_Registration
	for r in sw_registry.regs {
		if r.state == .Redundant || (active_only && !r.activated) { continue }
		if strings.has_prefix(u, r.scope) && (best == nil || len(r.scope) > len(best.scope)) { best = r }
	}
	return best
}

@(private)
sw_by_id :: proc(id: u64) -> ^Sw_Registration {
	for r in sw_registry.regs { if r.id == id { return r } }
	return nil
}

@(private)
sw_is_host :: proc(p: ^Page) -> bool {
	for r in sw_registry.regs { if r.host == p { return true } }
	return false
}

// The registration controlling page `p` (nil: none).
sw_controller :: proc(p: ^Page) -> ^Sw_Registration {
	if p == nil || p.web == nil || p.worker != nil || sw_registry.active == 0 || sw_is_host(p) { return nil }
	r := sw_match(p.env.location.href, true)
	if r == nil { return nil }
	if p.web.id > r.after_page || r.claimed[p.web.id] { return r }
	return nil
}

////////////////////////////////
// Running a registration's worker

@(private)
sw_console :: proc(user: rawptr, level: Log_Level, message: string) {
	r := (^Sw_Registration)(user)
	text := fmt.tprintf("[service worker %s] %s", r.script, message)
	for _, pg in live_pages {
		if pg.closed || sw_is_host(pg) { continue }
		if url.origin_serialize(pg.env.origin, context.temp_allocator) == r.origin { log(pg, level, text) }
	}
}

// Starts the registration's worker in a host page made from `like` (its loop, loader, settings, storage). False when
// it could not start (workers disabled, too many...).
@(private)
sw_start :: proc(r: ^Sw_Registration, like: ^Page) -> bool {
	if r.worker != nil { return true }
	if like == nil || like.loader == nil { return false }
	if sw_registry.scope == nil { sw_registry.scope = base.scope_make("service-workers") }
	hp := page_create(like.loop, like.loader, like.settings, sw_registry.scope, r.scope, sw_console, r)
	hp.web.embedder.storage = like.web.embedder.storage
	obj := worker_create(hp, r.script, "", 0, javascript = true)
	h := (^Worker_Host)(object_data(hp, obj, &worker_vt)) if obj != 0 else nil
	if h == nil { page_close(hp); return false }
	h.sw = r
	r.host, r.worker, r.running = hp, h, false
	return true
}

@(private)
sw_stop :: proc(r: ^Sw_Registration) {
	if r.host != nil { hp := r.host; r.host, r.worker, r.running = nil, nil, false; page_close(hp) }
}

// Sends an event to the worker (queued until its script ran).
@(private)
sw_send :: proc(r: ^Sw_Registration, m: ^Worker_Msg) {
	if r.worker == nil { msg_free(m); return }
	if !r.running { append(&r.queue, m); return }
	link_send(r.worker.link, true, m)
}

@(private)
sw_event :: proc(r: ^Sw_Registration, kind: Sw_Event_Kind, id: u64 = 0) -> ^Worker_Msg {
	m := new(Worker_Msg)
	m.kind, m.code, m.id = .Sw_Event, i64(kind), id
	return m
}

// The worker's script failed to load or threw: an installing version becomes redundant, register() rejects.
sw_instance_error :: proc(h: ^Worker_Host, message: string) {
	r := h.sw
	if r == nil { return }
	sw_console(r, .Error, message)
	if r.running && r.activated { return }   // an error of an event's listener: the worker goes on
	sw_reject_registering(r, message)
	if !r.activated { sw_redundant(r) }
}

@(private)
sw_reject_registering :: proc(r: ^Sw_Registration, message: string) {
	for w in r.registering { if pg := page_by_id(w.page); pg != nil && !pg.closed { promise_reject(pg, w.promise, i64(Api_Error.Type), fmt.tprintf("TypeError: %s", message)) } }
	clear(&r.registering)
}

@(private)
sw_redundant :: proc(r: ^Sw_Registration) {
	r.state = .Redundant
	sw_stop(r)
	for x, i in sw_registry.regs { if x == r { ordered_remove(&sw_registry.regs, i); break } }
	if r.activated { sw_registry.active -= 1 }
	sw_save(r.dir)
	sw_reg_free(r)
}

////////////////////////////////
// The worker's answers (UI thread)

sw_page_reply :: proc(h: ^Worker_Host, m: ^Worker_Msg) {
	r := h.sw
	if r == nil || r.worker != h { return }
	switch Sw_Reply_Kind(m.code) {
	case .None:
	case .Script_Ran:
		r.running = true
		for w in r.registering { if pg := page_by_id(w.page); pg != nil && !pg.closed { promise_resolve(pg, w.promise, i64(r.id)) } }
		clear(&r.registering)
		for q in r.queue { link_send(h.link, true, q) }
		clear(&r.queue)
		if r.state == .Parsed { r.state = .Installing; sw_send(r, sw_event(r, .Install)) }
	case .Install_Done:
		if m.code2 == 0 { sw_console(r, .Error, "installation failed (a promise given to waitUntil rejected)"); sw_redundant(r); return }
		r.state = .Installed
		sw_activate(r)
	case .Activate_Done:
		r.state = .Activated
		if !r.activated {
			r.activated = true
			r.after_page = next_page_id
			sw_registry.active += 1
		}
		sw_save(r.dir)
		sw_wake_ready()
		if r.claim_pending { r.claim_pending = false; sw_claim(r) }
	case .Skip_Waiting:
		r.skip_waiting = true
		if r.state == .Installed { sw_activate(r) }
	case .Claim:
		// (called from the activate event, before the version is active: done once it is)
		if !r.activated { r.claim_pending = true } else { sw_claim(r) }
	case .Post_Client:
		target := u64(m.code2)
		for id, pg in live_pages {
			if pg.closed || sw_is_host(pg) || (target != 0 && id != target) { continue }
			if sw_controller(pg) != r && target == 0 { continue }
			sw_notify_page(pg, "message", m.bytes)
		}
	case .Respond, .Fall_Back, .Fail:
		f, ok := sw_registry.fetches[m.id]
		if !ok { return }
		delete_key(&sw_registry.fetches, m.id)
		if f.timer != base.NIL_HANDLE { host.clear_timer(f.loop, f.timer) }
		#partial switch Sw_Reply_Kind(m.code) {
		case .Respond: fetch.sw_respond(f.loader, f.task, int(m.code2), m.text, m.bytes)
		case .Fall_Back: fetch.sw_fall_back(f.loader, f.task)
		case .Fail: fetch.sw_fail(f.loader, f.task, m.text2)
		}
		free(f)
	}
}

// clients.claim(): the pages in the scope that are not controlled yet become controlled (controllerchange).
@(private)
sw_claim :: proc(r: ^Sw_Registration) {
	for id, pg in live_pages {
		if pg.closed || sw_is_host(pg) || sw_match(pg.env.location.href, true) != r { continue }
		if pg.web.id > r.after_page || r.claimed[id] { continue }
		r.claimed[id] = true
		sw_notify_page(pg, "controllerchange", nil)
	}
}

// Installed: the version becomes active now when nothing else is (one version at a time here), or when it asked.
@(private)
sw_activate :: proc(r: ^Sw_Registration) {
	if r.state != .Installed { return }
	r.state = .Activating
	sw_send(r, sw_event(r, .Activate))
}

@(private)
sw_wake_ready :: proc() {
	k := 0
	for w in sw_registry.ready {
		pg := page_by_id(w.page)
		if pg == nil || pg.closed { continue }
		if r := sw_match(pg.env.location.href, true); r != nil { promise_resolve(pg, w.promise, i64(r.id)); continue }
		sw_registry.ready[k] = w
		k += 1
	}
	resize(&sw_registry.ready, k)
}

// navigator.serviceWorker's events in a page: controllerchange, or a message from the worker (its serialized data).
@(private)
sw_notify_page :: proc(pg: ^Page, type: string, data: []byte) {
	if type == "message" {
		q := sw_registry.inbox[pg.web.id]
		copy_ := make([]byte, len(data))
		copy(copy_, data)
		append(&q, copy_)
		sw_registry.inbox[pg.web.id] = q
	}
	r := js_realm(pg)
	if r == nil { return }
	argv := [1]u32{type == "message" ? 1 : 0}   // 0 controllerchange, 1 message (ServiceWorker_takeMessage)
	js_call(pg, r.inst, "wj_sw_container_event", argv[:])
}

////////////////////////////////
// Interception (fetch/service_worker.odin's hook, UI thread)

@(private)
page_of_env :: proc(env: ^fetch.Environment) -> ^Page {
	if env == nil { return nil }
	for _, pg in live_pages { if &pg.env == env { return pg } }
	return nil
}

@(private)
sw_intercept :: proc(t: ^fetch.Task) -> bool {
	client := page_of_env(t.initiator)
	if client != nil && (client.closed || sw_is_host(client) || !client.settings.sw.enabled) { return false }
	r: ^Sw_Registration
	navigation := t.mode == .Navigate && (t.destination == .Document || t.destination == .Iframe)
	if navigation {
		r = sw_match(t.target.href, true)
	} else {
		r = sw_controller(client)
	}
	if r == nil { return false }
	like := client
	if like == nil { for _, pg in live_pages { if !pg.closed && pg.loader != nil && !sw_is_host(pg) { like = pg; break } } }
	if r.worker == nil && !sw_start(r, like) { return false }
	sw_registry.next_fetch += 1
	id := sw_registry.next_fetch
	f := new(Sw_Fetch)
	f.loader, f.task, f.id = t.loader, t.self, id
	f.loop = r.host.loop
	sw_registry.fetches[id] = f
	timeout := r.host.settings.sw.fetch_timeout_ms
	f.timer = host.set_timer(f.loop, f64(timeout), 0, sw_fetch_timeout, rawptr(uintptr(id)))
	m := sw_event(r, .Fetch, id)
	m.text, m.text2 = strings.clone(t.target.href), strings.clone(t.method)
	hb := strings.builder_make()
	for e in t.headers.list { fmt.sbprintf(&hb, "%s: %s\r\n", e.name, e.value) }
	m.text3 = strings.to_string(hb)
	if len(t.body) > 0 { m.bytes = make([]byte, len(t.body)); copy(m.bytes, t.body) }
	client_id := client != nil ? client.web.id : 0
	m.code2 = i64(t.mode) | i64(t.destination) << 8 | i64(client_id) << 16
	sw_send(r, m)
	return true
}

@(private)
sw_fetch_timeout :: proc(data: rawptr) {
	id := u64(uintptr(data))
	f, ok := sw_registry.fetches[id]
	if !ok { return }
	delete_key(&sw_registry.fetches, id)
	f.timer = base.NIL_HANDLE
	fetch.sw_fall_back(f.loader, f.task)
	free(f)
}

////////////////////////////////
// Module "serviceworker", page side (api/serviceworker.widl)

@(private)
sw_scope_of :: proc(c: ^Call, script, scope: string) -> (script_url, scope_url: string, err: Api_Error) {
	p := c.page
	if !p.env.secure_context { return "", "", fail(c, .Security, "SecurityError: service workers need a secure context") }
	if !p.settings.sw.enabled { return "", "", fail(c, .Security, "SecurityError: service workers are disabled (service_workers.enabled)") }
	base_u := p.env.location
	su, ok := url.parse(script, &base_u, context.temp_allocator)
	if !ok || (su.scheme != "http" && su.scheme != "https") { return "", "", fail(c, .Type, "TypeError: invalid script URL") }
	if !url.same_origin(url.origin_of(su, context.temp_allocator), p.env.origin) { return "", "", fail(c, .Security, "SecurityError: the script's origin is not the document's") }
	sc := scope
	if sc == "" { sc = "./" }
	scu, ok2 := url.parse(sc, &su, context.temp_allocator)
	if !ok2 || !url.same_origin(url.origin_of(scu, context.temp_allocator), p.env.origin) { return "", "", fail(c, .Security, "SecurityError: the scope's origin is not the document's") }
	scope_str := url.without_fragment(scu)
	if q := strings.index_byte(scope_str, '?'); q >= 0 { scope_str = scope_str[:q] }
	// the scope must be under the script's directory (no Service-Worker-Allowed header is honoured)
	dir := su.href[:strings.last_index_byte(su.href, '/') + 1]
	if !strings.has_prefix(scope_str, dir) { return "", "", fail(c, .Security, fmt.tprintf("SecurityError: the scope %s is not under the script's directory %s", scope_str, dir)) }
	return url.without_fragment(su), scope_str, .None
}

ServiceWorker_register :: proc(c: ^Call, script: string, scope: Maybe(string), via_cache: string) -> (u64, Api_Error) {
	p := c.page
	su, sc, err := sw_scope_of(c, script, scope.? or_else "")
	if err != .None { return 0, err }
	pr := promise_create(p, c.owner)
	origin := url.origin_serialize(p.env.origin, context.temp_allocator)
	for r in sw_registry.regs {
		if r.scope != sc || r.state == .Redundant { continue }
		if r.script == su {
			if r.running || r.activated { promise_resolve(p, pr, i64(r.id)) } else { append(&r.registering, Sw_Waiter{page_id(p), pr}) }
			return pr, .None
		}
		sw_redundant(r)   // a new script for the scope replaces the version (one version at a time)
		break
	}
	sw_registry.next += 1
	r := new(Sw_Registration)
	r.id, r.origin, r.scope, r.script, r.via_cache = sw_registry.next, strings.clone(origin), strings.clone(sc), strings.clone(su), strings.clone(via_cache)
	dir := ""
	if sm := p.web.embedder.storage; sm != nil && sm.ready { dir = sm.dir }
	r.dir = strings.clone(dir)
	r.state = .Parsed
	append(&sw_registry.regs, r)
	append(&r.registering, Sw_Waiter{page_id(p), pr})
	if !sw_start(r, p) {
		sw_reject_registering(r, "the service worker could not start (workers disabled or too many)")
		sw_redundant(r)
	}
	return pr, .None
}

ServiceWorker_ready :: proc(c: ^Call) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	if r := sw_match(p.env.location.href, true); r != nil { promise_resolve(p, pr, i64(r.id)); return pr }
	append(&sw_registry.ready, Sw_Waiter{page_id(p), pr})
	return pr
}

ServiceWorker_getRegistration :: proc(c: ^Call, client_url: string) -> u64 {
	p := c.page
	base_u := p.env.location
	u := p.env.location.href
	if client_url != "" { if pu, ok := url.parse(client_url, &base_u, context.temp_allocator); ok { u = pu.href } }
	r := sw_match(u, false)
	if r == nil || r.origin != url.origin_serialize(p.env.origin, context.temp_allocator) { return 0 }
	return r.id
}

ServiceWorker_registrationIds :: proc(c: ^Call) -> string {
	origin := url.origin_serialize(c.page.env.origin, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	for r in sw_registry.regs {
		if r.origin != origin || r.state == .Redundant { continue }
		if strings.builder_len(b) > 0 { strings.write_byte(&b, '\n') }
		fmt.sbprintf(&b, "%d", r.id)
	}
	return strings.to_string(b)
}

ServiceWorker_controller :: proc(c: ^Call) -> u64 {
	r := sw_controller(c.page)
	return r != nil ? r.id : 0
}

// scope, script URL, the version's state, whether it is active, updateViaCache ("\n"-separated; "" when gone)
ServiceWorkerRegistration_info :: proc(c: ^Call, id: u64) -> string {
	r := sw_by_id(id)
	if r == nil { return "" }
	return fmt.tprintf("%s\n%s\n%s\n%d\n%s", r.scope, r.script, SW_STATE_NAMES[r.state], r.activated ? 1 : 0, r.via_cache)
}

ServiceWorkerRegistration_unregisterId :: proc(c: ^Call, id: u64) -> bool {
	r := sw_by_id(id)
	if r == nil || r.origin != url.origin_serialize(c.page.env.origin, context.temp_allocator) { return false }
	sw_redundant(r)
	return true
}

// serviceWorker.postMessage from a page: a "message" event in the worker with the page as its source.
ServiceWorker_postToWorker :: proc(c: ^Call, id: u64, data: []u8) -> Api_Error {
	r := sw_by_id(id)
	if r == nil || r.state == .Redundant { return fail(c, .Invalid_State, "InvalidStateError: the service worker is redundant") }
	if r.worker == nil && !sw_start(r, c.page) { return fail(c, .Invalid_State, "InvalidStateError: the service worker could not start") }
	m := sw_event(r, .Message)
	m.bytes = make([]byte, len(data))
	copy(m.bytes, data)
	m.code2 = i64(page_id(c.page)) << 16
	m.text = strings.clone(c.page.env.location.href)
	sw_send(r, m)
	return .None
}

// The next message the page's service worker sent it (Not_Found when none waits): serialized data.
ServiceWorker_takeMessage :: proc(c: ^Call) -> ([]byte, Api_Error) {
	id := page_id(c.page)
	q, ok := sw_registry.inbox[id]
	if !ok || len(q) == 0 { return nil, fail(c, .Not_Found, "no message") }
	m := q[0]
	ordered_remove(&q, 0)
	if len(q) == 0 { delete(q); delete_key(&sw_registry.inbox, id) } else { sw_registry.inbox[id] = q }
	out := make([]byte, len(m), context.temp_allocator)
	copy(out, m)
	delete(m)
	return out, .None
}

////////////////////////////////
// The worker's side (its thread)

Sw_Global :: struct {
	reg:    u64,
	scope:  string,
	script: string,
	events: [dynamic]^Worker_Msg,
}

sw_global_init :: proc(g: ^Sw_Global, r: ^Sw_Registration) {
	g.reg, g.scope, g.script = r.id, strings.clone(r.scope), strings.clone(r.script)
}

sw_global_free :: proc(g: ^Sw_Global) {
	for m in g.events { msg_free(m) }
	delete(g.events); delete(g.scope); delete(g.script)
	g^ = {}
}

// An event arrived for the worker: kept until the engine takes it (wj_sw_event, runtime/web_sw.c).
sw_worker_event :: proc(p: ^Page, m: ^Worker_Msg) {
	g := p.worker
	append(&g.sw.events, m)
	if r := js_realm(p); r != nil { js_call(p, r.inst, "wj_sw_event", nil) }
}

// The script ran (js_workers.odin): the page side may send events now.
sw_script_ran :: proc(p: ^Page) {
	if p.worker == nil || p.worker.sw.reg == 0 { return }
	m := new(Worker_Msg)
	m.kind, m.code = .Sw_Reply, i64(Sw_Reply_Kind.Script_Ran)
	link_send(p.worker.link, false, m)
}

@(private)
sw_global :: proc(c: ^Call) -> ^Sw_Global {
	if c.page.worker == nil || c.page.worker.sw.reg == 0 { return nil }
	return &c.page.worker.sw
}

// The realm's service worker: its registration (0: not a service worker's realm).
ServiceWorkerGlobalScope_registration :: proc(c: ^Call) -> u64 {
	g := sw_global(c)
	return g != nil ? g.reg : 0
}

ServiceWorkerGlobalScope_scope :: proc(c: ^Call) -> string {
	g := sw_global(c)
	return g != nil ? g.scope : ""
}

ServiceWorkerGlobalScope_scriptURL :: proc(c: ^Call) -> string {
	g := sw_global(c)
	return g != nil ? g.script : ""
}

// The next event to fire (kind None: none waits). Its strings and body: SwEvent_text, SwEvent_body.
SwEvent_next :: proc(c: ^Call) -> Api_SwEventInfo {
	g := sw_global(c)
	if g == nil || len(g.events) == 0 { return {} }
	m := g.events[0]
	return Api_SwEventInfo{kind = i32(m.code), id = m.id, mode = i32(m.code2 & 0xFF), destination = i32((m.code2 >> 8) & 0xFF), client = u64(m.code2 >> 16)}
}

// A string of the current event: 0 URL, 1 method, 2 header lines.
SwEvent_text :: proc(c: ^Call, which: i32) -> string {
	g := sw_global(c)
	if g == nil || len(g.events) == 0 { return "" }
	m := g.events[0]
	switch which {
	case 0: return m.text
	case 1: return m.text2
	case 2: return m.text3
	}
	return ""
}

SwEvent_body :: proc(c: ^Call) -> []byte {
	g := sw_global(c)
	if g == nil || len(g.events) == 0 { return nil }
	return g.events[0].bytes
}

// The engine took the current event.
SwEvent_done :: proc(c: ^Call) {
	g := sw_global(c)
	if g == nil || len(g.events) == 0 { return }
	msg_free(g.events[0])
	ordered_remove(&g.events, 0)
}

// What the worker did (an event's outcome, skipWaiting, claim, a message to a client): to the page side.
ServiceWorkerGlobalScope_reply :: proc(c: ^Call, kind: i32, id: u64, code: i64, headers: string, text: string, body: []u8) {
	g := sw_global(c)
	if g == nil { return }
	m := new(Worker_Msg)
	m.kind, m.code, m.id, m.code2 = .Sw_Reply, i64(kind), id, code
	m.text, m.text2 = strings.clone(headers), strings.clone(text)
	if len(body) > 0 { m.bytes = make([]byte, len(body)); copy(m.bytes, body) }
	link_send(c.page.worker.link, false, m)
}
