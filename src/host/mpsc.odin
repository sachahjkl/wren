package host

// What other threads hand to one consumer without a lock.
//
// `Mpsc(T)` is an unbounded multi-producer single-consumer queue of values in blocks (about MPSC_BLOCK_BYTES each,
// numbered from 0 and linked). A producer claims the next position with one fetch-and-add on the tail (wait-free: no
// retry, however many producers), finds the block of that position (the last one linked, almost always; it links the
// next one when nobody has), writes its slot and stamps it with its position. The consumer walks the slots in position
// order in place, each once it bears its stamp: order is kept per producer, and a slot still being written ends the walk
// until its producer, done, asks for another turn (a wake, a posted drain): nothing is lost and nobody waits.
//
// A block the consumer has left is retired with the tail's position at that moment: every producer that may still
// hold a pointer to it claimed its position before (it claims first, then looks for its block), so once the consumer
// has taken every position before that mark, nobody can touch the block, and it becomes a spare (or goes back to the
// heap). Spares are what new blocks are made of: a running queue allocates nothing.
//
// `Inbox(T)` is that queue between threads that produce and the loop that consumes in one posted drain per burst (the
// network's events): pushes after inbox_close are refused (the caller keeps the value), so a late completion never
// reaches a consumer that is gone.

import "core:sync"
import "core:thread"
import "wb:base"

// Bytes of a block's slots: a block holds as many values as fit (one at least), allocated once per as many pushes at most.
MPSC_BLOCK_BYTES :: 16 * 1024

// Emptied blocks a queue keeps for its next ones: a producer as far ahead of the consumer as this many blocks allocates
// none (more go back to the heap).
MPSC_SPARES :: 4

// Bytes between the producers' fields and the consumer's: each its own cache line.
@(private) CACHE_LINE :: 64

Mpsc_Slot :: struct($T: typeid) {
	value:   T,
	written: int,   // atomic: the position the value was pushed at, + 1 (a block used again holds older ones: no reset)
}


Mpsc_Block :: struct($T: typeid) #align(CACHE_LINE) {
	next:   ^Mpsc_Block(T),   // atomic: linked by the first producer that needs it
	number: int,              // atomic: positions [number * slots, (number + 1) * slots) are here
	_:      [CACHE_LINE - 2 * size_of(int)]u8,   // the slots start on a line of their own
	slots:  [max(MPSC_BLOCK_BYTES / size_of(Mpsc_Slot(T)), 1)]Mpsc_Slot(T),
}

@(private)
Mpsc_Retired :: struct($T: typeid) {
	block: ^Mpsc_Block(T),
	mark:  int,   // the tail when it was retired: free once the consumer took every position before
}

Mpsc :: struct($T: typeid) {
	_:          [CACHE_LINE]u8,   // (off the line of whatever precedes it)
	// producers
	tail:       int,                           // atomic: the next position to claim
	tail_block: ^Mpsc_Block(T),                // atomic: a hint, the last block linked (or one before it)
	head_block: ^Mpsc_Block(T),                // atomic: the consumer's block, where a producer whose hint ran ahead starts
	spares:     [MPSC_SPARES]^Mpsc_Block(T),   // atomic, each taken by an exchange
	_:          [CACHE_LINE]u8,
	// the consumer
	head:       int,
	retired:    [dynamic]Mpsc_Retired(T),
	_:          [CACHE_LINE]u8,   // (off the line of whatever follows it)
}

mpsc_init :: proc(q: ^Mpsc($T)) {
	b := new(Mpsc_Block(T), base.process_allocator())
	q^ = {tail_block = b, head_block = b}
	q.retired = make([dynamic]Mpsc_Retired(T), base.process_allocator())
}

