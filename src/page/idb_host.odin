package page

// IndexedDB for pages: the profile's idb.Manager (package idb) behind the one import "idb".Idb_call, and the delivery of its
// events to the page's JavaScript realm (native/js/prelude/idb.js, runtime/web_idb.c).
//
//   * The manager belongs to the profile's Storage_Manager (made on the first use, so a profile that never touches
//     IndexedDB pays nothing, not even a timer). The data of an origin is shared by every page of it; the pages are the
//     manager's clients, one per page and origin.
//   * A page's events (a request's result, a handler to run, a transaction that started) come from the manager's queue one
//     per task: the task hands the event to the realm (wj_idb_event, which takes it with operation 11), and the microtask
//     checkpoint after it runs before the next event, as it does after any task.
//   * A transaction is active while the script that made it (or a handler of its request) runs, microtasks included. The
//     realm asks for a call at the end of the next microtask checkpoint (operation 12) and makes its active transactions
//     inactive there (wj_idb_cleanup).
//   * Disk work (reading an origin's file, appending the commits) runs on the profile's blocking pool.
//
// A page whose origin is opaque, or whose storage is off (indexeddb.enabled), gets a SecurityError.
//
// Workers: a dedicated worker's realm runs on a thread of its own and is a client of the same manager as the pages of its
// origin (one realm, one client: same ordering of transactions, same versionchange / blocked handshake). The manager takes a
// lock at each entry point, so a worker calls it directly: no message, no copy but the reply. What the manager has for a
// worker's client is signalled to its thread (Worker_Global.idb_wake) and delivered by its loop, one event per task, as
// for a page. Disk work stays on the blocking pool, which any thread may submit to.

import "core:sync"
import "core:time"
import "wb:base"
import "wb:host"
import "wb:idb"

Idb_Host :: struct {
	m:     idb.Manager,
	sm:    ^Storage_Manager,
	timer: base.Handle,
	arm_posted: b32,   // atomic: a task to arm the idle timer is on the UI loop
}

Idb_Page :: struct {
	client:         ^idb.Client,
	event:          []byte,    // the event being delivered (temporary)
	last:           [dynamic]byte,   // the reply of the last call: a reply that did not fit the caller's buffer is asked for again (IDB_OP_AGAIN)
	cleanup_needed: bool,      // the realm wants wj_idb_cleanup after the current microtask checkpoint
	deliver_posted: bool,
	page_id:        u64,       // a document's id (live_pages); 0 in a worker
	ui_loop:        ^host.Loop,   // the loop of a document's thread
	worker:         ^Worker_Global,   // set in a worker's realm: events reach it by flag and signal, from any thread
}

IDB_OP_OPEN       :: 1
IDB_OP_DELETE     :: 2
IDB_OP_LIST       :: 3
IDB_OP_CLOSE      :: 4
IDB_OP_VC_DONE    :: 5
IDB_OP_BEGIN      :: 6
IDB_OP_COMMIT     :: 7
IDB_OP_ABORT      :: 8
IDB_OP_EXEC       :: 9
IDB_OP_TASK       :: 10
IDB_OP_EVENT      :: 11
IDB_OP_CLEANUP    :: 12
IDB_OP_LIMITS     :: 13
IDB_OP_PRELUDE    :: 14
IDB_OP_AGAIN      :: 0x4000   // or-ed into any operation: do not run it, repeat the last reply

@(private)
idb_submit :: proc(user: rawptr, work, done: proc(data: rawptr), data: rawptr) {
	h := (^Idb_Host)(user)
	if h.sm.blocking != nil {
		host.run_blocking(h.sm.blocking, work, done, data)
	} else {
		work(data)
		done(data)
	}
}

@(private)
idb_now_ms :: proc() -> f64 { return f64(time.tick_now()._nsec) / 1e6 }

// The manager of the profile, made on first use (by whichever thread needs it first).
@(private)
idb_host_of :: proc(p: ^Page) -> ^Idb_Host {
	sm := p.web.embedder.storage
	if sm == nil || !sm.ready { return nil }
	sync.mutex_lock(&sm.idb_mu)
	defer sync.mutex_unlock(&sm.idb_mu)
	if sm.idb == nil {
		h := new(Idb_Host, base.process_allocator())
		h.sm = sm
		idb.manager_init(&h.m, p.settings.idb, sm.dir, idb_submit, h, idb_now_ms, base.process_allocator())
		sm.idb = h
	}
	return sm.idb
}

// Called when the storage manager goes: the pages are closed already (their clients are gone).
idb_host_destroy :: proc(sm: ^Storage_Manager) {
	h := sm.idb
	if h == nil { return }
	if h.timer != base.NIL_HANDLE { host.clear_timer(sm.loop, h.timer) }
	idb.manager_destroy(&h.m)
	free(h, base.process_allocator())
	sm.idb = nil
}

