package page

// The Web Locks API (navigator.locks, import module "locks"). A lock is held per origin and shared across every page
// and worker of that origin in this process (the registry lives on the process allocator, behind a mutex). The engine
// (native/js/runtime/web_locks.c) holds the request's callback and the promise it returns; this host side owns the
// grant order, the shared/exclusive rule, ifAvailable, steal and the waiting queue, and tells the engine when a lock
// is granted so it can run the callback. The lock is released when the engine says the callback's promise settled, or
// when the owning page/worker goes away.
//
// Native-first: the whole queueing and granting policy is here (no JavaScript). Only running the author callback and
// chaining its returned promise is in the engine, because the callback is a JavaScript value.

import "core:strings"
import "core:sync"
import "wb:base"
import "wb:url"

Lock_Mode :: enum u8 { Shared, Exclusive }

@(private)
Held_Lock :: struct {
	id:        u64,         // global lock id (grant), unique per process
	name:      string,      // owned (registry allocator)
	mode:      Lock_Mode,
	client:    u64,         // the owning realm: page id (or a worker's link id, tagged)
	client_tag: string,     // owned: the clientId reported by query()
}

@(private)
Pending_Lock :: struct {
	id:         u64,        // the request id (becomes the grant id on grant)
	name:       string,     // owned
	mode:       Lock_Mode,
	client:     u64,
	client_tag: string,     // owned
	callback:   u32,        // engine function-table index of wj_cb_lock_granted
	user:       u32,        // the engine record slot
	instance:   u32,        // the owning instance, for call_guest
	page:       u64,        // page id (for delivering the grant on the right realm)
	steal:      bool,
}

@(private)
Lock_Registry :: struct {
	mu:      sync.Mutex,
	held:    [dynamic]Held_Lock,     // per origin keyed by name within; the origin is part of `name` ("origin\x00name")
	pending: [dynamic]Pending_Lock,
	next_id: u64,
}

@(private)
lock_registry: Lock_Registry

// Per-realm bookkeeping so a page/worker releases everything it holds (and drops its pending requests) on teardown.
Lock_Client :: struct {
	held_ids:    [dynamic]u64,
	pending_ids: [dynamic]u64,
}

@(private)
lock_client_of :: proc(p: ^Page) -> ^Lock_Client {
	if p.web == nil { return nil }
	if p.web.locks == nil {
		p.web.locks = new(Lock_Client)
		p.web.locks.held_ids = make([dynamic]u64)
		p.web.locks.pending_ids = make([dynamic]u64)
	}
	return p.web.locks
}

// The storage key + name, the scope a lock shares (same origin, partitioned as storage is).
@(private)
lock_key :: proc(p: ^Page, name: string) -> string {
	key := realm_storage_key(p)
	if key == "" {
		if p.env.origin.opaque { return "" }
		key = url.origin_serialize(p.env.origin, context.temp_allocator)
	}
	return strings.concatenate({key, "\x00", name}, base.process_allocator())
}

// A client id string for query(): the page's origin plus its id (stable within the process).
@(private)
lock_client_tag :: proc(p: ^Page) -> string {
	buf: [32]u8
	return strings.concatenate({"client-", url.uint_to_string(page_id(p), buf[:])}, base.process_allocator())
}

// Whether a request for (key, mode) can be granted now: no held lock on the same key conflicts. Shared locks coexist;
// an exclusive lock conflicts with any held lock on the key; a shared request conflicts only with a held exclusive.
@(private)
lock_grantable :: proc(key: string, mode: Lock_Mode) -> bool {
	for h in lock_registry.held {
		if h.name != key { continue }
		if mode == .Exclusive || h.mode == .Exclusive { return false }
	}
	return true
}

// Grant the front of the waiting queue for `key` when possible, oldest first; honours the shared/exclusive rule (a
// run of shared requests at the front may all be granted together). Returns the ids granted (to notify the engine).
@(private)
lock_pump :: proc(key: string, granted: ^[dynamic]Pending_Lock) {
	for {
		idx := -1
		for pl, i in lock_registry.pending {
			if pl.name != key { continue }
			idx = i
			break
		}
		if idx < 0 { return }
		pl := lock_registry.pending[idx]
		if !lock_grantable(key, pl.mode) { return }
		ordered_remove(&lock_registry.pending, idx)
		append(&lock_registry.held, Held_Lock{id = pl.id, name = strings.clone(pl.name, base.process_allocator()), mode = pl.mode, client = pl.client, client_tag = strings.clone(pl.client_tag, base.process_allocator())})
		append(granted, pl)
		if pl.mode == .Exclusive { return }   // an exclusive grant blocks the rest until it is released
	}
}

////////////////////////////////
// Imports (module "locks")

