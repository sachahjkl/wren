package browser

import "core:testing"
import "wb:remote"

// Encodes a masked client-to-server WebSocket frame (RFC 6455 §5.1) for unit tests.
@(private = "file")
cdp_test_client_frame :: proc(fin: bool, opcode: remote.Ws_Opcode, payload: []byte, allocator := context.temp_allocator) -> []byte {
	n := len(payload)
	head := 2
	switch {
	case n > 0xFFFF: head += 8
	case n > 125:    head += 2
	}
	out := make([]byte, head + 4 + n, allocator)
	out[0] = (fin ? u8(0x80) : u8(0)) | u8(opcode)
	switch {
	case n > 0xFFFF:
		out[1] = 0x80 | 127
		v := u64(n)
		for i in 0 ..< 8 { out[2 + i] = u8(v >> uint((7 - i) * 8)) }
	case n > 125:
		out[1] = 0x80 | 126
		out[2] = u8(n >> 8); out[3] = u8(n)
	case:
		out[1] = 0x80 | u8(n)
	}
	mask := [4]byte{0x37, 0xFA, 0x21, 0x3D}
	copy(out[head:head + 4], mask[:])
	for i in 0 ..< n { out[head + 4 + i] = payload[i] ~ mask[i & 3] }
	return out
}

// Loopback Host/Origin guard: allows IPv4, localhost, and bracketed/bare IPv6 loopback, and blocks DNS rebinding on both
// WebSocket upgrades and /json HTTP routes.
@(test)
cdp_origin_guard_allows_loopback_ipv4_ipv6_and_blocks_rebinding :: proc(t: ^testing.T) {
	good := [?][2]string{
		{"127.0.0.1:9222", ""},
		{"127.0.0.1", "http://127.0.0.1:9222"},
		{"localhost:9222", "http://localhost:3000"},
		{"LOCALHOST:9222", "http://LOCALHOST"},
		{"[::1]", ""},
		{"[::1]:9222", ""},
		{"[::1]:9222", "http://[::1]:9222"},
		{"[::1]", "https://[::1]/page"},
		{"::1", ""},
	}
	for c in good {
		testing.expectf(t, cdp_origin_ok(c[0], c[1]), "expected allowed host=%q origin=%q", c[0], c[1])
	}

	bad := [?][2]string{
		{"evil.com:9222", ""},
		{"127.0.0.1:9222", "http://evil.com"},
		{"127.0.0.1:9222", "null"},
		{"127.0.0.1.evil.com:9222", ""},
		{"http://127.0.0.1@evil.com", ""},
		{"[::1]@evil.com", ""},
		{"[::1]extra", ""},
		{"[::1]:abc", ""},
		{"[::1]:", ""},
		{"[::1", ""},
		{"[::2]:9222", ""},
		{"127.0.0.1:", ""},
		{"127.0.0.1:9222:extra", ""},
	}
	for c in bad {
		testing.expectf(t, !cdp_origin_ok(c[0], c[1]), "expected rejected host=%q origin=%q", c[0], c[1])
	}

	// Plain HTTP /json routes must be rejected before touching app state when Host or Origin is non-loopback.
	for req in ([]string{
		"GET /json HTTP/1.1\r\nHost: evil.com:9222\r\n\r\n",
		"GET /json/list HTTP/1.1\r\nHost: 127.0.0.1:9222\r\nOrigin: http://evil.com\r\n\r\n",
		"GET /json/new?https://evil.com HTTP/1.1\r\nHost: evil.com:9222\r\n\r\n",
		"GET /json/close/1 HTTP/1.1\r\nHost: 127.0.0.1:9222\r\nOrigin: https://attacker.example\r\n\r\n",
		"GET /json/activate/1 HTTP/1.1\r\nHost: evil.com:9222\r\n\r\n",
	}) {
		cl := Cdp_Client{tcp_id = 1}
		defer delete(cl.inbuf)
		defer delete(cl.frag_buf)
		append(&cl.inbuf, ..transmute([]byte)req)
		cdp_try_handshake(nil, &cl)
		testing.expect(t, !cl.upgraded, "rejected HTTP route must not upgrade")
		testing.expect_value(t, len(cl.inbuf), 0)
	}
}