// Drops the origins nobody uses once they have been idle long enough; the timer lives while some origin is loaded. Any
// thread may ask: the timer belongs to the UI loop, a task there sets it.
@(private)
idb_arm :: proc(h: ^Idb_Host) {
	sm := h.sm
	if sm.loop == nil || sm.dir == "" { return }
	if sync.atomic_exchange(&h.arm_posted, true) { return }
	host.post(sm.loop, proc(data: rawptr) {
		sm := (^Storage_Manager)(data)
		if !sm.ready || sm.idb == nil { return }
		h := sm.idb
		sync.atomic_store(&h.arm_posted, false)
		idb_arm_timer(h)
	}, sm)
}

@(private)
idb_arm_timer :: proc(h: ^Idb_Host) {
	if h.timer != base.NIL_HANDLE { return }
	interval := clamp(h.m.settings.idle_unload_ms / 2, 1000, 30_000)
	h.timer = host.set_timer(h.sm.loop, interval, 0, proc(data: rawptr) {
		h := (^Idb_Host)(data)
		h.timer = base.NIL_HANDLE
		if idb.manager_tick(&h.m) > 0 { idb_arm_timer(h) }
	}, h)
}

// The page's client, made on first use. Error: Security when the page may not use IndexedDB.
@(private)
idb_page_of :: proc(p: ^Page) -> (^Idb_Page, Api_Error) {
	if ip := p.web.idb; ip != nil && ip.client != nil { return ip, .None }
	if !p.settings.idb.enabled || p.env.origin.opaque { return nil, Api_Error(WEB_ERR_SECURITY) }
	h := idb_host_of(p)
	if h == nil { return nil, Api_Error(WEB_ERR_SECURITY) }
	ip := p.web.idb
	if ip == nil { ip = new(Idb_Page); p.web.idb = ip }
	ip.page_id, ip.ui_loop, ip.worker = page_id(p), p.loop, p.worker
	key := p.worker.storage_key if p.worker != nil else storage_origin_key(p)
	idb.manager_set_settings(&h.m, p.settings.idb)
	ip.client = idb.client_create(&h.m, key, idb_wake, ip)
	idb_arm(h)
	return ip, .None
}
// Manager -> page: the client has an event. A task of the page delivers it.
@(private)
idb_wake :: proc(c: ^idb.Client) {
	// (called by the manager with its lock held, on any thread: nothing here may touch a page of another thread)
	ip := (^Idb_Page)(c.user)
	if w := ip.worker; w != nil {
		sync.atomic_store(&w.idb_wake, true)
		host.signal(&w.link.loop)
		return
	}
	host.post(ip.ui_loop, proc(data: rawptr) {
		p := page_by_id(u64(uintptr(data)))
		if p == nil || p.web.idb == nil { return }
		idb_post_delivery(p)
	}, rawptr(uintptr(ip.page_id)))
}

// A worker's loop found the flag idb_wake set: its events are delivered, one per task.
idb_worker_wake :: proc(p: ^Page) {
	if p.web != nil && p.web.idb != nil && p.web.idb.client != nil { idb_post_delivery(p) }
}

@(private)
idb_post_delivery :: proc(p: ^Page) {
	ip := p.web.idb
	if ip.deliver_posted { return }
	ip.deliver_posted = true
	post_page_task(p, idb_deliver, nil)
}

@(private)
idb_deliver :: proc(p: ^Page, _: rawptr) {
	if p == nil || p.web == nil { return }
	ip := p.web.idb
	if ip == nil { return }
	ip.deliver_posted = false
	if ip.client == nil { return }
	ev, ok := idb.client_pop(ip.client)
	if !ok { return }
	w := idb.Writer{data = make([dynamic]byte, context.temp_allocator)}
	idb.w_u8(&w, u8(ev.kind))
	idb.w_uv(&w, ev.req); idb.w_uv(&w, ev.conn); idb.w_uv(&w, ev.tx)
	idb.w_uv(&w, ev.v1); idb.w_uv(&w, ev.v2); idb.w_uv(&w, ev.a)
	idb.w_u8(&w, u8(ev.err))
	idb.w_bytes(&w, ev.data)
	idb.event_free(ip.client, &ev)
	ip.event = w.data[:]
	if r := js_realm(p); r != nil { js_call(p, r.inst, "wj_idb_event", nil) }
	ip.event = nil
	if p.web.idb != nil && p.web.idb.client != nil && idb.client_has_events(p.web.idb.client) { idb_post_delivery(p) }
}

// End of a microtask checkpoint with active transactions: they become inactive (and commit if they have nothing left to do).
@(private)
idb_cleanup :: proc(p: ^Page) {
	ip := p.web.idb
	ip.cleanup_needed = false
	if r := js_realm(p); r != nil { js_call(p, r.inst, "wj_idb_cleanup", nil) }
}

// web_destroy: the client goes (its connections close, what it had not committed is rolled back).
@(private)
idb_page_closed :: proc(p: ^Page) {
	ip := p.web.idb
	if ip == nil { return }
	if ip.client != nil { idb.client_destroy(ip.client) }
	delete(ip.last)
	free(ip)
	p.web.idb = nil
}

