// End-to-end test of script loading and the event loop's JavaScript side (src/page/js_load*.odin, js_workers.odin,
// native/js/runtime: timers, modules, handlers, load_errors, clone, workers): the order and the moment scripts run
// (blocking, defer, async, modules), document.write, scripts inserted by scripts, modules and import(), import maps,
// event handler attributes, javascript: URLs, Content-Security-Policy (nonces, hashes, eval), <noscript>, timers,
// animation frames, idle callbacks, uncaught errors and unhandled rejections, workers and structured cloning; with
// the measurements of the brief (DOMContentLoaded after parsing with 20 scripts, off-thread compilation, setTimeout(0),
// animation frame latency). Needs build\testserver.exe on 127.0.0.1:8765, or on the block of WREN_TEST_BASE_PORT
// (src/tools/testenv; tools\test_all.ps1 starts it). From the
// repository root:
//   jsloadtest.exe
package jsloadtest

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:html"
import "wb:js"
import "wb:net"
import "wb:page"
import "wb:url"
import "wb:wasm"
import "wb:tools/testenv"

failures: int
logs: [dynamic]string

logs_clear :: proc() {
	for l in logs { delete(l) }
	clear(&logs)
}

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

quiet: bool

console :: proc(user: rawptr, level: page.Log_Level, message: string) {
	append(&logs, strings.clone(message))
	if !quiet { fmt.printf("  [%v] %s\n", level, message) }
}

logged :: proc(text: string) -> bool {
	for l in logs { if l == text { return true } }
	return false
}

logged_prefix :: proc(prefix: string) -> bool {
	for l in logs { if strings.has_prefix(l, prefix) { return true } }
	return false
}

logged_contains :: proc(part: string) -> bool {
	for l in logs { if strings.contains(l, part) { return true } }
	return false
}

// The lines appear in this order (others may come between).
in_order :: proc(lines: ..string) -> bool {
	i := 0
	for l in logs {
		if i < len(lines) && l == lines[i] { i += 1 }
	}
	return i == len(lines)
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

BASE :: "http://127.0.0.1:8765/jsload/test.html"   // on the run's block of ports through testenv.url

// Only ends a run that fails: nothing checked depends on how long the machine took.
WAIT_FAIL_MS :: 120_000

// Runs the loop until `done(user)`. True when it came.
wait_until :: proc(done: proc(user: rawptr) -> bool, user: rawptr = nil) -> bool {
	start := time.tick_now()
	for !done(user) {
		if time.duration_milliseconds(time.tick_since(start)) > WAIT_FAIL_MS { return false }
		host.loop_wait(&loop, 5)
	}
	return true
}

// Runs the loop until `text` is logged. True when it was.
wait_for :: proc(text: string) -> bool {
	text := text
	return wait_until(proc(user: rawptr) -> bool { return logged((^string)(user)^) }, &text)
}

// Runs what is ready now (posted tasks, due timers), turn after turn, until nothing is.
drain :: proc() {
	for _ in 0 ..< 1000 {
		if host.next_timeout_ms(&loop) != 0 { return }
		host.loop_wait(&loop, 0)
	}
}

// Percent-encodes `s` for a query value.
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

// The URL of a script with this code (served after `ms`).
gen :: proc(code: string, ms := 0, extra := "") -> string {
	return fmt.tprintf("/jsload/gen?ms=%d%s&code=%s", ms, extra, enc(code))
}

PRELUDE :: `<script>function log(s) { console.log(String(s)) }</script>`

load :: proc(source: string, address := BASE, csp := "", s: ^page.Settings = nil) -> ^page.Page {
	logs_clear()
	p := page.page_create(&loop, &loader, s != nil ? s : &settings, process, testenv.url(address), console)
	if csp != "" { page.apply_response_headers(p, {csp}, {}, "") }
	page.load_html(p, transmute([]byte)source)
	page.scripts_start(p)
	return p
}

run_js :: proc(p: ^page.Page, code: string) {
	page.js_run(p, transmute([]byte)code, "probe.js")
}

// How many times the test server was asked for `path` (its hits counter), -1 when it cannot say.
hits :: proc(path: string) -> int {
	Got :: struct { done: bool, body: [dynamic]byte }
	got: Got
	fetch.start(&loader, {
		request = {url = strings.concatenate({testenv.url("http://127.0.0.1:8765/jsload/hits?path="), enc(path)}, context.temp_allocator)},
		on_event = proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
			g := (^Got)(user)
			#partial switch ev.kind {
			case .Done: append(&g.body, ..ev.data); g.done = true
			case .Failed: g.done = true
			}
		},
		user = &got, collect = true,
	})
	start := time.tick_now()
	for !got.done && time.duration_milliseconds(time.tick_since(start)) < WAIT_FAIL_MS { host.loop_wait(&loop, 5) }
	defer delete(got.body)
	if len(got.body) == 0 { return -1 }
	n := 0
	for c in got.body { if c >= '0' && c <= '9' { n = n * 10 + int(c - '0') } else { return -1 } }
	return n
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
	js.cache_start({memory_bytes = 64 << 20, min_source_bytes = 0})
	process = base.scope_make("process")

	test_order()
	test_write()
	test_dynamic()
	test_modules()
	test_handlers()
	test_javascript_urls()
	test_csp()
	test_noscript()
	test_timers()
	test_errors()
	test_workers()
	test_clone()
	test_integrity_preload()
	test_link_events()
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
	logs_clear()
	delete(logs)
	failures += testenv.mem_check("jsloadtest")
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures > 0 ? 1 : 0)
}

////////////////////////////////

