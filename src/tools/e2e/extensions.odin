package e2e_scenarios

// Browser extensions, phase 1 (docs/extensions.md): the fixture examples/extensions/hello is loaded from about:extensions
// (its folder typed in), the install prompt accepted, its button is there, its popup page runs with the extension APIs:
// messages to the background (callback, promise, answer after the listener returned, no answer), ports both ways and
// their end, storage.local and session, storage.onChanged reaching the background, runtime.onInstalled, i18n, the
// manifest, and what its permissions leave out. Then the test that breaks this design if anything is off: calls of the
// popup while the background is stopped, queued in order, answered in order once it started. Reload and remove leave
// no extension and no background.
//
// The popup panel (extensions_popup_panel): the popup shows under its button, sized by its content; a click and a key
// reach its document; Escape, window.close() and a press outside close it.
//
// Phase 2 (extensions_vault_packed_offscreen_tabs, extensions_vault_restart): the fixture examples/extensions/vault,
// packed here into a .zip and a .crx and installed from them; an offscreen document that writes the clipboard for the
// background, one at a time; the popup's own clipboard with no click; tabs.create, its events and tabs.remove; the
// popout window and its end; runtime.getContexts; the idle state and its event; then a restart: the extension comes
// back from the profile with its id, and its background, whose listeners were kept, does not run until an event it
// listens to comes.
//
// Phase 3 (extensions_content_scripts_autofill): the fixture examples/extensions/autofill fills the login form of
// examples/site/extensions/login.html from content scripts in an isolated world, in a page with a frame of another
// origin; then scripting, tabs.sendMessage, tabs.connect and webNavigation from the extension's page.

import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:browser"
import "wb:e2e"
import "wb:extensions"
import "wb:host"
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
	e2e.expect_eval(s, `[typeof chrome.idle, typeof chrome.contextMenus, typeof chrome.scripting, typeof chrome.offscreen, typeof chrome.alarms.create, typeof chrome.storage.local.get].join(" ")`, "undefined undefined undefined undefined function function", "an API outside the phase or the permissions is undefined")
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

////////////////////////////////
// The popup panel

// The popup of the hello fixture opens in a panel under its button (browser.ext_open_popup: what a click on the button
// does), as a page of no window sized by its content (its body: 280 px wide and 16 px of padding); a click and a key
// reach its document; Escape closes it; it closes itself with window.close(); a press outside closes it.
@(test)
extensions_popup_panel :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = EXT_SIZE})
	dir := fmt.tprintf("%s/examples/extensions/hello", e2e.repo_root())
	e2e.navigate(s, fmt.tprintf("about:extensions?path=%s", url.percent_encoded(dir, url.UNRESERVED + "/:")))
	e2e.wait_js(s, `document.body.textContent.includes("Add Hello extension?")`)
	id := strings.clone(ext_id_on_page(s), context.temp_allocator)
	e2e.navigate(s, fmt.tprintf("about:extensions?accept=%s", id))
	e2e.wait_js(s, `document.body.textContent.includes("Hello extension is installed.")`)
	tabs_before := 0
	{
		context = s.ctx
		tabs_before = len(s.app.windows[0].tabs)
	}

	popup_open(s, id, "popup.html")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool {
		context = s.ctx
		ep := s.app.ext.popup
		return ep != nil && ep.fit.shown && ep.view.ready && ep.view.rect.max.x > ep.view.rect.min.x && popup_title(s) == "Hello popup"
	}, "the popup's panel to show its page")
	rect: [2]f64
	{
		context = s.ctx
		ep := s.app.ext.popup
		testing.expectf(t, ep.fit.css.x == 312, "the panel is as wide as the popup's body (got %v)", ep.fit.css)
		testing.expectf(t, ep.fit.css.y >= 25 && ep.fit.css.y < 600, "the panel is as tall as its content (got %v)", ep.fit.css)
		testing.expect_value(t, len(s.app.windows[0].tabs), tabs_before)   // (the popup is no tab of the window)
		testing.expect(t, ep.view.tab.view == &ep.view, "its tab is a view's")
		r := ep.view.rect
		rect = {f64((r.min.x + r.max.x) / 2), f64((r.min.y + r.max.y) / 2)}
	}
	e2e.click_at(s, rect, .Window)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { context = s.ctx; return popup_title(s) == "clicked" }, "a click in the panel to reach the popup's document")
	e2e.key(s, "a")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { context = s.ctx; return popup_title(s) == "key a" }, "a key to reach the popup's document")
	e2e.key(s, "Escape")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { context = s.ctx; return s.app.ext.popup == nil }, "Escape to close the popup")

	// window.close() from the popup closes it
	popup_open(s, id, "popup.html?close")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { context = s.ctx; return s.app.ext.popup == nil }, "window.close() to close the popup")

	// a press outside it closes it
	popup_open(s, id, "popup.html")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool {
		context = s.ctx
		ep := s.app.ext.popup
		return ep != nil && ep.fit.shown && ep.view.rect.max.x > ep.view.rect.min.x
	}, "the popup's panel to show again")
	e2e.click_at(s, {10, f64(EXT_SIZE.y - 10)}, .Window)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { context = s.ctx; return s.app.ext.popup == nil }, "a press outside to close the popup")
	{
		context = s.ctx
		testing.expect_value(t, len(s.app.windows[0].tabs), tabs_before)
	}
}

