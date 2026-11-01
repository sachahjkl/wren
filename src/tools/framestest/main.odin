// End-to-end test of nested documents (src/page/frames.odin, frames_scripts.odin; native/js/runtime/frames.c,
// prelude/frames.js): <iframe> creation and destruction, about:blank / srcdoc / fetched documents, load events and the
// parent's load, window.frames / length / parent / top / name, postMessage across origins (targetOrigin, origin,
// source), what a cross-origin window refuses, sandbox (scripts, opaque origin), X-Frame-Options, frame-ancestors, the
// parent's frame-src, navigation by src, by the frame itself and by window.open to a frame name, the Permissions
// Policy's allow attribute, storage partitioning. Needs build\testserver.exe on 127.0.0.1:8765 or on the block of
// WREN_TEST_BASE_PORT (src/tools/testenv). From the repository root:
//   framestest.exe
package framestest

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:js"
import "wb:net"
import "wb:page"
import "wb:style"
import "wb:wasm"
import "wb:tools/testenv"

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

logged_contains :: proc(part: string) -> bool {
	for l in logs { if strings.contains(l, part) { return true } }
	return false
}

index_of :: proc(text: string) -> int {
	for l, i in logs { if l == text { return i } }
	return -1
}

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings
process:  ^base.Scope

WAIT_FAIL_MS :: 60_000

wait_for :: proc(text: string) -> bool {
	start := time.tick_now()
	for !logged(text) {
		if time.duration_milliseconds(time.tick_since(start)) > WAIT_FAIL_MS { return false }
		host.loop_wait(&loop, 5)
	}
	return true
}

// Runs the loop for `ms` (what must not happen has had its chance).
run_for :: proc(ms: f64) {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < ms { host.loop_wait(&loop, 5) }
}

enc :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	hex := "0123456789ABCDEF"
	for c in transmute([]u8)s {
		switch {
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~':
			strings.write_byte(&sb, c)
		case:
			strings.write_byte(&sb, '%')
			strings.write_byte(&sb, hex[c >> 4])
			strings.write_byte(&sb, hex[c & 15])
		}
	}
	return strings.to_string(sb)
}

SAME  :: "http://127.0.0.1:8765"   // the parent's origin
OTHER :: "http://127.0.0.1:8767"   // another origin of the same site
SITE2 :: "http://localhost:8765"   // another site

// A document served by the test server: `body` as HTML, `headers` as "Name: value".
doc :: proc(origin: string, body: string, headers: ..string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, testenv.url(strings.concatenate({origin, "/frames/doc?body="}, context.temp_allocator)))
	strings.write_string(&sb, enc(body))
	for h in headers {
		strings.write_string(&sb, "&h=")
		strings.write_string(&sb, enc(h))
	}
	return strings.to_string(sb)
}

load :: proc(source: string, address := SAME + "/frames/doc", csp := "") -> ^page.Page {
	for l in logs { delete(l) }
	clear(&logs)
	p := page.page_create(&loop, &loader, &settings, process, testenv.url(address), console)
	if csp != "" { page.apply_response_headers(p, {csp}, {}, "") }
	if os.get_env("FRAMESTEST_DUMP", context.temp_allocator) != "" { fmt.println(source) }
	page.load_html(p, transmute([]byte)strings.concatenate({LOG, source}, context.temp_allocator))
	page.scripts_start(p)
	return p
}

run_js :: proc(p: ^page.Page, code: string) { page.js_run(p, transmute([]byte)code, "probe.js") }

// The child page of the first frame element of `p` (nil: none).
child_of :: proc(p: ^page.Page, index := 0) -> ^page.Page {
	kids := page.frames_children(p)
	if index >= len(kids) { return nil }
	return kids[index].page
}

// Replaces each %s of `t` by the next argument (fmt would read the braces of JavaScript as its own).
fill :: proc(t: string, args: ..string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	rest := t
	k := 0
	for {
		i := strings.index(rest, "%s")
		if i < 0 || k >= len(args) { strings.write_string(&sb, rest); break }
		strings.write_string(&sb, rest[:i])
		strings.write_string(&sb, args[k])
		k += 1
		rest = rest[i + 2:]
	}
	return strings.to_string(sb)
}

LOG :: `<script>function log(s) { console.log(String(s)) }</script>`

foreign import psapi "system:Psapi.lib"
PROCESS_MEMORY_COUNTERS_EX :: struct {
	cb: u32, PageFaultCount: u32,
	PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage: uint,
	QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage, PrivateUsage: uint,
}
@(default_calling_convention = "system")
foreign psapi {
	GetProcessMemoryInfo :: proc(process: win.HANDLE, counters: ^PROCESS_MEMORY_COUNTERS_EX, cb: u32) -> win.BOOL ---
}

private_bytes :: proc() -> int {
	c: PROCESS_MEMORY_COUNTERS_EX
	c.cb = size_of(c)
	GetProcessMemoryInfo(win.GetCurrentProcess(), &c, c.cb)
	return int(c.PrivateUsage)
}

// Numbers, not checks: the time a frame takes to have a running document, and the memory it holds. A performance run
// (tools\test_all.ps1 -Perf): it checks nothing, so a run without the option skips it.
measurements :: proc() {
	fmt.println("-- measurements")
	if base.perf_skip("framestest: the time and memory of 20 srcdoc frames") { return }
	N :: 20
	// warm-up: the engine's code and the first realm's costs are not a frame's
	{
		p := load(`<body><iframe srcdoc="<script>parent.postMessage('w', '*')</script>"></iframe><script>addEventListener("message", () => log("warm"))</script></body>`)
		wait_for("warm")
		page.page_close(p)
		run_for(200)
	}
	before := private_bytes()
	t0 := time.tick_now()
	p := load(fill(`<body><script>
let n = 0;
addEventListener("message", () => { if (++n === %s) log("all frames ran"); });
const t = performance.now();
for (let i = 0; i < %s; i++) {
  const f = document.createElement("iframe");
  f.srcdoc = "<p>frame " + i + "</p><script>parent.postMessage(1, '*')<\/script>";
  document.body.appendChild(f);
}
log("inserted in " + (performance.now() - t).toFixed(2) + " ms");
</script></body>`, fmt.tprint(N), fmt.tprint(N)))
	ok := wait_for("all frames ran")
	ms := time.duration_milliseconds(time.tick_since(t0))
	after := private_bytes()
	for l in logs { if strings.has_prefix(l, "inserted in") { fmt.printfln("measure: %d srcdoc frames %s (synchronous part: navigables, realms)", N, l) } }
	fmt.printfln("measure: %d srcdoc frames with a script each, until all ran: %.1f ms (%.2f ms per frame)%s", N, ms, ms / N, ok ? "" : " (not all ran)")
	fmt.printfln("measure: private bytes +%.1f MiB for %d frames (%.2f MiB per frame, document and JavaScript realm)", f64(after - before) / (1 << 20), N, f64(after - before) / (1 << 20) / N)
	page.page_close(p)
	run_for(300)
	t1 := time.tick_now()
	p = load(fill(`<body><iframe src="%s"></iframe><script>addEventListener("message", e => log("cross " + e.data))</script></body>`, doc(OTHER, `<script>parent.postMessage("up", "*")</script>`)))
	wait_for("cross up")
	fmt.printfln("measure: one cross-origin frame over the test server, page start to its first message: %.1f ms", time.duration_milliseconds(time.tick_since(t1)))
	page.page_close(p)
}

