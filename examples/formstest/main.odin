// Guest of the forms end-to-end test (examples/site/forms.html): reads, fills, validates and submits the form through
// the "forms" imports, sends FormData with fetch in the three encodings, and records what the browser tells it in
// data-* attributes of #status that the harness (src/tools/formstest) checks.
package formstest

import "web:web"

form, status, name_el, email, code, age, when_el, level, lang, news, plan_pro, bio, up, send_btn: web.Handle

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

put_value :: proc "contextless" (l: ^Log, label: string, el: web.Handle) {
	b: [256]u8
	v, _ := web.value(el, b[:])
	put(l, label); put(l, "="); put(l, v); put(l, ";")
}

by_id :: proc "contextless" (id: string) -> web.Handle { return web.get_element_by_id(id) }

events: Log

on_event :: proc "contextless" (user: i32, ev: web.Handle) {
	t: [32]u8
	n := web.raw_eventType(ev, raw_data(t[:]), i32(len(t)))
	id: [32]u8
	target := web.Event_target(ev)
	s, _ := web.get_attribute(target, "id", id[:])
	put(&events, string(t[:max(n, 0)])); put(&events, "@"); put(&events, s)
	if string(t[:max(n, 0)]) == "submit" {
		sub := web.Event_object(ev)
		sid: [32]u8
		ss, _ := web.get_attribute(sub, "id", sid[:])
		put(&events, "<"); put(&events, ss); put(&events, ">")
	}
	put(&events, " ")
	web.set_attribute(status, "data-events", str(&events))
}

on_formdata :: proc "contextless" (user: i32, ev: web.Handle) {
	web.form_data_append(web.Event_object(ev), "extra", "from-formdata")
}

