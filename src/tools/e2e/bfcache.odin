package e2e_scenarios

// The back/forward cache measured (bfcache.odin, Stats.bfcache): a page left by a navigation is kept and comes back from the cache (a hit), a page
// with an unload handler is not kept (its reason is counted) and going back to it loads it again (a miss).

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") BFCACHE_SIZE :: [2]int{1000, 700}
@(private = "file") FIRST_PAGE :: "/site/history/other.html"
@(private = "file") SECOND_PAGE :: "/site/history/next.html"

// `history.back()` from the page, until that traversal has happened and what it led to has loaded.
@(private = "file")
back_to :: proc(s: ^e2e.Session, traversals: int) {
	e2e.eval(s, "history.back(); 1")
	e2e.wait_until(s, traversals, proc(s: ^e2e.Session, n: int) -> bool { return e2e.stats(s).bfcache.traversals >= n }, "the traversal")
	e2e.wait_load(s)
}

@(test)
bfcache_hit_refusal_and_miss :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = BFCACHE_SIZE})
	e2e.navigate(s, e2e.url(server, FIRST_PAGE))
	e2e.navigate(s, e2e.url(server, SECOND_PAGE))
	back_to(s, 1)
	b := e2e.stats(s).bfcache
	testing.expectf(t, b.traversals >= 1 && b.restores >= 1 && b.misses == 0, "going back finds the page in the cache (a hit): got %v", b)

	// a page with an unload handler may not be kept
	e2e.eval(s, `addEventListener("unload", () => {}); 1`)
	e2e.navigate(s, e2e.url(server, SECOND_PAGE))
	back_to(s, 2)
	b = e2e.stats(s).bfcache
	unload := 0
	for r in b.reasons { if strings.contains(r.reason, "Unload") { unload = r.count } }
	testing.expect(t, b.refusals >= 1 && unload >= 1, fmt.tprintf("a page with an unload handler is refused, its reason counted: got %v", b))
	testing.expect(t, b.misses >= 1 && b.traversals >= 2, fmt.tprintf("going back to it is a miss: got %v", b))
}
