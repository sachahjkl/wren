package vault

import "core:strings"
import "core:testing"

@(private = "file")
body_of :: proc(frame: []u8) -> string { return string(frame[FRAME_HEAD:]) }

@(test)
a_request_is_one_frame_with_its_length :: proc(t: ^testing.T) {
	r: Request
	request_begin(&r, 7, .Login, 64)
	request_string(&r, "email", "a@b.c")
	request_string(&r, "password", "p\"w\\\n\x01")
	frame, ok := request_end(&r)
	defer frame_free(frame)
	testing.expect(t, ok)
	n, n_ok := frame_length({frame[0], frame[1], frame[2], frame[3]})
	testing.expect(t, n_ok)
	testing.expect_value(t, n, len(frame) - FRAME_HEAD)
	testing.expect_value(t, body_of(frame), `{"id":7,"op":"login","email":"a@b.c","password":"p\"w\\\u000a\u0001"}`)
}

@(test)
lists_ints_and_bools_are_written :: proc(t: ^testing.T) {
	r: Request
	request_begin(&r, 1, .Hello, 32)
	request_int(&r, "protocol", 1)
	request_bool(&r, "persist", false)
	request_list(&r, "fields", {"username", "password"})
	frame, ok := request_end(&r)
	defer frame_free(frame)
	testing.expect(t, ok)
	testing.expect_value(t, body_of(frame), `{"id":1,"op":"hello","protocol":1,"persist":false,"fields":["username","password"]}`)
}

@(test)
a_request_larger_than_its_reservation_is_refused :: proc(t: ^testing.T) {
	// (a buffer that grows leaves copies in freed memory: the request is dropped instead)
	r: Request
	request_begin(&r, 1, .Login, 1)
	request_string(&r, "password", strings.repeat("x", 4096, context.temp_allocator))
	frame, ok := request_end(&r)
	testing.expect(t, !ok)
	testing.expect(t, frame == nil)
}

@(test)
frame_lengths_are_bounded :: proc(t: ^testing.T) {
	_, ok0 := frame_length({0, 0, 0, 0})
	testing.expect(t, !ok0)
	n, ok1 := frame_length({0, 0, 0x10, 0})
	testing.expect(t, ok1)
	testing.expect_value(t, n, MAX_FRAME)
	_, ok2 := frame_length({1, 0, 0x10, 0})
	testing.expect(t, !ok2)
}

@(test)
answers_decode_into_owned_values :: proc(t: ^testing.T) {
	src := `{"id":3,"ok":true,"rows":[{"id":"a","name":"Site","username":"me","uri":"https://x.example","match":"host","has_totp":true},{"name":"no id"}]}`
	a, ok := answer_decode(transmute([]u8)src)
	defer answer_free(a)
	testing.expect(t, ok)
	testing.expect_value(t, a.id, 3)
	testing.expect(t, a.ok)
	testing.expect_value(t, len(a.rows), 1)   // (a row without an id is dropped)
	testing.expect_value(t, a.rows[0].match, Match_Kind.Host)
	testing.expect_value(t, a.rows[0].kind, Item_Kind.Login)   // (no kind: a login)
	testing.expect(t, a.rows[0].has_totp)
	testing.expect_value(t, a.rows[0].username, "me")
}

@(test)
fill_and_error_answers_decode :: proc(t: ^testing.T) {
	a, ok := answer_decode(transmute([]u8)string(`{"id":9,"ok":true,"username":"u","password":"s3cret"}`))
	defer answer_free(a)
	testing.expect(t, ok)
	testing.expect(t, Fill_Fields{.Username, .Password} <= a.has)
	testing.expect_value(t, a.values[.Password], "s3cret")
	e, ok2 := answer_decode(transmute([]u8)string(`{"id":2,"ok":false,"error":"bad_password","message":"The master password is wrong."}`))
	defer answer_free(e)
	testing.expect(t, ok2)
	testing.expect(t, !e.ok)
	testing.expect_value(t, e.error, "bad_password")
}

