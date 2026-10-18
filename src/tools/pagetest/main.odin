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

	base.scope_close(process)
	net.client_destroy(&client)
	host.loop_destroy(&loop)
	wasm.runtime_destroy()
	_ = baseline_nodes
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures)
}
