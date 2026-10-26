package page

// Service workers (W3C Service Workers), the browser's side. Our own approach, given that every realm is an engine
// instance and requests go through one native loader:
//
//   * Registrations live here (UI thread), kept in the profile (<profile>/service_workers.txt: scope, updateViaCache,
//     navigation preload, the last update check, the active version), with each active version's script stored next
//     to it (<profile>/service_workers/<version>.js): a version runs the script it was installed with, never the
//     network's, until an update installs another.
//   * A registration has up to three versions (Service Workers "installing", "waiting", "active"). A version's worker
//     runs as a JavaScript worker (worker.odin, js_workers.odin; a module one with {type: "module"}) hosted by a page of
//     its own that shows nothing, so one instance serves every client whatever pages open and close. It starts when an
//     event needs it and stops after service_workers.idle_ms without one (its next event starts it again).
//   * Update (register() with a new script, registration.update(), and a navigation in the scope when the last check is
//     older than service_workers.update_check_hours): the script is fetched (Service-Worker: script, the HTTP cache
//     bypassed unless updateViaCache is "all"); the same bytes change nothing, other bytes are a new version that
//     installs, waits while the active version has clients (unless it calls skipWaiting()), then activates: the old
//     active version becomes redundant and the clients it controlled get the new one (controllerchange).
//   * Requests are intercepted in the loader (fetch/service_worker.odin) before they reach the network: navigations
//     whose URL is in an active registration's scope, and the requests of controlled pages. While no registration has
//     an active version, the loader does not even ask (one counter). A navigation with navigation preload enabled
//     starts its network request at once, with Service-Worker-Navigation-Preload; the worker gets it as
//     FetchEvent.preloadResponse, and a worker that does not answer gets it as the response instead of a second request.
//   * A controlled page: in an active registration's scope and created after the registration became active (it was
//     loaded under it), or claimed (clients.claim()). The page that registered is not, until it reloads or is claimed.
//   * Events go to the worker as Sw_Event messages; it answers with Sw_Reply messages. Requests of the worker that need
//     the interface thread (clients.matchAll / get / openWindow, WindowClient.navigate / focus, registration.update /
//     unregister) are replies answered by an event. The worker's view of its registration is a copy the browser sends
//     at each change (ServiceWorkerRegistration_info answers from it there).
//
// Not done: Background Sync, Background Fetch, Push, Notifications (no such permission exists in this browser);
// worker clients (clients.matchAll({type: "worker" | "sharedworker"}) lists windows only).

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:fetch"
import "wb:csp"
import "wb:host"
import "wb:http"
import "wb:url"

Sw_State :: enum u8 { Parsed, Installing, Installed, Activating, Activated, Redundant }
SW_STATE_NAMES := [Sw_State]string{.Parsed = "parsed", .Installing = "installing", .Installed = "installed", .Activating = "activating", .Activated = "activated", .Redundant = "redundant"}

Sw_Event_Kind :: enum i64 { None, Install, Activate, Fetch, Message, Answer, Registration, Preload }
Sw_Reply_Kind :: enum i64 { None, Install_Done, Activate_Done, Respond, Fall_Back, Fail, Skip_Waiting, Claim, Post_Client, Script_Ran, Request, Preload }
Sw_Request_Op :: enum i64 { None, Match_All, Get, Open_Window, Navigate, Focus, Update, Unregister }

// The shell's side of clients.openWindow and WindowClient.focus (browser/sw_shell.odin); nil procedures: refused.
Sw_Embedder :: struct {
	open:  proc(user: rawptr, url: string) -> bool,
	focus: proc(user: rawptr, p: ^Page) -> bool,
	user:  rawptr,
}
sw_embedder: Sw_Embedder

@(private)
Sw_Waiter :: struct { page: u64, promise: u64 }

Sw_Version :: struct {
	id:           u64,
	reg:          ^Sw_Registration,
	script:       string,
	module:       bool,
	image:        []byte,          // its script (nil: not stored, fetched when it starts)
	csp:          [dynamic]string, // its script's Content-Security-Policy headers (enforced, then report-only after "\x00")
	state:        Sw_State,
	host_page:    ^Page,           // the page hosting its worker while it runs
	worker:       ^Worker_Host,
	running:      bool,            // its script ran: events go now
	queue:        [dynamic]^Worker_Msg,   // events waiting for the script
	skip_waiting: bool,
	claim_pending: bool,           // clients.claim() came before the version was active
	pending:      int,             // events waiting for its answer (install, activate, fetches, requests)
	idle:         base.Handle,     // stops the worker when nothing happened for service_workers.idle_ms
}

Sw_Registration :: struct {
	id:          u64,
	origin:      string,
	scope:       string,
	script:      string,          // the script URL of the last register() / update
	module:      bool,            // ... of type module
	via_cache:   string,
	installing, waiting, active: ^Sw_Version,
	counted:     bool,            // counted in sw_registry.active (it has an active version)
	after_page:  u64,             // pages with a larger id were created after it became active: they are controlled
	claimed:     map[u64]bool,    // pages claimed (clients.claim)
	registering: [dynamic]Sw_Waiter,   // register() / update() promises
	job:         base.Handle,     // the script fetch of an update in flight
	job_env:     fetch.Environment,   // who asks for the script (the scope's origin), while a job runs
	job_body:    [dynamic]byte,
	job_status:  int,
	job_csp:     [dynamic]string,
	job_error:   string,
	job_requests: [dynamic]u64,   // worker requests (update) answered when the job ends: version id << 32 | request id
	last_check:  i64,             // unix seconds of the last update check
	uninstalling: bool,           // unregistered while it controls pages: no new client, gone with the last one
	uninstall_after: u64,         // ... the pages created after it was unregistered are not its clients
	preload:     bool,            // navigation preload enabled
	preload_header: string,
	dir:         string,          // the profile directory it is kept in
}

@(private)
Sw_Fetch :: struct {
	loader:   ^fetch.Loader,
	task:     base.Handle,
	timer:    base.Handle,
	loop:     ^host.Loop,
	id:       u64,
	version:  u64,
	// navigation preload
	preload:  base.Handle,     // its request, NIL when none or finished
	pre_state: u8,             // 0 none, 1 running, 2 done, 3 failed
	pre_sent: bool,            // its response went to the worker
	pre_status: int,
	pre_url:  string,
	pre_headers: string,
	pre_body: [dynamic]byte,
	fall_back: bool,           // the worker did not answer: the preload's response is the answer once it is in
	answered: bool,            // the worker answered: the loader's task is settled
}

// clients.openWindow / WindowClient.navigate waiting for the new document.
@(private)
Sw_Open :: struct {
	version:  u64,
	request:  u64,
	after:    u64,     // the document is a page created after this id
	url:      string,
	deadline: time.Tick,
}

@(private)
Sw_Registry :: struct {
	regs:       [dynamic]^Sw_Registration,
	next:       u64,                  // registration and version ids
	active:     int,                  // registrations with an active version (the loader's counter)
	fetches:    map[u64]^Sw_Fetch,
	next_fetch: u64,
	ready:      [dynamic]Sw_Waiter,   // navigator.serviceWorker.ready
	scope:      ^base.Scope,          // the host pages' parent
	inbox:      map[u64][dynamic][]byte,   // messages from workers waiting for their page's engine (by page id)
	opens:      [dynamic]Sw_Open,
	open_timer: base.Handle,
	// what a version's host page is made like when no page is at hand (the shell's loop, loader, settings, storage)
	loop:       ^host.Loop,
	loader:     ^fetch.Loader,
	settings:   ^Settings,
	storage:    ^Storage_Manager,
}

@(private) sw_registry: Sw_Registry

////////////////////////////////
// Registry and persistence

@(private)
sw_file :: proc(dir: string) -> string { return strings.concatenate({dir, "/service_workers.txt"}, context.temp_allocator) }

@(private)
sw_script_file :: proc(dir: string, version: u64) -> string { return fmt.tprintf("%s/service_workers/%d.js", dir, version) }

@(private)
sw_now :: proc() -> i64 { return time.time_to_unix(time.now()) }

// Tabs and line breaks of a stored field.
@(private)
sw_escape :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "\\", "\\\\", context.temp_allocator)
	out, _ = strings.replace_all(out, "\t", "\\t", context.temp_allocator)
	out, _ = strings.replace_all(out, "\n", "\\n", context.temp_allocator)
	return out
}

@(private)
sw_unescape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] { case 't': strings.write_byte(&b, '\t'); case 'n': strings.write_byte(&b, '\n'); case: strings.write_byte(&b, s[i]) }
			continue
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

