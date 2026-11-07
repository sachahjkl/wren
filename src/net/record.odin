package wren_net

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "wb:base"

// What `wrentool replay record` keeps of a load: each answer that came to its end, one file a piece, as the host was given it: the body decoded, the head
// without the coding's fields (native/net: http.rs), which is what `tools/testserver/replay.go` serves again. WREN_TEST_RECORD=<folder>; a release never
// reads it. A request cut short or failed leaves nothing, and a WebSocket is not recorded: replayed, they are unknown requests.
RECORD_ENV :: "WREN_TEST_RECORD"

// <folder>/<number>.http: "METHOD URL\n", the head (it ends with an empty line), the body.
RECORD_NAME :: "%s/%06d.http"
@(private = "file") REDIRECT_FIRST :: 300
@(private = "file") REDIRECT_LAST :: 308

// (set before the first request, then only read; `next` is atomic: a worker's client records too)
@(private = "file") recorder: struct { folder: string, next: int }

record_from_env :: proc() {
	when #config(WREN_CHANNEL, "dev") != "release" {
		folder := os.get_env(RECORD_ENV, base.permanent_allocator())
		if folder != "" { record_to(folder) }
	}
}

record_to :: proc(folder: string) {
	_ = os.make_directory_all(folder)
	recorder.folder = folder
	sync.atomic_store(&recorder.next, 0)
}

record_stop :: proc() { recorder.folder = "" }

@(private)
recording :: #force_inline proc() -> bool { return recorder.folder != "" }

// On the way through `process_event`, on the stack of whatever client it is.
@(private)
record_event :: proc(r: ^Request, ev: ^Event) {
	#partial switch ev.kind {
	case .Headers:
		delete(r.recorded_head, heap())
		r.recorded_head = strings.clone(ev.headers, heap())
		// (a redirect is followed from its head: the request is cancelled and comes to no end)
		if ev.status >= REDIRECT_FIRST && ev.status <= REDIRECT_LAST { record_write(r, nil) }
	case .Data:
		if !r.collect { append(&r.recorded_body, ..ev.data) }
	case .Done:
		record_write(r, r.collect ? r.body[:] : r.recorded_body[:])
	}
}

@(private = "file")
record_write :: proc(r: ^Request, body: []byte) {
	if r.job == nil || r.recorded_head == "" { return }
	name := fmt.tprintf(RECORD_NAME, recorder.folder, sync.atomic_add(&recorder.next, 1))
	first := fmt.tprintf("%s %s\n", r.job.method, r.job.url)
	text := make([]byte, len(first) + len(r.recorded_head) + len(body), context.temp_allocator)
	at := copy(text, first)
	at += copy(text[at:], r.recorded_head)
	copy(text[at:], body)
	if err := os.write_entire_file(name, text); err != nil { fmt.eprintfln("wren net: cannot record %s: %v", name, err) }
	delete(r.recorded_head, heap())
	r.recorded_head = ""
}

@(private)
record_forget :: proc(r: ^Request) {
	delete(r.recorded_head, heap())
	delete(r.recorded_body)
}

_ :: base   // (used only outside a release: record_from_env)