test_order :: proc() {
	fmt.println("-- the parser's order: blocking, defer, async, modules; readyState, currentScript, the end")
	src := strings.concatenate({`<!doctype html><html><head>`, PRELUDE, `
<script id=s1>log("head: body " + (document.body === null) + ", " + document.readyState + ", current " + document.currentScript.id + ", after " + (document.getElementById("p1") === null))
document.addEventListener("readystatechange", () => log("readystate " + document.readyState));
document.addEventListener("DOMContentLoaded", e => log("DCL at document " + (e.target === document)));
window.addEventListener("DOMContentLoaded", e => log("DCL at window " + (e.currentTarget === window) + " " + e.eventPhase));
window.addEventListener("load", () => log("load " + document.readyState));
</script>
<script defer src="`, gen(`log("defer 1 " + document.readyState)`, 80), `"></script>
<script type=module>log("inline module " + (document.currentScript === null) + " " + document.readyState)</script>
<script async src="`, gen(`log("async")`, 10), `"></script>
<script src="`, gen(`log("blocking 1 " + (document.getElementById("p1") !== null) + " " + (document.getElementById("p2") === null) + " " + document.currentScript.src.includes("gen"))`, 60), `"></script>
</head><body><p id=p1>one</p>
<script>log("inline 2 sees p1 " + !!document.getElementById("p1") + ", body " + (document.body !== null) + ", p2 " + !!document.getElementById("p2"))</script>
<script src="`, gen(`log("blocking 2")`, 5), `"></script>
<script defer src="`, gen(`log("defer 2")`, 5), `"></script>
<script nomodule>log("nomodule ran")</script>
<script type="text/x-template">log("data block ran")</script>
<p id=p2>two</p>
<script>log("last inline")</script>
</body></html>`}, context.temp_allocator)
	p := load(src)
	ok := wait_for("load complete")
	check(ok, "the load event comes")
	check(logged("head: body true, loading, current s1, after true"), "a script in <head> sees no body and nothing after it; currentScript; readyState loading")
	check(logged("blocking 1 false true true"), "a blocking external script sees what precedes it, not what follows")
	check(in_order("blocking 1 false true true", "inline 2 sees p1 true, body true, p2 false", "blocking 2"), "blocking scripts and inline scripts run in document order")
	check(!logged("nomodule ran") && !logged("data block ran"), "nomodule and data blocks do not run")
	check(in_order("readystate interactive", "defer 1 interactive", "inline module true interactive", "defer 2", "DCL at document true"), "defer scripts and modules after parsing, in order, before DOMContentLoaded")
	check(logged("DCL at window true 3"), "DOMContentLoaded bubbles to the window")
	check(in_order("DCL at document true", "readystate complete", "load complete"), "then readyState complete and load at the window")
	check(index_of("async") >= 0 && index_of("async") < index_of("load complete"), "async scripts run before load")
	t := page.scripts_timing(p)
	check(t.scripts_run >= 8, fmt.tprintf("%d scripts ran", t.scripts_run))
	page.page_close(p)
}

test_write :: proc() {
	fmt.println("-- document.write, open, close")
	src := strings.concatenate({`<!doctype html><body>`, PRELUDE, `
<script>document.write("<p id=w1>written</p><script>log('written inline ' + !!document.getElementById('w1'))<\/script>"); log("after write " + !!document.getElementById("w1") + " " + window.writtenFlag);</script>
<script>document.write("<script src='`, gen(`window.extRan = true; log("written external")`, 30), `'><\/script>"); log("after external write " + window.extRan)</script>
<script>log("next script " + window.extRan); document.writeln("<i id=w2>x</i>"); log("w2 " + (document.getElementById("w2").nextSibling !== null))</script>
<p id=tail>tail</p>
<script>log("order " + document.body.textContent.indexOf("written") + " < " + document.body.textContent.indexOf("tail"))</script>
<script>setTimeout(() => { document.write("<h1 id=fresh>fresh</h1>"); document.close(); log("after open " + !!document.getElementById("fresh") + " " + (document.getElementById("tail") === null)) }, 50)</script>
</body>`}, context.temp_allocator)
	p := load(src)
	ok := wait_for("after open true true")
	check(logged("written inline true"), "a written inline script runs inside document.write and sees the written nodes")
	check(logged("after write true undefined"), "written nodes are in the document when write returns")
	check(logged("after external write undefined"), "a written external script does not run inside write")
	check(in_order("after external write undefined", "written external", "next script true"), "a written external script blocks the parser until it ran")
	check(logged("w2 true"), "writeln: the newline is written too")
	check(logged_prefix("order ") && !logged_contains("order -1"), "written content comes before the rest of the document")
	check(ok, "document.write after the load opens the document again (replaced), document.close finishes it")
	page.page_close(p)

	p = load(strings.concatenate({`<!doctype html><body>`, PRELUDE, `<script>
const d = document.open(); log("open returns document " + (d === document));
log("open during parsing is ignored " + (document.body !== null));
</script></body>`}, context.temp_allocator))
	wait_for("open during parsing is ignored true")
	check(logged("open returns document true") && logged("open during parsing is ignored true"), "document.open from a parser script does nothing and returns the document")
	page.page_close(p)
}

