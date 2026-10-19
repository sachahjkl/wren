// End-to-end test of the platform web APIs from a Wasm guest: animation frames, timers, idle callbacks, visibility,
// AbortController with fetch, promise fetch and body streams, TextEncoder / TextDecoder, crypto, Web Storage across pages
// and restarts, URL / URLSearchParams, performance, location / history. Needs build\testserver.exe running; run from the
// repository root:
//   webapitest.exe build\webapitest.wasm
package webapitest

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:net"
import "wb:page"
import "wb:wasm"

failures: int

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

console :: proc(user: rawptr, level: page.Log_Level, message: string) {
	fmt.printf("  [%v] %s\n", level, message)
}

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings
storage:  page.Storage_Manager
process:  ^base.Scope
navigations: [dynamic]string

PROFILE_DIR :: "build/webapitest_profile"

pump_until :: proc(what: string, cond: proc() -> bool, seconds := 10.0) -> bool {
	start := time.tick_now()
	for !cond() {
		if time.duration_seconds(time.tick_since(start)) > seconds { fmt.printf("  timeout waiting for %s\n", what); return false }
		host.loop_wait(&loop, 10)
	}
	return true
}

pump_for :: proc(ms: int) {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) { host.loop_wait(&loop, 5) }
}

cur: ^page.Page   // the page `attr` and `has` look at

attr :: proc(name: string) -> string {
	r := dom.find_by_id(cur.doc, "r")
	v, _ := dom.get_attribute(cur.doc, r, name)
	return v
}
has :: proc(name: string) -> bool {
	r := dom.find_by_id(cur.doc, "r")
	_, ok := dom.get_attribute(cur.doc, r, name)
	return ok
}

call :: proc(p: ^page.Page, inst: ^wasm.Instance, name: cstring, args: ..i32) -> i32 {
	argv: [4]u32
	for a, i in args { argv[i] = u32(a) }
	res := page.call_export(p, inst, name, argv[:max(len(args), 1)])
	if res != .Ok { return min(i32) }
	return i32(argv[0])
}

navigate_hook :: proc(user: rawptr, p: ^page.Page, req: page.Navigate_Request) {
	append(&navigations, fmt.aprintf("%v %s", req.kind, req.url))
}

new_page :: proc(address: string, image: []byte, tab_key: string, session: ^page.Session_History = nil) -> (^page.Page, ^wasm.Instance) {
	p := page.page_create(&loop, &loader, &settings, process, address, console)
	page.set_embedder(p, {navigate = navigate_hook, session = session, tab_key = tab_key, storage = &storage})
	inst, ok, err := page.load_module(p, image, "webapitest")
	check(ok, fmt.tprintf("module runs in %s %s", address, err))
	return p, inst
}

loop_ms :: proc() -> f64 { return f64(host.now_ns(&loop)) / 1e6 }