@(test)
login_steps_pins_and_events_decode :: proc(t: ^testing.T) {
	a, ok := answer_decode(transmute([]u8)string(`{"id":4,"ok":true,"result":"need_two_factor","providers":["email","duo","authenticator"],"email_sent":true}`))
	defer answer_free(a)
	testing.expect(t, ok)
	testing.expect_value(t, a.result, Login_Result.Need_Two_Factor)
	testing.expect_value(t, a.factors, Factors{.Authenticator, .Email})   // (an unknown provider is left out)
	testing.expect(t, a.email_sent)
	d, ok2 := answer_decode(transmute([]u8)string(`{"id":5,"ok":true,"result":"need_device_code"}`))
	defer answer_free(d)
	testing.expect(t, ok2)
	testing.expect_value(t, d.result, Login_Result.Need_Device_Code)
	p, ok3 := answer_decode(transmute([]u8)string(`{"id":6,"ok":false,"error":"bad_pin","message":"The PIN is wrong. 3 tries left.","tries_left":3}`))
	defer answer_free(p)
	testing.expect(t, ok3)
	testing.expect_value(t, p.tries_left, 3)
	h, ok4 := answer_decode(transmute([]u8)string(`{"id":1,"ok":true,"account":"locked","email":"a@b.c","pin":true,"login":"api_key"}`))
	defer answer_free(h)
	testing.expect(t, ok4)
	testing.expect(t, h.pin)
	e, ok5 := answer_decode(transmute([]u8)string(`{"id":0,"ok":true,"event":"locked"}`))
	defer answer_free(e)
	testing.expect(t, ok5)
	testing.expect_value(t, e.id, 0)
	testing.expect_value(t, e.event, "locked")
}

@(test)
the_new_requests_are_written :: proc(t: ^testing.T) {
	r: Request
	request_begin(&r, 3, .Login, 64)
	request_string(&r, "email", "a@b.c")
	request_string(&r, "provider", "email")
	request_bool(&r, "resend", true)
	frame, ok := request_end(&r)
	defer frame_free(frame)
	testing.expect(t, ok)
	testing.expect_value(t, body_of(frame), `{"id":3,"op":"login","email":"a@b.c","provider":"email","resend":true}`)
	k: Request
	request_begin(&k, 4, .Keepalive, 0)
	kf, k_ok := request_end(&k)
	defer frame_free(kf)
	testing.expect(t, k_ok)
	testing.expect_value(t, body_of(kf), `{"id":4,"op":"keepalive"}`)
}

@(test)
what_is_not_an_answer_is_refused :: proc(t: ^testing.T) {
	for src in ([]string{`not json`, `[1,2]`, `{"ok":true}`, `{"id":-1,"ok":true}`, `{"id":1}`}) {
		a, ok := answer_decode(transmute([]u8)src)
		testing.expect(t, !ok, src)
		testing.expect(t, a == nil, src)
	}
}

@(test)
codes_searches_and_equivalent_domains_decode :: proc(t: ^testing.T) {
	a, ok := answer_decode(transmute([]u8)string(`{"id":3,"ok":true,"totp":"123456","period":30,"remaining":7}`))
	defer answer_free(a)
	testing.expect(t, ok)
	testing.expect(t, .Totp in a.has)
	testing.expect_value(t, a.values[.Totp], "123456")
	testing.expect_value(t, a.remaining, 7)
	src := `{"id":4,"ok":true,"equivalent":["google.com",""],"rows":[` +
		`{"id":"a","name":"A","username":"u","uri":"https://a.example","match":"starts_with"},` +
		`{"id":"b","name":"B","username":"u","uri":"https://b.example","match":"something_new"},` +
		`{"id":"c","name":"C","username":"u","uri":"https://c.example"}]}`
	r, ok2 := answer_decode(transmute([]u8)src)
	defer answer_free(r)
	testing.expect(t, ok2)
	testing.expect_value(t, len(r.equivalent), 1)   // (an empty domain is left out)
	testing.expect_value(t, len(r.rows), 2)   // (an unknown rule is no rule Wren can check)
	testing.expect_value(t, r.rows[0].match, Match_Kind.Starts_With)
	testing.expect_value(t, r.rows[1].id, "c")   // (a search row has no match type)
}

// Protocol 4: a device's approval that is still pending, the fingerprint phrase, the passkey's options, and the hello's
// passkey mark.
@(test)
device_and_passkey_answers_decode :: proc(t: ^testing.T) {
	p, ok := answer_decode(transmute([]u8)string(`{"id":2,"ok":true,"result":"pending"}`))
	defer answer_free(p)
	testing.expect(t, ok)
	testing.expect_value(t, p.result, Login_Result.Pending)
	f, ok2 := answer_decode(transmute([]u8)string(`{"id":3,"ok":true,"fingerprint":"alpha-bravo-charlie-delta-echo"}`))
	defer answer_free(f)
	testing.expect(t, ok2)
	testing.expect_value(t, f.fingerprint, "alpha-bravo-charlie-delta-echo")
	o, ok3 := answer_decode(transmute([]u8)string(`{"id":4,"ok":true,"options":"{\"challenge\":\"Y2g\"}"}`))
	defer answer_free(o)
	testing.expect(t, ok3)
	testing.expect_value(t, o.options, `{"challenge":"Y2g"}`)
	h, ok4 := answer_decode(transmute([]u8)string(`{"id":1,"ok":true,"account":"locked","email":"a@b.c","pin":false,"passkey":true}`))
	defer answer_free(h)
	testing.expect(t, ok4)
	testing.expect(t, h.passkey)
}

