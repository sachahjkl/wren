package e2e_scenarios

// Browser extensions, phase 1 (docs/extensions.md): the fixture examples/extensions/hello is loaded from about:extensions
// (its folder typed in), the install prompt accepted, its button is there, its popup page runs with the extension APIs:
// messages to the background (callback, promise, answer after the listener returned, no answer), ports both ways and
// their end, storage.local and session, storage.onChanged reaching the background, runtime.onInstalled, i18n, the
// manifest, and what its permissions leave out. Then the test that breaks this design if anything is off: calls of the
// popup while the background is stopped, queued in order, answered in order once it started. Reload and remove leave
// no extension and no background.

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:e2e"
import "wb:extensions"
import "wb:page"
import "wb:url"

@(private = "file") EXT_SIZE :: [2]int{1000, 700}

@(private = "file")
ext_id_on_page :: proc(s: ^e2e.Session) -> string {
	return e2e.eval(s, `(() => { const a = document.querySelector('a[href*="accept="]'); return a ? a.getAttribute("href").split("accept=")[1] : ""; })()`)
}

@(test)
extensions_load_popup_background :: proc(t: ^testing.T) {
	// a short idle: the background stops between the steps that need it stopped (what ends it is waited for)
	s := e2e.start(t, {size = EXT_SIZE, prefs = {"extensions.background.idle_ms=1000", "extensions.background.port_keepalive_ms=0"}})
	dir := fmt.tprintf("%s/examples/extensions/hello", e2e.repo_root())
	e2e.navigate(s, fmt.tprintf("about:extensions?path=%s", url.percent_encoded(dir, url.UNRESERVED + "/:")))
	e2e.wait_js(s, `document.body.textContent.includes("Add Hello extension?")`)
	id := strings.clone(ext_id_on_page(s), context.temp_allocator)
	if !testing.expectf(t, extensions.id_valid(id), "the install prompt names the extension's id (got %q)", id) { return }
	e2e.expect_eval(s, `document.body.textContent.includes("Read and change your data on https://example.com/*")`, "true", "the prompt says which sites it asks for, in plain words")

	e2e.navigate(s, fmt.tprintf("about:extensions?accept=%s", id))
	e2e.wait_js(s, `document.body.textContent.includes("Hello extension is installed.")`)
	{
		context = s.ctx
		reg := &s.app.pages.extensions
		e := extensions.registry_find(reg, id)
		testing.expect(t, e != nil && e.enabled && e.image != nil && e.image.manifest.has_action)   // (its toolbar button: ext_toolbar_buttons)
		testing.expect(t, e != nil && len(e.granted) == 1 && e.granted[0] == "https://example.com/*")
	}

	// the popup's page (what a click on the button opens): its text comes from the catalogue, its answer from the background
	popup := fmt.tprintf("chrome-extension://%s/popup.html", id)
	e2e.navigate(s, popup)
	e2e.wait_js(s, `document.getElementById("answer").textContent === "background: ready"`)
	e2e.expect_eval(s, `document.getElementById("title").textContent`, "The popup of the Hello extension", "i18n.getMessage")
	e2e.expect_eval(s, `chrome.i18n.getMessage("greeting", ["test"])`, "Hello test!", "a placeholder with a substitution")
	e2e.expect_eval(s, `chrome.runtime.getManifest().name`, "Hello extension", "getManifest: the messages put in")
	e2e.expect_eval(s, `chrome.runtime.id`, id, "runtime.id")
	e2e.expect_eval(s, `chrome.runtime.getURL("/a/b.png")`, fmt.tprintf("chrome-extension://%s/a/b.png", id), "runtime.getURL")
	e2e.expect_eval(s, `String(isSecureContext) + " " + location.origin`, fmt.tprintf("true chrome-extension://%s", id), "the extension origin: a secure context, a tuple origin")

	// messages
	e2e.expect_eval(s, `new Promise((ok) => chrome.runtime.sendMessage({type: "echo", value: "cb"}, (r) => ok(r.echo + " " + (r.from === location.href) + " " + (chrome.runtime.lastError === undefined))))`, "cb true true", "sendMessage with a callback; the sender's URL")
	e2e.expect_eval(s, `chrome.runtime.sendMessage({type: "later", value: 7}).then((r) => String(r.later))`, "7", "an answer after the listener returned true")
	e2e.expect_eval(s, `chrome.runtime.sendMessage({type: "promise", value: "p"}).then((r) => r.promised)`, "p", "an answer given as a promise")
	e2e.expect_eval(s, `chrome.runtime.sendMessage({type: "ignored"}).then((r) => String(r))`, "undefined", "no listener answers: undefined")
	e2e.expect_eval(s, `chrome.runtime.sendMessage("abcdefghijklmnopabcdefghijklmnop", {type: "echo"}, {}).then(() => "answered", (e) => e.message)`, "Could not establish connection. Receiving end does not exist.", "another extension's id: no receiver (no message between extensions)")

	// ports, both ways, and their end
	e2e.expect_eval(s, `new Promise((ok) => { const p = chrome.runtime.connect({name: "n"}); p.onMessage.addListener((m) => ok(m.echo + " " + m.name)); p.postMessage("hi"); })`, "hi n", "a port: a message there and back, with its name")
	e2e.expect_eval(s, `new Promise((ok) => { const p = chrome.runtime.connect({name: "c"}); p.onDisconnect.addListener(() => { try { p.postMessage(1); ok("still open"); } catch (e) { ok("closed"); } }); p.postMessage("close"); })`, "closed", "the other end's disconnect fires onDisconnect")

	// storage
	e2e.expect_eval(s, `chrome.storage.local.set({a: 1, b: {c: [true, "x"]}}).then(() => chrome.storage.local.get(["a", "b", "z"])).then((r) => JSON.stringify(r))`, `{"a":1,"b":{"c":[true,"x"]}}`, "storage.local set and get")
	e2e.expect_eval(s, `chrome.storage.local.get({z: "default"}).then((r) => r.z)`, "default", "get with defaults")
	e2e.expect_eval(s, `chrome.storage.local.remove("a").then(() => chrome.storage.local.get(null)).then((r) => String("a" in r) + " " + String("b" in r))`, "false true", "remove")
	e2e.expect_eval(s, `new Promise((ok) => { const go = () => chrome.storage.local.get("installed").then((r) => r.installed ? ok(r.installed) : setTimeout(go, 20)); go(); })`, "install", "runtime.onInstalled reached the background once its listeners were known")
	e2e.expect_eval(s, `chrome.storage.local.set({ping: 42}).then(() => new Promise((ok) => { const go = () => chrome.storage.session.get("pong").then((r) => r.pong ? ok(String(r.pong)) : setTimeout(go, 20)); go(); }))`, "42", "storage.onChanged in the background; storage.session")
	e2e.expect_eval(s, `new Promise((ok) => { chrome.storage.onChanged.addListener((c, area) => ok(area + " " + c.k.newValue)); chrome.storage.local.set({k: "v"}); })`, "local v", "storage.onChanged in the page that wrote")

	// what its permissions leave out is absent
	e2e.expect_eval(s, `[typeof chrome.tabs.create, typeof chrome.contextMenus, typeof chrome.scripting, typeof chrome.alarms.create, typeof chrome.storage.local.get].join(" ")`, "undefined undefined undefined function function", "an API outside the phase or the permissions is undefined")
	e2e.expect_eval(s, `chrome.permissions.contains({origins: ["https://example.com/a*"]}).then(String)`, "true", "permissions.contains: a granted host")
	e2e.expect_eval(s, `chrome.permissions.contains({permissions: ["tabs"]}).then(String)`, "false", "permissions.contains: a permission it did not ask for")
	e2e.expect_eval(s, `chrome.management.getSelf().then((m) => m.name + " " + m.installType)`, "Hello extension development", "management.getSelf")

	// The test that breaks this design on day one: the background is stopped; the popup asks storage.local.get and
	// queues two messages at once. The background starts in between; the answers come in order, none is lost.
	{
		Wait :: struct { id: string }
		w := Wait{id = id}
		e2e.wait_until(s, &w, proc(s: ^e2e.Session, w: ^Wait) -> bool {
			context = s.ctx
			_, running, _ := page.ext_bg_state(w.id)
			return !running
		}, "the background to stop when idle (extensions.background.idle_ms)")
	}
	e2e.expect_eval(s, `(() => { const order = []; return Promise.all([
	    chrome.storage.local.get("b").then((r) => { order.push("get"); return r.b.c[1]; }),
	    chrome.runtime.sendMessage({type: "echo", value: 1}).then((r) => { order.push("m1"); return r.echo; }),
	    chrome.runtime.sendMessage({type: "echo", value: 2}).then((r) => { order.push("m2"); return r.echo; }),
	  ]).then((a) => a.join(",") + " " + order.join(","))})()`, "x,1,2 get,m1,m2", "calls and messages while the background is stopped: in order, all answered")
	{
		context = s.ctx
		_, running, starts := page.ext_bg_state(id)
		testing.expectf(t, running && starts >= 2, "the background started again for the message (started %d times)", starts)
	}

	// reload and remove
	e2e.navigate(s, fmt.tprintf("about:extensions?reload=%s", id))
	e2e.wait_js(s, `document.body.textContent.includes("Reloaded.")`)
	e2e.navigate(s, fmt.tprintf("about:extensions?remove=%s", id))
	e2e.wait_js(s, `document.body.textContent.includes("Hello extension was removed.")`)
	{
		context = s.ctx
		testing.expect(t, extensions.registry_find(&s.app.pages.extensions, id) == nil)
		exists, _, _ := page.ext_bg_state(id)
		testing.expect(t, !exists, "no background is left")
	}
	e2e.navigate(s, popup)
	e2e.expect_eval(s, `typeof chrome`, "undefined", "a page of a removed extension does not load (and has no chrome.*)")
}