// The consumer, once no producer is left. What is still queued is dropped (take it first to free what it owns).
mpsc_destroy :: proc(q: ^Mpsc($T)) {
	a := base.process_allocator()
	for b := q.head_block; b != nil; {
		next := b.next
		free(b, a)
		b = next
	}
	for r in q.retired { free(r.block, a) }
	delete(q.retired)
	for s in q.spares { free(s, a) }
	q^ = {}
}

// Any thread.
mpsc_push :: proc(q: ^Mpsc($T), v: T) {
	SLOTS :: max(MPSC_BLOCK_BYTES / size_of(Mpsc_Slot(T)), 1)
	pos := sync.atomic_add(&q.tail, 1)
	want := pos / SLOTS
	b := sync.atomic_load(&q.tail_block)
	if sync.atomic_load(&b.number) > want { b = sync.atomic_load(&q.head_block) }   // the hint ran past this position's block
	for sync.atomic_load(&b.number) < want {
		next := sync.atomic_load(&b.next)
		if next == nil {
			fresh := spare_take(q)
			fresh.number = b.number + 1
			if prev, linked := sync.atomic_compare_exchange_strong(&b.next, nil, fresh); linked { next = fresh } else { spare_put(q, fresh); next = prev }
		}
		b = next
	}
	for {   // the hint goes forward only
		hint := sync.atomic_load(&q.tail_block)
		if sync.atomic_load(&hint.number) >= want { break }
		if _, ok := sync.atomic_compare_exchange_weak(&q.tail_block, hint, b); ok { break }
	}
	slot := &b.slots[pos - want * SLOTS]
	slot.value = v
	sync.atomic_store(&slot.written, pos + 1)
}

// Any thread. Where the next push goes: mpsc_next(q, before = this) takes only what was pushed until now.
mpsc_mark :: proc(q: ^Mpsc($T)) -> int { return sync.atomic_load(&q.tail) }

// The consumer. The oldest value, in place (valid until the next call); nil when there is none before the mark
// `before`, or it is still being written.
mpsc_next :: #force_inline proc(q: ^Mpsc($T), before := max(int)) -> ^T {
	SLOTS :: max(MPSC_BLOCK_BYTES / size_of(Mpsc_Slot(T)), 1)
	b := q.head_block
	if q.head >= before || b == nil { return nil }   // (nil: destroyed, and a drain posted before still runs)
	if len(q.retired) > 0 && q.head >= q.retired[0].mark { release_retired(q) }
	offset := q.head - b.number * SLOTS
	if offset == SLOTS {   // the block is done: on to the next, when its first producer has linked it
		next := sync.atomic_load(&b.next)
		if next == nil { return nil }
		sync.atomic_store(&q.head_block, next)
		// a producer that holds `b` (or may still find it as the hint) claimed before this mark
		for {
			hint := sync.atomic_load(&q.tail_block)
			if hint != b { break }
			if _, ok := sync.atomic_compare_exchange_weak(&q.tail_block, b, next); ok { break }
		}
		append(&q.retired, Mpsc_Retired(T){b, sync.atomic_load(&q.tail)})
		b, offset = next, 0
	}
	slot := &b.slots[offset]
	if sync.atomic_load(&slot.written) != q.head + 1 { return nil }
	q.head += 1
	return &slot.value
}

// The consumer. Whether the next value is written (mpsc_next would return it, the mark aside).
mpsc_ready :: proc(q: ^Mpsc($T)) -> bool {
	SLOTS :: max(MPSC_BLOCK_BYTES / size_of(Mpsc_Slot(T)), 1)
	b := q.head_block
	if b == nil { return false }
	offset := q.head - b.number * SLOTS
	if offset == SLOTS {
		b = sync.atomic_load(&b.next)
		if b == nil { return false }
		offset = 0
	}
	return sync.atomic_load(&b.slots[offset].written) == q.head + 1
}

// The consumer. A copy of the oldest value (mpsc_next).
mpsc_pop :: proc(q: ^Mpsc($T), before := max(int)) -> (v: T, ok: bool) {
	p := mpsc_next(q, before)
	if p == nil { return }
	return p^, true
}

