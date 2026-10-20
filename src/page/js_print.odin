package page

// window.print() (api/js_print.widl). HTML's printing steps: a user agent that cannot print returns without doing
// anything (no beforeprint / afterprint, no exception); this one also tells the embedder, from a task of its own (the
// call comes from inside a guest call), so the shell can show a short notice. Calls are coalesced: a page calling
// print() in a loop posts one notice per turn of the event loop.

import "wb:host"

Window_print :: proc(c: ^Call) {
	p := c.page
	if p == nil || p.closed || p.web == nil || p.web.id == 0 || p.web.embedder.print == nil || p.web.print_posted { return }
	p.web.print_posted = true
	host.post(p.loop, print_notice, rawptr(uintptr(p.web.id)))
}

@(private = "file")
print_notice :: proc(data: rawptr) {
	p := page_by_id(u64(uintptr(data)))   // the page may be gone by then
	if p == nil || p.closed || p.web == nil { return }
	p.web.print_posted = false
	if p.web.embedder.print != nil { p.web.embedder.print(p.web.embedder.user, p) }
}
