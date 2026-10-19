// Headless end-to-end test of JavaScript in a page: the engine module instantiated as the page's realm, scripts of a
// parsed document, the bindings generated from the Web IDL, events, microtasks, the wrapper cache and the lifetime of
// nodes across the two heaps, the bytecode cache. No server needed. Run from the repository root:
//   jstest.exe
package jstest

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:js"
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

logged :: proc(text: string) -> bool {
	for l in logs { if l == text { return true } }
	return false
}

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings

pump :: proc(ms: int) {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < f64(ms) { host.loop_wait(&loop, 5) }
}

load :: proc(process: ^base.Scope, source: string, address := "http://127.0.0.1:8765/js.html") -> ^page.Page {
	clear(&logs)
	p := page.page_create(&loop, &loader, &settings, process, address, console)
	page.load_html(p, transmute([]byte)source)
	page.scripts_start(p)
	pump(30)
	return p
}

live_nodes :: proc(p: ^page.Page) -> int { return p.doc.nodes.count }

main :: proc() {
	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	wasm.configure_from_args(os.args[1:])
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }
	js.cache_start({memory_bytes = 16 << 20, min_source_bytes = 0})
	process := base.scope_make("process")

	fmt.println("-- a realm runs the scripts of a document, in order")
	{
		p := load(process, `<!doctype html><title>t</title><body>
<script>console.log("first", typeof window, typeof document, self === window)</script>
<p id=x>hello</p>
<script>console.log("second", document.getElementById("x").textContent)</script>
<script>Promise.resolve().then(() => console.log("microtask")); console.log("sync")</script>
</body>`)
		check(logged("first object object true"), "the global object, window and self")
		check(logged("second hello"), "getElementById and textContent from the browser's DOM")
		check(len(logs) >= 4 && logs[len(logs) - 2] == "sync" && logs[len(logs) - 1] == "microtask", "promise reactions run at the microtask checkpoint after the script")
		page.page_close(p)
	}

	fmt.println("-- DOM bindings: tree, attributes, wrappers")
	{
		p := load(process, `<!doctype html><body><div id=a class=c></div><script>
const a = document.getElementById("a");
console.log(a === document.getElementById("a"), a instanceof HTMLDivElement, a instanceof Element, a instanceof Node, a instanceof EventTarget);
console.log(Object.prototype.toString.call(a), a.tagName, a.getAttribute("class"), a.getAttribute("nope"));
const s = document.createElement("span");
s.textContent = "made";
console.log(s.parentNode, a.appendChild(s) === s, s.parentNode === a, a.firstChild === s, a.textContent);
a.setAttribute("data-x", "1");
console.log(a.getAttribute("data-x"), document.body.lastChild.nodeType, document.documentElement.tagName);
try { a.appendChild(a); } catch (e) { console.log("caught", e.name); }
try { Node.prototype.appendChild.call({}, s); } catch (e) { console.log("illegal", e instanceof TypeError); }
try { new Node(); } catch (e) { console.log("illegal ctor", e instanceof TypeError); }
</script></body>`)
		check(logged("true true true true true"), "one wrapper per node, prototype chain from the IDL")
		check(logged("[object HTMLDivElement] DIV c null"), "toStringTag, getters (tagName upper case in an HTML document), null for a missing attribute")
		check(logged("null true true true made"), "appendChild returns its argument; the tree is the browser's")
		check(logged("1 1 HTML"), "attributes, nodeType, documentElement")
		check(logged("caught HierarchyRequestError"), "browser errors become DOMException names")
		check(logged("illegal true"), "wrong this: TypeError")
		check(logged("illegal ctor true"), "Node is not constructible")
		page.page_close(p)
	}

	fmt.println("-- events: listeners, the same Event object, handlers, propagation")
	{
		p := load(process, `<!doctype html><body><div id=outer><button id=b>b</button></div><script>
const b = document.getElementById("b"), outer = document.getElementById("outer");
const ev = new CustomEvent("ping", {bubbles: true, cancelable: true, detail: 42});
let order = [];
outer.addEventListener("ping", e => order.push("outer-capture"), true);
outer.addEventListener("ping", e => order.push("outer-bubble " + (e === ev) + " " + (e.currentTarget === outer)));
b.addEventListener("ping", function (e) { order.push("target " + (this === b) + " " + e.detail + " " + e.eventPhase); e.preventDefault(); });
const once = () => order.push("once");
b.addEventListener("ping", once, {once: true});
const r = b.dispatchEvent(ev);
b.dispatchEvent(new Event("ping", {bubbles: true}));
console.log(order.join("|"), r, ev.defaultPrevented, ev.target === b, ev.currentTarget, ev.isTrusted);
b.onclick = () => console.log("onclick");
console.log(typeof b.onclick, b.onclick !== null);
b.dispatchEvent(new Event("click"));
b.onclick = null;
b.dispatchEvent(new Event("click"));
console.log("handlers done");
</script></body>`)
		check(logged("outer-capture|target true 42 2|once|outer-bubble true true|outer-capture|target true undefined 2|outer-bubble false true false true true null false"), "capture, target, bubble order; once; the dispatched object is the listener's; preventDefault")
		check(logged("function true"), "event handler attribute getter")
		check(logged("onclick") && logged("handlers done"), "event handler runs, removed with null")
		page.page_close(p)
	}

	fmt.println("-- wrappers and nodes: the two heaps free each other")
	{
		p := load(process, `<!doctype html><body><script>
for (let i = 0; i < 20000; i++) { const d = document.createElement("div"); d.textContent = "x"; }
const keep = document.createElement("section");
keep.appendChild(document.createElement("i")).id = "inner";
window.kept = keep;
document.body.appendChild(document.createElement("p")).id = "connected";
document.body.lastChild.addEventListener("x", () => console.log("listener kept"));
</script></body>`)
		before := live_nodes(p)
		js.collect(p.js.inst)
		after := live_nodes(p)
		fmt.printf("  nodes before collection %d, after %d\n", before, after)
		check(before > 20000 && after < 200, "unreferenced detached nodes are freed when their wrappers are collected")
		page.js_run(p, transmute([]byte)string(`console.log(kept.firstChild.id, kept.firstChild.parentNode === kept); document.getElementById("connected").dispatchEvent(new Event("x"))`), "probe.js")
		check(logged("inner true"), "a detached tree referenced from JavaScript stays whole")
		check(logged("listener kept"), "the wrapper of a connected node keeps its listeners without any JS reference")
		page.page_close(p)
	}

	fmt.println("-- bytecode cache")
	{
		src := `<!doctype html><body><script>console.log("cached run", 6 * 7)</script></body>`
		p1 := load(process, src)
		page.page_close(p1)
		st0 := js.cache_stats()
		p2 := load(process, src)
		st1 := js.cache_stats()
		check(logged("cached run 42"), "the script runs again")
		check(st1.memory_hits > st0.memory_hits, "the second page runs it from the bytecode cache")
		page.page_close(p2)
	}

	fmt.println("-- interruption of a script that loops")
	{
		s := settings
		s.js.slow_script_ms = 200
		saved := settings
		settings = s
		start := time.tick_now()
		p := load(process, `<!doctype html><body><script>console.log("before"); for (;;) {}</script><script>console.log("after")</script></body>`)
		ms := time.duration_milliseconds(time.tick_since(start))
		check(logged("before") && logged("after"), "the loop is stopped, the next script runs")
		check(ms < 2000, fmt.tprintf("stopped near javascript.slow_script_ms (%.0f ms)", ms))
		stopped := false
		for l in logs { if strings.contains(l, "slow_script_ms") { stopped = true } }
		check(stopped, "the console says a slow script was stopped")
		page.js_run(p, transmute([]byte)string(`console.log("still usable")`), "probe.js")
		check(logged("still usable"), "the realm is usable afterwards")
		page.page_close(p)
		settings = saved
	}

	base.scope_close(process)
	js.cache_stop()
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures > 0 ? 1 : 0)
}