// navigator.locks.request(name, {mode, ifAvailable, steal, signal}, callback). The engine has already created the
// request's overall promise; here we enqueue, grant, or report it unavailable. The result is packed:
//   bit 0 = available (false only for ifAvailable when the lock is busy, or an opaque origin);
//   bit 1 = granted now (the engine runs the callback with the Lock immediately);
//   the id is the rest (result >> 2). When granted-now is clear but available is set, the request waits in the queue
//   and the engine will be told later (wj_cb_lock_granted). When available is clear the engine runs the callback with
//   null (ifAvailable) and no lock is held.
LockManager_request :: proc(c: ^Call, name: string, mode: Api_LockMode, if_available: bool, steal: bool, callback: u32, user: i32) -> i64 {
	p := c.page
	key := lock_key(p, name)
	if key == "" { return 0 }   // opaque origin: not available
	m := mode == .Shared ? Lock_Mode.Shared : Lock_Mode.Exclusive
	tag := lock_client_tag(p)
	defer delete(tag, base.process_allocator())

	sync.mutex_lock(&lock_registry.mu)
	defer sync.mutex_unlock(&lock_registry.mu)
	lock_registry.next_id += 1
	id := lock_registry.next_id
	pack :: proc(id: u64, granted, available: bool) -> i64 { return i64(id << 2) | (granted ? 2 : 0) | (available ? 1 : 0) }

	if steal {
		w := 0
		for h in lock_registry.held {
			if h.name == key { delete(h.name, base.process_allocator()); delete(h.client_tag, base.process_allocator()); continue }
			lock_registry.held[w] = h; w += 1
		}
		resize(&lock_registry.held, w)
		append(&lock_registry.held, Held_Lock{id = id, name = strings.clone(key, base.process_allocator()), mode = m, client = page_id(p), client_tag = strings.clone(tag, base.process_allocator())})
		lock_note_held(p, id)
		delete(key, base.process_allocator())
		return pack(id, true, true)
	}
	if lock_grantable(key, m) {
		append(&lock_registry.held, Held_Lock{id = id, name = strings.clone(key, base.process_allocator()), mode = m, client = page_id(p), client_tag = strings.clone(tag, base.process_allocator())})
		lock_note_held(p, id)
		delete(key, base.process_allocator())
		return pack(id, true, true)
	}
	if if_available {
		delete(key, base.process_allocator())
		return pack(0, false, false)   // busy: the engine runs the callback with null
	}
	append(&lock_registry.pending, Pending_Lock{id = id, name = strings.clone(key, base.process_allocator()), mode = m,
		client = page_id(p), client_tag = strings.clone(tag, base.process_allocator()), callback = callback, user = u32(user), instance = c.owner, page = page_id(p), steal = steal})
	lock_note_pending(p, id)
	delete(key, base.process_allocator())
	return pack(id, false, true)
}

@(private)
lock_note_held :: proc(p: ^Page, id: u64) {
	cl := lock_client_of(p)
	if cl != nil { append(&cl.held_ids, id) }
}
@(private)
lock_note_pending :: proc(p: ^Page, id: u64) {
	cl := lock_client_of(p)
	if cl != nil { append(&cl.pending_ids, id) }
}

// The engine says the callback's promise settled (or the callback was null / threw): release the held lock and grant
// whatever waits. Also used to drop a pending request that was aborted by its signal.
LockManager_release :: proc(c: ^Call, id: u64) {
	p := c.page
	to_notify := make([dynamic]Pending_Lock, context.temp_allocator)
	key_clone: string
	{
		sync.mutex_lock(&lock_registry.mu)
		defer sync.mutex_unlock(&lock_registry.mu)
		// held?
		for h, i in lock_registry.held {
			if h.id == id {
				key_clone = strings.clone(h.name, context.temp_allocator)
				delete(h.name, base.process_allocator()); delete(h.client_tag, base.process_allocator())
				ordered_remove(&lock_registry.held, i)
				break
			}
		}
		// pending (aborted before grant)?
		for pl, i in lock_registry.pending {
			if pl.id == id {
				delete(pl.name, base.process_allocator()); delete(pl.client_tag, base.process_allocator())
				ordered_remove(&lock_registry.pending, i)
				break
			}
		}
		if key_clone != "" { lock_pump(key_clone, &to_notify) }
	}
	lock_client_forget(p, id)
	// deliver grants to the engine of each granted request's realm
	for pl in to_notify { lock_deliver_grant(pl) }
}

@(private)
lock_client_forget :: proc(p: ^Page, id: u64) {
	cl := p.web != nil ? p.web.locks : nil
	if cl == nil { return }
	for h, i in cl.held_ids { if h == id { ordered_remove(&cl.held_ids, i); break } }
	for pid, i in cl.pending_ids { if pid == id { ordered_remove(&cl.pending_ids, i); break } }
}

// Notify the engine that a waiting request was granted: run its callback on the owning realm. Delivered as a page task
// so it runs as its own event-loop turn (the callback and its promise run cleanly after the release that unblocked it).
@(private)
lock_deliver_grant :: proc(pl: Pending_Lock) {
	pg := page_by_id(pl.page)
	if pg == nil || pg.closed { return }
	cl := lock_client_of(pg)
	if cl != nil {
		for i, idx in cl.pending_ids { if i == pl.id { ordered_remove(&cl.pending_ids, idx); break } }
		append(&cl.held_ids, pl.id)
	}
	gr := new_clone(Grant_Delivery{callback = pl.callback, user = pl.user, instance = pl.instance, id = pl.id})
	post_page_task(pg, proc(p: ^Page, data: rawptr) {
		g := (^Grant_Delivery)(data)
		defer free(g)
		if p == nil || p.closed { return }
		inst := instance_by_index(p, g.instance)
		if inst == nil { return }
		loaf_set_invoker(p, .User_Callback, "navigator.locks.request")
		argv := [2]u32{g.user, u32(g.id)}   // (user: i32, lock id low 32 bits is enough: ids are small)
		call_guest(p, inst, g.callback, argv[:])
	}, gr)
}

