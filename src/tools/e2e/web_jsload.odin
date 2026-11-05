#+build windows
#+private file
// Script loading and the event loop's JavaScript side (src/page/js_load*.odin, js_workers.odin, native/js/runtime: timers, modules,
// handlers, load_errors, clone, workers): the order and the moment scripts run (blocking, defer, async, modules), document.write,
// scripts inserted by scripts, modules and import(), import maps, event handler attributes, javascript: URLs, Content-Security-Policy
// (nonces, hashes, eval), <noscript>, timers, animation frames, idle callbacks, uncaught errors and unhandled rejections, workers and
// structured cloning, off-thread compilation; with their measurements in the log (DOMContentLoaded after parsing with 20 scripts,
// compilation, setTimeout(0), animation frame latency). A page says what happened with `log`, a note to its test; only what the
// console itself is about (an uncaught error, a violation) is read from the console. Its files are examples/jsload, its routes
// tools/testserver/jsload.go.
package e2e_scenarios

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:html"
import "wb:http"
import "wb:js"
import "wb:page"
import "wb:tools/testenv"
import "wb:tools/testhost"
import "wb:url"

BASE :: "http://127.0.0.1:8765/jsload/test.html"   // on the run's block of ports through testenv.url
HITS :: "http://127.0.0.1:8765/jsload/hits?path="

// How late the server answers, so that what arrives first is not what comes first in the document.
ARRIVES_SOON_MS :: 5
ARRIVES_LATE_MS :: 60
SHEET_IMPORTED_MS :: 100         // an @import: a load event that does not wait for it comes before it
SHEET_LEFT_MS :: 100             // the sheet of a link pointed elsewhere
SHEET_AFTER_LEFT_MS :: 200       // a sheet asked for after it, and later than it: what the first one would have fired has come by then
SHEET_BLOCKING_MS :: 50
SHEET_NEVER_WAITED_FOR_MS :: 3000   // still on its way when the page has closed
SHEET_REL_CHANGED_MS :: 200
SCRIPT_AFTER_REL_CHANGE_MS :: 300
POLL_NEVER_MS :: 600_000         // a poll of the waiting page that never comes within a test
PUMP_SLICE_MS :: 20
PUMP_SCRIPT_MS :: 30             // past the slice
SHEET_IN_WAIT_SECONDS :: 20.0    // far below the poll: only ends a run that fails

SCRIPTS_IN_ORDER_PAGE :: 8       // at least: those of test_order's page that run
FRAGMENT_PARSE_BUDGET :: 1000
TIMERS_SPAN :: 200 * time.Millisecond   // on the test's clock: past every timer of the page
PAGE_LIMIT_SECONDS :: 120.0
EXTERNAL_SCRIPTS :: 20
OFFTHREAD_MIN_BYTES :: 32 << 10
SHORT_CALL_MS :: 1               // shorter than any compilation of the large script
TIMER_PAIRS :: 10000
HOPS :: 200
RAF_FRAMES :: 50
RAF_TRIES :: 60

PRELUDE :: `<script>function log(s) { wrenTest.note(String(s)) }</script>`

concat :: proc(parts: ..string) -> string { return strings.concatenate(parts, context.temp_allocator) }

// The URL of a script with this code (served after `ms`).
gen :: proc(code: string, ms := 0, extra := "") -> string {
	return fmt.tprintf("/jsload/gen?ms=%d%s&code=%s", ms, extra, enc(code))
}

// The URL of a sheet with this text.
css :: proc(text: string, ms: int, key: string) -> string { return gen(text, ms, concat("&type=text/css&k=", key)) }

load :: proc(t: ^testing.T, name, source: string, csp := "") -> ^Probe {
	pr := page_make(t, name, testenv.url(BASE))
	if csp != "" { page.apply_response_headers(pr.p, {csp}, {}, "") }
	page_load(pr, source)
	return pr
}

noted :: proc(pr: ^Probe, text: string) -> bool { return testhost.noted(&pr.section, text) }

noted_prefix :: proc(pr: ^Probe, prefix: string) -> bool {
	for n in pr.section.notes { if strings.has_prefix(n, prefix) { return true } }
	return false
}

// The notes came in this order (others may come between).
in_order :: proc(pr: ^Probe, lines: ..string) -> bool {
	i := 0
	for n in pr.section.notes {
		if i < len(lines) && n == lines[i] { i += 1 }
	}
	return i == len(lines)
}

index_of :: proc(pr: ^Probe, text: string) -> int {
	for n, i in pr.section.notes { if n == text { return i } }
	return -1
}

// What the page's console said: only for what the console is about.
console_says :: proc(pr: ^Probe, part: string) -> bool {
	for l in pr.lines { if strings.contains(l, part) { return true } }
	return false
}

Wait_Prefix :: struct { pr: ^Probe, prefix: string }

wait_note_prefix :: proc(pr: ^Probe, prefix: string) -> bool {
	return wait_until(pr.t, prefix, Wait_Prefix{pr, prefix}, proc(w: Wait_Prefix) -> bool {
		testhost.flush(&w.pr.section, w.pr.t)
		return noted_prefix(w.pr, w.prefix)
	})
}

Hits_Answer :: struct { done: bool, count: int }

// How many times the test server was asked for `path` (its hits counter), -1 when it cannot say.
hits :: proc(t: ^testing.T, path: string) -> int {
	answer: Hits_Answer
	fetch.start(&loader, {
		request = {url = concat(testenv.url(HITS), enc(path))},
		on_event = proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
			a := (^Hits_Answer)(user)
			#partial switch ev.kind {
			case .Done:
				a.count, a.done = -1, true
				if len(ev.data) == 0 { return }
				a.count = 0
				for c in ev.data {
					if c < '0' || c > '9' { a.count = -1; return }
					a.count = a.count * 10 + int(c - '0')
				}
			case .Failed: a.count, a.done = -1, true
			}
		},
		user = rawptr(&answer), collect = true,   // (until the request ends, waited for below)
	})
	if !wait_until(t, path, &answer, proc(a: ^Hits_Answer) -> bool { return a.done }) { return -1 }
	return answer.count
}

