package fetch

import "core:testing"
import "wb:csp"
import "wb:http"
import "wb:url"

@(test)
websocket_url_rules :: proc(t: ^testing.T) {
	doc, _ := url.parse_absolute("https://example.com/app/page.html", context.temp_allocator)
	cases := []struct { input, want: string, ok: bool }{
		{"ws://example.com/chat", "ws://example.com/chat", true},
		{"wss://example.com:8443/x?y=1", "wss://example.com:8443/x?y=1", true},
		{"http://example.com/a", "ws://example.com/a", true},
		{"https://example.com/a", "wss://example.com/a", true},
		{"/relative", "wss://example.com/relative", true},   // resolved against an https document, then mapped
		{"ws://example.com/#frag", "", false},
		{"ws://example.com/#", "", false},                   // an empty fragment is a fragment
		{"ftp://example.com/", "", false},
		{"data:text/plain,x", "", false},
		{"ws://[", "", false},
	}
	for c in cases {
		u, ok := websocket_parse_url(c.input, &doc, context.temp_allocator)
		testing.expect_value(t, ok, c.ok)
		if ok { testing.expect_value(t, u.href, c.want) }
	}
}

@(test)
websocket_protocol_rules :: proc(t: ^testing.T) {
	testing.expect(t, websocket_protocols_valid({}))
	testing.expect(t, websocket_protocols_valid({"chat", "superchat.v2"}))
	testing.expect(t, !websocket_protocols_valid({"chat", "chat"}), "duplicates")
	testing.expect(t, websocket_protocols_valid({"chat", "Chat"}), "case-sensitive")
	testing.expect(t, !websocket_protocols_valid({""}), "empty")
	testing.expect(t, !websocket_protocols_valid({"a b"}), "space")
	testing.expect(t, !websocket_protocols_valid({"a,b"}), "comma")
	testing.expect(t, !websocket_protocols_valid({"é"}), "non-ASCII")
	testing.expect_value(t, len(websocket_split_protocols("")), 0)
	testing.expect_value(t, len(websocket_split_protocols("a,b")), 2)
	testing.expect(t, !websocket_protocols_valid(websocket_split_protocols("a,,b")), "an empty item")
}

@(test)
websocket_close_rules :: proc(t: ^testing.T) {
	testing.expect_value(t, websocket_close_check(0, false, ""), Close_Check.Ok)
	testing.expect_value(t, websocket_close_check(1000, true, "bye"), Close_Check.Ok)
	testing.expect_value(t, websocket_close_check(3000, true, ""), Close_Check.Ok)
	testing.expect_value(t, websocket_close_check(4999, true, ""), Close_Check.Ok)
	for code in ([]int{0, 999, 1001, 1005, 1006, 1015, 2999, 5000, 65536}) {
		testing.expect_value(t, websocket_close_check(code, true, ""), Close_Check.Invalid_Access)
	}
	reason := make([]u8, 124, context.temp_allocator)
	for &c in reason { c = 'r' }
	testing.expect_value(t, websocket_close_check(1000, true, string(reason[:123])), Close_Check.Ok)
	testing.expect_value(t, websocket_close_check(1000, true, string(reason)), Close_Check.Syntax)
	// 41 three-byte characters = 123 bytes fit, 42 do not: the limit is in bytes
	euro := "€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€€"
	testing.expect_value(t, websocket_close_check(1000, true, euro[:123]), Close_Check.Ok)
	testing.expect_value(t, websocket_close_check(1000, true, euro), Close_Check.Syntax)
	// the code is checked before the reason (InvalidAccessError wins)
	testing.expect_value(t, websocket_close_check(1, true, string(reason)), Close_Check.Invalid_Access)
}

