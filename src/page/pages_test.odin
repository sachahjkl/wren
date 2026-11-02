package page

import "core:testing"

// What a test's pages share (Pages), bound to the test's thread, let go of with the test.
test_pages :: proc(t: ^testing.T) -> ^Pages {
	s := new(Pages)
	bind(s)
	testing.cleanup(t, proc(p: rawptr) {
		s := (^Pages)(p)
		bind(s)
		pages_shutdown()
		bind(nil)
		free(s)
	}, s)
	return s
}