@(test)
jsload_the_parsers_order :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "order", concat(`<!doctype html><html><head>`, PRELUDE, `
<script id=s1>log("head: body " + (document.body === null) + ", " + document.readyState + ", current " + document.currentScript.id + ", after " + (document.getElementById("p1") === null))
document.addEventListener("readystatechange", () => log("readystate " + document.readyState));
document.addEventListener("DOMContentLoaded", e => log("DCL at document " + (e.target === document)));
window.addEventListener("DOMContentLoaded", e => log("DCL at window " + (e.currentTarget === window) + " " + e.eventPhase));
window.addEventListener("load", () => log("load " + document.readyState));
</script>
<script defer src="`, gen(`log("defer 1 " + document.readyState)`, ARRIVES_LATE_MS), `"></script>
<script type=module>log("inline module " + (document.currentScript === null) + " " + document.readyState)</script>
<script async src="`, gen(`log("async")`, ARRIVES_SOON_MS), `"></script>
<script src="`, gen(`log("blocking 1 " + (document.getElementById("p1") !== null) + " " + (document.getElementById("p2") === null) + " " + document.currentScript.src.includes("gen"))`, ARRIVES_LATE_MS), `"></script>
</head><body><p id=p1>one</p>
<script>log("inline 2 sees p1 " + !!document.getElementById("p1") + ", body " + (document.body !== null) + ", p2 " + !!document.getElementById("p2"))</script>
<script src="`, gen(`log("blocking 2")`, ARRIVES_SOON_MS), `"></script>
<script defer src="`, gen(`log("defer 2")`, ARRIVES_SOON_MS), `"></script>
<script nomodule>log("nomodule ran")</script>
<script type="text/x-template">log("data block ran")</script>
<p id=p2>two</p>
<svg><script>log("svg outer " + (function () { var a = {
<script>log("svg inner")</script>
a: 1}; return a.a })())</script></svg>
<script>log("last inline")</script>
</body></html>`))
	check(pr, wait_note(pr, "load complete"), "the load event comes")
	check(pr, noted(pr, "head: body true, loading, current s1, after true"), "a script in <head> sees no body and nothing after it; currentScript; readyState loading")
	check(pr, noted(pr, "blocking 1 false true true"), "a blocking external script sees what precedes it, not what follows")
	check(pr, in_order(pr, "blocking 1 false true true", "inline 2 sees p1 true, body true, p2 false", "blocking 2"), "blocking scripts and inline scripts run in document order")
	check(pr, !noted(pr, "nomodule ran") && !noted(pr, "data block ran"), "nomodule and data blocks do not run")
	check(pr, in_order(pr, "readystate interactive", "defer 1 interactive", "inline module true interactive", "defer 2", "DCL at document true"), "defer scripts and modules after parsing, in order, before DOMContentLoaded")
	check(pr, noted(pr, "DCL at window true 3"), "DOMContentLoaded bubbles to the window")
	check(pr, in_order(pr, "DCL at document true", "readystate complete", "load complete"), "then readyState complete and load at the window")
	check(pr, index_of(pr, "async") >= 0 && index_of(pr, "async") < index_of(pr, "load complete"), "async scripts run before load")
	check(pr, in_order(pr, "svg inner", "svg outer 1", "last inline"), "an SVG script inside an SVG script runs at its end tag, first; the outer's text is its own text children")
	ran := page.scripts_timing(pr.p).scripts_run
	check(pr, ran >= SCRIPTS_IN_ORDER_PAGE, fmt.tprintf("%d scripts ran", ran))
	close_page(pr, min_checks = 11)
}

@(test)
jsload_document_write :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "write", concat(`<!doctype html><body>`, PRELUDE, `
<script>document.write("<p id=w1>written</p><script>log('written inline ' + !!document.getElementById('w1'))<\/script>"); log("after write " + !!document.getElementById("w1") + " " + window.writtenFlag);</script>
<script>document.write("<script src='`, gen(`window.extRan = true; log("written external"); document.write("<script>log('from external')<\/script>")`, ARRIVES_LATE_MS), `'><\/script>"); log("after external write " + window.extRan); document.write("<script>log('written after external ' + window.extRan)<\/script>"); document.write("<script>log('written last')<\/script>")</script>
<script>log("next script " + window.extRan); document.writeln("<i id=w2>x</i>"); log("w2 " + (document.getElementById("w2").nextSibling !== null))</script>
<p id=tail>tail</p>
<script>log("order " + document.body.textContent.indexOf("written") + " < " + document.body.textContent.indexOf("tail"))</script>
<script>addEventListener("load", () => setTimeout(() => { document.write("<h1 id=fresh>fresh</h1>"); document.close(); log("after open " + !!document.getElementById("fresh") + " " + (document.getElementById("tail") === null)) }, 0))</script>
</body>`))
	ok := wait_note(pr, "after open true true")
	check(pr, noted(pr, "written inline true"), "a written inline script runs inside document.write and sees the written nodes")
	check(pr, noted(pr, "after write true undefined"), "written nodes are in the document when write returns")
	check(pr, noted(pr, "after external write undefined"), "a written external script does not run inside write")
	check(pr, in_order(pr, "after external write undefined", "written external", "next script true"), "a written external script blocks the parser until it ran")
	check(pr, in_order(pr, "written external", "from external", "written after external true", "written last", "next script true"), "what a script writes after a written external script waits behind it, in the order written; what that one writes comes right after it")
	check(pr, noted(pr, "w2 true"), "writeln: the newline is written too")
	check(pr, noted_prefix(pr, "order ") && !noted_prefix(pr, "order -1"), "written content comes before the rest of the document")
	check(pr, ok, "document.write after the load opens the document again (replaced), document.close finishes it")
	close_page(pr, min_checks = 8)
}

@(test)
jsload_document_open_from_a_parser_script :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "open", concat(`<!doctype html><body>`, PRELUDE, `<script>
const d = document.open(); log("open returns document " + (d === document));
log("open during parsing is ignored " + (document.body !== null));
</script></body>`))
	wait_note(pr, "open during parsing is ignored true")
	check(pr, noted(pr, "open returns document true") && noted(pr, "open during parsing is ignored true"), "document.open from a parser script does nothing and returns the document")
	close_page(pr, min_checks = 1)
}

@(test)
jsload_scripts_inserted_by_scripts :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "dynamic", concat(`<!doctype html><body>`, PRELUDE, `<script>
const s = document.createElement("script");
s.text = "window.dyn = 1; log('dynamic inline ran')";
log("async default " + s.async);
document.body.appendChild(s);
log("after append " + window.dyn);
const detached = document.createElement("script");
detached.text = "log('detached ran')";
const e1 = document.createElement("script"); e1.src = "`, gen(`log("ordered 1")`, ARRIVES_LATE_MS), `"; e1.async = false;
const e2 = document.createElement("script"); e2.src = "`, gen(`log("ordered 2")`, ARRIVES_SOON_MS), `"; e2.async = false;
document.head.appendChild(e1); document.head.appendChild(e2);
const a = document.createElement("script"); a.src = "`, gen(`log("dynamic async")`, ARRIVES_SOON_MS), `";
a.onload = () => log("onload fired"); document.body.appendChild(a);
const bad = document.createElement("script"); bad.src = "/jsload/gen?status=404&code=x";
bad.addEventListener("error", () => log("onerror fired")); document.body.appendChild(bad);
const later = document.createElement("script"); document.body.appendChild(later);
later.appendChild(document.createTextNode("log('text inserted later ran')"));
const viaSrc = document.createElement("script"); document.body.appendChild(viaSrc);
viaSrc.src = "`, gen(`log("src set later ran")`), `";
log("supports " + HTMLScriptElement.supports("module") + " " + HTMLScriptElement.supports("speculationrules"));
</script></body>`))
	for m in ([]string{"ordered 2", "onerror fired", "src set later ran", "onload fired"}) { wait_note(pr, m) }
	check(pr, noted(pr, "async default true"), "a script made by a script is async by default")
	check(pr, noted(pr, "dynamic inline ran") && noted(pr, "after append 1"), "an inserted inline script runs before appendChild returns")
	check(pr, !noted(pr, "detached ran"), "a script that is not connected does not run")
	check(pr, in_order(pr, "ordered 1", "ordered 2"), "async = false scripts run in insertion order")
	check(pr, noted(pr, "dynamic async") && noted(pr, "onload fired"), "an inserted external script runs and fires load")
	check(pr, noted(pr, "onerror fired"), "an external script that fails fires error")
	check(pr, noted(pr, "text inserted later ran"), "text inserted into a connected script that had none runs it")
	check(pr, noted(pr, "src set later ran"), "src set on a connected script that had none fetches and runs it")
	check(pr, noted(pr, "supports true false"), "HTMLScriptElement.supports")
	// what innerHTML does: the fragment parser builds nodes in the document; its scripts never run, its handlers work
	html.parse_into(pr.p.doc, pr.p.body, transmute([]byte)string(`<script>log("fragment script ran")</script><b id=fb onclick="log('fragment handler ran')">x</b>`), FRAGMENT_PARSE_BUDGET)
	run(pr, `document.getElementById("fb").dispatchEvent(new Event("click")); log("fragment checked")`)
	drain()
	check(pr, noted(pr, "fragment checked") && !noted(pr, "fragment script ran"), "scripts made by a fragment parser never run")
	check(pr, noted(pr, "fragment handler ran"), "the handlers of a fragment's elements are registered")
	close_page(pr, min_checks = 11)
}

