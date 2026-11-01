#+private file
// The page stack with Wasm guests and no script: the DOM, events, timers, several modules per document, fetch through the policy layer,
// microtasks and promises, buffers, cookies, origin, closing with work in flight, and the policies of response headers and <meta>.
package webtests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:cookies"
import "wb:dom"
import "wb:fetch"
import "wb:html"
import "wb:net"
import "wb:page"
import "wb:tools/testenv"
import "wb:wasm"

E2E_WASM :: "build/e2e.wasm"
COUNTER_HTML :: "examples/site/counter.html"
COUNTER_WASM :: "examples/site/counter.wasm"
ADDRESS :: "http://127.0.0.1:8765/page.html"
COUNTER_ADDRESS :: "http://127.0.0.1:8765/site/counter.html"
FILE_ADDRESS :: "file:///S:/wasm_browser/build/x.html"
SECURE_ADDRESS :: "https://example.test/"
ROOT_BODY_BYTES :: "49"            // what the test server answers at /
FAR_CLICK_X :: 500                 // past 100: the guest calls preventDefault
CHURN_CYCLES :: 20000
COUNTER_CLICKS :: 5
MIN_COUNTER_NODES :: 20
POLICIES_OF_HEADERS :: 2
POLICIES_WITH_META :: 3

read :: proc(t: ^testing.T, path: string) -> []byte {
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expectf(t, err == nil, "cannot read %s", path)
	return data
}

// A page running the e2e guest (its first check). When that fails it is closed already.
open :: proc(t: ^testing.T, name, address: string) -> (pr: ^Probe, inst: ^wasm.Instance, ok: bool) {
	pr = page_make(t, name, testenv.url(address))
	loaded: bool
	e: string
	inst, loaded, e = page.load_module(pr.p, read(t, E2E_WASM), name)
	check(pr, loaded, fmt.tprintf("module loads and wb_main runs %s", e))
	if !loaded { close_page(pr); return nil, nil, false }
	return pr, inst, true
}

attr :: proc(p: ^page.Page, h: base.Handle, name: string) -> string {
	v, _ := dom.get_attribute(p.doc, h, name)
	return v
}

Wait_Attrs :: struct { p: ^page.Page, names: []string }

// Until #app has all these attributes.
wait_attrs :: proc(pr: ^Probe, names: ..string) -> bool {
	return wait_until(pr.t, fmt.tprint(names), Wait_Attrs{pr.p, names}, proc(w: Wait_Attrs) -> bool {
		a := dom.find_by_id(w.p.doc, "app")
		for n in w.names { if attr(w.p, a, n) == "" { return false } }
		return true
	})
}

@(test)
page_one_module_dom_events_timers_fetch :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	timers := loop.timers.count
	pr, inst, ok := open(t, "one module", ADDRESS)
	if !ok { return }
	p := pr.p
	check(pr, !p.env.origin.opaque && p.env.secure_context, "http://127.0.0.1 is a secure context with a tuple origin")
	app := dom.find_by_id(p.doc, "app")
	check(pr, app != base.NIL_HANDLE, "guest created #app in the DOM")
	check(pr, dom.text_content(p.doc, app) == "ready", "text content set by the guest")
	check(pr, fetch.in_flight(&loader) >= 1, "requests are in flight")
	check(pr, loop.timers.count == timers + 1, "one timer registered")

	wait_attrs(pr, "data-timer", "data-fetched", "data-error")
	check(pr, attr(p, app, "data-timer") == "fired", "timer callback ran in the guest")
	check(pr, attr(p, app, "data-fetched") == ROOT_BODY_BYTES, "same-origin fetch delivered the body to the guest (49 bytes)")
	check(pr, attr(p, app, "data-type") == "basic", "same-origin response type is basic")
	check(pr, strings.contains(attr(p, app, "data-error"), "secure connection failed"), "self-signed HTTPS rejected, error reaches the guest")
	check(pr, fetch.in_flight(&loader) == 0, "no task left after completion")
	check(pr, loop.timers.count == timers, "one-shot timer released after firing")
	check(pr, p.fetches.count == 0 && p.held == 0, "guest released its fetch records")

	click := dom.Event{type = "click", bubbles = true, cancelable = true, x = 10, y = 10}
	check(pr, page.dispatch_event(p, app, click), "click dispatched")
	check(pr, dom.text_content(p.doc, app) == "clicked 1", "listener in the guest updated the DOM")
	click.x = FAR_CLICK_X
	check(pr, !page.dispatch_event(p, app, click), "guest called preventDefault")
	check(pr, p.dp.events.count == 0, "transient event objects freed")

	before := p.doc.nodes.count
	wasm.call_raw(inst, "churn", {CHURN_CYCLES})
	check(pr, p.doc.nodes.count == before, "20,000 create/release cycles leave the node count unchanged")
	r, res := wasm.call_i32(inst, "stale")
	check(pr, res == .Ok && r == i32(dom.Error.Invalid_Handle), "stale handle rejected cleanly")
	res = wasm.call_raw(inst, "bad_pointer")
	check(pr, res == .Trapped, "out-of-bounds pointer traps instead of reaching the host")
	r, res = wasm.call_i32(inst, "stale")
	check(pr, res == .Ok, "instance still usable after the trap")
	close_page(pr, min_checks = 21)
}