// Loads the registrations of the profile (storage_manager_init) and installs the loader's hook.
//   v2 lines: "2", id, origin, scope, script, updateViaCache, last check, preload, preload header, version, module
//   v1 lines (before versions were stored): id, origin, scope, script, updateViaCache, state
sw_registry_load :: proc(dir: string) {
	fetch.sw_hook = {intercept = sw_intercept, active = &sw_registry.active}
	if dir == "" { return }
	data, err := os.read_entire_file(sw_file(dir), context.temp_allocator)
	if err != nil { return }
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split(line, "\t", context.temp_allocator)
		r: ^Sw_Registration
		vid: u64
		if len(f) >= 11 && f[0] == "2" {
			r = new(Sw_Registration)
			r.id, _ = strconv.parse_u64(f[1])
			r.origin, r.scope, r.script, r.via_cache = strings.clone(f[2]), strings.clone(f[3]), strings.clone(f[4]), strings.clone(f[5])
			r.last_check, _ = strconv.parse_i64(f[6])
			r.preload = f[7] == "1"
			r.preload_header = strings.clone(sw_unescape(f[8]))
			vid, _ = strconv.parse_u64(f[9])
			r.module = f[10] == "1"
		} else if len(f) >= 6 && f[5] == "activated" {
			r = new(Sw_Registration)
			r.id, _ = strconv.parse_u64(f[0])
			r.origin, r.scope, r.script, r.via_cache = strings.clone(f[1]), strings.clone(f[2]), strings.clone(f[3]), strings.clone(f[4])
			r.preload_header = strings.clone("true")
		} else {
			continue   // a version that never finished installing is dropped
		}
		r.dir = strings.clone(dir)
		v := new(Sw_Version)
		v.id, v.reg, v.script, v.module, v.state = vid, r, strings.clone(r.script), r.module, .Activated
		if vid != 0 {
			if img, e := os.read_entire_file(sw_script_file(dir, vid), context.allocator); e == nil { v.image = img }
		}
		r.active = v
		r.counted = true
		sw_registry.active += 1
		sw_registry.next = max(sw_registry.next, r.id, vid)
		append(&sw_registry.regs, r)
	}
	// (a version from before versions were stored: an id now; its script is fetched when it starts)
	for r in sw_registry.regs { if r.active.id == 0 { sw_registry.next += 1; r.active.id = sw_registry.next } }
}

@(private)
sw_save :: proc(dir: string) {
	if dir == "" { return }
	b := strings.builder_make(context.temp_allocator)
	for r in sw_registry.regs {
		if r.dir != dir || r.active == nil || r.uninstalling { continue }
		v := r.active
		fmt.sbprintf(&b, "2\t%d\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%d\t%s\n", r.id, r.origin, r.scope, v.script, r.via_cache, r.last_check,
			r.preload ? "1" : "0", sw_escape(r.preload_header), v.id, v.module ? "1" : "0")
	}
	_ = os.write_entire_file(sw_file(dir), transmute([]byte)strings.to_string(b))
}

// Keeps a version's script in the profile (an active version starts from it after the browser restarts).
@(private)
sw_store_script :: proc(v: ^Sw_Version) {
	r := v.reg
	if r.dir == "" || v.image == nil { return }
	_ = os.make_directory_all(fmt.tprintf("%s/service_workers", r.dir))
	_ = os.write_entire_file(sw_script_file(r.dir, v.id), v.image)
}

@(private)
sw_version_new :: proc(r: ^Sw_Registration, script: string, module: bool) -> ^Sw_Version {
	v := new(Sw_Version)
	sw_registry.next += 1
	v.id = sw_registry.next
	v.reg, v.script, v.module = r, strings.clone(script), module
	return v
}

@(private)
sw_version_free :: proc(v: ^Sw_Version) {
	for m in v.queue { msg_free(m) }
	delete(v.queue)
	for s in v.csp { delete(s) }
	delete(v.csp)
	delete(v.script)
	delete(v.image)
	free(v)
}

@(private)
sw_reg_free :: proc(r: ^Sw_Registration) {
	for v in ([3]^Sw_Version{r.installing, r.waiting, r.active}) { if v != nil { sw_version_stop(v); sw_version_free(v) } }
	if r.job != base.NIL_HANDLE && sw_registry.loader != nil { fetch.cancel(sw_registry.loader, r.job) }
	fetch.environment_destroy(&r.job_env)
	delete(r.job_body)
	for s in r.job_csp { delete(s) }
	delete(r.job_csp)
	delete(r.job_error)
	delete(r.job_requests)
	delete(r.registering); delete(r.claimed)
	delete(r.origin); delete(r.scope); delete(r.script); delete(r.via_cache); delete(r.dir); delete(r.preload_header)
	free(r)
}

// Stops every worker and forgets the registrations of the profile (storage_manager_destroy; pages are closed).
sw_registry_shutdown :: proc() {
	for r in sw_registry.regs { sw_reg_free(r) }
	delete(sw_registry.regs)
	for _, f in sw_registry.fetches { sw_fetch_free(f) }
	delete(sw_registry.fetches)
	for _, q in sw_registry.inbox { for m in q { delete(m) }; delete(q) }
	delete(sw_registry.inbox)
	delete(sw_registry.ready)
	for o in sw_registry.opens { delete(o.url) }
	delete(sw_registry.opens)
	if sw_registry.open_timer != base.NIL_HANDLE && sw_registry.loop != nil { host.clear_timer(sw_registry.loop, sw_registry.open_timer) }
	if sw_registry.scope != nil { base.scope_close(sw_registry.scope) }
	sw_registry = {}
	fetch.sw_hook = {}
}

@(private)
sw_fetch_free :: proc(f: ^Sw_Fetch) {
	if f.timer != base.NIL_HANDLE { host.clear_timer(f.loop, f.timer) }
	if f.preload != base.NIL_HANDLE { fetch.cancel(f.loader, f.preload) }
	delete(f.pre_url); delete(f.pre_headers); delete(f.pre_body)
	free(f)
}

// Remembers what a host page is made like (the shell's loop, loader, settings, storage are the same for every page).
@(private)
sw_note_page :: proc(p: ^Page) {
	if p == nil || p.loader == nil || p.worker != nil { return }
	sw_registry.loop, sw_registry.loader, sw_registry.settings = p.loop, p.loader, p.settings
	if p.web != nil && p.web.embedder.storage != nil { sw_registry.storage = p.web.embedder.storage }
}