@(test)
jsload_modules :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "modules", concat(`<!doctype html><head>`, PRELUDE, `
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
const sheet = (await import("/jsload/files/mod/sheet.css", { with: { type: "css" } })).default;
document.adoptedStyleSheets = [sheet];
log("css module " + (sheet instanceof CSSStyleSheet) + " " + sheet.cssRules.length + " " + getComputedStyle(document.documentElement).color);
try { await import("/jsload/files/mod/sheet.css"); } catch (e) { log("css module as javascript " + (e instanceof TypeError)); }
log("modules done");
</script>
<script type=module src="/jsload/files/mod/imports_missing.js" onerror="log('missing import: error event')"></script>
<script type=module src="/jsload/files/mod/tla.js"></script>
<script type=module src="/jsload/files/mod/broken.js" onerror="log('no error event for a parse error')"></script>
<script>import("/jsload/files/mod/dyn.js").then(ns => log("import() from a classic script " + ns.default));
addEventListener("load", () => log("window load"))</script>
</head><body></body>`))
	pr.expect_uncaught = true   // the module that does not compile
	for m in ([]string{"modules done", "top-level await done", "import() from a classic script dynamic", "window load"}) { wait_note(pr, m) }
	check(pr, noted(pr, "module main bc 42 c true object null"), "a module graph (three modules, a JSON module) runs once fetched; currentScript is null")
	check(pr, in_order(pr, "module c evaluated", "module b evaluated", "module main bc 42 c true object null"), "dependencies are evaluated first, once each")
	check(pr, noted(pr, "bare specifiers mapped c"), "import maps map bare specifiers and prefixes")
	check(pr, noted(pr, "meta url true resolve true"), "import.meta.url of an inline module is the document's; import.meta.resolve")
	check(pr, noted(pr, "dynamic import dynamic true"), "import() of a module")
	check(pr, noted(pr, "broken import rejects SyntaxError"), "import() of a module that does not compile rejects")
	check(pr, noted(pr, "unmapped bare specifier true"), "an unmapped bare specifier is a TypeError")
	check(pr, noted(pr, "missing import: error event") && !noted(pr, "never"), "a graph with a missing module fires error at its script")
	check(pr, noted(pr, "top-level await done"), "top-level await")
	check(pr, console_says(pr, "Uncaught SyntaxError") && !noted(pr, "no error event for a parse error"), "a module that does not compile is reported when its script runs (no error event)")
	check(pr, noted(pr, "import() from a classic script dynamic"), "import() from a classic script")
	check(pr, noted(pr, "css module true 1 rgb(1, 2, 3)"), "a CSS module: a CSSStyleSheet of its rules, adopted")
	check(pr, noted(pr, "css module as javascript true"), "the same URL imported as JavaScript fails (module map by URL and type)")
	close_page(pr, min_checks = 13)
}

@(test)
jsload_event_handler_attributes :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "handlers", concat(`<!doctype html><head>`, PRELUDE, `</head><body onload="log('body onload ' + (this === window) + ' ' + event.type)">
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
</script></body>`))
	pr.expect_uncaught = true   // the handler that does not compile
	wait_note(pr, "body onload true load")
	check(pr, noted(pr, "handler getter function onclick"), "the IDL attribute returns the compiled handler, named after the attribute")
	check(pr, noted(pr, "onclick b click function function"), "this, event, and the scope chain (document, form, element)")
	check(pr, noted(pr, "return false cancels true"), "a handler returning false cancels")
	check(pr, noted(pr, "set later d") && noted(pr, "changed"), "setAttribute registers and changes the handler")
	check(pr, noted(pr, "after removal null") && !noted(pr, "never"), "removeAttribute removes it; unknown on* attributes do nothing")
	check(pr, console_says(pr, "SyntaxError"), "a handler that does not compile is reported")
	check(pr, noted(pr, "body onload true load"), "<body onload> is the window's load handler")
	check(pr, noted(pr, "body onload is window's function true"), "document.body.onload is window.onload (window-reflecting body handlers)")
	close_page(pr, min_checks = 8)
}

// What a click on <a href="javascript:..."> or location.href = "javascript:..." hands the page.
follow :: proc(p: ^page.Page, href: string) -> bool {
	u, ok := url.parse_absolute(href, context.temp_allocator)
	return ok && page.follow_javascript_url(p, u)
}

@(test)
jsload_javascript_urls :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "javascript urls", concat(`<!doctype html><body>`, PRELUDE, `<p id=old>old</p></body>`))
	drain()
	check(pr, follow(pr.p, "javascript:log('javascript%20url%20ran%20'%20+%20(typeof document))"), "a javascript: URL is handled by the page")
	check(pr, wait_note(pr, "javascript url ran object"), "its percent-decoded script runs in the document, in a task of its own")
	follow(pr.p, "javascript:'<p id=fresh>' + 'replaced' + '</p>'")
	wait_until(t, "the document the URL's string makes", pr.p, proc(p: ^page.Page) -> bool { return dom.find_by_id(p.doc, "fresh") != base.NIL_HANDLE })
	run(pr, `log("replaced " + !!document.getElementById("fresh") + " " + (document.getElementById("old") === null))`)
	check(pr, noted(pr, "replaced true true"), "a string result becomes the document")
	close_page(pr, min_checks = 3)
}

@(test)
jsload_csp_nonces_hashes_eval_attributes_strict_dynamic :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	code := `log("hashed")`
	dig := page.digest_base64("sha256", transmute([]byte)string(code))
	policy := fmt.tprintf("script-src 'nonce-abc' 'sha256-%s' 'strict-dynamic'", dig)
	pr := load(t, "csp", concat(`<!doctype html><body>
<script nonce=abc>function log(s) { wrenTest.note(String(s)) }
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
</body>`), csp = policy)
	pr.expect_uncaught = true   // the string timer's refusal
	wait_note(pr, "strict-dynamic child ran")
	wait_note(pr, "csp done")   // after the parser-inserted external script, which would have run before it
	wait_note(pr, "timers checked")
	check(pr, noted(pr, "nonce ran"), "a script with the policy's nonce runs")
	check(pr, !noted(pr, "no nonce ran"), "an inline script without nonce or hash is blocked")
	check(pr, noted(pr, "hashed"), "an inline script matching a sha256 hash runs")
	check(pr, noted(pr, "eval refused EvalError") && noted(pr, "Function refused true"), "eval and new Function are refused without 'unsafe-eval'")
	check(pr, !noted(pr, "string timer ran"), "setTimeout(string) is refused without 'unsafe-eval'")
	check(pr, noted(pr, "strict-dynamic child ran"), "'strict-dynamic': a script inserted by a trusted script runs")
	check(pr, !noted(pr, "parser external without nonce ran"), "'strict-dynamic': a parser-inserted external script without nonce is blocked")
	check(pr, !noted(pr, "attribute ran") && noted(pr, "csp done"), "an event handler attribute is blocked without 'unsafe-inline'")
	check(pr, console_says(pr, "Content-Security-Policy: script-src"), "violations are reported in the console")
	close_page(pr, min_checks = 9)
}

