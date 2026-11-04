#+build windows
#+private file
// JavaScript in a page: the engine module instantiated as the page's realm, scripts of a parsed document, the bindings generated from
// the Web IDL, events, microtasks, the wrapper cache and the lifetime of nodes across the two heaps, the bytecode cache, interruption,
// hostile scripts. No server. A page reports with `is(want, what, ...got)`, a wrenTest.check of what console.log would have printed,
// or a note; only what the console itself is about (the developer tools, what a stopped script says) is read from the console.
package e2e_scenarios

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:js"
import "wb:page"
import "wb:tools/testhost"

ADDRESS :: "http://127.0.0.1:8765/js.html"
SETTLE_TURNS :: 200                  // pages that keep timers forever (the hostile ones) stop there; turns, not milliseconds: what is checked does not depend on the machine's speed
SETTLE_FARTHEST_MS :: 100            // a timer further than this is not one of these pages' (they have 0 ms ones): something else in the process's
FEW_NODES :: 200                     // what a page keeps once its detached nodes have gone
DEV_CONSOLE_BYTES :: 65536
SLOW_SCRIPT_MS :: 200
NOT_STOPPED_BEFORE_MS :: 100.0       // real time: the limit is on a real clock, and a loop of the engine has no other
HOSTILE_SLOW_SCRIPT_MS :: 300
HOSTILE_HEAP_BYTES :: 64 << 20
FILLING_THE_HEAP_SLOW_SCRIPT_MS :: 60_000
DEEP_TREES_SLOW_SCRIPT_MS :: 20_000
BENCH_SLOW_SCRIPT_MS :: 300_000      // the benchmarks are one long script, of no interest to the limit
BENCHES :: 9

HEAD :: `<!doctype html><head><script>
function is(want, what, ...got) { const line = got.map(String).join(" "); wrenTest.check(line === want, line === want ? what : what + ": " + line); }
</script></head>`

// Runs the loop until nothing is left to do (no task posted, no timer near), at most SETTLE_TURNS turns. Returns the turns run.
settle :: proc() -> int {
	turns := 0
	for ; turns < SETTLE_TURNS; turns += 1 {
		next := host.next_timeout_ms(&loop)
		if next < 0 || next > SETTLE_FARTHEST_MS { break }
		host.loop_wait(&loop, next)
	}
	return turns
}

load :: proc(t: ^testing.T, name, source: string) -> ^Probe {
	pr := open_page(t, name, source, ADDRESS)
	settle()
	return pr
}

noted :: proc(pr: ^Probe, text: string) -> bool { return testhost.noted(&pr.section, text) }

live_nodes :: proc(pr: ^Probe) -> int { return pr.p.doc.nodes.count }

// The console: only for what is about the console.
console_is :: proc(pr: ^Probe, text: string) -> bool {
	for l in pr.lines { if l == text { return true } }
	return false
}

console_says :: proc(pr: ^Probe, part: string) -> bool {
	for l in pr.lines { if strings.contains(l, part) { return true } }
	return false
}

console_clear :: proc(pr: ^Probe) {
	for l in pr.lines { delete(l) }
	clear(&pr.lines)
}

// The realm of a page that has done its worst still runs a script.
usable :: proc(pr: ^Probe, what: string) {
	run(pr, fmt.tprintf(`wrenTest.check(true, %q)`, fmt.tprintf("%s: the realm is usable afterwards", what)))
}

hostile :: proc() {
	settings.js.slow_script_ms = HOSTILE_SLOW_SCRIPT_MS
	settings.js.max_heap_bytes = HOSTILE_HEAP_BYTES
}

@(test)
js_a_realm_runs_the_scripts_of_a_document_in_order :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := load(t, "realm", HEAD + `<title>t</title><body>
<script>is("object object true", "the global object, window and self", typeof window, typeof document, self === window)</script>
<p id=x>hello</p>
<script>is("hello", "getElementById and textContent from the browser's DOM", document.getElementById("x").textContent)</script>
<script>var steps = []; Promise.resolve().then(() => steps.push("microtask")); steps.push("sync")</script>
<script>is("sync,microtask", "promise reactions run at the microtask checkpoint after the script", steps.join())</script>
</body>`)
	close_page(pr, min_checks = 3)
}