main :: proc() {
	if len(os.args) < 2 { fmt.eprintln("usage: webapitest webapitest.wasm"); os.exit(2) }
	image, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil { fmt.eprintln("cannot read the module"); os.exit(2) }

	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	settings.web.storage_quota = 2000
	settings.web.background_align_ms = 200
	wasm.configure_from_args(os.args[1:])   // --pref wasm.wasmtime.compiler=winch ...
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }
	os.remove_all(PROFILE_DIR)
	page.storage_manager_init(&storage, &loop, &blocking, PROFILE_DIR)
	process = base.scope_make("process")

	session: page.Session_History
	p, inst := new_page("http://127.0.0.1:8765/webapi/page.html", image, "tab-1", &session)
	cur = p

	////////////////////////////////
	fmt.println("-- animation frames, microtasks, timers")
	call(p, inst, "order_probe")
	check(page.wants_animation_frame(p), "a page with frame callbacks wants a frame")
	check(page.run_animation_frames(p, loop_ms()) == 2, "frame 1 runs the callbacks requested before it (one was cancelled)")
	check(page.wants_animation_frame(p), "a callback requested from a frame waits for the next one")
	check(page.run_animation_frames(p, loop_ms() + 16) == 1, "frame 2 runs it")
	check(!page.wants_animation_frame(p), "no frame wanted afterwards")
	pump_until("order", proc() -> bool { return has("data-order") })
	check(attr("data-order") == "sync m1 rafA m2 rafD rafC t ", fmt.tprintf("order of sync code, microtasks, frames, timers (%q)", attr("data-order")))

	call(p, inst, "nesting_probe")
	pump_until("nesting", proc() -> bool { return has("data-nest") && has("data-wide") })
	check(attr("data-nest") == "ok", fmt.tprintf("deeply nested zero-delay timers are clamped to 4 ms (levels 8-12 took %s ms)", attr("data-nest-late")))
	check(attr("data-wide") == "ok", "setTimeout with a 64-bit user value")

	call(p, inst, "idle_probe")
	pump_until("idle", proc() -> bool { return has("data-idle") })
	idle := attr("data-idle")
	check(strings.has_prefix(idle, "i1") && strings.contains(idle, "i2") && !strings.contains(idle, "i9"), fmt.tprintf("idle callbacks run in order, cancelled one skipped (%q)", idle))
	check(!strings.contains(idle, "?"), "idle callbacks get a deadline within the idle period")

	////////////////////////////////
	fmt.println("-- visibility and background throttling")
	call(p, inst, "visibility_listen")
	page.set_page_visible(p, false)
	check(attr("data-visibility") == "hidden", "visibilitychange fired, visibilityState is hidden")
	call(p, inst, "hidden_timer_probe")
	pump_until("hidden timer", proc() -> bool { return has("data-hidden-delay") })
	phase := attr("data-hidden-phase")
	check(len(phase) <= 2, fmt.tprintf("a hidden page's timer wakes up on the 200 ms grid (phase %s ms, delay %s ms)", phase, attr("data-hidden-delay")))
	call(p, inst, "order_probe")
	check(!page.wants_animation_frame(p), "a hidden page gets no animation frames")
	page.set_page_visible(p, true)
	check(attr("data-visibility") == "visible", "visible again")
	page.run_animation_frames(p, loop_ms()); page.run_animation_frames(p, loop_ms() + 16)
	pump_for(50)

	////////////////////////////////
	fmt.println("-- AbortController and fetch")
	t0 := time.tick_now()
	call(p, inst, "abort_probe")
	pump_until("abort", proc() -> bool {
		return has("data-abort") && has("data-abort-promise") && has("data-pre-aborted") && has("data-timeout") && has("data-any")
	})
	aborted := fmt.tprintf("resp ev-16 fail%d ", int(fetch.Error_Kind.Aborted))
	check(attr("data-abort") == aborted, fmt.tprintf("abort during the body: abort event, then the request fails with Aborted (%q)", attr("data-abort")))
	check(attr("data-abort-promise") == "rejected-abort", "the promise fetch on the same signal is rejected with AbortError")
	check(attr("data-pre-aborted") == fmt.tprintf("%d", int(fetch.Error_Kind.Aborted)), "an already aborted signal fails the fetch at once")
	check(attr("data-timeout") == "-17", "AbortSignal.timeout aborts with TimeoutError")
	check(attr("data-any") == "custom reason", "AbortSignal.any follows its source with its reason")
	check(time.duration_seconds(time.tick_since(t0)) < 4, "the 8 s requests did not run to completion")
	pump_until("requests cancelled", proc() -> bool { return fetch.in_flight(&loader) == 0 && net.in_flight(&client) == 0 })
	check(fetch.in_flight(&loader) == 0 && net.in_flight(&client) == 0, "aborted requests are cancelled in the network stack")

	////////////////////////////////
	fmt.println("-- promise fetch, streams, buffer bodies")
	call(p, inst, "fetch_probe")
	pump_until("fetch", proc() -> bool { return has("data-stream") && has("data-echo") && has("data-split") && has("data-neterr") })
	stream := attr("data-stream")
	joined, _ := strings.remove_all(stream, "|", context.temp_allocator)
	check(joined == "chunk-0\nchunk-1\nchunk-2\n" && strings.count(stream, "|") >= 2, fmt.tprintf("the body arrives as a stream, chunk by chunk (%q)", stream))
	check(attr("data-echo") == "bytes", "request body from a buffer, response as a buffer")
	split := attr("data-split")
	joined, _ = strings.remove_all(split, "|", context.temp_allocator)
	check(joined == "€uro" && strings.has_prefix(split, "|"), fmt.tprintf("TextDecoder stream across network chunks cut inside a character (%q)", split))
	check(attr("data-neterr") == "rejected", "a network error rejects the fetch promise with a TypeError code")

	////////////////////////////////
	fmt.println("-- encoding, crypto, URL, performance")
	rc_encoding_probe := call(p, inst, "encoding_probe")
	check(rc_encoding_probe == 1, fmt.tprintf("TextEncoder / TextDecoder (%d)", rc_encoding_probe))
	check(call(p, inst, "crypto_probe") == 1, "getRandomValues, its quota, randomUUID")
	pump_until("digests", proc() -> bool { return has("data-sha256") && has("data-sha256-big") && has("data-badalg") })
	check(attr("data-sha256") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of \"abc\"")
	zeros := make([]byte, 1 << 20)
	d: [64]u8
	page.digest(.SHA256, zeros, d[:])
	delete(zeros)
	hex := strings.builder_make(context.temp_allocator)
	for v in d[:32] { fmt.sbprintf(&hex, "%02x", v) }
	check(attr("data-sha256-big") == strings.to_string(hex), "SHA-256 of 1 MiB computed on a worker thread")
	check(attr("data-badalg") == "rejected", "an unknown digest algorithm is rejected with NotSupportedError")
	rc_url_probe := call(p, inst, "url_probe")
	check(rc_url_probe == 1, fmt.tprintf("URL and URLSearchParams (%d)", rc_url_probe))
	rc_performance_probe := call(p, inst, "performance_probe")
	check(rc_performance_probe == 1, fmt.tprintf("performance mark / measure / entries (%d)", rc_performance_probe))

	rc_stale := call(p, inst, "stale_probe")
	check(rc_stale == 1, fmt.tprintf("stale handles and bad arguments are refused cleanly (%d)", rc_stale))
	check(call(p, inst, "stale_getter_probe") == min(i32) && strings.contains(inst.last_error, "not a live URL"), fmt.tprintf("a getter on a released object traps (%q)", inst.last_error))
	check(call(p, inst, "wrong_kind_probe") == min(i32) && strings.contains(inst.last_error, "not a live TextDecoder"), fmt.tprintf("a handle of another kind traps (%q)", inst.last_error))
	held := p.held
	check(call(p, inst, "bad_length_probe") == min(i32) && strings.contains(inst.last_error, "out of bounds"), "a length past the memory traps in the binding layer instead of reaching the implementation")
	check(p.held == held && call(p, inst, "url_probe") == 1, "the instance stays usable after the trap")

	////////////////////////////////
	fmt.println("-- Web Storage")
	q, qi := new_page("http://127.0.0.1:8765/other.html", image, "tab-2")
	call(q, qi, "storage_listen")
	check(call(p, inst, "storage_probe", 0) == 1, "setItem / key in one page")
	cur = q
	pump_until("storage event", proc() -> bool { return has("data-storage-event") })
	pump_for(50)
	check(attr("data-storage-event") == "k,<null>,persisted value,http://127.0.0.1:8765/webapi/page.html,0",
		fmt.tprintf("the other page of the origin gets one storage event, not the other tab's sessionStorage (%q)", attr("data-storage-event")))
	check(call(q, qi, "storage_probe", 1) == 15, "the other page reads the value")
	check(call(p, inst, "storage_probe", 2) == page.WEB_ERR_QUOTA, "a write past the quota fails with QuotaExceededError")
	o, oi := new_page("file:///C:/nowhere/x.html", image, "tab-3")
	check(call(o, oi, "storage_probe", 3) == page.WEB_ERR_SECURITY, "an opaque origin gets a SecurityError")
	page.page_close(o)
	page.page_close(q)
	cur = p

	////////////////////////////////
	fmt.println("-- location and history")
	navs := len(navigations)
	rc_history_probe := call(p, inst, "history_probe")
	check(rc_history_probe == 1, fmt.tprintf("pushState / replaceState / state / length (%d)", rc_history_probe))
	pump_until("popstate", proc() -> bool { return strings.contains(attr("data-history"), "hash:") })
	pump_for(50)
	h := attr("data-history")
	check(h == "pop:s1 hash:http://127.0.0.1:8765/webapi/page.html?p=1 ", fmt.tprintf("history.back to a same-document entry: popstate with its state, then hashchange (%q)", h))
	check(len(navigations) > navs && strings.has_prefix(navigations[len(navigations) - 1], "Url_Changed"), "the embedder hears about same-document URL changes")
	navs = len(navigations)
	check(call(p, inst, "location_probe") == 1, "location.assign to a fragment stays in the document")
	pump_until("navigation request", proc() -> bool { return len(navigations) > 0 && strings.has_prefix(navigations[len(navigations) - 1], "Assign") })
	check(navigations[len(navigations) - 1] == "Assign http://127.0.0.1:8765/elsewhere.html", fmt.tprintf("a cross-document navigation goes to the embedder (%s)", navigations[len(navigations) - 1]))

	////////////////////////////////
	fmt.println("-- closing, restart")
	page.page_close(p)
	pump_for(50)
	check(fetch.in_flight(&loader) == 0, "no request left")
	page.storage_manager_destroy(&storage)
	check(os.exists(PROFILE_DIR + "/storage/http_3A_2F_2F127.0.0.1_3A8765.wls"), "localStorage was written to the profile")
	page.storage_manager_init(&storage, &loop, &blocking, PROFILE_DIR)
	r, ri := new_page("http://127.0.0.1:8765/after-restart.html", image, "tab-9")
	check(call(r, ri, "storage_probe", 1) == 15, "localStorage survives a restart of the storage manager")
	page.page_close(r)
	page.session_destroy(&session)

	base.scope_close(process)
	page.storage_manager_destroy(&storage)
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	host.loop_destroy(&loop)
	wasm.runtime_destroy()
	os.remove_all(PROFILE_DIR)
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures)
}