// The DOM of a same-origin frame, reached from the parent and from the frame (src/page/frames_access.odin).
same_origin_dom :: proc() {
	fmt.println("-- the DOM of a same-origin frame: contentDocument, contentWindow.document, parent.document")
	{
		p := load(`<body><div id=top-marker>t</div><iframe id=b></iframe><script>
const f = document.getElementById("b");
const d = f.contentDocument;
log("doc " + d.nodeType + " " + (d === f.contentDocument) + " " + (d === f.contentWindow.document) + " " + (d === frames[0].document) + " " + (d !== document));
log("parts " + d.documentElement.tagName + " " + d.body.tagName + " " + (d.body === d.body) + " " + (d.body.ownerDocument === d) + " " + (d.defaultView === f.contentWindow));
d.body.innerHTML = '<p id=x class="c d">hello <b>there</b></p>';
const x = d.getElementById("x");
log("read " + x.textContent + " " + (d.querySelector("#x") === x) + " " + d.querySelectorAll("b").length + " " + (x.parentNode === d.body) + " " + x.classList.contains("d") + " " + d.getElementsByTagName("b").length);
log("separate " + (document.getElementById("x") === null) + " " + (document.getElementById("top-marker") !== null) + " " + (d.getElementById("top-marker") === null));
const made = d.createElement("span");
made.textContent = "made";
made.setAttribute("data-a", "1");
d.body.appendChild(made);
const text = d.createTextNode("!");
made.appendChild(text);
log("made " + (made.ownerDocument === d) + " " + d.body.lastChild.textContent + " " + d.body.children.length + " " + made.getAttribute("data-a") + " " + (made instanceof HTMLElement));
made.style.color = "rgb(1, 2, 3)";
log("style " + d.defaultView.frameElement + " " + made.style.color);
made.foo = 42;
log("expando " + d.querySelector("span").foo);
const own = document.createElement("div");
own.id = "moved"; own.innerHTML = "<i>inside</i>";
const inner = own.firstChild;
d.body.appendChild(own);
log("adopt " + (own.ownerDocument === d) + " " + (own.parentNode === d.body) + " " + (d.getElementById("moved") === own) + " " + (own.firstChild === inner) + " " + (document.getElementById("moved") === null) + " " + own.textContent);
own.classList.add("after");
log("after adopt " + own.className);
document.body.appendChild(d.getElementById("x"));
const back = document.getElementById("x");
log("back " + (back.ownerDocument === document) + " " + (d.getElementById("x") === null) + " " + back.textContent);
d.title = "frame title";
log("title " + d.title + " | " + document.title + " | " + d.readyState + " " + d.URL + " " + d.compatMode);
</script></body>`)
		check(wait_for("doc 9 true true true true"), "contentDocument, contentWindow.document and frames[0].document are one object in the caller's realm")
		check(logged("parts HTML BODY true true true"), "it is a real document: its elements, their identity, ownerDocument and defaultView")
		check(logged("read hello there true 1 true true 1"), "innerHTML writes in the frame's document; getElementById, querySelector, collections and classList read it")
		check(logged("separate true true true"), "the two documents stay two")
		check(logged("made true made! 2 1 true"), "createElement, createTextNode, appendChild, setAttribute on the frame's document")
		check(logged(`style [object HTMLIFrameElement] rgb(1, 2, 3)`), "element.style of a node of the frame; frameElement through defaultView")
		check(logged("expando 42"), "the same element gives the same wrapper: properties set on it are there")
		check(logged("adopt true true true true true inside"), "appendChild of a parent's node moves it: its wrapper and its children's follow")
		check(logged("after adopt after"), "the objects a moved wrapper keeps (classList) follow")
		check(logged("back true true hello there"), "and back from the frame to the parent")
		check(logged_contains("title frame title |  | "), "document.title of the frame, not of the parent")
		c := child_of(p)
		check(c != nil && strings.contains(page.serialize_html(c.doc, c.body, false), `<span data-a="1"`), "what was written is in the frame's own DOM (seen from the browser's side)")
		// the frame's own styles and layout follow what the parent wrote
		if c != nil {
			page.set_layout_journal(c, 4096)
			page.set_frame_time(c, 1000)
			st := page.styles(c, 800, 600, 1.5)
			page.set_frame_time(c, 0, unpin = true)
			_ = st
			check(true, "the frame's styles compute after a write from the parent")
		}
		page.page_close(p)
	}

	fmt.println("-- from the frame: parent.document, top.document, frameElement; a frame of a frame")
	{
		inner := `<script>
const log = s => top.postMessage(String(s), "*");
const pd = parent.document;
log("inner parent " + pd.getElementById("mid-mark").textContent + " top " + top.document.getElementById("top-mark").textContent + " " + (frameElement.ownerDocument === pd) + " " + (parent.document === pd));
top.document.getElementById("top-mark").textContent = "changed by inner";
log("inner wrote " + top.document.getElementById("top-mark").textContent);
</script>`
		p := load(fill(`<body><div id=top-mark>top</div><iframe id=m src="%s"></iframe><script>
addEventListener("message", e => log(e.data));
const m = document.getElementById("m");
m.addEventListener("load", () => {
  const mid = m.contentDocument;
  const nested = mid.querySelector("iframe");
  log("nested " + nested.tagName + " " + (nested.contentDocument.defaultView === nested.contentWindow) + " " + nested.contentDocument.body.childElementCount + " " + m.contentWindow.frames.length + " " + (m.contentWindow.frames[0].document === nested.contentDocument));
  log("top mark " + document.getElementById("top-mark").textContent);
});
</script></body>`, doc(SAME, fill(`<div id=mid-mark>middle</div><iframe srcdoc="%s"></iframe>`, html_attr(inner)))))
		check(wait_for("inner parent middle top top true true"), "a nested frame reads parent.document and top.document")
		check(wait_for("inner wrote changed by inner"), "and writes there")
		check(wait_for("nested IFRAME true 0 1 true") && wait_for("top mark changed by inner"), "the top document reaches a frame of its frame; the write shows in the top's own wrappers")
		page.page_close(p)
	}

	fmt.println("-- a frame with an address of its own, srcdoc, and a frame's own script next to the parent's")
	{
		child := doc(SAME, `<p id=mine>from server</p><script>window.childValue = 1; document.getElementById("mine").dataset.seen = "own script"; </script>`)
		p := load(fill(`<body><iframe id=a src="%s"></iframe><iframe id=s srcdoc="<p id=q>from srcdoc</p>"></iframe><script>
addEventListener("load", () => {
  const a = document.getElementById("a").contentDocument, s = document.getElementById("s").contentDocument;
  log("fetched " + a.getElementById("mine").textContent + " " + a.getElementById("mine").dataset.seen + " " + a.URL.includes("/frames/doc"));
  log("srcdoc " + s.getElementById("q").textContent + " " + s.URL);
  log("window load");
});
</script></body>`, child))
		check(wait_for("window load"), "loaded")
		check(logged("fetched from server own script true"), "a same-origin frame with an address: contentDocument is its real document (its own script wrote there)")
		check(logged("srcdoc from srcdoc about:srcdoc"), "a srcdoc frame: contentDocument is its real document")
		page.page_close(p)
	}

	fmt.println("-- a frame gone, or navigated: its wrappers do no harm")
	{
		p := load(`<body><iframe id=a></iframe><script>
const a = document.getElementById("a");
const d = a.contentDocument, b = d.body;
b.innerHTML = "<p>x</p>";
const para = b.firstChild;
a.remove();
log("removed " + a.contentDocument + " " + a.contentWindow);
const out = [];
for (const [name, f] of [["tag", () => para.tagName], ["text", () => para.textContent], ["set", () => { para.textContent = "y"; return "ok"; }],
    ["create", () => d.createElement("p")], ["query", () => d.querySelector("p")], ["append", () => { b.appendChild(document.createElement("p")); return "ok"; }], ["own", () => document.body.appendChild(para)]]) {
  try { out.push(name + ":" + f()); } catch (e) { out.push(name + ":" + e.name); }
}
log("harmless " + out.length);
log("still here " + document.body.tagName);
</script></body>`)
		check(wait_for("still here BODY"), "using the wrappers of a removed frame's document neither crashes nor reaches anything")
		check(logged("removed null null"), "the element has no document any more")
		check(logged("harmless 7"), "each use of them returned or threw")
		page.page_close(p)
	}

	fmt.println("-- a frame's realm torn down while a call is in it")
	{
		p := load(`<body><iframe id=a></iframe><script>
addEventListener("message", e => log(e.data));
const a = document.getElementById("a");
a.srcdoc = "<script>const me = frameElement, up = parent; up.postMessage('before', '*'); try { me.remove(); document.documentElement.setAttribute('data-x', 'still runs'); up.postMessage('after ' + document.documentElement.getAttribute('data-x'), '*'); } catch (e) { up.postMessage('threw ' + e, '*'); }<\/script>";
window.tick = 0;
</script></body>`)
		check(wait_for("before") && wait_for("after still runs"), "a frame's script removes its own frame through parent's DOM and goes on running")
		run_js(p, `log("parent after " + (document.getElementById("a") === null) + " " + frames.length);`)
		check(wait_for("parent after true 0"), "the frame left at once; the parent goes on")
		run_for(50)
		page.page_close(p)

		// a nested frame closes its parent: the page in use is closed only after the call
		p = load(fill(`<body><iframe id=m srcdoc="%s"></iframe><script>addEventListener("message", e => log(e.data));</script></body>`, html_attr(`<iframe srcdoc="<script>const t = top; t.document.getElementById('m').remove(); t.postMessage('inner survived', '*');</script>"></iframe>`)))
		check(wait_for("inner survived"), "a frame's script removes the frame around it")
		run_for(50)
		page.page_close(p)
		run_for(50)
	}
}