@(test)
js_the_developer_tools_describe_console_arguments_while_the_panel_is_open :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := load(t, "developer tools", `<!doctype html><body><div id=n class="c"></div><script>
console.log("plain", {a: 1});
</script></body>`)
	check(pr, len(pr.lines) == 1 && strings.has_prefix(pr.lines[0], "plain"), "closed: one line per call, nothing described")
	page.dev_console_arm(pr.p, DEV_CONSOLE_BYTES)
	console_clear(pr)
	page.js_console_eval(pr.p, `console.log("hi %s", "Ada", {k: [1, 2]}, new Map([[1, 2]]), document.getElementById("n"))`)
	described := false
	for l in pr.lines { if strings.has_prefix(l, "\x01dt:") && strings.contains(l, `"c":"Map"`) && strings.contains(l, `<div id=\"n\" class=\"c\">`) && strings.contains(l, `"k"`) { described = true } }
	check(pr, described, "armed: the call is described (object, Map, DOM node) in a private line before its own")
	console_clear(pr)
	page.js_console_eval(pr.p, `1 + 1`)
	check(pr, console_is(pr, "2"), "a console expression prints its value as a line")
	check(pr, len(pr.lines) >= 2 && strings.has_prefix(pr.lines[0], "\x01dt:") && strings.contains(pr.lines[0], `"l":"result"`), "and describes it as a result")
	console_clear(pr)
	page.dev_console_complete(pr.p, "Math")
	check(pr, len(pr.lines) == 1 && strings.has_prefix(pr.lines[0], "\x01dtc:") && strings.contains(pr.lines[0], `"floor"`), "completion asks the realm for the members of an expression")
	page.dev_console_arm(pr.p, 0)
	console_clear(pr)
	page.js_console_eval(pr.p, `console.log({z: 1})`)
	check(pr, !console_says(pr, "\x01") && console_is(pr, "{ z: 1 }"), "disarmed: no description, the line as it was")
	close_page(pr, min_checks = 6)
}

@(test)
js_dom_bindings_tree_attributes_wrappers :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := load(t, "bindings", HEAD + `<body><div id=a class=c></div><script>
const a = document.getElementById("a");
is("true true true true true", "one wrapper per node, prototype chain from the IDL", a === document.getElementById("a"), a instanceof HTMLDivElement, a instanceof Element, a instanceof Node, a instanceof EventTarget);
is("[object HTMLDivElement] DIV c null", "toStringTag, getters (tagName upper case in an HTML document), null for a missing attribute", Object.prototype.toString.call(a), a.tagName, a.getAttribute("class"), a.getAttribute("nope"));
const s = document.createElement("span");
s.textContent = "made";
is("null true true true made", "appendChild returns its argument; the tree is the browser's", s.parentNode, a.appendChild(s) === s, s.parentNode === a, a.firstChild === s, a.textContent);
a.setAttribute("data-x", "1");
is("1 1 HTML", "attributes, nodeType, documentElement", a.getAttribute("data-x"), document.body.lastChild.nodeType, document.documentElement.tagName);
try { a.appendChild(a); } catch (e) { is("HierarchyRequestError", "browser errors become DOMException names", e.name); }
try { Node.prototype.appendChild.call({}, s); } catch (e) { is("true", "wrong this: TypeError", e instanceof TypeError); }
try { new Node(); } catch (e) { is("true", "Node is not constructible", e instanceof TypeError); }
</script></body>`)
	close_page(pr, min_checks = 7)
}

@(test)
js_events_listeners_the_same_event_object_handlers_propagation :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := load(t, "events", HEAD + `<body><div id=outer><button id=b>b</button></div><script>
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
is("outer-capture|target true 42 2|once|outer-bubble true true|outer-capture|target true undefined 2|outer-bubble false true false true true null false", "capture, target, bubble order; once; the dispatched object is the listener's; preventDefault",
  order.join("|"), r, ev.defaultPrevented, ev.target === b, ev.currentTarget, ev.isTrusted);
let clicks = 0;
b.onclick = () => clicks++;
is("function true", "event handler attribute getter", typeof b.onclick, b.onclick !== null);
b.dispatchEvent(new Event("click"));
b.onclick = null;
b.dispatchEvent(new Event("click"));
is("1", "event handler runs, removed with null", clicks);
</script></body>`)
	close_page(pr, min_checks = 3)
}

@(test)
js_the_browsers_own_events_reach_javascript_listeners :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := load(t, "the browser's events", HEAD + `<body><button id=b>b</button><script>
let seen = null;
document.getElementById("b").addEventListener("click", e => {
  seen = e;
  is("true true click b true true", "a click from the browser is a trusted MouseEvent", e instanceof MouseEvent, e.isTrusted, e.type, e.target.id, e.bubbles, e.cancelable);
  e.preventDefault();
});
document.addEventListener("click", e => is("true 3", "the same wrapper bubbles up to the document", e === seen, e.eventPhase));
</script></body>`)
	b := dom.find_by_id(pr.p.doc, "b")
	allowed := page.dispatch_event(pr.p, b, dom.Event{type = "click", bubbles = true, cancelable = true, x = 3, y = 4})
	check(pr, !allowed, "preventDefault from JavaScript cancels the browser's default action")
	run(pr, `is("click null 0 true", "a kept event keeps its state after the dispatch", seen.type, seen.currentTarget, seen.eventPhase, seen.defaultPrevented)`)
	close_page(pr, min_checks = 4)
}