@(test)
jsload_csp_unsafe_inline_and_unsafe_eval :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "csp unsafe", concat(`<!doctype html><body>`, PRELUDE, `<button id=b onclick="log('attr ok')"></button><script>
try { log("eval " + eval("6 * 7")); } catch (e) { log("eval refused"); }
setTimeout("log('string timer ok')", 1);
document.getElementById("b").dispatchEvent(new Event("click"));
</script></body>`), csp = "script-src 'unsafe-inline' 'unsafe-eval'")
	wait_note(pr, "string timer ok")
	check(pr, noted(pr, "eval 42") && noted(pr, "string timer ok") && noted(pr, "attr ok"), "'unsafe-inline' 'unsafe-eval' allow inline code, eval and string timers")
	close_page(pr, min_checks = 1)
}

// A <meta> policy starts where it stands: what the parser ran before it is not under it.
@(test)
jsload_csp_of_a_meta_element :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "csp meta", `<!doctype html><head><script>wrenTest.note("before meta ran"); try { eval("1"); wrenTest.note("eval before meta"); } catch (e) {}</script>
<meta http-equiv="Content-Security-Policy" content="script-src 'none'">
<script>wrenTest.note("after meta ran")</script></head><body><script nonce=x>wrenTest.note("late ran")</script></body>`)
	drain()   // (no network: the document is parsed in what is ready now)
	check(pr, noted(pr, "before meta ran") && noted(pr, "eval before meta"), "a script before a <meta> policy runs, and may eval")
	check(pr, !noted(pr, "after meta ran") && !noted(pr, "late ran"), "a script after a <meta> policy is under it")
	close_page(pr, min_checks = 2)
}

WASM_PAGE :: `<!doctype html><body>` + PRELUDE + `<script>
const bytes = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]);
log("wasm valid " + WebAssembly.validate(bytes));
try { new WebAssembly.Module(bytes); log("wasm compiled"); } catch (e) { log("wasm refused " + e.name); }
log("wasm done");
</script></body>`

// A page's WebAssembly: 'wasm-unsafe-eval' or 'unsafe-eval'.
@(test)
jsload_csp_of_webassembly :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "csp wasm refused", WASM_PAGE, csp = "script-src 'unsafe-inline'")
	wait_note(pr, "wasm done")
	check(pr, noted(pr, "wasm valid true"), "WebAssembly.validate is not subject to the policy")
	check(pr, noted(pr, "wasm refused CompileError"), "a WebAssembly module does not compile without 'wasm-unsafe-eval'")
	check(pr, !noted(pr, "wasm compiled"), "and is not compiled")
	close_page(pr, min_checks = 3)
	pr = load(t, "csp wasm allowed", WASM_PAGE, csp = "script-src 'unsafe-inline' 'wasm-unsafe-eval'")
	wait_note(pr, "wasm done")
	check(pr, noted(pr, "wasm compiled"), "'wasm-unsafe-eval' allows a WebAssembly module")
	close_page(pr, min_checks = 1)
}

// A module with a shared memory, in workers: wait(address, value) (no timeout), notify(address, count), add(address, value).
THREAD_MODULE :: `const threadBytes = new Uint8Array([0,97,115,109,1,0,0,0,
  1,7,1,0x60,2,0x7f,0x7f,1,0x7f,
  2,9,1,1,101,1,109,2,3,1,1,
  3,4,3,0,0,0,
  7,13,3,1,119,0,0,1,110,0,1,1,97,0,2,
  10,36,3,
  12,0,0x20,0,0x20,1,0x42,0x7f,0xfe,1,2,0,0x0b,
  10,0,0x20,0,0x20,1,0xfe,0,2,0,0x0b,
  10,0,0x20,0,0x20,1,0xfe,0x1e,2,0,0x0b]);`

// Without the headers: nothing is shared.
@(test)
jsload_threads_without_isolation :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "threads, not isolated", concat(`<!doctype html><body>`, PRELUDE, `<script>` + THREAD_MODULE + `
log("isolated " + crossOriginIsolated);
log("global " + typeof SharedArrayBuffer);
const m = new WebAssembly.Memory({initial: 1, maximum: 1, shared: true});
log("buffer " + Object.prototype.toString.call(m.buffer));
try { structuredClone(m.buffer); log("sent"); } catch (e) { log("buffer " + e.name); }
try { structuredClone(m); log("sent"); } catch (e) { log("memory " + e.name); }
log("module " + (structuredClone(new WebAssembly.Module(threadBytes)) instanceof WebAssembly.Module));
log("plain done");
</script></body>`))
	wait_note(pr, "plain done")
	check(pr, noted(pr, "isolated false"), "a page without the headers is not cross-origin isolated")
	check(pr, noted(pr, "global undefined"), "and has no global SharedArrayBuffer")
	check(pr, noted(pr, "buffer [object SharedArrayBuffer]"), "a shared memory's buffer is one")
	check(pr, noted(pr, "buffer DataCloneError") && noted(pr, "memory DataCloneError"), "which it cannot send")
	check(pr, noted(pr, "module true"), "a module can be sent, isolated or not")
	close_page(pr, min_checks = 5)
}

// With them: a script and a module in another thread, on the same bytes.
@(test)
jsload_threads_with_isolation :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	headers := http.headers_make(context.temp_allocator)
	http.append_header(&headers, "cross-origin-opener-policy", "same-origin")
	http.append_header(&headers, "cross-origin-embedder-policy", "require-corp")
	pr := page_make(t, "threads, isolated", testenv.url(BASE))
	page.apply_isolation_headers(pr.p, headers)
	page_load(pr, concat(`<!doctype html><body>`, PRELUDE, `<script>` + THREAD_MODULE + `
log("isolated " + crossOriginIsolated);
const WORKER = URL.createObjectURL(new Blob([` + "`" + `
onmessage = e => {
  const d = e.data;
  if (d.sab) {
    const a = new Int32Array(d.sab);
    a[1] = 42;                               // a plain write, then what orders it
    Atomics.add(a, 0, 5);
    Atomics.notify(a, 0);
    postMessage("sab isolated " + crossOriginIsolated + " " + Atomics.wait(a, 2, 0, 10000));
    return;
  }
  const i = new WebAssembly.Instance(d.module, {e: {m: d.memory}});
  if (d.spin) {
    postMessage("waiting");
    i.exports.w(8, 0);                       // only the page's notify ends this one
    postMessage("woke");
    i.exports.w(8, 0);                       // nothing wakes this one but terminate
    postMessage("woke again");
    return;
  }
  postMessage("module woken " + i.exports.w(12, 0) + " value " + new Int32Array(d.memory.buffer)[0]);   // (nothing changes 12: only a notify ends this)
  i.exports.a(4, 7);
  postMessage("module notified " + i.exports.n(4, 1));
  postMessage("wait in js " + Atomics.wait(new Int32Array(d.memory.buffer), 5, 0, 20));
};` + "`" + `]));
try { Atomics.wait(new Int32Array(new SharedArrayBuffer(8)), 0, 0, 1); log("page waited"); } catch (e) { log("page wait " + e.name); }

const sab = new SharedArrayBuffer(16);
const a = new Int32Array(sab);
const w1 = new Worker(WORKER);
w1.onmessage = e => log(e.data);
w1.postMessage({sab});
(function look() {
  if (Atomics.load(a, 0) !== 5) { setTimeout(look, 1); return; }
  log("sab seen " + a[0] + " " + a[1]);
  a[2] = 9;
  Atomics.notify(a, 2);
})();

const module = new WebAssembly.Module(threadBytes);
const memory = new WebAssembly.Memory({initial: 1, maximum: 1, shared: true});
const heap = new Int32Array(memory.buffer);
const w2 = new Worker(WORKER);
w2.onmessage = e => log(e.data);
w2.postMessage({module, memory});
Atomics.store(heap, 0, 11);
setTimeout(function wake() {
  if (Atomics.notify(heap, 3) === 0) { setTimeout(wake, 1); return; }   // (it is not waiting yet)
  log("page woke a module");
  (function added() { if (Atomics.load(heap, 1) === 7) log("page saw the module's add"); else setTimeout(added, 1); })();
}, 1);

const w3 = new Worker(WORKER);
w3.onmessage = e => {
  log(e.data);
  if (e.data === "waiting") (function find() {   // a notify that wakes someone: it was blocked in its wait
    if (Atomics.notify(heap, 2, 1) === 0) { setTimeout(find, 1); return; }
    log("page found a module waiting");
  })();
  if (e.data === "woke") { w3.terminate(); log("terminated"); }
};
w3.postMessage({module, memory, spin: true});
</script></body>`))
	page.scripts_start(pr.p)
	wait_note(pr, "page saw the module's add")
	wait_note(pr, "wait in js timed-out")
	wait_note_prefix(pr, "sab isolated true")
	wait_note(pr, "terminated")
	check(pr, noted(pr, "isolated true"), "COOP same-origin with COEP require-corp: cross-origin isolated")
	check(pr, noted(pr, "page wait TypeError"), "a window may not block")
	check(pr, noted(pr, "sab seen 5 42"), "a worker's writes reach the page's SharedArrayBuffer")
	check(pr, noted(pr, "sab isolated true not-equal") || noted(pr, "sab isolated true ok"), "the page's write reaches the worker, and it is isolated too")
	check(pr, noted(pr, "page woke a module"), "Atomics.notify wakes memory.atomic.wait of a module in another thread")
	check(pr, noted(pr, "module woken 0 value 11"), "which sees what the page stored")
	check(pr, noted(pr, "page saw the module's add"), "and the page sees what it adds")
	check(pr, noted(pr, "wait in js timed-out"), "Atomics.wait times out on a shared memory")
	check(pr, in_order(pr, "waiting", "page found a module waiting", "woke") && !noted(pr, "woke again"), "a module's wait without timeout blocks")
	close_page(pr, min_checks = 9)   // (a worker terminated while it waited: its thread must end, or this never returns)
}

