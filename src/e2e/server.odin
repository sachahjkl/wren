package e2e

// The test server (src/testserver) in the test's process: the same block of ports for the whole process, what it has counted forgotten
// at each test. Every origin is an offset from one base port (tools/testserver/ports.go): +0 http on 127.0.0.1 and localhost, +1 https,
// +2 a second http origin.

import "core:fmt"
import "core:net"
import "core:testing"
import "wb:testserver"

Server :: struct {
	t:      ^testing.T,
	base:   int,
	origin: string,    // http://127.0.0.1:<base>
}

// The test server for this test: it listens when this returns.
test_server :: proc(t: ^testing.T, loc := #caller_location) -> ^Server {
	base, why := testserver.start()
	if base == 0 { stop_test(t, why, loc) }
	s := new(Server)
	testing.cleanup(t, proc(ptr: rawptr) {
		s := (^Server)(ptr)
		delete(s.origin)
		free(s)
	}, s)
	s.t, s.base = t, base
	s.origin = fmt.aprintf("http://127.0.0.1:%d", base)
	return s
}

// An address of the test server: `path` from its root.
url :: proc(s: ^Server, path: string) -> string { return fmt.tprintf("%s%s", s.origin, path) }

// What the server holds back with ?gate=name is answered from now on (tools/testserver/gate.go): a slow response whose end the test decides, with no clock in it. It holds when this returns.
// (Not through the browser: a page held by a navigation has no script any more.)
open_gate :: proc(s: ^Server, name: string, loc := #caller_location) {
	socket, dialed := net.dial_tcp_from_endpoint({address = net.IP4_Loopback, port = s.base})
	if dialed != nil { stop_test(s.t, fmt.tprintf("the test server does not answer: %v", dialed), loc) }
	defer net.close(socket)
	request := fmt.tprintf("GET /gate/open?name=%s HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n", name)
	if _, sent := net.send_tcp(socket, transmute([]byte)request); sent != nil { stop_test(s.t, fmt.tprintf("the test server does not read: %v", sent), loc) }
	buf: [GATE_ANSWER_BYTES]byte
	for {
		n, received := net.recv_tcp(socket, buf[:])
		if n == 0 || received != nil { return }   // (HTTP/1.0: the end of the answer is the end of the connection)
	}
}
@(private = "file") GATE_ANSWER_BYTES :: 1024

