package forms

import "core:math"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"

// Test fixture: a document parsed by the real HTML parser, a host that records events and submissions.

@(private = "file")
Fixture :: struct {
	doc:      ^dom.Document,
	f:        ^Forms,
	settings: Settings,
	events:   [dynamic]string,        // "type@id"
	cancel:   map[string]bool,        // event types to cancel
	subs:     [dynamic]^Submission,
	clock:    f64,
	url:      string,
	style_changes: int,
	edit_on_beforeinput: bool,
}

@(private = "file")
fx_make :: proc(src: string, doc_url := "http://example.test/dir/page.html") -> ^Fixture {
	x := new(Fixture)
	x.doc = dom.document_create()
	html.parse_into(x.doc, x.doc.root, transmute([]byte)src, 100_000)
	x.settings = settings_default()
	x.url = doc_url
	x.f = forms_create(x.doc, &x.settings, Host{
		user = x,
		dispatch = proc(user: rawptr, target: base.Handle, ev: dom.Event) -> bool {
			x := (^Fixture)(user)
			id, _ := dom.get_attribute(x.doc, target, "id")
			append(&x.events, strings.concatenate({ev.type, "@", id}))
			return !(ev.cancelable && x.cancel[ev.type])
		},
		document_url = proc(user: rawptr) -> string { return (^Fixture)(user).url },
		navigate = proc(user: rawptr, s: ^Submission) { append(&(^Fixture)(user).subs, s) },
		style_changed = proc(user: rawptr) { (^Fixture)(user).style_changes += 1 },
		now_ms = proc(user: rawptr) -> f64 { return (^Fixture)(user).clock },
	})
	return x
}

@(private = "file")
fx_destroy :: proc(x: ^Fixture) {
	forms_destroy(x.f)
	dom.document_destroy(x.doc)
	for e in x.events { delete(e) }
	delete(x.events)
	delete(x.cancel)
	for s in x.subs { submission_destroy(s) }
	delete(x.subs)
	settings_destroy(&x.settings)
	free(x)
}

@(private = "file")
id :: proc(x: ^Fixture, name: string) -> base.Handle { return dom.find_by_id(x.doc, name) }

@(private = "file")
events_string :: proc(x: ^Fixture) -> string { return strings.join(x.events[:], " ", context.temp_allocator) }

@(private = "file")
clear_events :: proc(x: ^Fixture) {
	for e in x.events { delete(e) }
	clear(&x.events)
}

////////////////////////////////
// Sanitization

@(test)
sanitization_per_type :: proc(t: ^testing.T) {
	x := fx_make(`<input id=t value="a&#10;b"><input id=u type=url value="  http://x/  "><input id=e type=email multiple value=" a@b.c , d@e.f ">
<input id=n type=number value="1e3"><input id=nb type=number value="1."><input id=r type=range min=0 max=10 step=3 value=8>
<input id=r2 type=range value=abc><input id=d type=date value=2024-02-29><input id=d2 type=date value=2023-02-29>
<input id=dt type=datetime-local value="2024-01-02 03:04:00"><input id=c type=color value="#AABBCC"><input id=c2 type=color value=red>
<input id=w type=week value=2020-W53><input id=w2 type=week value=2021-W53><input id=m type=month value=2024-13>
<input id=tm type=time value="23:59:59.5"><input id=cb type=checkbox><input id=h type=hidden value=" x ">`)
	defer fx_destroy(x)
	f := x.f
	testing.expect_value(t, value(f, id(x, "t")), "ab")
	testing.expect_value(t, value(f, id(x, "u")), "http://x/")
	testing.expect_value(t, value(f, id(x, "e")), "a@b.c,d@e.f")
	testing.expect_value(t, value(f, id(x, "n")), "1e3")
	testing.expect_value(t, value(f, id(x, "nb")), "")
	testing.expect_value(t, value(f, id(x, "r")), "9")     // clamped to max 10, then the nearest step (0, 3, 6, 9)
	testing.expect_value(t, value(f, id(x, "r2")), "50")   // default: the middle
	testing.expect_value(t, value(f, id(x, "d")), "2024-02-29")
	testing.expect_value(t, value(f, id(x, "d2")), "")
	testing.expect_value(t, value(f, id(x, "dt")), "2024-01-02T03:04")
	testing.expect_value(t, value(f, id(x, "c")), "#aabbcc")
	testing.expect_value(t, value(f, id(x, "c2")), "#000000")
	testing.expect_value(t, value(f, id(x, "w")), "2020-W53")
	testing.expect_value(t, value(f, id(x, "w2")), "")
	testing.expect_value(t, value(f, id(x, "m")), "")
	testing.expect_value(t, value(f, id(x, "tm")), "23:59:59.5")
	testing.expect_value(t, value(f, id(x, "cb")), "on")
	testing.expect_value(t, value(f, id(x, "h")), " x ")

	// script sets: sanitized, dirty, the attribute no longer follows
	n := id(x, "n")
	set_value(f, n, "abc")
	testing.expect_value(t, value(f, n), "")
	set_value(f, n, "42")
	dom.set_attribute(x.doc, n, "value", "7")
	testing.expect_value(t, value(f, n), "42")
	// a non-dirty field follows its attribute
	dom.set_attribute(x.doc, id(x, "t"), "value", "new")
	testing.expect_value(t, value(f, id(x, "t")), "new")
	// type change: value mode transitions
	tt := id(x, "t")
	set_value(f, tt, "typed")
	dom.set_attribute(x.doc, tt, "type", "hidden")
	testing.expect_value(t, value(f, tt), "typed")   // value -> default: the dirty value went into the attribute
	dom.set_attribute(x.doc, tt, "type", "number")
	testing.expect_value(t, value(f, tt), "")        // back to value mode: sanitized from the attribute
}

