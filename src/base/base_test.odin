package base

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
pool_stale_handles :: proc(t: ^testing.T) {
	p: Pool(int)
	defer pool_destroy(&p)
	a, pa := pool_insert(&p, 11)
	testing.expect_value(t, pa^, 11)
	_, ok := pool_remove(&p, a)
	testing.expect(t, ok)
	testing.expect(t, pool_get(&p, a) == nil, "removed handle must not resolve")
	b, _ := pool_insert(&p, 22)   // reuses the slot
	testing.expect_value(t, handle_index(a), handle_index(b))
	testing.expect(t, a != b, "generation must differ")
	testing.expect(t, pool_get(&p, a) == nil, "old handle must stay dead after reuse")
	testing.expect_value(t, pool_get(&p, b)^, 22)
	testing.expect(t, pool_get(&p, NIL_HANDLE) == nil)
	_, ok = pool_remove(&p, a)
	testing.expect(t, !ok, "double remove")
}

@(test)
pool_pointers_are_stable :: proc(t: ^testing.T) {
	p: Pool(int)
	defer pool_destroy(&p)
	h0, p0 := pool_insert(&p, 7)
	for i in 0 ..< 5 * POOL_CHUNK_SIZE { pool_insert(&p, i) }
	testing.expect(t, pool_get(&p, h0) == p0, "growing must not move existing objects")
	testing.expect_value(t, p.count, 5 * POOL_CHUNK_SIZE + 1)
}

@(test)
pool_iteration_and_reuse :: proc(t: ^testing.T) {
	p: Pool(int)
	defer pool_destroy(&p)
	hs: [100]Handle
	for i in 0 ..< 100 { hs[i], _ = pool_insert(&p, i) }
	for i := 0; i < 100; i += 2 { pool_remove(&p, hs[i]) }
	sum, n: int
	it: u32
	for _, v in pool_next(&p, &it) { sum += v^; n += 1 }
	testing.expect_value(t, n, 50)
	testing.expect_value(t, sum, 2500)
	for i in 0 ..< 50 { pool_insert(&p, 1000 + i) }
	testing.expect_value(t, p.used, u32(100))   // free slots were reused, the pool did not grow
}

@(test)
generation_wrap_skips_zero :: proc(t: ^testing.T) {
	p: Pool(int)
	defer pool_destroy(&p)
	h, _ := pool_insert(&p, 1)
	p.chunks[0][0].gen = max(u32) - 1
	h = handle_make(0, max(u32) - 1)
	pool_remove(&p, h)
	h2, _ := pool_insert(&p, 2)   // gen = max
	pool_remove(&p, h2)
	h3, _ := pool_insert(&p, 3)   // wraps: must be 1, never 0
	testing.expect_value(t, handle_gen(h3), u32(1))
	testing.expect(t, h3 != NIL_HANDLE)
}

@(private = "file")
Log :: struct { order: [dynamic]int }

@(private = "file")
log_a :: proc(data: rawptr) { l := (^Log)(data); append(&l.order, 1) }
@(private = "file")
log_b :: proc(data: rawptr) { l := (^Log)(data); append(&l.order, 2) }
@(private = "file")
log_c :: proc(data: rawptr) { l := (^Log)(data); append(&l.order, 3) }

@(test)
scope_closes_children_then_cleanups_in_reverse :: proc(t: ^testing.T) {
	l: Log
	defer delete(l.order)
	root := scope_make("root")
	child := scope_make("child", root)
	on_close(root, log_a, &l)
	on_close(child, log_b, &l)
	forgotten := on_close(root, log_c, &l)
	testing.expect(t, forget_cleanup(root, forgotten))
	testing.expect(t, !forget_cleanup(root, forgotten))
	_ = make([]byte, 1 << 20, scope_allocator(child))
	scope_close(root)
	testing.expect_value(t, len(l.order), 2)
	testing.expect_value(t, l.order[0], 2)   // child first
	testing.expect_value(t, l.order[1], 1)
}

// A replacement keeps the replaced resource's place: still released after what was registered since (a page's new
// document outlives the scripts' DOM state made for the old one, which writes into the document when it goes).
@(test)
scope_rebound_cleanup_keeps_its_place :: proc(t: ^testing.T) {
	l: Log
	defer delete(l.order)
	root := scope_make("root")
	old := on_close(root, log_a, &l)    // the old document
	on_close(root, log_b, &l)           // made since, points into the document
	testing.expect(t, rebind_cleanup(root, old, log_c, &l))   // the new document takes the old one's place
	testing.expect(t, !rebind_cleanup(root, Cleanup_Id(9999), log_c, &l))
	scope_close(root)
	testing.expect_value(t, len(l.order), 2)
	testing.expect_value(t, l.order[0], 2)   // what came since goes first
	testing.expect_value(t, l.order[1], 3)   // then the new document, in the old one's place
}

@(test)
scope_child_closed_early_detaches :: proc(t: ^testing.T) {
	l: Log
	defer delete(l.order)
	root := scope_make("root")
	child := scope_make("child", root)
	on_close(child, log_b, &l)
	scope_close(child)
	testing.expect_value(t, len(root.children), 0)
	scope_close(root)
	testing.expect_value(t, len(l.order), 1)   // the child's cleanup ran once only
}

@(test)
remove_tree_removes_a_directory_with_everything_in_it :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/wren_base_remove_tree", os.get_env("TEMP", context.temp_allocator))
	remove_tree(root)
	testing.expect(t, remove_tree(root), "an absent path: nothing to do")
	deep := fmt.tprintf("%s/a/b/c", root)
	testing.expect(t, os.make_directory_all(deep) == nil, "the tree is made")
	for name in ([]string{"x.txt", "a/y.txt", "a/b/z.txt", "a/b/c/w.txt"}) {
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), transmute([]byte)string("data")) == nil, "a file is written")
	}
	testing.expect(t, remove_tree(root), "removed")
	testing.expect(t, !os.exists(root), "nothing is left")
	file := fmt.tprintf("%s.txt", root)
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string("x")) == nil)
	testing.expect(t, remove_tree(file) && !os.exists(file), "a single file too")
}