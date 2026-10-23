package remote

import "core:strings"
import "core:testing"

@(test)
parses_a_request :: proc(t: ^testing.T) {
	req, code, _ := parse_request(transmute([]byte)string(`{"id": 7, "method": "Page.navigate", "params": {"url": "https://a.test/", "n": 3, "on": true}}`))
	testing.expect_value(t, code, 0)
	testing.expect_value(t, req.id, "7")
	testing.expect_value(t, req.method, "Page.navigate")
	u, ok := param_string(req.params, "url")
	testing.expect(t, ok && u == "https://a.test/")
	n, _ := param_int(req.params, "n")
	testing.expect_value(t, n, 3)
	on, _ := param_bool(req.params, "on")
	testing.expect(t, on)
}

@(test)
keeps_string_ids_and_missing_params :: proc(t: ^testing.T) {
	req, code, _ := parse_request(transmute([]byte)string(`{"id":"a\"b","method":"Browser.close"}`))
	testing.expect_value(t, code, 0)
	testing.expect_value(t, req.id, `"a\"b"`)
	testing.expect_value(t, len(req.params), 0)
}

@(test)
refuses_what_is_not_a_request :: proc(t: ^testing.T) {
	_, code, _ := parse_request(transmute([]byte)string(`{"id":1`))
	testing.expect_value(t, code, ERR_PARSE)
	_, code, _ = parse_request(transmute([]byte)string(`[1,2]`))
	testing.expect_value(t, code, ERR_REQUEST)
	req, code2, _ := parse_request(transmute([]byte)string(`{"id":5,"params":{}}`))
	testing.expect_value(t, code2, ERR_REQUEST)
	testing.expect_value(t, req.id, "5")   // (the error response still names the request)
	_, code, _ = parse_request(transmute([]byte)string(`{"id":1,"method":"x","params":3}`))
	testing.expect_value(t, code, ERR_PARAMS)
}

@(test)
strings_are_escaped_and_stay_valid_json :: proc(t: ^testing.T) {
	testing.expect_value(t, quote("a\"b\\c\n\t\x01é"), "\"a\\\"b\\\\c\\n\\t\\u0001é\"")
	bad := strings.clone_from_bytes([]byte{'x', 0xff, 'y'}, context.temp_allocator)
	testing.expect_value(t, quote(bad), "\"x\ufffdy\"")
	// what was written parses back
	req, code, _ := parse_request(transmute([]byte)strings.concatenate({`{"method":`, quote("é\u2028\"\x00"), `}`}, context.temp_allocator))
	testing.expect_value(t, code, 0)
	testing.expect_value(t, req.method, "é\u2028\"\x00")
}

@(test)
responses_have_the_expected_shape :: proc(t: ^testing.T) {
	testing.expect_value(t, response_ok("3", `{"a":1}`), `{"id":3,"result":{"a":1}}`)
	testing.expect_value(t, response_ok("3", ""), `{"id":3,"result":{}}`)
	testing.expect_value(t, response_error(`"x"`, ERR_METHOD, "no such method"), `{"id":"x","error":{"code":-32601,"message":"no such method"}}`)
	testing.expect_value(t, event_line("Page.loadEventFired", `{"t":1}`), `{"event":"Page.loadEventFired","params":{"t":1}}`)
}
