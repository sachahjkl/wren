#+private file
// The platform web APIs from a Wasm guest: animation frames, timers, idle callbacks, visibility, AbortController with fetch, promise fetch
// and body streams, TextEncoder / TextDecoder, crypto, Web Storage across pages and restarts, URL / URLSearchParams, performance,
// location / history, and what happens to stale handles and bad arguments.
package e2e_scenarios

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:net"
import "wb:page"
import "wb:tools/testenv"
import "wb:wasm"

GUEST :: "build/webapitest.wasm"
ADDRESS :: "http://127.0.0.1:8765/webapi/page.html"
OTHER_ADDRESS :: "http://127.0.0.1:8765/other.html"
RESTART_ADDRESS :: "http://127.0.0.1:8765/after-restart.html"
OPAQUE_ADDRESS :: "file:///C:/nowhere/x.html"
NEXT_FRAME_MS :: 16
STORAGE_QUOTA :: 2000
BACKGROUND_GRID_MS :: 200
BIG_DIGEST_BYTES :: 1 << 20         // of the guest's zeros: above crypto.digest_offload_bytes
SHA256_BYTES :: 32
STORED_VALUE_BYTES :: 15            // of "persisted value"
TRAPPED :: min(i32)

// storage_probe's modes (examples/webapitest)
STORAGE_WRITE :: 0
STORAGE_READ :: 1
STORAGE_QUOTA_CHECK :: 2
STORAGE_SECURITY_CHECK :: 3
STORAGE_CLEAR :: 4

Embedding :: struct {
	navigations: [dynamic]string,
	session:     page.Session_History,
}

navigate_hook :: proc(user: rawptr, p: ^page.Page, req: page.Navigate_Request) {
	e := (^Embedding)(user)
	append(&e.navigations, fmt.aprintf("%v %s", req.kind, req.url, allocator = base.process_context().temp_allocator))
}

// A page running the guest (its first check). When that fails it is closed already.
open :: proc(t: ^testing.T, address, tab_key: string, storage: ^page.Storage_Manager = nil, e: ^Embedding = nil) -> (pr: ^Probe, inst: ^wasm.Instance, ok: bool) {
	pr = page_make(t, tab_key, address)
	page.set_embedder(pr.p, {navigate = e != nil ? navigate_hook : nil, user = e, session = e != nil ? &e.session : nil, tab_key = tab_key, storage = storage})
	image, err := os.read_entire_file(GUEST, context.temp_allocator)
	testing.expect(t, err == nil, "cannot read the guest")
	loaded: bool
	message: string
	inst, loaded, message = page.load_module(pr.p, image, "webapitest")
	check(pr, loaded, fmt.tprintf("module runs in %s %s", address, message))
	if !loaded { close_page(pr); return nil, nil, false }
	return pr, inst, true
}

attr :: proc(p: ^page.Page, name: string) -> string {
	v, _ := dom.get_attribute(p.doc, dom.find_by_id(p.doc, "r"), name)
	return v
}

has :: proc(p: ^page.Page, name: string) -> bool {
	_, ok := dom.get_attribute(p.doc, dom.find_by_id(p.doc, "r"), name)
	return ok
}

Wait_Attrs :: struct { p: ^page.Page, names: []string }

// Until the result element has all these attributes.
wait_attrs :: proc(pr: ^Probe, names: ..string) -> bool {
	return wait_until(pr.t, fmt.tprint(names), Wait_Attrs{pr.p, names}, proc(w: Wait_Attrs) -> bool {
		for n in w.names { if !has(w.p, n) { return false } }
		return true
	})
}

call :: proc(pr: ^Probe, inst: ^wasm.Instance, name: cstring, args: ..i32) -> i32 {
	argv: [4]u32
	for a, i in args { argv[i] = u32(a) }
	res := page.call_export(pr.p, inst, name, argv[:max(len(args), 1)])
	if res != .Ok { return TRAPPED }
	return i32(argv[0])
}

loop_ms :: proc() -> f64 { return f64(host.now_ns(&loop)) / 1e6 }