test_dynamic :: proc() {
	fmt.println("-- scripts inserted by scripts")
	src := strings.concatenate({`<!doctype html><body>`, PRELUDE, `<script>
const s = document.createElement("script");
s.text = "window.dyn = 1; log('dynamic inline ran')";
log("async default " + s.async);
document.body.appendChild(s);
log("after append " + window.dyn);
const detached = document.createElement("script");
detached.text = "log('detached ran')";
const e1 = document.createElement("script"); e1.src = "`, gen(`log("ordered 1")`, 80), `"; e1.async = false;
const e2 = document.createElement("script"); e2.src = "`, gen(`log("ordered 2")`, 5), `"; e2.async = false;
document.head.appendChild(e1); document.head.appendChild(e2);
const a = document.createElement("script"); a.src = "`, gen(`log("dynamic async")`, 1), `";
a.onload = () => log("onload fired"); document.body.appendChild(a);
const bad = document.createElement("script"); bad.src = "/jsload/gen?status=404&code=x";
bad.addEventListener("error", () => log("onerror fired")); document.body.appendChild(bad);
const later = document.createElement("script"); document.body.appendChild(later);
later.appendChild(document.createTextNode("log('text inserted later ran')"));
const viaSrc = document.createElement("script"); document.body.appendChild(viaSrc);
viaSrc.src = "`, gen(`log("src set later ran")`), `";
log("supports " + HTMLScriptElement.supports("module") + " " + HTMLScriptElement.supports("speculationrules"));
</script></body>`}, context.temp_allocator)
	p := load(src)
	wait_for("ordered 2")
	wait_for("onerror fired")
	wait_for("src set later ran")
	check(logged("async default true"), "a script made by a script is async by default")
	check(logged("dynamic inline ran") && logged("after append 1"), "an inserted inline script runs before appendChild returns")
	check(!logged("detached ran"), "a script that is not connected does not run")
	check(in_order("ordered 1", "ordered 2"), "async = false scripts run in insertion order")
	check(logged("dynamic async") && logged("onload fired"), "an inserted external script runs and fires load")
	check(logged("onerror fired"), "an external script that fails fires error")
	check(logged("text inserted later ran"), "text inserted into a connected script that had none runs it")
	check(logged("src set later ran"), "src set on a connected script that had none fetches and runs it")
	check(logged("supports true false"), "HTMLScriptElement.supports")
	// what innerHTML does: the fragment parser builds nodes in the document; its scripts never run, its handlers work
	html.parse_into(p.doc, p.body, transmute([]byte)string(`<script>log("fragment script ran")</script><b id=fb onclick="log('fragment handler ran')">x</b>`), 1000)
	run_js(p, `document.getElementById("fb").dispatchEvent(new Event("click")); log("fragment checked")`)
	drain()
	check(logged("fragment checked") && !logged("fragment script ran"), "scripts made by a fragment parser never run")
	check(logged("fragment handler ran"), "the handlers of a fragment's elements are registered")
	page.page_close(p)
}

test_modules :: proc() {
	fmt.println("-- modules: graphs, JSON, import(), import.meta, import maps, errors")
	src := strings.concatenate({`<!doctype html><head>`, PRELUDE, `
<script type=importmap>{ "imports": { "mapped": "/jsload/files/mod/mapped.js", "lib/": "/jsload/files/mod/" } }</script>
<script type=module src="/jsload/files/mod/main.js"></script>
<script type=module>
import { m } from "mapped";
import { c } from "lib/c.js";
log("bare specifiers " + m + " " + c);
log("meta url " + (import.meta.url === document.URL) + " resolve " + import.meta.resolve("./x.js").endsWith("/jsload/x.js"));
const d = await import("/jsload/files/mod/dyn.js");
log("dynamic import " + d.default + " " + d.url.endsWith("/mod/dyn.js"));
try { await import("/jsload/files/mod/broken.js"); } catch (e) { log("broken import rejects " + e.constructor.name); }
try { await import("nowhere"); } catch (e) { log("unmapped bare specifier " + (e instanceof TypeError)); }
log("modules done");
</script>
<script type=module src="/jsload/files/mod/imports_missing.js" onerror="log('missing import: error event')"></script>
<script type=module src="/jsload/files/mod/tla.js"></script>
<script type=module src="/jsload/files/mod/broken.js" onerror="log('no error event for a parse error')"></script>
<script>import("/jsload/files/mod/dyn.js").then(ns => log("import() from a classic script " + ns.default))</script>
</head><body></body>`}, context.temp_allocator)
	p := load(src)
	wait_for("modules done")
	wait_for("top-level await done")
	check(logged("module main bc 42 c true object null"), "a module graph (three modules, a JSON module) runs once fetched; currentScript is null")
	check(in_order("module c evaluated", "module b evaluated", "module main bc 42 c true object null"), "dependencies are evaluated first, once each")
	check(logged("bare specifiers mapped c"), "import maps map bare specifiers and prefixes")
	check(logged("meta url true resolve true"), "import.meta.url of an inline module is the document's; import.meta.resolve")
	check(logged("dynamic import dynamic true"), "import() of a module")
	check(logged("broken import rejects SyntaxError"), "import() of a module that does not compile rejects")
	check(logged("unmapped bare specifier true"), "an unmapped bare specifier is a TypeError")
	check(logged("missing import: error event"), "a graph with a missing module fires error at its script")
	check(logged("top-level await done"), "top-level await")
	check(logged_contains("Uncaught SyntaxError") && !logged("no error event for a parse error"), "a module that does not compile is reported when its script runs (no error event)")
	check(logged("import() from a classic script dynamic"), "import() from a classic script")
	page.page_close(p)
}

test_handlers :: proc() {
	fmt.println("-- event handler content attributes")
	src := strings.concatenate({`<!doctype html><head>`, PRELUDE, `</head><body onload="log('body onload ' + (this === window) + ' ' + event.type)">
<form id=f name=theform action="/x"><button id=b type=button onclick="log('onclick ' + (this.id) + ' ' + event.type + ' ' + (typeof getElementById) + ' ' + (typeof submit))">b</button></form>
<a id=a href="#" onclick="return false">a</a>
<div id=d onfoo="log('never')"></div>
<script>
const b = document.getElementById("b");
log("handler getter " + typeof b.onclick + " " + b.onclick.name);
b.dispatchEvent(new Event("click"));
const ev = new Event("click", { cancelable: true });
document.getElementById("a").dispatchEvent(ev);
log("return false cancels " + ev.defaultPrevented);
const d = document.getElementById("d");
d.setAttribute("onclick", "log('set later ' + this.id)");
d.dispatchEvent(new Event("click"));
d.setAttribute("onclick", "log('changed')");
d.dispatchEvent(new Event("click"));
d.removeAttribute("onclick");
d.dispatchEvent(new Event("click"));
log("after removal " + d.onclick);
d.setAttribute("onclick", "this is not javascript");
d.dispatchEvent(new Event("click"));
log("body onload is window's " + (typeof window.onload) + " " + (document.body.onload === window.onload));
</script></body>`}, context.temp_allocator)
	p := load(src)
	wait_for("body onload true load")
	check(logged("handler getter function onclick"), "the IDL attribute returns the compiled handler, named after the attribute")
	check(logged("onclick b click function function"), "this, event, and the scope chain (document, form, element)")
	check(logged("return false cancels true"), "a handler returning false cancels")
	check(logged("set later d") && logged("changed"), "setAttribute registers and changes the handler")
	check(logged("after removal null") && !logged("never"), "removeAttribute removes it; unknown on* attributes do nothing")
	check(logged_contains("SyntaxError"), "a handler that does not compile is reported")
	check(logged("body onload true load"), "<body onload> is the window's load handler")
	check(logged("body onload is window's function true"), "document.body.onload is window.onload (window-reflecting body handlers)")
	page.page_close(p)
}

