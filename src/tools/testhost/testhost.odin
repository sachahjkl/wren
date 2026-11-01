// The test programs' side of a page's `wrenTest` (api/testhost.widl, src/page/test_host.odin): what a section of a test
// program (one script or page, one @(test)) ran, against what it declared. A section passes only when it declared what it
// runs, all of it ran and came to its end, and every check held:
//   * a section that ran no test, or fewer or more than it declared, or that did not reach done(), fails;
//   * so does a test that checked nothing;
//   * "this machine has no X" is an explicit skip: reported and counted, and it fails unless `verify_skip` finds it true.
// The calls of a page arrive inside the page's script, in the context of a Wasm import: nothing here may reach core:testing
// from there (its logger is not in that context, and a failure would be lost). They are recorded, and report hands them to
// the test on its own thread.
package testhost

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"
import "wb:page"

Skip_Verdict :: enum {
	Absent,      // true: the machine has none. Counted as a skip.
	Present,     // the machine has one: the skip hides something broken. A failure.
	Unknown,     // the program could not tell, which is no reason to pass. A failure.
}

Section :: struct {
	name:        string,
	host:        page.Test_Host,
	test_open:   string,            // the test running ("" none)
	checks_open: int,               // its checks and skips
	begun, ended: int,
	checks:      int,               // those that held
	finished:    bool,              // done() was called
	skipped:     bool,              // skip() with no test open: the whole section
	notes:       [dynamic]string,
	signals:     [dynamic]string,   // asked for and not acted on yet
	measures:    [dynamic]string,
	failures:    [dynamic]string,   // recorded, for report
	skips:       [dynamic]Skip,
}

Skip :: struct {
	reason: page.Test_Skip_Reason,
	test:   string,
	why:    string,
}

// What a whole run counted (the last test prints it).
Totals :: struct {
	sections, passes, failures, skips: int,
}
totals: Totals

// Connects the section to a page, before its first script.
attach :: proc(s: ^Section, p: ^page.Page) {
	s.host = page.Test_Host{
		user = s,
		test_begin = test_begin, test_end = test_end, check = check, measure = measure, note = note, signal = signal, skip = skip, done = done,
	}
	page.set_test_host(p, &s.host)
}

@(private = "file")
fail :: proc(s: ^Section, text: string) { append(&s.failures, text) }

@(private = "file")
test_begin :: proc(user: rawptr, name: string) {
	s := (^Section)(user)
	if s.test_open != "" { fail(s, fmt.aprintf("test %q began inside %q", name, s.test_open)) ; delete(s.test_open) }
	s.test_open, s.checks_open = strings.clone(name), 0
	s.begun += 1
}

@(private = "file")
test_end :: proc(user: rawptr, name: string) {
	s := (^Section)(user)
	if s.checks_open == 0 { fail(s, fmt.aprintf("test %q checked nothing", name)) }
	delete(s.test_open)
	s.test_open = ""
	s.ended += 1
}

@(private = "file")
check :: proc(user: rawptr, passed: bool, what: string) {
	s := (^Section)(user)
	s.checks_open += 1
	if passed { s.checks += 1 } else { fail(s, strings.clone(what)) }
}

@(private = "file")
measure :: proc(user: rawptr, name: string, value: f64) {
	s := (^Section)(user)
	s.checks_open += 1
	append(&s.measures, fmt.aprintf("%s %v", name, value))
}

@(private = "file")
note :: proc(user: rawptr, text: string) { append(&(^Section)(user).notes, strings.clone(text)) }

@(private = "file")
signal :: proc(user: rawptr, name: string) { append(&(^Section)(user).signals, strings.clone(name)) }

@(private = "file")
skip :: proc(user: rawptr, reason: page.Test_Skip_Reason, why: string) {
	s := (^Section)(user)
	s.checks_open += 1
	if s.test_open == "" { s.skipped = true }
	append(&s.skips, Skip{reason, strings.clone(s.test_open), strings.clone(why)})
}

@(private = "file")
done :: proc(user: rawptr) { (^Section)(user).finished = true }

// A note of the page.
noted :: proc(s: ^Section, text: string) -> bool {
	for n in s.notes { if n == text { return true } }
	return false
}