@(test)
webapi_animation_frames_microtasks_timers :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr, inst, ok := open(t, testenv.url(ADDRESS), "tab-1")
	if !ok { return }
	p := pr.p
	call(pr, inst, "order_probe")
	check(pr, page.wants_animation_frame(p), "a page with frame callbacks wants a frame")
	check(pr, page.run_animation_frames(p, loop_ms()) == 2, "frame 1 runs the callbacks requested before it (one was cancelled)")
	check(pr, page.wants_animation_frame(p), "a callback requested from a frame waits for the next one")
	check(pr, page.run_animation_frames(p, loop_ms() + NEXT_FRAME_MS) == 1, "frame 2 runs it")
	check(pr, !page.wants_animation_frame(p), "no frame wanted afterwards")
	wait_attrs(pr, "data-order")
	check(pr, attr(p, "data-order") == "sync m1 rafA m2 rafD rafC t ", fmt.tprintf("order of sync code, microtasks, frames, timers (%q)", attr(p, "data-order")))

	call(pr, inst, "nesting_probe")
	wait_attrs(pr, "data-nest", "data-wide")
	check(pr, attr(p, "data-nest") == "ok", fmt.tprintf("deeply nested zero-delay timers are clamped to 4 ms (levels 8-12 took %s ms)", attr(p, "data-nest-late")))
	check(pr, attr(p, "data-wide") == "ok", "setTimeout with a 64-bit user value")

	call(pr, inst, "idle_probe")
	wait_attrs(pr, "data-idle")
	idle := attr(p, "data-idle")
	check(pr, strings.has_prefix(idle, "i1") && strings.contains(idle, "i2") && !strings.contains(idle, "i9"), fmt.tprintf("idle callbacks run in order, cancelled one skipped (%q)", idle))
	check(pr, !strings.contains(idle, "?"), "idle callbacks get a deadline within the idle period")
	close_page(pr, min_checks = 11)
}

@(test)
webapi_visibility_and_background_throttling :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	settings.web.background_align_ms = BACKGROUND_GRID_MS
	pr, inst, ok := open(t, testenv.url(ADDRESS), "tab-1")
	if !ok { return }
	p := pr.p
	call(pr, inst, "visibility_listen")
	page.set_page_visible(p, false)
	check(pr, attr(p, "data-visibility") == "hidden", "visibilitychange fired, visibilityState is hidden")
	call(pr, inst, "hidden_timer_probe")
	wait_attrs(pr, "data-hidden-delay")
	check(pr, attr(p, "data-hidden-grid") == "ok", fmt.tprintf("a hidden page's timer waits for the 200 ms grid (phase %s ms, delay %s ms)", attr(p, "data-hidden-phase"), attr(p, "data-hidden-delay")))
	call(pr, inst, "order_probe")
	check(pr, !page.wants_animation_frame(p), "a hidden page gets no animation frames")
	page.set_page_visible(p, true)
	check(pr, attr(p, "data-visibility") == "visible", "visible again")
	close_page(pr, min_checks = 5)
}

@(test)
webapi_abort_controller_and_fetch :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr, inst, ok := open(t, testenv.url(ADDRESS), "tab-1")
	if !ok { return }
	p := pr.p
	call(pr, inst, "abort_probe")
	wait_attrs(pr, "data-abort", "data-abort-promise", "data-pre-aborted", "data-timeout", "data-any")
	aborted := fmt.tprintf("resp ev-16 fail%d ", int(fetch.Error_Kind.Aborted))
	check(pr, attr(p, "data-abort") == aborted, fmt.tprintf("abort during the body: abort event, then the request fails with Aborted (%q)", attr(p, "data-abort")))
	check(pr, attr(p, "data-abort-promise") == "rejected-abort", "the promise fetch on the same signal is rejected with AbortError")
	check(pr, attr(p, "data-pre-aborted") == fmt.tprintf("%d", int(fetch.Error_Kind.Aborted)), "an already aborted signal fails the fetch at once")
	check(pr, attr(p, "data-timeout") == "-17", "AbortSignal.timeout aborts with TimeoutError")
	check(pr, attr(p, "data-any") == "custom reason", "AbortSignal.any follows its source with its reason")
	check(pr, wait_until(t, "the requests' end", 0, proc(_: int) -> bool { return fetch.in_flight(&loader) == 0 && net.in_flight(&client) == 0 }), "aborted requests are cancelled in the network stack")
	close_page(pr, min_checks = 7)
}

