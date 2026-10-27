package remote

// WebSocket (RFC 6455) framing and the opening handshake, as pure functions over byte buffers: the transport
// (tcp_server_windows.odin) reads and writes bytes; this turns an HTTP upgrade request into its response and decodes /
// encodes the frames a WebSocket carries. A CDP or WebDriver BiDi adapter (src/browser/cdp.odin) speaks text frames of
// JSON over it, the same JSON-lines protocol the pipe carries, so one command engine serves both. Nothing here touches
// the network or allocates a server: it is data in, data out.

import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:strings"

WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"   // RFC 6455 §1.3

// A parsed opening handshake (an HTTP/1.1 GET upgrading to WebSocket). `complete` is false until the blank line that
// ends the headers has arrived.
Ws_Handshake :: struct {
	complete:   bool,
	ok:         bool,       // a well-formed WebSocket upgrade (method GET, Upgrade: websocket, a key)
	path:       string,     // the request target (into the buffer)
	key:        string,     // Sec-WebSocket-Key (into the buffer)
	origin:     string,     // Origin header, "" when absent (into the buffer)
	host:       string,     // Host header (into the buffer)
	header_end: int,        // bytes the headers take (the body, if any, follows): 0 until complete
}

// Parses the start of an HTTP request. Slices point into `buf`; valid while it is. `complete` false: read more bytes.
ws_parse_handshake :: proc(buf: []byte) -> (h: Ws_Handshake) {
	s := string(buf)
	end := strings.index(s, "\r\n\r\n")
	if end < 0 { return }
	h.complete = true
	h.header_end = end + 4
	head := s[:end]
	// request line: METHOD SP target SP HTTP/1.1
	nl := strings.index(head, "\r\n")
	line := nl < 0 ? head : head[:nl]
	parts := strings.fields(line, context.temp_allocator)
	if len(parts) < 2 || parts[0] != "GET" { return }
	h.path = parts[1]
	upgrade_ws, has_upgrade := false, false
	rest := nl < 0 ? "" : head[nl + 2:]
	for len(rest) > 0 {
		e := strings.index(rest, "\r\n")
		hl := e < 0 ? rest : rest[:e]
		rest = e < 0 ? "" : rest[e + 2:]
		colon := strings.index(hl, ":")
		if colon < 0 { continue }
		name := strings.trim_space(hl[:colon])
		value := strings.trim_space(hl[colon + 1:])
		switch {
		case ascii_equal_fold(name, "sec-websocket-key"):     h.key = value
		case ascii_equal_fold(name, "origin"):                h.origin = value
		case ascii_equal_fold(name, "host"):                  h.host = value
		case ascii_equal_fold(name, "upgrade"):               upgrade_ws = ascii_contains_fold(value, "websocket")
		case ascii_equal_fold(name, "connection"):            has_upgrade = ascii_contains_fold(value, "upgrade")
		}
	}
	h.ok = upgrade_ws && has_upgrade && h.key != ""
	return
}

// The 101 Switching Protocols response for a handshake with key `key` (Sec-WebSocket-Accept = base64(sha1(key+GUID))).
ws_accept_response :: proc(key: string, allocator := context.temp_allocator) -> string {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)key)
	sha1.update(&ctx, transmute([]byte)string(WS_GUID))
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	accept, _ := base64.encode(digest[:], allocator = context.temp_allocator)
	return strings.concatenate({
		"HTTP/1.1 101 Switching Protocols\r\n",
		"Upgrade: websocket\r\n",
		"Connection: Upgrade\r\n",
		"Sec-WebSocket-Accept: ", accept, "\r\n\r\n",
	}, allocator)
}

////////////////////////////////
// Frames

Ws_Opcode :: enum u8 { Continuation = 0x0, Text = 0x1, Binary = 0x2, Close = 0x8, Ping = 0x9, Pong = 0xA }

Ws_Frame :: struct {
	fin:     bool,
	opcode:  Ws_Opcode,
	payload: []byte,   // into the input buffer (unmasked in place when a mask was set)
}

// Decodes one frame at the start of `buf`. `got` is false (read more) until a whole frame is there; `consumed` is the
// bytes it took. A client-to-server frame must be masked (RFC 6455 §5.1); `bad` is set when it is not, or the header is
// malformed, so the server can close with 1002. The payload is unmasked in place (into `buf`).
ws_decode_frame :: proc(buf: []byte) -> (f: Ws_Frame, consumed: int, got: bool, bad: bool) {
	if len(buf) < 2 { return }
	b0, b1 := buf[0], buf[1]
	f.fin = b0 & 0x80 != 0
	f.opcode = Ws_Opcode(b0 & 0x0F)
	masked := b1 & 0x80 != 0
	n := int(b1 & 0x7F)
	off := 2
	switch n {
	case 126:
		if len(buf) < off + 2 { return }
		n = int(buf[off]) << 8 | int(buf[off + 1])
		off += 2
	case 127:
		if len(buf) < off + 8 { return }
		v := u64(0)
		for i in 0 ..< 8 { v = v << 8 | u64(buf[off + i]) }
		off += 8
		if v > 1 << 31 { f, bad = {}, true; return }   // a frame larger than the limit: refused by the caller anyway
		n = int(v)
	}
	if !masked { f, bad = {}, true; return }   // a client must mask
	if len(buf) < off + 4 + n { return }
	mask := buf[off:off + 4]
	off += 4
	payload := buf[off:off + n]
	for i in 0 ..< n { payload[i] ~= mask[i & 3] }
	f.payload = payload
	return f, off + n, true, false
}

// Encodes a server-to-client frame (never masked). The bytes are the caller's (allocated with `allocator`).
ws_encode_frame :: proc(opcode: Ws_Opcode, payload: []byte, allocator := context.allocator) -> []byte {
	n := len(payload)
	head := 2
	switch {
	case n > 0xFFFF: head += 8
	case n > 125:    head += 2
	}
	out := make([]byte, head + n, allocator)
	out[0] = 0x80 | u8(opcode)   // FIN
	switch {
	case n > 0xFFFF:
		out[1] = 127
		v := u64(n)
		for i in 0 ..< 8 { out[2 + i] = u8(v >> uint((7 - i) * 8)) }
	case n > 125:
		out[1] = 126
		out[2] = u8(n >> 8); out[3] = u8(n)
	case:
		out[1] = u8(n)
	}
	copy(out[head:], payload)
	return out
}

// A text frame of `s` (the common case: JSON), the caller's bytes.
ws_text_frame :: proc(s: string, allocator := context.allocator) -> []byte {
	return ws_encode_frame(.Text, transmute([]byte)s, allocator)
}

// A Close frame with status `code` (1000 normal, 1002 protocol error...). The caller's bytes.
ws_close_frame :: proc(code: u16, allocator := context.allocator) -> []byte {
	body := [2]byte{u8(code >> 8), u8(code)}
	return ws_encode_frame(.Close, body[:], allocator)
}

////////////////////////////////
// ASCII helpers (header names and tokens are ASCII; case-insensitive comparisons)

ascii_equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		if ascii_lower(a[i]) != ascii_lower(b[i]) { return false }
	}
	return true
}

ascii_contains_fold :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 { return true }
	if len(haystack) < len(needle) { return false }
	for i in 0 ..= len(haystack) - len(needle) {
		match := true
		for j in 0 ..< len(needle) {
			if ascii_lower(haystack[i + j]) != ascii_lower(needle[j]) { match = false; break }
		}
		if match { return true }
	}
	return false
}

@(private = "file")
ascii_lower :: proc(c: byte) -> byte { return c >= 'A' && c <= 'Z' ? c + 32 : c }