// Site data: everything IndexedDB keeps for an origin (serialized origin, as storage_origin_key makes it) is removed.
idb_clear_origin :: proc(sm: ^Storage_Manager, origin: string) {
	if sm == nil || !sm.ready { return }
	if sm.idb != nil {
		idb.manager_clear_origin(&sm.idb.m, origin)
	} else if sm.dir != "" {
		// not in use: only the file goes
		m: idb.Manager
		idb.manager_init(&m, idb.settings_default(), sm.dir, nil, nil, nil, base.process_allocator())
		idb.manager_clear_origin(&m, origin)
		idb.manager_destroy(&m)
	}
}

// IndexedDB's JavaScript, run by a realm when a script first needs it (runtime/web_idb.c). Not in the engine's image: a realm that
// never uses IndexedDB does not carry it.
IDB_PRELUDE_SOURCE :: #load("../../native/js/lazy/idb.js", string)

Idb_call :: proc(c: ^Call, op: i32, args: []u8) -> ([]u8, Api_Error) {
	p := c.page
	if op & ~i32(IDB_OP_AGAIN) == IDB_OP_PRELUDE { return transmute([]u8)string(IDB_PRELUDE_SOURCE), .None }
	ip, err := idb_page_of(p)
	if ip == nil { return nil, err }
	cl := ip.client
	if op & IDB_OP_AGAIN != 0 { return ip.last[:], .None }
	r := idb.Reader{data = args}
	out := idb.Writer{data = make([dynamic]byte, context.temp_allocator)}
	status := idb.Error.None
	idb.w_u8(&out, 0)
	switch op {
	case IDB_OP_OPEN:
		name := idb.r_str(&r)
		version := idb.r_uv(&r)
		has := idb.r_u8(&r) != 0
		if r.bad { return nil, Api_Error(WEB_ERR_TYPE) }
		idb.w_uv(&out, idb.open_database(cl, name, version, has))
	case IDB_OP_DELETE:
		name := idb.r_str(&r)
		if r.bad { return nil, Api_Error(WEB_ERR_TYPE) }
		idb.w_uv(&out, idb.delete_database(cl, name))
	case IDB_OP_LIST:
		idb.w_uv(&out, idb.list_databases(cl))
	case IDB_OP_CLOSE:
		status = idb.close_connection(cl, idb.r_uv(&r))
	case IDB_OP_VC_DONE:
		idb.versionchange_done(cl, idb.r_uv(&r))
	case IDB_OP_BEGIN:
		conn := idb.r_uv(&r)
		mode := idb.r_u8(&r)
		strict := idb.r_u8(&r) != 0
		n := int(idb.r_uv(&r))
		if r.bad || n > len(args) || mode > 1 { return nil, Api_Error(WEB_ERR_TYPE) }
		scope := make([]u32, n, context.temp_allocator)
		for i in 0 ..< n { scope[i] = u32(idb.r_uv(&r)) }
		if r.bad { return nil, Api_Error(WEB_ERR_TYPE) }
		id, e := idb.begin_transaction(cl, conn, scope, idb.Tx_Mode(mode), strict)
		status = e
		idb.w_uv(&out, id)
	case IDB_OP_COMMIT:
		status = idb.tx_commit(cl, idb.r_uv(&r))
	case IDB_OP_ABORT:
		id := idb.r_uv(&r)
		e := idb.Error(idb.r_u8(&r))
		status = idb.tx_abort(cl, id, e)
	case IDB_OP_EXEC:
		id := idb.r_uv(&r)
		if r.bad { return nil, Api_Error(WEB_ERR_TYPE) }
		payload := idb.Writer{data = make([dynamic]byte, context.temp_allocator)}
		status = idb.tx_exec(cl, id, args[r.pos:], &payload)
		if status == .None { append(&out.data, ..payload.data[:]) }
	case IDB_OP_TASK:
		idb.client_post_task(cl, idb.r_uv(&r))
	case IDB_OP_EVENT:
		append(&out.data, ..ip.event)
	case IDB_OP_CLEANUP:
		ip.cleanup_needed = true
	case IDB_OP_LIMITS:
		s := &p.settings.idb
		idb.w_uv(&out, u64(s.max_key_bytes)); idb.w_uv(&out, u64(s.max_value_bytes))
	case:
		return nil, Api_Error(WEB_ERR_TYPE)
	}
	out.data[0] = u8(status)
	resize(&ip.last, len(out.data))
	copy(ip.last[:], out.data[:])
	return out.data[:], .None
}

// Whether IndexedDB has something in flight for the page (see idb.client_busy).
idb_busy :: proc(p: ^Page) -> bool {
	if p == nil || p.web == nil { return false }
	ip := p.web.idb
	return ip != nil && ip.client != nil && (ip.deliver_posted || idb.client_busy(ip.client))
}