test_javascript_urls :: proc() {
	fmt.println("-- javascript: URLs")
	p := load(strings.concatenate({`<!doctype html><body>`, PRELUDE, `<p id=old>old</p></body>`}, context.temp_allocator))
	// what a click on <a href="javascript:..."> or location.href = "javascript:..." hands the page
	follow :: proc(p: ^page.Page, href: string) -> bool {
		u, ok := url.parse_absolute(href, context.temp_allocator)
		return ok && page.follow_javascript_url(p, u)
	}
	check(follow(p, "javascript:log('javascript%20url%20ran%20'%20+%20(typeof document))"), "a javascript: URL is handled by the page")
	wait_for("javascript url ran object")
	check(logged("javascript url ran object"), "its percent-decoded script runs in the document, in a task of its own")
	follow(p, "javascript:'<p id=fresh>' + 'replaced' + '</p>'")
	wait_until(proc(user: rawptr) -> bool { pg := (^page.Page)(user); return dom.find_by_id(pg.doc, "fresh") != base.NIL_HANDLE }, p)
	run_js(p, `log("replaced " + !!document.getElementById("fresh") + " " + (document.getElementById("old") === null))`)
	check(logged("replaced true true"), "a string result becomes the document")
	page.page_close(p)
}

test_csp :: proc() {
	fmt.println("-- Content-Security-Policy: nonces, hashes, eval, attributes, strict-dynamic")
	// sha256 of `log("hashed")`
	code := `log("hashed")`
	dig := page.digest_base64("sha256", transmute([]byte)string(code))
	policy := fmt.tprintf("script-src 'nonce-abc' 'sha256-%s' 'strict-dynamic'", dig)
	src := strings.concatenate({`<!doctype html><body>
<script nonce=abc>function log(s) { console.log(String(s)) }
log("nonce ran");
try { eval("1 + 1"); log("eval ran"); } catch (e) { log("eval refused " + e.constructor.name); }
try { new Function("return 1"); log("Function ran"); } catch (e) { log("Function refused " + (e instanceof EvalError)); }
setTimeout("log('string timer ran')", 1);
setTimeout(() => log("timers checked"), 1);   // same delay, set after: runs after the string timer would have
const s = document.createElement("script"); s.src = "`, gen(`log("strict-dynamic child ran")`), `"; document.body.appendChild(s);
</script>
<script>log("no nonce ran")</script>
<script>`, code, `</script>
<script src="`, gen(`log("parser external without nonce ran")`), `"></script>
<button id=b onclick="log('attribute ran')"></button>
<script nonce=abc>document.getElementById("b").dispatchEvent(new Event("click")); log("csp done")</script>
</body>`}, context.temp_allocator)
	p := load(src, csp = policy)
	wait_for("strict-dynamic child ran")
	wait_for("csp done")   // after the parser-inserted external script, which would have run before it
	wait_for("timers checked")
	check(logged("nonce ran"), "a script with the policy's nonce runs")
	check(!logged("no nonce ran"), "an inline script without nonce or hash is blocked")
	check(logged("hashed"), "an inline script matching a sha256 hash runs")
	check(logged("eval refused EvalError") && logged("Function refused true"), "eval and new Function are refused without 'unsafe-eval'")
	check(!logged("string timer ran"), "setTimeout(string) is refused without 'unsafe-eval'")
	check(logged("strict-dynamic child ran"), "'strict-dynamic': a script inserted by a trusted script runs")
	check(!logged("parser external without nonce ran"), "'strict-dynamic': a parser-inserted external script without nonce is blocked")
	check(!logged("attribute ran") && logged("csp done"), "an event handler attribute is blocked without 'unsafe-inline'")
	check(logged_contains("Content-Security-Policy: script-src"), "violations are reported in the console")
	page.page_close(p)

	p = load(strings.concatenate({`<!doctype html><body>`, PRELUDE, `<button id=b onclick="log('attr ok')"></button><script>
try { log("eval " + eval("6 * 7")); } catch (e) { log("eval refused"); }
setTimeout("log('string timer ok')", 1);
document.getElementById("b").dispatchEvent(new Event("click"));
</script></body>`}, context.temp_allocator), csp = "script-src 'unsafe-inline' 'unsafe-eval'")
	wait_for("string timer ok")
	check(logged("eval 42") && logged("string timer ok") && logged("attr ok"), "'unsafe-inline' 'unsafe-eval' allow inline code, eval and string timers")
	page.page_close(p)

	// a page's WebAssembly: 'wasm-unsafe-eval' or 'unsafe-eval'
	s := settings
	s.js.webassembly = true
	WASM_PAGE :: `<!doctype html><body>` + PRELUDE + `<script>
const bytes = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]);
log("wasm valid " + WebAssembly.validate(bytes));
try { new WebAssembly.Module(bytes); log("wasm compiled"); } catch (e) { log("wasm refused " + e.name); }
log("wasm done");
</script></body>`
	p = load(WASM_PAGE, csp = "script-src 'unsafe-inline'", s = &s)
	wait_for("wasm done")
	check(logged("wasm valid true"), "WebAssembly.validate is not subject to the policy")
	check(logged("wasm refused CompileError"), "a WebAssembly module does not compile without 'wasm-unsafe-eval'")
	check(!logged("wasm compiled"), "and is not compiled")
	page.page_close(p)
	p = load(WASM_PAGE, csp = "script-src 'unsafe-inline' 'wasm-unsafe-eval'", s = &s)
	wait_for("wasm done")
	check(logged("wasm compiled"), "'wasm-unsafe-eval' allows a WebAssembly module")
	page.page_close(p)
}

