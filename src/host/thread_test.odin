package host

import "core:testing"

@(private = "file")
Probe :: struct { depth: int, temp_ok: bool }

@(private = "file")
recurse :: proc(n: int) -> int {
	buf: [1024]u8   // 1 KiB of stack per level
	buf[n % len(buf)] = u8(n)
	if n == 0 { return int(buf[0]) }
	return recurse(n - 1) + int(buf[n % len(buf)]) - int(u8(n))
}

@(test)
thread_with_its_own_stack_and_temp_allocator :: proc(t: ^testing.T) {
	pr: Probe
	th := thread_start(proc(data: rawptr) {
		p := (^Probe)(data)
		p.depth = recurse(3000)   // ~3 MiB of stack: more than the default thread stack
		s := make([]u8, 1 << 20, context.temp_allocator)
		p.temp_ok = len(s) == 1 << 20
	}, &pr, 8 << 20, .Below_Normal)
	testing.expect(t, th != nil)
	thread_join(th)
	testing.expect_value(t, pr.depth, 0)
	testing.expect(t, pr.temp_ok, "the thread has a temporary allocator of its own")
}

@(private = "file")
Flood :: struct { l: ^Loop, received: int }

@(test)
posts_from_many_threads_all_arrive :: proc(t: ^testing.T) {
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	f := Flood{l = &l}
	THREADS :: 8
	EACH :: 2000
	threads: [THREADS]^Thread
	for i in 0 ..< THREADS {
		threads[i] = thread_start(proc(data: rawptr) {
			fl := (^Flood)(data)
			for _ in 0 ..< EACH { post(fl.l, proc(d: rawptr) { (^Flood)(d).received += 1 }, fl) }
		}, &f)
	}
	for f.received < THREADS * EACH { loop_wait(&l, 100) }
	for th in threads { thread_join(th) }
	testing.expect_value(t, f.received, THREADS * EACH)
}
