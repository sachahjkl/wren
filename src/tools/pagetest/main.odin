// Headless end-to-end test of the page stack: DOM, events, timers, several modules per document, fetch through the
// policy layer, cookies, origin. Needs build\testserver.exe running and is run from the repository root.
//   pagetest.exe build\e2e.wasm examples\site\index.html examples\site\counter.wasm
package pagetest

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:cookies"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:html"
import "wb:net"
import "wb:page"
import "wb:wasm"

failures: int
logs: [dynamic]string

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

console :: proc(user: rawptr, level: page.Log_Level, message: string) {
	append(&logs, strings.clone(message))
	fmt.printf("  [%v] %s\n", level, message)
}

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings

pump_until :: proc(what: string, cond: proc() -> bool, seconds := 10.0) -> bool {
	start := time.tick_now()
	for !cond() {
		if time.duration_seconds(time.tick_since(start)) > seconds { fmt.printf("  timeout waiting for %s\n", what); return false }
		host.loop_wait(&loop, 20)
	}
	return true
}

the_page: ^page.Page

attr :: proc(h: base.Handle, name: string) -> string {
	v, _ := dom.get_attribute(the_page.doc, h, name)
	return v
}

main :: proc() {
	if len(os.args) < 4 { fmt.eprintln("usage: pagetest e2e.wasm index.html counter.wasm"); os.exit(2) }
	e2e, err := os.read_entire_file(os.args[1], context.allocator)
	html_bytes, herr := os.read_entire_file(os.args[2], context.allocator)
	counter, cerr := os.read_entire_file(os.args[3], context.allocator)
	if err != nil || herr != nil || cerr != nil { fmt.eprintln("cannot read inputs"); os.exit(2) }

	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	wasm.configure_from_args(os.args[1:])   // --pref wasm.engine=wamr ...
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }

	process := base.scope_make("process")

	////////////////////////////////
	fmt.println("-- one module: DOM, events, timers, fetch")
	p := page.page_create(&loop, &loader, &settings, process, "http://127.0.0.1:8765/page.html", console)
	the_page = p
	check(!p.env.origin.opaque && p.env.secure_context, "http://127.0.0.1 is a secure context with a tuple origin")

	inst, ok, e := page.load_module(p, e2e, "e2e")
	check(ok, fmt.tprintf("module loads and wb_main runs %s", e))
	app := dom.find_by_id(p.doc, "app")
	check(app != base.NIL_HANDLE, "guest created #app in the DOM")
	check(dom.text_content(p.doc, app) == "ready", "text content set by the guest")
	check(fetch.in_flight(&loader) >= 1, "requests are in flight")
	check(loop.timers.count == 1, "one timer registered")

	pump_until("timer and fetches", proc() -> bool {
		a := dom.find_by_id(the_page.doc, "app")
		return attr(a, "data-timer") == "fired" && attr(a, "data-fetched") != "" && attr(a, "data-error") != ""
	})
	check(attr(app, "data-timer") == "fired", "timer callback ran in the guest")
	check(attr(app, "data-fetched") == "49", "same-origin fetch delivered the body to the guest (49 bytes)")
	check(attr(app, "data-type") == "basic", "same-origin response type is basic")
	check(strings.contains(attr(app, "data-error"), "secure connection failed"), "self-signed HTTPS rejected, error reaches the guest")
	check(fetch.in_flight(&loader) == 0, "no task left after completion")
	check(loop.timers.count == 0, "one-shot timer released after firing")
	check(p.fetches.count == 0 && p.held == 0, "guest released its fetch records")

	click := dom.Event{type = "click", bubbles = true, cancelable = true, x = 10, y = 10}
	check(page.dispatch_event(p, app, click), "click dispatched")
	check(dom.text_content(p.doc, app) == "clicked 1", "listener in the guest updated the DOM")
	click.x = 500
	check(!page.dispatch_event(p, app, click), "guest called preventDefault")
	check(p.dp.events.count == 0, "transient event objects freed")

	before := p.doc.nodes.count
	wasm.call_raw(inst, "churn", {20000})
	check(p.doc.nodes.count == before, "20,000 create/release cycles leave the node count unchanged")
	r, res := wasm.call_i32(inst, "stale")
	check(res == .Ok && r == i32(dom.Error.Invalid_Handle), "stale handle rejected cleanly")
	res = wasm.call_raw(inst, "bad_pointer")
	check(res == .Trapped, "out-of-bounds pointer traps instead of reaching the host")
	r, res = wasm.call_i32(inst, "stale")
	check(res == .Ok, "instance still usable after the trap")

	////////////////////////////////
	fmt.println("-- microtasks, promises, buffers")
	page.call_export(p, inst, "async_probe")
	pump_until("promise all", proc() -> bool { return attr(dom.find_by_id(the_page.doc, "app"), "data-async") != "" })
	check(attr(app, "data-async") == "sync m1 m2 ok42 ko-7 m3 all-ok ", fmt.tprintf("microtask and promise ordering (got %q)", attr(app, "data-async")))
	check(len(p.objects.microtasks) == 0, "microtask queue drained")
	b, bres := wasm.call_i32(inst, "buffer_probe")
	check(bres == .Ok && b == 1, fmt.tprintf("buffers: create, slice, read, write, release (%d)", b))
	check(p.held == 0, "buffer memory returned to the page budget")

	////////////////////////////////
	fmt.println("-- origin, cookies, CORS from the guest")
	cookies.clear_all(&profile.jar)
	n, res2 := wasm.call_i32(inst, "cookie_probe")
	check(res2 == .Ok && n == len("probe=1"), "document.cookie set and read by the guest")
	check(cookies.count(&profile.jar) == 1, "the cookie lives in the profile's jar")
	o, _ := wasm.call_i32(inst, "origin_probe")
	check(o == len("http://127.0.0.1:8765"), "the guest can read its own origin")

	wasm.call_raw(inst, "start_cors_probe", {0})
	pump_until("cors probe", proc() -> bool { return attr(dom.find_by_id(the_page.doc, "app"), "data-cors") != "" })
	check(attr(app, "data-cors") == fmt.tprintf("%d", int(fetch.Error_Kind.Blocked_Cors)), "a cross-origin fetch without CORS is refused with Blocked_Cors")
	dom.remove_attribute(p.doc, app, "data-cors")
	wasm.call_raw(inst, "start_cors_probe", {1})
	pump_until("cors probe 2", proc() -> bool { return attr(dom.find_by_id(the_page.doc, "app"), "data-cors") != "" })
	check(attr(app, "data-cors") == "allowed", "a CORS-enabled cross-origin fetch succeeds")

	fpage := page.page_create(&loop, &loader, &settings, process, "file:///S:/wasm_browser/build/x.html", console)
	finst, fok, _ := page.load_module(fpage, e2e, "e2e-file")
	_ = fok
	fn, _ := wasm.call_i32(finst, "cookie_probe")
	check(fn == -1, "a file: document gets a SecurityError for cookies")
	fo, _ := wasm.call_i32(finst, "origin_probe")
	check(fo == len("null"), "a file: document's origin is \"null\"")
	page.page_close(fpage)

	////////////////////////////////
	fmt.println("-- closing with work in flight")
	wasm.call_raw(inst, "wb_main")   // second run: more requests + a timer
	check(fetch.in_flight(&loader) > 0 && loop.timers.count > 0, "work in flight before close")
	page.page_close(p)
	check(fetch.in_flight(&loader) == 0 && net.in_flight(&client) == 0, "closing the page cancelled its requests")
	check(loop.timers.count == 0, "closing the page removed its timers")
	for _ in 0 ..< 10 { host.loop_wait(&loop, 20) }
	check(len(process.children) == 0, "page scope detached from its parent")

	////////////////////////////////
	fmt.println("-- an HTML document with two modules")
	// the second module is e2e itself: both instances share the DOM; table indices collide on purpose
	decoded, _ := html.decode_document(html_bytes, "utf-8", settings.html.default_encoding)
	hp := page.page_create(&loop, &loader, &settings, process, "http://127.0.0.1:8765/site/index.html", console)
	the_page = hp
	rr := page.load_html(hp, decoded.text)
	check(rr.ok && rr.nodes > 20, "HTML document parsed by Lexbor into the DOM")
	check(html.title(hp.doc) == "Wasm-first demo", "document title extracted")
	scripts := html.wasm_scripts(hp.doc, settings.html.module_script_type)
	src, _ := dom.get_attribute(hp.doc, scripts[0] if len(scripts) > 0 else base.NIL_HANDLE, "src")
	check(len(scripts) == 1 && src == "counter.wasm", "the document names its Wasm module")

	ci, cok, ce := page.load_module(hp, counter, "counter")
	check(cok, fmt.tprintf("counter module runs %s", ce))
	ei, eok, _ := page.load_module(hp, e2e, "e2e-second")
	check(eok && ci != ei && ci.index == 0 && ei.index == 1, "two instances live in one page")
	count := dom.find_by_id(hp.doc, "count")
	check(dom.text_content(hp.doc, count) == "0", "module initialised #count from the parsed HTML")
	press := dom.Event{type = "click", bubbles = true, cancelable = true}
	inc := dom.find_by_id(hp.doc, "inc")
	for _ in 0 ..< 5 { page.dispatch_event(hp, inc, press) }
	check(dom.text_content(hp.doc, count) == "5", "clicks reach the module that registered the listener")
	papp := dom.find_by_id(hp.doc, "app")
	page.dispatch_event(hp, papp, press)
	check(dom.text_content(hp.doc, papp) == "clicked 1" && dom.text_content(hp.doc, count) == "5", "each listener runs in its own instance")
	check(loop.timers.count >= 1, "the counter's interval timer is registered")
	for _ in 0 ..< 30 { host.loop_wait(&loop, 50) }
	check(dom.text_content(hp.doc, dom.find_by_id(hp.doc, "clock")) != "0", "interval timer ticked and updated the DOM")
	page.page_close(hp)
	check(loop.timers.count == 0 && fetch.in_flight(&loader) == 0, "everything of both modules was released")

	////////////////////////////////
	fmt.println("-- security headers and meta")
	sp := page.page_create(&loop, &loader, &settings, process, "https://example.test/", console)
	page.apply_response_headers(sp, {"default-src 'self'"}, {"img-src 'none'"}, "no-referrer")
	check(len(sp.env.policies.policies) == 2 && sp.env.referrer_policy == .No_Referrer, "response headers feed the environment")
	meta := "<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"connect-src 'self'\"><meta name=\"referrer\" content=\"origin\"><p>x"
	page.load_html(sp, transmute([]byte)meta)
	check(len(sp.env.policies.policies) == 3 && sp.env.referrer_policy == .Origin, "<meta> policies are applied")
	page.page_close(sp)

	base.scope_close(process)
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	host.loop_destroy(&loop)
	wasm.runtime_destroy()
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures)
}