@(test)
websocket_handshake_rules :: proc(t: ^testing.T) {
	h := http.parse_header_block("Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Protocol: chat\r\n", context.temp_allocator)
	v := check_websocket_handshake(101, h, {"x", "chat"})
	testing.expect(t, v.ok)
	testing.expect_value(t, v.protocol, "chat")
	testing.expect(t, !check_websocket_handshake(101, h, {"x"}).ok, "a protocol we did not offer")
	testing.expect(t, !check_websocket_handshake(101, h, {}).ok, "a protocol when none was offered")
	testing.expect(t, !check_websocket_handshake(200, h, {"chat"}).ok, "not 101")
	testing.expect(t, !check_websocket_handshake(302, http.headers_make(context.temp_allocator), {}).ok, "redirects are not followed")
	none := http.parse_header_block("Upgrade: websocket\r\n", context.temp_allocator)
	v = check_websocket_handshake(101, none, {"chat"})
	testing.expect(t, v.ok && v.protocol == "", "the server may decline every protocol")
	deflate := http.parse_header_block("Sec-WebSocket-Extensions: permessage-deflate\r\n", context.temp_allocator)
	testing.expect(t, !check_websocket_handshake(101, deflate, {}).ok, "an extension that was not offered")
}

@(private = "file")
policy :: proc(l: ^Loader, env: ^Environment, target: string) -> (Error_Kind, string) {
	u, _ := url.parse_absolute(target)
	defer url.destroy(&u)
	e, _ := websocket_policy_check(l, env, &u)
	return e, u.href
}

@(test)
websocket_policy_rules :: proc(t: ^testing.T) {
	prof := profile_make()
	defer profile_destroy(&prof)
	l := Loader{profile = &prof}

	plain_u, _ := url.parse_absolute("http://example.com/p", context.temp_allocator)
	plain := environment_make(plain_u)
	defer environment_destroy(&plain)
	secure_u, _ := url.parse_absolute("https://example.com/p", context.temp_allocator)
	secure := environment_make(secure_u)
	defer environment_destroy(&secure)

	e, href := policy(&l, &plain, "ws://example.com/x")
	testing.expect_value(t, e, Error_Kind.None)
	testing.expect_value(t, href, "ws://example.com/x")
	e, _ = policy(&l, &secure, "ws://other.example/x")
	testing.expect_value(t, e, Error_Kind.Blocked_Mixed_Content)
	e, _ = policy(&l, &secure, "ws://127.0.0.1:8765/x")
	testing.expect_value(t, e, Error_Kind.None)   // loopback is potentially trustworthy
	e, _ = policy(&l, &secure, "wss://other.example/x")
	testing.expect_value(t, e, Error_Kind.None)
	e, _ = policy(&l, &plain, "ws://example.com:25/x")
	testing.expect_value(t, e, Error_Kind.Bad_Port)
	e, _ = policy(&l, nil, "ws://example.com:6000/")
	testing.expect_value(t, e, Error_Kind.Bad_Port)

	// HSTS upgrades ws to wss before the mixed-content check
	hsts_note(&prof.hsts, "secure.example", "max-age=600", now_ms())
	e, href = policy(&l, &secure, "ws://secure.example/x")
	testing.expect_value(t, e, Error_Kind.None)
	testing.expect_value(t, href, "wss://secure.example/x")

	// CSP connect-src: 'self' covers ws(s) of the same host, other hosts must be listed
	csp.parse_header(&plain.policies, "connect-src 'self' wss://listed.example", .Enforce)
	e, _ = policy(&l, &plain, "ws://example.com/x")
	testing.expect_value(t, e, Error_Kind.None)
	e, _ = policy(&l, &plain, "wss://example.com/x")
	testing.expect_value(t, e, Error_Kind.None)
	e, _ = policy(&l, &plain, "wss://listed.example/x")
	testing.expect_value(t, e, Error_Kind.None)
	e, _ = policy(&l, &plain, "ws://evil.example/x")
	testing.expect_value(t, e, Error_Kind.Blocked_Csp)

	up_u, _ := url.parse_absolute("https://example.com/p", context.temp_allocator)
	up := environment_make(up_u)
	defer environment_destroy(&up)
	csp.parse_header(&up.policies, "upgrade-insecure-requests", .Enforce)
	e, href = policy(&l, &up, "ws://insecure.example/x")
	testing.expect_value(t, e, Error_Kind.None)
	testing.expect_value(t, href, "wss://insecure.example/x")

	prof.settings.block_active_mixed = false
	e, _ = policy(&l, &secure, "ws://other.example/x")
	testing.expect_value(t, e, Error_Kind.None)   // the administrator's choice
}