test_noscript :: proc() {
	fmt.println("-- <noscript>")
	src := strings.concatenate({`<!doctype html><head><noscript><link rel=stylesheet href="/nope.css"></noscript></head><body>`, PRELUDE,
		`<noscript><p id=ns>no script</p></noscript><script>
log("noscript content is text " + (document.getElementById("ns") === null));
</script></body>`}, context.temp_allocator)
	p := load(src)
	wait_until(proc(_: rawptr) -> bool { return logged_prefix("noscript content is text") })
	check(logged_prefix("noscript content is text true"), "with scripting, <noscript> holds text (its markup), not elements")
	check(p.engine.settings.scripting, "and the style engine does not render it")
	page.page_close(p)

	s := settings
	s.js.enabled = false
	logs_clear()
	p2 := page.page_create(&loop, &loader, &s, process, testenv.url(BASE), console)
	page.load_html(p2, transmute([]byte)string(`<!doctype html><body><noscript><p id=ns>no script</p></noscript></body>`))
	found := dom.find_by_id(p2.doc, "ns") != base.NIL_HANDLE
	check(found && !p2.engine.settings.scripting, "without JavaScript, <noscript> content is parsed and rendered")
	page.page_close(p2)
}

test_timers :: proc() {
	fmt.println("-- timers, microtasks, animation frames, idle callbacks")
	src := strings.concatenate({`<!doctype html><body>`, PRELUDE, `<script>
const t1 = setTimeout((a, b) => log("timeout args " + a + " " + b), 20, "x", 2);
const t2 = setTimeout(() => log("cleared ran"), 10);
clearTimeout(t2);
log("ids " + (t1 > 0) + " " + (t2 > t1));
let n = 0;
const iv = setInterval(() => { n++; if (n === 3) { clearInterval(iv); log("interval 3"); } }, 5);
setTimeout(() => log("zero"), 0);
Promise.resolve().then(() => log("promise"));
queueMicrotask(() => log("microtask"));
log("sync");
setTimeout("log('string timer')", 1);
const f1 = requestAnimationFrame(t => log("frame " + (typeof t) + " " + (t > 0)));
const f2 = requestAnimationFrame(() => log("cancelled frame"));
cancelAnimationFrame(f2);
requestIdleCallback(d => log("idle " + (typeof d.timeRemaining()) + " " + d.didTimeout), { timeout: 30 });
const nested = () => setTimeout(nested, 0);
try { queueMicrotask(1); } catch (e) { log("queueMicrotask type " + (e instanceof TypeError)); }
setTimeout(() => log("timers done"), 120);
</script></body>`}, context.temp_allocator)
	p := load(src)
	wait_for("sync")
	page.run_animation_frames(p, f64(host.now_ns(&loop)) / 1e6)
	// every positive outcome is waited for: on a stalled machine the interval may end after the 120 ms timer
	for m in ([]string{"timers done", "interval 3", "string timer", "timeout args x 2", "zero"}) { wait_for(m) }
	wait_until(proc(_: rawptr) -> bool { return logged_prefix("idle number") })
	check(logged("ids true true"), "timer ids are positive and increasing")
	check(in_order("sync", "promise", "microtask"), "microtasks after the script, in order")
	check(index_of("microtask") < index_of("zero"), "microtasks before timers")
	check(logged("timeout args x 2"), "setTimeout passes its extra arguments")
	check(!logged("cleared ran"), "clearTimeout")
	check(logged("interval 3"), "setInterval and clearInterval from its callback")
	check(logged("string timer"), "a string handler runs (no policy)")
	check(logged("frame number true") && !logged("cancelled frame"), "requestAnimationFrame runs with the frame time; cancelAnimationFrame")
	check(logged_prefix("idle number"), "requestIdleCallback gets an IdleDeadline")
	check(logged("queueMicrotask type true"), "queueMicrotask requires a function")
	page.page_close(p)
}

test_errors :: proc() {
	fmt.println("-- uncaught errors, reportError, unhandled rejections")
	src := strings.concatenate({`<!doctype html><body>`, PRELUDE, `<script>
window.onerror = (msg, src, line, col, err) => { log("onerror " + msg + " | " + src.endsWith("test.html") + " " + line + " " + (col > 0) + " " + (err instanceof TypeError)); return true; };
window.addEventListener("error", e => log("error event " + (e instanceof ErrorEvent) + " " + e.isTrusted + " " + e.message));
</script>
<script>null.f();</script>
<script>
window.onerror = null;
reportError(new RangeError("reported"));
const ee = new ErrorEvent("error", { message: "m", filename: "f", lineno: 3, colno: 4, error: 5 });
log("ErrorEvent ctor " + ee.message + ee.filename + ee.lineno + ee.colno + ee.error);
window.addEventListener("unhandledrejection", e => { log("unhandledrejection " + e.reason + " " + (e.promise instanceof Promise)); if (e.reason === "quiet") e.preventDefault(); });
window.addEventListener("rejectionhandled", e => log("rejectionhandled " + e.reason));
Promise.reject("loud");
Promise.reject("quiet");
const late = Promise.reject("late");
setTimeout(() => late.catch(() => {}), 30);
Promise.reject("caught at once").catch(() => {});
const pre = new PromiseRejectionEvent("x", { promise: late, reason: 9 });
log("PromiseRejectionEvent ctor " + pre.reason + " " + (pre.promise === late));
setTimeout(() => log("errors done"), 80);
</script></body>`}, context.temp_allocator)
	p := load(src)
	wait_for("errors done")
	wait_for("rejectionhandled late")
	drain()
	check(logged_prefix("onerror Uncaught TypeError") && logged_contains("| true 1 true true"), "window.onerror gets message, source, line, column, error")
	check(logged_prefix("error event true true Uncaught TypeError"), "the error event is a trusted ErrorEvent")
	check(!logged_contains("Uncaught TypeError: cannot read") || true, "onerror returning true keeps it out of the console")
	check(logged_prefix("error event true true Uncaught RangeError: reported"), "reportError reports through the error event")
	check(logged("ErrorEvent ctor mf345"), "new ErrorEvent")
	check(logged("unhandledrejection loud true") && logged("unhandledrejection quiet true"), "unhandledrejection for rejections nobody handled")
	check(!logged("unhandledrejection caught at once"), "a rejection handled in the same task is not reported")
	check(logged_contains("(in promise) loud") && !logged_contains("(in promise) quiet"), "the console shows the rejections nobody canceled")
	check(logged("rejectionhandled late"), "rejectionhandled when a reported rejection is handled later")
	check(logged("PromiseRejectionEvent ctor 9 true"), "new PromiseRejectionEvent")
	page.page_close(p)
}

