package page

// Messages between pages, workers and sockets: the stand-in for structured clone when there are no JavaScript objects.
// A message is a string plus a list of transferred buffers. Capturing it detaches the buffers from the source page
// (their objects stay valid with length 0, as a transferred ArrayBuffer does) and moves their bytes into a payload that
// belongs to no page; delivering it makes new buffer objects in the target page. The payload lives on the process heap,
// so it may be created on one thread and delivered or destroyed on another.

import "base:runtime"
import "wb:dom"
import "wb:base"

// What a guest hands over / receives: text and buffer handles of its own page.
Message :: struct {
	text:    string,
	buffers: []u64,
}

// A message in transit (owned, process heap).
Message_Payload :: struct {
	text:    string,
	buffers: [][]byte,
	bytes:   int,      // total size of the buffers
}

// Detaches `buffers` from `p` and copies `text`. Fails without detaching anything when a handle is not a buffer of this
// page or is listed twice (DataCloneError in the platform).
message_capture :: proc(p: ^Page, text: string, buffers: []u64) -> (Message_Payload, dom.Error) {
	for h, i in buffers {
		if buffer_get(p, h) == nil { return {}, .Invalid_Handle }
		for j in 0 ..< i { if buffers[j] == h { return {}, .Invalid_Argument } }
	}
	a := base.process_allocator()
	m: Message_Payload
	if len(text) > 0 {
		t := make([]byte, len(text), a)
		copy(t, text)
		m.text = string(t)
	}
	if len(buffers) > 0 { m.buffers = make([][]byte, len(buffers), a) }
	for h, i in buffers {
		b := buffer_get(p, h)
		n := len(b.bytes)
		out := make([]byte, n, a)
		copy(out, b.bytes[:])
		delete(b.bytes)
		b.bytes = {}
		p.held -= n
		m.buffers[i] = out
		m.bytes += n
	}
	return m, .None
}

// Creates the buffers of `m` in `p` (owned by instance `owner`) and consumes the payload. `buffers` is allocated with
// `allocator`; `text` is a copy as well. Fails when the page cannot hold the bytes (its memory ceiling): the payload is
// then left intact.
message_deliver :: proc(p: ^Page, m: ^Message_Payload, owner: u32, allocator := context.allocator) -> (msg: Message, ok: bool) {
	if p.held + m.bytes > p.settings.max_fetch_bytes { return {}, false }
	msg.text = clone_string(m.text, allocator)
	msg.buffers = make([]u64, len(m.buffers), allocator)
	for b, i in m.buffers {
		buf := new(Buffer)
		buf.bytes = make([dynamic]byte, len(b))
		copy(buf.bytes[:], b)
		p.held += len(b)
		msg.buffers[i] = object_create(p, &buffer_vt, buf, owner)
	}
	message_destroy(m)
	return msg, true
}

message_destroy :: proc(m: ^Message_Payload) {
	a := base.process_allocator()
	delete(m.text, a)
	for b in m.buffers { delete(b, a) }
	delete(m.buffers, a)
	m^ = {}
}

@(private)
clone_string :: proc(s: string, allocator: runtime.Allocator) -> string {
	if s == "" { return "" }
	b := make([]byte, len(s), allocator)
	copy(b, s)
	return string(b)
}