// Opens the extension's popup as its button does.
@(private = "file")
popup_open :: proc(s: ^e2e.Session, id, path: string) {
	context = s.ctx
	e := extensions.registry_find(&s.app.pages.extensions, id)
	if e == nil { return }
	browser.ext_open_popup(s.app, e, path)
}

// The title of the popup's document ("" : no popup, or no document yet).
@(private = "file")
popup_title :: proc(s: ^e2e.Session) -> string {
	ep := s.app.ext.popup
	if ep == nil || ep.view.tab == nil || ep.view.tab.page == nil || ep.view.tab.page.doc == nil { return "" }
	return browser.document_title(ep.view.tab.page.doc)
}

////////////////////////////////
// Phase 2

@(private = "file")
VAULT_FILES := [?]string{"manifest.json", "background.js", "offscreen.html", "offscreen.js", "popup.html", "popup.js", "page.html"}

@(private = "file")
put16 :: proc(b: ^[dynamic]byte, v: u16) {
	x: [2]byte
	endian.put_u16(x[:], .Little, v)
	append(b, ..x[:])
}

@(private = "file")
put32 :: proc(b: ^[dynamic]byte, v: u32) {
	x: [4]byte
	endian.put_u32(x[:], .Little, v)
	append(b, ..x[:])
}

