package base

// The tracker of the check builds (run with -define:WREN_TRACK_MEMORY=true; a normal build checks that the process
// allocators are the heap). Counters are compared before / after: other tests run at the same time.

@(require) import "base:runtime"
import "core:sync"
import "core:testing"
import "core:thread"

@(private = "file") mem_test_lock: sync.Mutex

@(test)
process_allocators :: proc(t: ^testing.T) {
	when !TRACK_MEMORY {
		testing.expect(t, process_allocator().procedure == runtime.heap_allocator_proc)
		testing.expect(t, permanent_allocator().procedure == runtime.heap_allocator_proc)
		testing.expect(t, process_context().allocator.procedure == runtime.heap_allocator_proc)
		testing.expect(t, !mem_stats().tracked)
		testing.expect_value(t, mem_report("normal build"), 0)
		return
	}
	sync.guard(&mem_test_lock)
	a := process_allocator()
	s0 := mem_stats()
	testing.expect(t, s0.tracked)
	p := new(int, a)
	s1 := mem_stats()
	testing.expect_value(t, s1.live_blocks - s0.live_blocks, 1)
	testing.expect_value(t, s1.live_bytes - s0.live_bytes, size_of(int))
	// a resize follows the block
	buf := make([dynamic]u8, 0, 16, a)
	for _ in 0 ..< 1000 { append(&buf, 1) }
	s2 := mem_stats()
	testing.expect_value(t, s2.live_blocks - s0.live_blocks, 2)
	testing.expect_value(t, s2.live_bytes - s0.live_bytes, i64(size_of(int) + cap(buf)))
	delete(buf)
	free(p, a)
	s3 := mem_stats()
	testing.expect_value(t, s3.live_blocks, s0.live_blocks)
	testing.expect_value(t, s3.live_bytes, s0.live_bytes)
	// a double free is refused and counted; a block the tracker never saw is freed on the heap
	q := new(int, a)
	free(q, a)
	free(q, a)
	testing.expect_value(t, mem_stats().bad_frees - s0.bad_frees, 1)
	sync.guard(&tracker.lock)
	clear(&tracker.bad); tracker.stats.bad_frees = s0.bad_frees
}

@(test)
permanent_blocks_are_not_leaks :: proc(t: ^testing.T) {
	when !TRACK_MEMORY { return }
	sync.guard(&mem_test_lock)
	s0 := mem_stats()
	p := new([64]u8, permanent_allocator())
	s1 := mem_stats()
	testing.expect_value(t, s1.live_blocks, s0.live_blocks)
	testing.expect_value(t, s1.permanent_blocks - s0.permanent_blocks, 1)
	free(p, permanent_allocator())
	testing.expect_value(t, mem_stats().permanent_blocks, s0.permanent_blocks)
}

@(test)
threads_share_the_tracker :: proc(t: ^testing.T) {
	when !TRACK_MEMORY { return }
	sync.guard(&mem_test_lock)
	s0 := mem_stats()
	N :: 8
	blocks: [N][dynamic]rawptr
	threads: [N]^thread.Thread
	for i in 0 ..< N {
		threads[i] = thread.create_and_start_with_data(&blocks[i], proc(data: rawptr) {
			context = process_context()
			list := (^[dynamic]rawptr)(data)
			for k in 0 ..< 500 {
				append(list, rawptr(new(int)))
				if k % 2 == 1 { free(pop(list)) }
			}
		})
	}
	for th in threads { thread.join(th); thread.destroy(th) }
	s1 := mem_stats()
	// each thread keeps 250 ints and its list
	testing.expect_value(t, s1.live_blocks - s0.live_blocks, N * 251)
	// freed from another thread than the one that allocated
	for &l in blocks {
		for p in l { free(p, process_allocator()) }
		delete(l)
	}
	testing.expect_value(t, mem_stats().live_blocks, s0.live_blocks)
}