@(test)
jsload_noscript_with_scripting :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "noscript", concat(`<!doctype html><head><noscript><link rel=stylesheet href="/nope.css"></noscript></head><body>`, PRELUDE,
		`<noscript><p id=ns>no script</p></noscript><script>
log("noscript content is text " + (document.getElementById("ns") === null));
</script></body>`))
	check(pr, wait_note(pr, "noscript content is text true"), "with scripting, <noscript> holds text (its markup), not elements")
	check(pr, pr.p.engine.settings.scripting, "and the style engine does not render it")
	close_page(pr, min_checks = 2)
}

@(test)
jsload_noscript_without_javascript :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	settings.js.enabled = false
	pr := page_make(t, "noscript off", testenv.url(BASE))
	page.load_html(pr.p, transmute([]byte)string(`<!doctype html><body><noscript><p id=ns>no script</p></noscript></body>`))
	found := dom.find_by_id(pr.p.doc, "ns") != base.NIL_HANDLE
	check(pr, found && !pr.p.engine.settings.scripting, "without JavaScript, <noscript> content is parsed and rendered")
	close_page(pr, min_checks = 1)
}

// On the test's clock: what is due runs when it says, what was cleared has had all the time it wanted.
@(test)
jsload_timers_microtasks_animation_frames_idle_callbacks :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	virtual_clock(t)
	pr := load(t, "timers", concat(`<!doctype html><body>`, PRELUDE, `<script>
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
</script></body>`))
	wait_note(pr, "sync")
	host.clock_advance(&loop, TIMERS_SPAN)
	page.run_animation_frames(pr.p, f64(host.now_ns(&loop)) / 1e6)
	for m in ([]string{"interval 3", "string timer", "timeout args x 2", "zero"}) { wait_note(pr, m) }
	wait_note_prefix(pr, "idle number")
	check(pr, noted(pr, "ids true true"), "timer ids are positive and increasing")
	check(pr, in_order(pr, "sync", "promise", "microtask"), "microtasks after the script, in order")
	check(pr, index_of(pr, "microtask") < index_of(pr, "zero"), "microtasks before timers")
	check(pr, noted(pr, "timeout args x 2"), "setTimeout passes its extra arguments")
	check(pr, !noted(pr, "cleared ran"), "clearTimeout")
	check(pr, noted(pr, "interval 3"), "setInterval and clearInterval from its callback")
	check(pr, noted(pr, "string timer"), "a string handler runs (no policy)")
	check(pr, noted(pr, "frame number true") && !noted(pr, "cancelled frame"), "requestAnimationFrame runs with the frame time; cancelAnimationFrame")
	check(pr, noted_prefix(pr, "idle number"), "requestIdleCallback gets an IdleDeadline")
	check(pr, noted(pr, "queueMicrotask type true"), "queueMicrotask requires a function")
	close_page(pr, min_checks = 10)
}

@(test)
jsload_uncaught_errors_report_error_unhandled_rejections :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "errors", concat(`<!doctype html><body>`, PRELUDE, `<script>
window.onerror = (msg, src, line, col, err) => { log("onerror " + msg + " | " + src.endsWith("test.html") + " " + line + " " + (col > 0) + " " + (err instanceof TypeError)); return true; };
window.addEventListener("error", e => log("error event " + (e instanceof ErrorEvent) + " " + e.isTrusted + " " + e.message));
</script>
<script>null.f();</script>
<script>
window.onerror = null;
reportError(new RangeError("reported"));
const ee = new ErrorEvent("error", { message: "m", filename: "f", lineno: 3, colno: 4, error: 5 });
log("ErrorEvent ctor " + ee.message + ee.filename + ee.lineno + ee.colno + ee.error);
const late = Promise.reject("late");
window.addEventListener("unhandledrejection", e => {
  log("unhandledrejection " + e.reason + " " + (e.promise instanceof Promise));
  if (e.reason === "quiet") e.preventDefault();
  if (e.reason === "late") setTimeout(() => late.catch(() => {}), 0);   // once reported, handled later
});
window.addEventListener("rejectionhandled", e => log("rejectionhandled " + e.reason));
Promise.reject("loud");
Promise.reject("quiet");
Promise.reject("caught at once").catch(() => {});
const pre = new PromiseRejectionEvent("x", { promise: late, reason: 9 });
log("PromiseRejectionEvent ctor " + pre.reason + " " + (pre.promise === late));
</script></body>`))
	pr.expect_uncaught = true   // what this is about
	wait_note(pr, "rejectionhandled late")
	drain()
	check(pr, noted_prefix(pr, "onerror Uncaught TypeError") && has_part(pr, "| true 1 true true"), "window.onerror gets message, source, line, column, error")
	check(pr, noted_prefix(pr, "error event true true Uncaught TypeError"), "the error event is a trusted ErrorEvent")
	check(pr, !console_says(pr, "Uncaught TypeError"), "onerror returning true keeps it out of the console")
	check(pr, noted_prefix(pr, "error event true true Uncaught RangeError: reported"), "reportError reports through the error event")
	check(pr, noted(pr, "ErrorEvent ctor mf345"), "new ErrorEvent")
	check(pr, noted(pr, "unhandledrejection loud true") && noted(pr, "unhandledrejection quiet true"), "unhandledrejection for rejections nobody handled")
	check(pr, !noted(pr, "unhandledrejection caught at once true"), "a rejection handled in the same task is not reported")
	check(pr, console_says(pr, "(in promise) loud") && !console_says(pr, "(in promise) quiet"), "the console shows the rejections nobody canceled")
	check(pr, noted(pr, "rejectionhandled late"), "rejectionhandled when a reported rejection is handled later")
	check(pr, noted(pr, "PromiseRejectionEvent ctor 9 true"), "new PromiseRejectionEvent")
	close_page(pr, min_checks = 10)
}