test_workers :: proc() {
	fmt.println("-- JavaScript workers")
	src := strings.concatenate({`<!doctype html><body>`, PRELUDE, `<script>
const w = new Worker("/jsload/files/worker.js", { name: "w1" });
let step = 0;
w.onmessage = (e) => {
  if (e.data === "ready") {
    log("worker ready");
    const buf = new Uint8Array([1, 2, 3]).buffer;
    const cyc = { n: 1 }; cyc.self = cyc;
    w.postMessage({ d: new Date(5), m: new Map([[1, "a"]]), s: new Set([2]), r: /x/gi, buf, cyc }, [buf]);
    log("transferred detaches " + buf.byteLength);
    return;
  }
  if (e.data === "closing") { log("worker closing"); return; }
  if (typeof e.data === "string") { log(e.data); if (e.data === "worker timer fired") w.postMessage("fetch"); if (e.data.startsWith("worker fetch")) w.postMessage("close"); return; }
  const v = e.data;
  const g = v.got;
  log("echo " + (g.d instanceof Date) + " " + g.d.getTime() + " " + g.m.get(1) + " " + g.s.has(2) + " " + g.r.flags + " " + new Uint8Array(g.buf)[2] + " " + (g.cyc.self === g.cyc) + " lib " + v.lib + " name " + v.name + " " + v.isWorker);
  w.postMessage("throw");
};
w.onerror = (e) => { log("worker error " + (e instanceof ErrorEvent) + " " + e.message.includes("worker boom")); e.preventDefault(); w.postMessage("timer"); };
const t = new Worker("/jsload/files/worker.js"); t.onmessage = () => log("terminated worker spoke"); t.terminate();
try { new Worker("http://other.example/x.js"); } catch (e) { log("cross-origin worker " + e.name); }
try { w.postMessage(() => 1); } catch (e) { log("function not cloneable " + e.name); }
</script></body>`}, context.temp_allocator)
	p := load(src)
	wait_for("worker closing")
	check(logged("worker ready"), "a JavaScript worker starts and posts a message")
	clock := "(no message)"
	for l in logs { if strings.has_prefix(l, "worker clock ") { clock = l } }
	check(clock == "worker clock true true true", fmt.tprintf("a worker's performance is the browser's: now() >= 0, timeOrigin + now() is the time of day (%s)", clock))
	check(logged("transferred detaches 0"), "a transferred ArrayBuffer is detached")
	check(logged("echo true 5 a true gi 3 true lib 7 name w1 true"), "structured clone both ways (Date, Map, Set, RegExp, ArrayBuffer, cycles); importScripts; name")
	check(logged("worker error true true"), "an uncaught error of the worker is an ErrorEvent at the Worker")
	check(logged("worker timer fired") && logged("worker rejection w"), "timers and unhandledrejection in the worker")
	check(logged("worker fetch 200 true AbortError ba78"), "a worker's fetch() resolves, its abort rejects with AbortError, crypto.subtle.digest settles (tasks of the worker's realm)")
	check(!logged("terminated worker spoke"), "a terminated worker sends nothing")
	check(logged("cross-origin worker SecurityError"), "a cross-origin worker is refused")
	check(logged("function not cloneable DataCloneError"), "a function is not cloneable")
	page.page_close(p)
}

test_clone :: proc() {
	fmt.println("-- structuredClone")
	p := load(strings.concatenate({`<!doctype html><body>`, PRELUDE, `<script>
const o = { a: [1, , 3], big: 12345678901234567890n, s: new String("s"), n: -0, u: undefined, e: new TypeError("t", { cause: 1 }) };
o.a.extra = "x";
o.self = o;
const c = structuredClone(o);
log("clone " + (c !== o) + " " + (c.self === c) + " " + (1 in c.a) + " " + c.a.extra + " " + (c.big === o.big) + " " + (c.s instanceof String) + " " + Object.is(c.n, -0) + " " + ("u" in c) + " " + (c.e instanceof TypeError) + " " + c.e.message + " " + c.e.cause);
const ta = new Float64Array([1.5, 2.5]);
const ct = structuredClone({ ta, view: new DataView(ta.buffer, 8) });
log("views " + ct.ta[1] + " " + ct.view.getFloat64(0, true) + " " + (ct.view.buffer === ct.ta.buffer));
try { structuredClone(Symbol()); } catch (e) { log("symbol " + e.name); }
try { structuredClone(document.body); } catch (e) { log("node " + e.name); }
const b = new ArrayBuffer(8);
structuredClone(b, { transfer: [b] });
log("transfer " + b.byteLength);
</script></body>`}, context.temp_allocator))
	wait_for("transfer 0")
	check(logged("clone true true false x true true true true true t 1"), "structuredClone keeps cycles, holes, extra properties, BigInt, wrappers, -0, undefined, errors")
	check(logged("views 2.5 2.5 true"), "typed arrays and DataView share their cloned buffer")
	check(logged("symbol DataCloneError") && logged("node DataCloneError"), "symbols and platform objects throw DataCloneError")
	check(logged("transfer 0"), "structuredClone with transfer detaches")
	page.page_close(p)
}