@(test)
webapi_promise_fetch_streams_buffer_bodies :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr, inst, ok := open(t, testenv.url(ADDRESS), "tab-1")
	if !ok { return }
	p := pr.p
	call(pr, inst, "fetch_probe")
	wait_attrs(pr, "data-stream", "data-echo", "data-split", "data-neterr")
	stream := attr(p, "data-stream")
	joined, _ := strings.remove_all(stream, "|", context.temp_allocator)
	check(pr, joined == "chunk-0\nchunk-1\nchunk-2\n" && strings.count(stream, "|") >= 2, fmt.tprintf("the body arrives as a stream, chunk by chunk (%q)", stream))
	check(pr, attr(p, "data-echo") == "bytes", "request body from a buffer, response as a buffer")
	split := attr(p, "data-split")
	joined, _ = strings.remove_all(split, "|", context.temp_allocator)
	check(pr, joined == "€uro" && strings.has_prefix(split, "|"), fmt.tprintf("TextDecoder stream across network chunks cut inside a character (%q)", split))
	check(pr, attr(p, "data-neterr") == "rejected", "a network error rejects the fetch promise with a TypeError code")
	close_page(pr, min_checks = 5)
}

@(test)
webapi_encoding_crypto_url_performance :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr, inst, ok := open(t, testenv.url(ADDRESS), "tab-1")
	if !ok { return }
	p := pr.p
	rc := call(pr, inst, "encoding_probe")
	check(pr, rc == 1, fmt.tprintf("TextEncoder / TextDecoder (%d)", rc))
	check(pr, call(pr, inst, "crypto_probe") == 1, "getRandomValues, its quota, randomUUID")
	wait_attrs(pr, "data-sha256", "data-sha256-big", "data-badalg")
	check(pr, attr(p, "data-sha256") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of \"abc\"")
	zeros := make([]byte, BIG_DIGEST_BYTES, context.temp_allocator)
	d: [64]u8
	page.digest(.SHA256, zeros, d[:])
	hex := strings.builder_make(context.temp_allocator)
	for v in d[:SHA256_BYTES] { fmt.sbprintf(&hex, "%02x", v) }
	check(pr, attr(p, "data-sha256-big") == strings.to_string(hex), "SHA-256 of 1 MiB computed on a worker thread")
	check(pr, attr(p, "data-badalg") == "rejected", "an unknown digest algorithm is rejected with NotSupportedError")
	rc = call(pr, inst, "url_probe")
	check(pr, rc == 1, fmt.tprintf("URL and URLSearchParams (%d)", rc))
	rc = call(pr, inst, "performance_probe")
	check(pr, rc == 1, fmt.tprintf("performance mark / measure / entries (%d)", rc))
	close_page(pr, min_checks = 8)
}

@(test)
webapi_stale_handles_and_bad_arguments :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr, inst, ok := open(t, testenv.url(ADDRESS), "tab-1")
	if !ok { return }
	p := pr.p
	rc := call(pr, inst, "stale_probe")
	check(pr, rc == 1, fmt.tprintf("stale handles and bad arguments are refused cleanly (%d)", rc))
	check(pr, call(pr, inst, "stale_getter_probe") == TRAPPED && strings.contains(inst.last_error, "not a live URL"), fmt.tprintf("a getter on a released object traps (%q)", inst.last_error))
	check(pr, call(pr, inst, "wrong_kind_probe") == TRAPPED && strings.contains(inst.last_error, "not a live TextDecoder"), fmt.tprintf("a handle of another kind traps (%q)", inst.last_error))
	held := p.held
	check(pr, call(pr, inst, "bad_length_probe") == TRAPPED && strings.contains(inst.last_error, "out of bounds"), "a length past the memory traps in the binding layer instead of reaching the implementation")
	check(pr, p.held == held && call(pr, inst, "url_probe") == 1, "the instance stays usable after the trap")
	close_page(pr, min_checks = 6)
}