@(test)
numbers_and_dates :: proc(t: ^testing.T) {
	a, b := 0.1, 0.2
	testing.expect_value(t, format_float(a + b), "0.30000000000000004")
	testing.expect_value(t, format_float(0.000001), "0.000001")
	testing.expect_value(t, format_float(123456.789), "123456.789")
	testing.expect_value(t, format_float(1e21), "1e+21")
	testing.expect_value(t, format_float(-5), "-5")
	testing.expect_value(t, format_float(1e-7), "1e-7")
	testing.expect(t, is_valid_float(".5") && !is_valid_float("5.") && !is_valid_float("+1") && is_valid_float("-1.5E-3"))
	d, ok := parse_date("1970-01-02")
	testing.expect(t, ok && d == 1)
	testing.expect_value(t, format_date(days_from_civil(2000, 2, 29)), "2000-02-29")
	testing.expect_value(t, format_week(i64(days_from_civil(2021, 1, 3)) * MS_PER_DAY), "2020-W53")
	testing.expect_value(t, format_week(i64(days_from_civil(2024, 12, 30)) * MS_PER_DAY), "2025-W01")
	testing.expect_value(t, format_time(45_296_007), "12:34:56.007")
	testing.expect_value(t, format_month(-1), "1969-12")
	ms, ok2 := parse_datetime_local("2024-03-10T10:00")
	testing.expect(t, ok2)
	s, _ := string_from_number(.Datetime_Local, f64(ms))
	testing.expect_value(t, s, "2024-03-10T10:00")
}

@(test)
value_as_number_and_step :: proc(t: ^testing.T) {
	x := fx_make(`<input id=n type=number min=1 max=10 step=3 value=4><input id=d type=date value=2024-01-31 step=7>
<input id=a type=number step=any value=1.5><input id=tm type=time value=10:00><input id=m type=month value=1970-03>`)
	defer fx_destroy(x)
	f := x.f
	n := id(x, "n")
	testing.expect_value(t, value_as_number(f, n), 4)
	testing.expect_value(t, step(f, n, 1), Error.None)
	testing.expect_value(t, value(f, n), "7")
	step(f, n, 2)
	testing.expect_value(t, value(f, n), "10")   // 13 is over max: the largest step value <= max
	set_value(f, n, "5")                          // off-step: stepUp goes to the next step value
	step(f, n, 1)
	testing.expect_value(t, value(f, n), "7")
	set_value(f, n, "5")
	step(f, n, -1)
	testing.expect_value(t, value(f, n), "4")
	testing.expect_value(t, step(f, id(x, "a"), 1), Error.Invalid_State)
	d := id(x, "d")
	step(f, d, 1)
	testing.expect_value(t, value(f, d), "2024-02-07")
	set_value_as_number(f, id(x, "tm"), 3_600_000 * 13 + 1500)
	testing.expect_value(t, value(f, id(x, "tm")), "13:00:01.5")
	testing.expect_value(t, value_as_number(f, id(x, "m")), 2)
	dv, dok := value_as_date(f, id(x, "m"))
	testing.expect(t, dok && dv == 59 * f64(MS_PER_DAY))
	testing.expect(t, math.is_nan(value_as_number(f, id(x, "nonexistent"))))
}