// The registration whose scope is the longest prefix of `u` (Service Workers "match service worker registration").
sw_match :: proc(u: string, active_only: bool, uninstalling := false) -> ^Sw_Registration {
	best: ^Sw_Registration
	for r in sw_registry.regs {
		if active_only && r.active == nil { continue }
		if r.uninstalling && !uninstalling { continue }
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
sw_version_by_id :: proc(id: u64) -> ^Sw_Version {
	if id == 0 { return nil }
	for r in sw_registry.regs {
		for v in ([3]^Sw_Version{r.installing, r.waiting, r.active}) { if v != nil && v.id == id { return v } }
	}
	return nil
}

// A page that hosts a worker (a service worker's or a shared worker's): not a client.
@(private)
sw_is_host :: proc(p: ^Page) -> bool {
	for r in sw_registry.regs {
		for v in ([3]^Sw_Version{r.installing, r.waiting, r.active}) { if v != nil && v.host_page == p { return true } }
	}
	for s in shared_workers { if s.host_page == p { return true } }
	return false
}

// The registration controlling page `p` (nil: none).
sw_controller :: proc(p: ^Page) -> ^Sw_Registration {
	if p == nil || p.web == nil || p.worker != nil || sw_registry.active == 0 || sw_is_host(p) { return nil }
	// (an unregistered registration still controls the pages it controlled: Service Workers "Unregister")
	r := sw_match(p.env.location.href, true, uninstalling = true)
	if r == nil { return nil }
	if r.uninstalling && !r.claimed[p.web.id] && p.web.id > r.uninstall_after { return nil }
	if p.web.id > r.after_page || r.claimed[p.web.id] { return r }
	return nil
}

// Whether the registration's active version controls an open page.
@(private)
sw_has_clients :: proc(r: ^Sw_Registration) -> bool {
	for _, pg in live_pages { if !pg.closed && !pg.web.frozen && sw_controller(pg) == r { return true } }
	return false
}

////////////////////////////////
// Running a version's worker

@(private)
sw_console :: proc(user: rawptr, level: Log_Level, message: string) {
	v := (^Sw_Version)(user)
	text := fmt.tprintf("[service worker %s] %s", v.script, message)
	for _, pg in live_pages {
		if pg.closed || sw_is_host(pg) { continue }
		if url.origin_serialize(pg.env.origin, context.temp_allocator) == v.reg.origin { log(pg, level, text) }
	}
}

// Starts the version's worker in a host page made like `like` (or what the registry noted). False when it could not
// start (workers disabled, too many...).
@(private)
sw_version_start :: proc(v: ^Sw_Version, like: ^Page = nil) -> bool {
	if v.worker != nil { return true }
	if like != nil { sw_note_page(like) }
	if sw_registry.loader == nil || sw_registry.settings == nil { return false }
	if sw_registry.scope == nil { sw_registry.scope = base.scope_make("service-workers") }
	hp := page_create(sw_registry.loop, sw_registry.loader, sw_registry.settings, sw_registry.scope, v.reg.scope, sw_console, v)
	hp.web.embedder.storage = sw_registry.storage
	// (the version first: the worker's thread may start before worker_create returns)
	v.host_page = hp
	obj := worker_create(hp, v.script, "", 0, javascript = true, module = v.module, image = v.image, sw = v)
	h := (^Worker_Host)(object_data(hp, obj, &worker_vt)) if obj != 0 else nil
	if h == nil || h.state == .Exited { v.host_page = nil; page_close(hp); return false }
	// the policy its script came with (a stored script: as when it was installed)
	if !h.env.origin.opaque {
		for s in v.csp {
			if strings.has_prefix(s, "\x00") { csp.parse_header(&h.env.policies, s[1:], .Report_Only) } else { csp.parse_header(&h.env.policies, s, .Enforce) }
		}
	}
	v.host_page, v.worker, v.running = hp, h, false
	sw_touch(v)
	return true
}

// Stops the version's worker (idle, redundant, unregistered): the version itself stays.
@(private)
sw_version_stop :: proc(v: ^Sw_Version) {
	if v.idle != base.NIL_HANDLE && sw_registry.loop != nil { host.clear_timer(sw_registry.loop, v.idle); v.idle = base.NIL_HANDLE }
	if v.host_page != nil { hp := v.host_page; v.host_page, v.worker, v.running = nil, nil, false; page_close(hp) }
	for m in v.queue { msg_free(m) }
	clear(&v.queue)
	v.pending = 0
}

// Something happened for the version: its idle countdown starts again.
@(private)
sw_touch :: proc(v: ^Sw_Version) {
	if sw_registry.loop == nil || sw_registry.settings == nil { return }
	ms := sw_registry.settings.sw.idle_ms
	if v.idle != base.NIL_HANDLE { host.clear_timer(sw_registry.loop, v.idle); v.idle = base.NIL_HANDLE }
	if ms <= 0 || v.worker == nil { return }
	v.idle = host.set_timer(sw_registry.loop, f64(ms), 0, sw_idle_fire, rawptr(uintptr(v.id)))
}

@(private)
sw_idle_fire :: proc(data: rawptr) {
	v := sw_version_by_id(u64(uintptr(data)))
	if v == nil { return }
	v.idle = base.NIL_HANDLE
	// busy: an event waits for its answer, or the version is in the middle of installing / activating
	if v.pending > 0 || v.state == .Installing || v.state == .Activating || v.state == .Parsed || !v.running { sw_touch(v); return }
	sw_version_stop(v)
}

// Sends an event to the version's worker (started if it is not running; queued until its script ran).
@(private)
sw_send :: proc(v: ^Sw_Version, m: ^Worker_Msg) {
	if v.worker == nil && !sw_version_start(v) { msg_free(m); return }
	sw_touch(v)
	if !v.running { append(&v.queue, m); return }
	link_send(v.worker.link, true, m)
}

@(private)
sw_event :: proc(kind: Sw_Event_Kind, id: u64 = 0) -> ^Worker_Msg {
	m := new(Worker_Msg)
	m.kind, m.code, m.id = .Sw_Event, i64(kind), id
	return m
}

// The registration's state as its realms read it (ServiceWorkerRegistration_info).
@(private)
sw_reg_info :: proc(r: ^Sw_Registration, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	vid :: proc(v: ^Sw_Version) -> u64 { return v != nil ? v.id : 0 }
	fmt.sbprintf(&b, "%s\n%s\n%d\n%d\n%d\n%d\n%s", r.scope, r.via_cache, vid(r.installing), vid(r.waiting), vid(r.active), r.preload ? 1 : 0, sw_escape(r.preload_header))
	// then a line per version: id TAB state TAB script (what a service worker's realm reads ServiceWorker_info from)
	for v in ([3]^Sw_Version{r.installing, r.waiting, r.active}) {
		if v != nil { fmt.sbprintf(&b, "\n%d\t%s\t%s", v.id, SW_STATE_NAMES[v.state], v.script) }
	}
	return strings.to_string(b)
}

// The registration changed (a version's state, a new version, navigation preload): every realm that may show it
// learns it (pages refresh their objects: statechange, updatefound; running versions get the new state).
@(private)
sw_changed :: proc(r: ^Sw_Registration, also: ^Sw_Version = nil) {
	info := sw_reg_info(r)
	versions := [4]^Sw_Version{r.installing, r.waiting, r.active, also}
	for v, i in versions {
		if v == nil || v.worker == nil || !v.running { continue }
		dup := false
		for k in 0 ..< i { if versions[k] == v { dup = true } }
		if dup { continue }
		m := sw_event(.Registration)
		m.text = strings.clone(info)
		link_send(v.worker.link, true, m)
	}
	for _, pg in live_pages {
		if pg.closed || sw_is_host(pg) || url.origin_serialize(pg.env.origin, context.temp_allocator) != r.origin { continue }
		sw_notify_page(pg, 2, nil)
	}
}

@(private)
sw_set_state :: proc(v: ^Sw_Version, s: Sw_State) {
	v.state = s
	sw_changed(v.reg, v)
}

// The worker's script failed to load or threw: an installing version becomes redundant, register() rejects.
sw_instance_error :: proc(h: ^Worker_Host, message: string) {
	v := h.sw
	if v == nil { return }
	sw_console(v, .Error, message)
	if v.worker != h { return }   // (it could not even start: sw_version_start says so)
	if v.running && v.state != .Parsed { return }   // an error of an event's listener: the worker goes on
	r := v.reg
	sw_reject_registering(r, message)
	if v.state == .Parsed || v.state == .Installing { sw_redundant(v) } else { sw_version_stop(v) }
}

@(private)
sw_reject_registering :: proc(r: ^Sw_Registration, message: string) {
	for w in r.registering { if pg := page_by_id(w.page); pg != nil && !pg.closed { promise_reject(pg, w.promise, i64(Api_Error.Type), fmt.tprintf("TypeError: %s", message)) } }
	clear(&r.registering)
	for q in r.job_requests { sw_answer(u64(q >> 32), q & 0xFFFF_FFFF, false, message) }
	clear(&r.job_requests)
}

@(private)
sw_resolve_registering :: proc(r: ^Sw_Registration) {
	for w in r.registering { if pg := page_by_id(w.page); pg != nil && !pg.closed { promise_resolve(pg, w.promise, i64(r.id)) } }
	clear(&r.registering)
	for q in r.job_requests { sw_answer(u64(q >> 32), q & 0xFFFF_FFFF, true, "") }
	clear(&r.job_requests)
}

// A version becomes redundant: its worker stops; a registration left without versions goes.
@(private)
sw_redundant :: proc(v: ^Sw_Version) {
	r := v.reg
	if r.installing == v { r.installing = nil }
	if r.waiting == v { r.waiting = nil }
	was_active := r.active == v
	if was_active { r.active = nil }
	sw_set_state(v, .Redundant)
	sw_version_stop(v)
	if r.dir != "" { _ = os.remove(sw_script_file(r.dir, v.id)) }
	sw_version_free(v)
	if was_active && r.counted && r.active == nil { r.counted = false; sw_registry.active -= 1 }
	if r.installing == nil && r.waiting == nil && r.active == nil && r.job == base.NIL_HANDLE { sw_remove(r) } else { sw_save(r.dir) }
}

// registration.unregister(): gone at once when it controls no page, else it stops taking new clients and goes when the
// last page it controls closes (Service Workers "Unregister", "Try Clear Registration").
@(private)
sw_unregister :: proc(r: ^Sw_Registration) {
	r.uninstalling = true
	r.uninstall_after = next_page_id
	if !sw_has_clients(r) { sw_remove(r); return }
	sw_save(r.dir)   // (not kept: a restart forgets it)
	sw_changed(r)
}

// The registration goes (unregister, or nothing left of it).
@(private)
sw_remove :: proc(r: ^Sw_Registration) {
	for x, i in sw_registry.regs { if x == r { ordered_remove(&sw_registry.regs, i); break } }
	if r.counted { sw_registry.active -= 1; r.counted = false }
	for v in ([3]^Sw_Version{r.installing, r.waiting, r.active}) {
		if v == nil { continue }
		v.state = .Redundant
		if r.dir != "" { _ = os.remove(sw_script_file(r.dir, v.id)) }
	}
	sw_reject_registering(r, "the registration was removed")
	for _, pg in live_pages {
		if !pg.closed && !sw_is_host(pg) && url.origin_serialize(pg.env.origin, context.temp_allocator) == r.origin { sw_notify_page(pg, 2, nil) }
	}
	sw_save(r.dir)
	sw_reg_free(r)
}

////////////////////////////////
// Update (Service Workers "update" and "install" jobs)

// Fetches the registration's script (`script`, of `module` type); a different script than the newest version's is a
// new version that installs. `waiter`: a register() / update() promise.
@(private)
sw_update :: proc(r: ^Sw_Registration, script: string, module: bool, waiter: Maybe(Sw_Waiter), force_network := false) {
	if w, ok := waiter.?; ok { append(&r.registering, w) }
	if r.job != base.NIL_HANDLE { return }   // a check in flight answers them all
	if sw_registry.loader == nil { sw_reject_registering(r, "the service worker's script cannot be fetched now"); return }
	if script != r.script { delete(r.script); r.script = strings.clone(script) }
	r.module = module
	// updateViaCache: "all" lets the HTTP cache answer (unless the last check is a day old), else it is bypassed
	cache := fetch.Cache_Mode.No_Cache
	if r.via_cache == "all" && !force_network && sw_now() - r.last_check < 86400 { cache = .Default }
	clear(&r.job_body)
	for s in r.job_csp { delete(s) }
	clear(&r.job_csp)
	delete(r.job_error)
	r.job_error, r.job_status = "", 0
	scope_u, _ := url.parse_absolute(r.scope, context.temp_allocator)
	fetch.environment_destroy(&r.job_env)
	r.job_env = fetch.environment_make(scope_u)
	headers := [1]fetch.Header_Pair{{"Service-Worker", "script"}}
	r.job = fetch.start(sw_registry.loader, {
		request = {url = script, mode = .Same_Origin, credentials = .Same_Origin, destination = .Worker, cache = cache, initiator = &r.job_env,
			script = module ? .Module : .Classic, headers = headers[:], skip_service_worker = true},
		on_event = sw_job_event, user = rawptr(uintptr(r.id)), collect = true,
	})
}

@(private)
sw_job_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	r := sw_by_id(u64(uintptr(user)))
	if r == nil || r.job != task { return }
	#partial switch ev.kind {
	case .Response:
		res := ev.response
		r.job_status = res.status
		for h in res.headers.list {
			if strings.equal_fold(h.name, "content-security-policy") { append(&r.job_csp, strings.clone(h.value)) }
			if strings.equal_fold(h.name, "content-security-policy-report-only") { append(&r.job_csp, strings.concatenate({"\x00", h.value})) }
			if strings.equal_fold(h.name, "service-worker-allowed") && !sw_scope_allowed(r, h.value) {
				delete(r.job_error)
				r.job_error = fmt.aprintf("SecurityError: the scope %s is not allowed by Service-Worker-Allowed: %s", r.scope, h.value)
			}
		}
		if !strings.has_prefix(r.scope, sw_script_dir(r.script)) && !sw_has_allowed(res.headers.list[:]) && r.job_error == "" {
			r.job_error = fmt.aprintf("SecurityError: the scope %s is not under the script's directory %s (no Service-Worker-Allowed header)", r.scope, sw_script_dir(r.script))
		}
	case .Failed:
		r.job = base.NIL_HANDLE
		sw_job_failed(r, ev.detail)
	case .Done:
		r.job = base.NIL_HANDLE
		if r.job_error != "" { sw_job_failed(r, r.job_error); return }
		if r.job_status < 200 || r.job_status >= 300 { sw_job_failed(r, fmt.tprintf("HTTP %d for %s", r.job_status, r.script)); return }
		sw_job_done(r, ev.data)
	}
}