@(test)
webapi_web_storage :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	settings.web.storage_quota = STORAGE_QUOTA
	storage := storage_world()
	pr, inst, ok := open(t, testenv.url(ADDRESS), "tab-1", storage)
	if !ok { return }
	call(pr, inst, "storage_probe", STORAGE_CLEAR)   // the profile's, shared with what ran before
	other, other_inst, other_ok := open(t, testenv.url(OTHER_ADDRESS), "tab-2", storage)
	if !other_ok { close_page(pr); return }
	call(other, other_inst, "storage_listen")
	check(pr, call(pr, inst, "storage_probe", STORAGE_WRITE) == 1, "setItem / key in one page")
	wait_attrs(other, "data-storage-event")
	drain()
	event := attr(other.p, "data-storage-event")
	check(other, event == testenv.url("k,<null>,persisted value,http://127.0.0.1:8765/webapi/page.html,0"), fmt.tprintf("the other page of the origin gets one storage event, not the other tab's sessionStorage (%q)", event))
	check(other, call(other, other_inst, "storage_probe", STORAGE_READ) == STORED_VALUE_BYTES, "the other page reads the value")
	check(pr, call(pr, inst, "storage_probe", STORAGE_QUOTA_CHECK) == page.WEB_ERR_QUOTA, "a write past the quota fails with QuotaExceededError")
	opaque, opaque_inst, opaque_ok := open(t, OPAQUE_ADDRESS, "tab-3", storage)
	if opaque_ok {
		check(opaque, call(opaque, opaque_inst, "storage_probe", STORAGE_SECURITY_CHECK) == page.WEB_ERR_SECURITY, "an opaque origin gets a SecurityError")
		close_page(opaque, min_checks = 2)
	}
	close_page(other, min_checks = 3)
	call(pr, inst, "storage_probe", STORAGE_CLEAR)
	close_page(pr, min_checks = 3)
}

@(test)
webapi_location_and_history :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	e: Embedding
	e.navigations = make([dynamic]string, base.process_context().temp_allocator)
	defer page.session_destroy(&e.session)
	pr, inst, ok := open(t, testenv.url(ADDRESS), "tab-1", nil, &e)
	if !ok { return }
	p := pr.p
	rc := call(pr, inst, "history_probe")
	check(pr, rc == 1, fmt.tprintf("pushState / replaceState / state / length (%d)", rc))
	wait_until(t, "popstate", p, proc(p: ^page.Page) -> bool { return strings.contains(attr(p, "data-history"), "hash:") })
	drain()
	h := attr(p, "data-history")
	check(pr, h == testenv.url("pop:s1 hash:http://127.0.0.1:8765/webapi/page.html?p=1 "), fmt.tprintf("history.back to a same-document entry: popstate with its state, then hashchange (%q)", h))
	check(pr, len(e.navigations) > 0 && strings.has_prefix(e.navigations[len(e.navigations) - 1], "Url_Changed"), "the embedder hears about same-document URL changes")
	check(pr, call(pr, inst, "location_probe") == 1, "location.assign to a fragment stays in the document")
	wait_until(t, "the navigation request", &e, proc(e: ^Embedding) -> bool { return len(e.navigations) > 0 && strings.has_prefix(e.navigations[len(e.navigations) - 1], "Assign") })
	last := e.navigations[len(e.navigations) - 1]
	check(pr, last == testenv.url("Assign http://127.0.0.1:8765/elsewhere.html"), fmt.tprintf("a cross-document navigation goes to the embedder (%s)", last))
	close_page(pr, min_checks = 6)
}

@(test)
webapi_closing_and_restart :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	storage := storage_world()
	pr, inst, ok := open(t, testenv.url(ADDRESS), "tab-1", storage)
	if !ok { return }
	check(pr, call(pr, inst, "storage_probe", STORAGE_CLEAR) == 1, "the profile's area is cleared")
	check(pr, call(pr, inst, "storage_probe", STORAGE_WRITE) == 1, "setItem")
	close_page(pr, min_checks = 3)
	testing.expect(t, wait_until(t, "the requests of the closed page", 0, proc(_: int) -> bool { return fetch.in_flight(&loader) == 0 }), "no request left")
	page.storage_manager_destroy(storage)
	testing.expect(t, os.exists(fmt.tprintf("%s/storage/http_3A_2F_2F127.0.0.1_3A%d.wls", storage_dir(), testenv.port())), "localStorage was written to the profile")
	page.storage_manager_init(storage, &loop, &blocking, storage_dir())
	after, after_inst, after_ok := open(t, testenv.url(RESTART_ADDRESS), "tab-9", storage)
	if !after_ok { return }
	check(after, call(after, after_inst, "storage_probe", STORAGE_READ) == STORED_VALUE_BYTES, "localStorage survives a restart of the storage manager")
	call(after, after_inst, "storage_probe", STORAGE_CLEAR)
	close_page(after, min_checks = 2)
}
