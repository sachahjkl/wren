// Headless test of the page's side of history: the session history tree as pages see it (history.length, pushState,
// back after a branch), history.scrollRestoration, pagehide / pageshow and PageTransitionEvent.persisted, freezing and
// thawing for the back/forward cache (timers and tasks held, then run), the reasons a page cannot be kept, and the
// persisted state of form controls. No server, no window. Run from the repository root:
//   historytest.exe
package historytest

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
import "wb:tools/testenv"

failures: int
passes: int
logs: [dynamic]string

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { passes += 1; fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

console :: proc(user: rawptr, level: page.Log_Level, message: string) {
	append(&logs, strings.clone(message))
	if level != .Log { fmt.printf("  [%v] %s\n", level, message) }
}

logged :: proc(text: string) -> bool {
	for l in logs { if l == text { return true } }
	return false
}

logged_prefix :: proc(prefix: string) -> string {
	for i := len(logs) - 1; i >= 0; i -= 1 { if strings.has_prefix(logs[i], prefix) { return logs[i] } }
	return ""
}

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings

Hooks :: struct { left, entered: int }

pump :: proc(ms: f64, until := "") {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < ms {
		if until != "" && logged(until) { return }
		host.loop_wait(&loop, 2)
	}
}

open :: proc(process: ^base.Scope, sh: ^page.Session_History, hooks: ^Hooks, source: string, address := "http://127.0.0.1:8765/history/a.html") -> ^page.Page {
	p := page.page_create(&loop, &loader, &settings, process, address, console)
	page.session_push(sh, address, 0)
	page.set_embedder(p, {session = sh, user = hooks,
		leaving = proc(user: rawptr, p: ^page.Page, e: ^page.History_Entry) { (^Hooks)(user).left += 1 },
		entered = proc(user: rawptr, p: ^page.Page, e: ^page.History_Entry) { (^Hooks)(user).entered += 1 },
	})
	page.load_html(p, transmute([]byte)source)
	page.scripts_start(p)
	pump(5000, "loaded")
	return p
}

run :: proc(p: ^page.Page, src: string) { page.js_run(p, transmute([]byte)src, "probe.js") }

PAGE_A :: `<!doctype html><title>A</title><body>
<form id=f><input id=t name=t><input id=pw type=password name=pw><input id=off name=off autocomplete=off>
<input id=c type=checkbox name=c><select id=s name=s><option>one<option>two<option>three</select><textarea id=ta name=ta></textarea></form>
<div><p>x</p><input name=nested></div>
<script>
addEventListener('pageshow', e => console.log('pageshow ' + e.persisted + ' ' + (e instanceof PageTransitionEvent)));
addEventListener('pagehide', e => console.log('pagehide ' + e.persisted));
addEventListener('popstate', e => console.log('popstate ' + JSON.stringify(e.state)));
addEventListener('load', () => console.log('loaded'));
</script>`

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
	process := base.scope_make("process")

	sh: page.Session_History
	hooks: Hooks
	p := open(process, &sh, &hooks, PAGE_A)
	check(logged("loaded"), "the page loads")
	check(logged("pageshow false true"), "pageshow after load: persisted false, a PageTransitionEvent")

	// the web sees the active path of the tree
	run(p, `history.pushState({n:1}, '', '#1'); history.pushState({n:2}, '', '#2'); console.log('len ' + history.length)`)
	check(logged("len 3"), "pushState adds entries (history.length 3)")
	check(hooks.left == 2, "the embedder saves the entry left by each pushState")
	run(p, `history.back(); history.back();`)
	pump(500, "popstate null")
	pump(200)
	check(logged("popstate {\"n\":1}") && logged("popstate null"), "back twice: popstate with each entry's state")
	check(hooks.entered >= 2, "the embedder restores the entry entered by a same-document traversal")
	run(p, `history.pushState({n:9}, '', '#9'); console.log('len2 ' + history.length + ' ' + location.hash)`)
	check(logged("len2 2 #9"), "a push after going back: the web sees 2 entries (the old ones are a branch)")
	check(sh.count == 4, "... and the tree keeps all 4")
	run(p, `history.back()`)
	pump(300, "popstate null")
	run(p, `console.log('fwd ' + history.length)`)
	check(logged("fwd 2"), "back from the branch: forward goes to the branch visited last")

	// scrollRestoration
	run(p, `console.log('sr ' + history.scrollRestoration); history.scrollRestoration = 'manual'; history.scrollRestoration = 'bogus'; console.log('sr2 ' + history.scrollRestoration)`)
	check(logged("sr auto") && logged("sr2 manual"), "history.scrollRestoration: auto, then manual (other values ignored)")
	check(page.session_current(&sh).scroll_manual, "... kept in the current entry")
	run(p, `history.pushState(null, '', '#m'); console.log('sr3 ' + history.scrollRestoration)`)
	check(logged("sr3 manual"), "pushState carries the mode to the new entry")
	run(p, `history.scrollRestoration = 'auto'`)

	// PageTransitionEvent built by scripts
	run(p, `console.log('pte ' + new PageTransitionEvent('pageshow', {persisted: true}).persisted + ' ' + new PageTransitionEvent('x').persisted)`)
	check(logged("pte true false"), "new PageTransitionEvent(type, {persisted})")

	// back/forward cache: eligibility
	check(page.bfcache_blockers(p) == {}, "a loaded page with nothing open can be kept")
	run(p, `window.u = () => {}; addEventListener('unload', u)`)
	check(.Unload_Listener in page.bfcache_blockers(p), "an unload listener keeps the page out of the cache")
	run(p, `removeEventListener('unload', u)`)
	check(page.bfcache_blockers(p) == {}, "... and not once removed")

	// freezing: timers and tasks wait, then run in order
	run(p, `window.ticks = 0; setTimeout(() => console.log('timer ran ' + document.visibilityState), 20); setInterval(() => window.ticks++, 10)`)
	page.page_freeze(p)
	check(logged("pagehide true"), "frozen: pagehide with persisted true")
	check(page.page_frozen(p) && !page.page_visible(p), "frozen and hidden")
	pump(200)
	check(!logged_contains("timer ran"), "no timer runs while frozen")
	page.page_thaw(p)
	check(logged("pageshow true true"), "thawed: pageshow with persisted true")
	pump(500, "timer ran visible")
	check(logged("timer ran visible"), "the timer that came due runs once thawed, the page visible")
	run(p, `console.log('ticks ' + (window.ticks > 0))`)
	check(logged("ticks true"), "intervals go on")

	// persisted state of form controls
	run(p, `t.value = 'typed'; pw.value = 'secret'; off.value = 'nope'; c.checked = true; s.selectedIndex = 2; ta.value = 'long\ntext'; document.querySelector('[name=nested]').value = 'deep'`)
	ps: page.Persisted_State
	n := page.persisted_capture_controls(p, &ps)
	check(n == 7, fmt.tprintf("controls captured: text, checkbox, the 3 options of the select, textarea, nested (%d)", n))
	for c in ps.controls { check(!strings.contains(c.path, "pw") && !strings.contains(c.path, "off"), fmt.tprintf("not captured: password, autocomplete=off (%s)", c.path)) }
	page.page_close(p)

	sh2: page.Session_History
	hooks2: Hooks
	q := open(process, &sh2, &hooks2, PAGE_A)
	done := page.persisted_restore_controls(q, &ps)
	check(done == 7, fmt.tprintf("restored into a new document of the same page (%d)", done))
	run(q, `console.log('vals ' + [t.value, pw.value, off.value, c.checked, s.value, ta.value, document.querySelector('[name=nested]').value].join('|'))`)
	check(logged("vals typed|||true|three|long\ntext|deep"), fmt.tprintf("the values are back: %s", logged_prefix("vals ")))
	// a page whose controls changed kind keeps its own
	page.page_close(q)
	sh3: page.Session_History
	hooks3: Hooks
	r := open(process, &sh3, &hooks3, `<input id=t type=checkbox name=t><script>addEventListener('load', () => console.log('loaded'))</script>`)
	check(page.persisted_restore_controls(r, &ps) == 0, "nothing restored into controls that are not the same kind any more")
	page.page_close(r)

	// paths: id, else indexes
	page.persisted_destroy(&ps)
	page.session_destroy(&sh); page.session_destroy(&sh2); page.session_destroy(&sh3)
	base.scope_close(process)
	host.loop_drain(&loop)
	page.process_shutdown()
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	host.loop_destroy(&loop)
	page.settings_destroy(&settings)
	for l in logs { delete(l) }
	delete(logs)
	failures += testenv.mem_check("historytest")
	fmt.printf("\n%d checks passed, %d failure(s)\n", passes, failures)
	os.exit(failures > 0 ? 1 : 0)
}

logged_contains :: proc(s: string) -> bool {
	for l in logs { if strings.contains(l, s) { return true } }
	return false
}
