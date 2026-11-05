package e2e_scenarios

// What a long session on many sites leaves behind, in a loop on a local page (examples/site/memory-growth.html, a page unlike the one before it at each ?n=: functions hot enough to be
// compiled, styles, nodes, an image): the stores stay within their limits counted by what they really hold, the process levels off, closing tabs gives their memory back.
// docs/performance.md, round 26.

import "core:fmt"
import "core:testing"
import "wb:base"
import "wb:e2e"

@(private = "file") PAGE :: "/site/memory-growth.html"
@(private = "file") SIZE :: [2]int{800, 600}
@(private = "file") MB :: 1 << 20

// What ?heap= keeps alive in a page, and what the back/forward cache may hold of such pages: two of them, not the five it had when a realm counted for its nodes alone.
@(private = "file") HEAVY_PAGE_MB :: 24
@(private = "file") BFCACHE_LIMIT_MB :: 64
@(private = "file") HEAVY_PAGES :: 6

// The engine's own module (about 19 MB of code) and room for about a hundred small ones; twelve pages make about five hundred.
@(private = "file") MODULES_LIMIT_MB :: 24
@(private = "file") MODULES_PAGES :: 12
@(private = "file") MODULES_MOST :: 150

// A session past its caches' warming up: what each page adds from there. 30 pages of 40 modules grew by 60 MB and went on; bounded, by a few MB: what the system's heaps do leaves room.
@(private = "file") WARM_PAGES :: 12
@(private = "file") SESSION_PAGES :: 36
@(private = "file") SESSION_GROWTH_MB :: 48

// Tabs closed: at least this share of what their scripts held is back. (What is left is the heap's own free blocks and the allocator's rounding.)
@(private = "file") TABS :: 3
@(private = "file") TAB_HEAP_MB :: 48
@(private = "file") TAB_MEMORY_BACK_PERCENT :: 66

// A tab that leaves a large page: what the page took of the tracked memory (this program counts every block) is at least the first, and it keeps no more than the second.
@(private = "file") LARGE_PAGE_NODES :: 60_000
@(private = "file") LARGE_PAGE_HEAP_MB :: 30
@(private = "file") LARGE_PAGE_LEFT_MB :: 8

@(private = "file")
page_url :: proc(server: ^e2e.Server, n: int, heap_mb := 0, nodes := 300) -> string { return e2e.url(server, fmt.tprintf("%s?n=%d&heap=%d&nodes=%d", PAGE, n, heap_mb, nodes)) }

@(private = "file")
visit :: proc(s: ^e2e.Session, server: ^e2e.Server, n: int, heap_mb := 0, nodes := 300) {
	e2e.navigate(s, page_url(server, n, heap_mb, nodes))
	e2e.wait_js(s, `document.title.startsWith("page ")`)
}

@(test)
the_bfcache_counts_what_the_scripts_of_its_pages_hold :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = SIZE, prefs = {fmt.tprintf("history.bfcache.max_memory=%d", BFCACHE_LIMIT_MB * MB), "history.bfcache.page_overhead=0"}})
	for n in 1 ..= HEAVY_PAGES { visit(s, server, n, HEAVY_PAGE_MB) }
	st := e2e.stats_all(s)
	most := BFCACHE_LIMIT_MB / HEAVY_PAGE_MB
	testing.expectf(t, st.bfcache.stores >= HEAVY_PAGES - 1, "the pages left were stored: %v", st.bfcache)
	testing.expectf(t, st.bfcache.cached <= most, "at most %d pages of %d MB in %d MB: %d", most, HEAVY_PAGE_MB, BFCACHE_LIMIT_MB, st.bfcache.cached)
	testing.expectf(t, st.memory.wasm_instances <= most + 1, "their realms went with them: %d left", st.memory.wasm_instances)
}

@(test)
compiled_modules_stay_within_their_limit :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = SIZE, prefs = {fmt.tprintf("wasm.cache.memory_bytes=%d", MODULES_LIMIT_MB * MB), "history.bfcache.enabled=false"}})
	for n in 1 ..= MODULES_PAGES { visit(s, server, n) }
	st := e2e.stats_all(s)
	testing.expectf(t, st.memory.wasm_modules <= MODULES_MOST, "a module is counted with what it costs beyond its code: %d kept, %d MB of code", st.memory.wasm_modules, st.memory.wasm_code_bytes / MB)
}

@(test)
a_long_session_levels_off :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = SIZE})
	for n in 1 ..= WARM_PAGES { visit(s, server, n) }
	e2e.memory_trim(s)
	warm := base.process_counters().private
	for n in WARM_PAGES + 1 ..= SESSION_PAGES { visit(s, server, n) }
	e2e.memory_trim(s)
	end := base.process_counters().private
	testing.expectf(t, end - warm <= SESSION_GROWTH_MB * MB, "%d pages more add at most %d MB: %d MB -> %d MB", SESSION_PAGES - WARM_PAGES, SESSION_GROWTH_MB, warm / MB, end / MB)
}

@(test)
a_tab_forgets_the_size_of_a_large_page :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = SIZE, prefs = {"history.bfcache.enabled=false"}})
	visit(s, server, 1)
	e2e.wait_frames(s)
	e2e.memory_trim(s)
	before := base.mem_stats().live_bytes
	visit(s, server, 2, nodes = LARGE_PAGE_NODES)
	e2e.wait_frames(s)
	large := base.mem_stats().live_bytes
	testing.expectf(t, large - before >= LARGE_PAGE_HEAP_MB * MB, "the page takes memory: %d MB -> %d MB", before / MB, large / MB)
	visit(s, server, 3)
	e2e.wait_frames(s)
	e2e.memory_trim(s)
	after := base.mem_stats().live_bytes
	testing.expectf(t, after - before <= LARGE_PAGE_LEFT_MB * MB, "the next page does not carry its arrays: %d MB, %d MB, then %d MB", before / MB, large / MB, after / MB)
}

@(test)
closing_tabs_gives_their_memory_back :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = SIZE, prefs = {"history.bfcache.enabled=false"}})
	visit(s, server, 0)
	e2e.memory_trim(s)
	before := base.process_counters().private
	instances := e2e.stats_all(s).memory.wasm_instances
	tabs: [TABS]int
	for &id, i in tabs {
		id = e2e.new_tab(s, page_url(server, i + 1, TAB_HEAP_MB))
		e2e.wait_load(s)
		e2e.wait_js(s, `document.title.startsWith("page ")`)
	}
	open := base.process_counters().private
	testing.expectf(t, open - before >= TABS * TAB_HEAP_MB * MB, "the tabs hold their scripts' memory: %d MB -> %d MB", before / MB, open / MB)
	for id in tabs { e2e.close_tab(s, id) }
	e2e.wait_frames(s)
	e2e.memory_trim(s)
	closed := base.process_counters().private
	testing.expectf(t, e2e.stats_all(s).memory.wasm_instances == instances, "their realms are gone")
	testing.expectf(t, (open - closed) * 100 >= TABS * TAB_HEAP_MB * MB * TAB_MEMORY_BACK_PERCENT, "closed, at least %d %% of the %d MB is back: %d MB -> %d MB", TAB_MEMORY_BACK_PERCENT, TABS * TAB_HEAP_MB, open / MB, closed / MB)
}