@(test)
page_microtasks_promises_buffers :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr, inst, ok := open(t, "microtasks", ADDRESS)
	if !ok { return }
	p := pr.p
	app := dom.find_by_id(p.doc, "app")
	wait_attrs(pr, "data-fetched", "data-error")   // what wb_main started holds page memory until it ends
	page.call_export(p, inst, "async_probe")
	wait_attrs(pr, "data-async")
	check(pr, attr(p, app, "data-async") == "sync m1 m2 ok42 ko-7 m3 all-ok ", fmt.tprintf("microtask and promise ordering (got %q)", attr(p, app, "data-async")))
	check(pr, len(p.objects.microtasks) == 0, "microtask queue drained")
	b, bres := wasm.call_i32(inst, "buffer_probe")
	check(pr, bres == .Ok && b == 1, fmt.tprintf("buffers: create, slice, read, write, release (%d)", b))
	check(pr, p.held == 0, "buffer memory returned to the page budget")
	close_page(pr, min_checks = 5)
}

@(test)
page_origin_cookies_cors_from_the_guest :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	cookies.clear_all(&profile.jar)
	defer cookies.clear_all(&profile.jar)
	pr, inst, ok := open(t, "origin", ADDRESS)
	if !ok { return }
	p := pr.p
	app := dom.find_by_id(p.doc, "app")
	n, res := wasm.call_i32(inst, "cookie_probe")
	check(pr, res == .Ok && n == len("probe=1"), "document.cookie set and read by the guest")
	check(pr, cookies.count(&profile.jar) == 1, "the cookie lives in the profile's jar")
	o, _ := wasm.call_i32(inst, "origin_probe")
	check(pr, int(o) == len(testenv.url("http://127.0.0.1:8765")), "the guest can read its own origin")

	wasm.call_raw(inst, "start_cors_probe", {0})
	wait_attrs(pr, "data-cors")
	check(pr, attr(p, app, "data-cors") == fmt.tprintf("%d", int(fetch.Error_Kind.Blocked_Cors)), "a cross-origin fetch without CORS is refused with Blocked_Cors")
	dom.remove_attribute(p.doc, app, "data-cors")
	wasm.call_raw(inst, "start_cors_probe", {1})
	wait_attrs(pr, "data-cors")
	check(pr, attr(p, app, "data-cors") == "allowed", "a CORS-enabled cross-origin fetch succeeds")
	close_page(pr, min_checks = 6)

	fpr, finst, fok := open(t, "file document", FILE_ADDRESS)
	if !fok { return }
	fn, _ := wasm.call_i32(finst, "cookie_probe")
	check(fpr, fn == -1, "a file: document gets a SecurityError for cookies")
	fo, _ := wasm.call_i32(finst, "origin_probe")
	check(fpr, fo == len("null"), "a file: document's origin is \"null\"")
	close_page(fpr, min_checks = 3)
}

Children :: struct { want: int }