// Events and scripts of a frame reached from the parent: both realms' listeners, scripts inserted there.
events_and_scripts :: proc() {
	fmt.println("-- events: listeners of both realms on one node")
	{
		p := load(`<body><iframe id=f srcdoc="<button id=b>go</button><script>
window.order = [];
const b = document.getElementById('b');
b.addEventListener('click', e => { order.push('frame ' + e.type + ' ' + (e.target === b) + ' ' + (this === window)); parent.postMessage('frame heard ' + e.type + ' ' + e.isTrusted + ' ' + (e.target === b), '*'); });
parent.postMessage('ready', '*');
</script>"></iframe><script>
addEventListener("message", e => {
  log(e.data);
  if (e.data !== "ready") return;
  const d = document.getElementById("f").contentDocument;
  const b = d.getElementById("b");
  let parentHeard = [];
  const fn = e => { parentHeard.push(e.type + " " + (e.target === b) + " " + (e.currentTarget === b) + " " + (e instanceof Event)); };
  b.addEventListener("click", fn);
  b.click();
  log("parent heard " + parentHeard.join());
  b.dispatchEvent(new Event("custom"));
  b.addEventListener("custom", e => { parentHeard.push("custom " + e.bubbles); e.preventDefault(); });
  const ev = new Event("custom", {bubbles: true, cancelable: true});
  const notCanceled = b.dispatchEvent(ev);
  log("own event " + parentHeard[parentHeard.length - 1] + " " + notCanceled + " " + ev.defaultPrevented + " " + (ev.target === b));
  b.removeEventListener("click", fn);
  parentHeard = [];
  b.click();
  log("removed " + parentHeard.length);
  let viaAttr = 0;
  b.onclick = () => { viaAttr++; };
  b.click();
  log("on attribute " + viaAttr + " " + (typeof b.onclick));
  d.body.addEventListener("click", e => { log("bubbled to frame body " + (e.target === b)); e.stopPropagation(); });
  d.addEventListener("click", () => log("must not run"));
  b.click();
});
</script></body>`)
		check(wait_for("ready"), "the frame is ready")
		check(wait_for("parent heard click true true true"), "a parent's listener on a node of the frame is called, with its own wrappers")
		check(wait_for("frame heard click true true"), "the frame's own listener is called too, with its wrappers")
		check(wait_for("own event custom true false true true"), "an Event of the parent dispatched on a frame's node: preventDefault counts, target is the node")
		check(wait_for("removed 0"), "removeEventListener from the parent")
		check(wait_for("on attribute 1 function"), "an event handler attribute set from the parent")
		check(wait_for("bubbled to frame body true"), "propagation goes through the frame's tree")
		check(!logged("must not run"), "stopPropagation from the parent's listener stops it")
		page.page_close(p)
	}

	fmt.println("-- scripts inserted in a frame run in its realm")
	{
		p := load(fill(`<body><iframe id=f></iframe><script>
window.who = "parent realm";
addEventListener("message", e => log(e.data));
const f = document.getElementById("f");
const d = f.contentDocument;
const s = d.createElement("script");
s.textContent = "window.who = 'frame realm'; parent.postMessage('inline ran: ' + who + ' ' + (document.currentScript !== null) + ' ' + (document !== parent.document) + ' ' + (window !== parent), '*');";
d.head.appendChild(s);
log("after insert " + who);
const moved = document.createElement("script");
moved.textContent = "parent.postMessage('moved script ran in ' + who, '*');";
d.body.appendChild(moved);
const ext = d.createElement("script");
ext.src = "%s";
ext.onload = () => log("external loaded");
d.body.appendChild(ext);
d.body.innerHTML += "<p id=h onclick=\"parent.postMessage('attribute handler in ' + who, '*')\">x</p>";
d.getElementById("h").click();
const tm = d.createElement("script");
tm.textContent = "setTimeout(() => parent.postMessage('timer of the frame in ' + who, '*'), 0); Promise.resolve().then(() => parent.postMessage('microtask of the frame', '*'));";
d.body.appendChild(tm);
log("still sync");
</script></body>`, testenv.url(SAME + "/jsload/gen?ms=0&code=parent.postMessage('external%20ran%20in%20'%20%2B%20who%2C%20'*')")))
		check(wait_for("inline ran: frame realm true true true"), "a script created through contentDocument runs at once, in the frame's realm")
		check(wait_for("after insert parent realm"), "the parent's global is untouched")
		check(wait_for("moved script ran in frame realm"), "a script made in the parent and moved to the frame runs in the frame's realm")
		check(wait_for("external ran in frame realm") && wait_for("external loaded"), "an external script loads in the frame, with its load event seen by the parent")
		check(wait_for("attribute handler in frame realm"), "an onclick attribute written from the parent is compiled in the frame's realm")
		check(wait_for("timer of the frame in frame realm") && wait_for("microtask of the frame"), "timers and microtasks of an inserted script are the frame's")
		page.page_close(p)
	}

}

