// Headless end-to-end test of JavaScript in a page: the engine module instantiated as the page's realm, scripts of a
// parsed document, the bindings generated from the Web IDL, events, microtasks, the wrapper cache and the lifetime of
// nodes across the two heaps, the bytecode cache. No server needed. Run from the repository root:
//   jstest.exe
package jstest

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
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

// Runs the loop until nothing is left to do (no task posted, no timer set), at most `max_turns` turns: pages that keep
// timers forever (the hostile ones below) stop at the cap. Turns are counted, not milliseconds, so what is checked
// afterwards does not depend on the machine's speed. Returns the turns run.
settle :: proc(max_turns := 200) -> int {
	turns := 0
	for ; turns < max_turns; turns += 1 {
		next := host.next_timeout_ms(&loop)
		if next < 0 { break }
		host.loop_wait(&loop, next)
	}
	return turns
}

load :: proc(process: ^base.Scope, source: string, address := "http://127.0.0.1:8765/js.html") -> ^page.Page {
	clear(&logs)
	p := page.page_create(&loop, &loader, &settings, process, address, console)
	page.load_html(p, transmute([]byte)source)
	page.scripts_start(p)
	settle()
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

	fmt.println("-- the browser's own events reach JavaScript listeners")
	{
		p := load(process, `<!doctype html><body><button id=b>b</button><script>
let seen = null;
document.getElementById("b").addEventListener("click", e => {
  seen = e;
  console.log("click", e instanceof MouseEvent, e.isTrusted, e.type, e.target.id, e.bubbles, e.cancelable);
  e.preventDefault();
});
document.addEventListener("click", e => console.log("document saw", e === seen, e.eventPhase));
</script></body>`)
		b := dom.find_by_id(p.doc, "b")
		allowed := page.dispatch_event(p, b, dom.Event{type = "click", bubbles = true, cancelable = true, x = 3, y = 4})
		check(logged("click true true click b true true"), "a click from the browser is a trusted MouseEvent")
		check(logged("document saw true 3"), "the same wrapper bubbles up to the document")
		check(!allowed, "preventDefault from JavaScript cancels the browser's default action")
		page.js_run(p, transmute([]byte)string(`console.log("after", seen.type, seen.currentTarget, seen.eventPhase, seen.defaultPrevented)`), "probe.js")
		check(logged("after click null 0 true"), "a kept event keeps its state after the dispatch")
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
		check(after < 200, "unreferenced detached nodes are freed when their wrappers are collected")
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
		check(ms >= 100, fmt.tprintf("not stopped before javascript.slow_script_ms (%.0f ms)", ms))
		stopped := false
		for l in logs { if strings.contains(l, "slow_script_ms") { stopped = true } }
		check(stopped, "the console says a slow script was stopped")
		page.js_run(p, transmute([]byte)string(`console.log("still usable")`), "probe.js")
		check(logged("still usable"), "the realm is usable afterwards")
		page.page_close(p)
		settings = saved
	}

	fmt.println("-- PerformanceObserver")
	{
		p := load(process, `<!doctype html><body><script>
performance.mark("early");
var po = new PerformanceObserver((list, obs) => {
  console.log("po", list.getEntries().map(e => e.entryType + ":" + e.name).join(","), obs === po, list.getEntriesByType("mark").length, list.getEntriesByName("m2").length);
});
po.observe({ type: "mark", buffered: true });
po.observe({ type: "measure" });
new PerformanceObserver(() => {}).observe({ type: "paint" });
performance.mark("m2");
performance.measure("ms", "early", "m2");
console.log("types", PerformanceObserver.supportedEntryTypes.join(), PerformanceObserver.supportedEntryTypes === PerformanceObserver.supportedEntryTypes, Object.isFrozen(PerformanceObserver.supportedEntryTypes));
try { po.observe({ entryTypes: ["mark"] }); } catch (e) { console.log("mixed", e.name); }
try { po.observe({}); } catch (e) { console.log("empty", e.name); }
var p2 = new PerformanceObserver(() => console.log("p2 called"));
p2.observe({ entryTypes: ["mark"] });
performance.mark("m3");
console.log("take", p2.takeRecords().length);
p2.disconnect();
</script></body>`)
		settle()
		check(logged("types mark,measure true true"), "supportedEntryTypes: a frozen [SameObject] array of what the timeline records")
		check(logged("mixed InvalidModificationError") && logged("empty TypeError"), "observe(): the errors of Performance Timeline")
		check(logged("take 1") && !logged("p2 called"), "takeRecords empties the buffer, disconnect stops delivery")
		check(logged("po mark:early,measure:ms,mark:m2,mark:m3 true 3 1"), "buffered entries, then new marks and measures, delivered by one task in start time order")
		warned := false
		for l in logs { if strings.contains(l, "'paint' does not exist") { warned = true } }
		check(warned, "an unsupported entry type is ignored with a warning")
		page.page_close(p)
	}
	fmt.println("-- hostile scripts: the page survives, the browser stays responsive")
	{
		saved := settings
		settings.js.slow_script_ms = 300
		settings.js.max_heap_bytes = 64 << 20
		defer settings = saved
		usable :: proc(p: ^page.Page, what: string) {
			clear(&logs)
			page.js_run(p, transmute([]byte)string(`console.log("usable")`), "probe.js")
			check(logged("usable"), fmt.tprintf("%s: the realm is usable afterwards", what))
		}
		timed :: proc(process: ^base.Scope, source: string) -> (^page.Page, f64) {
			start := time.tick_now()
			p := load(process, source)
			return p, time.duration_milliseconds(time.tick_since(start))
		}

		p, ms := timed(process, `<!doctype html><body><script>
function f(n) { return f(n + 1) + 1; }
try { f(0) } catch (e) { console.log("recursion", e instanceof RangeError) }
</script></body>`)
		check(logged("recursion true"), "unbounded JavaScript recursion throws RangeError")
		usable(p, "recursion")
		page.page_close(p)

		p, ms = timed(process, `<!doctype html><body><div id=a></div><script>
const a = document.getElementById("a");
let depth = 0;
a.addEventListener("x", () => { depth++; a.dispatchEvent(new Event("x")); });
try { a.dispatchEvent(new Event("x")); console.log("returned", depth) } catch (e) { console.log("host recursion", e.name, depth > 10) }
</script></body>`)
		host_rec := false
		for l in logs { if strings.has_prefix(l, "host recursion") || strings.has_prefix(l, "returned") { host_rec = true } }
		check(host_rec, "recursion through the browser (dispatchEvent from a listener) ends without a crash")
		usable(p, "recursion through the browser")
		page.page_close(p)

		p, ms = timed(process, `<!doctype html><body><script>
const keep = [];
try { for (;;) keep.push(new Array(1 << 16).fill(1.5)); } catch (e) { console.log("oom", e.name || String(e)) }
keep.length = 0;
try { "x".repeat(1 << 30); } catch (e) { console.log("huge string", e.name) }
</script></body>`)
		oom := false
		for l in logs { if strings.has_prefix(l, "oom") { oom = true } }
		check(oom, "allocating past javascript.max_heap_bytes throws, the script can catch it")
		check(logged("huge string RangeError") || logged("huge string InternalError"), "a 1 GiB string is refused")
		usable(p, "out of memory")
		page.page_close(p)

		p, ms = timed(process, `<!doctype html><body><script>
function m() { Promise.resolve().then(m); }
m();
</script><script>console.log("after microtasks")</script></body>`)
		check(logged("after microtasks"), "an endless microtask chain is stopped, the next script runs")
		usable(p, "microtask chain")
		restarted := false
		for l in logs { if strings.contains(l, "slow_script_ms") { restarted = true } }
		check(!restarted, "the stopped microtask chain does not start again at the next checkpoint")
		page.page_close(p)

		p, ms = timed(process, `<!doctype html><body><script>
let n = 0;
function t() { n++; setTimeout(t, 0); setTimeout(t, 0); }
t();
</script></body>`)
		// load() ran its turns under the flood (each one ends: the loop's time slice, host tests); a task the shell posts
		// meanwhile (input, painting) runs at the very next turn
		posted := false
		host.post(&loop, proc(data: rawptr) { (^bool)(data)^ = true }, &posted)
		host.loop_wait(&loop, 0)
		check(posted, "timers doubling at every run: a task posted meanwhile runs at the next turn")
		clear(&logs)
		page.js_run(p, transmute([]byte)string(`console.log("flood", n >= 100)`), "probe.js")
		check(logged("flood true"), "the timers did run in those turns")
		usable(p, "timer flood")
		page.page_close(p)

		p, ms = timed(process, `<!doctype html><body><script>
const w = s => document.write(s);
w("<script>w('<script>w(\"<b>deep</b>\")<\/script>')<\/script>");
let k = 0;
function nest() { k++; document.write("<script>nest()<\/script>"); }
nest();
console.log("nested writes", k < 1000);
try { for (let i = 0; i < 1e7; i++) document.write("xxxxxxxxxxxxxxxx"); } catch (e) { console.log("write flood", e.name) }
</script><script>console.log("after writes")</script></body>`)
		check(logged("nested writes true"), "document.write nested without end is cut at javascript.document_write.max_depth")
		check(logged("after writes"), "a document.write flood ends (javascript.document_write.max_bytes or the time limit)")
		usable(p, "document.write")
		page.page_close(p)

		p, ms = timed(process, `<!doctype html><body><div id=t></div><script>
const t = document.getElementById("t");
let calls = 0;
new MutationObserver(() => { calls++; t.setAttribute("n", calls); }).observe(t, { attributes: true });
t.setAttribute("n", 0);
</script></body>`)
		fed_back := false
		for l in logs { if strings.contains(l, "slow_script_ms") { fed_back = true } }
		check(fed_back, "a MutationObserver that mutates what it observes is stopped like a slow script")
		check(settle() < 200, "and leaves nothing running")
		usable(p, "observer feedback")
		page.page_close(p)

		settings.js.slow_script_ms = 20_000
		p, ms = timed(process, `<!doctype html><body><script>
let n = document.createElement("div");
const root = n;
for (let i = 0; i < 20000; i++) { const c = document.createElement("div"); n.appendChild(c); n = c; }
n.textContent = "leaf";
document.body.appendChild(root);
const html = root.outerHTML;
const copy = root.cloneNode(true);
console.log("deep", html.length > 200000, copy.textContent, root.contains(n), document.querySelectorAll("div").length,
  n.compareDocumentPosition(root) & Node.DOCUMENT_POSITION_CONTAINS ? "contains" : "no", n.closest("body") === document.body);
root.remove();
const holder = document.createElement("div");
holder.innerHTML = "<div>".repeat(50000) + "x";
console.log("deep markup", holder.textContent);
</script></body>`)
		check(logged("deep true leaf true 20001 contains true"), "20 000 nested elements: serialization, clone, contains, selectors, position, closest")
		check(logged("deep markup x"), "50 000 nested elements from innerHTML")
		usable(p, "deep tree")
		page.page_close(p)
		settings.js.slow_script_ms = 300

		p, ms = timed(process, `<!doctype html><body><p id=old>old</p><script>
var old = document.getElementById("old"), body = document.body;
document.open();   // the parser is running this script: does nothing (HTML)
console.log("open in a parser script", old.isConnected);
</script></body>`)
		check(logged("open in a parser script true"), "document.open from a script the parser runs does nothing")
		clear(&logs)
		page.js_run(p, transmute([]byte)string(`
document.open();
document.write("<body><p id=n>new</p></body>");
document.close();
console.log("after open", old.id, old.isConnected, old.textContent, body.isConnected, document.getElementById("n").textContent, old === document.getElementById("n"));
const p = document.getElementById("n");
const kept = p.firstChild;
p.innerHTML = "<i>x</i>";
console.log("replaced child", kept.data, kept.parentNode);
p.textContent = "";
console.log("cleared", p.childNodes.length);
`), "open.js")
		check(logged("after open old false old false new false"), "nodes kept by JavaScript survive document.open, and are not confused with new nodes")
		check(logged("replaced child new null"), "a child replaced by innerHTML stays usable from JavaScript")
		check(logged("cleared 0"), "textContent = '' empties")
		usable(p, "document.open")
		page.page_close(p)

		p, ms = timed(process, `<!doctype html><body><script>
for (let i = 0; i < 20000; i++) {
  const d = document.createElement("div");
  d.self = d;
  d.box = { node: d };
  d.addEventListener("click", () => d.textContent);
  d.appendChild(document.createElement("span")).owner = d;
}
</script></body>`)
		before := live_nodes(p)
		js.collect(p.js.inst)
		after := live_nodes(p)
		fmt.printf("  nodes before collection %d, after %d\n", before, after)
		check(after < 200, "detached nodes in cycles with their wrappers (expandos, listener closures, children) are freed")
		page.page_close(p)
	}

	fmt.println("-- the engine's C code against scripts that run in the middle of it")
	{
		p := load(process, `<!doctype html><body><form><input id=i onclick="console.log('stale handler ran')"></form><script>
// settling a read reads the result's then: a getter releasing the lock (the stream's last reference) mid-read
(async () => {
  let reader = new Blob(["abc"]).stream().getReader(), hits = 0;
  Object.defineProperty(Object.prototype, "then", {configurable: true, get() { if (reader && "done" in this) { hits++; const r = reader; reader = null; r.releaseLock(); } return undefined; }});
  const pr = reader.read();
  delete Object.prototype.then;
  const res = await pr;
  console.log("stream then", hits, res.done, res.value.length);
})();
// structured clone of a value nested deeper than the C stack allows: an exception, not a crash
let deep = []; for (let k = 0; k < 100000; k++) deep = [deep];
try { structuredClone(deep); console.log("deep clone no error"); } catch (e) { console.log("deep clone", e.name); }
// a rejected promise whose reason is a rejected promise, deeply: the console stops at its depth
let pr = Promise.reject(0); pr.catch(() => {});
for (let k = 0; k < 20000; k++) { pr = Promise.reject(pr); pr.catch(() => {}); }
console.log(pr);
console.log("deep promise logged");
// a listener removed then another added (its memory may be reused): the signal removes only the first
{
  const ac = new AbortController(), t = document.createElement("div"), f = () => {}; let n = 0;
  t.addEventListener("x", f, {signal: ac.signal}); t.removeEventListener("x", f);
  t.addEventListener("x", () => n++);
  ac.abort(); t.dispatchEvent(new Event("x"));
  console.log("abort follower", n);
}
// passive listeners cannot cancel; the signal's own state decides, not its aborted getter
{
  const t = document.createElement("div"); let inside = null;
  t.addEventListener("x", e => { e.preventDefault(); inside = e.defaultPrevented; }, {passive: true});
  const ev = new Event("x", {cancelable: true});
  console.log("passive", t.dispatchEvent(ev), inside, ev.defaultPrevented);
  const d = Object.getOwnPropertyDescriptor(AbortSignal.prototype, "aborted");
  Object.defineProperty(AbortSignal.prototype, "aborted", {configurable: true, get() { throw new Error("getter"); }});
  let n = 0, threw = false;
  try { t.addEventListener("y", () => n++, {signal: new AbortController().signal}); } catch (e) { threw = true; }
  Object.defineProperty(AbortSignal.prototype, "aborted", d);
  t.dispatchEvent(new Event("y"));
  console.log("signal state", threw, n);
}
// a content attribute handler cleared by the form getter while it compiles stays cleared
{
  const i = document.getElementById("i");
  const d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "form");
  Object.defineProperty(HTMLInputElement.prototype, "form", {configurable: true, get() { i.onclick = null; return null; }});
  const h = i.onclick;
  Object.defineProperty(HTMLInputElement.prototype, "form", d);
  console.log("handler cleared", h, i.onclick);
  i.click();
}
// arrays the engine builds get their elements defined: an indexed accessor on Array.prototype never runs
{
  let ran = 0;
  Object.defineProperty(Array.prototype, 0, {configurable: true, get() { return "hijacked"; }, set(v) { ran++; }});
  let path = null;
  document.body.addEventListener("z", e => { path = e.composedPath(); });
  document.body.dispatchEvent(new Event("z"));
  const any = AbortSignal.any([new AbortController().signal]);
  delete Array.prototype[0];
  console.log("own elements", ran, Object.hasOwn(path, 0), path[0] === document.body, any instanceof AbortSignal);
}
// an index of a collection cannot be deleted; anything else can
{
  const nl = document.body.childNodes;
  console.log("delete index", delete nl[0], 0 in nl, delete nl[999], delete nl.foo);
}
// the rejection tracker and module evaluation use the engine's own WeakSet methods and then
WeakSet.prototype.has = function () { console.log("patched has ran"); return false; };
const thenOrig = Promise.prototype.then;
Promise.prototype.then = function (...a) { console.log("patched then ran"); return thenOrig.apply(this, a); };
const late = Promise.reject(new Error("late"));
setTimeout(() => setTimeout(() => { thenOrig.call(late, undefined, () => {}); console.log("late handled"); }), 0);
</script><script type=module>
await new Promise(r => setTimeout(r, 0));
console.log("module done");
</script></body>`)
		check(logged("stream then 1 false 3"), "a read settled while a then getter releases the stream's last reference")
		check(logged("deep clone RangeError"), "a structured clone deeper than the C stack throws a RangeError")
		check(logged("deep promise logged"), "console.log of deeply nested promises stops at its depth")
		check(logged("abort follower 1"), "an aborted signal removes its own listener, not a later one")
		check(logged("passive true false false"), "preventDefault in a passive listener does nothing")
		check(logged("signal state false 1"), "addEventListener reads the signal's state, not its aborted getter")
		check(logged("handler cleared null null") && !logged("stale handler ran"), "a handler cleared while it compiles is not brought back")
		check(logged("own elements 0 true true true"), "engine-built arrays define their elements (AbortSignal.any, composedPath)")
		check(logged("delete index false true true true"), "an existing index of a collection cannot be deleted")
		check(logged("late handled") && logged("module done"), "the late handler and the module ran")
		check(!logged("patched has ran") && !logged("patched then ran"), "scripts' WeakSet.prototype.has and Promise.prototype.then are not called by the engine")
		page.page_close(p)
	}

	fmt.println("-- a wrapper collected while its node lives on: its listeners leave the browser too")
	{
		p := load(process, `<!doctype html><body><script>
window.list = (() => {
  const d = document.createElement("div"), s = d.appendChild(document.createElement("span"));
  s.addEventListener("x", () => console.log("old listener"));
  return d.querySelectorAll("span");
})();
</script></body>`)
		js.collect(p.js.inst)
		js.collect(p.js.inst)
		page.js_run(p, transmute([]byte)string(`
window.hits = 0;
for (let k = 0; k < 20; k++) { const o = document.createElement("p"); o.addEventListener("y", () => hits++); (window.keepAlive ??= []).push(o); }
list[0].dispatchEvent(new Event("x"));
console.log("other listeners hit", hits);`), "probe.js")
		check(logged("other listeners hit 0"), "an event at a node whose wrapper died never calls a listener of another target")
		page.page_close(p)
	}

	fmt.println("-- cost of a call across the boundary (ns per call, informational)")
	{
		p := load(process, `<!doctype html><body><div id=a title=t><span></span></div><script>
const a = document.getElementById("a"), N = 1000000;
function bench(name, f) {
  f(1000);
  const t0 = performance_now();
  f(N);
  const ns = (performance_now() - t0) * 1e6 / N;
  console.log("BENCH " + name + " " + ns.toFixed(1));
}
function performance_now() { return Date.now(); }
const o = {x: 1};
bench("empty loop", n => { for (let i = 0; i < n; i++) {} });
bench("JS property get", n => { let s = 0; for (let i = 0; i < n; i++) s += o.x; });
const ev = new Event("x");
bench("constant on the prototype chain (Node.ELEMENT_NODE via a)", n => { let s = 0; for (let i = 0; i < n; i++) s += a.ELEMENT_NODE; });
bench("C getter, no browser call (event.bubbles)", n => { let s = 0; for (let i = 0; i < n; i++) s += ev.bubbles; });
bench("nodeType (getter, import)", n => { let s = 0; for (let i = 0; i < n; i++) s += a.nodeType; });
bench("firstChild (getter, wrapper cache)", n => { let s; for (let i = 0; i < n; i++) s = a.firstChild; });
bench("title (reflected attribute)", n => { let s; for (let i = 0; i < n; i++) s = a.title; });
bench("getAttribute('title')", n => { let s; for (let i = 0; i < n; i++) s = a.getAttribute("title"); });
bench("document.body", n => { let s; for (let i = 0; i < n; i++) s = document.body; });
</script></body>`)
		for l in logs { if strings.has_prefix(l, "BENCH ") { fmt.printf("  %s ns\n", l[6:]) } }
		page.page_close(p)
	}

	base.scope_close(process)
	js.cache_stop()
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures > 0 ? 1 : 0)
}