@(private)
sw_script_dir :: proc(script: string) -> string {
	s := script
	if q := strings.index_byte(s, '?'); q >= 0 { s = s[:q] }   // (a slash of the query is not the script's directory)
	return s[:strings.last_index_byte(s, '/') + 1]
}

@(private)
sw_has_allowed :: proc(list: []http.Header) -> bool {
	for h in list { if strings.equal_fold(h.name, "service-worker-allowed") { return true } }
	return false
}

// Service-Worker-Allowed: the most a script may control (a path, resolved against the script).
@(private)
sw_scope_allowed :: proc(r: ^Sw_Registration, value: string) -> bool {
	base_u, ok := url.parse_absolute(r.script, context.temp_allocator)
	if !ok { return false }
	max_u, ok2 := url.parse(strings.trim_space(value), &base_u, context.temp_allocator)
	if !ok2 || !url.same_origin(url.origin_of(max_u, context.temp_allocator), url.origin_of(base_u, context.temp_allocator)) { return false }
	return strings.has_prefix(r.scope, url.without_fragment(max_u))
}

@(private)
sw_job_failed :: proc(r: ^Sw_Registration, why: string) {
	msg := strings.clone(why, context.temp_allocator)
	sw_reject_registering(r, msg)
	if r.installing == nil && r.waiting == nil && r.active == nil { sw_remove(r) }
}

@(private)
sw_job_done :: proc(r: ^Sw_Registration, body: []byte) {
	r.last_check = sw_now()
	newest := r.installing != nil ? r.installing : (r.waiting != nil ? r.waiting : r.active)
	if newest != nil && newest.script == r.script && newest.module == r.module && newest.image != nil && string(newest.image) == string(body) {
		// the same script: nothing to install (Service Workers "update": byte-for-byte equal)
		sw_save(r.dir)
		sw_resolve_registering(r)
		return
	}
	if r.installing != nil { sw_redundant(r.installing) }   // a newer script replaces a version still installing
	v := sw_version_new(r, r.script, r.module)
	v.image = make([]byte, len(body))
	copy(v.image, body)
	for s in r.job_csp { append(&v.csp, strings.clone(s)) }
	v.state = .Parsed
	r.installing = v
	sw_changed(r)   // updatefound
	if !sw_version_start(v) {
		sw_reject_registering(r, "the service worker could not start (workers disabled or too many)")
		sw_redundant(v)
	}
}

// A navigation in the scope: the script is checked when the last check is older than the preference says.
@(private)
sw_soft_update :: proc(r: ^Sw_Registration) {
	if r.active == nil || r.job != base.NIL_HANDLE || sw_registry.settings == nil { return }
	hours := i64(sw_registry.settings.sw.update_hours)
	if sw_now() - r.last_check < hours * 3600 { return }
	sw_update(r, r.script, r.module, nil, force_network = true)
}

////////////////////////////////
// The worker's answers (UI thread)

sw_page_reply :: proc(h: ^Worker_Host, m: ^Worker_Msg) {
	v := h.sw
	if v == nil || v.worker != h { return }
	r := v.reg
	sw_touch(v)
	switch Sw_Reply_Kind(m.code) {
	case .None:
	case .Script_Ran:
		v.running = true
		if v == r.installing { sw_resolve_registering(r) }
		for q in v.queue { link_send(h.link, true, q) }
		clear(&v.queue)
		// the worker learns its registration's state, then its first event
		info := sw_event(.Registration)
		info.text = strings.clone(sw_reg_info(r))
		link_send(h.link, true, info)
		if v.state == .Parsed {
			sw_set_state(v, .Installing)
			v.pending += 1
			sw_send(v, sw_event(.Install))
		}
	case .Install_Done:
		v.pending = max(v.pending - 1, 0)
		if m.code2 == 0 { sw_console(v, .Error, "installation failed (a promise given to waitUntil rejected)"); sw_redundant(v); return }
		if r.waiting != nil && r.waiting != v { sw_redundant(r.waiting) }
		if r.installing == v { r.installing = nil }
		r.waiting = v
		sw_set_state(v, .Installed)
		sw_try_activate(r)
	case .Activate_Done:
		v.pending = max(v.pending - 1, 0)
		if v != r.active { return }
		sw_set_state(v, .Activated)
		sw_save(r.dir)
		sw_wake_ready()
		if v.claim_pending { v.claim_pending = false; sw_claim(r) }
	case .Skip_Waiting:
		v.skip_waiting = true
		if v == r.waiting { sw_try_activate(r) }
	case .Claim:
		// (called from the activate event: done once the version is active)
		if v == r.active && v.state == .Activated { sw_claim(r) } else { v.claim_pending = true }
	case .Post_Client:
		target := u64(m.code2)
		if target >= SW_WORKER_CLIENT_BASE {
			// a worker client: its thread gets it (sw_client_message)
			for _, pg in live_pages {
				for wh in pg.workers.hosts {
					if wh.client_id != target || wh.terminated || wh.state != .Running { continue }
					msg := new(Worker_Msg)
					msg.kind, msg.id = .Sw_Client, v.id
					msg.bytes = make([]byte, len(m.bytes))
					copy(msg.bytes, m.bytes)
					link_send(wh.link, true, msg)
				}
			}
			return
		}
		for id, pg in live_pages {
			if pg.closed || sw_is_host(pg) || (target != 0 && id != target) { continue }
			if sw_controller(pg) != r && target == 0 { continue }
			sw_queue_message(pg, v.id, m.bytes)
		}
	case .Respond, .Fall_Back, .Fail:
		v.pending = max(v.pending - 1, 0)
		f, ok := sw_registry.fetches[m.id]
		if !ok { return }
		if f.timer != base.NIL_HANDLE { host.clear_timer(f.loop, f.timer); f.timer = base.NIL_HANDLE }
		#partial switch Sw_Reply_Kind(m.code) {
		case .Respond:
			fetch.sw_respond(f.loader, f.task, int(m.code2), m.text, m.bytes)
			f.answered = true
		case .Fall_Back:
			if f.pre_state != 0 { f.fall_back = true; sw_preload_settle(f); return }   // the preload's response answers
			fetch.sw_fall_back(f.loader, f.task)
			f.answered = true
		case .Fail:
			fetch.sw_fail(f.loader, f.task, m.text2)
			f.answered = true
		}
		sw_fetch_done(f)
	case .Request:
		v.pending += 1
		sw_request(v, m.id, Sw_Request_Op(m.code2), m.text2, m.text)
	case .Preload:
		sw_preload_op(r, i32(m.code2), m.text2)
	}
}