// The fixture's files as a zip (stored entries), or as a CRX3 whose header names `crx_key` as its public key.
@(private = "file")
pack_vault :: proc(crx_key := "") -> []byte {
	dir := fmt.tprintf("%s/examples/extensions/vault", e2e.repo_root())
	out := make([dynamic]byte, 0, 16 * 1024, context.temp_allocator)
	central := make([dynamic]byte, 0, 1024, context.temp_allocator)
	for name in VAULT_FILES {
		data := transmute([]byte)e2e.read_text(fmt.tprintf("%s/%s", dir, name))
		crc := hash.crc32(data)
		local := u32(len(out))
		put32(&out, 0x04034b50); put16(&out, 20); put16(&out, 0); put16(&out, 0); put16(&out, 0); put16(&out, 0)
		put32(&out, crc); put32(&out, u32(len(data))); put32(&out, u32(len(data))); put16(&out, u16(len(name))); put16(&out, 0)
		append(&out, ..transmute([]byte)name)
		append(&out, ..data)
		put32(&central, 0x02014b50); put16(&central, 20); put16(&central, 20); put16(&central, 0); put16(&central, 0)
		put16(&central, 0); put16(&central, 0); put32(&central, crc); put32(&central, u32(len(data))); put32(&central, u32(len(data)))
		put16(&central, u16(len(name))); put16(&central, 0); put16(&central, 0); put16(&central, 0); put16(&central, 0)
		put32(&central, 0); put32(&central, local)
		append(&central, ..transmute([]byte)name)
	}
	cd_at := u32(len(out))
	append(&out, ..central[:])
	put32(&out, 0x06054b50); put16(&out, 0); put16(&out, 0); put16(&out, u16(len(VAULT_FILES))); put16(&out, u16(len(VAULT_FILES)))
	put32(&out, u32(len(central))); put32(&out, cd_at); put16(&out, 0)
	if crx_key == "" { return out[:] }
	// CrxFileHeader { 2: AsymmetricKeyProof { 1: public_key } } (protobuf; lengths below 128: one byte each)
	proof := make([dynamic]byte, 0, 64, context.temp_allocator)
	append(&proof, 0x0A, byte(len(crx_key)))
	append(&proof, ..transmute([]byte)crx_key)
	header := make([dynamic]byte, 0, 64, context.temp_allocator)
	append(&header, 0x12, byte(len(proof)))
	append(&header, ..proof[:])
	crx := make([dynamic]byte, 0, len(out) + 64, context.temp_allocator)
	append(&crx, ..transmute([]byte)string("Cr24"))
	put32(&crx, 3)
	put32(&crx, u32(len(header)))
	append(&crx, ..header[:])
	append(&crx, ..out[:])
	return crx[:]
}

// Installs a package file from about:extensions (its path typed in) and accepts the prompt: its id.
@(private = "file")
install_file :: proc(s: ^e2e.Session, path: string) -> string {
	e2e.navigate(s, fmt.tprintf("about:extensions?path=%s", url.percent_encoded(path, url.UNRESERVED + "/:")))
	e2e.wait_js(s, `document.body.textContent.includes("Add Vault fixture?")`)
	id := strings.clone(ext_id_on_page(s), context.temp_allocator)
	e2e.navigate(s, fmt.tprintf("about:extensions?accept=%s", id))
	e2e.wait_js(s, `document.body.textContent.includes("Vault fixture is installed.")`)
	return id
}

// The script that waits until the background's log has `text` (the log: background.js `events`).
@(private = "file")
seen_js :: proc(text: string) -> string {
	return fmt.tprintf(`new Promise((ok) => {{ const go = () => chrome.runtime.sendMessage({{type: "events"}}).then((list) => list.includes(%q) ? ok("seen") : setTimeout(go, 20)); go(); }})`, text)
}

@(private = "file")
VAULT_PREFS := [?]string{"extensions.background.idle_ms=3600000"}   // (the background's log is in its memory: it must not stop between the steps)

