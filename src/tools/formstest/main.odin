// Headless end-to-end test of form controls: the forms model inside a real page, a Wasm guest using the "forms" imports,
// user input through the forms API, FormData sent with fetch in the three encodings, and form submissions (POST
// multipart with a file read from disk, GET) performed against build\testserver.exe's /forms/echo. Run from the
// repository root with the test server running:
//   formstest.exe examples\site\forms.html examples\site\formstest.wasm
package formstest

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:forms"
import "wb:host"
import "wb:html"
import "wb:net"
import "wb:page"
import "wb:wasm"
import "wb:tools/testenv"

failures: int

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

console :: proc(user: rawptr, level: page.Log_Level, message: string) { fmt.printf("  [%v] %s\n", level, message) }

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings
the_page: ^page.Page
submissions: [dynamic]^forms.Submission

pump_until :: proc(what: string, cond: proc() -> bool, seconds := 10.0) -> bool {
	start := time.tick_now()
	for !cond() {
		if time.duration_seconds(time.tick_since(start)) > seconds { fmt.printf("  timeout waiting for %s\n", what); return false }
		host.loop_wait(&loop, 20)
	}
	return true
}

status_attr :: proc(name: string) -> string {
	v, _ := dom.get_attribute(the_page.doc, dom.find_by_id(the_page.doc, "status"), name)
	return v
}

el :: proc(id: string) -> base.Handle { return dom.find_by_id(the_page.doc, id) }

// What the shell does with a POST submission, minus the window: encode, then fetch as a navigation would.
Echo :: struct { done: bool, body: [dynamic]byte, status: int }
echo: Echo

echo_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	#partial switch ev.kind {
	case .Response: echo.status = ev.response.status
	case .Done: append(&echo.body, ..ev.data); echo.done = true
	case .Failed: fmt.printf("  echo failed: %s\n", ev.detail); echo.done = true
	}
}

perform :: proc(s: ^forms.Submission) -> string {
	clear(&echo.body)
	echo.done = false
	headers := make([dynamic]fetch.Header_Pair, context.temp_allocator)
	if s.method == .Post {
		ok, msg := forms.encode_submission(s, settings.forms)
		if !ok { fmt.printf("  encode failed: %s\n", msg); return "" }
		append(&headers, fetch.Header_Pair{"Content-Type", s.content_type})
	}
	fetch.start(&loader, {
		request = {url = s.url, method = s.method == .Post ? "POST" : "GET", headers = headers[:], body = s.body,
			mode = .Navigate, credentials = .Include, destination = .Document, initiator = &the_page.env},
		on_event = echo_event, user = nil, scope = the_page.scope, collect = true,
	})
	pump_until("echo", proc() -> bool { return echo.done })
	return strings.clone(string(echo.body[:]), context.temp_allocator)
}