@(private)
release_retired :: proc(q: ^Mpsc($T)) {
	n := 0
	for n < len(q.retired) && q.head >= q.retired[n].mark {
		b := q.retired[n].block
		b.next = nil
		spare_put(q, b)
		n += 1
	}
	remove_range(&q.retired, 0, n)
}

@(private)
spare_take :: proc(q: ^Mpsc($T)) -> ^Mpsc_Block(T) {
	for &s in q.spares {
		if b := sync.atomic_exchange(&s, nil); b != nil { return b }
	}
	return new(Mpsc_Block(T), base.process_allocator())
}

// A block nobody holds (next nil) becomes a spare, or goes when there are enough.
@(private)
spare_put :: proc(q: ^Mpsc($T), b: ^Mpsc_Block(T)) {
	for &s in q.spares {
		if _, ok := sync.atomic_compare_exchange_strong(&s, nil, b); ok { return }
	}
	free(b, base.process_allocator())
}

// Inbox.gate: closed, plus one INBOX_PRODUCER for each thread inside inbox_push.
@(private) INBOX_CLOSED :: 1
@(private) INBOX_PRODUCER :: 2

Inbox :: struct($T: typeid) {
	queue:  Mpsc(T),
	gate:   int,   // atomic: INBOX_CLOSED | producers inside x INBOX_PRODUCER
	posted: b32,   // atomic: a drain is posted to the loop and has not begun
}

inbox_init :: proc(b: ^Inbox($T)) { mpsc_init(&b.queue) }

// Loop thread, once closed. What is still queued is dropped (take it first).
inbox_destroy :: proc(b: ^Inbox($T)) { mpsc_destroy(&b.queue) }

// Any thread. Pushes `v` and posts `drain(data)` to the loop unless a drain is already posted. False when the inbox is
// closed: `v` is still the caller's.
inbox_push :: proc(l: ^Loop, b: ^Inbox($T), v: T, drain: Task_Proc, data: rawptr, by := #caller_location) -> bool {
	defer sync.atomic_sub(&b.gate, INBOX_PRODUCER)
	if sync.atomic_add(&b.gate, INBOX_PRODUCER) & INBOX_CLOSED != 0 { return false }
	mpsc_push(&b.queue, v)
	if sync.atomic_load(&b.posted) { return true }   // (read first: no write to a line every push reads)
	if _, first := sync.atomic_compare_exchange_strong(&b.posted, false, true); first { post(l, drain, data, by) }
	return true
}

// Loop thread, first thing in the drain: a push from now on posts a drain of its own (this one finds it, or the next).
inbox_begin :: proc(b: ^Inbox($T)) { sync.atomic_store(&b.posted, false) }

// Loop thread (mpsc_mark, mpsc_next, mpsc_pop).
inbox_mark :: proc(b: ^Inbox($T)) -> int { return mpsc_mark(&b.queue) }
inbox_next :: proc(b: ^Inbox($T), before := max(int)) -> ^T { return mpsc_next(&b.queue, before) }
inbox_pop :: proc(b: ^Inbox($T), before := max(int)) -> (v: T, ok: bool) { return mpsc_pop(&b.queue, before) }

// Loop thread. Once it returns, no push succeeds and none is under way (it waits for those inside, a few instructions
// each). Returns whether a drain is still posted: it will run, and must find the inbox's owner alive.
inbox_close :: proc(b: ^Inbox($T)) -> (drain_posted: bool) {
	sync.atomic_or(&b.gate, INBOX_CLOSED)
	for sync.atomic_load(&b.gate) != INBOX_CLOSED { thread.yield() }
	return bool(sync.atomic_load(&b.posted))
}

inbox_closed :: proc(b: ^Inbox($T)) -> bool { return sync.atomic_load(&b.gate) & INBOX_CLOSED != 0 }
