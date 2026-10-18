// Headless end-to-end test of the page stack (needs build\testserver.exe running: tools\testserver).
//   pagetest.exe build\e2e.wasm
package pagetest

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
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

pump_until :: proc(loop: ^host.Loop, what: string, cond: proc() -> bool, seconds := 10.0) -> bool {
	start := time.tick_now()
	for !cond() {
		if time.duration_seconds(time.tick_since(start)) > seconds { fmt.printf("  timeout waiting for %s\n", what); return false }
		host.loop_wait(loop, 20)
	}
	return true
}

the_page: ^page.Page

attr :: proc(h: base.Handle, name: string) -> string {
	v, _ := dom.get_attribute(the_page.doc, h, name)
	return v
}

main :: proc() {
	image, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil { fmt.eprintln("cannot read module"); os.exit(2) }

	loop: host.Loop
	host.loop_init(&loop)
	client: net.Client
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }

	process := base.scope_make("process")
	p := page.page_create(&loop, &client, process, console)
	the_page = p
	baseline_nodes := p.doc.nodes.count

	ok, e := page.load_module(p, image, "e2e")
	check(ok, fmt.tprintf("module loads and wb_main runs %s", e))
	app := dom.find_by_id(p.doc, "app")
	check(app != base.NIL_HANDLE, "guest created #app in the DOM")
	check(dom.text_content(p.doc, app) == "ready", "text content set by the guest")

	// the page started 2 requests and 1 timer
	check(net.in_flight(&client) >= 1, "requests are in flight")
	check(loop.timers.count == 1, "one timer registered")

	pump_until(&loop, "timer and fetches", proc() -> bool {
		a := dom.find_by_id(the_page.doc, "app")
		return attr(a, "data-timer") == "fired" && attr(a, "data-fetched") != "" && attr(a, "data-error") != ""
	})
	check(attr(app, "data-timer") == "fired", "timer callback ran in the guest")
	check(attr(app, "data-fetched") == "49", "HTTP fetch delivered the body to the guest (49 bytes)")
	check(strings.contains(attr(app, "data-error"), "secure connection failed"), "self-signed HTTPS rejected, error reaches the guest")
	check(net.in_flight(&client) == 0, "no request left after completion")
	check(loop.timers.count == 0, "one-shot timer released after firing")
	check(p.fetches.count == 0, "guest released its fetch records")

	// events dispatched by the shell
	click := dom.Event{type = "click", bubbles = true, cancelable = true, x = 10, y = 10}
	check(page.dispatch_event(p, app, click), "click dispatched")
	check(dom.text_content(p.doc, app) == "clicked 1", "listener in the guest updated the DOM")
	click.x = 500
	check(!page.dispatch_event(p, app, click), "guest called preventDefault")
	check(dom.text_content(p.doc, app) == "clicked 2", "second click handled")
	check(p.dp.events.count == 0, "transient event objects freed")

	// resource churn
	before := p.doc.nodes.count
	wasm.call_raw(p.inst, "churn", {20000})
	check(p.doc.nodes.count == before, "20,000 create/release cycles leave the node count unchanged")
	r, res := wasm.call_i32(p.inst, "stale")
	check(res == .Ok && r == i32(dom.Error.Invalid_Handle), "stale handle rejected cleanly")
	res = wasm.call_raw(p.inst, "bad_pointer")
	check(res == .Trapped, "out-of-bounds pointer traps instead of reaching the host")
	r, res = wasm.call_i32(p.inst, "stale")
	check(res == .Ok, "instance still usable after the trap")

	// close with work still pending: start a slow fetch and a timer, then close the tab
	wasm.call_raw(p.inst, "wb_main")   // second run: 2 more requests + 1 timer
	check(net.in_flight(&client) > 0 && loop.timers.count > 0, "work in flight before close")
	page.page_close(p)
	check(net.in_flight(&client) == 0, "closing the page cancelled its requests")
	check(loop.timers.count == 0, "closing the page removed its timers")
	// late events must be harmless
	for _ in 0 ..< 10 { host.loop_wait(&loop, 20) }
	check(len(process.children) == 0, "page scope detached from its parent")

	// HTML document + the Wasm module it names (args: e2e.wasm index.html counter.wasm)
	if len(os.args) >= 4 {
		html_bytes, herr := os.read_entire_file(os.args[2], context.allocator)
		counter, cerr := os.read_entire_file(os.args[3], context.allocator)
		if herr != nil || cerr != nil { fmt.eprintln("cannot read html/counter"); os.exit(2) }
		hp := page.page_create(&loop, &client, process, console)
		the_page = hp
		r := page.load_html(hp, html_bytes)
		check(r.ok && r.nodes > 20, "HTML document parsed by Lexbor into the DOM")
		check(html.title(hp.doc) == "Wasm-first demo", "document title extracted")
		scripts := html.wasm_scripts(hp.doc)
		src, _ := dom.get_attribute(hp.doc, scripts[0] if len(scripts) > 0 else base.NIL_HANDLE, "src")
		check(len(scripts) == 1 && src == "counter.wasm", "the document names its Wasm module")
		ok2, e2 := page.load_module(hp, counter, "counter")
		check(ok2, fmt.tprintf("module named by the document runs %s", e2))
		count := dom.find_by_id(hp.doc, "count")
		check(dom.text_content(hp.doc, count) == "0", "module initialised #count from the parsed HTML")
		inc := dom.find_by_id(hp.doc, "inc")
		press := dom.Event{type = "click", bubbles = true, cancelable = true}
		for _ in 0 ..< 5 { page.dispatch_event(hp, inc, press) }
		check(dom.text_content(hp.doc, count) == "5", "5 clicks on a parsed <button> reach the module")
		dec := dom.find_by_id(hp.doc, "dec")
		page.dispatch_event(hp, dec, press)
		check(dom.text_content(hp.doc, count) == "4", "-1 button")
		// the interval timer is alive, then dies with the page
		check(loop.timers.count == 1, "the module's interval timer is registered")
		for _ in 0 ..< 30 { host.loop_wait(&loop, 50) }
		clock := dom.find_by_id(hp.doc, "clock")
		check(dom.text_content(hp.doc, clock) != "0", "interval timer ticked and updated the DOM")
		page.page_close(hp)
		check(loop.timers.count == 0, "interval timer removed with the page")
	}

	base.scope_close(process)
	net.client_destroy(&client)
	host.loop_destroy(&loop)
	wasm.runtime_destroy()
	_ = baseline_nodes
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures)
}