////////////////////////////////
// Validity

@(test)
validity_flags :: proc(t: ^testing.T) {
	x := fx_make(`<form id=f>
<input id=req required><input id=email type=email value="nope"><input id=url type=url value="not a url">
<input id=pat pattern="[a-z]{2}\d+" value="ab12"><input id=pat2 pattern="[a-z]{2}\d+" value="AB12">
<input id=lo type=number min=5 value=3><input id=hi type=number max=5 value=7><input id=st type=number min=0 step=2 value=3>
<input id=ml maxlength=3><input id=mn minlength=3><input id=dis required disabled><input id=ro required readonly>
<input id=num type=number><select id=sel required><option value="">Choose</option><option>A</option></select>
<input id=cb type=checkbox required><input id=f1 type=file required><textarea id=ta required></textarea>
<input id=ok value=fine><input id=badpat pattern="(?=x)" value=y><input id=rev type=time min=22:00 max=06:00 value=12:00>
</form>`)
	defer fx_destroy(x)
	f := x.f
	testing.expect_value(t, validity(f, id(x, "req")), Validity{.Value_Missing})
	testing.expect_value(t, validity(f, id(x, "email")), Validity{.Type_Mismatch})
	testing.expect_value(t, validity(f, id(x, "url")), Validity{.Type_Mismatch})
	testing.expect_value(t, validity(f, id(x, "pat")), Validity{})
	testing.expect_value(t, validity(f, id(x, "pat2")), Validity{.Pattern_Mismatch})
	testing.expect_value(t, validity(f, id(x, "lo")), Validity{.Range_Underflow})
	testing.expect_value(t, validity(f, id(x, "hi")), Validity{.Range_Overflow})
	testing.expect_value(t, validity(f, id(x, "st")), Validity{.Step_Mismatch})
	testing.expect_value(t, validity(f, id(x, "rev")), Validity{.Range_Underflow, .Range_Overflow})
	testing.expect_value(t, validity(f, id(x, "badpat")), Validity{})   // unsupported pattern: ignored
	// too long / too short only after a user edit
	ml := id(x, "ml")
	set_value(f, ml, "abcdef")
	testing.expect_value(t, validity(f, ml), Validity{})
	focus(f, ml)
	edit(f, ml, .Delete_Backward)
	testing.expect_value(t, validity(f, ml), Validity{.Too_Long})
	mn := id(x, "mn")
	focus(f, mn)
	edit(f, mn, .Insert_Text, "é")
	testing.expect_value(t, validity(f, mn), Validity{.Too_Short})
	// maxlength stops typing
	set_value(f, ml, "")
	edit(f, ml, .Insert_Text, "12345")
	testing.expect_value(t, value(f, ml), "123")
	// bad input
	num := id(x, "num")
	focus(f, num)
	edit(f, num, .Insert_Text, "12x")
	testing.expect_value(t, validity(f, num), Validity{.Bad_Input})
	testing.expect_value(t, value(f, num), "")
	// barred and not mutable
	testing.expect(t, !will_validate(f, id(x, "dis")) && !will_validate(f, id(x, "ro")))
	testing.expect_value(t, validity(f, id(x, "dis")), Validity{})
	// select placeholder label option
	testing.expect_value(t, validity(f, id(x, "sel")), Validity{.Value_Missing})
	set_selected_index(f, id(x, "sel"), 1)
	testing.expect_value(t, validity(f, id(x, "sel")), Validity{})
	testing.expect_value(t, validity(f, id(x, "cb")), Validity{.Value_Missing})
	testing.expect_value(t, validity(f, id(x, "f1")), Validity{.Value_Missing})
	testing.expect_value(t, validity(f, id(x, "ta")), Validity{.Value_Missing})
	// custom error
	ok := id(x, "ok")
	set_custom_validity(f, ok, "nope")
	testing.expect_value(t, validity(f, ok), Validity{.Custom_Error})
	testing.expect_value(t, validation_message(f, ok), "nope")
	set_custom_validity(f, ok, "")
	testing.expect(t, is_valid(f, ok))
	testing.expect_value(t, validation_message(f, id(x, "req")), "Please fill out this field.")
	testing.expect(t, strings.contains(validation_message(f, id(x, "email")), "missing an '@'"))
	// checkValidity fires invalid at each invalid element
	clear_events(x)
	testing.expect(t, !check_validity(f, id(x, "f")))
	testing.expect(t, strings.contains(events_string(x), "invalid@req") && strings.contains(events_string(x), "invalid@email"))
	testing.expect(t, !strings.contains(events_string(x), "invalid@ok"))
}