@(test)
js_wrappers_and_nodes_the_two_heaps_free_each_other :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := load(t, "wrappers and nodes", HEAD + `<body><script>
for (let i = 0; i < 20000; i++) { const d = document.createElement("div"); d.textContent = "x"; }
const keep = document.createElement("section");
keep.appendChild(document.createElement("i")).id = "inner";
window.kept = keep;
document.body.appendChild(document.createElement("p")).id = "connected";
document.body.lastChild.addEventListener("x", () => wrenTest.check(true, "the wrapper of a connected node keeps its listeners without any JS reference"));
</script></body>`)
	js.collect(pr.p.js.inst)
	check(pr, live_nodes(pr) < FEW_NODES, "unreferenced detached nodes are freed when their wrappers are collected")
	run(pr, `is("inner true", "a detached tree referenced from JavaScript stays whole", kept.firstChild.id, kept.firstChild.parentNode === kept); document.getElementById("connected").dispatchEvent(new Event("x"))`)
	close_page(pr, min_checks = 3)
}

// A node a script makes comes with its wrapper's pin and interface in the same call to the browser
// (Document_createElementWrapped, Document_createTextWrapped): one pin for each wrapper, the custom element whose
// constructor made its wrapper before createElement returned included, and the browser's errors as before; the realm's
// document, asked once, is the same object.
@(test)
js_new_nodes_wrapped_in_one_call :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := load(t, "new nodes wrapped", HEAD + `<body><script>
(function () {
  customElements.define("x-made", class extends HTMLElement { constructor() { super(); window.made = this } });
  const x = document.body.appendChild(document.createElement("x-made"));
  x.id = "custom";
  const d = document.body.appendChild(document.createElement("div"));
  d.id = "div";
  const text = d.appendChild(document.createTextNode("text"));
  let thrown = "";
  try { document.createElement("1x") } catch (e) { thrown = e.name }
  is("true HTMLDivElement Text text true true InvalidCharacterError", "the wrappers of new nodes",
    x === made, d.constructor.name, text.constructor.name, d.textContent, d.ownerDocument === document, document === window.document, thrown)
  window.kept = d;
})();
</script></body>`)
	pins :: proc(pr: ^Probe, id: string) -> u32 { return dom.get(pr.p.doc, dom.find_by_id(pr.p.doc, id)).pins }
	check(pr, pins(pr, "custom") == 1 && pins(pr, "div") == 1, fmt.tprintf("one pin for each wrapper (%d, %d)", pins(pr, "custom"), pins(pr, "div")))
	// the custom element's wrapper has a prototype of its own: it stays with the document; the plain one goes
	run(pr, `window.made = null; window.kept = null`)
	js.collect(pr.p.js.inst)
	check(pr, pins(pr, "custom") == 1 && pins(pr, "div") == 0, fmt.tprintf("the collection unpins the plain one (%d, %d)", pins(pr, "custom"), pins(pr, "div")))
	close_page(pr, min_checks = 3)
}

// A wrapper that carries nothing of its own goes with the collection even when its node is connected, and is made again
// when a script reaches the node; one with a property, a WeakMap or WeakRef holding it, another prototype, a [SameObject]
// value, or made non-extensible stays, the same object.
@(test)
js_plain_wrappers_go_the_others_stay_the_same :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := load(t, "plain wrappers", HEAD + `<body><ul id=list><li id=e0><li id=e1><li id=e2><li id=e3><li id=e4><li id=e5><li id=plain></ul><script>
(function () {
  const li = document.getElementById("list").children;
  li[0].foo = 42;
  window.wm = new WeakMap([[li[1], "weak"]]);
  window.ref = new WeakRef(li[2]);
  Object.setPrototypeOf(li[3], Object.create(HTMLLIElement.prototype, {tag: {value: "mine"}}));
  window.cl = li[4].classList;
  Object.preventExtensions(li[5]);
  li[6].id;
  const root = document.createElement("div");
  root.appendChild(document.createElement("b")).bar = 7;
  window.root = root;
})();
</script></body>`)
	js.collect(pr.p.js.inst)
	pins :: proc(pr: ^Probe, id: string) -> u32 { return dom.get(pr.p.doc, dom.find_by_id(pr.p.doc, id)).pins }
	check(pr, pins(pr, "plain") == 0, "the plain wrapper of a connected node is collected (its node unpinned)")
	kept := 0
	for id in ([?]string{"e0", "e1", "e2", "e3", "e4", "e5"}) { if pins(pr, id) > 0 { kept += 1 } }
	check(pr, kept == 6, fmt.tprintf("the wrappers that carry something stay (%d of 6)", kept))
	run(pr, `const li = document.getElementById("list").children;
is("42 weak true mine true false 7 plain", "the same objects after the collection: property, WeakMap key, WeakRef target, prototype, [SameObject] value, extensibility, a detached tree's member",
  li[0].foo, wm.get(li[1]), ref.deref() === li[2], li[3].tag, cl === li[4].classList, Object.isExtensible(li[5]), root.firstChild.bar, li[6].id)`)
	close_page(pr, min_checks = 3)
}