@(export)
wb_main :: proc "contextless" () {
	form = by_id("f"); status = by_id("status"); name_el = by_id("name"); email = by_id("email"); code = by_id("code")
	age = by_id("age"); when_el = by_id("when"); level = by_id("level"); lang = by_id("lang"); news = by_id("news")
	plan_pro = by_id("p2"); bio = by_id("bio"); up = by_id("up"); send_btn = by_id("send")
	for ty in ([?]string{"submit", "invalid", "change", "input", "reset", "focus", "blur"}) {
		web.add_listener(form, ty, on_event, 0, capture = true)
	}
	web.add_listener(form, "formdata", on_formdata)
	web.set_text(status, "guest ready")
	// forms.html?demo=fill / ?demo=invalid: a filled form for screenshots, with or without a reported problem
	u: [512]u8
	n := web.raw_documentURL(raw_data(u[:]), i32(len(u)))
	url := string(u[:min(max(int(n), 0), len(u))])
	if contains(url, "demo=") {
		web.set_value(name_el, "Ada Lovelace")
		web.set_value(email, contains(url, "demo=invalid") ? "ada.example.com" : "ada@example.com")
		web.set_value(age, "36")
		web.set_checked(plan_pro, true)
		web.set_value(bio, "Analyst, metaphysician\nand founder of scientific computing.")
		web.set_value(level, "7")
		if contains(url, "demo=invalid") { web.report_validity(form) } else { web.HTMLElement_focus(code) }
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
	put(&l, "checked="); put(&l, web.checked(news) ? "1" : "0"); put(&l, ";")
	put(&l, "index="); put_int(&l, i64(web.HTMLSelectElement_selectedIndex(lang))); put(&l, ";")
	put(&l, "options="); put_int(&l, i64(web.HTMLSelectElement_length(lang))); put(&l, ";")
	put(&l, "elements="); put_int(&l, i64(web.HTMLFormElement_length(form))); put(&l, ";")
	t: [32]u8
	put(&l, "type="); put(&l, web.control_type(lang, t[:])); put(&l, ";")
	put(&l, "active=")
	id: [32]u8
	s, _ := web.get_attribute(web.Document_activeElement(), "id", id[:])
	put(&l, s); put(&l, ";")
	web.set_attribute(status, "data-initial", str(&l))
}

// Fills the form wrongly and reports the validity of each field.
@(export)
validate :: proc "contextless" () {
	web.set_value(email, "not-an-email")
	web.set_value(code, "abc")
	web.set_value(age, "200")
	l: Log
	put(&l, "name:"); put_int(&l, i64(transmute(u32)web.validity(name_el))); put(&l, " ")
	put(&l, "email:"); put_int(&l, i64(transmute(u32)web.validity(email))); put(&l, " ")
	put(&l, "code:"); put_int(&l, i64(transmute(u32)web.validity(code))); put(&l, " ")
	put(&l, "age:"); put_int(&l, i64(transmute(u32)web.validity(age))); put(&l, " ")
	put(&l, "form:"); put(&l, web.check_validity(form) ? "valid" : "invalid"); put(&l, " ")
	msg: [256]u8
	put(&l, "msg:"); put(&l, web.validation_message(email, msg[:]))
	web.set_attribute(status, "data-validity", str(&l))
	web.set_custom_validity(name_el, "custom problem")
	m2: [64]u8
	web.set_attribute(status, "data-custom", web.validation_message(name_el, m2[:]))
	web.set_custom_validity(name_el, "")
}

// Correct values, selection and step APIs.
@(export)
fix :: proc "contextless" () {
	web.set_value(name_el, "Ada Lovelace")
	web.set_value(email, "ada@example.com")
	web.set_value(code, "XYZ42")
	web.set_value(age, "36")
	web.HTMLInputElement_stepUp(age, 2)
	web.set_checked(plan_pro, true)
	web.HTMLSelectElement_setSelectedIndex(lang, 1)
	web.HTMLInputElement_setSelectionRange(name_el, 4, 12, .Forward)
	web.set_range_text(name_el, "Byron", -1, -1, .Select)
	l: Log
	put_value(&l, "name", name_el)
	put(&l, "sel="); put_int(&l, i64(web.HTMLInputElement_selectionStart(name_el))); put(&l, ","); put_int(&l, i64(web.HTMLInputElement_selectionEnd(name_el))); put(&l, ";")
	put(&l, "age="); put_int(&l, i64(web.HTMLInputElement_valueAsNumber(age))); put(&l, ";")
	put(&l, "date="); put_int(&l, i64(web.HTMLInputElement_valueAsDate(when_el) / 86_400_000)); put(&l, ";")
	put(&l, "form="); put(&l, web.check_validity(form) ? "valid" : "invalid"); put(&l, ";")
	web.set_attribute(status, "data-fixed", str(&l))
}

echo_body: [3][2048]u8
echo_len: [3]int

on_echo :: proc "contextless" (user: i32, req: web.Handle, st: web.Fetch_State) {
	#partial switch st {
	case .Done:
		body := web.read_body(req, echo_body[user][:])
		echo_len[user] = len(body)
		names := [3]string{"data-echo-multipart", "data-echo-urlencoded", "data-echo-text"}
		web.set_attribute(status, names[user], string(body))
		web.Fetch_release(req)
	case .Failed:
		b: [128]u8
		n := web.raw_fetchError(req, raw_data(b[:]), i32(len(b)))
		web.set_attribute(status, "data-echo-error", string(b[:max(n, 0)]))
		web.Fetch_release(req)
	}
}

// FormData from the form (submitter = Send, plus an appended blob) sent with fetch in encoding `enctype`.
@(export)
send :: proc "contextless" (enctype: i32) {
	fd := web.form_data(form, send_btn)
	if fd == web.NIL { web.set_attribute(status, "data-echo-error", "no FormData"); return }
	bytes := [5]u8{'h', 'e', 'l', 'l', 'o'}
	buf := web.buffer_create(bytes[:])
	web.form_data_append_blob(fd, "blob", buf, "hello.txt", "text/plain")
	web.Object_release(buf)
	web.form_data_set(fd, "code", "SET01")
	l: Log
	put(&l, "size="); put_int(&l, i64(web.FormData_size(fd))); put(&l, ";has-extra="); put(&l, web.form_data_has(fd, "extra") ? "1" : "0")
	web.set_attribute(status, "data-formdata", str(&l))
	web.fetch_form_data("/forms/echo", fd, on_echo, enctype, enctype = web.Form_Enctype(enctype))
	web.Object_release(fd)
}

@(export)
request_submit :: proc "contextless" () -> i32 { return i32(web.HTMLFormElement_requestSubmit(form, send_btn)) }

@(export)
reset_form :: proc "contextless" () { web.HTMLFormElement_reset(form) }
