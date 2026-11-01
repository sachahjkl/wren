#+private file
// Form controls in a real page: the forms model, a Wasm guest using the "forms" imports, user input through the forms API, FormData sent
// with fetch in the three encodings, and form submissions (POST multipart with a file read from disk, GET) performed against the test
// server's /forms/echo.
package webtests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:forms"
import "wb:html"
import "wb:page"
import "wb:tools/testenv"
import "wb:wasm"

FORMS_HTML :: "examples/site/forms.html"
FORMS_WASM :: "examples/site/formstest.wasm"
THEME_CSS :: "examples/site/theme.css"
ADDRESS :: "http://127.0.0.1:8765/site/forms.html"
EARLY_ADDRESS :: "http://127.0.0.1:8765/site/early.html"
ECHO_ADDRESS :: "http://127.0.0.1:8765/forms/echo"
ENCODINGS :: 3
INITIAL :: "name=;code=ABC12;age=30;when=2026-10-18;level=4;lang=fr;bio=Hello\nworld;news=yes;checked=1;index=2;options=5;elements=19;type=select-one;active=name;"
LANG_DEFAULT_INDEX :: 2
OPEN_CHECKS :: 2                    // of `open`

EARLY_DOC :: `<!doctype html><form id=f action="/next"></form><script>document.getElementById("f").submit(); wrenTest.note("submitted")</script>`

Echo :: struct { done: bool, body: string, status: int }

Form :: struct {
	t:           ^testing.T,
	pr:          ^Probe,
	f:           ^forms.Forms,
	decoded:     html.Decoded,
	timers:      int,
	autofocused: bool,
	submissions: [dynamic]^forms.Submission,
	echo:        Echo,
}

keep_submission :: proc(user: rawptr, pg: ^page.Page, s: ^forms.Submission) { append(&(^Form)(user).submissions, s) }

// The page, its form focused, the guest running (two checks). When it cannot go on, nothing is left of it.
open :: proc(t: ^testing.T, fm: ^Form) -> bool {
	fm.t = t
	fm.timers = loop.timers.count
	fm.submissions = make([dynamic]^forms.Submission)
	fm.pr = page_make(t, "forms", testenv.url(ADDRESS))
	source, herr := os.read_entire_file(FORMS_HTML, context.temp_allocator)
	guest, gerr := os.read_entire_file(FORMS_WASM, context.temp_allocator)
	testing.expect(t, herr == nil && gerr == nil, "cannot read the page and its guest")
	fm.decoded, _ = html.decode_document(source, "utf-8", settings.html.default_encoding)
	page.load_html(fm.pr.p, fm.decoded.text)
	page.set_forms_embedder(fm.pr.p, page.Forms_Embedder{user = fm, navigate = keep_submission})
	fm.f = page.page_forms(fm.pr.p)
	fm.autofocused = forms.run_autofocus(fm.f)
	_, ok, err := page.load_module(fm.pr.p, guest, "formstest")
	check(fm.pr, ok, fmt.tprintf("guest runs %s", err))
	if !ok { shut(fm, 0); return false }
	check(fm.pr, dom.text_content(fm.pr.p.doc, el(fm, "status")) == "guest ready", "guest found the form")
	return true
}

// The page's end. Whatever it was doing, its requests and timers go with it.
shut :: proc(fm: ^Form, min_checks: int, loc := #caller_location) {
	close_page(fm.pr, min_checks = min_checks, loc = loc)
	testing.expect(fm.t, fetch.in_flight(&loader) == 0 && loop.timers.count == fm.timers, "closing the page released its requests and timers", loc = loc)
	for s in fm.submissions { forms.submission_destroy(s) }
	delete(fm.submissions)
	delete(fm.decoded.text)
}

el :: proc(fm: ^Form, id: string) -> base.Handle { return dom.find_by_id(fm.pr.p.doc, id) }

status_attr :: proc(fm: ^Form, name: string) -> string {
	v, _ := dom.get_attribute(fm.pr.p.doc, el(fm, "status"), name)
	return v
}