@(test)
extensions_vault_packed_offscreen_tabs :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = EXT_SIZE, prefs = VAULT_PREFS[:]})
	files := e2e.temp_folder(t, "packages")

	// a .crx: its key gives the id; it installs, runs, and goes
	crx_path := fmt.tprintf("%s/vault.crx", files)
	_ = os.write_entire_file(crx_path, pack_vault("a DER public key of the test"))
	crx_id := install_file(s, crx_path)
	testing.expect_value(t, crx_id, extensions.id_from_bytes(transmute([]byte)string("a DER public key of the test"), context.temp_allocator))
	{
		context = s.ctx
		e := extensions.registry_find(&s.app.pages.extensions, crx_id)
		testing.expect(t, e != nil && e.source == .Crx && e.image != nil && e.image.ok && strings.has_suffix(e.path, "/package"), "installed from the .crx, unpacked into the profile")
	}
	e2e.navigate(s, fmt.tprintf("chrome-extension://%s/popup.html", crx_id))
	e2e.expect_eval(s, `chrome.runtime.id`, crx_id, "the .crx extension's page runs")
	e2e.navigate(s, fmt.tprintf("about:extensions?remove=%s", crx_id))
	e2e.wait_js(s, `document.body.textContent.includes("Vault fixture was removed.")`)

	// a .zip
	zip_path := fmt.tprintf("%s/vault.zip", files)
	_ = os.write_entire_file(zip_path, pack_vault())
	id := install_file(s, zip_path)
	{
		context = s.ctx
		e := extensions.registry_find(&s.app.pages.extensions, id)
		testing.expect(t, e != nil && e.source == .Zip && e.image != nil && e.image.ok, "installed from the .zip")
	}
	popup := fmt.tprintf("chrome-extension://%s/popup.html", id)
	e2e.navigate(s, popup)
	e2e.wait_js(s, `document.getElementById("where").textContent === "in the popup"`)

	// the clipboard: an extension page with clipboardWrite and clipboardRead needs no click
	e2e.expect_eval(s, `navigator.clipboard.writeText("from the popup").then(() => navigator.clipboard.readText())`, "from the popup", "the popup writes and reads the clipboard with no gesture")

	// an offscreen document: made, it gets the background's message, writes the clipboard, is a context, then closes
	e2e.expect_eval(s, `chrome.runtime.sendMessage({type: "copy", text: "s3cret"}).then((r) => [r.answer && r.answer.written, r.answer && r.answer.apis, r.kinds, r.after, r.error].join("|"))`,
		"true|undefined undefined function|BACKGROUND,OFFSCREEN_DOCUMENT,TAB|false|", "offscreen.createDocument, a message to it, the clipboard from it, runtime.getContexts, closeDocument")
	e2e.expect_eval(s, `navigator.clipboard.readText()`, "s3cret", "what the offscreen document wrote is on the clipboard")
	e2e.expect_eval(s, `chrome.runtime.sendMessage({type: "offscreen-twice"})`, "Only a single offscreen document may be created.", "one offscreen document at a time")
	e2e.expect_eval(s, `chrome.runtime.sendMessage({type: "offscreen-bad-url"}).then((m) => String(m.includes("not a file of the extension")))`, "true", "an offscreen document is a file of the extension")
	{
		context = s.ctx
		testing.expect(t, len(s.app.ext.offscreen) == 0, "no offscreen tab is left")
	}

	// tabs.create opens a tab that loads; its events reach the background; tabs.remove closes it
	tab_text := e2e.eval(s, `chrome.tabs.create({url: "page.html", active: false}).then((t) => String(t.id))`, await = true)
	e2e.expect_eval(s, fmt.tprintf(`new Promise((ok) => {{ const go = () => chrome.tabs.get(%s).then((t) => t.status === "complete" ? ok(t.title + " " + t.url.endsWith("/page.html")) : setTimeout(go, 20)); go(); }})`, tab_text),
		"Vault fixture page true", "the tab tabs.create opened loads the extension's page")
	e2e.expect_eval(s, seen_js(fmt.tprintf("tabs.onCreated:%s", tab_text)), "seen", "tabs.onCreated")
	e2e.expect_eval(s, seen_js(fmt.tprintf("tabs.onUpdated:%s:complete", tab_text)), "seen", "tabs.onUpdated, complete")
	e2e.expect_eval(s, fmt.tprintf(`chrome.tabs.remove(%s).then(() => "removed")`, tab_text), "removed", "tabs.remove")
	e2e.expect_eval(s, seen_js(fmt.tprintf("tabs.onRemoved:%s", tab_text)), "seen", "tabs.onRemoved")
	e2e.expect_eval(s, `chrome.tabs.create({url: "file:///etc/passwd"}).then(() => "opened", (e) => "refused")`, "refused", "a file of the disk is not opened")

	// the popout window: one tab, no tab strip, no toolbar; windows.remove ends it
	win_text := e2e.eval(s, `chrome.windows.create({url: "popup.html?popout", type: "popup", width: 400, height: 520}).then((w) => w.type + " " + w.tabs.length + " " + w.id)`, await = true)
	parts := strings.split(win_text, " ", context.temp_allocator)
	if !testing.expectf(t, len(parts) == 3 && parts[0] == "popup" && parts[1] == "1", "windows.create popup: %q", win_text) { return }
	{
		context = s.ctx
		popout_found := false
		for w in s.app.windows { if fmt.tprintf("%d", w.id) == parts[2] { popout_found = browser_is_popout(s, w.id) } }
		testing.expect(t, popout_found, "the window is a popout window (no tab strip, no toolbar)")
	}
	e2e.expect_eval(s, seen_js(fmt.tprintf("windows.onCreated:%s", parts[2])), "seen", "windows.onCreated")
	e2e.expect_eval(s, fmt.tprintf(`chrome.windows.getAll().then((all) => String(all.some((w) => w.id === %s && w.type === "popup")))`, parts[2]), "true", "windows.getAll lists it as a popup")
	e2e.expect_eval(s, fmt.tprintf(`chrome.windows.remove(%s).then(() => "removed")`, parts[2]), "removed", "windows.remove")
	e2e.expect_eval(s, seen_js(fmt.tprintf("windows.onRemoved:%s", parts[2])), "seen", "windows.onRemoved")

	// idle: the time since the last input (set here: a test has none); the event when it changes
	{
		context = s.ctx
		s.app.ext.last_input_ns = host.now_ns(&s.app.loop)
		page.ext_idle_schedule()
	}
	e2e.expect_eval(s, `chrome.idle.queryState(15)`, "active", "idle.queryState: active after an input")
	{
		context = s.ctx
		s.app.ext.last_input_ns = host.now_ns(&s.app.loop) - 120_000_000_000
		page.ext_idle_schedule()
	}
	e2e.expect_eval(s, `chrome.idle.queryState(60)`, "idle", "idle.queryState: idle two minutes after the last input")
	e2e.expect_eval(s, seen_js("idle.onStateChanged:idle"), "seen", "idle.onStateChanged: idle")
	{
		context = s.ctx
		s.app.ext.last_input_ns = host.now_ns(&s.app.loop)
		page.ext_idle_schedule()
	}
	e2e.expect_eval(s, seen_js("idle.onStateChanged:active"), "seen", "idle.onStateChanged: active again")
}

