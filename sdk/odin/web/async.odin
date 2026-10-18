package web

// Promises, microtasks, buffers and object handles (import module "async").
//
// A promise reaction is (callback, user); it runs as a microtask once the promise settles, with the promise and its state.
// Read the result with Promise_value / promise_text. There is no chaining: a reaction that produces a result resolves a
// promise of its own.

Promise_State :: enum i32 { Pending = 0, Fulfilled = 1, Rejected = 2 }

Microtask_Callback :: #type proc "contextless" (user: i32)
Promise_Callback :: #type proc "contextless" (user: i32, promise: Handle, state: Promise_State)

foreign import async_mod "async"
foreign import events_payload "events"

@(default_calling_convention = "contextless")
foreign async_mod {
	queueMicrotask :: proc(cb: Microtask_Callback, user: i32) ---
	Promise_create :: proc() -> Handle ---
	@(link_name = "Promise_resolve") raw_promiseResolve :: proc(p: Handle, value: i64, text: [^]u8, tl: i32) -> Error ---
	@(link_name = "Promise_reject") raw_promiseReject :: proc(p: Handle, code: i64, text: [^]u8, tl: i32) -> Error ---
	Promise_then :: proc(p: Handle, cb: Promise_Callback, user: i32) -> Error ---
	Promise_state :: proc(p: Handle) -> Promise_State ---
	Promise_value :: proc(p: Handle) -> i64 ---
	@(link_name = "Promise_text") raw_promiseText :: proc(p: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Promise_all") raw_promiseAll :: proc(list: [^]Handle, bytes: i32) -> Handle ---
	Object_release :: proc(h: Handle) -> Error ---
	@(link_name = "Object_kind") raw_objectKind :: proc(h: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Buffer_create") raw_bufferCreate :: proc(src: [^]u8, n: i32) -> Handle ---
	Buffer_alloc :: proc(n: i64) -> Handle ---
	Buffer_length :: proc(b: Handle) -> i64 ---
	@(link_name = "Buffer_read") raw_bufferRead :: proc(b: Handle, offset: i64, dst: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Buffer_write") raw_bufferWrite :: proc(b: Handle, offset: i64, src: [^]u8, n: i32) -> i32 ---
	Buffer_slice :: proc(b: Handle, start, end: i64) -> Handle ---
}

@(default_calling_convention = "contextless")
foreign events_payload {
	@(link_name = "Event_data") raw_eventData :: proc(ev: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Event_text") raw_eventText :: proc(ev: Handle, buf: [^]u8, cap: i32) -> i32 ---
	Event_code :: proc(ev: Handle) -> i64 ---
	Event_object :: proc(ev: Handle) -> Handle ---
	Event_defaultPrevented :: proc(ev: Handle) -> i32 ---
}

promise_resolve :: proc "contextless" (p: Handle, value: i64 = 0, text := "") -> Error { return raw_promiseResolve(p, value, raw_data(text), i32(len(text))) }
promise_reject :: proc "contextless" (p: Handle, code: i64, message := "") -> Error { return raw_promiseReject(p, code, raw_data(message), i32(len(message))) }

promise_text :: proc "contextless" (p: Handle, buf: []u8) -> string {
	n := raw_promiseText(p, raw_data(buf), i32(len(buf)))
	return string(buf[:min(int(max(n, 0)), len(buf))])
}

promise_all :: proc "contextless" (list: []Handle) -> Handle { return raw_promiseAll(raw_data(list), i32(len(list) * size_of(Handle))) }

buffer_create :: proc "contextless" (bytes: []u8) -> Handle { return raw_bufferCreate(raw_data(bytes), i32(len(bytes))) }
buffer_read :: proc "contextless" (b: Handle, dst: []u8, offset: i64 = 0) -> []u8 {
	n := raw_bufferRead(b, offset, raw_data(dst), i32(len(dst)))
	return dst[:max(n, 0)]
}
buffer_write :: proc "contextless" (b: Handle, src: []u8, offset: i64 = 0) -> int { return int(raw_bufferWrite(b, offset, raw_data(src), i32(len(src)))) }

// MessageEvent.data and friends: the event's main string payload.
event_data :: proc "contextless" (ev: Handle, buf: []u8) -> (s: string, needed: int) {
	n := raw_eventData(ev, raw_data(buf), i32(len(buf)))
	if n < 0 { return "", 0 }
	return string(buf[:min(int(n), len(buf))]), int(n)
}
event_text :: proc "contextless" (ev: Handle, buf: []u8) -> string {
	n := raw_eventText(ev, raw_data(buf), i32(len(buf)))
	return string(buf[:min(int(max(n, 0)), len(buf))])
}
