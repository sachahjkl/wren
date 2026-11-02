package page

import "core:sync"
import "core:testing"
import "core:thread"
import "wb:base"
import "wb:host"

// Two Apps' pages at once, each on its own thread (docs/architecture.md, Where state lives): each thread makes its pages from
// a document, styles them and gives them their navigables, at the same time as the other. Each sees its own live pages and
// navigables and none of the other's, every id is unique in the process, and closing them leaves its thread's registries empty.

@(private = "file") SIDE_PAGES :: 6
@(private = "file") SIDE_VIEWPORT :: [2]f32{800, 600}
@(private = "file") SIDE_DOC :: `<!doctype html><title>side</title><style>p { color: red } .x > p { margin: 1em }</style><div class=x><p>one</p><p>two</p></div>`

@(private = "file")
Side :: struct {
	barrier:      ^sync.Barrier,
	other:        ^Side,
	page_ids:     [SIDE_PAGES]u64,
	nav_ids:      [SIDE_PAGES]u64,
	styled:       int,   // pages whose style pass gave a result
	listed:       int,   // live_page_list on this thread, all pages open
	own_found:    int,   // of its page ids, those page_by_id finds on this thread
	other_found:  int,   // ... of the other thread's
	own_navs:     int,   // of its navigable ids, those navigable_by_id finds on this thread
	other_navs:   int,   // ... of the other thread's
	listed_after: int,   // live_page_list once its pages are closed
	navs_after:   int,   // of its navigables, those still found then
}

@(private = "file")
side_run :: proc(s: ^Side) {
	context.allocator = base.process_allocator()
	loop: host.Loop
	host.loop_init(&loop)
	settings := settings_default()
	process := base.scope_make("process")
	pages: [SIDE_PAGES]^Page
	for i in 0 ..< SIDE_PAGES {
		p := page_create(&loop, nil, &settings, process, "https://side.example/")
		load_html(p, transmute([]byte)string(SIDE_DOC))
		if styles(p, SIDE_VIEWPORT.x, SIDE_VIEWPORT.y, 1) != nil { s.styled += 1 }
		pages[i] = p
		s.page_ids[i] = page_id(p)
		s.nav_ids[i] = page_navigable(p).id
	}
	sync.barrier_wait(s.barrier)   // both have made theirs
	s.listed = len(live_page_list())
	for i in 0 ..< SIDE_PAGES {
		if page_by_id(s.page_ids[i]) == pages[i] { s.own_found += 1 }
		if page_by_id(s.other.page_ids[i]) != nil { s.other_found += 1 }
		if navigable_by_id(s.nav_ids[i]) != nil { s.own_navs += 1 }
		if navigable_by_id(s.other.nav_ids[i]) != nil { s.other_navs += 1 }
	}
	sync.barrier_wait(s.barrier)   // both have looked
	base.scope_close(process)
	for _ in 0 ..< SIDE_PAGES { host.run_ready(&loop) }
	s.listed_after = len(live_page_list())
	for id in s.nav_ids { if navigable_by_id(id) != nil { s.navs_after += 1 } }
	frames_shutdown()
	settings_destroy(&settings)
	host.loop_destroy(&loop)
}

@(test)
two_apps_pages_on_two_threads_keep_to_their_own :: proc(t: ^testing.T) {
	barrier: sync.Barrier
	sync.barrier_init(&barrier, 2)
	a, b: Side
	a.barrier, a.other = &barrier, &b
	b.barrier, b.other = &barrier, &a
	ta := thread.create_and_start_with_poly_data(&a, side_run)
	tb := thread.create_and_start_with_poly_data(&b, side_run)
	thread.join(ta); thread.destroy(ta)
	thread.join(tb); thread.destroy(tb)

	for s, k in ([2]^Side{&a, &b}) {
		testing.expectf(t, s.styled == SIDE_PAGES, "side %d: every page has its styles (%d)", k, s.styled)
		testing.expectf(t, s.listed == SIDE_PAGES, "side %d: its thread lists its own %d pages, not the other's (%d)", k, SIDE_PAGES, s.listed)
		testing.expectf(t, s.own_found == SIDE_PAGES && s.other_found == 0, "side %d: page_by_id finds its pages (%d) and none of the other's (%d)", k, s.own_found, s.other_found)
		testing.expectf(t, s.own_navs == SIDE_PAGES && s.other_navs == 0, "side %d: navigable_by_id finds its navigables (%d) and none of the other's (%d)", k, s.own_navs, s.other_navs)
		testing.expectf(t, s.listed_after == 0 && s.navs_after == 0, "side %d: closed, its registries are empty (%d pages, %d navigables)", k, s.listed_after, s.navs_after)
	}
	seen: map[u64]bool
	defer delete(seen)
	navs: map[u64]bool
	defer delete(navs)
	for s in ([2]^Side{&a, &b}) {
		for id in s.page_ids { seen[id] = true }
		for id in s.nav_ids { navs[id] = true }
	}
	testing.expectf(t, len(seen) == 2 * SIDE_PAGES && len(navs) == 2 * SIDE_PAGES, "every id is unique in the process: %d pages, %d navigables", len(seen), len(navs))
}
