package page

// BroadcastChannel (HTML §9.5) on the port router (ports.odin): each BroadcastChannel object of a realm (a document or
// a worker, any thread) is a port end with no peer and a channel key (the realm's origin and the channel's name). A
// message posted on one end is copied into the queue of every other end with the same key and delivered to its owner
// as port messages are (one wake per message, a task of the receiving realm); the engine fires it at the
// BroadcastChannel bound to that end (native/js/runtime/web_broadcast.c). Closing the object closes its end.

import "core:strings"
import "core:sync"
import "wb:url"

// The key of a channel: the realm's origin (an opaque origin has a channel of its own) and the name.
@(private)
broadcast_key :: proc(p: ^Page, name: string) -> string {
	o := p.env.origin
	ser := url.origin_serialize(o, context.temp_allocator)
	if ser == "null" { return "" }
	return strings.concatenate({ser, "\x00", name})
}

// new BroadcastChannel(name): an end of the router owned by the calling realm (0: an opaque origin, which can talk to
// nobody: the object exists and sends nowhere).
Broadcast_open :: proc(c: ^Call, name: string) -> u64 {
	p := c.page
	key := broadcast_key(p, name)
	if key == "" { return 0 }
	if p.worker == nil { frames_of(p) }   // (its cleanup closes the ends the document owns)
	sync.mutex_lock(&router.mu)
	defer sync.mutex_unlock(&router.mu)
	ports_note_loop(p)
	router.next += 1
	e := new(Port_End)
	e.id = router.next | BROADCAST_TAG
	e.channel = key
	if p.worker != nil { e.link = p.worker.link } else { e.page = page_id(p) }
	router.ends[e.id] = e
	return e.id
}

BROADCAST_TAG :: u64(1) << 62

// channel.postMessage(message): to every other open BroadcastChannel of the same origin and name, in every realm.
Broadcast_post :: proc(c: ^Call, end: u64, data: []u8) -> Api_Error {
	max_bytes := c.page.settings.frames.max_message_bytes
	if max_bytes > 0 && len(data) > max_bytes { return fail(c, .Data_Clone, "DataCloneError: the message is larger than frames.max_message_bytes") }
	sync.mutex_lock(&router.mu)
	defer sync.mutex_unlock(&router.mu)
	e, ok := router.ends[end]
	if !ok || e.channel == "" || !port_owned_by(e, c.page) { return .None }
	for id, other in router.ends {
		if id == end || other.channel != e.channel || (other.page == 0 && other.link == nil) { continue }
		m := Port_Msg{data = make([]byte, len(data))}
		copy(m.data, data)
		append(&other.queue, m)
		port_wake_locked(other)
	}
	return .None
}