// A fetch event is over when the loader's task is settled and its preload (if any) went to the worker.
@(private)
sw_fetch_done :: proc(f: ^Sw_Fetch) {
	if !f.answered || f.pre_state == 1 { return }
	delete_key(&sw_registry.fetches, f.id)
	sw_fetch_free(f)
}

// clients.claim(): the pages in the scope that are not controlled yet become controlled (controllerchange).
@(private)
sw_claim :: proc(r: ^Sw_Registration) {
	for id, pg in live_pages {
		if pg.closed || sw_is_host(pg) || sw_match(pg.env.location.href, true) != r { continue }
		if pg.web.id > r.after_page || r.claimed[id] { continue }
		r.claimed[id] = true
		sw_notify_page(pg, 0, nil)
	}
}

// The waiting version activates when nothing uses the active one, or when it called skipWaiting().
@(private)
sw_try_activate :: proc(r: ^Sw_Registration) {
	w := r.waiting
	if w == nil || w.state != .Installed { return }
	if r.active != nil && !w.skip_waiting && sw_has_clients(r) { return }
	old := r.active
	controlled := make([dynamic]^Page, context.temp_allocator)
	if old != nil { for _, pg in live_pages { if !pg.closed && sw_controller(pg) == r { append(&controlled, pg) } } }
	r.waiting = nil
	r.active = w
	if old != nil { sw_redundant(old) }
	if !r.counted {
		r.counted = true
		r.after_page = next_page_id
		sw_registry.active += 1
	}
	sw_store_script(w)
	sw_set_state(w, .Activating)
	for pg in controlled { sw_notify_page(pg, 0, nil) }   // their controller is the new version
	w.pending += 1
	sw_send(w, sw_event(.Activate))
	sw_save(r.dir)
}

// A document went away: a waiting version may activate now that its old version has one client less.
sw_page_gone :: proc(p: ^Page) {
	if p.web == nil { return }
	if q, ok := sw_registry.inbox[p.web.id]; ok {
		for m in q { delete(m) }
		delete(q)
		delete_key(&sw_registry.inbox, p.web.id)
	}
	if len(sw_registry.regs) == 0 || sw_registry.loop == nil || sw_is_host(p) { return }
	host.post(sw_registry.loop, proc(_: rawptr) {
		for i := len(sw_registry.regs) - 1; i >= 0; i -= 1 {
			if i >= len(sw_registry.regs) { continue }
			r := sw_registry.regs[i]
			if r.uninstalling && !sw_has_clients(r) { sw_remove(r); continue }   // its last client went
			if r.waiting != nil { sw_try_activate(r) }
		}
	}, nil)
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

// A message for page `pg` from version `version` (its serialized data).
@(private)
sw_queue_message :: proc(pg: ^Page, version: u64, data: []byte) {
	q := sw_registry.inbox[pg.web.id]
	msg := make([]byte, 8 + len(data))
	for i in 0 ..< 8 { msg[i] = u8(version >> (8 * uint(i))) }
	copy(msg[8:], data)
	append(&q, msg)
	sw_registry.inbox[pg.web.id] = q
	sw_notify_page(pg, 1, nil)
}

// navigator.serviceWorker's events in a page: 0 controllerchange, 1 messages wait (ServiceWorker_takeMessage),
// 2 a registration of its origin changed (the engine compares its objects' states: statechange, updatefound).
// From a task of the page: this may run in the middle of one of its own calls (unregister(), a preload setting).
@(private)
sw_notify_page :: proc(pg: ^Page, kind: u32, _: []byte) {
	if pg.js == nil { return }   // no realm: nobody listens
	post_page_task(pg, proc(p: ^Page, data: rawptr) {
		if p == nil || p.closed { return }
		r := js_realm(p)
		if r == nil { return }
		argv := [1]u32{u32(uintptr(data))}
		js_call(p, r.inst, "wj_sw_container_event", argv[:])
	}, rawptr(uintptr(kind)))
}

////////////////////////////////
// Requests of a worker (clients, update, unregister)

// The answer of request `request` of version `version`: an Answer event (`ok` false: rejected, `text` says why).
@(private)
sw_answer :: proc(version, request: u64, ok: bool, text: string) {
	v := sw_version_by_id(version)
	if v == nil { return }
	v.pending = max(v.pending - 1, 0)
	m := sw_event(.Answer, request)
	m.code2 = ok ? 0 : 1
	m.text = strings.clone(text)
	sw_send(v, m)
}

// A client of the registration as a service worker reads it: id TAB url TAB type TAB frameType TAB visibility TAB focused.
@(private)
sw_client_line :: proc(b: ^strings.Builder, pg: ^Page, focused_now := false) {
	if strings.builder_len(b^) > 0 { strings.write_byte(b, '\n') }
	nested := pg.frames != nil && pg.frames.nav != nil && pg.frames.nav.parent != nil
	focused := focused_now || (pg.web.visible && !nested)   // (a shown top-level document: the shell shows one tab)
	fmt.sbprintf(b, "%d\t%s\twindow\t%s\t%s\t%d", pg.web.id, pg.env.location.href, nested ? "nested" : "top-level", pg.web.visible ? "visible" : "hidden", focused ? 1 : 0)
}

@(private)
sw_client_page :: proc(r: ^Sw_Registration, text: string) -> ^Page {
	id, ok := strconv.parse_u64(strings.trim_space(text))
	if !ok { return nil }
	pg := page_by_id(id)
	if pg == nil || pg.closed || sw_is_host(pg) || url.origin_serialize(pg.env.origin, context.temp_allocator) != r.origin { return nil }
	return pg
}

// Service Workers: openWindow and focus need a user activation. A service worker has no input of its own (it would be a
// notification click, which this browser does not have): a click or key press in a window of its origin within
// service_workers.window_activation_ms stands for it.
@(private)
sw_origin_activated :: proc(origin: string) -> bool {
	ms := sw_registry.settings != nil ? sw_registry.settings.sw.window_activation_ms : 5000
	for _, pg in live_pages {
		if pg.closed || pg.worker != nil || sw_is_host(pg) || url.origin_serialize(pg.env.origin, context.temp_allocator) != origin { continue }
		if age, had := activation_age_ns(pg); had && age <= i64(ms) * 1_000_000 { return true }
	}
	return false
}

@(private)
sw_request :: proc(v: ^Sw_Version, request: u64, op: Sw_Request_Op, text, extra: string) {
	r := v.reg
	if (op == .Open_Window || op == .Focus) && !sw_origin_activated(r.origin) {
		sw_answer(v.id, request, false, "InvalidAccessError: opening or focusing a window needs a user gesture")
		return
	}
	switch op {
	case .None:
		sw_answer(v.id, request, false, "unknown request")
	case .Match_All:
		// "includeUncontrolled TAB type": windows of the origin, controlled by this registration unless asked
		f := strings.split(extra, "\t", context.temp_allocator)
		uncontrolled := len(f) > 0 && f[0] == "1"
		type := len(f) > 1 ? f[1] : "window"
		b := strings.builder_make(context.temp_allocator)
		if type == "window" || type == "all" {
			ids := make([dynamic]u64, context.temp_allocator)
			for id, pg in live_pages {
				// (a document in the back/forward cache is not a client: it is not fully active)
				if pg.closed || pg.worker != nil || pg.web.frozen || sw_is_host(pg) || url.origin_serialize(pg.env.origin, context.temp_allocator) != r.origin { continue }
				if !uncontrolled && sw_controller(pg) != r { continue }
				append(&ids, id)
			}
			// most recently created first (the order of focus is not known here)
			for i := len(ids) - 1; i >= 0; i -= 1 {
				for k in 0 ..< i { if ids[k] > ids[k + 1] { ids[k], ids[k + 1] = ids[k + 1], ids[k] } }
			}
			for i := len(ids) - 1; i >= 0; i -= 1 { sw_client_line(&b, page_by_id(ids[i])) }
		}
		if type == "worker" || type == "all" {
			// dedicated workers: clients of their document's controller (HTML: a worker inherits it)
			for _, pg in live_pages {
				if pg.closed || pg.worker != nil || sw_is_host(pg) || url.origin_serialize(pg.env.origin, context.temp_allocator) != r.origin { continue }
				if !uncontrolled && sw_controller(pg) != r { continue }
				for h in pg.workers.hosts {
					if !h.javascript || h.terminated || h.state != .Running || h.sw != nil || h.shared != nil { continue }
					if strings.builder_len(b) > 0 { strings.write_byte(&b, '\n') }
					fmt.sbprintf(&b, "%d\t%s\tworker\tnone\thidden\t0", h.client_id, h.url)
				}
			}
		}
		if (type == "sharedworker" || type == "all") && uncontrolled {
			for s in shared_workers {
				if s.gone || s.worker == nil || !strings.has_prefix(s.key, r.origin) { continue }
				if strings.builder_len(b) > 0 { strings.write_byte(&b, '\n') }
				fmt.sbprintf(&b, "%d\t%s\tsharedworker\tnone\thidden\t0", s.worker.client_id, s.url)
			}
		}
		sw_answer(v.id, request, true, strings.to_string(b))
	case .Get:
		b := strings.builder_make(context.temp_allocator)
		if pg := sw_client_page(r, text); pg != nil && pg.worker == nil { sw_client_line(&b, pg) }
		sw_answer(v.id, request, true, strings.to_string(b))
	case .Open_Window:
		open := sw_embedder.open
		if open == nil { sw_answer(v.id, request, false, "InvalidAccessError: this browser cannot open a window now"); return }
		after := next_page_id
		if !open(sw_embedder.user, text) { sw_answer(v.id, request, false, "InvalidAccessError: the window was not opened"); return }
		sw_wait_document(v, request, after, text)
	case .Navigate:
		pg := sw_client_page(r, extra)
		if pg == nil || sw_controller(pg) != r { sw_answer(v.id, request, false, "TypeError: the client is not controlled by this service worker"); return }
		nav := pg.web.embedder.navigate
		if nav == nil { sw_answer(v.id, request, false, "TypeError: the client cannot navigate"); return }
		after := next_page_id
		Nav :: struct { page: u64, url: string }
		n := new(Nav)
		n^ = {pg.web.id, strings.clone(text)}
		// a navigation reaches the embedder from a task of its own (web.odin)
		host.post(sw_registry.loop, proc(data: rawptr) {
			n := (^Nav)(data)
			defer { delete(n.url); free(n) }
			if pg := page_by_id(n.page); pg != nil && !pg.closed && pg.web.embedder.navigate != nil {
				pg.web.embedder.navigate(pg.web.embedder.user, pg, {kind = .Assign, url = n.url})
			}
		}, n)
		sw_wait_document(v, request, after, text)
	case .Focus:
		pg := sw_client_page(r, text)
		focus := sw_embedder.focus
		if pg == nil || focus == nil || !focus(sw_embedder.user, pg) { sw_answer(v.id, request, false, "InvalidAccessError: the client cannot be focused"); return }
		b := strings.builder_make(context.temp_allocator)
		sw_client_line(&b, pg, focused_now = true)
		sw_answer(v.id, request, true, strings.to_string(b))
	case .Update:
		v.pending = max(v.pending - 1, 0)
		append(&r.job_requests, v.id << 32 | (request & 0xFFFF_FFFF))
		v.pending += 1
		sw_update(r, r.script, r.module, nil, force_network = true)
	case .Unregister:
		sw_answer(v.id, request, true, "1")
		sw_unregister(r)
	}
}

// openWindow / navigate: answered with the document that opens at `u` (a client when it is of the origin, else null),
// or null after service_workers.fetch_timeout_ms.
@(private)
sw_wait_document :: proc(v: ^Sw_Version, request, after: u64, u: string) {
	timeout := sw_registry.settings != nil ? sw_registry.settings.sw.fetch_timeout_ms : 30_000
	append(&sw_registry.opens, Sw_Open{version = v.id, request = request, after = after, url = strings.clone(u), deadline = time.tick_add(time.tick_now(), time.Duration(timeout) * time.Millisecond)})
	if sw_registry.open_timer == base.NIL_HANDLE { sw_registry.open_timer = host.set_timer(sw_registry.loop, 50, 50, sw_opens_poll, nil) }
}

@(private)
sw_opens_poll :: proc(_: rawptr) {
	k := 0
	for o in sw_registry.opens {
		found: ^Page
		for id, pg in live_pages {
			if id <= o.after || pg.closed || pg.worker != nil || sw_is_host(pg) { continue }
			if pg.env.location.href == o.url || strings.has_prefix(pg.env.location.href, url_without_fragment(o.url)) { found = pg; break }
		}
		timed_out := time.tick_diff(o.deadline, time.tick_now()) > 0
		if found == nil && !timed_out { sw_registry.opens[k] = o; k += 1; continue }
		b := strings.builder_make(context.temp_allocator)
		if v := sw_version_by_id(o.version); found != nil && v != nil && url.origin_serialize(found.env.origin, context.temp_allocator) == v.reg.origin { sw_client_line(&b, found) }
		sw_answer(o.version, o.request, true, strings.to_string(b))
		delete(o.url)
	}
	resize(&sw_registry.opens, k)
	if k == 0 && sw_registry.open_timer != base.NIL_HANDLE { host.clear_timer(sw_registry.loop, sw_registry.open_timer); sw_registry.open_timer = base.NIL_HANDLE }
}

////////////////////////////////
// Navigation preload

@(private)
sw_preload_op :: proc(r: ^Sw_Registration, op: i32, header: string) -> (state: string, ok: bool) {
	switch op {
	case 1, 2:
		if r.active == nil { return "", false }
		r.preload = op == 1
	case 3:
		delete(r.preload_header)
		r.preload_header = strings.clone(header)
	}
	if op != 0 { sw_save(r.dir); sw_changed(r) }
	return fmt.tprintf("%d\n%s", r.preload ? 1 : 0, r.preload_header), true
}

// The preload's events: its response, kept whole.
@(private)
sw_preload_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	f, ok := sw_registry.fetches[u64(uintptr(user))]
	if !ok || f.preload != task { return }
	#partial switch ev.kind {
	case .Response:
		res := ev.response
		f.pre_status = res.status
		delete(f.pre_url); delete(f.pre_headers)
		f.pre_url = strings.clone(res.url)
		f.pre_headers = serialize_headers(res.headers.list[:], context.allocator)
	case .Done:
		f.preload = base.NIL_HANDLE
		f.pre_state = 2
		append(&f.pre_body, ..ev.data)
		sw_preload_settle(f)
	case .Failed:
		f.preload = base.NIL_HANDLE
		f.pre_state = 3
		sw_preload_settle(f)
	}
}