call :: proc(fm: ^Form, export: cstring) { page.call_export(fm.pr.p, fm.pr.p.instances[0], export) }

// Correct values, as the guest sets them.
fix :: proc(fm: ^Form) { call(fm, "fix") }

// A file chosen by the user (what the file dialog does), read from disk at submission. Its size.
choose_file :: proc(fm: ^Form) -> int {
	theme, _ := os.read_entire_file(THEME_CSS, context.temp_allocator)
	list := []forms.File{{path = strings.clone(THEME_CSS), name = strings.clone("theme.css"), mime = strings.clone("text/css"), size = i64(len(theme))}}
	forms.set_files(fm.f, el(fm, "up"), list)
	return len(theme)
}

on_echo :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	e := (^Echo)(user)
	context.allocator = base.process_context().temp_allocator
	#partial switch ev.kind {
	case .Response: e.status = ev.response.status
	case .Done:     e.body, e.done = strings.clone(string(ev.data)), true
	case .Failed:   e.body, e.done = strings.clone(ev.detail), true
	}
}

// What the shell does with a POST submission, minus the window: encode, then fetch as a navigation would.
perform :: proc(fm: ^Form, s: ^forms.Submission) -> string {
	fm.echo = {}
	headers := make([dynamic]fetch.Header_Pair, context.temp_allocator)
	if s.method == .Post {
		ok, msg := forms.encode_submission(s, settings.forms)
		testing.expectf(fm.t, ok, "encode failed: %s", msg)
		if !ok { return "" }
		append(&headers, fetch.Header_Pair{"Content-Type", s.content_type})
	}
	fetch.start(&loader, {
		request = {url = s.url, method = s.method == .Post ? "POST" : "GET", headers = headers[:], body = s.body,
			mode = .Navigate, credentials = .Include, destination = .Document, initiator = &fm.pr.p.env},
		on_event = on_echo, user = &fm.echo, scope = fm.pr.p.scope, collect = true,
	})
	wait_until(fm.t, "the echo", &fm.echo, proc(e: ^Echo) -> bool { return e.done })
	return fm.echo.body
}

Wait_Submissions :: struct { fm: ^Form, want: int }

wait_submissions :: proc(fm: ^Form, want: int) -> bool {
	return wait_until(fm.t, "a planned navigation", Wait_Submissions{fm, want}, proc(w: Wait_Submissions) -> bool { return len(w.fm.submissions) >= w.want })
}

@(test)
forms_a_submission_while_the_page_loads_waits_for_the_embedder :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	fm: Form
	fm.t = t
	fm.submissions = make([dynamic]^forms.Submission)
	pr := open_page(t, "early", EARLY_DOC, testenv.url(EARLY_ADDRESS))
	fm.pr = pr
	wait_note(pr, "submitted")
	page.set_forms_embedder(pr.p, page.Forms_Embedder{user = &fm, navigate = keep_submission})
	check(pr, wait_submissions(&fm, 1), "its navigation waited, and goes when the embedder comes")
	check(pr, len(fm.submissions) == 1, "one navigation")
	close_page(pr, min_checks = 2)
	for s in fm.submissions { forms.submission_destroy(s) }
	delete(fm.submissions)
}

@(test)
forms_autofocus_and_initial_values :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	fm: Form
	if !open(t, &fm) { return }
	check(fm.pr, fm.autofocused && fm.f.focus == el(&fm, "name"), "autofocus focuses #name")
	check(fm.pr, fm.pr.p.style_state.focus == el(&fm, "name"), "the focus reaches the style state (:focus)")
	call(&fm, "read_initial")
	initial := status_attr(&fm, "data-initial")
	check(fm.pr, initial == INITIAL, fmt.tprintf("initial values as the guest reads them: %q", initial))
	shut(&fm, OPEN_CHECKS + 3)
}