// HTML "notify about rejected promises" runs from a task queued at the end of the checkpoint, one for each checkpoint's
// rejections: a task queued before it (a <details> given open queues its toggle) may still handle one. A classic script
// of another origin fetched without CORS reports its errors muted; a data: URL is a script's whole name.
@(test)
jsload_rejection_tasks_muted_errors :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	other_origin := testenv.url(concat("http://localhost:8765", gen(`undefined_variable_of_another_origin`)))
	pr := load(t, "rejections", concat(`<!doctype html><body>`, PRELUDE, `<script>
addEventListener("unhandledrejection", e => log("unhandledrejection " + e.reason));
addEventListener("error", e => { log("error " + e.message + "|" + e.filename + "|" + e.lineno + "|" + (e.error === null)); e.preventDefault(); });
const later = Promise.reject("later");
const d = document.createElement("details");
d.ontoggle = e => { log("toggle " + e.oldState + " " + e.newState); Promise.resolve().then(() => later.catch(() => {})); Promise.reject("in toggle"); };
d.open = true;
Promise.reject("loud");
</script><script src="`, other_origin, `"></script><script src="data:text/javascript,for(;){}"></script><script>log("last script")</script></body>`))
	pr.expect_uncaught = true   // what this is about
	wait_note(pr, "unhandledrejection in toggle")
	wait_note(pr, "last script")
	drain()
	check(pr, in_order(pr, "toggle closed open", "unhandledrejection loud", "unhandledrejection in toggle"), "the toggle task, then a notification for each checkpoint's rejections, in order")
	check(pr, !noted(pr, "unhandledrejection later"), "a task queued before the notification still handles a rejection")
	check(pr, noted(pr, "error Script error.||0|true"), "an error of another origin's script without CORS is muted")
	check(pr, has_part(pr, "|data:text/javascript,for(;){}|"), "a data: URL is the name of its script's errors, parentheses and all")
	close_page(pr, min_checks = 4)
}

has_part :: proc(pr: ^Probe, part: string) -> bool {
	for n in pr.section.notes { if strings.contains(n, part) { return true } }
	return false
}

@(test)
jsload_workers :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "workers", concat(`<!doctype html><body>`, PRELUDE, `<script>
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
</script></body>`))
	wait_note(pr, "worker closing")
	check(pr, noted(pr, "worker ready"), "a JavaScript worker starts and posts a message")
	check(pr, noted(pr, "worker clock true true true"), "a worker's performance is the browser's: now() >= 0, timeOrigin + now() is the time of day")
	check(pr, noted(pr, "transferred detaches 0"), "a transferred ArrayBuffer is detached")
	check(pr, noted(pr, "echo true 5 a true gi 3 true lib 7 name w1 true"), "structured clone both ways (Date, Map, Set, RegExp, ArrayBuffer, cycles); importScripts; name")
	check(pr, noted(pr, "worker error true true"), "an uncaught error of the worker is an ErrorEvent at the Worker")
	check(pr, noted(pr, "worker timer fired") && noted(pr, "worker rejection w"), "timers and unhandledrejection in the worker")
	check(pr, noted(pr, "worker fetch 200 true AbortError ba78"), "a worker's fetch() resolves, its abort rejects with AbortError, crypto.subtle.digest settles (tasks of the worker's realm)")
	check(pr, !noted(pr, "terminated worker spoke"), "a terminated worker sends nothing")
	check(pr, noted(pr, "cross-origin worker SecurityError"), "a cross-origin worker is refused")
	check(pr, noted(pr, "function not cloneable DataCloneError"), "a function is not cloneable")
	close_page(pr, min_checks = 10)
}

@(test)
jsload_structured_clone :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "clone", concat(`<!doctype html><body>`, PRELUDE, `<script>
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
</script></body>`))
	wait_note(pr, "transfer 0")
	check(pr, noted(pr, "clone true true false x true true true true true t 1"), "structuredClone keeps cycles, holes, extra properties, BigInt, wrappers, -0, undefined, errors")
	check(pr, noted(pr, "views 2.5 2.5 true"), "typed arrays and DataView share their cloned buffer")
	check(pr, noted(pr, "symbol DataCloneError") && noted(pr, "node DataCloneError"), "symbols and platform objects throw DataCloneError")
	check(pr, noted(pr, "transfer 0"), "structuredClone with transfer detaches")
	close_page(pr, min_checks = 4)
}

@(test)
jsload_integrity_preload_the_window_in_the_event_path :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	code := `log("integrity ok")`
	good := page.digest_base64("sha256", transmute([]byte)string(code))
	once := gen(`log("fetched once")`, ARRIVES_LATE_MS, "&k=once")
	pr := load(t, "integrity", concat(`<!doctype html><body>`, PRELUDE,
		`<script src="`, gen(code, 0, "&k=sri"), `" integrity="sha256-`, good, `"></script>`,
		`<script src="`, gen(`log("tampered ran")`, 0, "&k=bad"), `" integrity="sha256-AAAA" onerror="log('integrity mismatch: error')"></script>`,
		`<script src="`, once, `"></script>`,
		`<button id=b>b</button><script>
window.addEventListener("click", e => log("window capture " + e.eventPhase), true);
window.addEventListener("click", e => log("window bubble " + e.eventPhase + " " + (e.currentTarget === window)));
document.getElementById("b").addEventListener("click", () => log("target"));
document.getElementById("b").dispatchEvent(new Event("click", { bubbles: true }));
</script></body>`))
	wait_note(pr, "window bubble 3 true")
	check(pr, noted(pr, "integrity ok"), "a script matching its integrity runs")
	check(pr, !noted(pr, "tampered ran") && noted(pr, "integrity mismatch: error"), "a script that does not match is not run: error event")
	check(pr, in_order(pr, "window capture 1", "target", "window bubble 3 true"), "the window is the last step of a document event's path (capture first, bubble last)")
	n := hits(t, once)
	check(pr, n == 1, fmt.tprintf("a parser script is downloaded once (the preload is claimed by its element): %d download(s)", n))
	close_page(pr, min_checks = 4)
}

// <link rel=stylesheet> fires load / error (link_events.odin), without anything being rendered (this tool lays out nothing): a link
// inserted by a script is fetched at once, its load waits for the @import its sheet has, a failed one fires error, and one pointed
// elsewhere before its sheet came fires only for the new address. (Turbopack and Next.js load CSS chunks this way and go on in onload:
// DuckDuckGo's home page waited for ever.)
@(test)
jsload_stylesheet_links_fire_load_and_error :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	imported := css("b { color: green }", SHEET_IMPORTED_MS, "imp")
	with_import := css(concat(`@import url("`, imported, `"); p { color: red }`), 0, "outer")
	pr := load(t, "link events", concat(`<!doctype html><head>`, PRELUDE, `</head><body><p id=t>x</p><b id=bb>b</b><script>
function add(name, href, then) {
  const l = document.createElement("link");
  l.rel = "stylesheet";
  l.onload = () => log(name + " load" + (then ? " " + then() : ""));
  l.onerror = () => log(name + " error");
  l.href = href;
  document.head.appendChild(l);
  return l;
}
add("plain", "`, css("p { margin: 1px }", ARRIVES_SOON_MS, "plain"), `");
add("missing", "`, gen("p {}", 0, "&type=text/css&status=404&k=missing"), `");
add("imports", "`, with_import, `", () => getComputedStyle(document.getElementById("bb")).color);
const moved = add("moved", "`, css("p {}", SHEET_LEFT_MS, "first"), `");
moved.href = "`, css("p {}", 0, "second"), `";
add("after the one left", "`, css("p {}", SHEET_AFTER_LEFT_MS, "after"), `");
</script></body>`))
	for m in ([]string{"plain load", "missing error", "imports load rgb(0, 128, 0)", "moved load", "after the one left load"}) { wait_note(pr, m) }
	check(pr, noted(pr, "plain load"), "a link a script inserts fires load once its sheet is in (nothing rendered)")
	check(pr, noted(pr, "missing error") && !noted(pr, "missing load"), "a link whose sheet failed (HTTP 404) fires error")
	check(pr, noted(pr, "imports load rgb(0, 128, 0)"), "a link whose sheet has an @import fires load once the imported sheet applies too")
	n := hits(t, imported)
	check(pr, n == 1, fmt.tprintf("the @import was fetched before that load (%d request(s))", n))
	moved := 0
	for l in pr.section.notes { if l == "moved load" { moved += 1 } }
	check(pr, moved == 1, fmt.tprintf("a link pointed elsewhere before its sheet came fires load once, for the new sheet (%d)", moved))
	close_page(pr, min_checks = 5)
}