// The preload finished (or the worker gave up on the request): the worker gets the response, and a request the
// worker did not answer gets it too.
@(private)
sw_preload_settle :: proc(f: ^Sw_Fetch) {
	if f.pre_state == 1 { return }
	if v := sw_version_by_id(f.version); v != nil && v.worker != nil && !f.pre_sent {
		f.pre_sent = true
		m := sw_event(.Preload, f.id)
		m.code2 = f.pre_state == 2 ? i64(f.pre_status) : 0
		m.text, m.text3 = strings.clone(f.pre_url), strings.clone(f.pre_headers)
		if f.pre_state == 2 { m.bytes = make([]byte, len(f.pre_body)); copy(m.bytes, f.pre_body[:]) }
		sw_send(v, m)
	}
	if f.fall_back && !f.answered {
		f.answered = true
		if f.pre_state == 2 { fetch.sw_respond(f.loader, f.task, f.pre_status, f.pre_headers, f.pre_body[:]) } else { fetch.sw_fall_back(f.loader, f.task) }
	}
	sw_fetch_done(f)
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
	if client != nil { sw_note_page(client) }
	r: ^Sw_Registration
	navigation := t.mode == .Navigate && (t.destination == .Document || fetch.is_frame_destination(t.destination))
	if navigation {
		r = sw_match(t.target.href, true)
	} else {
		r = sw_controller(client)
	}
	if r == nil || r.active == nil { return false }
	if client == nil && sw_registry.loader == nil { for _, pg in live_pages { if !pg.closed && pg.loader != nil && !sw_is_host(pg) { sw_note_page(pg); break } } }
	v := r.active
	if v.worker == nil && !sw_version_start(v) { return false }
	sw_registry.next_fetch += 1
	id := sw_registry.next_fetch
	f := new(Sw_Fetch)
	f.loader, f.task, f.id, f.version = t.loader, t.self, id, v.id
	f.loop = v.host_page.loop
	sw_registry.fetches[id] = f
	timeout := v.host_page.settings.sw.fetch_timeout_ms
	f.timer = host.set_timer(f.loop, f64(timeout), 0, sw_fetch_timeout, rawptr(uintptr(id)))
	m := sw_event(.Fetch, id)
	m.text, m.text2 = strings.clone(t.target.href), strings.clone(t.method)
	hb := strings.builder_make()
	for e in t.headers.list { fmt.sbprintf(&hb, "%s: %s\r\n", e.name, e.value) }
	m.text3 = strings.to_string(hb)
	if len(t.body) > 0 { m.bytes = make([]byte, len(t.body)); copy(m.bytes, t.body) }
	client_id := client != nil ? client.web.id : 0
	m.code2 = i64(t.mode) | i64(t.destination) << 8 | i64(client_id) << 16
	if navigation && r.preload && t.method == "GET" {
		// navigation preload: the network request starts now, the worker may use it
		pairs := make([dynamic]fetch.Header_Pair, context.temp_allocator)
		for e in t.headers.list { append(&pairs, fetch.Header_Pair{e.name, e.value}) }
		append(&pairs, fetch.Header_Pair{"Service-Worker-Navigation-Preload", r.preload_header})
		f.pre_state = 1
		f.preload = fetch.start(t.loader, {
			request = {url = t.target.href, method = "GET", headers = pairs[:], mode = .Navigate, credentials = .Include,
				destination = t.destination, skip_service_worker = true, guard = .None},
			on_event = sw_preload_event, user = rawptr(uintptr(id)), collect = true,
		})
		m.code2 |= SW_FETCH_PRELOAD
	}
	v.pending += 1
	sw_send(v, m)
	if navigation { sw_soft_update(r) }
	return true
}