// (one script in each page: another one could be what the cache finds)
@(test)
js_bytecode_cache :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	source := `<!doctype html><body><script>wrenTest.note("cached run " + 6 * 7)</script></body>`
	first := load(t, "bytecode cache, first", source)
	close_page(first)
	before := js.cache_stats()
	pr := load(t, "bytecode cache, second", source)
	after := js.cache_stats()
	check(pr, noted(pr, "cached run 42"), "the script runs again")
	check(pr, after.memory_hits > before.memory_hits, "the second page runs it from the bytecode cache")
	close_page(pr, min_checks = 2)
}

@(test)
js_bytecode_cache_of_a_module :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	source := `<!doctype html><body><script type="module">wrenTest.note("module run " + 6 * 7 + " " + (import.meta.url.indexOf("js.html") > 0)); export const x = 1</script></body>`
	first := load(t, "module cache, first", source)
	check(first, noted(first, "module run 42 true"), "the module runs")
	close_page(first, min_checks = 1)
	before := js.cache_stats()
	pr := load(t, "module cache, second", source)
	after := js.cache_stats()
	check(pr, noted(pr, "module run 42 true"), "it runs again, import.meta.url included")
	check(pr, after.memory_hits > before.memory_hits, "the second page reads its bytecode from the cache")
	close_page(pr, min_checks = 2)
}

@(test)
js_interruption_of_a_script_that_loops :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	settings.js.slow_script_ms = SLOW_SCRIPT_MS
	start := time.tick_now()
	pr := load(t, "interruption", `<!doctype html><body><script>wrenTest.note("before"); for (;;) {}</script><script>wrenTest.note("after")</script></body>`)
	ms := time.duration_milliseconds(time.tick_since(start))
	pr.expect_uncaught = true
	check(pr, noted(pr, "before") && noted(pr, "after"), "the loop is stopped, the next script runs")
	check(pr, ms >= NOT_STOPPED_BEFORE_MS, fmt.tprintf("not stopped before javascript.slow_script_ms (%.0f ms)", ms))
	check(pr, console_says(pr, "slow_script_ms"), "the console says a slow script was stopped")
	run(pr, `wrenTest.check(true, "the realm is usable afterwards")`)
	close_page(pr, min_checks = 4)

	// the same in a promise reaction: no script to name, the console still says what happened
	pr = load(t, "interruption of a reaction", `<!doctype html><body><script>Promise.resolve().then(() => { for (;;) {} });</script><script>wrenTest.note("reaction stopped")</script></body>`)
	pr.expect_uncaught = true
	said := false
	for l in pr.lines { if strings.contains(l, "slow_script_ms") && strings.contains(l, "promise reaction") { said = true } }
	check(pr, noted(pr, "reaction stopped") && said, "a reaction that loops is stopped too, and the console says so")
	close_page(pr, min_checks = 1)
}

@(test)
js_performance_observer :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := load(t, "PerformanceObserver", HEAD + `<body><script>
const say = (...a) => wrenTest.note(a.map(String).join(" "));
performance.mark("early");
var po = new PerformanceObserver((list, obs) => {
  say("po", list.getEntries().map(e => e.entryType + ":" + e.name).join(","), obs === po, list.getEntriesByType("mark").length, list.getEntriesByName("m2").length);
});
po.observe({ type: "mark", buffered: true });
po.observe({ type: "measure" });
new PerformanceObserver(() => {}).observe({ type: "no-such-entry-type" });
var lt = new PerformanceObserver((list) => { for (const e of list.getEntries()) say("lt", e.entryType, e.name, e.duration >= 50, e.attribution.length, e.attribution[0].containerType, e.attribution === e.attribution, e.toJSON().entryType, performance.getEntriesByType("longtask").length); });
lt.observe({ type: "longtask" });
setTimeout(() => { const t = performance.now(); while (performance.now() - t < 70) {} }, 0);
performance.mark("m2");
performance.measure("ms", "early", "m2");
is("element,event,first-input,largest-contentful-paint,layout-shift,long-animation-frame,longtask,mark,measure,navigation,paint,resource,visibility-state true true", "supportedEntryTypes: a frozen [SameObject] array of what the timeline records",
  PerformanceObserver.supportedEntryTypes.join(), PerformanceObserver.supportedEntryTypes === PerformanceObserver.supportedEntryTypes, Object.isFrozen(PerformanceObserver.supportedEntryTypes));
try { po.observe({ entryTypes: ["mark"] }); } catch (e) { say("mixed", e.name); }
try { po.observe({}); } catch (e) { say("empty", e.name); }
var p2 = new PerformanceObserver(() => say("p2 called"));
p2.observe({ entryTypes: ["mark"] });
performance.mark("m3");
say("take", p2.takeRecords().length);
p2.disconnect();
</script></body>`)
	settle()
	check(pr, noted(pr, "lt longtask self true 1 window true longtask 0"), "a task of 70 ms is a long task: observed (attribution: the window), not in getEntriesByType")
	check(pr, noted(pr, "mixed InvalidModificationError") && noted(pr, "empty TypeError"), "observe(): the errors of Performance Timeline")
	check(pr, noted(pr, "take 1") && !noted(pr, "p2 called"), "takeRecords empties the buffer, disconnect stops delivery")
	check(pr, noted(pr, "po mark:early,measure:ms,mark:m2,mark:m3 true 3 1"), "buffered entries, then new marks and measures, delivered by one task in start time order")
	check(pr, console_says(pr, "'no-such-entry-type' does not exist"), "an unsupported entry type is ignored with a warning")
	close_page(pr, min_checks = 6)
}

