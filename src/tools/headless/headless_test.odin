package headless

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:host"
import "wb:page"
import "wb:testenv"
import "wb:tools/tooling"

// The windows scripts open: a document such a window leaves stays in its back/forward cache, and going back shows it again
// (pageshow persisted, its script not run again) instead of loading it.

// How long the opener's script and its window may take, ms (a deadline: the test ends when A is shown again; among a full
// run's steps the first load took more than 10 s).
@(private = "file")
BFCACHE_TEST_MS :: 30_000

@(private = "file")
Seen :: struct { lines: [dynamic]string }

@(private = "file")
seen_console :: proc(d: ^Doc, level: page.Log_Level, text: string) {
	s := (^Seen)(d.user)
	append(&s.lines, strings.clone(text))
}

// /frames/doc of the test server: an HTML document of `body`.
@(private = "file")
doc_url :: proc(body: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)body {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') { strings.write_byte(&b, c) } else { fmt.sbprintf(&b, "%%%02X", c) }
	}
	return testenv.url(fmt.tprintf("http://127.0.0.1:8765/frames/doc?body=%s", strings.to_string(b)))
}

@(private = "file")
quoted :: proc(s: string) -> string { return strings.concatenate({`"`, s, `"`}, context.temp_allocator) }

@(test)
popup_back_forward_cache :: proc(t: ^testing.T) {
	testenv.serve(t)
	// (on a thread with the stack JavaScript needs, as the WPT runner's pages; the stack's memory is the process's, as the browser's)
	th := host.thread_start(proc(data: rawptr) {
		context.allocator = base.process_allocator()
		back_forward_run((^testing.T)(data))
	}, t, tooling.JS_THREAD_STACK_BYTES, name = "headless-test")
	if testing.expect(t, th != nil, "a thread for the pages") { host.thread_join(th) }
}

@(private = "file")
back_forward_run :: proc(t: ^testing.T) {
	e: Env
	if !testing.expect(t, init(&e), "the page stack starts") { return }
	defer destroy(&e)
	// (each step starts from the page shown before it, not from a timer: a loaded machine shows them late)
	b := doc_url(`<script>onpageshow = () => { console.log("B shown"); setTimeout(() => history.back()); };</script>`)
	a := doc_url(strings.concatenate({`<script>window.runs = (window.runs || 0) + 1; onpageshow = (e) => { console.log("A show " + e.persisted + " " + runs); if (!e.persisted) setTimeout(() => { location = `, quoted(b), `; }); }; onpagehide = (e) => console.log("A hide " + e.persisted);</script>`}, context.temp_allocator))
	opener := doc_url(strings.concatenate({`<script>open(`, quoted(a), `);</script>`}, context.temp_allocator))
	seen: Seen
	defer { for l in seen.lines { delete(l) }; delete(seen.lines) }
	d := open(&e, opener, seen_console, &seen)
	defer close(d)
	shown_again :: proc(d: ^Doc) -> bool {
		for l in (^Seen)(d.user).lines { if strings.has_prefix(l, "A show true") { return true } }
		return false
	}
	pump(d, BFCACHE_TEST_MS, shown_again)
	got := strings.join(seen.lines[:], ", ", context.temp_allocator)
	testing.expect_value(t, got, "A show false 1, A hide true, B shown, A show true 1")
}