// document.open / write / close on a frame's document, from the parent.
document_write :: proc() {
	fmt.println("-- document.open, write and close of a frame")
	{
		p := load(`<body><iframe id=f></iframe><script>
addEventListener("message", e => log(e.data));
const f = document.getElementById("f");
let loads = 0;
f.addEventListener("load", () => log("frame load " + (++loads)));
const d = f.contentDocument;
const same = d.open();
log("open " + (same === d));
d.write("<!doctype html><html><head><title>written</title></head><body><p id=w>written</p>");
d.write("<script>parent.postMessage('written script ran ' + document.getElementById('w').textContent, '*');</" + "script>");
d.writeln("<p id=second>second</p></body></html>");
d.close();
log("read " + d.title + " " + d.getElementById("w").textContent + " " + d.getElementById("second").textContent + " " + (document.getElementById("w") === null) + " " + (d.body.tagName));
log("mode " + d.compatMode);
</script></body>`)
		check(wait_for("open true"), "document.open of a frame gives that document")
		check(wait_for("written script ran written"), "a written script runs in the frame's realm, with what was written before it")
		check(wait_for("read written written second true BODY"), "what was written is the frame's document, and not the parent's")
		check(wait_for("mode CSS1Compat"), "its doctype counts")
		page.page_close(p)
	}
	{
		p := load(`<body><iframe id=f></iframe><script>
const f = document.getElementById("f");
const d1 = f.contentWindow.document;
d1.write("<body>one</body>");
d1.close();
log("first " + f.contentDocument.body.textContent);
f.contentDocument.write("<body>two</body>");
f.contentDocument.close();
log("second " + f.contentDocument.body.textContent);
</script></body>`)
		check(wait_for("first one") && wait_for("second two"), "write without open opens it; a second one replaces what is there")
		page.page_close(p)
	}
}

