// Guest of the forms end-to-end test (examples/site/forms.html): reads, fills, validates and submits the form through
// the "forms" imports, sends FormData with fetch in the three encodings, and records what the browser tells it in
// data-* attributes of #status that its test (src/tools/webtests/forms.odin) checks.
package formstest

import "wren:core"
import "wren:document"
import "wren:dom"
import "wren:fetch"
import "wren:forms"
import "wren:net"

form, status, name_el, email, code, age, when_el, level, lang, news, plan_pro, bio, up, send_btn: dom.Element

// a tiny append-only text log, written to an attribute when done
Log :: struct { buf: [4096]u8, n: int }

put :: proc "contextless" (l: ^Log, s: string) {
	for i in 0 ..< len(s) { if l.n < len(l.buf) { l.buf[l.n] = s[i]; l.n += 1 } }
}

str :: proc "contextless" (l: ^Log) -> string { return string(l.buf[:l.n]) }

itoa :: proc "contextless" (v: i64, buf: []u8) -> string {
	if v == 0 { buf[0] = '0'; return string(buf[:1]) }
	neg := v < 0
	n := neg ? -v : v
	i := len(buf)
	for n > 0 { i -= 1; buf[i] = u8('0' + n % 10); n /= 10 }
	if neg { i -= 1; buf[i] = '-' }
	return string(buf[i:])
}

put_int :: proc "contextless" (l: ^Log, v: i64) { b: [24]u8; put(l, itoa(v, b[:])) }

put_value :: proc "contextless" (l: ^Log, label: string, el: dom.Element) {
	b: [256]u8
	v, _ := forms.HTMLInputElement_value(el, b[:])
	put(l, label); put(l, "="); put(l, v); put(l, ";")
}

by_id :: proc "contextless" (id: string) -> dom.Element { return dom.Document_getElementById(id) }

events: Log

on_event :: proc "contextless" (user: i32, ev: core.Event) {
	t: [32]u8
	ty, _ := core.Event_type(ev, t[:])
	id: [32]u8
	target := core.Event_target(ev)
	s, _ := dom.Element_getAttribute(dom.Element(target), "id", id[:])
	put(&events, ty); put(&events, "@"); put(&events, s)
	if ty == "submit" {
		sub := core.Event_object(ev)
		sid: [32]u8
		ss, _ := dom.Element_getAttribute(dom.Element(sub), "id", sid[:])
		put(&events, "<"); put(&events, ss); put(&events, ">")
	}
	put(&events, " ")
	dom.Element_setAttribute(status, "data-events", str(&events))
}

on_formdata :: proc "contextless" (user: i32, ev: core.Event) {
	forms.FormData_append(forms.FormData(core.Event_object(ev)), "extra", "from-formdata")
}

@(export)
wb_main :: proc "contextless" () {
	form = by_id("f"); status = by_id("status"); name_el = by_id("name"); email = by_id("email"); code = by_id("code")
	age = by_id("age"); when_el = by_id("when"); level = by_id("level"); lang = by_id("lang"); news = by_id("news")
	plan_pro = by_id("p2"); bio = by_id("bio"); up = by_id("up"); send_btn = by_id("send")
	for ty in ([?]string{"submit", "invalid", "change", "input", "reset", "focus", "blur"}) {
		core.EventTarget_addEventListener(form, ty, on_event, 0, {.Capture})
	}
	core.EventTarget_addEventListener(form, "formdata", on_formdata)
	dom.Node_setTextContent(status, "guest ready")
	// forms.html?demo=fill / ?demo=invalid: a filled form for screenshots, with or without a reported problem
	u: [512]u8
	url, _ := document.URL(u[:])
	if contains(url, "demo=") {
		forms.HTMLInputElement_setValue(name_el, "Ada Lovelace")
		forms.HTMLInputElement_setValue(email, contains(url, "demo=invalid") ? "ada.example.com" : "ada@example.com")
		forms.HTMLInputElement_setValue(age, "36")
		forms.HTMLInputElement_setChecked(plan_pro, true)
		forms.HTMLInputElement_setValue(bio, "Analyst, metaphysician\nand founder of scientific computing.")
		forms.HTMLInputElement_setValue(level, "7")
		if contains(url, "demo=invalid") { forms.HTMLFormElement_reportValidity(form) } else { forms.HTMLElement_focus(code) }
	}
}

contains :: proc "contextless" (s, sub: string) -> bool {
	if len(sub) > len(s) { return false }
	for i in 0 ..= len(s) - len(sub) { if s[i:i + len(sub)] == sub { return true } }
	return false
}

// What the page starts with, as the guest reads it.
@(export)
read_initial :: proc "contextless" () {
	l: Log
	put_value(&l, "name", name_el); put_value(&l, "code", code); put_value(&l, "age", age); put_value(&l, "when", when_el)
	put_value(&l, "level", level); put_value(&l, "lang", lang); put_value(&l, "bio", bio); put_value(&l, "news", news)
	put(&l, "checked="); put(&l, forms.HTMLInputElement_checked(news) ? "1" : "0"); put(&l, ";")
	put(&l, "index="); put_int(&l, i64(forms.HTMLSelectElement_selectedIndex(lang))); put(&l, ";")
	put(&l, "options="); put_int(&l, i64(forms.HTMLSelectElement_length(lang))); put(&l, ";")
	put(&l, "elements="); put_int(&l, i64(forms.HTMLFormElement_length(form))); put(&l, ";")
	t: [32]u8
	ts, _ := forms.HTMLSelectElement_type(lang, t[:])
	put(&l, "type="); put(&l, ts); put(&l, ";")
	put(&l, "active=")
	id: [32]u8
	s, _ := dom.Element_getAttribute(forms.Document_activeElement(), "id", id[:])
	put(&l, s); put(&l, ";")
	dom.Element_setAttribute(status, "data-initial", str(&l))
}

