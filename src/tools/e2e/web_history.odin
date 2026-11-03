#+build windows
#+private file
// The page's side of history: the session history tree as pages see it (history.length, pushState, back after a branch),
// history.scrollRestoration, pagehide / pageshow and PageTransitionEvent.persisted, freezing and thawing for the back/forward cache
// (timers and tasks held, then run), the reasons a page cannot be kept, and the persisted state of form controls. No server.
package e2e_scenarios

import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:host"
import "wb:page"

ADDRESS :: "http://127.0.0.1:8765/history/a.html"
TIMER_MS :: 20
FROZEN_FOR :: 200 * time.Millisecond     // more than the timer's and the interval's delays, on the test's clock
THAWED_FOR :: 50 * time.Millisecond
CONTROLS_CAPTURED :: 7                   // text, checkbox, the 3 options of the select, textarea, nested
TREE_ENTRIES :: 4

Hooks :: struct { left: int }

Tab :: struct {
	pr:      ^Probe,
	session: page.Session_History,
	hooks:   Hooks,
	left_before: int,
}

open :: proc(t: ^testing.T, tab: ^Tab, source: string) {
	tab.pr = page_make(t, "history", ADDRESS)
	page.session_push(&tab.session, ADDRESS, 0)
	page.set_embedder(tab.pr.p, {session = &tab.session, user = &tab.hooks,
		leaving = proc(user: rawptr, p: ^page.Page, e: ^page.History_Entry) { (^Hooks)(user).left += 1 },
	})
	page_load(tab.pr, source)
	wait_note(tab.pr, "loaded")
}

shut :: proc(tab: ^Tab, min_checks: int, loc := #caller_location) {
	close_page(tab.pr, min_checks = min_checks, loc = loc)
	page.session_destroy(&tab.session)
}

PAGE_A :: `<!doctype html><title>A</title><body>
<form id=f><input id=t name=t><input id=pw type=password name=pw><input id=off name=off autocomplete=off>
<input id=c type=checkbox name=c><select id=s name=s><option>one<option>two<option>three</select><textarea id=ta name=ta></textarea></form>
<div><p>x</p><input name=nested></div>
<script>
addEventListener('pageshow', e => wrenTest.note('pageshow ' + e.persisted + ' ' + (e instanceof PageTransitionEvent)));
addEventListener('pagehide', e => wrenTest.note('pagehide ' + e.persisted));
addEventListener('popstate', e => wrenTest.note('popstate ' + JSON.stringify(e.state)));
addEventListener('load', () => wrenTest.note('loaded'));
</script>`

@(test)
history_the_web_sees_the_active_path_of_the_tree :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	tab: Tab
	open(t, &tab, PAGE_A)
	check(tab.pr, wait_note(tab.pr, "pageshow false true"), "pageshow after load: persisted false, a PageTransitionEvent")
	run(tab.pr, `history.pushState({n:1}, '', '#1'); history.pushState({n:2}, '', '#2'); wrenTest.check(history.length === 3, 'pushState adds entries')`)
	check(tab.pr, tab.hooks.left == 2, "the embedder saves the entry left by each pushState")
	run(tab.pr, `history.back(); history.back();`)
	check(tab.pr, wait_note(tab.pr, `popstate {"n":1}`) && wait_note(tab.pr, "popstate null"), "back twice: popstate with each entry's state")
	run(tab.pr, `history.pushState({n:9}, '', '#9'); wrenTest.check(history.length === 2 && location.hash === '#9', 'a push after going back: the web sees 2 entries (the old ones are a branch)')`)
	check(tab.pr, tab.session.count == TREE_ENTRIES, "... and the tree keeps all 4")
	tab.left_before = tab.hooks.left
	run(tab.pr, `history.back()`)
	check(tab.pr, wait_until(t, "the traversal back from the branch", &tab, proc(tab: ^Tab) -> bool { return tab.hooks.left > tab.left_before }), "the traversal back from the branch ran")
	run(tab.pr, `wrenTest.check(history.length === 2, 'back from the branch: forward goes to the branch visited last')`)
	shut(&tab, min_checks = 6)
}

@(test)
history_scroll_restoration :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	tab: Tab
	open(t, &tab, PAGE_A)
	run(tab.pr, `wrenTest.check(history.scrollRestoration === 'auto', 'history.scrollRestoration starts auto'); history.scrollRestoration = 'manual'; history.scrollRestoration = 'bogus'; wrenTest.check(history.scrollRestoration === 'manual', 'then manual (other values ignored)')`)
	check(tab.pr, page.session_current(&tab.session).scroll_manual, "... kept in the current entry")
	run(tab.pr, `history.pushState(null, '', '#m'); wrenTest.check(history.scrollRestoration === 'manual', 'pushState carries the mode to the new entry')`)
	shut(&tab, min_checks = 4)
}

