package page

import "core:testing"
import "core:time"
import "wb:host"
import "wb:images"

// What a test's pages share (Pages), bound to the test's thread, let go of with the test.
test_pages :: proc(t: ^testing.T) -> ^Pages {
	js_code_from_env()
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

// The end of the loop of a test that shows images. The decoding threads post to it through the cache's port, and test_pages
// closes that port only after the test's own defers: a decode that ended in between posted to a loop that was gone, under
// the decoder's lock. A decode cancelled while it runs also frees what the test allocated, on its thread: waited for.
test_loop_destroy :: proc(loop: ^host.Loop) {
	images_shutdown()
	images.decoder_settle(30 * time.Second)
	host.loop_destroy(loop)
}