// Fills the form wrongly and reports the validity of each field.
@(export)
validate :: proc "contextless" () {
	forms.HTMLInputElement_setValue(email, "not-an-email")
	forms.HTMLInputElement_setValue(code, "abc")
	forms.HTMLInputElement_setValue(age, "200")
	l: Log
	put(&l, "name:"); put_int(&l, i64(transmute(u32)forms.HTMLInputElement_validity(name_el))); put(&l, " ")
	put(&l, "email:"); put_int(&l, i64(transmute(u32)forms.HTMLInputElement_validity(email))); put(&l, " ")
	put(&l, "code:"); put_int(&l, i64(transmute(u32)forms.HTMLInputElement_validity(code))); put(&l, " ")
	put(&l, "age:"); put_int(&l, i64(transmute(u32)forms.HTMLInputElement_validity(age))); put(&l, " ")
	put(&l, "form:"); put(&l, forms.HTMLFormElement_checkValidity(form) ? "valid" : "invalid"); put(&l, " ")
	msg: [256]u8
	vm, _ := forms.HTMLInputElement_validationMessage(email, msg[:])
	put(&l, "msg:"); put(&l, vm)
	dom.Element_setAttribute(status, "data-validity", str(&l))
	forms.HTMLInputElement_setCustomValidity(name_el, "custom problem")
	m2: [64]u8
	cm, _ := forms.HTMLInputElement_validationMessage(name_el, m2[:])
	dom.Element_setAttribute(status, "data-custom", cm)
	forms.HTMLInputElement_setCustomValidity(name_el, "")
}

// Correct values, selection and step APIs.
@(export)
fix :: proc "contextless" () {
	forms.HTMLInputElement_setValue(name_el, "Ada Lovelace")
	forms.HTMLInputElement_setValue(email, "ada@example.com")
	forms.HTMLInputElement_setValue(code, "XYZ42")
	forms.HTMLInputElement_setValue(age, "36")
	forms.HTMLInputElement_stepUp(age, 2)
	forms.HTMLInputElement_setChecked(plan_pro, true)
	forms.HTMLSelectElement_setSelectedIndex(lang, 1)
	forms.HTMLInputElement_setSelectionRange(name_el, 4, 12, .Forward)
	forms.HTMLInputElement_setRangeText(name_el, "Byron", -1, -1, .Select)
	l: Log
	put_value(&l, "name", name_el)
	put(&l, "sel="); put_int(&l, i64(forms.HTMLInputElement_selectionStart(name_el))); put(&l, ","); put_int(&l, i64(forms.HTMLInputElement_selectionEnd(name_el))); put(&l, ";")
	put(&l, "age="); put_int(&l, i64(forms.HTMLInputElement_valueAsNumber(age))); put(&l, ";")
	put(&l, "date="); put_int(&l, i64(forms.HTMLInputElement_valueAsDate(when_el) / 86_400_000)); put(&l, ";")
	put(&l, "form="); put(&l, forms.HTMLFormElement_checkValidity(form) ? "valid" : "invalid"); put(&l, ";")
	dom.Element_setAttribute(status, "data-fixed", str(&l))
}

echo_body: [3][2048]u8
echo_len: [3]int

on_echo :: proc "contextless" (user: i32, req: net.Fetch, st: net.FetchState) {
	#partial switch st {
	case .Done:
		body := echo_body[user][:net.Fetch_readBody(req, 0, echo_body[user][:])]
		echo_len[user] = len(body)
		names := [3]string{"data-echo-multipart", "data-echo-urlencoded", "data-echo-text"}
		dom.Element_setAttribute(status, names[user], string(body))
		net.Fetch_release(req)
	case .Failed:
		b: [128]u8
		msg, _ := net.Fetch_error(req, b[:])
		dom.Element_setAttribute(status, "data-echo-error", msg)
		net.Fetch_release(req)
	}
}

// FormData from the form (submitter = Send, plus an appended blob) sent with fetch in encoding `enctype`.
@(export)
send :: proc "contextless" (enctype: i32) {
	fd, ferr := forms.FormData_create(form, send_btn)
	if ferr != .None { dom.Element_setAttribute(status, "data-echo-error", "no FormData"); return }
	bytes := [5]u8{'h', 'e', 'l', 'l', 'o'}
	buf, _ := core.Buffer_create(bytes[:])
	forms.FormData_appendBlob(fd, "blob", buf, "hello.txt", "text/plain")
	core.Object_release(buf)
	forms.FormData_set(fd, "code", "SET01")
	l: Log
	put(&l, "size="); put_int(&l, i64(forms.FormData_size(fd))); put(&l, ";has-extra="); put(&l, forms.FormData_has(fd, "extra") ? "1" : "0")
	dom.Element_setAttribute(status, "data-formdata", str(&l))
	fetch.startFormData("/forms/echo", fd, on_echo, enctype, enctype = forms.FormEnctype(enctype))
	core.Object_release(fd)
}

@(export)
request_submit :: proc "contextless" () -> i32 { return i32(forms.HTMLFormElement_requestSubmit(form, send_btn)) }

@(export)
reset_form :: proc "contextless" () { forms.HTMLFormElement_reset(form) }