@(test)
pattern_engine :: proc(t: ^testing.T) {
	cases := [?]struct { pat, s: string, want: bool }{
		{`[a-z]+`, "abc", true}, {`[a-z]+`, "abC", false}, {`a|b|cd`, "cd", true}, {`a|b|cd`, "c", false},
		{`(ab)*c`, "ababc", true}, {`x{2,3}`, "xxxx", false}, {`x{2,}`, "xxxxx", true}, {`\d{3}-\d{4}`, "555-1234", true},
		{`[^0-9]*`, "abc", true}, {`[^0-9]*`, "ab1", false}, {`.`, "\n", false}, {`\p{Lu}\p{Ll}+`, "Élan", true},
		{`[\p{L}--[a-z]]+`, "ABÉ", true}, {`[\p{L}--[a-z]]+`, "Ab", false}, {`[\w&&[^_]]+`, "a_b", false},
		{`\u{1F600}`, "\U0001F600", true}, {`\uD83D\uDE00`, "\U0001F600", true}, {`a(?:b|c)?`, "a", true},
		{`^abc$`, "abc", true}, {`\bfoo\b`, "foo", true}, {`(a*)*b`, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac", false},
		{`[\q{x|y}]`, "y", true}, {`\.`, ".", true}, {`\.`, "a", false},
	}
	for c in cases {
		re := regex_compile(c.pat, 10_000)
		testing.expect(t, re != nil, c.pat)
		if re == nil { continue }
		m, ok := regex_full_match(re, c.s, 1_000_000)
		testing.expect(t, ok && m == c.want, c.pat)
		regex_destroy(re)
	}
	for bad in ([?]string{`(?=a)`, `\1`, `[a`, `a{2`, `*a`, `[(]`, `a**`, `(?<!x)`, `\q`}) {
		re := regex_compile(bad, 10_000)
		testing.expect(t, re == nil, bad)
		regex_destroy(re)
	}
	testing.expect(t, regex_compile(`a{1000}{1000}`, 10_000) == nil, "program size is capped")
	// zero-width bodies repeated an enormous number of times compile at once (the size cap never saw them grow)
	zero_width := [?]struct { pat, s: string }{{`(?:(?:){16777216}){16777216}`, ""}, {`(?:a{0}){16777216}x`, "x"}, {`(?:(?:(?:){99999999}){99999999})*y`, "y"}}
	for zw in zero_width {
		re := regex_compile(zw.pat, 10_000)
		testing.expect(t, re != nil, zw.pat)
		if re != nil {
			m, ok := regex_full_match(re, zw.s, 1_000_000)
			testing.expect(t, ok && m, zw.pat)
		}
		regex_destroy(re)
	}
}

////////////////////////////////
// Radio groups, form owner, disabled

@(test)
radio_groups_and_owners :: proc(t: ^testing.T) {
	x := fx_make(`<form id=f1><input id=a type=radio name=g checked><input id=b type=radio name=g checked>
<input id=c type=radio name=G><fieldset id=fs disabled><legend id=lg><input id=inlegend></legend><input id=infs></fieldset></form>
<form id=f2></form><input id=d type=radio name=g form=f1><input id=e type=radio name=g><input id=o form=f2><input id=bad form=nope>
<select id=s><optgroup disabled><option id=og>x</option></optgroup></select>`)
	defer fx_destroy(x)
	f := x.f
	a, b, c, d, e := id(x, "a"), id(x, "b"), id(x, "c"), id(x, "d"), id(x, "e")
	testing.expect(t, !checked(f, a) && checked(f, b), "the parser leaves the last checked radio checked")
	testing.expect_value(t, len(radio_group(f, a)), 3)   // a, b, d (form attribute) ; not c (name differs in case), not e (no owner)
	testing.expect_value(t, form_owner(f, d), id(x, "f1"))
	testing.expect_value(t, form_owner(f, id(x, "o")), id(x, "f2"))
	testing.expect_value(t, form_owner(f, id(x, "bad")), base.NIL_HANDLE)
	set_checked(f, d, true)
	testing.expect(t, !checked(f, b) && checked(f, d) && !checked(f, c))
	testing.expect(t, checked(f, d))
	set_checked(f, e, true)
	testing.expect(t, checked(f, d), "a radio of another group is not affected")
	testing.expect(t, is_disabled(f, id(x, "infs")) && !is_disabled(f, id(x, "inlegend")))
	testing.expect(t, is_disabled(f, id(x, "og")))
	testing.expect_value(t, len(form_elements(f, id(x, "f1"))), 7)   // a b c fs inlegend infs d
}

////////////////////////////////
// Entry list and encodings

@(private = "file")
SUBMIT_DOC :: `<form id=f action="/submit?old=1#frag" method=post>
<input name=text value="a b&c=d"><input name="ünï" value="é€😀"><textarea name=ta>line1
line2</textarea><input type=checkbox name=cb checked><input type=checkbox name=cb2><input type=radio name=r value=x>
<input type=radio name=r value=y checked><select name=s multiple><option selected>one</option><option selected disabled>two</option><option value=3 selected>three</option></select>
<input name=_charset_ type=hidden><input name=dis disabled value=z><input type=submit name=go value=Go id=go><input type=submit name=other value=Other>
<input type=image name=img id=img><input type=file name=up><input name="q&quot;
x" dirname=q.dir value=hi><button name=b>btn</button>
</form>`

@(test)
entry_list_and_urlencoded :: proc(t: ^testing.T) {
	x := fx_make(SUBMIT_DOC)
	defer fx_destroy(x)
	f := x.f
	list, ok := construct_entry_list(f, id(x, "f"), id(x, "go"))
	testing.expect(t, ok)
	defer entries_destroy(&list)
	names := make([dynamic]string, context.temp_allocator)
	for e in list { append(&names, e.name) }
	testing.expect_value(t, strings.join(names[:], ",", context.temp_allocator), "text,ünï,ta,cb,r,s,s,_charset_,go,up,q\"\nx,q.dir")
	body := urlencode(list[:], context.temp_allocator)
	testing.expect_value(t, body, "text=a+b%26c%3Dd&%C3%BCn%C3%AF=%C3%A9%E2%82%AC%F0%9F%98%80&ta=line1%0D%0Aline2&cb=on&r=y&s=one&s=3&_charset_=UTF-8&go=Go&up=&q%22%0D%0Ax=hi&q.dir=ltr")
	tp := text_plain(list[:], context.temp_allocator)
	testing.expect(t, strings.has_prefix(tp, "text=a b&c=d\r\nünï=é€😀\r\nta=line1\r\nline2\r\ncb=on\r\n"), tp)
}

@(test)
multipart_bytes :: proc(t: ^testing.T) {
	list := make([dynamic]Entry)
	defer entries_destroy(&list)
	append(&list, Entry{name = strings.clone("a\"b\nc"), value = strings.clone("x\ny")})
	append(&list, Entry{name = strings.clone("f"), is_file = true, file = File{name = strings.clone("n\"a.txt"), mime = strings.clone("text/plain"), data = transmute([]byte)strings.clone("DATA")}})
	append(&list, Entry{name = strings.clone("empty"), is_file = true, file = File{name = strings.clone(""), mime = strings.clone("application/octet-stream")}})
	s := settings_default()
	defer settings_destroy(&s)
	body, ok, _ := multipart(list[:], "BOUND", s)
	defer delete(body)
	testing.expect(t, ok)
	want := "--BOUND\r\nContent-Disposition: form-data; name=\"a%22b%0D%0Ac\"\r\n\r\nx\r\ny\r\n" +
		"--BOUND\r\nContent-Disposition: form-data; name=\"f\"; filename=\"n%22a.txt\"\r\nContent-Type: text/plain\r\n\r\nDATA\r\n" +
		"--BOUND\r\nContent-Disposition: form-data; name=\"empty\"; filename=\"\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n" +
		"--BOUND--\r\n"
	testing.expect_value(t, string(body), want)
	b := make_boundary(context.temp_allocator)
	testing.expect(t, strings.has_prefix(b, "----WrenFormBoundary") && len(b) == 36)
}

@(test)
submission_get_post :: proc(t: ^testing.T) {
	x := fx_make(`<form id=g action="search?x=1#top"><input name=q value="a b"><input type=submit id=s formmethod=post formaction="/p" formenctype=text/plain></form>
<form id=dlg method=dialog></form><form id=nv novalidate action=/nv><input required name=r></form><form id=v action=/v><input required name=r id=r></form>`)
	defer fx_destroy(x)
	f := x.f
	submit(f, id(x, "g"), base.NIL_HANDLE)
	testing.expect_value(t, len(x.subs), 1)
	s := x.subs[0]
	testing.expect_value(t, s.method, Submit_Method.Get)
	testing.expect_value(t, s.url, "http://example.test/dir/search?q=a+b#top")
	submit(f, id(x, "g"), id(x, "s"))
	s = x.subs[1]
	testing.expect_value(t, s.method, Submit_Method.Post)
	testing.expect_value(t, s.url, "http://example.test/p")
	testing.expect_value(t, s.enctype, Enctype.Text_Plain)
	ok, _ := encode_submission(s, x.settings)
	testing.expect(t, ok)
	testing.expect_value(t, string(s.body), "q=a b\r\n")
	testing.expect_value(t, s.content_type, "text/plain")
	// validation blocks, novalidate does not
	clear_events(x)
	submit(f, id(x, "v"), base.NIL_HANDLE)
	testing.expect_value(t, len(x.subs), 2)
	testing.expect(t, strings.contains(events_string(x), "invalid@r"))
	testing.expect_value(t, f.focus, id(x, "r"))
	_, msg, shown := current_report(f)
	testing.expect(t, shown && msg == "Please fill out this field.")
	submit(f, id(x, "nv"), base.NIL_HANDLE)
	testing.expect_value(t, len(x.subs), 3)
	// the submit event can cancel
	x.cancel["submit"] = true
	submit(f, id(x, "g"), base.NIL_HANDLE)
	testing.expect_value(t, len(x.subs), 3)
	submit(f, id(x, "g"), base.NIL_HANDLE, from_method = true)   // form.submit(): no event, no validation
	testing.expect_value(t, len(x.subs), 4)
	// requestSubmit checks its submitter
	testing.expect_value(t, request_submit(f, id(x, "g"), id(x, "r")), Error.Not_Supported)
}

@(test)
implicit_submission_and_reset :: proc(t: ^testing.T) {
	x := fx_make(`<form id=one action=/one><input id=only name=a value=1></form>
<form id=two action=/two><input id=t1 name=a><input id=t2 name=b></form>
<form id=three action=/three><input id=t3 name=a><input id=t4 name=b><button id=go disabled>go</button></form>
<form id=four action=/four><input id=t5 name=a value=orig><input type=checkbox id=cb checked><select id=s><option>a</option><option selected>b</option></select><textarea id=ta>txt</textarea><input type=submit id=sb></form>`)
	defer fx_destroy(x)
	f := x.f
	focus(f, id(x, "only"))
	key_down(f, .Enter, {})
	testing.expect_value(t, len(x.subs), 1)
	focus(f, id(x, "t1"))
	key_down(f, .Enter, {})
	testing.expect_value(t, len(x.subs), 1)   // two blocking fields and no default button
	focus(f, id(x, "t3"))
	key_down(f, .Enter, {})
	testing.expect_value(t, len(x.subs), 1)   // the default button is disabled
	focus(f, id(x, "t5"))
	key_down(f, .Enter, {})
	testing.expect_value(t, len(x.subs), 2)   // through the default button
	testing.expect_value(t, x.subs[1].submitter, id(x, "sb"))

	set_value(f, id(x, "t5"), "changed")
	set_checked(f, id(x, "cb"), false)
	set_selected_index(f, id(x, "s"), 0)
	set_value(f, id(x, "ta"), "other")
	reset(f, id(x, "four"))
	testing.expect_value(t, value(f, id(x, "t5")), "orig")
	testing.expect(t, checked(f, id(x, "cb")))
	testing.expect_value(t, selected_index(f, id(x, "s")), 1)
	testing.expect_value(t, value(f, id(x, "ta")), "txt")
	x.cancel["reset"] = true
	set_value(f, id(x, "t5"), "changed")
	reset(f, id(x, "four"))
	testing.expect_value(t, value(f, id(x, "t5")), "changed")
}

////////////////////////////////
// Editing

@(test)
text_editing :: proc(t: ^testing.T) {
	x := fx_make(`<input id=i value="héllo"><textarea id=ta>ab
cd</textarea><input id=ro readonly value=r>`)
	defer fx_destroy(x)
	f := x.f
	i := id(x, "i")
	focus(f, i)
	set_selection(f, i, len("héllo"), len("héllo"))
	clear_events(x)
	edit(f, i, .Insert_Text, "😀")
	testing.expect_value(t, value(f, i), "héllo😀")
	testing.expect_value(t, events_string(x), "beforeinput@i input@i")
	edit(f, i, .Delete_Backward)
	testing.expect_value(t, value(f, i), "héllo")
	move_caret(f, i, .Char, -1, false)
	move_caret(f, i, .Char, -1, false)
	move_caret(f, i, .Char, -1, false)
	move_caret(f, i, .Char, -1, true)
	testing.expect_value(t, selected_text(f, i), "é")
	s16, e16, _, ok := selection_utf16(f, i)
	testing.expect(t, ok && s16 == 1 && e16 == 2)
	edit(f, i, .Insert_Text, "e\nE")   // newlines are stripped in single-line fields
	testing.expect_value(t, value(f, i), "heEllo")
	edit(f, i, .History_Undo)
	testing.expect_value(t, value(f, i), "héllo")
	edit(f, i, .History_Redo)
	testing.expect_value(t, value(f, i), "heEllo")
	// word deletion
	set_value(f, i, "one two  three")
	edit(f, i, .Delete_Word_Backward)
	testing.expect_value(t, value(f, i), "one two  ")
	// beforeinput can cancel
	x.cancel["beforeinput"] = true
	edit(f, i, .Insert_Text, "zzz")
	testing.expect_value(t, value(f, i), "one two  ")
	x.cancel["beforeinput"] = false
	// change fires on commit (blur) when the value changed
	clear_events(x)
	focus(f, id(x, "ta"))
	testing.expect(t, strings.contains(events_string(x), "change@i"))
	// textarea: line breaks, line moves, CRLF normalization
	ta := id(x, "ta")
	set_selection(f, ta, 1, 1)
	move_caret(f, ta, .Line, 1, false)
	testing.expect_value(t, caret(f, ta), 4)
	edit(f, ta, .Insert_Line_Break)
	testing.expect_value(t, value(f, ta), "ab\nc\nd")
	set_value(f, ta, "x\r\ny\rz")
	testing.expect_value(t, value(f, ta), "x\ny\nz")
	// read-only refuses edits
	testing.expect(t, !edit(f, id(x, "ro"), .Insert_Text, "q"))
	// setRangeText and the selection API in UTF-16 units
	set_value(f, i, "a😀b")
	set_range_text(f, i, "XY", 1, 3, .Select)
	testing.expect_value(t, value(f, i), "aXYb")
	ss, se, _, _ := selection_utf16(f, i)
	testing.expect(t, ss == 1 && se == 3)
	testing.expect_value(t, utf16_to_byte("a😀b", 3), 5)
	testing.expect_value(t, byte_to_utf16("a😀b", 5), 3)
}

@(test)
checkbox_and_label_activation :: proc(t: ^testing.T) {
	x := fx_make(`<form id=f><label id=l>Tick <input type=checkbox id=cb></label><label for=r1 id=l2>R</label>
<input type=radio name=g id=r1><input type=radio name=g id=r2 checked><input type=checkbox id=dis disabled></form>`)
	defer fx_destroy(x)
	f := x.f
	cb := id(x, "cb")
	click(f, cb, {trusted = true})
	testing.expect(t, checked(f, cb))
	testing.expect_value(t, events_string(x), "click@cb input@cb change@cb")
	clear_events(x)
	x.cancel["click"] = true
	click(f, cb, {trusted = true})
	testing.expect(t, checked(f, cb), "a cancelled click restores the checkbox")
	testing.expect_value(t, events_string(x), "click@cb")
	x.cancel["click"] = false
	clear_events(x)
	click(f, id(x, "l"), {trusted = true})
	testing.expect(t, !checked(f, cb), "the label clicks its control")
	testing.expect_value(t, events_string(x), "click@l focus@cb focusin@cb click@cb input@cb change@cb")
	click(f, id(x, "l2"), {trusted = true})
	testing.expect(t, checked(f, id(x, "r1")) && !checked(f, id(x, "r2")))
	clear_events(x)
	click(f, id(x, "dis"), {trusted = true})
	testing.expect_value(t, events_string(x), "")
	// arrow keys move through the radio group
	focus(f, id(x, "r1"))
	key_down(f, .Down, {})
	testing.expect(t, checked(f, id(x, "r2")) && f.focus == id(x, "r2"))
}

@(test)
select_options_and_selectedness :: proc(t: ^testing.T) {
	x := fx_make(`<select id=s><option id=a disabled>A</option><option id=b value=bv> B  text </option><option id=c>C</option></select>
<select id=m multiple><option id=m1 selected>1</option><option id=m2 selected>2</option></select>
<select id=two><option id=t1 selected>1</option><option id=t2 selected>2</option></select><select id=lb size=3><option>x</option></select>`)
	defer fx_destroy(x)
	f := x.f
	s := id(x, "s")
	testing.expect_value(t, selected_index(f, s), 1)   // the first enabled option
	testing.expect_value(t, value(f, s), "bv")
	testing.expect_value(t, option_text(f, id(x, "b")), "B text")
	testing.expect_value(t, option_value(f, id(x, "c")), "C")
	set_value(f, s, "C")
	testing.expect_value(t, selected_index(f, s), 2)
	set_option_selected(f, id(x, "c"), false)
	testing.expect_value(t, selected_index(f, s), 1)   // a drop-down always has a selection
	testing.expect(t, option_selected(f, id(x, "m1")) && option_selected(f, id(x, "m2")))
	testing.expect(t, !option_selected(f, id(x, "t1")) && option_selected(f, id(x, "t2")))
	testing.expect_value(t, selected_index(f, id(x, "lb")), -1)   // a list box may have none
	focus(f, s)
	clear_events(x)
	key_down(f, .Down, {})
	testing.expect_value(t, selected_index(f, s), 2)
	testing.expect_value(t, events_string(x), "input@s change@s")
	key_down(f, .Up, {})
	key_down(f, .Up, {})
	testing.expect_value(t, selected_index(f, s), 1)   // the disabled first option is skipped
}

@(test)
pseudo_class_state :: proc(t: ^testing.T) {
	x := fx_make(`<form id=f><input id=p placeholder=hint><input id=r type=number min=1 max=5 value=9><input id=cb type=checkbox checked>
<input type=submit id=s1><input type=submit id=s2><input id=req required></form>`)
	defer fx_destroy(x)
	f := x.f
	testing.expect(t, .Placeholder_Shown in style_bits(f, id(x, "p")))
	testing.expect(t, .Out_Of_Range in style_bits(f, id(x, "r")))
	testing.expect(t, .Checked in style_bits(f, id(x, "cb")) && .Default in style_bits(f, id(x, "cb")))
	testing.expect(t, .Default in style_bits(f, id(x, "s1")) && .Default not_in style_bits(f, id(x, "s2")))
	testing.expect(t, .Invalid in style_bits(f, id(x, "f")))
	testing.expect(t, .User_Invalid not_in style_bits(f, id(x, "req")))
	submit(f, id(x, "f"), base.NIL_HANDLE)
	testing.expect(t, .User_Invalid in style_bits(f, id(x, "req")))
	before := x.style_changes
	focus(f, id(x, "p"))
	edit(f, id(x, "p"), .Insert_Text, "a")
	testing.expect(t, x.style_changes > before, "typing the first character changes :placeholder-shown")
	before = x.style_changes
	edit(f, id(x, "p"), .Insert_Text, "b")
	testing.expect_value(t, x.style_changes, before)   // nothing a pseudo-class sees changed
}

@(test)
focus_order_and_events :: proc(t: ^testing.T) {
	x := fx_make(`<input id=a><input id=b tabindex=2><input id=c tabindex=-1><input id=d type=hidden><input id=e tabindex=1><button id=f disabled>x</button><a id=g href=#>l</a>`)
	defer fx_destroy(x)
	f := x.f
	order := tab_order(f)
	ids := make([dynamic]string, context.temp_allocator)
	for h in order { v, _ := dom.get_attribute(x.doc, h, "id"); append(&ids, v) }
	testing.expect_value(t, strings.join(ids[:], ",", context.temp_allocator), "e,b,a,g")
	focus(f, id(x, "a"))
	clear_events(x)
	focus(f, id(x, "c"))
	testing.expect_value(t, events_string(x), "blur@a focusout@a focus@c focusin@c")
	testing.expect(t, !focus(f, id(x, "f")))
	testing.expect(t, focus_next(f, 1))
	testing.expect_value(t, f.focus, id(x, "e"))
}

@(test)
records_are_collected :: proc(t: ^testing.T) {
	x := fx_make(`<div id=box><input id=i></div>`)
	defer fx_destroy(x)
	f := x.f
	i := id(x, "i")
	set_value(f, i, "x")
	testing.expect_value(t, len(f.controls), 1)
	dom.remove_child(x.doc, id(x, "box"), i)
	dom.release(x.doc, i)
	collect(f)
	testing.expect_value(t, len(f.controls), 0)
}