@(test)
history_page_transition_event_built_by_scripts :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	tab: Tab
	open(t, &tab, PAGE_A)
	run(tab.pr, `wrenTest.check(new PageTransitionEvent('pageshow', {persisted: true}).persisted === true && new PageTransitionEvent('x').persisted === false, 'new PageTransitionEvent(type, {persisted})')`)
	shut(&tab, min_checks = 1)
}

@(test)
history_what_keeps_a_page_out_of_the_cache :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	tab: Tab
	open(t, &tab, PAGE_A)
	check(tab.pr, page.bfcache_blockers(tab.pr.p) == {}, "a loaded page with nothing open can be kept")
	run(tab.pr, `window.u = () => {}; addEventListener('unload', u)`)
	check(tab.pr, .Unload_Listener in page.bfcache_blockers(tab.pr.p), "an unload listener keeps the page out of the cache")
	run(tab.pr, `removeEventListener('unload', u)`)
	check(tab.pr, page.bfcache_blockers(tab.pr.p) == {}, "... and not once removed")
	shut(&tab, min_checks = 3)
}

// On the test's clock: nothing may run for as long as the test says, and what comes due runs when it says.
@(test)
history_frozen_timers_wait_then_run :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	tab: Tab
	open(t, &tab, PAGE_A)
	virtual_clock(t)
	run(tab.pr, `window.ticks = 0; setTimeout(() => wrenTest.note('timer ran ' + document.visibilityState), 20); setInterval(() => window.ticks++, 10)`)
	page.page_freeze(tab.pr.p)
	check(tab.pr, wait_note(tab.pr, "pagehide true"), "frozen: pagehide with persisted true")
	check(tab.pr, page.page_frozen(tab.pr.p) && !page.page_visible(tab.pr.p), "frozen and hidden")
	host.clock_advance(&loop, FROZEN_FOR)
	check(tab.pr, !said_prefix(tab.pr, "timer ran"), "no timer runs while frozen")
	run(tab.pr, `wrenTest.check(window.ticks === 0, 'no interval runs while frozen')`)
	page.page_thaw(tab.pr.p)
	check(tab.pr, wait_note(tab.pr, "pageshow true true"), "thawed: pageshow with persisted true")
	host.clock_advance(&loop, THAWED_FOR)
	check(tab.pr, wait_note(tab.pr, "timer ran visible"), "the timer that came due runs once thawed, the page visible")
	run(tab.pr, `wrenTest.check(window.ticks > 0, 'intervals go on')`)
	shut(&tab, min_checks = 7)
}

said_prefix :: proc(pr: ^Probe, prefix: string) -> bool {
	for n in pr.section.notes { if strings.has_prefix(n, prefix) { return true } }
	return false
}

@(test)
history_persisted_state_of_form_controls :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	tab: Tab
	open(t, &tab, PAGE_A)
	run(tab.pr, `t.value = 'typed'; pw.value = 'secret'; off.value = 'nope'; c.checked = true; s.selectedIndex = 2; ta.value = 'long\ntext'; document.querySelector('[name=nested]').value = 'deep'`)
	ps: page.Persisted_State
	defer page.persisted_destroy(&ps)
	testing.expect_value(t, page.persisted_capture_controls(tab.pr.p, &ps), CONTROLS_CAPTURED)
	for c in ps.controls { testing.expectf(t, !strings.contains(c.path, "pw") && !strings.contains(c.path, "off"), "not captured: password, autocomplete=off (%s)", c.path) }
	shut(&tab, min_checks = 0)

	again: Tab
	open(t, &again, PAGE_A)
	testing.expect_value(t, page.persisted_restore_controls(again.pr.p, &ps), CONTROLS_CAPTURED)
	run(again.pr, `wrenTest.check([t.value, pw.value, off.value, c.checked, s.value, ta.value, document.querySelector('[name=nested]').value].join('|') === 'typed|||true|three|long\ntext|deep', 'the values are back in a new document of the same page')`)
	shut(&again, min_checks = 1)

	// a page whose controls changed kind keeps its own
	other: Tab
	open(t, &other, `<input id=t type=checkbox name=t><script>addEventListener('load', () => wrenTest.note('loaded'))</script>`)
	testing.expect_value(t, page.persisted_restore_controls(other.pr.p, &ps), 0)
	shut(&other, min_checks = 0)
}
