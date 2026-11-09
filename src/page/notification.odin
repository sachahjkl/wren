package page

// System notifications (WHATWG Notifications API; api/notification.widl). The page asks, the embedder decides and shows:
//
//   * the permission is the origin's, kept by the embedder (Notification_Embedder.permission); requestPermission asks the
//     user only after a click or a key press of theirs on the page (notifications.activation_ms), as file permissions;
//   * a notification shown is the embedder's (the system's, through gui_toolkit's platform.notify): an id it gives;
//   * what happens to it comes back through notification_event (a click, its end), which settles the promise of
//     Notification_next the page's object keeps waiting on (native/js/odin/web_notification.odin fires the event and
//     waits again until the end). An event that comes before the page waits is kept for its next wait.

import "core:strings"

Notification_Embedder :: struct {
	user:       rawptr,
	permission: proc(user: rawptr, origin: string) -> i32,               // 0 default, 1 granted, 2 denied
	ask:        proc(user: rawptr, p: ^Page, req: ^Notification_Ask),   // asks the user; notification_ask_done(req, granted) later
	show:       proc(user: rawptr, p: ^Page, title, body, tag: string, silent: bool) -> u64,   // 0: not shown
	close:      proc(user: rawptr, id: u64),
}

Notification_Ask :: struct {
	page:    u64,
	promise: u64,
	origin:  string,   // owned
}

// A shown notification's waits: the promise of the page's Notification_next, or what came before it.
Notification_Wait :: struct {
	page:    u64,
	promise: u64,          // 0: the page does not wait now
	queued:  [dynamic]i64, // events that came while it did not
}

NOTIFICATION_CLICK :: 0
NOTIFICATION_GONE  :: 1
NOTIFICATION_SHOWN :: 2   // the first answer of a notification shown (the page's object fires "show")

NOTIFICATION_STATES := [3]string{"default", "granted", "denied"}

// The origin's state: 0 default, 1 granted, 2 denied (no embedder: denied).
@(private = "file")
notification_state :: proc(p: ^Page) -> i32 {
	e := &the_pages.notification_embedder
	if e.permission == nil { return 2 }
	return clamp(e.permission(e.user, page_origin(p)), 0, 2)
}

Notification_permission :: proc(c: ^Call) -> string { return NOTIFICATION_STATES[notification_state(c.page)] }

Notification_ask :: proc(c: ^Call) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	e := &the_pages.notification_embedder
	state := notification_state(p)
	age, had := activation_age_ns(p)
	if state != 0 || e.ask == nil || p.worker != nil || !had || age > i64(p.settings.sw.fs_activation_ms) * 1_000_000 {
		promise_resolve(p, pr, i64(state))   // (no prompt without a user gesture: the state stays what it is)
		return pr
	}
	req := new(Notification_Ask)
	req^ = {page = page_id(p), promise = pr, origin = strings.clone(page_origin(p))}
	e.ask(e.user, p, req)
	return pr
}

// The user's answer to req (the embedder keeps it for the origin before calling this).
notification_ask_done :: proc(req: ^Notification_Ask, granted: bool) {
	defer { delete(req.origin); free(req) }
	if p := page_by_id(req.page); p != nil && !p.closed { promise_resolve(p, req.promise, granted ? 1 : 2) }
}

Notification_show :: proc(c: ^Call, title: string, body: string, tag: string, silent: bool) -> u64 {
	e := &the_pages.notification_embedder
	if e.show == nil || notification_state(c.page) != 1 { return 0 }
	id := e.show(e.user, c.page, title, body, tag, silent)
	if id != 0 {
		if the_pages.notification_waits == nil { the_pages.notification_waits = make(map[u64]^Notification_Wait) }
		w := new(Notification_Wait)
		w.page = page_id(c.page)
		append(&w.queued, NOTIFICATION_SHOWN)
		the_pages.notification_waits[id] = w
	}
	return id
}

Notification_next :: proc(c: ^Call, id: u64) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	w, ok := the_pages.notification_waits[id]
	if !ok { promise_resolve(p, pr, NOTIFICATION_GONE); return pr }
	if len(w.queued) > 0 {
		ev := w.queued[0]
		ordered_remove(&w.queued, 0)
		promise_resolve(p, pr, ev)
		if ev == NOTIFICATION_GONE { notification_forget(id) }
		return pr
	}
	w.promise = pr
	return pr
}

Notification_close :: proc(c: ^Call, id: u64) {
	e := &the_pages.notification_embedder
	if _, ok := the_pages.notification_waits[id]; ok && e.close != nil { e.close(e.user, id) }
}

// What happened to notification `id` (NOTIFICATION_CLICK, NOTIFICATION_GONE): from the embedder, on the loop's thread.
notification_event :: proc(id: u64, ev: i64) {
	w, ok := the_pages.notification_waits[id]
	if !ok { return }
	p := page_by_id(w.page)
	if p == nil || p.closed { notification_forget(id); return }
	if w.promise == 0 {
		append(&w.queued, ev)
		return
	}
	pr := w.promise
	w.promise = 0
	promise_resolve(p, pr, ev)
	if ev == NOTIFICATION_GONE { notification_forget(id) }
}

// The page of a shown notification (0: none, or gone): the embedder brings its tab up at a click.
notification_page :: proc(id: u64) -> u64 {
	w, ok := the_pages.notification_waits[id]
	return ok ? w.page : 0
}

@(private = "file")
notification_forget :: proc(id: u64) {
	w, ok := the_pages.notification_waits[id]
	if !ok { return }
	delete(w.queued)
	free(w)
	delete_key(&the_pages.notification_waits, id)
}

notifications_shutdown :: proc() {
	for _, w in the_pages.notification_waits { delete(w.queued); free(w) }
	delete(the_pages.notification_waits)
	the_pages.notification_waits = nil
}