// A fetch event's flag (Worker_Msg.code2): a navigation preload runs for it.
@(private)
SW_FETCH_PRELOAD :: i64(1) << 62

@(private)
sw_fetch_timeout :: proc(data: rawptr) {
	id := u64(uintptr(data))
	f, ok := sw_registry.fetches[id]
	if !ok { return }
	f.timer = base.NIL_HANDLE
	if v := sw_version_by_id(f.version); v != nil { v.pending = max(v.pending - 1, 0) }
	if !f.answered { f.answered = true; fetch.sw_fall_back(f.loader, f.task) }
	if f.preload != base.NIL_HANDLE { fetch.cancel(f.loader, f.preload); f.preload = base.NIL_HANDLE }
	f.pre_state = 0
	delete_key(&sw_registry.fetches, id)
	sw_fetch_free(f)
}

////////////////////////////////
// Module "serviceworker", page side (api/serviceworker.widl)

@(private)
sw_scope_of :: proc(c: ^Call, script: string, scope: Maybe(string)) -> (script_url, scope_url: string, err: Api_Error) {
	p := c.page
	if !p.env.secure_context { return "", "", fail(c, .Security, "SecurityError: service workers need a secure context") }
	if !p.settings.sw.enabled { return "", "", fail(c, .Security, "SecurityError: service workers are disabled (service_workers.enabled)") }
	base_u := p.env.location
	su, ok := url.parse(script, &base_u, context.temp_allocator)
	if !ok || (su.scheme != "http" && su.scheme != "https") { return "", "", fail(c, .Type, "TypeError: invalid script URL") }
	if !url.same_origin(url.origin_of(su, context.temp_allocator), p.env.origin) { return "", "", fail(c, .Security, "SecurityError: the script's origin is not the document's") }
	// (Service Workers "register": a given scope is parsed against the document's URL, the default "./" against the
	// script's; the query stays part of the scope, only the fragment goes)
	scu: url.URL
	ok2: bool
	if s, given := scope.?; given { scu, ok2 = url.parse(s, &base_u, context.temp_allocator) } else { scu, ok2 = url.parse("./", &su, context.temp_allocator) }
	if !ok2 || !url.same_origin(url.origin_of(scu, context.temp_allocator), p.env.origin) { return "", "", fail(c, .Security, "SecurityError: the scope's origin is not the document's") }
	scope_str := url.without_fragment(scu)
	// (a scope above the script's directory needs the script's Service-Worker-Allowed header: checked by the job)
	return url.without_fragment(su), scope_str, .None
}

// (The registry belongs to the interface thread: from a worker's realm the page-side functions refuse or answer
// nothing; navigator.serviceWorker is a document's.)
@(private)
sw_off_thread :: #force_inline proc(c: ^Call) -> bool { return c.page.worker != nil }

ServiceWorker_register :: proc(c: ^Call, script: string, scope: Maybe(string), via_cache: string, module: bool) -> (u64, Api_Error) {
	p := c.page
	if sw_off_thread(c) { return 0, fail(c, .Not_Supported, "NotSupportedError: service workers are registered from documents") }
	su, sc, err := sw_scope_of(c, script, scope)
	if err != .None { return 0, err }
	sw_note_page(p)
	pr := promise_create(p, c.owner)
	origin := url.origin_serialize(p.env.origin, context.temp_allocator)
	r: ^Sw_Registration
	for x in sw_registry.regs { if x.scope == sc { r = x; break } }
	if r == nil {
		sw_registry.next += 1
		r = new(Sw_Registration)
		r.id, r.origin, r.scope, r.script = sw_registry.next, strings.clone(origin), strings.clone(sc), strings.clone(su)
		dir := ""
		if sm := p.web.embedder.storage; sm != nil && sm.ready { dir = sm.dir }
		r.dir = strings.clone(dir)
		r.preload_header = strings.clone("true")
		append(&sw_registry.regs, r)
	}
	if r.via_cache != via_cache { delete(r.via_cache); r.via_cache = strings.clone(via_cache) }
	if r.uninstalling { r.uninstalling = false; sw_save(r.dir) }   // registered again before it went
	newest := r.installing != nil ? r.installing : (r.waiting != nil ? r.waiting : r.active)
	if newest != nil && newest.script == su && newest.module == module && r.job == base.NIL_HANDLE && newest != r.installing {
		// Service Workers "register": the same script is already there: the registration, at once
		promise_resolve(p, pr, i64(r.id))
		return pr, .None
	}
	sw_update(r, su, module, Sw_Waiter{page_id(p), pr})
	return pr, .None
}

ServiceWorker_ready :: proc(c: ^Call) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	if sw_off_thread(c) {
		if g := sw_client_view(c); g != nil && g.client_sw_reg != 0 { promise_resolve(p, pr, i64(g.client_sw_reg)) }
		return pr
	}
	if r := sw_match(p.env.location.href, true); r != nil { promise_resolve(p, pr, i64(r.id)); return pr }
	append(&sw_registry.ready, Sw_Waiter{page_id(p), pr})
	return pr
}

ServiceWorker_getRegistration :: proc(c: ^Call, client_url: string) -> u64 {
	p := c.page
	if sw_off_thread(c) { g := sw_client_view(c); return g != nil ? g.client_sw_reg : 0 }
	base_u := p.env.location
	u := p.env.location.href
	if client_url != "" { if pu, ok := url.parse(client_url, &base_u, context.temp_allocator); ok { u = pu.href } }
	r := sw_match(u, false)
	if r == nil || r.origin != url.origin_serialize(p.env.origin, context.temp_allocator) { return 0 }
	return r.id
}