@(test)
js_a_media_source_nothing_in_the_script_holds :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := load(t, "MediaSource", HEAD + `<body></body>`)
	run(pr, `
globalThis.weak = [];
globalThis.elements = [];
globalThis.urls = [];
const source = (revoke, what) => {
	const v = document.createElement("video");
	document.body.appendChild(v);
	const ms = new MediaSource();
	weak.push(new WeakRef(ms));
	elements.push(v);
	ms.addEventListener("sourceopen", () => wrenTest.note("sourceopen " + what));
	ms.addEventListener("sourceclose", () => wrenTest.note("sourceclose " + what));
	const u = URL.createObjectURL(ms);
	v.src = u;
	if (revoke) URL.revokeObjectURL(u); else urls.push(u);
};
source(true, "element");
source(false, "url");
source(false, "kept");
`)
	js.collect(pr.p.js.inst)   // (before the load's tasks: what used to lose the event)
	settle()
	check(pr, noted(pr, "sourceopen url"), "a MediaSource held by its object URL gets sourceopen after a collection")
	check(pr, noted(pr, "sourceopen element"), "and one whose revoked URL is still named by the src attribute")
	js.collect(pr.p.js.inst)
	run(pr, `URL.revokeObjectURL(urls[0]); for (const v of elements.slice(0, 2)) { v.removeAttribute("src"); v.load(); }`)
	settle()
	check(pr, noted(pr, "sourceclose url") && noted(pr, "sourceclose element"), "attached, it stays alive until the element lets go: sourceclose")
	// (the engine lets go of the last event dispatched, and of its target, at the next one)
	run(pr, `{ const t = document.createElement("div"); t.addEventListener("x", () => {}); t.dispatchEvent(new Event("x")); }`)
	settle()
	js.collect(pr.p.js.inst)
	settle()
	run(pr, `is("true true", "and then nothing holds it: its wrapper is collected (the one still attached stays)", weak.slice(0, 2).every((w) => w.deref() === undefined), weak[2].deref() !== undefined)`)
	close_page(pr, min_checks = 4)
}

@(test)
js_hostile_recursion :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	hostile()
	pr := load(t, "recursion", HEAD + `<body><script>
function f(n) { return f(n + 1) + 1; }
try { f(0) } catch (e) { is("true", "unbounded JavaScript recursion throws RangeError", e instanceof RangeError) }
</script></body>`)
	usable(pr, "recursion")
	close_page(pr, min_checks = 2)
}

@(test)
js_hostile_recursion_through_the_browser :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	hostile()
	pr := load(t, "recursion through the browser", HEAD + `<body><div id=a></div><script>
const a = document.getElementById("a");
let depth = 0;
a.addEventListener("x", () => { depth++; a.dispatchEvent(new Event("x")); });
try { a.dispatchEvent(new Event("x")); } catch (e) {}
wrenTest.check(depth > 0, "recursion through the browser (dispatchEvent from a listener) ends without a crash");
</script></body>`)
	pr.expect_uncaught = true   // the listener at the bottom ran out of stack
	usable(pr, "recursion through the browser")
	close_page(pr, min_checks = 2)
}

// Filling the heap to its limit must not be a race with the limits of time (the call stopped before the heap is full): they are far.
// Running out of memory cannot be caught (src/engine/jsrt/gc.odin): the next script runs.
@(test)
js_hostile_out_of_memory :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	hostile()
	settings.js.slow_script_ms = FILLING_THE_HEAP_SLOW_SCRIPT_MS
	pr := load(t, "out of memory", HEAD + `<body><script>
const keep = [];
try { for (;;) keep.push(new Array(1 << 16).fill(1.5)); } catch (e) { wrenTest.note("caught") }
</script><script>
wrenTest.check(keep.length > 0, "the script before it had filled the heap");
keep.length = 0;
try { "x".repeat(1 << 30); } catch (e) { wrenTest.check(e.name === "RangeError" || e.name === "InternalError", "a 1 GiB string is refused") }
</script></body>`)
	pr.expect_uncaught = true
	check(pr, console_says(pr, "Uncaught InternalError: out of memory") && !noted(pr, "caught"), "allocating past javascript.max_heap_bytes stops the script: no catch sees it (the engine's rule), the console says so")
	usable(pr, "out of memory")
	close_page(pr, min_checks = 4)
}

