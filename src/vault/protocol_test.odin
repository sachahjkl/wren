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
	testing.expect_value(t, a.rows[0].kind, Match_Kind.Host)
	testing.expect(t, a.rows[0].has_totp)
	testing.expect_value(t, a.rows[0].username, "me")
}

@(test)
fill_and_error_answers_decode :: proc(t: ^testing.T) {
	a, ok := answer_decode(transmute([]u8)string(`{"id":9,"ok":true,"username":"u","password":"s3cret"}`))
	defer answer_free(a)
	testing.expect(t, ok)
	testing.expect(t, a.has_username && a.has_password)
	testing.expect_value(t, a.password, "s3cret")
	e, ok2 := answer_decode(transmute([]u8)string(`{"id":2,"ok":false,"error":"bad_password","message":"The master password is wrong."}`))
	defer answer_free(e)
	testing.expect(t, ok2)
	testing.expect(t, !e.ok)
	testing.expect_value(t, e.error, "bad_password")
}

@(test)
what_is_not_an_answer_is_refused :: proc(t: ^testing.T) {
	for src in ([]string{`not json`, `[1,2]`, `{"ok":true}`, `{"id":-1,"ok":true}`, `{"id":1}`}) {
		a, ok := answer_decode(transmute([]u8)src)
		testing.expect(t, !ok, src)
		testing.expect(t, a == nil, src)
	}
}