ServiceWorker_registrationIds :: proc(c: ^Call) -> string {
	if sw_off_thread(c) { g := sw_client_view(c); return g != nil && g.client_sw_reg != 0 ? fmt.tprintf("%d", g.client_sw_reg) : "" }
	origin := url.origin_serialize(c.page.env.origin, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	for r in sw_registry.regs {
		if r.origin != origin || r.uninstalling { continue }
		if strings.builder_len(b) > 0 { strings.write_byte(&b, '\n') }
		fmt.sbprintf(&b, "%d", r.id)
	}
	return strings.to_string(b)
}

ServiceWorker_controller :: proc(c: ^Call) -> u64 {
	if sw_off_thread(c) {
		g := sw_client_view(c)
		if g == nil || g.client_sw == "" { return 0 }
		f := strings.split(g.client_sw, "\n", context.temp_allocator)
		id, _ := strconv.parse_u64(len(f) > 4 ? f[4] : "0")
		return id
	}
	r := sw_controller(c.page)
	return r != nil && r.active != nil ? r.active.id : 0
}

ServiceWorkerRegistration_info :: proc(c: ^Call, id: u64) -> string {
	if g := sw_global(c); g != nil { return id == g.reg ? g.info : "" }   // a service worker's copy
	if c.page.worker != nil { g := sw_client_view(c); return g != nil && id == g.client_sw_reg ? g.client_sw : "" }
	r := sw_by_id(id)
	if r == nil { return "" }
	return sw_reg_info(r)
}

ServiceWorker_info :: proc(c: ^Call, version: u64) -> string {
	if g := sw_global(c); g != nil {
		rest := g.info
		for line in strings.split_lines_iterator(&rest) {
			f := strings.split(line, "\t", context.temp_allocator)
			if len(f) == 3 && f[0] == fmt.tprintf("%d", version) { return fmt.tprintf("%s\n%s", f[1], f[2]) }
		}
		return version == g.version ? fmt.tprintf("redundant\n%s", g.script) : ""
	}
	if c.page.worker != nil {
		// a worker client: its copy of the registration (version lines: id TAB state TAB script)
		g := sw_client_view(c)
		if g == nil { return "" }
		rest := g.client_sw
		for line in strings.split_lines_iterator(&rest) {
			f := strings.split(line, "\t", context.temp_allocator)
			if len(f) == 3 && f[0] == fmt.tprintf("%d", version) { return fmt.tprintf("%s\n%s", f[1], f[2]) }
		}
		return ""
	}
	v := sw_version_by_id(version)
	if v == nil { return "" }
	return fmt.tprintf("%s\n%s", SW_STATE_NAMES[v.state], v.script)
}

ServiceWorkerRegistration_unregisterId :: proc(c: ^Call, id: u64) -> bool {
	if sw_off_thread(c) { return false }
	r := sw_by_id(id)
	if r == nil || r.uninstalling || r.origin != url.origin_serialize(c.page.env.origin, context.temp_allocator) { return false }
	sw_unregister(r)
	return true
}

ServiceWorkerRegistration_updateId :: proc(c: ^Call, id: u64) -> (u64, Api_Error) {
	p := c.page
	if sw_off_thread(c) { return 0, fail(c, .Not_Supported, "NotSupportedError: not from a worker") }
	r := sw_by_id(id)
	if r == nil || r.origin != url.origin_serialize(p.env.origin, context.temp_allocator) { return 0, fail(c, .Invalid_State, "InvalidStateError: the registration is gone") }
	if r.installing == nil && r.waiting == nil && r.active == nil { return 0, fail(c, .Invalid_State, "InvalidStateError: the registration has no version") }
	sw_note_page(p)
	pr := promise_create(p, c.owner)
	sw_update(r, r.script, r.module, Sw_Waiter{page_id(p), pr}, force_network = true)
	return pr, .None
}

ServiceWorkerRegistration_preload :: proc(c: ^Call, id: u64, op: i32, header: string) -> (string, Api_Error) {
	if g := sw_global(c); g != nil {
		// a service worker: the browser applies it; the state read here is the copy, as updated just now
		if op != 0 {
			m := new(Worker_Msg)
			m.kind, m.code, m.code2 = .Sw_Reply, i64(Sw_Reply_Kind.Preload), i64(op)
			m.text2 = strings.clone(header)
			link_send(c.page.worker.link, false, m)
		}
		f := strings.split(g.info, "\n", context.temp_allocator)
		enabled := len(f) > 5 && f[5] == "1"
		hv := len(f) > 6 ? sw_unescape(f[6]) : "true"
		if op == 1 { enabled = true } else if op == 2 { enabled = false } else if op == 3 { hv = header }
		return fmt.tprintf("%d\n%s", enabled ? 1 : 0, hv), .None
	}
	r := sw_by_id(id)
	if r == nil || c.page.worker != nil { return "", fail(c, .Invalid_State, "InvalidStateError: the registration is gone") }
	state, ok := sw_preload_op(r, op, header)
	if !ok { return "", fail(c, .Invalid_State, "InvalidStateError: the registration has no active service worker") }
	return state, .None
}

// serviceWorker.postMessage from a page: a "message" event in the worker with the page as its source.
ServiceWorker_postToWorker :: proc(c: ^Call, version: u64, data: []u8) -> Api_Error {
	if sw_off_thread(c) {
		// a worker client: the UI thread delivers it (sw_client_post)
		if sw_client_view(c) == nil { return fail(c, .Not_Supported, "NotSupportedError: a service worker cannot post to a service worker") }
		m := new(Worker_Msg)
		m.kind, m.id = .Sw_Post, version
		m.bytes = make([]byte, len(data))
		copy(m.bytes, data)
		link_send(c.page.worker.link, false, m)
		return .None
	}
	v := sw_version_by_id(version)
	if v == nil || v.state == .Redundant { return fail(c, .Invalid_State, "InvalidStateError: the service worker is redundant") }
	sw_note_page(c.page)
	if v.worker == nil && !sw_version_start(v, c.page) { return fail(c, .Invalid_State, "InvalidStateError: the service worker could not start") }
	m := sw_event(.Message)
	m.bytes = make([]byte, len(data))
	copy(m.bytes, data)
	m.code2 = i64(page_id(c.page)) << 16
	m.text = strings.clone(c.page.env.location.href)
	sw_send(v, m)
	return .None
}

// The next message a service worker sent the page (Not_Found when none waits): the version's id then the data.
ServiceWorker_takeMessage :: proc(c: ^Call) -> ([]byte, Api_Error) {
	if sw_off_thread(c) {
		g := sw_client_view(c)
		if g == nil || len(g.client_inbox) == 0 { return nil, fail(c, .Not_Found, "no message") }
		m := g.client_inbox[0]
		ordered_remove(&g.client_inbox, 0)
		out := make([]byte, len(m), context.temp_allocator)
		copy(out, m)
		delete(m)
		return out, .None
	}
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
// Workers as clients (dedicated and shared workers: navigator.serviceWorker in a worker)

// Worker clients' ids start here (a page's id is far below).
SW_WORKER_CLIENT_BASE :: u64(1) << 40

// At a worker's start (UI thread): its view of the registration controlling its document (a dedicated worker is a
// client of its document's controller; a shared worker has none here).
sw_client_init :: proc(g: ^Worker_Global, p: ^Page) {
	r := sw_controller(p)
	if r == nil { return }
	g.client_sw_reg = r.id
	g.client_sw = strings.clone(sw_reg_info(r))
}

// A service worker's message to a worker client arrived (the worker's thread): navigator.serviceWorker's message.
sw_client_message :: proc(p: ^Page, m: ^Worker_Msg) {
	g := p.worker
	data := make([]byte, 8 + len(m.bytes))
	for i in 0 ..< 8 { data[i] = u8(m.id >> (8 * uint(i))) }
	copy(data[8:], m.bytes)
	append(&g.client_inbox, data)
	if r := js_realm(p); r != nil {
		argv := [1]u32{1}
		js_call(p, r.inst, "wj_sw_container_event", argv[:])
		js_after_task(p, r, "message")
	}
}

// serviceWorker.postMessage from a worker client (UI thread): a message event in the service worker.
sw_client_post :: proc(h: ^Worker_Host, m: ^Worker_Msg) {
	v := sw_version_by_id(m.id)
	if v == nil || v.state == .Redundant { return }
	if v.worker == nil && !sw_version_start(v, h.page) { return }
	e := sw_event(.Message)
	e.bytes, m.bytes = m.bytes, nil
	e.code2 = i64(h.client_id) << 16
	e.text = strings.clone(h.url)
	sw_send(v, e)
}

// A worker client's own view (its thread): nil when the realm is not one.
@(private)
sw_client_view :: proc(c: ^Call) -> ^Worker_Global {
	g := c.page.worker
	if g == nil || g.sw.reg != 0 { return nil }
	return g
}

////////////////////////////////
// The worker's side (its thread)

Sw_Global :: struct {
	reg:     u64,
	version: u64,
	scope:   string,
	script:  string,
	info:    string,   // the registration's state the browser sent last (ServiceWorkerRegistration_info)
	events:  [dynamic]^Worker_Msg,
}

sw_global_init :: proc(g: ^Sw_Global, v: ^Sw_Version) {
	g.reg, g.version, g.scope, g.script = v.reg.id, v.id, strings.clone(v.reg.scope), strings.clone(v.script)
	g.info = strings.clone(sw_reg_info(v.reg))
}

sw_global_free :: proc(g: ^Sw_Global) {
	for m in g.events { msg_free(m) }
	delete(g.events); delete(g.scope); delete(g.script); delete(g.info)
	g^ = {}
}

// An event arrived for the worker: kept until the engine takes it (wj_sw_event, runtime/web_sw.c).
sw_worker_event :: proc(p: ^Page, m: ^Worker_Msg) {
	g := p.worker
	if Sw_Event_Kind(m.code) == .Registration { delete(g.sw.info); g.sw.info = m.text; m.text = "" }
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

ServiceWorkerGlobalScope_version :: proc(c: ^Call) -> u64 {
	g := sw_global(c)
	return g != nil ? g.version : 0
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
	#partial switch Sw_Event_Kind(m.code) {
	case .Answer, .Preload:
		return Api_SwEventInfo{kind = i32(m.code), id = m.id, mode = i32(m.code2)}
	case .Fetch:
		return Api_SwEventInfo{kind = i32(m.code), id = m.id, mode = i32(m.code2 & 0xFF), destination = i32((m.code2 >> 8) & 0xFF),
			client = u64(m.code2 &~ SW_FETCH_PRELOAD) >> 16, flags = m.code2 & SW_FETCH_PRELOAD != 0 ? 1 : 0}
	}
	return Api_SwEventInfo{kind = i32(m.code), id = m.id, mode = i32(m.code2 & 0xFF), destination = i32((m.code2 >> 8) & 0xFF), client = u64(m.code2 >> 16)}
}

// A string of the current event: 0 URL (an answer's text), 1 method, 2 header lines.
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

// What the worker did (an event's outcome, skipWaiting, claim, a message to a client, a request): to the page side.
ServiceWorkerGlobalScope_reply :: proc(c: ^Call, kind: i32, id: u64, code: i64, headers: string, text: string, body: []u8) {
	g := sw_global(c)
	if g == nil { return }
	m := new(Worker_Msg)
	m.kind, m.code, m.id, m.code2 = .Sw_Reply, i64(kind), id, code
	m.text, m.text2 = strings.clone(headers), strings.clone(text)
	if len(body) > 0 { m.bytes = make([]byte, len(body)); copy(m.bytes, body) }
	link_send(c.page.worker.link, false, m)
}