type_ad :: proc(fm: ^Form) {
	forms.type_text(fm.f, "A")
	forms.type_text(fm.f, "d")
}

@(test)
forms_user_input :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	fm: Form
	if !open(t, &fm) { return }
	type_ad(&fm)
	check(fm.pr, forms.value(fm.f, el(&fm, "name")) == "Ad", "typed text lands in the focused field")
	check(fm.pr, strings.contains(status_attr(&fm, "data-events"), "input@name input@name"), "the guest saw input events")
	forms.focus_next(fm.f, 1)
	check(fm.pr, fm.f.focus == el(&fm, "email") && strings.contains(status_attr(&fm, "data-events"), "change@name"), "Tab moves to #email and commits #name (change)")
	shut(&fm, OPEN_CHECKS + 3)
}

@(test)
forms_validation :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	fm: Form
	if !open(t, &fm) { return }
	type_ad(&fm)
	forms.focus_next(fm.f, 1)
	call(&fm, "validate")
	v := status_attr(&fm, "data-validity")
	check(fm.pr, strings.has_prefix(v, "name:0 email:2 code:4 age:64 form:invalid msg:Please include an '@'"), fmt.tprintf("validity flags and message: %q", v))
	check(fm.pr, status_attr(&fm, "data-custom") == "custom problem", "setCustomValidity / validationMessage")
	check(fm.pr, strings.contains(status_attr(&fm, "data-events"), "invalid@email"), "checkValidity fired invalid")

	fix(&fm)
	date_days := forms.days_from_civil(2026, 10, 18)
	fixed := status_attr(&fm, "data-fixed")
	check(fm.pr, fixed == fmt.tprintf("name=Ada Byron;sel=4,9;age=38;date=%d;form=valid;", date_days), fmt.tprintf("selection, setRangeText, stepUp, valueAsDate: %q", fixed))

	choose_file(&fm)
	check(fm.pr, len(forms.files(fm.f, el(&fm, "up"))) == 1 && forms.value(fm.f, el(&fm, "up")) == "C:\\fakepath\\theme.css", "a file input holds the chosen file")
	shut(&fm, OPEN_CHECKS + 5)
}

@(test)
forms_form_data_with_fetch :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	fm: Form
	if !open(t, &fm) { return }
	fix(&fm)
	size := choose_file(&fm)
	for enc in 0 ..< u32(ENCODINGS) { wasm.call_raw(fm.pr.p.instances[0], "send", {enc}) }
	check(fm.pr, status_attr(&fm, "data-formdata") == "size=16;has-extra=1", fmt.tprintf("FormData from the form, formdata event, append/set: %q", status_attr(&fm, "data-formdata")))
	wait_until(t, "the echoes", &fm, proc(fm: ^Form) -> bool {
		return status_attr(fm, "data-echo-multipart") != "" && status_attr(fm, "data-echo-urlencoded") != "" && status_attr(fm, "data-echo-text") != "" || status_attr(fm, "data-echo-error") != ""
	})
	mp := status_attr(&fm, "data-echo-multipart")
	check(fm.pr, strings.contains(mp, "method=POST\ncontent-type=multipart/form-data; boundary=----WrenFormBoundary"), "multipart Content-Type with a random boundary")
	lines := [?]string{"field name=Ada Byron\n", "field code=SET01\n", "field age=38\n", "field lang=en\n", "field news=yes\n", "field plan=pro\n",
		"field bio=Hello\\r\\nworld\n", fmt.tprintf("file up=theme.css;text/css;%d;", size), "field _charset_=UTF-8\n", "field action=send\n",
		"field extra=from-formdata\n", "file blob=hello.txt;text/plain;5;hello\n"}
	for line in lines {
		check(fm.pr, strings.contains(mp, line), fmt.tprintf("multipart carries %q", strings.trim_space(line)))
	}
	check(fm.pr, strings.index(mp, "field name=") < strings.index(mp, "field code=") && strings.index(mp, "field action=") < strings.index(mp, "field extra="), "entries keep tree order")
	ue := status_attr(&fm, "data-echo-urlencoded")
	check(fm.pr, strings.contains(ue, "content-type=application/x-www-form-urlencoded\n") && strings.contains(ue, "field bio=Hello\\r\\nworld\n") && strings.contains(ue, "field up=theme.css\n"), "urlencoded body (files by name, CRLF newlines)")
	tp := status_attr(&fm, "data-echo-text")
	check(fm.pr, strings.contains(tp, "content-type=text/plain\n") && strings.contains(tp, "line name=Ada Byron\n") && strings.contains(tp, "line blob=hello.txt\n"), "text/plain body")
	check(fm.pr, status_attr(&fm, "data-echo-error") == "", "no fetch failed")
	shut(&fm, OPEN_CHECKS + 6 + len(lines))
}