@(test)
search_and_totp_requests_are_written :: proc(t: ^testing.T) {
	r: Request
	request_begin(&r, 5, .Search, 96)
	request_search(&r, "git hub", 100, 9999, {.Card, .Identity})
	frame, ok := request_end(&r)
	defer frame_free(frame)
	testing.expect(t, ok)
	// (the limit is the helper's bound at most)
	testing.expect_value(t, body_of(frame), `{"id":5,"op":"search","query":"git hub","offset":100,"limit":500,"kinds":["card","identity"]}`)
	c, c_ok := answer_decode(transmute([]u8)string(`{"id":5,"ok":true,"rows":[],"total":1234}`))
	defer answer_free(c)
	testing.expect(t, c_ok)
	testing.expect_value(t, c.total, 1234)
	n, n_ok := answer_decode(transmute([]u8)string(`{"id":5,"ok":true,"rows":[]}`))
	defer answer_free(n)
	testing.expect(t, n_ok)
	testing.expect_value(t, n.total, -1)   // (not said)
	k: Request
	request_begin(&k, 6, .Totp, 8)
	request_string(&k, "item", "x")
	kf, k_ok := request_end(&k)
	defer frame_free(kf)
	testing.expect(t, k_ok)
	testing.expect_value(t, body_of(kf), `{"id":6,"op":"totp","item":"x"}`)
}

// Protocol 5: the kinds of the rows, a card's and an identity's fill, the answers of save and generate.
@(test)
kinds_and_card_fields_decode :: proc(t: ^testing.T) {
	src := `{"id":2,"ok":true,"rows":[` +
		`{"id":"c","kind":"card","name":"Visa","username":"Visa *1111","uri":"","has_totp":false},` +
		`{"id":"i","kind":"identity","name":"Me","username":"Ada Lovelace","uri":""},` +
		`{"id":"n","kind":"secure_note","name":"Note","username":"","uri":""}]}`
	a, ok := answer_decode(transmute([]u8)src)
	defer answer_free(a)
	testing.expect(t, ok)
	testing.expect_value(t, len(a.rows), 2)   // (a kind this version does not know is dropped)
	testing.expect_value(t, a.rows[0].kind, Item_Kind.Card)
	testing.expect_value(t, a.rows[1].kind, Item_Kind.Identity)
	f, ok2 := answer_decode(transmute([]u8)string(`{"id":3,"ok":true,"number":"4111","exp_month":"7","exp_year":"2031","code":"123","full_name":"Ada Lovelace"}`))
	defer answer_free(f)
	testing.expect(t, ok2)
	testing.expect_value(t, f.has, Fill_Fields{.Number, .Exp_Month, .Exp_Year, .Code, .Full_Name})
	testing.expect_value(t, f.values[.Exp_Year], "2031")
	g, ok3 := answer_decode(transmute([]u8)string(`{"id":4,"ok":true,"value":"x-y-z"}`))
	defer answer_free(g)
	testing.expect(t, ok3)
	testing.expect_value(t, g.value, "x-y-z")
	sv, ok4 := answer_decode(transmute([]u8)string(`{"id":5,"ok":true,"item":"abc"}`))
	defer answer_free(sv)
	testing.expect(t, ok4)
	testing.expect_value(t, sv.item, "abc")
}

@(test)
save_and_generate_requests_are_written :: proc(t: ^testing.T) {
	r: Request
	request_begin(&r, 7, .Save, 64)
	request_string(&r, "item", "")
	request_string(&r, "name", "example.com")
	request_string(&r, "password", "pw")
	frame, ok := request_end(&r)
	defer frame_free(frame)
	testing.expect(t, ok)
	testing.expect_value(t, body_of(frame), `{"id":7,"op":"save","item":"","name":"example.com","password":"pw"}`)
	g: Request
	request_begin(&g, 8, .Generate, 32)
	request_string(&g, "kind", "passphrase")
	request_int(&g, "words", 5)
	gf, g_ok := request_end(&g)
	defer frame_free(gf)
	testing.expect(t, g_ok)
	testing.expect_value(t, body_of(gf), `{"id":8,"op":"generate","kind":"passphrase","words":5}`)
}
