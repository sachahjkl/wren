package testhost

import "core:strings"
import "core:testing"
import "wb:page"

@(private = "file") DECLARED_TESTS :: 3
@(private = "file") DECLARED_CHECKS :: 2

@(private = "file")
has :: proc(problems: [dynamic]string, what: string) -> bool {
	for p in problems { if strings.contains(p, what) { return true } }
	return false
}

@(test)
a_section_that_ran_what_it_declares_passes :: proc(t: ^testing.T) {
	s := Section{begun = DECLARED_TESTS, ended = DECLARED_TESTS, checks = DECLARED_CHECKS, finished = true}
	problems, skips := judge(&s, tests = DECLARED_TESTS, min_checks = DECLARED_CHECKS)
	testing.expectf(t, len(problems) == 0, "%v", problems)
	testing.expect_value(t, len(skips), 0)
}

@(test)
a_section_that_ran_nothing_fails :: proc(t: ^testing.T) {
	s := Section{finished = true}
	problems, _ := judge(&s, tests = DECLARED_TESTS)
	testing.expect(t, has(problems, "it ran no test"))
}

@(test)
a_section_that_ended_early_fails :: proc(t: ^testing.T) {
	s := Section{begun = DECLARED_TESTS - 1, ended = DECLARED_TESTS - 2, test_open = "stuck"}
	problems, _ := judge(&s, tests = DECLARED_TESTS)
	testing.expect(t, has(problems, "still open"))
	testing.expect(t, has(problems, "ended early"))
}

@(test)
a_section_that_ran_more_than_it_declares_fails :: proc(t: ^testing.T) {
	s := Section{begun = DECLARED_TESTS + 1, ended = DECLARED_TESTS + 1, finished = true}
	problems, _ := judge(&s, tests = DECLARED_TESTS)
	testing.expect(t, has(problems, "it declares"))
}

@(test)
fewer_checks_than_declared_fail :: proc(t: ^testing.T) {
	s := Section{checks = DECLARED_CHECKS - 1, finished = true}
	problems, _ := judge(&s, min_checks = DECLARED_CHECKS)
	testing.expect(t, has(problems, "checks at least"))
}

// A skip: counted when the machine says the same, a failure whatever else it says or when nobody can tell.
@(test)
a_skip_holds_only_when_the_machine_says_so :: proc(t: ^testing.T) {
	skip_list := make([dynamic]Skip, context.temp_allocator)
	append(&skip_list, Skip{reason = .WebglAdapter, why = "null"})
	s := Section{skipped = true, finished = true, skips = skip_list}
	problems, skips := judge(&s, tests = DECLARED_TESTS, verify_skip = proc(_: page.Test_Skip_Reason) -> (Skip_Verdict, string) { return .Absent, "none" })
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, len(skips), 1)
	problems, skips = judge(&s, tests = DECLARED_TESTS, verify_skip = proc(_: page.Test_Skip_Reason) -> (Skip_Verdict, string) { return .Present, "there is one" })
	testing.expect(t, has(problems, "there is one"))
	testing.expect_value(t, len(skips), 0)
	problems, skips = judge(&s, tests = DECLARED_TESTS, verify_skip = proc(_: page.Test_Skip_Reason) -> (Skip_Verdict, string) { return .Unknown, "it timed out" })
	testing.expect(t, has(problems, "it timed out"))
	problems, skips = judge(&s, tests = DECLARED_TESTS)
	testing.expect_value(t, len(problems), 1)
	testing.expect_value(t, len(skips), 0)
}
