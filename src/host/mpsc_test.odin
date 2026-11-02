package host

import "core:sync"
import "core:testing"
import "core:thread"

// Threads push into an inbox while the loop drains it, then it closes half-way: one drain posted per burst, every push
// accepted before the close drained once in its producer's order, every push after it refused.
@(test)
inbox_drains_in_order_and_refuses_after_close :: proc(t: ^testing.T) {
	INBOX_THREADS :: 4
	INBOX_PER_THREAD :: 10_000
	INBOX_WAIT_MS :: 100   // the longest a turn waits (a drain is posted far sooner while pushes come)
	Msg :: struct { producer, seq: int }
	Box :: struct {
		l:        ^Loop,
		inbox:    Inbox(Msg),
		last:     [INBOX_THREADS]int,
		wrong:    int,
		drained:  int,
		drains:   int,
		refused:  int,   // atomic
		accepted: int,   // atomic
		starts:   [INBOX_THREADS]Start,
	}
	Start :: struct { b: ^Box, producer: int }
	drain :: proc(data: rawptr) {
		b := (^Box)(data)
		inbox_begin(&b.inbox)
		b.drains += 1
		for {
			m := inbox_pop(&b.inbox) or_break
			if m.seq <= b.last[m.producer] { b.wrong += 1 }
			b.last[m.producer] = m.seq
			b.drained += 1
		}
	}
	l: Loop
	loop_init(&l)
	defer loop_destroy(&l)
	b := Box{l = &l}
	inbox_init(&b.inbox)
	defer inbox_destroy(&b.inbox)
	for p in 0 ..< INBOX_THREADS {
		b.last[p] = -1
		b.starts[p] = Start{&b, p}
	}
	threads: [INBOX_THREADS]^thread.Thread
	for p in 0 ..< INBOX_THREADS {
		threads[p] = thread.create_and_start_with_data(&b.starts[p], proc(data: rawptr) {
			st := (^Start)(data)
			b := st.b
			for s in 0 ..< INBOX_PER_THREAD {
				if inbox_push(b.l, &b.inbox, Msg{st.producer, s}, drain, b) { sync.atomic_add(&b.accepted, 1) } else { sync.atomic_add(&b.refused, 1) }
			}
		})
	}
	for sync.atomic_load(&b.accepted) < INBOX_THREADS * INBOX_PER_THREAD / 2 { loop_wait(&l, INBOX_WAIT_MS) }
	inbox_close(&b.inbox)
	testing.expect(t, inbox_closed(&b.inbox))
	for th in threads { thread.join(th); thread.destroy(th) }
	loop_drain(&l)   // the drain still posted, if one is, takes the rest
	testing.expect_value(t, b.wrong, 0)
	testing.expect_value(t, b.drained, sync.atomic_load(&b.accepted))
	testing.expect_value(t, b.drained + sync.atomic_load(&b.refused), INBOX_THREADS * INBOX_PER_THREAD)
	testing.expectf(t, b.drains < b.drained, "%d drains for %d messages: one per burst", b.drains, b.drained)
	_, left := inbox_pop(&b.inbox)
	testing.expect(t, !left)
}

// The queue alone, across many blocks: values come out in each producer's order, all of them, once.
@(test)
mpsc_keeps_each_producers_order_across_blocks :: proc(t: ^testing.T) {
	QUEUE_THREADS :: 5
	QUEUE_PER_THREAD :: 50 * MPSC_BLOCK_SLOTS + 7   // many blocks, the last one partly filled
	Q :: struct { q: Mpsc([2]int) }
	Start :: struct { q: ^Q, producer: int }
	q: Q
	mpsc_init(&q.q)
	defer mpsc_destroy(&q.q)
	starts: [QUEUE_THREADS]Start
	threads: [QUEUE_THREADS]^thread.Thread
	for p in 0 ..< QUEUE_THREADS {
		starts[p] = Start{&q, p}
		threads[p] = thread.create_and_start_with_data(&starts[p], proc(data: rawptr) {
			st := (^Start)(data)
			for s in 0 ..< QUEUE_PER_THREAD { mpsc_push(&st.q.q, [2]int{st.producer, s}) }
		})
	}
	next: [QUEUE_THREADS]int
	wrong, got := 0, 0
	for th in threads { thread.join(th); thread.destroy(th) }   // (then pops: the take of a finished queue is exact)
	for {
		v := mpsc_pop(&q.q) or_break
		if v[1] != next[v[0]] { wrong += 1 }
		next[v[0]] = v[1] + 1
		got += 1
	}
	testing.expect_value(t, wrong, 0)
	testing.expect_value(t, got, QUEUE_THREADS * QUEUE_PER_THREAD)
}
