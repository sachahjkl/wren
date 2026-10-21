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
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:js"
import "wb:net"
import "wb:page"
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
});
</script></body>`, child))
		check(wait_for(fill("parent got hello from child %s true | %s true", testenv.url(OTHER), testenv.url(OTHER))), "a cross-origin frame posts to its parent: origin and source")
		check(wait_for(fill("parent got child refused SecurityError | %s true", testenv.url(OTHER))), "the child cannot reach its parent's document")
		check(wait_for(fill("parent got child got ping from %s true | %s true", testenv.url(SAME), testenv.url(OTHER))), "the parent posts to the frame with its origin as targetOrigin; the frame sees the parent as source")
		check(wait_for(fill("parent got child got [object Object] from %s true | %s true", testenv.url(SAME), testenv.url(OTHER))), "structured clone of an object across documents")
		run_for(300)
		check(!logged_contains("child got wrong origin"), "a message whose targetOrigin does not match is dropped")
		check(logged("refused document:SecurityError foo:SecurityError alert:SecurityError set:SecurityError href:SecurityError function true true true true true false 0 null undefined"), "a cross-origin WindowProxy: only the members HTML allows")
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

	base.scope_close(process)
	js.cache_stop()
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures > 0 ? 1 : 0)
}

_ :: dom