// Render-blocking: the parser's <link> holds the first paint back, one a script inserts does not.
@(test)
jsload_stylesheets_and_the_first_paint :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "first paint", concat(`<!doctype html><head>`, PRELUDE, `<link rel=stylesheet href="`, css("p { color: red }", SHEET_BLOCKING_MS, "parser"),
		`" onload="log('parser link load')"></head><body><script>
const l = document.createElement("link");
l.rel = "stylesheet"; l.href = "`, css("p { color: blue }", SHEET_NEVER_WAITED_FOR_MS, "late"), `";
document.head.appendChild(l);
log("inserted");
</script></body>`))
	st, why := page.first_paint_state(pr.p)
	check(pr, st == .Blocked && strings.contains(why, "parser"), fmt.tprintf("the parser's stylesheet blocks the first paint (%v %s)", st, why))
	// (the inline script waits for that stylesheet: javascript.load.scripts_wait_for_stylesheets)
	wait_note(pr, "parser link load")
	wait_note(pr, "inserted")
	st, why = page.first_paint_state(pr.p)
	check(pr, st == .Ready, fmt.tprintf("a stylesheet a script inserted does not block it (%v %s)", st, why))
	close_page(pr, min_checks = 2)
}

// The parser's script that waits for a stylesheet, and the load event, go on once the sheet is in and its load event
// fired: not at the next look of the poll (javascript.load.poll_ms, set here past the test's wait; 16 ms by default, the
// first realm's script on shadow-dom.html ran 25 ms after its sheets).
@(test)
jsload_a_sheet_in_lets_the_parser_and_the_load_go_on :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	settings.js_load.poll_ms = POLL_NEVER_MS
	pr := load(t, "sheet in", concat(`<!doctype html><head>`, PRELUDE, `<link rel=stylesheet href="`, css("p { color: red }", ARRIVES_SOON_MS, "nopoll"),
		`"><script>log("after the sheet"); addEventListener("load", () => log("loaded"))</script></head><body><p>x</p></body>`))
	check(pr, wait_note(pr, "after the sheet", SHEET_IN_WAIT_SECONDS), "the parser's script ran once the sheet was in")
	check(pr, wait_note(pr, "loaded", SHEET_IN_WAIT_SECONDS), "the load event fired once the sheet's load event had")
	close_page(pr, min_checks = 2)
}

// Scripts that are ready do not run back to back for ever: past the slice the loop gets a turn (a frame, what the network brought; here
// the page's own timer) between two of them. They ran in one go before: bbc.com painted 3 s after its document was interactive.
@(test)
jsload_ready_scripts_give_the_loop_a_turn :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	settings.js_load.pump_slice_ms = PUMP_SLICE_MS
	first := fmt.tprintf(`setTimeout(() => log("a turn of the loop"), 0); const end = performance.now() + %d; while (performance.now() < end); log("first script")`, PUMP_SCRIPT_MS)
	pr := load(t, "turn", concat(`<!doctype html><head>`, PRELUDE, `<script defer src="`, gen(first, ARRIVES_SOON_MS, "&k=turn1"), `"></script>`,
		`<script defer src="`, gen(`log("second script")`, ARRIVES_SOON_MS, "&k=turn2"), `"></script></head><body><p>x</p></body>`))
	wait_note(pr, "second script")
	check(pr, in_order(pr, "first script", "a turn of the loop") && in_order(pr, "a turn of the loop", "second script"), "the loop had a turn between the two scripts")
	close_page(pr, min_checks = 1)
}

// A script turns the parser's <link> into something else while the document is parsed: the scripts after it (which wait for pending
// stylesheets) do not wait for it for ever.
@(test)
jsload_a_link_whose_rel_changed_does_not_hold_the_parser :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "rel changed", concat(`<!doctype html><head>`, PRELUDE, `<link id=l rel=stylesheet href="`, css("p {}", SHEET_REL_CHANGED_MS, "relchange"),
		`"></head><body><script>document.getElementById("l").rel = "expect"; log("rel changed")</script><p>x</p>`,
		`<script src="`, gen(`log("script after the change ran")`, SCRIPT_AFTER_REL_CHANGE_MS, "&k=after"), `"></script>`,
		`<script>document.addEventListener("DOMContentLoaded", () => log("relchange dcl"))</script></body>`))
	wait_note(pr, "relchange dcl")
	check(pr, noted(pr, "rel changed") && in_order(pr, "script after the change ran", "relchange dcl"), "a parser link whose rel a script changed does not hold the parser")
	close_page(pr, min_checks = 1)
}