////////////////////////////////
// Phase 3: content scripts

// The script that waits until the autofill fixture's background log has `text` (examples/extensions/autofill).
@(private = "file")
autofill_seen_js :: proc(text: string) -> string {
	return fmt.tprintf(`new Promise((ok) => {{ const go = () => chrome.runtime.sendMessage({{type: "log"}}).then((l) => l.includes(%q) ? ok("seen") : setTimeout(go, 20)); go(); }})`, text)
}

// The id of the window's current tab.
@(private = "file")
current_tab :: proc(s: ^e2e.Session) -> int {
	for t in e2e.targets(s).tabs { if t.active { return t.id } }
	return -1
}

// The autofill fixture against examples/site/extensions/login.html (served on 127.0.0.1, with a frame of localhost and
// a frame of its own origin that no pattern matches): content scripts read and fill the login form in an isolated
// world; the page sees none of their globals and has no chrome.*; document_start runs before the page's first script;
// the cross-origin frame gets the all_frames script only; the CSS applies and is not in document.styleSheets; window
// messages reach both worlds; then, from the extension's page: tabs.sendMessage, tabs.connect, scripting.executeScript
// in both worlds and in every frame, insertCSS, registerContentScripts, webNavigation; a web-accessible file loads in
// the page, another file of the extension does not.
@(test)
extensions_content_scripts_autofill :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = EXT_SIZE, prefs = {"extensions.background.idle_ms=3600000"}})   // (its log is in its memory)
	dir := fmt.tprintf("%s/examples/extensions/autofill", e2e.repo_root())
	e2e.navigate(s, fmt.tprintf("about:extensions?path=%s", url.percent_encoded(dir, url.UNRESERVED + "/:")))
	e2e.wait_js(s, `document.body.textContent.includes("Add Autofill fixture?")`)
	id := strings.clone(ext_id_on_page(s), context.temp_allocator)
	if !testing.expectf(t, extensions.id_valid(id), "the install prompt names the extension's id (got %q)", id) { return }
	e2e.navigate(s, fmt.tprintf("about:extensions?accept=%s", id))
	e2e.wait_js(s, `document.body.textContent.includes("Autofill fixture is installed.")`)

	// the page: its form filled by the document_idle script, in the extension's isolated world
	login := e2e.url(server, "/site/extensions/login.html")
	e2e.navigate(s, login)
	e2e.wait_js(s, `document.getElementById("user").value === "alice"`)
	login_tab := current_tab(s)
	e2e.expect_eval(s, `document.getElementById("pass").value`, "s3cret", "the content script read the form and filled the password")
	e2e.expect_eval(s, `document.documentElement.dataset.extStart`, "before", "document_start runs before the page's first script")
	e2e.expect_eval(s, `[typeof contentScriptMarker, typeof window.extWorldSecret, typeof chrome, window.pageMarker].join(" ")`, "undefined undefined undefined page",
		"the page sees none of the content script's globals, and has no chrome.*")
	e2e.expect_eval(s, `getComputedStyle(document.getElementById("user")).outlineColor`, "rgb(1, 2, 3)", "the content script's CSS applies")
	e2e.expect_eval(s, `String(document.styleSheets.length)`, "1", "and the page does not see it in document.styleSheets")
	e2e.wait_js(s, `document.documentElement.dataset.pageGot === "hello page"`)   // (the world's postMessage reached the page's listener)
	e2e.eval(s, `(window.postMessage({ping: "from page"}, "*"), "posted")`)
	e2e.wait_js(s, `document.documentElement.dataset.extGot === "from page"`)   // (the page's message reached the world's listener)
	// a frame of the page's origin that exclude_matches leaves out: nothing ran in it
	e2e.wait_js(s, `(() => { const d = document.getElementById("nomatch").contentDocument; return !!d && d.readyState === "complete"; })()`)
	e2e.expect_eval(s, `String(document.getElementById("nomatch").contentDocument.documentElement.dataset.extStart)`, "undefined", "exclude_matches: no script in that frame")
	// web_accessible_resources: one file the page may load, the others not (the same error as an absent extension)
	e2e.expect_eval(s, fmt.tprintf(`fetch("chrome-extension://%s/menu.html").then((r) => r.text()).then((t) => String(t.includes("web-accessible menu")), () => "refused")`, id),
		"true", "a web-accessible file loads in the page")
	e2e.expect_eval(s, fmt.tprintf(`fetch("chrome-extension://%s/background.js").then(() => "loaded", () => "refused")`, id), "refused", "another file of the extension does not")

	// the extension's side, from its page in a tab of its own
	page_tab := e2e.new_tab(s, fmt.tprintf("chrome-extension://%s/page.html", id))
	e2e.activate_tab(s, page_tab)
	s.tab = page_tab
	e2e.wait_load(s)
	e2e.wait_js(s, `document.getElementById("state").textContent === "ready"`)
	tab := e2e.eval(s, `chrome.tabs.query({url: "http://127.0.0.1/*"}).then((t) => String(t.length === 1 ? t[0].id : -1))`, await = true)
	if !testing.expect(t, tab != "-1" && tab != "", "tabs.query finds the login page's tab") { return }
	e2e.expect_eval(s, autofill_seen_js("started:127.0.0.1:top"), "seen", "document_start in the top document; the sender's frameId is 0")
	e2e.expect_eval(s, autofill_seen_js("started:localhost:frame:child"), "seen", "the cross-origin frame got the all_frames script (its pattern matches)")
	e2e.expect_eval(s, autofill_seen_js("world:127.0.0.1:top:true,string,undefined"), "seen", "the world: customElements is null, runtime is there, tabs is not")
	e2e.expect_eval(s, autofill_seen_js("filled:127.0.0.1:top:true"), "seen", "document_idle filled the form and told the background")
	e2e.expect_eval(s, autofill_seen_js("webNavigation.onCompleted:top"), "seen", "webNavigation.onCompleted")
	e2e.expect_eval(s, `chrome.runtime.sendMessage({type: "log"}).then((l) => String(l.some((x) => x.startsWith("filled:localhost"))))`, "false",
		"the frame did not get the script that is not all_frames")

	e2e.expect_eval(s, fmt.tprintf(`chrome.tabs.sendMessage(%s, {{type: "fill", user: "bob", pass: "pw2"}}, {{frameId: 0}}).then((r) => r.filled + " " + r.from)`, tab), "true true",
		"tabs.sendMessage reaches the content script, which answers")
	e2e.expect_eval(s, fmt.tprintf(`new Promise((ok) => {{ const p = chrome.tabs.connect(%s, {{frameId: 0}}); p.onMessage.addListener((m) => ok(m.seen + " " + m.host)); p.postMessage("knock"); }})`, tab),
		"knock 127.0.0.1", "tabs.connect: a port to the content script and back")
	e2e.expect_eval(s, fmt.tprintf(`chrome.scripting.executeScript({{target: {{tabId: %s}}, func: (s) => typeof contentScriptMarker + s, args: ["!"]}}).then((r) => r.length + " " + r[0].frameId + " " + r[0].result)`, tab),
		"1 0 string!", "executeScript: a function in the isolated world, beside the content scripts, with its arguments")
	e2e.expect_eval(s, fmt.tprintf(`chrome.scripting.executeScript({{target: {{tabId: %s}}, func: () => new Promise((ok) => setTimeout(() => ok(document.title), 10))}}).then((r) => r[0].result)`, tab),
		"Login fixture", "executeScript: a promise's value")
	e2e.expect_eval(s, fmt.tprintf(`chrome.scripting.executeScript({{target: {{tabId: %s, allFrames: true}}, func: () => location.hostname}}).then((r) => r.map((x) => x.result).sort().join(","))`, tab),
		"127.0.0.1,127.0.0.1,localhost", "executeScript in every frame")
	e2e.expect_eval(s, fmt.tprintf(`chrome.scripting.executeScript({{target: {{tabId: %s}}, world: "MAIN", func: (v) => {{ window.fromMain = v; }}, args: ["main"]}}).then((r) => String(r[0].result))`, tab),
		"null", "executeScript in the page's world")
	e2e.expect_eval(s, fmt.tprintf(`chrome.scripting.insertCSS({{target: {{tabId: %s}}, css: "#login {{ color: rgb(4, 5, 6); }}"}}).then(() => "inserted")`, tab), "inserted", "insertCSS")
	e2e.expect_eval(s, fmt.tprintf(`chrome.webNavigation.getAllFrames({{tabId: %s}}).then((f) => f.length + " " + f[0].frameId + " " + f[0].parentFrameId + " " + (f[1].parentFrameId === 0))`, tab),
		"3 0 -1 true", "webNavigation.getAllFrames: the top document and its two frames")
	e2e.expect_eval(s, `chrome.scripting.registerContentScripts([{id: "late", matches: ["http://127.0.0.1/*"], js: ["content/late.js"], runAt: "document_end"}]).then(() => chrome.scripting.getRegisteredContentScripts()).then((l) => l.map((x) => x.id + " " + x.runAt).join())`,
		"late document_end", "registerContentScripts")
	e2e.expect_eval(s, `chrome.scripting.registerContentScripts([{id: "late", matches: ["http://127.0.0.1/*"], js: ["content/late.js"]}]).then(() => "registered", (e) => e.message)`,
		"Duplicate script ID 'late'", "a registered id is unique")

	// back on the page: what the extension did there
	e2e.activate_tab(s, login_tab)
	s.tab = login_tab
	e2e.expect_eval(s, `document.getElementById("user").value + " " + document.getElementById("pass").value`, "bob pw2", "the form as tabs.sendMessage filled it")
	e2e.expect_eval(s, `String(window.fromMain)`, "main", "the MAIN world function ran in the page's realm")
	e2e.expect_eval(s, `getComputedStyle(document.getElementById("login")).color`, "rgb(4, 5, 6)", "the inserted CSS applies")
	e2e.reload(s)
	e2e.wait_js(s, `document.documentElement.dataset.extLate === "interactive"`)   // (the registered script ran at document_end)
	e2e.wait_js(s, `document.getElementById("user").value === "alice"`)

	// the worlds go with their documents
	e2e.navigate(s, "about:blank")
	{
		Wait :: struct { id: string }
		w := Wait{id}
		e2e.wait_until(s, &w, proc(s: ^e2e.Session, w: ^Wait) -> bool {
			context = s.ctx
			for _, c in s.app.pages.ext_router.contexts { if c.ext == w.id && c.kind == .Content { return false } }
			return true
		}, "the content scripts' contexts to go with their documents")
	}
}