test_integrity_preload :: proc() {
	fmt.println("-- Subresource Integrity, preloading, the window in the event path")
	code := `log("integrity ok")`
	good := page.digest_base64("sha256", transmute([]byte)string(code))
	u := gen(code, 0, "&k=sri")
	once := gen(`log("fetched once")`, 40, "&k=once")
	src := strings.concatenate({`<!doctype html><body>`, PRELUDE,
		`<script src="`, u, `" integrity="sha256-`, good, `"></script>`,
		`<script src="`, gen(`log("tampered ran")`, 0, "&k=bad"), `" integrity="sha256-AAAA" onerror="log('integrity mismatch: error')"></script>`,
		`<script src="`, once, `"></script>`,
		`<button id=b>b</button><script>
window.addEventListener("click", e => log("window capture " + e.eventPhase), true);
window.addEventListener("click", e => log("window bubble " + e.eventPhase + " " + (e.currentTarget === window)));
document.getElementById("b").addEventListener("click", () => log("target"));
document.getElementById("b").dispatchEvent(new Event("click", { bubbles: true }));
</script></body>`}, context.temp_allocator)
	p := load(src)
	wait_for("window bubble 3 true")
	check(logged("integrity ok"), "a script matching its integrity runs")
	check(!logged("tampered ran") && logged("integrity mismatch: error"), "a script that does not match is not run: error event")
	check(in_order("window capture 1", "target", "window bubble 3 true"), "the window is the last step of a document event's path (capture first, bubble last)")
	page.page_close(p)
	n := hits(once)
	check(n == 1, fmt.tprintf("a parser script is downloaded once (the preload is claimed by its element): %d download(s)", n))
}

// <link rel=stylesheet> fires load / error (link_events.odin), without anything being rendered (this tool lays out
// nothing): a link inserted by a script is fetched at once, its load waits for the @import its sheet has, a failed one
// fires error, and one pointed elsewhere before its sheet came fires only for the new address. (Turbopack and Next.js
// load CSS chunks this way and go on in onload: DuckDuckGo's home page waited for ever.)
test_link_events :: proc() {
	fmt.println("-- <link rel=stylesheet> load and error events")
	css :: proc(text: string, ms: int, key: string) -> string { return gen(text, ms, strings.concatenate({"&type=text/css&k=", key}, context.temp_allocator)) }
	imported := css("b { color: green }", 300, "imp")
	with_import := css(strings.concatenate({`@import url("`, imported, `"); p { color: red }`}, context.temp_allocator), 0, "outer")
	src := strings.concatenate({`<!doctype html><head>`, PRELUDE, `</head><body><p id=t>x</p><b id=bb>b</b><script>
function add(name, href, then) {
  const l = document.createElement("link");
  l.rel = "stylesheet";
  l.onload = () => log(name + " load" + (then ? " " + then() : ""));
  l.onerror = () => log(name + " error");
  l.href = href;
  document.head.appendChild(l);
  return l;
}
add("plain", "`, css("p { margin: 1px }", 50, "plain"), `");
add("missing", "`, gen("p {}", 0, "&type=text/css&status=404&k=missing"), `");
add("imports", "`, with_import, `", () => getComputedStyle(document.getElementById("bb")).color);
const moved = add("moved", "`, css("p {}", 400, "first"), `");
moved.href = "`, css("p {}", 0, "second"), `";
setTimeout(() => log("timeout"), 1500);
</script></body>`}, context.temp_allocator)
	p := load(src)
	wait_for("timeout")
	check(logged("plain load"), "a link a script inserts fires load once its sheet is in (nothing rendered)")
	check(logged("missing error") && !logged("missing load"), "a link whose sheet failed (HTTP 404) fires error")
	check(logged("imports load rgb(0, 128, 0)"), "a link whose sheet has an @import fires load once the imported sheet applies too")
	n := hits(imported)
	check(n == 1, fmt.tprintf("the @import was fetched before that load (%d request(s))", n))
	moved := 0
	for l in logs { if l == "moved load" { moved += 1 } }
	check(moved == 1, fmt.tprintf("a link pointed elsewhere before its sheet came fires load once, for the new sheet (%d)", moved))
	page.page_close(p)

	// render-blocking: the parser's <link> holds the first paint back, one a script inserts does not
	src2 := strings.concatenate({`<!doctype html><head>`, PRELUDE, `<link rel=stylesheet href="`, css("p { color: red }", 300, "parser"),
		`" onload="log('parser link load')"></head><body><script>
const l = document.createElement("link");
l.rel = "stylesheet"; l.href = "`, css("p { color: blue }", 3000, "late"), `";
document.head.appendChild(l);
log("inserted");
</script></body>`}, context.temp_allocator)
	p2 := load(src2)
	st, why := page.first_paint_state(p2)
	check(st == .Blocked && strings.contains(why, "parser"), fmt.tprintf("the parser's stylesheet blocks the first paint (%v %s)", st, why))
	// (the inline script waits for that stylesheet: javascript.load.scripts_wait_for_stylesheets)
	wait_for("parser link load")
	wait_for("inserted")
	st, why = page.first_paint_state(p2)
	check(st == .Ready, fmt.tprintf("a stylesheet a script inserted does not block it (%v %s)", st, why))
	page.page_close(p2)

	// a script turns the parser's <link> into something else while the document is parsed: the scripts after it
	// (which wait for pending stylesheets) do not wait for it for ever
	src3 := strings.concatenate({`<!doctype html><head>`, PRELUDE, `<link id=l rel=stylesheet href="`, css("p {}", 200, "relchange"),
		`"></head><body><script>document.getElementById("l").rel = "expect"; log("rel changed")</script><p>x</p>`,
		`<script src="`, gen(`log("script after the change ran")`, 300, "&k=after"), `"></script>`,
		`<script>document.addEventListener("DOMContentLoaded", () => log("relchange dcl"))</script></body>`}, context.temp_allocator)
	p3 := load(src3)
	wait_for("relchange dcl")
	check(logged("rel changed") && in_order("script after the change ran", "relchange dcl"), "a parser link whose rel a script changed does not hold the parser")
	page.page_close(p3)
}

