// For the guests of the end-to-end tests (import "../testports"): the test server's block of ports moves as a whole
// (tools/testserver/ports.go, src/tools/testenv): the guests keep writing the default ports (http://127.0.0.1:8765/,
// https 8766, the second origin 8767) and pass those addresses through url(), which moves them by the distance of this
// document's port from 8765. A document that is not on the test server's block (file:, another host, no port) moves
// nothing.
package testports

import "web:web"

DEFAULT_BASE_PORT :: 8765

@(private) shift: int
@(private) known: bool
// url() results live in a ring of buffers: a few addresses of one expression or call stay valid together.
@(private) ring: [8][512]u8
@(private) next: int

// How far this document's port is from the default base port (0 when it is not on the test server).
port_shift :: proc "contextless" () -> int {
	if known { return shift }
	known = true
	buf: [128]u8
	origin, err := web.Window_origin(buf[:])
	if err != .None { return 0 }
	host_end := 0
	for i := len(origin) - 1; i >= 0; i -= 1 {
		if origin[i] == ':' { host_end = i; break }
		if origin[i] < '0' || origin[i] > '9' { return 0 }
	}
	if host_end == 0 || host_end == len(origin) - 1 { return 0 }
	host := origin[:host_end]
	if host != "http://127.0.0.1" && host != "http://localhost" && host != "https://127.0.0.1" && host != "https://localhost" { return 0 }
	p := 0
	for c in transmute([]u8)origin[host_end + 1:] { p = p * 10 + int(c - '0') }
	// an https document sits on base+1
	if host[:5] == "https" { p -= 1 }
	shift = p - DEFAULT_BASE_PORT
	return shift
}

// The port `offset` places after the base of the current block (0 http, 1 https, 2 the second http origin).
port :: proc "contextless" (offset := 0) -> int { return DEFAULT_BASE_PORT + port_shift() + offset }

// `s` with every default port written after a host (":8765" .. ":8769", not part of a longer number) moved to the
// current block. The result is `s` itself when nothing moves, else a buffer of the ring (valid for the next 7 calls).
url :: proc "contextless" (s: string) -> string {
	d := port_shift()
	if d == 0 { return s }
	out := &ring[next]
	next = (next + 1) % len(ring)
	n := 0
	put :: proc "contextless" (out: ^[512]u8, n: ^int, c: u8) { if n^ < len(out) { out[n^] = c; n^ += 1 } }
	for i := 0; i < len(s); {
		if is_default_port_at(s, i) {
			put(out, &n, ':')
			v := DEFAULT_BASE_PORT + d + int(s[i + 4] - '5')
			digits: [8]u8
			k := len(digits)
			for v > 0 { k -= 1; digits[k] = u8('0' + v % 10); v /= 10 }
			for c in digits[k:] { put(out, &n, c) }
			i += 5
			continue
		}
		put(out, &n, s[i])
		i += 1
	}
	return string(out[:n])
}

@(private)
is_default_port_at :: proc "contextless" (s: string, i: int) -> bool {
	if i == 0 || i + 5 > len(s) || s[i:i + 4] != ":876" { return false }
	d := s[i + 4]
	if d < '5' || d > '9' { return false }
	if i + 5 < len(s) && s[i + 5] >= '0' && s[i + 5] <= '9' { return false }
	c := s[i - 1]
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ']'
}
