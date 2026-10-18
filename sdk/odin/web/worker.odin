package web

// Dedicated workers (import module "workers"): a module started by a page on a thread of its own. They share no memory:
// messages carry a text and, optionally, buffers whose ownership moves to the receiver (the sender's buffer becomes
// empty, "detached").
//
// Page side:   w := worker_create("worker.wasm", "name"); add_event_listener(w, "message", on_message)
//              worker_post(w, "hello", {buffer}); Worker_terminate(w)
// Worker side: add_event_listener(worker_self(), "message", on_message); worker_post_to_page("result")
//              DedicatedWorkerGlobalScope_close()
//
// A message event: event_data(ev, buf) is the text, Event_code(ev) the number of buffers, message_buffer(ev, i) each
// of them (Event_object(ev) is the first). Received buffers are yours: release them with Object_release.
// A Worker object also receives "error" (Event_data = message, Event_text = script URL) and "messageerror".
// A worker can use console, timers, async (promises, buffers), events on objects and fetch (requests are made with the
// worker's origin); the document imports fail there.

foreign import workers_mod "workers"

@(default_calling_convention = "contextless")
foreign workers_mod {
	@(link_name = "Worker_create") raw_workerCreate :: proc(url: [^]u8, ul: i32, name: [^]u8, nl: i32) -> Handle ---
	@(link_name = "Worker_postMessage") raw_workerPostMessage :: proc(w: Handle, text: [^]u8, tl: i32, transfer: [^]Handle, bytes: i32) -> Error ---
	Worker_terminate :: proc(w: Handle) -> Error ---
	DedicatedWorkerGlobalScope_self :: proc() -> Handle ---
	@(link_name = "DedicatedWorkerGlobalScope_postMessage") raw_selfPostMessage :: proc(text: [^]u8, tl: i32, transfer: [^]Handle, bytes: i32) -> Error ---
	DedicatedWorkerGlobalScope_close :: proc() -> Error ---
	@(link_name = "DedicatedWorkerGlobalScope_name") raw_workerName :: proc(buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "WorkerGlobalScope_location") raw_workerLocation :: proc(buf: [^]u8, cap: i32) -> i32 ---
	MessageEvent_transfer :: proc(ev: Handle, index: i32) -> Handle ---
}

// Page: starts a worker running the module at `url` (same origin as the document, or a data: URL). NIL if refused.
worker_create :: proc "contextless" (url: string, name := "") -> Handle {
	return raw_workerCreate(raw_data(url), i32(len(url)), raw_data(name), i32(len(name)))
}

// Page: sends a message to the worker; the buffers in `transfer` move to it.
worker_post :: proc "contextless" (w: Handle, text: string, transfer: []Handle = nil) -> Error {
	return raw_workerPostMessage(w, raw_data(text), i32(len(text)), raw_data(transfer), i32(len(transfer) * size_of(Handle)))
}

// Worker: the global scope, target of the page's messages. NIL in a page (a cheap "am I a worker?").
worker_self :: proc "contextless" () -> Handle { return DedicatedWorkerGlobalScope_self() }

// Worker: sends a message to the page; the buffers in `transfer` move to it.
worker_post_to_page :: proc "contextless" (text: string, transfer: []Handle = nil) -> Error {
	return raw_selfPostMessage(raw_data(text), i32(len(text)), raw_data(transfer), i32(len(transfer) * size_of(Handle)))
}

worker_name :: proc "contextless" (buf: []u8) -> string {
	n := raw_workerName(raw_data(buf), i32(len(buf)))
	return string(buf[:min(int(max(n, 0)), len(buf))])
}

worker_location :: proc "contextless" (buf: []u8) -> string {
	n := raw_workerLocation(raw_data(buf), i32(len(buf)))
	return string(buf[:min(int(max(n, 0)), len(buf))])
}

// The i-th buffer transferred with a message event (0 <= i < Event_code(ev)).
message_buffer :: proc "contextless" (ev: Handle, i: int) -> Handle { return MessageEvent_transfer(ev, i32(i)) }