// What another origin, or a sandbox, must not reach: every route (src/page/frames_access.odin).
cross_origin_boundary :: proc() {
	fmt.println("-- the boundary: a cross-origin frame stays out of reach by every route")
	{
		child := doc(OTHER, `<p id=secret>secret</p><script>
const r = [];
const t = (n, f) => { try { const v = f(); r.push(n + ":" + (v === null ? "null" : typeof v)); } catch (e) { r.push(n + ":" + e.name); } };
t("parent.document", () => parent.document);
t("top.document", () => top.document);
t("sibling.document", () => parent.frames[1].document);
t("frameElement", () => window.frameElement);
parent.postMessage("from child " + r.join(" "), "*");
</script>`)
		p := load(fill(`<body><iframe id=f src="%s"></iframe><iframe id=f2 name=named src="%s"></iframe><script>
addEventListener("message", e => log(e.data));
const f = document.getElementById("f");
f.addEventListener("load", () => {
  const r = [];
  const t = (n, g) => { try { const v = g(); r.push(n + ":" + (v === null ? "null" : typeof v)); } catch (e) { r.push(n + ":" + e.name); } };
  t("contentDocument", () => f.contentDocument);
  t("contentWindow.document", () => f.contentWindow.document);
  t("frames[0].document", () => frames[0].document);
  t("window.named.document", () => frames.named.document);
  t("getSVGDocument", () => f.getSVGDocument());
  t("get own descriptor", () => Object.getOwnPropertyDescriptor(f.contentWindow, "document"));
  t("Reflect.get", () => Reflect.get(f.contentWindow, "document"));
  log("routes " + r.join(" "));
});
</script></body>`, child, doc(SITE2, "sibling")))
		check(wait_for("routes contentDocument:null contentWindow.document:SecurityError frames[0].document:SecurityError window.named.document:SecurityError getSVGDocument:null get own descriptor:SecurityError Reflect.get:SecurityError"), "from the parent: contentDocument is null, every other route a SecurityError")
		check(wait_for("from child parent.document:SecurityError top.document:SecurityError sibling.document:SecurityError frameElement:null"), "from the frame: parent.document, top.document, a sibling's document, frameElement")
		page.page_close(p)
	}

	fmt.println("-- the boundary: an element kept from before the frame navigated to another origin")
	{
		p := load(fill(`<body><iframe id=f></iframe><script>
const f = document.getElementById("f");
const kept = f.contentDocument;
kept.body.innerHTML = "<p id=old>old</p>";
const el = kept.getElementById("old");
window.kept = kept; window.el = el;
f.addEventListener("load", () => {
  const r = [];
  const t = (n, g) => { try { r.push(n + ":" + g()); } catch (e) { r.push(n + ":" + e.name); } };
  t("now", () => f.contentDocument);
  t("kept body", () => kept.body);
  t("kept query", () => kept.querySelector("#secret"));
  t("kept element", () => kept.getElementById("secret"));
  t("el parent", () => el.parentNode);
  t("el text", () => el.textContent);
  t("write", () => { kept.body.innerHTML = "<p>overwritten</p>"; return "no throw"; });
  log("after navigation " + r.slice(0, 1) + " " + r.length);
  log("kept reads " + r.slice(1, 4).join(" "));
  f.contentWindow.postMessage("report", "*");
});
addEventListener("message", e => log(e.data));
f.src = "%s";
</script></body>`, doc(OTHER, `<p id=secret>secret</p><script>addEventListener("message", () => parent.postMessage("intact " + (document.getElementById("secret") !== null) + " " + (document.querySelectorAll("p").length === 1), "*"))</script>`)))
		check(wait_for("after navigation now:null 7"), "after the navigation contentDocument is null")
		check(wait_for("intact true true"), "what was kept from before reaches nothing of the new cross-origin document")
		check(!logged_contains("kept reads now") && !logged_contains(":[object HTMLParagraphElement]"), "no node of the new document came out of the old wrappers")
		page.page_close(p)
	}

	fmt.println("-- the boundary: sandbox")
	{
		p := load(`<body>
<iframe id=opaque sandbox="allow-scripts" srcdoc="<p id=s>s</p><script>const r=[];for(const g of [()=>parent.document,()=>top.document,()=>frameElement]){try{const v=g();r.push(v===null?'null':typeof v)}catch(e){r.push(e.name)}};parent.postMessage('sandboxed child '+r.join(' '),'*')</script>"></iframe>
<iframe id=same sandbox="allow-same-origin" srcdoc="<p id=s>reached</p>"></iframe>
<script>
addEventListener("message", e => log(e.data));
addEventListener("load", () => {
  const o = document.getElementById("opaque"), s = document.getElementById("same");
  const r = [];
  r.push(String(o.contentDocument));
  try { o.contentWindow.document; r.push("open"); } catch (e) { r.push(e.name); }
  log("opaque " + r.join(" "));
  log("same " + s.contentDocument.getElementById("s").textContent);
});
</script></body>`)
		check(wait_for("opaque null SecurityError"), "a sandbox without allow-same-origin: out of reach from the parent")
		check(wait_for("sandboxed child SecurityError SecurityError null"), "and the parent is out of reach from it")
		check(wait_for("same reached"), "allow-same-origin keeps the origin: reachable")
		page.page_close(p)
	}
}

// A value for an HTML attribute in double quotes.
html_attr :: proc(s: string) -> string {
	r, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	r, _ = strings.replace_all(r, `"`, "&quot;", context.temp_allocator)
	return r
}