@(test)
page_closing_with_work_in_flight :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	timers := loop.timers.count
	children := len(process.children)
	pr, inst, ok := open(t, "closing", ADDRESS)
	if !ok { return }
	wasm.call_raw(inst, "wb_main")   // a second run: more requests and a timer
	check(pr, fetch.in_flight(&loader) > 0 && loop.timers.count > timers, "work in flight before close")
	close_page(pr, min_checks = 2)
	testing.expect(t, fetch.in_flight(&loader) == 0 && net.in_flight(&client) == 0, "closing the page cancelled its requests")
	testing.expect_value(t, loop.timers.count, timers)
	testing.expect(t, wait_until(t, "the page's scope to leave", Children{children}, proc(c: Children) -> bool { return len(process.children) == c.want }), "page scope detached from its parent")
}

// The second module is e2e itself: both instances share the DOM, and their table indices collide on purpose.
@(test)
page_an_html_document_with_two_modules :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	timers := loop.timers.count
	pr := page_make(t, "two modules", testenv.url(COUNTER_ADDRESS))
	p := pr.p
	decoded, _ := html.decode_document(read(t, COUNTER_HTML), "utf-8", settings.html.default_encoding)
	defer delete(decoded.text)
	rr := page.load_html(p, decoded.text)
	check(pr, rr.ok && rr.nodes > MIN_COUNTER_NODES, "HTML document parsed by Lexbor into the DOM")
	check(pr, html.title(p.doc) == "Wasm-first demo", "document title extracted")
	scripts := html.wasm_scripts(p.doc, settings.html.module_script_type)
	src, _ := dom.get_attribute(p.doc, scripts[0] if len(scripts) > 0 else base.NIL_HANDLE, "src")
	check(pr, len(scripts) == 1 && src == "counter.wasm", "the document names its Wasm module")

	ci, cok, ce := page.load_module(p, read(t, COUNTER_WASM), "counter")
	check(pr, cok, fmt.tprintf("counter module runs %s", ce))
	ei, eok, _ := page.load_module(p, read(t, E2E_WASM), "e2e-second")
	check(pr, eok && ci != ei && ci.index == 0 && ei.index == 1, "two instances live in one page")
	if !cok || !eok { close_page(pr); return }
	count := dom.find_by_id(p.doc, "count")
	check(pr, dom.text_content(p.doc, count) == "0", "module initialised #count from the parsed HTML")
	press := dom.Event{type = "click", bubbles = true, cancelable = true}
	inc := dom.find_by_id(p.doc, "inc")
	for _ in 0 ..< COUNTER_CLICKS { page.dispatch_event(p, inc, press) }
	check(pr, dom.text_content(p.doc, count) == "5", "clicks reach the module that registered the listener")
	app := dom.find_by_id(p.doc, "app")
	page.dispatch_event(p, app, press)
	check(pr, dom.text_content(p.doc, app) == "clicked 1" && dom.text_content(p.doc, count) == "5", "each listener runs in its own instance")
	check(pr, loop.timers.count >= timers + 1, "the counter's interval timer is registered")
	ticked := wait_until(t, "the counter's clock", p, proc(p: ^page.Page) -> bool { return dom.text_content(p.doc, dom.find_by_id(p.doc, "clock")) != "0" })
	check(pr, ticked, "interval timer ticked and updated the DOM")
	close_page(pr, min_checks = 10)
	testing.expect(t, loop.timers.count == timers && fetch.in_flight(&loader) == 0, "everything of both modules was released")
}

META :: "<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"connect-src 'self'\"><meta name=\"referrer\" content=\"origin\"><p>x"

@(test)
page_security_headers_and_meta :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := page_make(t, "security", SECURE_ADDRESS)
	p := pr.p
	page.apply_response_headers(p, {"default-src 'self'"}, {"img-src 'none'"}, "no-referrer")
	check(pr, len(p.env.policies.policies) == POLICIES_OF_HEADERS && p.env.referrer_policy == .No_Referrer, "response headers feed the environment")
	page.load_html(p, transmute([]byte)string(META))
	check(pr, len(p.env.policies.policies) == POLICIES_WITH_META && p.env.referrer_policy == .Origin, "<meta> policies are applied")
	close_page(pr, min_checks = 2)
}