@(test)
js_hostile_endless_microtasks :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	hostile()
	pr := load(t, "microtask chain", HEAD + `<body><script>
globalThis.links = 0;
function m() { links++; Promise.resolve().then(m); }
m();
</script><script>wrenTest.check(true, "an endless microtask chain is stopped, the next script runs")</script></body>`)
	pr.expect_uncaught = true
	usable(pr, "microtask chain")
	// (its count, not the slow script's message: on a loaded machine the probe's own checkpoint may pass the limit)
	run(pr, `globalThis.seen = links;`)
	settle()
	run(pr, `is("true", "the stopped microtask chain does not start again at the next checkpoint", links === seen)`)
	close_page(pr, min_checks = 3)
}

@(test)
js_hostile_a_flood_of_timers :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	hostile()
	pr := load(t, "timer flood", HEAD + `<body><script>
let n = 0;
function t() { n++; setTimeout(t, 0); setTimeout(t, 0); }
t();
</script></body>`)
	// load ran its turns under the flood (each one ends: the loop's time slice, host tests); a task the shell posts meanwhile (input,
	// painting) runs at the very next turn
	posted := false
	host.post(&loop, proc(data: rawptr) { (^bool)(data)^ = true }, rawptr(&posted))   // (run by the wait below)
	host.loop_wait(&loop, 0)
	check(pr, posted, "timers doubling at every run: a task posted meanwhile runs at the next turn")
	run(pr, `is("true", "the timers did run in those turns", n >= 100)`)
	usable(pr, "timer flood")
	close_page(pr, min_checks = 3)
}

@(test)
js_hostile_document_write :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	hostile()
	pr := load(t, "document.write", HEAD + `<body><script>
const w = s => document.write(s);
w("<script>w('<script>w(\"<b>deep</b>\")<\/script>')<\/script>");
let k = 0;
function nest() { k++; document.write("<script>nest()<\/script>"); }
nest();
is("true", "document.write nested without end is cut at javascript.document_write.max_depth", k < 1000);
try { for (let i = 0; i < 1e7; i++) document.write("xxxxxxxxxxxxxxxx"); } catch (e) {}
</script><script>wrenTest.check(true, "a document.write flood ends (javascript.document_write.max_bytes or the time limit)")</script></body>`)
	pr.expect_uncaught = true
	usable(pr, "document.write")
	close_page(pr, min_checks = 3)
}

// The same flood in a loop the JIT compiled at once (it reads `document` and calls a native of a fixed cost, ~0.1 ms):
// the compiled code must give the interrupt its turn as the interpreter does, once the native calls count for a poll.
// It gave it only every JIT_BUDGET iterations, seconds of such calls, past wasm.max_call_ms: the engine was stopped.
@(test)
js_hostile_compiled_native_flood :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	hostile()
	settings.js.jit.call_threshold = 1
	settings.js.jit.loop_threshold = 1
	settings.js.jit.background_threads = 0
	pr := load(t, "compiled flood", HEAD + `<body><script>
function flood() { const big = new Array(20000).fill("ab"); let n = 0; for (;;) { n += big.join(document.title).length; } }
try { flood(); } catch (e) {}
</script><script>wrenTest.check(true, "a compiled loop of native calls is stopped like a slow script, the next script runs")</script></body>`)
	pr.expect_uncaught = true
	check(pr, console_says(pr, "slow_script_ms"), "it was stopped by javascript.slow_script_ms")
	usable(pr, "compiled flood")
	close_page(pr, min_checks = 3)
}

@(test)
js_hostile_an_observer_that_feeds_itself :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	hostile()
	pr := load(t, "observer feedback", HEAD + `<body><div id=t></div><script>
const t = document.getElementById("t");
let calls = 0;
new MutationObserver(() => { calls++; t.setAttribute("n", calls); }).observe(t, { attributes: true });
t.setAttribute("n", 0);
</script></body>`)
	pr.expect_uncaught = true
	check(pr, console_says(pr, "slow_script_ms"), "a MutationObserver that mutates what it observes is stopped like a slow script")
	check(pr, settle() < SETTLE_TURNS, "and leaves nothing running")
	usable(pr, "observer feedback")
	close_page(pr, min_checks = 3)
}

// A load test: how long they take depends on the machine, and a script past its limit is stopped; they run with -Perf, not on the CI.
@(test)
js_hostile_deep_trees :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	if base.perf_skip("deep trees: 20 000 and 50 000 nested elements") { return }
	hostile()
	settings.js.slow_script_ms = DEEP_TREES_SLOW_SCRIPT_MS
	pr := load(t, "deep trees", HEAD + `<body><script>
let n = document.createElement("div");
const root = n;
for (let i = 0; i < 20000; i++) { const c = document.createElement("div"); n.appendChild(c); n = c; }
n.textContent = "leaf";
document.body.appendChild(root);
const html = root.outerHTML;
const copy = root.cloneNode(true);
is("true leaf true 20001 contains true", "20 000 nested elements: serialization, clone, contains, selectors, position, closest", html.length > 200000, copy.textContent, root.contains(n), document.querySelectorAll("div").length,
  n.compareDocumentPosition(root) & Node.DOCUMENT_POSITION_CONTAINS ? "contains" : "no", n.closest("body") === document.body);
root.remove();
const holder = document.createElement("div");
holder.innerHTML = "<div>".repeat(50000) + "x";
is("x", "50 000 nested elements from innerHTML", holder.textContent);
</script></body>`)
	usable(pr, "deep tree")
	close_page(pr, min_checks = 3)
}