// (a window's popout mark, read the way build_ui reads it)
@(private = "file")
browser_is_popout :: proc(s: ^e2e.Session, id: int) -> bool {
	_, ok := s.app.ext.popouts[id]
	return ok
}

// The extension comes back from the profile after a restart, with the id its archive gave it; its background's
// listeners were kept, so the browser's start does not run it, an event it does not listen to does not start it, and a
// message (it listens to runtime.onMessage) does.
@(test)
extensions_vault_restart :: proc(t: ^testing.T) {
	profile := e2e.temp_profile(t)
	s := e2e.start(t, {size = EXT_SIZE, profile = profile, prefs = VAULT_PREFS[:]})
	files := e2e.temp_folder(t, "packages")
	zip_path := fmt.tprintf("%s/vault.zip", files)
	_ = os.write_entire_file(zip_path, pack_vault())
	id := install_file(s, zip_path)
	popup := fmt.tprintf("chrome-extension://%s/popup.html", id)
	e2e.navigate(s, popup)
	e2e.expect_eval(s, `chrome.storage.local.set({kept: "yes"}).then(() => chrome.runtime.sendMessage({type: "events"})).then((l) => String(Array.isArray(l)))`, "true", "the background ran")
	state := fmt.tprintf("%s/extensions/%s/state.txt", profile, id)
	{
		Wait :: struct { path: string }
		w := Wait{state}
		e2e.wait_until(s, &w, proc(s: ^e2e.Session, w: ^Wait) -> bool {
			return strings.contains(e2e.read_text(w.path), "idle.onStateChanged")
		}, "state.txt to keep the background's listeners")
	}
	testing.expect(t, !strings.contains(e2e.read_text(state), "runtime.onStartup"), "it does not listen to runtime.onStartup")

	s = e2e.restart(s, {size = EXT_SIZE, profile = profile, prefs = VAULT_PREFS[:]})
	{
		Wait :: struct { id: string }
		w := Wait{id}
		e2e.wait_until(s, &w, proc(s: ^e2e.Session, w: ^Wait) -> bool {
			context = s.ctx
			e := extensions.registry_find(&s.app.pages.extensions, w.id)
			return e != nil && !e.loading && e.image != nil && e.image.ok
		}, "the extension to load from the profile")
	}
	{
		context = s.ctx
		e := extensions.registry_find(&s.app.pages.extensions, id)
		testing.expect(t, e != nil && e.source == .Zip && e.listeners_known, "the same id, from the unpacked package, with its listeners known")
		exists, running, starts := page.ext_bg_state(id)
		testing.expectf(t, exists && !running && starts == 0, "the browser's start does not run it (running %v, started %d times)", running, starts)
		page.ext_emit(id, "tabs.onHighlighted", "[]")   // (it does not listen to it)
		_, running, starts = page.ext_bg_state(id)
		testing.expectf(t, !running && starts == 0, "an event it does not listen to does not start it (started %d times)", starts)
	}
	e2e.navigate(s, popup)
	e2e.expect_eval(s, `chrome.storage.local.get("kept").then((r) => r.kept)`, "yes", "its storage came back")
	e2e.expect_eval(s, `chrome.runtime.sendMessage({type: "events"}).then((l) => String(Array.isArray(l)))`, "true", "a message starts it")
	{
		context = s.ctx
		_, running, starts := page.ext_bg_state(id)
		testing.expectf(t, running && starts == 1, "it started once, for the message (started %d times)", starts)
	}
}
