package page

// Whose work the window thread does (host: Loop.work; `wrentool threadtime` reads the spans). A task or a timer inherits the
// owner of who makes it, so a script's origin follows its timers, its requests' responses and its listeners. The engine
// does not say which script a function came from: an origin is known at the entry of a script and passed on from there,
// so a function of one script called from another's task counts for the latter.

import "wb:base"
import "wb:host"
import "wb:url"

// The owner of what is made now for page `p`: the script at work if it is this page's, else the page's own origin.
page_work :: proc(p: ^Page, class: base.Work_Class) -> base.Work {
	w := host.work_now(p.loop, class)
	if p.web == nil || p.web.id == 0 { return w }   // (a worker's realm: its own loop, no page of the window)
	id := u32(p.web.id)
	if w.page == id { return w }
	w.page, w.origin, w.third_party = id, 0, false
	if host.on_loop_thread(p.loop) {
		if p.web.own_origin == 0 { p.web.own_origin = host.origin_number(p.loop, url.origin_serialize(p.env.origin, context.temp_allocator)) }
		w.origin = p.web.own_origin
		w.third_party = !url.same_site(p.env.site, p.env.top_level_site)
	}
	return w
}

// The owner of the script at `script_url`, in the class of what runs it. An address with no origin of its own (a blob, data:) is its maker's.
script_work :: proc(p: ^Page, script_url: string) -> base.Work {
	w := page_work(p, p.loop.work.class)
	u, ok := url.parse_absolute(script_url, context.temp_allocator)
	if !ok { return w }
	o := url.origin_of(u, context.temp_allocator)
	if o.opaque { return w }
	w.origin = host.origin_number(p.loop, url.origin_serialize(o, context.temp_allocator))
	w.third_party = !url.same_site(url.site_of(o, context.temp_allocator), p.env.top_level_site)
	return w
}

// A callback made by `made`, called now as work of `class`.
callback_work :: proc(made: base.Work, class: base.Work_Class) -> base.Work {
	w := made
	w.class = class
	return w
}