@(test)
js_hostile_document_open :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	hostile()
	pr := load(t, "document.open", HEAD + `<body><p id=old>old</p><script>
var old = document.getElementById("old"), body = document.body;
document.open();   // the parser is running this script: does nothing (HTML)
is("true", "document.open from a script the parser runs does nothing", old.isConnected);
</script></body>`)
	run(pr, `
document.open();
document.write("<body><p id=n>new</p></body>");
document.close();
is("old false old false new false", "nodes kept by JavaScript survive document.open, and are not confused with new nodes", old.id, old.isConnected, old.textContent, body.isConnected, document.getElementById("n").textContent, old === document.getElementById("n"));
const p = document.getElementById("n");
const kept = p.firstChild;
p.innerHTML = "<i>x</i>";
is("new null", "a child replaced by innerHTML stays usable from JavaScript", kept.data, kept.parentNode);
p.textContent = "";
is("0", "textContent = '' empties", p.childNodes.length);
`)
	usable(pr, "document.open")
	close_page(pr, min_checks = 5)
}

// HTML document.open: every listener and handler of the document's tree and of the Window is erased; the old DOMContentLoaded listener
// opening the document again used to see the new document's and loop forever.
@(test)
js_hostile_document_open_in_dom_content_loaded :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	hostile()
	pr := load(t, "document.open in DOMContentLoaded", HEAD + `<body><p id=t>t</p><script>
var runs = 0, winRuns = 0;
function onWin() { winRuns++; }
window.addEventListener("ping", onWin);
document.addEventListener("DOMContentLoaded", () => {
  runs++;
  if (runs > 3) { return; }
  history.replaceState(undefined, "", "");
  document.open();
  document.write("<!doctype html><body>done</body>");
  document.close();
  window.dispatchEvent(new Event("ping"));
  is("1 done null 0", "document.open in DOMContentLoaded: the listener runs once, the Window's listeners and handlers are erased", runs, document.body.textContent, window.onload, winRuns);
  window.addEventListener("ping", onWin);
  window.dispatchEvent(new Event("ping"));
  is("1", "a listener erased by document.open can be added again", winRuns);
});
window.onload = () => wrenTest.note("old onload ran");
</script></body>`)
	check(pr, !noted(pr, "old onload ran"), "the old document's onload does not run for the new document")
	usable(pr, "document.open in DOMContentLoaded")
	close_page(pr, min_checks = 4)
}

@(test)
js_hostile_nodes_in_cycles_with_their_wrappers :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := load(t, "cycles", `<!doctype html><body><script>
for (let i = 0; i < 20000; i++) {
  const d = document.createElement("div");
  d.self = d;
  d.box = { node: d };
  d.addEventListener("click", () => d.textContent);
  d.appendChild(document.createElement("span")).owner = d;
}
wrenTest.check(true, "all of them were made");
</script></body>`)
	js.collect(pr.p.js.inst)
	check(pr, live_nodes(pr) < FEW_NODES, "detached nodes in cycles with their wrappers (expandos, listener closures, children) are freed")
	close_page(pr, min_checks = 2)
}

