#+build windows
#+private file
// Whose work a timer is (src/page/work.odin, host.Work): the script that set it, and from it what it scheduled, on a page that runs a script of another site.
package e2e_scenarios

import "core:strings"
import "core:testing"
import "wb:base"
import "wb:host"
import "wb:page"
import "wb:tools/testenv"
import "wb:url"

ADDRESS :: "http://127.0.0.1:8765/jsload/test.html"
ANOTHER_SITE :: "http://localhost:8765"
// Timers that stay in the queue for the test to read, told apart by their delay.
OWN_MS :: 400_000
THIRD_MS :: 300_000
CHAINED_MS :: 200_000
ANSWERED_MS :: 100_000
LISTENED_MS :: 50_000
MS_TO_NS :: 1_000_000
// A delay is found within this much of what the script gave it.
DELAY_SLACK_MS :: 20_000

// The owner of the timer the page set with this delay.
timer_work :: proc(delay_ms: i64) -> (w: base.Work, found: bool) {
	now := host.now_ns(&loop)
	for e in loop.queue.queue {
		t := base.pool_get(&loop.timers, e.handle)
		if t == nil { continue }
		left := (t.deadline - now) / MS_TO_NS
		if left <= delay_ms && left > delay_ms - DELAY_SLACK_MS { return t.work, true }
	}
	return
}

@(test)
work_of_a_timer_is_the_script_that_set_it_and_what_it_scheduled :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	serve(t)
	third := url.percent_encoded(`
		setTimeout(function(){}, 300000);
		setTimeout(function(){ setTimeout(function(){}, 200000); wrenTest.note("chained"); }, 0);
		fetch("/jsload/gen?code=1").finally(function(){ setTimeout(function(){}, 100000); wrenTest.note("answered"); });
		addEventListener("heard", function(){ setTimeout(function(){}, 50000); });
	`, url.UNRESERVED)
	src := testenv.url(strings.concatenate({ANOTHER_SITE, "/jsload/gen?code=", third}, context.temp_allocator))
	pr := open_page(t, "work", strings.concatenate({`<!doctype html><script src="`, src, `"></script>
		<script>setTimeout(function(){}, 400000); dispatchEvent(new Event("heard")); wrenTest.note("own");</script>`}, context.temp_allocator), testenv.url(ADDRESS))
	wait_note(pr, "own")
	wait_note(pr, "chained")
	wait_note(pr, "answered")
	own, own_found := timer_work(OWN_MS)
	testing.expect(t, own_found, "the page's own timer")
	testing.expect(t, !own.third_party, "the page's own script is no third party")
	testing.expect_value(t, own.page, u32(page.page_id(pr.p)))
	testing.expect_value(t, own.class, base.Work_Class.Background)
	for delay in ([]i64{THIRD_MS, CHAINED_MS, ANSWERED_MS, LISTENED_MS}) {
		w, found := timer_work(delay)
		testing.expect(t, found, "a timer of the other site's script")
		testing.expect(t, w.third_party, "a timer of the other site's script is a third party's, through a timer, a response and a listener")
		testing.expect_value(t, w.page, own.page)
		testing.expect(t, w.origin != 0 && w.origin != own.origin, "it has the origin of that script")
	}
	close_page(pr)
}
