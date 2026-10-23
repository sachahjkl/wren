package blocker

import "core:fmt"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:host"
import "wb:http"
import "wb:net"

// Keeping the lists up to date: a round downloads every enabled list that is due (or all of them when asked), one at a
// time, as low-priority requests with conditional headers (If-None-Match / If-Modified-Since: an unchanged list answers
// 304 and costs a few hundred bytes). The bodies are handed to a compile job, which validates each one (a body that is
// not a list is refused and the previous copy stays) and rebuilds the index. Nothing is fetched when blocker.update.enabled
// is off, and nothing is ever reported anywhere.

Download :: struct {
	id:            string,      // owned
	body:          []byte,      // owned (process allocator): moves to the compile job
	etag:          string,      // owned
	last_modified: string,      // owned
}

Updater :: struct {
	timer:        base.Handle,
	queue:        [dynamic]string,   // list ids still to ask
	current_id:   string,            // owned
	current:      base.Handle,       // the network request
	downloads:    [dynamic]Download,
	running:      bool,
	job:          ^Job,
	held:         [dynamic]Download,
	rebuild_pending: bool,
	status:       string,            // owned: a line for the dashboard
	last_round:   i64,               // unix seconds
	last_compile_ms: f64,
	errors:       int,
	forced:       bool,
	pending_etag, pending_lm: string,   // owned: the headers of the answer being read
	pending_status: int,
}

@(private)
Ctx :: struct { b: ^Blocker, id: string }

// A round in `delay_s` seconds (the first one after start-up), then every hour to see what is due.
updater_schedule :: proc(b: ^Blocker, delay_s: int) {
	if b.upd.timer != base.NIL_HANDLE { host.clear_timer(b.loop, b.upd.timer) }
	b.upd.timer = host.set_timer(b.loop, f64(max(delay_s, 1)) * 1000, 0, updater_tick, b)
}

updater_stop :: proc(b: ^Blocker) {
	if b.upd.timer != base.NIL_HANDLE { host.clear_timer(b.loop, b.upd.timer); b.upd.timer = base.NIL_HANDLE }
	if b.upd.current != base.NIL_HANDLE { net.cancel(b.client, b.upd.current); b.upd.current = base.NIL_HANDLE }
	if b.upd.job != nil {
		j := b.upd.job
		if j.thread != nil { host.thread_join(j.thread); j.thread = nil }
		j.user = nil
		b.upd.job = nil
		// the thread has posted compile_done: it frees the job when the loop runs it
	}
	for d in b.upd.downloads { delete(d.id); delete(d.etag); delete(d.last_modified); delete(d.body, base.process_allocator()) }
	delete(b.upd.downloads)
	for d in b.upd.held { delete(d.id); delete(d.etag); delete(d.last_modified); delete(d.body, base.process_allocator()) }
	delete(b.upd.held)
	for q in b.upd.queue { delete(q) }
	delete(b.upd.queue)
	delete(b.upd.current_id); delete(b.upd.status)
}

@(private)
updater_tick :: proc(data: rawptr) {
	b := (^Blocker)(data)
	b.upd.timer = base.NIL_HANDLE
	if b.cfg.update && b.cfg.enabled && !b.upd.running { updater_round(b, false) }
	updater_schedule(b, 3600)
}

// Starts a round. `force`: every enabled list, due or not (the dashboard's "update now").
updater_round :: proc(b: ^Blocker, force: bool) {
	if b.upd.running || !b.persist { return }
	if !b.cfg.update && !force { return }
	now := unix_ms() / 1000
	interval := i64(b.cfg.update_hours) * 3600
	for &l in b.conf.lists {
		if !l.enabled || l.url == "" { continue }
		_, _, have := file_stat(list_path(b, l.id))
		due := force || !have || now - l.checked >= interval
		if !due { continue }
		append(&b.upd.queue, strings.clone(l.id))
		l.state = .Queued
	}
	if len(b.upd.queue) == 0 { return }
	b.upd.running = true
	b.upd.forced = force
	delete(b.upd.status)
	b.upd.status = strings.clone("updating the lists...")
	updater_next(b)
	touch(b)
}