@(test)
js_the_engines_c_code_against_scripts_that_run_in_the_middle_of_it :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := load(t, "the engine's C code", HEAD + `<body><form><input id=i onclick="wrenTest.note('stale handler ran')"></form><script>
// settling a read reads the result's then: a getter releasing the lock (the stream's last reference) mid-read
(async () => {
  let reader = new Blob(["abc"]).stream().getReader(), hits = 0;
  Object.defineProperty(Object.prototype, "then", {configurable: true, get() { if (reader && "done" in this) { hits++; const r = reader; reader = null; r.releaseLock(); } return undefined; }});
  const pr = reader.read();
  delete Object.prototype.then;
  const res = await pr;
  is("1 false 3", "a read settled while a then getter releases the stream's last reference", hits, res.done, res.value.length);
})();
// structured clone of a value nested deeper than the C stack allows: an exception, not a crash
let deep = []; for (let k = 0; k < 100000; k++) deep = [deep];
try { structuredClone(deep); } catch (e) { is("RangeError", "a structured clone deeper than the C stack throws a RangeError", e.name); }
// a rejected promise whose reason is a rejected promise, deeply: the console stops at its depth
let pr = Promise.reject(0); pr.catch(() => {});
for (let k = 0; k < 20000; k++) { pr = Promise.reject(pr); pr.catch(() => {}); }
console.log(pr);
wrenTest.check(true, "console.log of deeply nested promises stops at its depth");
// a listener removed then another added (its memory may be reused): the signal removes only the first
{
  const ac = new AbortController(), t = document.createElement("div"), f = () => {}; let n = 0;
  t.addEventListener("x", f, {signal: ac.signal}); t.removeEventListener("x", f);
  t.addEventListener("x", () => n++);
  ac.abort(); t.dispatchEvent(new Event("x"));
  is("1", "an aborted signal removes its own listener, not a later one", n);
}
// passive listeners cannot cancel; the signal's own state decides, not its aborted getter
{
  const t = document.createElement("div"); let inside = null;
  t.addEventListener("x", e => { e.preventDefault(); inside = e.defaultPrevented; }, {passive: true});
  const ev = new Event("x", {cancelable: true});
  is("true false false", "preventDefault in a passive listener does nothing", t.dispatchEvent(ev), inside, ev.defaultPrevented);
  const d = Object.getOwnPropertyDescriptor(AbortSignal.prototype, "aborted");
  Object.defineProperty(AbortSignal.prototype, "aborted", {configurable: true, get() { throw new Error("getter"); }});
  let n = 0, threw = false;
  try { t.addEventListener("y", () => n++, {signal: new AbortController().signal}); } catch (e) { threw = true; }
  Object.defineProperty(AbortSignal.prototype, "aborted", d);
  t.dispatchEvent(new Event("y"));
  is("false 1", "addEventListener reads the signal's state, not its aborted getter", threw, n);
}
// a content attribute handler cleared by the form getter while it compiles stays cleared
{
  const i = document.getElementById("i");
  const d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "form");
  Object.defineProperty(HTMLInputElement.prototype, "form", {configurable: true, get() { i.onclick = null; return null; }});
  const h = i.onclick;
  Object.defineProperty(HTMLInputElement.prototype, "form", d);
  is("null null", "a handler cleared while it compiles is not brought back", h, i.onclick);
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
  is("0 true true true", "engine-built arrays define their elements (AbortSignal.any, composedPath)", ran, Object.hasOwn(path, 0), path[0] === document.body, any instanceof AbortSignal);
}
// an index of a collection cannot be deleted; anything else can
{
  const nl = document.body.childNodes;
  is("false true true true", "an existing index of a collection cannot be deleted", delete nl[0], 0 in nl, delete nl[999], delete nl.foo);
}
// the rejection tracker and module evaluation use the engine's own WeakSet methods and then
WeakSet.prototype.has = function () { wrenTest.note("patched has ran"); return false; };
const thenOrig = Promise.prototype.then;
Promise.prototype.then = function (...a) { wrenTest.note("patched then ran"); return thenOrig.apply(this, a); };
const late = Promise.reject(new Error("late"));
setTimeout(() => setTimeout(() => { thenOrig.call(late, undefined, () => {}); wrenTest.note("late handled"); }), 0);
</script><script type=module>
await new Promise(r => setTimeout(r, 0));
wrenTest.note("module done");
</script></body>`)
	pr.expect_uncaught = true   // the late rejection, unhandled for a while
	check(pr, !noted(pr, "stale handler ran"), "the handler cleared while it compiled does not run")
	check(pr, noted(pr, "late handled") && noted(pr, "module done"), "the late handler and the module ran")
	check(pr, !noted(pr, "patched has ran") && !noted(pr, "patched then ran"), "scripts' WeakSet.prototype.has and Promise.prototype.then are not called by the engine")
	close_page(pr, min_checks = 12)
}

@(test)
js_a_wrapper_collected_while_its_node_lives_on_takes_its_listeners_along :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	pr := load(t, "a wrapper collected", HEAD + `<body><script>
window.list = (() => {
  const d = document.createElement("div"), s = d.appendChild(document.createElement("span"));
  s.addEventListener("x", () => wrenTest.note("old listener"));
  return d.querySelectorAll("span");
})();
</script></body>`)
	js.collect(pr.p.js.inst)
	js.collect(pr.p.js.inst)
	run(pr, `
window.hits = 0;
for (let k = 0; k < 20; k++) { const o = document.createElement("p"); o.addEventListener("y", () => hits++); (window.keepAlive ??= []).push(o); }
list[0].dispatchEvent(new Event("x"));
is("0", "an event at a node whose wrapper died never calls a listener of another target", hits);`)
	close_page(pr, min_checks = 1)
}

// What a call across the boundary costs, in the log: a measure of time, so with -Perf only, and each must have come.
@(test)
js_cost_of_a_call_across_the_boundary :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	if base.perf_skip("the cost of a call across the boundary") { return }
	settings.js.slow_script_ms = BENCH_SLOW_SCRIPT_MS
	pr := load(t, "boundary", `<!doctype html><body><div id=a title=t><span></span></div><script>
const a = document.getElementById("a"), N = 1000000;
function bench(name, f) {
  f(1000);
  const t0 = performance_now();
  f(N);
  wrenTest.measure(name + " (ns per call)", (performance_now() - t0) * 1e6 / N);
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
	check(pr, len(pr.section.measures) == BENCHES, "every benchmark ran")
	close_page(pr, min_checks = 1)
}
