// End-to-end tests of what real sites do that the unit tests of one package do not see, each a reduced fixture of a site
// that rendered wrong (the first: clockin.sacha.house, an Angular + Tailwind application): stylesheet loading tricks
// (<link media=print onload="this.media='all'">), load / error events of <link>. Needs build\testserver.exe on
// 127.0.0.1:8765 (tools\test_all.ps1 starts it). From the repository root:
//   sitecompattest.exe
package sitecompattest

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
process:  ^base.Scope

BASE :: "http://127.0.0.1:8765/sitecompat/test.html"
WAIT_FAIL_MS :: 60_000

wait_for :: proc(text: string) -> bool {
	start := time.tick_now()
	for !logged(text) {
		if time.duration_milliseconds(time.tick_since(start)) > WAIT_FAIL_MS { return false }
		host.loop_wait(&loop, 5)
	}
	return true
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

// A stylesheet served by the test server (after `ms`), with this text.
css_url :: proc(text: string, ms := 0, status := 0) -> string {
	return fmt.tprintf("/jsload/gen?ms=%d&type=text/css&status=%d&code=%s", ms, status, enc(text))
}

PRELUDE :: `<script>function log(s) { console.log(String(s)) }</script>`

load :: proc(source: string) -> ^page.Page {
	clear(&logs)
	p := page.page_create(&loop, &loader, &settings, process, BASE, console)
	page.load_html(p, transmute([]byte)source)
	page.scripts_start(p)
	return p
}

main :: proc() {
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

	test_link_events()
	test_print_media_swap()

	base.scope_close(process)
	page.compile_shutdown()
	js.cache_stop()
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures > 0 ? 1 : 0)
}

// The width of #t as styled now (the page's styles at a desktop viewport), through getComputedStyle.
probe_width :: proc(p: ^page.Page, tag: string) {
	page.styles(p, 1280, 720, 1)
	page.js_run(p, transmute([]byte)fmt.tprintf(`log("%s " + getComputedStyle(document.getElementById("t")).width)`, tag), "probe.js")
}

test_link_events :: proc() {
	fmt.println("-- <link rel=stylesheet>: load and error events")
	src := strings.concatenate({`<!doctype html><head>`, PRELUDE,
		`<link id=ok rel=stylesheet href="`, css_url("p { color: red }", 30), `" onload="log('ok load ' + (event.target === this))" onerror="log('ok error')">`,
		`<link id=bad rel=stylesheet href="`, css_url("p {}", 0, 404), `" onload="log('bad load')" onerror="log('bad error')">`,
		`</head><body><script>
document.getElementById("ok").addEventListener("load", e => log("listener load " + e.bubbles + " " + e.cancelable));
window.addEventListener("load", () => log("window load"));
</script></body>`}, context.temp_allocator)
	p := load(src)
	wait_for("window load")
	wait_for("bad error")
	check(logged("ok load true"), "a loaded stylesheet fires load at its <link> (onload attribute, this = the element)")
	check(logged("listener load false false"), "load does not bubble and cannot be cancelled")
	check(logged("bad error") && !logged("bad load"), "an HTTP error fires error, not load")
	check(!logged("ok error"), "a loaded stylesheet does not fire error")
	page.page_close(p)
}

test_print_media_swap :: proc() {
	fmt.println("-- <link media=print onload=\"this.media='all'\"> (the non-blocking stylesheet pattern)")
	src := strings.concatenate({`<!doctype html><head>`, PRELUDE,
		`<link rel=stylesheet href="`, css_url("#t { width: 123px }", 30), `" media="print" onload="this.media='all'; log('swapped')">`,
		`<link id=late rel=stylesheet href="`, css_url("#t { height: 7px }", 300), `" media="print">`,
		`</head><body><div id=t></div></body>`}, context.temp_allocator)
	p := load(src)
	wait_for("swapped")
	probe_width(p, "after swap")
	wait_for("after swap 123px")
	check(logged("after swap 123px"), "a loaded print sheet applies once its media becomes all")

	// the media changes while the sheet is still loading: the sheet comes with the new media
	page.js_run(p, transmute([]byte)string(`document.getElementById("late").media = "all"; log("late set")`), "probe.js")
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < 1000 { host.loop_wait(&loop, 5) }
	page.styles(p, 1280, 720, 1)
	page.js_run(p, transmute([]byte)string(`log("late " + getComputedStyle(document.getElementById("t")).height)`), "probe.js")
	check(logged("late 7px"), "a media changed while the sheet loads applies when it arrives")

	page.js_run(p, transmute([]byte)string(`document.querySelector("link").media = "print"`), "probe.js")
	probe_width(p, "back to print")
	back := ""
	for l in logs { if strings.has_prefix(l, "back to print ") { back = l } }
	check(back != "" && back != "back to print 123px", "and stops applying when the media becomes print again")
	page.page_close(p)
}