@(private)
updater_next :: proc(b: ^Blocker) {
	for len(b.upd.queue) > 0 {
		id := b.upd.queue[0]
		ordered_remove(&b.upd.queue, 0)
		l := list_by_id(&b.conf, id)
		if l == nil || !l.enabled || l.url == "" { delete(id); continue }
		delete(b.upd.current_id)
		b.upd.current_id = id
		l.state = .Downloading
		_, _, have := file_stat(list_path(b, l.id))
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, "Accept: text/plain, */*;q=0.5")
		if have {
			if l.etag != "" { fmt.sbprintf(&sb, "\r\nIf-None-Match: %s", l.etag) }
			if l.last_modified != "" { fmt.sbprintf(&sb, "\r\nIf-Modified-Since: %s", l.last_modified) }
		}
		c := new(Ctx)
		c.b, c.id = b, strings.clone(id)
		b.upd.current = net.fetch(b.client, {
			url = l.url, method = "GET", headers = strings.to_string(sb), on_event = list_event, user = c,
			collect = true, max_body = b.cfg.max_list_bytes, priority = .Low,
		})
		touch(b)
		return
	}
	updater_finish(b)
}

@(private)
list_event :: proc(user: rawptr, req: base.Handle, ev: ^net.Event) {
	c := (^Ctx)(user)
	b := c.b
	#partial switch ev.kind {
	case .Headers:
		l := list_by_id(&b.conf, c.id)
		if l == nil { return }
		hdr := http.parse_header_block(ev.headers, context.temp_allocator)
		if ev.status == 304 {
			l.checked = unix_ms() / 1000
			delete(l.error); l.error = ""
		}
		delete(b.upd.pending_etag); delete(b.upd.pending_lm)
		v, _ := http.get_header(hdr, "etag")
		b.upd.pending_etag = clone_str(v)
		v, _ = http.get_header(hdr, "last-modified")
		b.upd.pending_lm = clone_str(v)
		b.upd.pending_status = ev.status
	case .Done:
		l := list_by_id(&b.conf, c.id)
		if l != nil {
			l.state = .Idle
			switch {
			case b.upd.pending_status == 200 && len(ev.data) > 0:
				a := base.process_allocator()
				body := make([]byte, len(ev.data), a)
				copy(body, ev.data)
				append(&b.upd.downloads, Download{id = strings.clone(c.id), body = body, etag = b.upd.pending_etag, last_modified = b.upd.pending_lm})
				b.upd.pending_etag, b.upd.pending_lm = "", ""
			case b.upd.pending_status == 304:
			case:
				delete(l.error)
				l.error = fmt.aprintf("the server answered %d", b.upd.pending_status)
				b.upd.errors += 1
			}
		}
		finish_request(c)
		updater_next(b)
	case .Failed:
		l := list_by_id(&b.conf, c.id)
		if l != nil {
			l.state = .Idle
			delete(l.error)
			if ev.error == net.ERROR_BODY_TOO_LARGE { l.error = strings.clone("the list is larger than blocker.update.max_list_bytes") } else { l.error = strings.clone(net.error_text(ev.error, ev.secure_flags)) }
			b.upd.errors += 1
		}
		finish_request(c)
		updater_next(b)
	}
}

@(private)
finish_request :: proc(c: ^Ctx) {
	c.b.upd.current = base.NIL_HANDLE
	delete(c.id)
	free(c)
}

@(private)
updater_finish :: proc(b: ^Blocker) {
	b.upd.running = false
	b.upd.last_round = unix_ms() / 1000
	delete(b.upd.status)
	b.upd.status = fmt.aprintf("%d list(s) downloaded%s", len(b.upd.downloads), b.upd.errors > 0 ? fmt.tprintf(", %d error(s)", b.upd.errors) : "")
	b.upd.errors = 0
	if len(b.upd.downloads) > 0 {
		dl := make([]Download, len(b.upd.downloads), context.temp_allocator)
		copy(dl, b.upd.downloads[:])
		clear(&b.upd.downloads)
		start_job(b, dl)
	} else {
		conf_save(b)
		if b.on_event != nil { ev := Event{kind = .Lists}; b.on_event(b.event_user, &ev) }
	}
	touch(b)
}

_ :: strconv