// Passes on what the page's calls recorded so far (a failure as it happens: a section that then hangs has said what it knows).
flush :: proc(s: ^Section, t: ^testing.T, loc := #caller_location) {
	for f in s.failures {
		testing.expectf(t, false, "[%s] %s", s.name, f, loc = loc)
		fmt.printf("FAIL [%s] %s\n", s.name, f)
		totals.failures += 1
		delete(f)
	}
	clear(&s.failures)
}

// A failure the program found itself.
expect :: proc(s: ^Section, t: ^testing.T, ok: bool, what: string, loc := #caller_location) {
	if ok { s.checks += 1; return }
	testing.expectf(t, false, "[%s] %s", s.name, what, loc = loc)
	fmt.printf("FAIL [%s] %s\n", s.name, what)
	totals.failures += 1
}

Verify_Skip :: #type proc(reason: page.Test_Skip_Reason) -> (Skip_Verdict, string)

// What is wrong with a section that has ended, and the skips that are true (temporary memory), against what it declares: `tests`
// tests (< 0: no tests, but `min_checks` checks at least). `verify_skip` nil: no skip is acceptable.
judge :: proc(s: ^Section, tests := -1, min_checks := 0, verify_skip: Verify_Skip = nil) -> (problems, true_skips: [dynamic]string) {
	problems = make([dynamic]string, context.temp_allocator)
	true_skips = make([dynamic]string, context.temp_allocator)
	verdicts: [len(page.Test_Skip_Reason)]Maybe(Skip_Verdict)
	details: [len(page.Test_Skip_Reason)]string
	for x in s.skips {
		i := int(x.reason)
		if verdicts[i] == nil {
			v := Skip_Verdict.Unknown
			if verify_skip != nil { v, details[i] = verify_skip(x.reason) }
			verdicts[i] = v
		}
		place := x.test != "" ? x.test : "the whole section"
		if verdicts[i].? == .Absent {
			append(&true_skips, fmt.tprintf("SKIP [%s] %s: %v (%s): %s", s.name, place, x.reason, details[i], x.why))
		} else {
			append(&problems, fmt.tprintf("%s said it cannot run: %v (%s), but that is not what this machine says: %s", place, x.reason, x.why, details[i]))
		}
	}
	if !s.skipped {
		if tests >= 0 {
			if s.begun == 0 { append(&problems, "it ran no test") }
			if s.begun != tests || s.ended != tests {
				open := s.test_open != "" ? fmt.tprintf("; still open: %q", s.test_open) : ""
				append(&problems, fmt.tprintf("it declares %d tests: %d began, %d ended%s", tests, s.begun, s.ended, open))
			}
		}
		if s.checks < min_checks { append(&problems, fmt.tprintf("it declares %d checks at least: %d", min_checks, s.checks)) }
	}
	if !s.finished { append(&problems, "it ended early: the script never said it was done") }
	return
}

// What a section recorded goes.
forget :: proc(s: ^Section) {
	for x in s.skips { delete(x.test); delete(x.why) }
	delete(s.skips)
	s.skips = nil
	for m in s.measures { delete(m) }
	delete(s.measures)
	s.measures = nil
	for n in s.notes { delete(n) }
	delete(s.notes)
	s.notes = nil
	for x in s.signals { delete(x) }
	delete(s.signals)
	s.signals = nil
	for f in s.failures { delete(f) }
	delete(s.failures)
	s.failures = nil
	if s.test_open != "" { delete(s.test_open); s.test_open = "" }
}

// The end of a section: judged, reported, counted, forgotten.
finish :: proc(s: ^Section, t: ^testing.T, tests := -1, min_checks := 0, verify_skip: Verify_Skip = nil, loc := #caller_location) {
	flush(s, t, loc)
	problems, true_skips := judge(s, tests, min_checks, verify_skip)
	for line in true_skips {
		fmt.println(line)
		log.info(line)
		totals.skips += 1
	}
	for p in problems { expect(s, t, false, p, loc) }
	totals.sections += 1
	totals.passes += s.checks
	for m in s.measures { log.infof("measure [%s] %s", s.name, m) }
	forget(s)
}