@(test)
forms_submission :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	fm: Form
	if !open(t, &fm) { return }
	fix(&fm)
	size := choose_file(&fm)
	r, _ := wasm.call_i32(fm.pr.p.instances[0], "request_submit")
	check(fm.pr, r == 0, "requestSubmit(send) accepted")
	wait_submissions(&fm, 1)
	check(fm.pr, strings.contains(status_attr(&fm, "data-events"), "submit@f<send>"), "submit event with its submitter")
	if len(fm.submissions) < 1 { shut(&fm, 0); return }
	s := fm.submissions[0]
	check(fm.pr, s.method == .Post && s.enctype == .Multipart && s.url == testenv.url(ECHO_ADDRESS), fmt.tprintf("POST multipart to the action (%v %v %s)", s.method, s.enctype, s.url))
	body := perform(&fm, s)
	check(fm.pr, fm.echo.status == 200 && strings.contains(body, "field action=send\n") && strings.contains(body, fmt.tprintf("file up=theme.css;text/css;%d;", size)), "the server received the multipart submission and the file")

	// the GET button: formmethod / formaction, through a user click
	forms.click(fm.f, el(&fm, "get"), forms.Click_Info{trusted = true})
	wait_submissions(&fm, 2)
	if len(fm.submissions) < 2 { shut(&fm, 0); return }
	s = fm.submissions[1]
	check(fm.pr, s.method == .Get && strings.has_prefix(s.url, testenv.url(ECHO_ADDRESS + "?name=Ada+Byron&email=ada%40example.com")), fmt.tprintf("GET replaces the query: %s", s.url))
	body = perform(&fm, s)
	check(fm.pr, strings.contains(body, "method=GET\n") && strings.contains(body, "field bio=Hello\\r\\nworld\n") && strings.contains(body, "field up=theme.css\n"), "the server received the GET submission")
	shut(&fm, OPEN_CHECKS + 6)
}

@(test)
forms_invalid_form_implicit_submission_reset :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	fm: Form
	if !open(t, &fm) { return }
	fix(&fm)
	choose_file(&fm)
	forms.focus(fm.f, el(&fm, "email"))
	forms.select_all(fm.f, el(&fm, "email"))
	forms.type_text(fm.f, "broken")
	forms.key_down(fm.f, .Enter, {})
	drain()
	check(fm.pr, len(fm.submissions) == 0, "Enter in an invalid form does not submit")
	node, msg, shown := forms.current_report(fm.f)
	check(fm.pr, shown && node == el(&fm, "email") && strings.contains(msg, "'@'"), "the problem is reported on the field")
	call(&fm, "reset_form")
	check(fm.pr, forms.value(fm.f, el(&fm, "name")) == "" && forms.value(fm.f, el(&fm, "email")) == "" && forms.selected_index(fm.f, el(&fm, "lang")) == LANG_DEFAULT_INDEX && len(forms.files(fm.f, el(&fm, "up"))) == 0, "reset restores defaults")
	check(fm.pr, strings.contains(status_attr(&fm, "data-events"), "reset@f"), "reset event")
	shut(&fm, OPEN_CHECKS + 4)
}