@(private)
Grant_Delivery :: struct { callback, user, instance: u32, id: u64 }

// navigator.locks.query(): the engine reads the snapshot out of these. We expose counts and per-entry fields keyed by
// the page's origin (query only sees locks of the caller's storage key).
LockManager_queryCount :: proc(c: ^Call, held: bool) -> i32 {
	p := c.page
	prefix := lock_query_prefix(p)
	if prefix == "" { return 0 }
	defer delete(prefix, context.temp_allocator)
	sync.mutex_lock(&lock_registry.mu)
	defer sync.mutex_unlock(&lock_registry.mu)
	n := 0
	if held {
		for h in lock_registry.held { if strings.has_prefix(h.name, prefix) { n += 1 } }
	} else {
		for pl in lock_registry.pending { if strings.has_prefix(pl.name, prefix) { n += 1 } }
	}
	return i32(n)
}

@(private)
lock_query_prefix :: proc(p: ^Page) -> string {
	key := realm_storage_key(p)
	if key == "" {
		if p.env.origin.opaque { return "" }
		key = url.origin_serialize(p.env.origin, context.temp_allocator)
	}
	return strings.concatenate({key, "\x00"}, context.temp_allocator)
}

// The i-th held/pending entry's name, mode and clientId (query()). Not_Found past the end.
LockManager_queryName :: proc(c: ^Call, held: bool, index: i32) -> (string, Api_Error) {
	return lock_query_field(c.page, held, index, .Name)
}
LockManager_queryMode :: proc(c: ^Call, held: bool, index: i32) -> (string, Api_Error) {
	return lock_query_field(c.page, held, index, .Mode)
}
LockManager_queryClient :: proc(c: ^Call, held: bool, index: i32) -> (string, Api_Error) {
	return lock_query_field(c.page, held, index, .Client)
}

@(private)
Lock_Field :: enum u8 { Name, Mode, Client }

@(private)
lock_query_field :: proc(p: ^Page, held: bool, index: i32, field: Lock_Field) -> (string, Api_Error) {
	prefix := lock_query_prefix(p)
	if prefix == "" { return "", .Not_Found }
	defer delete(prefix, context.temp_allocator)
	sync.mutex_lock(&lock_registry.mu)
	defer sync.mutex_unlock(&lock_registry.mu)
	k := 0
	collect :: proc(name: string, mode: Lock_Mode, tag: string, prefix: string, field: Lock_Field) -> string {
		switch field {
		case .Name: return strings.clone(name[len(prefix):], context.temp_allocator)
		case .Mode: return mode == .Shared ? "shared" : "exclusive"
		case .Client: return strings.clone(tag, context.temp_allocator)
		}
		return ""
	}
	if held {
		for h in lock_registry.held {
			if !strings.has_prefix(h.name, prefix) { continue }
			if k == int(index) { return collect(h.name, h.mode, h.client_tag, prefix, field), .None }
			k += 1
		}
	} else {
		for pl in lock_registry.pending {
			if !strings.has_prefix(pl.name, prefix) { continue }
			if k == int(index) { return collect(pl.name, pl.mode, pl.client_tag, prefix, field), .None }
			k += 1
		}
	}
	return "", .Not_Found
}

// A page/worker is gone: release everything it holds and drop its pending requests, then pump the waiters.
@(private)
locks_page_closed :: proc(p: ^Page) {
	cl := p.web != nil ? p.web.locks : nil
	if cl == nil { return }
	keys := make([dynamic]string, context.temp_allocator)
	grants := make([dynamic]Pending_Lock, context.temp_allocator)
	{
		sync.mutex_lock(&lock_registry.mu)
		defer sync.mutex_unlock(&lock_registry.mu)
		for id in cl.held_ids {
			for h, i in lock_registry.held {
				if h.id == id {
					append(&keys, strings.clone(h.name, context.temp_allocator))
					delete(h.name, base.process_allocator()); delete(h.client_tag, base.process_allocator())
					ordered_remove(&lock_registry.held, i)
					break
				}
			}
		}
		for id in cl.pending_ids {
			for pl, i in lock_registry.pending {
				if pl.id == id {
					delete(pl.name, base.process_allocator()); delete(pl.client_tag, base.process_allocator())
					ordered_remove(&lock_registry.pending, i)
					break
				}
			}
		}
		for key in keys { lock_pump(key, &grants) }
	}
	delete(cl.held_ids); delete(cl.pending_ids)
	free(cl)
	for pl in grants { lock_deliver_grant(pl) }
}
