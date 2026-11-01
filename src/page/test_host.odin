package page

// What a page tells its test program (api/testhost.widl): typed calls instead of lines of the console. A page has this only
// when a test program gives it (set_test_host, before its first script): its realm then has the global `wrenTest`. A browser
// never does, so that no page can reach any of it; a Wasm guest importing the module directly reaches nothing either.

Test_Skip_Reason :: Api_TestSkipReason

Test_Host :: struct {
	user:       rawptr,
	test_begin: proc(user: rawptr, name: string),
	test_end:   proc(user: rawptr, name: string),
	check:      proc(user: rawptr, passed: bool, what: string),
	measure:    proc(user: rawptr, name: string, value: f64),
	note:       proc(user: rawptr, text: string),
	signal:     proc(user: rawptr, name: string),
	skip:       proc(user: rawptr, reason: Test_Skip_Reason, why: string),
	done:       proc(user: rawptr),
}

set_test_host :: proc(p: ^Page, h: ^Test_Host) { p.test_host = h }

TestHost_testBegin :: proc(c: ^Call, name: string) { if h := c.page.test_host; h != nil { h.test_begin(h.user, name) } }
TestHost_testEnd :: proc(c: ^Call, name: string) { if h := c.page.test_host; h != nil { h.test_end(h.user, name) } }
TestHost_check :: proc(c: ^Call, passed: bool, what: string) { if h := c.page.test_host; h != nil { h.check(h.user, passed, what) } }
TestHost_measure :: proc(c: ^Call, name: string, value: f64) { if h := c.page.test_host; h != nil { h.measure(h.user, name, value) } }
TestHost_note :: proc(c: ^Call, text: string) { if h := c.page.test_host; h != nil { h.note(h.user, text) } }
TestHost_signal :: proc(c: ^Call, name: string) { if h := c.page.test_host; h != nil { h.signal(h.user, name) } }
TestHost_skip :: proc(c: ^Call, reason: Api_TestSkipReason, why: string) { if h := c.page.test_host; h != nil { h.skip(h.user, reason, why) } }
TestHost_done :: proc(c: ^Call) { if h := c.page.test_host; h != nil { h.done(h.user) } }