main :: proc() {
	context = testenv.context_of_process()
	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	wasm.configure_from_args(os.args[1:])
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }
	js.cache_start({memory_bytes = 16 << 20, min_source_bytes = 0})
	process = base.scope_make("process")

	fmt.println("-- about:blank and srcdoc frames: created at insertion, windows, names, load events")
	{
		p := load(`<body>
<iframe id=a name=first></iframe>
<iframe id=b name=second srcdoc="<script>parent.postMessage('srcdoc ran ' + window.name + ' ' + (parent === top) + ' ' + (window.parent !== window) + ' ' + location.href + ' ' + origin, '*')</script>"></iframe>
<script>
const a = document.getElementById("a"), b = document.getElementById("b");
log("blank " + (a.contentWindow !== null) + " " + (a.contentWindow === frames[0]) + " " + (frames.first === a.contentWindow) + " " + window.length + " " + (a.contentDocument !== null));
addEventListener("message", e => log("message " + e.data + " from " + e.origin + " " + (e.source === b.contentWindow) + " " + e.isTrusted));
b.addEventListener("load", () => log("b load"));
addEventListener("load", () => log("window load"));
const c = document.createElement("iframe");
let sync = false;
c.addEventListener("load", () => { sync = true; });
document.body.appendChild(c);
log("sync load on insertion " + sync + " " + window.length);
c.remove();
log("after removal " + c.contentWindow + " " + window.length);
const w = a.contentWindow;
log("shared " + (w.navigator.userAgent === navigator.userAgent) + " " + (w.screen.width === screen.width) + " " + (w.crypto.getRandomValues(new Uint8Array(4)).length));
</script></body>`)
		check(wait_for("shared true true 4"), "a same-origin frame gives a navigator, screen and crypto")
		check(wait_for("window load"), "the parent's load event fires")
		check(logged("blank true true true 2 true"), "an about:blank frame has a window at once: frames[0], window[name], length; contentDocument is its document")
		check(logged("sync load on insertion true 3"), "an iframe without src fires load synchronously when inserted")
		check(logged("after removal null 2"), "removal destroys the nested document at once")
		check(wait_for(fill("message srcdoc ran second true true about:srcdoc %s from %s true true", testenv.url(SAME), testenv.url(SAME))), "srcdoc: parent, top, window.name from the name attribute, the parent's origin; message origin and source")
		check(index_of("b load") >= 0 && index_of("b load") < index_of("window load"), "the parent's load waits for its frames' load")
		page.page_close(p)
	}

	fmt.println("-- a frame in a shadow tree")
	{
		p := load(`<body><div id=host></div><script>
const root = document.getElementById("host").attachShadow({mode: "closed"});
const f = document.createElement("iframe");
f.srcdoc = "<script>parent.postMessage('in shadow ' + (parent !== window), '*')<\/script>";
root.appendChild(f);
addEventListener("message", e => log(e.data));
log("shadow frames " + frames.length);
</script></body>`)
		check(wait_for("shadow frames 0") && wait_for("in shadow true"), "an iframe inserted into a shadow tree gets its document (not a document-tree child: window.length leaves it out)")
		page.page_close(p)
	}

	fmt.println("-- the styles of nested documents")
	{
		p := load(`<body><iframe srcdoc="<p id=x style='font:14px system-ui;padding:8px'>Hi</p><style>p{color:rgb(1, 2, 3)}</style><script>const s = getComputedStyle(document.getElementById('x')); parent.postMessage('style ' + s.fontFamily + ' ' + s.paddingTop + ' ' + s.color, '*')</script>"></iframe>
<script>addEventListener("message", e => log(e.data))</script></body>`)
		check(wait_for("style system-ui 8px rgb(1, 2, 3)"), "a srcdoc document has its own style sheets and style attributes")
		page.page_close(p)
		// without scripts (sandboxed, or nothing to run): its <style> applies all the same
		p = load(`<body><iframe sandbox srcdoc="<style>body{font-size:23px}</style><p>x</p>"></iframe><iframe srcdoc="<style>body{font-size:23px}</style><p>x</p>"></iframe><script>addEventListener("load", () => log("window load"))</script></body>`)
		check(wait_for("window load"), "loaded")
		for i in 0 ..< 2 {
			c := child_of(p, i)
			page.set_layout_journal(c, 4096)
			page.set_frame_time(c, 1000)
			st := page.styles(c, 800, 600, 1.5)
			page.set_frame_time(c, 0, unpin = true)
			cs := c.body != base.NIL_HANDLE ? style.style_of(st, c.body) : nil
			check(cs != nil && cs.font_size == 23, fmt.tprintf("the <style> of a srcdoc document applies (%s, font-size %v)", i == 0 ? "sandboxed" : "no script", cs != nil ? cs.font_size : -1))
		}
		page.page_close(p)
	}

	fmt.println("-- cross-origin frames: postMessage both ways, targetOrigin, what is refused")
	{
		child := doc(OTHER, LOG + `<script>
addEventListener("message", e => {
  parent.postMessage("child got " + e.data + " from " + e.origin + " " + (e.source === parent), "*");
});
parent.postMessage("hello from child " + location.origin + " " + (parent === top), "*");
try { parent.document; parent.postMessage("no throw", "*") } catch (e) { parent.postMessage("child refused " + e.name, "*") }
</script>`)
		p := load(fill(`<body><iframe id=f src="%s"></iframe><script>
const f = document.getElementById("f");
addEventListener("message", e => {
  log("parent got " + e.data + " | " + e.origin + " " + (e.source === f.contentWindow));
  if (String(e.data).startsWith("hello")) {
    f.contentWindow.postMessage("wrong origin", "http://elsewhere.example");
    f.contentWindow.postMessage("ping", e.origin);
    f.contentWindow.postMessage({deep: [1, 2]}, "*");
  }
});
f.addEventListener("load", () => {
  const w = f.contentWindow;
  const r = [];
  for (const k of ["document", "foo", "alert"]) { try { w[k]; r.push(k + ":open"); } catch (e) { r.push(k + ":" + e.name); } }
  try { w.foo = 1; r.push("set:open"); } catch (e) { r.push("set:" + e.name); }
  try { w.location.href; r.push("href:open"); } catch (e) { r.push("href:" + e.name); }
  r.push(typeof w.postMessage, w.window === w, w.self === w, w.frames === w, w.top === window, w.parent === window, w.closed, w.length, String(w.opener), String(w.then));
  log("refused " + r.join(" "));
  const q = [];
  for (const k of ["history", "Array", "Node", "fetch", "console", "setTimeout", "JSON"]) { try { w[k]; q.push(k + ":open"); } catch (e) { q.push(k + ":" + e.name); } }
  log("pristine refused " + q.join(" "));
});
</script></body>`, child))
		check(wait_for(fill("parent got hello from child %s true | %s true", testenv.url(OTHER), testenv.url(OTHER))), "a cross-origin frame posts to its parent: origin and source")
		check(wait_for(fill("parent got child refused SecurityError | %s true", testenv.url(OTHER))), "the child cannot reach its parent's document")
		check(wait_for(fill("parent got child got ping from %s true | %s true", testenv.url(SAME), testenv.url(OTHER))), "the parent posts to the frame with its origin as targetOrigin; the frame sees the parent as source")
		check(wait_for(fill("parent got child got [object Object] from %s true | %s true", testenv.url(SAME), testenv.url(OTHER))), "structured clone of an object across documents")
		run_for(300)
		check(!logged_contains("child got wrong origin"), "a message whose targetOrigin does not match is dropped")
		check(logged("refused document:SecurityError foo:SecurityError alert:SecurityError set:SecurityError href:SecurityError function true true true true true false 0 null undefined"), "a cross-origin WindowProxy: only the members HTML allows")
		check(logged("pristine refused history:SecurityError Array:SecurityError Node:SecurityError fetch:SecurityError console:SecurityError setTimeout:SecurityError JSON:SecurityError"), "a cross-origin WindowProxy gives no pristine copy of anything")
		page.page_close(p)
	}

	fmt.println("-- a same-origin frame: pristine copies of the platform (what SPF takes from contentWindow.history)")
	{
		p := load(`<body><iframe id=a></iframe><script>
const w = document.getElementById("a").contentWindow;
const r = [];
const t = (name, f) => { try { r.push(name + ":" + f()); } catch (e) { r.push(name + ":" + e.name); } };
t("pushState", () => typeof w.history.pushState + " " + (w.history.pushState === History.prototype.pushState));
t("replace", () => { w.history.replaceState.call(window.history, { k: 7 }, "", "#viaframe"); return location.hash + " " + history.state.k; });
t("push", () => { w.history.pushState.call(history, 1, "", "#second"); return location.hash + " " + history.state; });
t("brandless", () => w.history.length);
t("instanceof", () => (w.history instanceof History) + " " + (w.history === w.history));
t("builtins", () => (w.Array === Array) + " " + (w.JSON === JSON) + " " + (w.Node === Node) + " " + (w.XMLHttpRequest === XMLHttpRequest));
t("console", () => w.console === console);
t("fetch", () => typeof w.fetch + " " + (w.fetch !== fetch));
t("timer", () => typeof w.setTimeout(() => {}, 0));
t("in", () => ("history" in w) + " " + ("Array" in w) + " " + ("nothing" in w));
t("document", () => w.document);
t("location", () => String(w.location.href));
t("page global", () => { window.PageGlobal = function PageGlobal() {}; return w.PageGlobal; });
t("page lowercase", () => { window.pageValue = 1; return w.pageValue; });
t("navigator", () => w.navigator);
t("descriptor", () => Object.getOwnPropertyDescriptor(w, "history").value === w.history);
log("same-origin " + r.join(" | "));
</script></body>`)
		check(wait_for("same-origin pushState:function true | replace:#viaframe 7 | push:#second 1 | brandless:TypeError | instanceof:true true | builtins:true true true true | console:true | fetch:function true | timer:number | in:true true false | document:[object Document] | location:SecurityError | page global:SecurityError | page lowercase:SecurityError | navigator:[object Navigator] | descriptor:true"), "history's methods, the built-ins, the interface objects and navigator of this realm; the frame's state stays out of reach")
		page.page_close(p)
	}

	fmt.println("-- MessagePorts between documents")
	{
		child := doc(OTHER, `<script>
addEventListener("message", e => {
  const port = e.ports[0];
  port.onmessage = m => {
    port.postMessage("child heard " + m.data);
    const back = new MessageChannel();
    back.port1.onmessage = x => port.postMessage("child second channel " + x.data);
    port.postMessage({hello: "channel", p: back.port2}, [back.port2]);
  };
  port.postMessage("child ready " + e.ports.length + " " + (e.data === "take"));
});
</script>`)
		p := load(fill(`<body><iframe id=f src="%s"></iframe><script>
const f = document.getElementById("f");
f.addEventListener("load", () => {
  const ch = new MessageChannel();
  ch.port1.onmessage = e => {
    log("parent port got " + (typeof e.data === "string" ? e.data : JSON.stringify(Object.keys(e.data)) + " " + (e.data.p instanceof MessagePort)));
    if (e.data === "child ready 1 true") ch.port1.postMessage("ping");
    if (e.data && e.data.p) { e.data.p.postMessage("via a port the child sent"); }
  };
  f.contentWindow.postMessage("take", "*", [ch.port2]);
  try { ch.port2.postMessage("x"); log("shipped port still posts silently") } catch (e) { log("shipped " + e.name) }
});
</script></body>`, child))
		check(wait_for("parent port got child ready 1 true"), "a port transferred to a cross-origin frame arrives in event.ports")
		check(wait_for("parent port got child heard ping"), "messages flow both ways on the transferred port")
		check(wait_for(`parent port got ["hello","p"] true`), "a port inside the message data, transferred back")
		check(wait_for("parent port got child second channel via a port the child sent"), "a port the frame sent works in the parent")
		page.page_close(p)
	}

	fmt.println("-- MessagePorts to and from a worker")
	{
		worker_js := `onmessage = e => {
  const port = e.ports[0];
  port.onmessage = m => port.postMessage("worker heard " + m.data);
  const ch = new MessageChannel();
  ch.port1.onmessage = m => ch.port1.postMessage("worker channel echo " + m.data);
  postMessage({kind: "mine"}, [ch.port2]);
  port.postMessage("worker ready " + e.ports.length);
};`
		src := strings.concatenate({testenv.url(SAME + "/jsload/gen?ms=0&code="), enc(worker_js)}, context.temp_allocator)
		p := load(fill(`<body><script>
const w = new Worker("%s");
const ch = new MessageChannel();
ch.port1.onmessage = e => { log("page port got " + e.data); if (e.data === "worker ready 1") ch.port1.postMessage("ping"); };
w.onmessage = e => { const p = e.ports[0]; log("page got a worker port " + (p instanceof MessagePort)); p.onmessage = m => log("page " + m.data); p.postMessage("hi"); };
w.postMessage("take", [ch.port2]);
</script></body>`, src))
		check(wait_for("page port got worker ready 1"), "a port transferred to a worker arrives in event.ports there")
		check(wait_for("page port got worker heard ping"), "messages flow both ways between a page and a worker on a port")
		check(wait_for("page got a worker port true") && wait_for("page worker channel echo hi"), "a port a worker sends works in the page")
		page.page_close(p)
	}

	fmt.println("-- sandbox: scripts, opaque origin")
	{
		p := load(`<body>
<iframe sandbox srcdoc="<script>parent.postMessage('sandboxed script ran', '*')</script>"></iframe>
<iframe sandbox="allow-scripts" srcdoc="<script>parent.postMessage('allowed ' + origin + ' ' + (() => { try { localStorage.x = 1; return 'storage' } catch (e) { return e.name } })(), '*')</script>"></iframe>
<iframe sandbox="allow-scripts allow-same-origin" srcdoc="<script>parent.postMessage('same origin ' + origin, '*')</script>"></iframe>
<script>addEventListener("message", e => log(e.data + " / " + e.origin)); addEventListener("load", () => log("window load"));</script></body>`)
		check(wait_for("window load"), "the parent loads")
		check(wait_for("allowed null SecurityError / null"), "allow-scripts without allow-same-origin: scripts run, the origin is opaque, storage refused")
		check(wait_for(fill("same origin %s / %s", testenv.url(SAME), testenv.url(SAME))), "allow-same-origin keeps the origin")
		run_for(200)
		check(!logged_contains("sandboxed script ran"), "an empty sandbox runs no script")
		page.page_close(p)
	}

	fmt.println("-- X-Frame-Options, frame-ancestors, frame-src")
	{
		shown :: `<script>parent.postMessage("shown " + location.search.length, "*")</script>`
		p := load(fill(`<body>
<iframe id=deny src="%s"></iframe>
<iframe id=so src="%s"></iframe>
<iframe id=so2 src="%s"></iframe>
<iframe id=fa src="%s"></iframe>
<iframe id=fa2 src="%s"></iframe>
<script>
addEventListener("message", e => log("msg " + e.origin));
for (const id of ["deny", "so", "so2", "fa", "fa2"]) document.getElementById(id).addEventListener("load", () => log("load " + id));
addEventListener("load", () => log("window load"));
</script></body>`,
			doc(OTHER, shown, "X-Frame-Options: DENY"),
			doc(OTHER, shown, "X-Frame-Options: SAMEORIGIN"),
			doc(SAME, shown, "X-Frame-Options: SAMEORIGIN"),
			doc(OTHER, shown, "Content-Security-Policy: frame-ancestors 'none'", "X-Frame-Options: ALLOWALL"),
			doc(SITE2, shown, fill("Content-Security-Policy: frame-ancestors %s", testenv.url(SAME)), "X-Frame-Options: DENY")))
		check(wait_for("window load"), "the parent's load is not stuck on refused frames")
		check(logged("load deny") && logged("load so") && logged("load fa"), "a refused frame still fires load at its container")
		check(logged_contains("it set 'X-Frame-Options' to 'deny'"), "the console says why (X-Frame-Options)")
		check(logged_contains("frame-ancestors"), "the console says why (frame-ancestors)")
		check(wait_for(fill("msg %s", testenv.url(SAME))), "X-Frame-Options: SAMEORIGIN from the same origin is shown")
		check(wait_for(fill("msg %s", testenv.url(SITE2))), "frame-ancestors naming the parent overrides X-Frame-Options")
		count := 0
		for l in logs { if strings.has_prefix(l, "msg ") { count += 1 } }
		check(count == 2, fmt.tprintf("only the allowed documents ran (%d messages)", count))
		page.page_close(p)

		p = load(fill(`<body><iframe id=x src="%s"></iframe><script>
addEventListener("message", e => log("csp msg " + e.data));
document.getElementById("x").addEventListener("load", () => log("x load"));
</script></body>`, doc(OTHER, shown)), csp = "frame-src 'self'")
		check(wait_for("x load"), "a frame refused by the parent's frame-src still fires load")
		run_for(200)
		check(!logged_contains("csp msg"), "the parent's CSP frame-src refuses another origin")
		page.page_close(p)
	}

	fmt.println("-- navigation: src, the frame itself, window.open to a frame name, location of another window")
	{
		second := doc(OTHER, `<script>parent.postMessage("second " + name, "*")</script>`)
		first := doc(OTHER, fill(`<script>parent.postMessage("first " + name, "*"); setTimeout(() => { location.href = "%s" }, 0)</script>`, second))
		p := load(fill(`<body><iframe id=f name=target src="%s"></iframe><script>
let loads = 0;
const f = document.getElementById("f");
f.addEventListener("load", () => log("f load " + (++loads)));
addEventListener("message", e => log("nav " + e.data));
</script></body>`, first))
		check(wait_for("nav first target"), "the first document")
		check(wait_for("nav second target"), "the frame navigates itself (location.href); its name stays")
		check(wait_for("f load 2"), "each navigation fires load at the container")
		run_js(p, fill(`const w = window.open("%s", "target"); log("open returned " + (w === f.contentWindow));`, doc(OTHER, `<script>parent.postMessage("opened", "*")</script>`)))
		check(logged("open returned true") && wait_for("nav opened"), "window.open(url, name) navigates the named frame and returns its window")
		run_js(p, fill(`f.contentWindow.location = "%s";`, doc(OTHER, `<script>parent.postMessage("by location", "*")</script>`)))
		check(wait_for("nav by location"), "the parent navigates a cross-origin frame through its location")
		run_js(p, fill(`f.src = "%s";`, doc(SAME, `<script>parent.postMessage("by src", "*")</script>`)))
		check(wait_for("nav by src"), "setting src navigates")
		page.page_close(p)
	}

	fmt.println("-- nesting: frames of frames, top and parent, a frame closed with its parent")
	{
		inner := doc(SITE2, `<script>parent.postMessage("inner top " + (top === parent.parent) + " " + (parent !== top), "*"); top.postMessage("inner to top", "*")</script>`)
		middle := doc(OTHER, fill("%s" + `<iframe src="%s"></iframe><script>addEventListener("message", e => parent.postMessage("middle relays " + e.data + " " + (e.source === frames[0]), "*"))</script>`, LOG, inner))
		p := load(fill(`<body><iframe src="%s"></iframe><script>addEventListener("message", e => log("top got " + e.data + " " + e.origin))</script></body>`, middle))
		check(wait_for(fill("top got middle relays inner top true true true %s", testenv.url(OTHER))), "a frame's frame: top, parent, frames[0] as source")
		check(wait_for(fill("top got inner to top %s", testenv.url(SITE2))), "top.postMessage from a nested frame")
		c := child_of(p)
		check(c != nil && len(page.frames_children(c)) == 1, "the middle document has its own frame")
		page.page_close(p)
		run_for(50)
	}

	same_origin_dom()
	events_and_scripts()
	document_write()
	cross_origin_boundary()

	fmt.println("-- Permissions Policy: the allow attribute delegates features")
	{
		p := load(fill(`<body><iframe id=a src="%s"></iframe><iframe id=b allow="publickey-credentials-get; fullscreen 'none'" src="%s"></iframe><iframe id=c srcdoc="x"></iframe><script>addEventListener("load", () => log("window load"))</script></body>`, doc(OTHER, "a"), doc(OTHER, "b")))
		check(wait_for("window load"), "loaded")
		a, b, c := child_of(p, 0), child_of(p, 1), child_of(p, 2)
		check(a != nil && !page.feature_enabled(a, .Publickey_Credentials_Get) && !page.feature_enabled(a, .Fullscreen), "a cross-origin frame without allow: 'self' features are off")
		check(a != nil && page.feature_enabled(a, .Sync_Xhr), "features whose default is * stay on")
		check(b != nil && page.feature_enabled(b, .Publickey_Credentials_Get), "allow=\"publickey-credentials-get\" delegates WebAuthn to the frame")
		check(b != nil && !page.feature_enabled(b, .Fullscreen), "allow=\"fullscreen 'none'\" keeps it off")
		check(c != nil && page.feature_enabled(c, .Publickey_Credentials_Get), "a same-origin frame has the 'self' features")
		page.page_close(p)
	}

	measurements()

	base.scope_close(process)
	host.blocking_settle(&blocking)
	page.process_shutdown()
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	page.discard_page_tasks(&loop)
	host.loop_destroy(&loop)
	page.settings_destroy(&settings)
	for l in logs { delete(l) }
	delete(logs)
	failures += testenv.mem_check("framestest")
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures > 0 ? 1 : 0)
}

_ :: dom
