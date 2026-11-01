package e2e

// The test server (src/testserver) in the test's process: the same block of ports for the whole process, what it has counted forgotten
// at each test. Every origin is an offset from one base port (tools/testserver/ports.go): +0 http on 127.0.0.1 and localhost, +1 https,
// +2 a second http origin.

import "core:fmt"
import "core:testing"
import "wb:testserver"

Server :: struct {
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
	s.base = base
	s.origin = fmt.aprintf("http://127.0.0.1:%d", base)
	return s
}

// An address of the test server: `path` from its root.
url :: proc(s: ^Server, path: string) -> string { return fmt.tprintf("%s%s", s.origin, path) }