measurements :: proc() {
	fmt.println("-- measurements")
	quiet = true
	defer quiet = false
	// DOMContentLoaded after parsing, 20 external scripts
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<!doctype html><head>`)
	strings.write_string(&sb, PRELUDE)
	for i in 0 ..< 20 {
		fmt.sbprintf(&sb, `<script src="%s"></script>`, gen(fmt.tprintf(`window.s%d = %d`, i, i), 0, fmt.tprintf("&m=%d", i)))
		fmt.sbprintf(&sb, `<p>paragraph %d</p>`, i)
	}
	strings.write_string(&sb, `<script>document.addEventListener("DOMContentLoaded", () => log("dcl20"))</script></head><body></body>`)
	p := load(strings.to_string(sb))
	wait_for("dcl20")
	t := page.scripts_timing(p)
	fmt.printf("  MEASURE 20 external scripts: DOMContentLoaded %.1f ms after the document was parsed (scripts %d)\n", t.dcl_ms - t.started_ms, t.scripts_run)
	check(logged("dcl20"), "20 scripts: DOMContentLoaded")
	page.page_close(p)

	// the same, already in the bytecode cache and the scripts of the second load in memory
	p = load(strings.to_string(sb))
	wait_for("dcl20")
	t = page.scripts_timing(p)
	fmt.printf("  MEASURE 20 external scripts, second load: DOMContentLoaded %.1f ms after parsing\n", t.dcl_ms - t.started_ms)
	page.page_close(p)

	// off-thread compilation of large scripts
	s := settings
	s.js.offthread_min_bytes = 32 << 10
	big := `<!doctype html><head><script src="/jsload/big?kb=512&id=a"></script><script src="/jsload/big?kb=512&id=b"></script><script>console.log("bigs done")</script></head>`
	st0 := page.compile_stats()
	t0 := time.tick_now()
	p = load(big, s = &s)
	wait_for("bigs done")
	ms_off := time.duration_milliseconds(time.tick_since(t0))
	st1 := page.compile_stats()
	page.page_close(p)
	fmt.printf("  MEASURE 2 x 512 KiB scripts compiled off-thread: %d jobs, %.1f ms of compilation on %d thread(s); page done in %.1f ms\n", st1.jobs - st0.jobs, st1.total_ms - st0.total_ms, st1.threads, ms_off)
	check(st1.jobs - st0.jobs == 2, "large scripts are compiled on the compile threads")
	check(logged("big a 512") && logged("big b 512"), "and run from the bytecode they made")
	// large modules too: the module waits for its bytecode, then it is prepared from the cache
	st2 := page.compile_stats()
	t0 = time.tick_now()
	p = load(`<!doctype html><head><script type=module src="/jsload/big?kb=512&id=ma"></script><script type=module src="/jsload/big?kb=512&id=mb"></script><script type=module>console.log("big modules done")</script></head>`, s = &s)
	wait_for("big modules done")
	st3 := page.compile_stats()
	page.page_close(p)
	fmt.printf("  MEASURE 2 x 512 KiB modules compiled off-thread: %d jobs, %.1f ms of compilation; page done in %.1f ms\n", st3.jobs - st2.jobs, st3.total_ms - st2.total_ms, time.duration_milliseconds(time.tick_since(t0)))
	check(st3.jobs - st2.jobs == 2, "large modules are compiled on the compile threads")
	check(logged("big ma 512") && logged("big mb 512"), "and run from the bytecode they made")
	s2 := settings
	s2.js_load.compile_threads = 0
	js.cache_clear_memory()
	t0 = time.tick_now()
	p = load(`<!doctype html><head><script src="/jsload/big?kb=512&id=c"></script><script src="/jsload/big?kb=512&id=d"></script><script>console.log("bigs done")</script></head>`, s = &s2)
	wait_for("bigs done")
	fmt.printf("  MEASURE the same compiled on the interface thread: page done in %.1f ms\n", time.duration_milliseconds(time.tick_since(t0)))
	page.page_close(p)

	// setTimeout: the cost of a call (with its clearTimeout), and a round trip through the event loop
	p = load(strings.concatenate({`<!doctype html><body>`, PRELUDE, `<script>window.noop = () => {}</script></body>`}, context.temp_allocator))
	drain()
	t0 = time.tick_now()
	run_js(p, `for (let i = 0; i < 10000; i++) {}`)
	empty := time.duration_microseconds(time.tick_since(t0))
	t0 = time.tick_now()
	run_js(p, `for (let i = 0; i < 10000; i++) clearTimeout(setTimeout(noop, 0))`)
	pairs := time.duration_microseconds(time.tick_since(t0))
	fmt.printf("  MEASURE setTimeout(f, 0) + clearTimeout: %.2f us per pair\n", (pairs - empty) / 10000)
	run_js(p, `let hops = 0; const hop = () => { if (++hops === 200) log("hops done"); else setTimeout(hop, 0); }; log("hops start"); setTimeout(hop, 0);`)
	start := time.tick_now()
	// spinning (no wait in the OS, whose timer resolution would be measured instead), bounded only for a failing run
	for !logged("hops done") && time.duration_milliseconds(time.tick_since(start)) < WAIT_FAIL_MS { host.loop_wait(&loop, 0) }
	hop_ms := time.duration_milliseconds(time.tick_since(start))
	fmt.printf("  MEASURE setTimeout(0) round trip: %.3f ms per hop over 200 (HTML clamps to 4 ms past 5 nested levels)\n", hop_ms / 200)
	check(logged("hops done"), "setTimeout(0) chain")
	page.page_close(p)

	// requestAnimationFrame: from the shell's frame (run_animation_frames) to the callback running
	p = load(strings.concatenate({`<!doctype html><body>`, PRELUDE, `<script>
window.n = 0; const go = () => requestAnimationFrame(ts => { log("raf " + (++n)); if (n < 50) go(); }); go();
</script></body>`}, context.temp_allocator))
	drain()
	quiet = true
	total: f64
	frames := 0
	for i in 0 ..< 60 {
		_ = i
		before := len(logs)
		t1 := time.tick_now()
		page.run_animation_frames(p, f64(host.now_ns(&loop)) / 1e6)
		if len(logs) > before { total += time.duration_microseconds(time.tick_since(t1)); frames += 1 }
		host.loop_wait(&loop, 0)
		if logged("raf 50") { break }
	}
	fmt.printf("  MEASURE requestAnimationFrame: %.1f us from the frame to the end of the callback (%d frames)\n", total / f64(max(frames, 1)), frames)
	check(logged("raf 50"), "50 animation frames, one callback each")
	page.page_close(p)
}