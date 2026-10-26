package page

// The Storage Access API (api/js_storage_access.widl). A frame of another site than its tab's lives in a partition of
// the tab's site (storage.partitioned: its cookies, storage, service workers, channels: storage_origin_key); it may ask
// for its own with document.requestStorageAccess() after a user gesture in it. The decision (storage.access_requests:
// the person through a prompt of the shell, or the preference) is kept for the session per (frame site, tab site): a
// grant makes the asking document "active" (fetch.Storage_Access: its requests to its own site carry its first-party
// cookies, its storage key is its origin's) and every later document of that pair "inactive" until it asks too (no
// gesture needed then); a refusal by the person is not asked again in the session. Its requests say which
// (Sec-Fetch-Storage-Access, fetch/loader.odin). Clearing a site's data forgets its grants.

import "core:fmt"
import "core:strings"
import "wb:fetch"
import "wb:url"

// A request waiting for the person (the shell answers with storage_access_done).
Storage_Access_Ask :: struct {
	page:    u64,
	promise: u64,
	site:    string,   // owned: the frame's site
	top:     string,   // owned: the tab's site
}

// The shell's prompt (browser/storage_access_shell.odin); nil: the requests that would ask are refused.
Storage_Access_Embedder :: struct {
	ask:  proc(user: rawptr, p: ^Page, req: ^Storage_Access_Ask),
	user: rawptr,
}
storage_access_embedder: Storage_Access_Embedder

@(private) sa_decisions: map[string]bool   // owned keys "frame site TAB tab site": granted (true) or refused (false)

@(private)
sa_key :: proc(site, top: string) -> string { return strings.concatenate({site, "\t", top}, context.temp_allocator) }

// A frame of another site than its tab's (where storage access means anything).
@(private)
sa_third_party :: proc(p: ^Page) -> bool {
	if p.worker != nil || p.frames == nil || p.frames.nav == nil || p.frames.nav.parent == nil { return false }
	return !url.same_site(p.env.site, p.env.top_level_site)
}

// The state a new document of a frame starts in: inactive when its pair was granted before.
storage_access_initial :: proc(c: ^Page) -> fetch.Storage_Access {
	if c.env.origin.opaque || url.same_site(c.env.site, c.env.top_level_site) { return .None }
	if granted, known := sa_decisions[sa_key(site_text(c.env.site), site_text(c.env.top_level_site))]; known && granted { return .Inactive }
	return .None
}

// The document uses its own storage and cookies from now on; the other documents of the pair may (inactive).
@(private)
sa_activate :: proc(p: ^Page) {
	p.env.storage_access = .Active
	for _, q in live_pages {
		if q == p || q.closed || q.env.storage_access != .None { continue }
		if url.same_site(q.env.site, p.env.site) && url.same_site(q.env.top_level_site, p.env.top_level_site) { q.env.storage_access = .Inactive }
	}
}

@(private)
sa_decide :: proc(site, top: string, granted: bool) {
	key := sa_key(site, top)
	if _, known := sa_decisions[key]; known { sa_decisions[key] = granted; return }
	sa_decisions[strings.clone(key)] = granted
}

Document_hasStorageAccess :: proc(c: ^Call) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	has := !p.env.origin.opaque && (!sa_third_party(p) || p.env.storage_access == .Active)
	promise_resolve(p, pr, has ? 1 : 0)
	return pr
}

Document_requestStorageAccess :: proc(c: ^Call) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	refuse :: proc(p: ^Page, pr: u64, why: string) { promise_reject(p, pr, i64(Api_Error.Not_Allowed), fmt.tprintf("NotAllowedError: %s", why)) }
	switch {
	case p.env.origin.opaque: refuse(p, pr, "a document of an opaque origin has no storage of its own"); return pr
	case !sa_third_party(p), p.env.storage_access == .Active: promise_resolve(p, pr, 0); return pr
	}
	if sb := page_sandbox(p); sb.active && .Storage_Access_By_User_Activation not_in sb.allow {
		refuse(p, pr, "the frame's sandbox does not allow storage access (allow-storage-access-by-user-activation)")
		return pr
	}
	if !feature_enabled(p, .Storage_Access) { refuse(p, pr, "the storage-access permission policy of the page refuses it"); return pr }
	site, top := site_text(p.env.site), site_text(p.env.top_level_site)
	if granted, known := sa_decisions[sa_key(site, top)]; known {
		if granted { sa_activate(p); promise_resolve(p, pr, 0) } else { refuse(p, pr, "storage access was refused for this site here") }
		return pr
	}
	age, had := activation_age_ns(p)
	if !had || age > i64(p.settings.frames.access_activation_ms) * 1_000_000 {
		refuse(p, pr, "requestStorageAccess() needs a user gesture in the frame (storage.access_activation_ms)")
		return pr
	}
	switch p.settings.frames.access_requests {
	case .Allow:
		sa_decide(site, top, true)
		sa_activate(p)
		promise_resolve(p, pr, 0)
	case .Deny:
		refuse(p, pr, "storage access is refused by the browser's settings (storage.access_requests)")
	case .Ask:
		if storage_access_embedder.ask == nil { refuse(p, pr, "nobody can be asked"); return pr }
		req := new(Storage_Access_Ask)
		req^ = {page = page_id(p), promise = pr, site = strings.clone(site), top = strings.clone(top)}
		storage_access_embedder.ask(storage_access_embedder.user, p, req)
	}
	return pr
}

// The person answered (or the prompt went away: refused).
storage_access_done :: proc(req: ^Storage_Access_Ask, granted: bool) {
	defer { delete(req.site); delete(req.top); free(req) }
	sa_decide(req.site, req.top, granted)
	p := page_by_id(req.page)
	if p == nil || p.closed { return }
	if granted {
		sa_activate(p)
		promise_resolve(p, req.promise, 0)
	} else {
		promise_reject(p, req.promise, i64(Api_Error.Not_Allowed), "NotAllowedError: storage access was refused")
	}
}

// Clearing a site's data: the decisions about it (as the frame's site or as the tab's) go.
storage_access_forget :: proc(site: string) {
	gone := make([dynamic]string, context.temp_allocator)
	for k in sa_decisions {
		a, _, b := strings.partition(k, "\t")
		if a == site || b == site { append(&gone, k) }
	}
	for k in gone { key, _ := delete_key(&sa_decisions, k); delete(key) }
}

// The session ends (storage_manager_destroy).
storage_access_reset :: proc() {
	for k in sa_decisions { delete(k) }
	delete(sa_decisions)
	sa_decisions = nil
}
