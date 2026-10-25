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
log("blank " + (a.contentWindow !== null) + " " + (a.contentWindow === frames[0]) + " " + (frames.first === a.contentWindow) + " " + window.length + " " + (a.contentDocument === null));
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
</script></body>`)
		check(wait_for("window load"), "the parent's load event fires")
		check(logged("blank true true true 2 true"), "an about:blank frame has a window at once: frames[0], window[name], length; contentDocument is null (another realm)")
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
		check(wait_for("same-origin pushState:function true | replace:#viaframe 7 | push:#second 1 | brandless:TypeError | instanceof:true true | builtins:true true true true | console:true | fetch:function true | timer:number | in:true true false | document:SecurityError | location:SecurityError | page global:SecurityError | page lowercase:SecurityError | navigator:SecurityError | descriptor:true"), "history's methods, the built-ins and the interface objects of this realm; the frame's state stays out of reach")
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
	host.loop_destroy(&loop)
	page.settings_destroy(&settings)
	for l in logs { delete(l) }
	delete(logs)
	failures += testenv.mem_check("framestest")
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures > 0 ? 1 : 0)
}

_ :: dom