@(test)
jsload_twenty_external_scripts :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<!doctype html><head>`)
	strings.write_string(&sb, PRELUDE)
	for i in 0 ..< EXTERNAL_SCRIPTS {
		fmt.sbprintf(&sb, `<script src="%s"></script>`, gen(fmt.tprintf(`window.s%d = %d`, i, i), 0, fmt.tprintf("&m=%d", i)))
		fmt.sbprintf(&sb, `<p>paragraph %d</p>`, i)
	}
	strings.write_string(&sb, `<script>document.addEventListener("DOMContentLoaded", () => log("dcl20"))</script></head><body></body>`)
	pr := load(t, "20 scripts", strings.to_string(sb))
	check(pr, wait_note(pr, "dcl20"), "20 scripts: DOMContentLoaded")
	timing := page.scripts_timing(pr.p)
	log.infof("MEASURE 20 external scripts: DOMContentLoaded %.1f ms after the document was parsed (scripts %d)", timing.dcl_ms - timing.started_ms, timing.scripts_run)
	close_page(pr, min_checks = 1)

	// the same, already in the bytecode cache and the scripts of the second load in memory
	pr = load(t, "20 scripts again", strings.to_string(sb))
	check(pr, wait_note(pr, "dcl20"), "20 scripts, in the cache: DOMContentLoaded")
	timing = page.scripts_timing(pr.p)
	log.infof("MEASURE 20 external scripts, second load: DOMContentLoaded %.1f ms after parsing", timing.dcl_ms - timing.started_ms)
	close_page(pr, min_checks = 1)
}

// A large script that says it ran (`log` of its load event).
big :: proc(attributes, id: string) -> string {
	return fmt.tprintf(`<script %s src="/jsload/big?kb=512&id=%s" onload="wrenTest.note('big %s 512')"></script>`, attributes, id, id)
}

@(test)
jsload_large_scripts_compile_off_thread :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	settings.js.offthread_min_bytes = OFFTHREAD_MIN_BYTES
	before := page.compile_stats()
	start := time.tick_now()
	pr := load(t, "large scripts", concat(`<!doctype html><head>`, big("", "a"), big("", "b"), `<script>wrenTest.note("bigs done")</script></head>`))
	wait_note(pr, "bigs done")
	ms := time.duration_milliseconds(time.tick_since(start))
	after := page.compile_stats()
	log.infof("MEASURE 2 x 512 KiB scripts compiled off-thread: %d jobs, %.1f ms of compilation on %d thread(s); page done in %.1f ms", after.jobs - before.jobs, after.total_ms - before.total_ms, after.threads, ms)
	check(pr, after.jobs - before.jobs == 2, "large scripts are compiled on the compile threads")
	check(pr, noted(pr, "big a 512") && noted(pr, "big b 512"), "and run from the bytecode they made")
	close_page(pr, min_checks = 2)
}

// A classic script of another origin, fetched without CORS (the scripts of a CDN), runs from what the compile thread made of it: one
// compilation, not a second one on the interface thread. Its errors are muted, which the bytecode does not know.
@(test)
jsload_a_large_script_of_another_origin_compiles_once :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	settings.js.offthread_min_bytes = OFFTHREAD_MIN_BYTES
	other_origin := testenv.url("http://localhost:8765/jsload/big?kb=512&id=cdn")
	jobs, hits := page.compile_stats().jobs, js.cache_stats().memory_hits
	pr := load(t, "a script of another origin", concat(`<!doctype html><head><script src="`, other_origin, `"></script><script>wrenTest.note("cdn done")</script></head>`))
	wait_note(pr, "cdn done")
	check(pr, page.compile_stats().jobs - jobs == 1, "it went to a compile thread")
	check(pr, js.cache_stats().memory_hits - hits == 1, "and ran from that bytecode")
	close_page(pr, min_checks = 2)
}

// The module waits for its bytecode, then it is prepared from the cache.
@(test)
jsload_large_modules_compile_off_thread :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	settings.js.offthread_min_bytes = OFFTHREAD_MIN_BYTES
	before := page.compile_stats()
	start := time.tick_now()
	pr := load(t, "large modules", concat(`<!doctype html><head>`, big("type=module", "ma"), big("type=module", "mb"), `<script type=module>wrenTest.note("big modules done")</script></head>`))
	wait_note(pr, "big modules done")
	ms := time.duration_milliseconds(time.tick_since(start))
	wait_note(pr, "big mb 512")
	after := page.compile_stats()
	log.infof("MEASURE 2 x 512 KiB modules compiled off-thread: %d jobs, %.1f ms of compilation; page done in %.1f ms", after.jobs - before.jobs, after.total_ms - before.total_ms, ms)
	check(pr, after.jobs - before.jobs == 2, "large modules are compiled on the compile threads")
	check(pr, noted(pr, "big ma 512") && noted(pr, "big mb 512"), "and run from the bytecode they made")
	close_page(pr, min_checks = 2)
}

// A compile longer than a page's call may be: no deadline on the compile threads (they take the settings of the page that starts them).
@(test)
jsload_a_compile_past_the_limit_of_a_call_goes_on :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	page.compile_shutdown()
	defer page.compile_shutdown()
	settings.js.offthread_min_bytes = OFFTHREAD_MIN_BYTES
	settings.wasm.max_call_ms = SHORT_CALL_MS
	before := page.compile_stats()
	pr := load(t, "long compile", `<!doctype html><head><script src="/jsload/big?kb=4096&id=long"></script><script>wrenTest.note("long done")</script></head>`)
	wait_note(pr, "long done")
	after := page.compile_stats()
	check(pr, after.jobs - before.jobs == 1 && after.failed == before.failed, "a compile past wasm.max_call_ms goes on, on its thread")
	close_page(pr, min_checks = 1)
}

@(test)
jsload_no_compile_thread_compiles_on_the_interface_thread :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	settings.js.offthread_min_bytes = OFFTHREAD_MIN_BYTES
	settings.js_load.compile_threads = 0
	before := page.compile_stats()
	start := time.tick_now()
	pr := load(t, "no compile thread", concat(`<!doctype html><head>`, big("", "c"), big("", "d"), `<script>wrenTest.note("bigs done")</script></head>`))
	wait_note(pr, "bigs done")
	log.infof("MEASURE the same compiled on the interface thread: page done in %.1f ms", time.duration_milliseconds(time.tick_since(start)))
	check(pr, page.compile_stats().jobs == before.jobs && noted(pr, "big c 512") && noted(pr, "big d 512"), "with no compile thread the scripts are compiled where they run")
	close_page(pr, min_checks = 1)
}

// setTimeout: the cost of a call (with its clearTimeout), and a round trip through the event loop, in real time: that is the measure.
@(test)
jsload_a_chain_of_timers :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "setTimeout", concat(`<!doctype html><body>`, PRELUDE, `<script>window.noop = () => {}; log("ready")</script></body>`))
	wait_note(pr, "ready")
	start := time.tick_now()
	run(pr, fmt.tprintf(`for (let i = 0; i < %d; i++) {{}}`, TIMER_PAIRS))
	empty := time.duration_microseconds(time.tick_since(start))
	start = time.tick_now()
	run(pr, fmt.tprintf(`for (let i = 0; i < %d; i++) clearTimeout(setTimeout(noop, 0))`, TIMER_PAIRS))
	pairs := time.duration_microseconds(time.tick_since(start))
	log.infof("MEASURE setTimeout(f, 0) + clearTimeout: %.2f us per pair", (pairs - empty) / TIMER_PAIRS)
	run(pr, fmt.tprintf(`let hops = 0; const hop = () => {{ if (++hops === %d) log("hops done"); else setTimeout(hop, 0); }}; setTimeout(hop, 0);`, HOPS))
	start = time.tick_now()
	// spinning (no wait in the OS, whose timer resolution would be measured instead), bounded only for a failing run
	for !noted(pr, "hops done") && time.duration_seconds(time.tick_since(start)) < PAGE_LIMIT_SECONDS { host.loop_wait(&loop, 0) }
	log.infof("MEASURE setTimeout(0) round trip: %.3f ms per hop over %d (HTML clamps to 4 ms past 5 nested levels)", time.duration_milliseconds(time.tick_since(start)) / HOPS, HOPS)
	check(pr, noted(pr, "hops done"), "setTimeout(0) chain")
	close_page(pr, min_checks = 1)
}

// requestAnimationFrame: from the shell's frame (run_animation_frames) to the callback running.
@(test)
jsload_animation_frames :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	pr := load(t, "requestAnimationFrame", concat(`<!doctype html><body>`, PRELUDE, fmt.tprintf(`<script>
window.n = 0; const go = () => requestAnimationFrame(ts => {{ log("raf " + (++n)); if (n < %d) go(); }}); go(); log("asked");
</script></body>`, RAF_FRAMES)))
	wait_note(pr, "asked")
	last := fmt.tprintf("raf %d", RAF_FRAMES)
	total: f64
	frames := 0
	for _ in 0 ..< RAF_TRIES {
		before := len(pr.section.notes)
		start := time.tick_now()
		page.run_animation_frames(pr.p, f64(host.now_ns(&loop)) / 1e6)
		if len(pr.section.notes) > before { total += time.duration_microseconds(time.tick_since(start)); frames += 1 }
		host.loop_wait(&loop, 0)
		if noted(pr, last) { break }
	}
	log.infof("MEASURE requestAnimationFrame: %.1f us from the frame to the end of the callback (%d frames)", total / f64(max(frames, 1)), frames)
	check(pr, noted(pr, last) && frames == RAF_FRAMES, fmt.tprintf("%d animation frames, one callback each (%d)", RAF_FRAMES, frames))
	close_page(pr, min_checks = 1)
}