// Buffer cap prevents unbounded growth; fragmented WebSocket text frames reassemble cleanly while protocol violations close with 1002.
@(test)
cdp_inbuf_cap_and_fragmented_frames :: proc(t: ^testing.T) {
	// Cap check: appending past CDP_MAX_INBUF fails and clears inbuf.
	{
		cl := Cdp_Client{}
		defer delete(cl.inbuf)
		chunk := make([]byte, CDP_MAX_INBUF, context.temp_allocator)
		testing.expect(t, cdp_append_inbuf(&cl, chunk), "exact cap fits")
		testing.expect_value(t, len(cl.inbuf), CDP_MAX_INBUF)
		extra := [1]byte{'x'}
		testing.expect(t, !cdp_append_inbuf(&cl, extra[:]), "one byte past cap is rejected")
		testing.expect_value(t, len(cl.inbuf), 0)
	}

	// Unsolicited Continuation frame is a protocol error (1002).
	{
		cl := Cdp_Client{upgraded = true}
		defer delete(cl.inbuf)
		defer delete(cl.frag_buf)
		append(&cl.inbuf, ..cdp_test_client_frame(true, .Continuation, transmute([]byte)string("stray")))
		testing.expect_value(t, cdp_drain_frames(nil, &cl), u16(1002))
		testing.expect_value(t, len(cl.inbuf), 0)
	}

	// Starting a new Text frame before a fragmented message ends is a protocol error (1002).
	{
		cl := Cdp_Client{upgraded = true}
		defer delete(cl.inbuf)
		defer delete(cl.frag_buf)
		append(&cl.inbuf, ..cdp_test_client_frame(false, .Text, transmute([]byte)string(`{"id":1,`)))
		append(&cl.inbuf, ..cdp_test_client_frame(true, .Text, transmute([]byte)string(`{}`)))
		testing.expect_value(t, cdp_drain_frames(nil, &cl), u16(1002))
		testing.expect(t, !cl.frag_active)
	}

	// Fragmented control frame is a protocol error (1002).
	{
		cl := Cdp_Client{upgraded = true}
		defer delete(cl.inbuf)
		defer delete(cl.frag_buf)
		append(&cl.inbuf, ..cdp_test_client_frame(false, .Ping, transmute([]byte)string("hi")))
		testing.expect_value(t, cdp_drain_frames(nil, &cl), u16(1002))
	}

	// Valid fragmented Text message with an interleaved Pong reassembles and dispatches Target.setAutoAttach.
	{
		cl := Cdp_Client{upgraded = true}
		defer delete(cl.inbuf)
		defer delete(cl.frag_buf)
		append(&cl.inbuf, ..cdp_test_client_frame(false, .Text, transmute([]byte)string(`{"id":1,"method":"Target.`)))
		append(&cl.inbuf, ..cdp_test_client_frame(true, .Pong, nil))
		append(&cl.inbuf, ..cdp_test_client_frame(false, .Continuation, transmute([]byte)string(`setAutoAttach",`)))
		append(&cl.inbuf, ..cdp_test_client_frame(true, .Continuation, transmute([]byte)string(`"params":{"autoAttach":true}}`)))
		testing.expect_value(t, cdp_drain_frames(nil, &cl), u16(0))
		testing.expect(t, cl.auto_attach, "reassembled fragmented CDP message was dispatched")
		testing.expect(t, !cl.frag_active)
		testing.expect_value(t, len(cl.inbuf), 0)
		testing.expect_value(t, len(cl.frag_buf), 0)
	}
}

// DevTools Network media preview sanitizes untrusted URL extensions and never touches disk off Windows.
@(test)
net_media_extension_is_sanitized :: proc(t: ^testing.T) {
	testing.expect_value(t, net_media_safe_ext("audio/mpeg", "http://a/x.foo"), ".mp3")
	testing.expect_value(t, net_media_safe_ext("audio/wav; charset=utf-8", "http://a/x"), ".wav")
	testing.expect_value(t, net_media_safe_ext("", "http://a/sound.aac?v=1"), ".aac")
	testing.expect_value(t, net_media_safe_ext("", "http://a/sound.MP3#t=2"), ".MP3")
	for bad_url in ([]string{
		`http://evil.example/x." alias evil; play "`,
		`http://evil.example/x.mp3\..\evil`,
		`http://evil.example/x.a\b`,
		"http://evil.example/x.123456789",
		"http://evil.example/x.",
		"http://evil.example/x.a b",
		"http://evil.example/x.a\nb",
		"http://evil.example/noext",
	}) {
		testing.expectf(t, net_media_safe_ext("", bad_url) == ".bin", "expected .bin for %q, got %q", bad_url, net_media_safe_ext("", bad_url))
	}

	when ODIN_OS != .Windows {
		app := app_make()
		defer {
			net_media_release(app)
			app_free(app)
		}
		entry := Net_Entry{id = 42, mime = "audio/mpeg", url = "http://evil.example/a.mp3"}
		append(&entry.body, ..transmute([]byte)string("not mp4 or webm"))
		defer delete(entry.body)
		net_media_open(app, &entry)
		testing.expect_value(t, app.net_media.mode, Media_Mode.None)
		testing.expect_value(t, app.net_media.path, "")
		testing.expect(t, !app.net_media.loading)
		testing.expect(t, app.net_media.err != "")
	}
}
