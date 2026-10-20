package fetch

import "wb:base"
import "wb:net"

// Hands a task over to another consumer from its Response event on: a navigation whose answer turns out to be a
// download (Content-Disposition: attachment, a type the browser does not display) keeps its connection and continues
// as the download, instead of being cancelled and asked again (a POST, a one-time link, a slow server). From the call:
//   * events go to `on_event(user, ...)`;
//   * the task belongs to `scope` (closing the old one no longer cancels it; nil: to nobody, cancel it yourself);
//   * the body streams in Data events (collect = false) or is collected, and may be up to `max_body` bytes (0: the
//     network.max_response_bytes setting; the cap also applies to what the transport still has to read);
//   * the initiator is forgotten: the response is in, nothing left of the request needs it (it may go with the
//     document that started the navigation).
// Call it from the task's Response event only (nothing has been collected yet). False when the task is gone.
task_hand_over :: proc(l: ^Loader, h: base.Handle, scope: ^base.Scope, on_event: Event_Proc, user: rawptr, collect: bool, max_body: int) -> bool {
	t := base.pool_get(&l.tasks, h)
	if t == nil { return false }
	if t.scope != nil {
		// the old scope's cleanup goes, with its data (what start allocated for it)
		for c, i in t.scope.cleanups {
			if c.id == t.cleanup { free(c.data); ordered_remove(&t.scope.cleanups, i); break }
		}
	}
	t.scope, t.cleanup = scope, 0
	if scope != nil { t.cleanup = base.on_close(scope, task_scope_closed, new_clone(Kick{l, h})) }
	t.on_event, t.user = on_event, user
	t.collect = collect
	clear(&t.collected)
	t.initiator = nil
	t.max_body = max_body
	if t.net_req != base.NIL_HANDLE { net.set_max_body(l.net, t.net_req, max_body) }
	return true
}