main :: proc() {
	context = testenv.context_of_process()
	if len(os.args) < 3 { fmt.eprintln("usage: formstest forms.html formstest.wasm"); os.exit(2) }
	html_bytes, herr := os.read_entire_file(os.args[1], context.allocator)
	guest, gerr := os.read_entire_file(os.args[2], context.allocator)
	if herr != nil || gerr != nil { fmt.eprintln("cannot read inputs"); os.exit(2) }

	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }
	process := base.scope_make("process")

	fmt.println("-- the page and its form")
	p := page.page_create(&loop, &loader, &settings, process, testenv.url("http://127.0.0.1:8765/site/forms.html"), console)
	the_page = p
	decoded, _ := html.decode_document(html_bytes, "utf-8", settings.html.default_encoding)
	page.load_html(p, decoded.text)
	page.set_forms_embedder(p, page.Forms_Embedder{
		navigate = proc(user: rawptr, pg: ^page.Page, s: ^forms.Submission) { append(&submissions, s) },
	})
	f := page.page_forms(p)
	check(forms.run_autofocus(f) && f.focus == el("name"), "autofocus focuses #name")
	check(p.style_state.focus == el("name"), "the focus reaches the style state (:focus)")

	_, ok, err := page.load_module(p, guest, "formstest")
	check(ok, fmt.tprintf("guest runs %s", err))
	check(dom.text_content(p.doc, el("status")) == "guest ready", "guest found the form")

	page.call_export(p, p.instances[0], "read_initial")
	initial := status_attr("data-initial")
	check(initial == "name=;code=ABC12;age=30;when=2026-10-18;level=4;lang=fr;bio=Hello\nworld;news=yes;checked=1;index=2;options=5;elements=19;type=select-one;active=name;", fmt.tprintf("initial values as the guest reads them: %q", initial))

	fmt.println("-- user input")
	forms.type_text(f, "A")
	forms.type_text(f, "d")
	check(forms.value(f, el("name")) == "Ad", "typed text lands in the focused field")
	check(strings.contains(status_attr("data-events"), "input@name input@name"), "the guest saw input events")
	forms.focus_next(f, 1)
	check(f.focus == el("email") && strings.contains(status_attr("data-events"), "change@name"), "Tab moves to #email and commits #name (change)")

	fmt.println("-- validation")
	page.call_export(p, p.instances[0], "validate")
	v := status_attr("data-validity")
	check(strings.has_prefix(v, "name:0 email:2 code:4 age:64 form:invalid msg:Please include an '@'"), fmt.tprintf("validity flags and message: %q", v))
	check(status_attr("data-custom") == "custom problem", "setCustomValidity / validationMessage")
	check(strings.contains(status_attr("data-events"), "invalid@email"), "checkValidity fired invalid")

	page.call_export(p, p.instances[0], "fix")
	date_days := forms.days_from_civil(2026, 10, 18)
	fixed := status_attr("data-fixed")
	check(fixed == fmt.tprintf("name=Ada Byron;sel=4,9;age=38;date=%d;form=valid;", date_days), fmt.tprintf("selection, setRangeText, stepUp, valueAsDate: %q", fixed))

	// a file chosen by the user (what the file dialog does), read from disk at submission
	theme, _ := os.read_entire_file("examples/site/theme.css", context.temp_allocator)
	list := []forms.File{{path = strings.clone("examples/site/theme.css"), name = strings.clone("theme.css"), mime = strings.clone("text/css"), size = i64(len(theme))}}
	forms.set_files(f, el("up"), list)
	check(len(forms.files(f, el("up"))) == 1 && forms.value(f, el("up")) == "C:\\fakepath\\theme.css", "a file input holds the chosen file")

	fmt.println("-- FormData with fetch")
	for enc in 0 ..< 3 { wasm.call_raw(p.instances[0], "send", {u32(enc)}) }
	check(status_attr("data-formdata") == "size=16;has-extra=1", fmt.tprintf("FormData from the form, formdata event, append/set: %q", status_attr("data-formdata")))
	pump_until("echoes", proc() -> bool { return status_attr("data-echo-multipart") != "" && status_attr("data-echo-urlencoded") != "" && status_attr("data-echo-text") != "" || status_attr("data-echo-error") != "" })
	mp := status_attr("data-echo-multipart")
	check(strings.contains(mp, "method=POST\ncontent-type=multipart/form-data; boundary=----WrenFormBoundary"), "multipart Content-Type with a random boundary")
	for line in ([?]string{"field name=Ada Byron\n", "field code=SET01\n", "field age=38\n", "field lang=en\n", "field news=yes\n", "field plan=pro\n",
		"field bio=Hello\\r\\nworld\n", fmt.tprintf("file up=theme.css;text/css;%d;", len(theme)), "field _charset_=UTF-8\n", "field action=send\n",
		"field extra=from-formdata\n", "file blob=hello.txt;text/plain;5;hello\n"}) {
		check(strings.contains(mp, line), fmt.tprintf("multipart carries %q", strings.trim_space(line)))
	}
	check(strings.index(mp, "field name=") < strings.index(mp, "field code=") && strings.index(mp, "field action=") < strings.index(mp, "field extra="), "entries keep tree order")
	ue := status_attr("data-echo-urlencoded")
	check(strings.contains(ue, "content-type=application/x-www-form-urlencoded\n") && strings.contains(ue, "field bio=Hello\\r\\nworld\n") && strings.contains(ue, "field up=theme.css\n"), "urlencoded body (files by name, CRLF newlines)")
	tp := status_attr("data-echo-text")
	check(strings.contains(tp, "content-type=text/plain\n") && strings.contains(tp, "line name=Ada Byron\n") && strings.contains(tp, "line blob=hello.txt\n"), "text/plain body")
	check(status_attr("data-echo-error") == "", "no fetch failed")

	fmt.println("-- submission")
	r := 0
	{
		res, _ := wasm.call_i32(p.instances[0], "request_submit")
		r = int(res)
	}
	check(r == 0, "requestSubmit(send) accepted")
	pump_until("planned navigation", proc() -> bool { return len(submissions) > 0 })
	check(strings.contains(status_attr("data-events"), "submit@f<send>"), "submit event with its submitter")
	if len(submissions) > 0 {
		s := submissions[0]
		check(s.method == .Post && s.enctype == .Multipart && s.url == testenv.url("http://127.0.0.1:8765/forms/echo"), fmt.tprintf("POST multipart to the action (%v %v %s)", s.method, s.enctype, s.url))
		body := perform(s)
		check(echo.status == 200 && strings.contains(body, "field action=send\n") && strings.contains(body, fmt.tprintf("file up=theme.css;text/css;%d;", len(theme))), "the server received the multipart submission and the file")
	}
	// the GET button: formmethod / formaction, through a user click
	forms.click(f, el("get"), forms.Click_Info{trusted = true})
	pump_until("GET navigation", proc() -> bool { return len(submissions) > 1 })
	if len(submissions) > 1 {
		s := submissions[1]
		check(s.method == .Get && strings.has_prefix(s.url, testenv.url("http://127.0.0.1:8765/forms/echo?name=Ada+Byron&email=ada%40example.com")), fmt.tprintf("GET replaces the query: %s", s.url))
		body := perform(s)
		check(strings.contains(body, "method=GET\n") && strings.contains(body, "field bio=Hello\\r\\nworld\n") && strings.contains(body, "field up=theme.css\n"), "the server received the GET submission")
	}

	fmt.println("-- invalid form, implicit submission, reset")
	forms.focus(f, el("email"))
	forms.select_all(f, el("email"))
	forms.type_text(f, "broken")
	forms.key_down(f, .Enter, {})
	check(len(submissions) == 2, "Enter in an invalid form does not submit")
	node, msg, shown := forms.current_report(f)
	check(shown && node == el("email") && strings.contains(msg, "'@'"), "the problem is reported on the field")
	page.call_export(p, p.instances[0], "reset_form")
	check(forms.value(f, el("name")) == "" && forms.value(f, el("email")) == "" && forms.selected_index(f, el("lang")) == 2 && len(forms.files(f, el("up"))) == 0, "reset restores defaults")
	check(strings.contains(status_attr("data-events"), "reset@f"), "reset event")

	fmt.println("-- closing")
	page.page_close(p)
	for _ in 0 ..< 10 { host.loop_wait(&loop, 20) }
	check(fetch.in_flight(&loader) == 0 && loop.timers.count == 0, "closing the page released its requests and timers")

	for s in submissions { forms.submission_destroy(s) }
	delete(submissions)
	delete(echo.body)
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
	delete(decoded.text)
	delete(html_bytes); delete(guest)
	failures += testenv.mem_check("formstest")
	fmt.printf("\n%d failure(s)\n", failures)
	os.exit(failures)
}
