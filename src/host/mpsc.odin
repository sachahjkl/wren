package host

// What other threads hand to one consumer without a lock.
//
// `Mpsc(T)` is an unbounded multi-producer single-consumer queue of values, in blocks of MPSC_BLOCK_SLOTS (the scheme of
// crossbeam's SegQueue, with one consumer). A producer claims the next position with a compare-and-swap on one
// counter, writes its slot and stamps it with its position: one contended atomic per push, and values side by side as in an
// array. The consumer takes slots in position order, each once it bears its stamp, so order is kept per producer, and a slot
// still being written ends the take until its producer, done, asks for another turn (a wake, a posted drain): nothing
// is lost and nobody waits for the consumer. The producer that claims a block's last slot links the next block first;
// a block the consumer emptied is kept as a spare the next ones are made of (no allocation once running). A
// producer holding a stale block pointer never touches it: its claim fails first (positions only grow).
//
// `Inbox(T)` is that queue between threads that produce and the loop that consumes in one posted drain per burst (the
// network's events): pushes after inbox_close are refused (the caller keeps the value), so a late completion never
// reaches a consumer that is gone.

import "core:sync"
import "core:thread"
import "wb:base"

// Values per block: a block is a little more than this many values, allocated once per as many pushes at most.
MPSC_BLOCK_SLOTS :: 63

// Emptied blocks a queue keeps for its next ones: a producer as far ahead of the consumer as this many blocks allocates
// none (more go back to the heap).
MPSC_SPARES :: 4

// Positions per block: its slots, then one that no push takes (the next block is being linked while the tail is on it).
@(private) MPSC_LAP :: MPSC_BLOCK_SLOTS + 1

// Bytes between the producers' fields and the consumer's: each its own cache line.
@(private) CACHE_LINE :: 64

Mpsc_Slot :: struct($T: typeid) {
	value:   T,
	written: int,   // atomic: the position the value was pushed at, + 1 (a block used again holds older ones: no reset)
}

Mpsc_Block :: struct($T: typeid) {
	next:  ^Mpsc_Block(T),   // atomic: linked by the producer of the last slot, before it writes that slot
	slots: [MPSC_BLOCK_SLOTS]Mpsc_Slot(T),
}

Mpsc :: struct($T: typeid) {
	// producers
	tail:       int,               // atomic: the next position to claim
	tail_block: ^Mpsc_Block(T),    // atomic: the block of `tail`
	spares:     [MPSC_SPARES]^Mpsc_Block(T),   // atomic, each taken by an exchange: emptied blocks for the next ones
	_:          [CACHE_LINE]u8,
	// the consumer
	head:       int,
	head_block: ^Mpsc_Block(T),
}

// Blocks come from the process's heap: producers are any thread.
mpsc_init :: proc(q: ^Mpsc($T)) {
	b := new(Mpsc_Block(T), base.process_allocator())
	q^ = {tail_block = b, head_block = b}
}

// The consumer, once no producer is left. What is still queued is dropped (pop it first to free what it owns).
mpsc_destroy :: proc(q: ^Mpsc($T)) {
	a := base.process_allocator()
	free(q.head_block, a)
	for s in q.spares { free(s, a) }
	q^ = {}
}

// Any thread.
mpsc_push :: proc(q: ^Mpsc($T), v: T) {
	fresh: ^Mpsc_Block(T)   // the next block, made before claiming a block's last slot
	for {
		tail := sync.atomic_load(&q.tail)
		block := sync.atomic_load(&q.tail_block)
		offset := tail % MPSC_LAP
		if offset == MPSC_BLOCK_SLOTS { thread.yield(); continue }   // the claimer of the last slot is linking the next block
		last := offset + 1 == MPSC_BLOCK_SLOTS
		if last && fresh == nil { fresh = spare_take(q) }
		if _, ok := sync.atomic_compare_exchange_weak(&q.tail, tail, tail + 1); !ok { continue }
		if last {
			sync.atomic_store(&q.tail_block, fresh)
			sync.atomic_store(&q.tail, tail + 2)   // past the position no push takes
			sync.atomic_store(&block.next, fresh)
			fresh = nil
		}
		slot := &block.slots[offset]
		slot.value = v
		sync.atomic_store(&slot.written, tail + 1)
		if fresh != nil { spare_put(q, fresh) }   // made for a last slot another producer claimed
		return
	}
}

// Any thread. Where the next push goes: mpsc_pop(q, before = this) takes only what was pushed until now.
mpsc_mark :: proc(q: ^Mpsc($T)) -> int { return sync.atomic_load(&q.tail) }

// The consumer. The oldest value; not ok when the queue is empty, that value is still being written, or it was pushed
// at or after the mark `before`.
mpsc_pop :: proc(q: ^Mpsc($T), before := max(int)) -> (v: T, ok: bool) {
	block := q.head_block
	if q.head >= before || block == nil { return }   // (nil: destroyed, and a drain posted before still runs)
	offset := q.head % MPSC_LAP   // (never the position no push takes: the head skips it with the block)
	slot := &block.slots[offset]
	if sync.atomic_load(&slot.written) != q.head + 1 { return }
	v = slot.value
	q.head += 1
	if offset + 1 == MPSC_BLOCK_SLOTS {
		q.head_block = sync.atomic_load(&block.next)   // linked before this last slot was written
		q.head += 1
		block.next = nil
		spare_put(q, block)
	}
	return v, true
}

@(private)
spare_take :: proc(q: ^Mpsc($T)) -> ^Mpsc_Block(T) {
	for &s in q.spares {
		if b := sync.atomic_exchange(&s, nil); b != nil { return b }
	}
	return new(Mpsc_Block(T), base.process_allocator())
}

// An emptied block (next nil) becomes a spare, or goes when there are enough.
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

// Loop thread, once closed. What is still queued is dropped (pop it first).
inbox_destroy :: proc(b: ^Inbox($T)) { mpsc_destroy(&b.queue) }

// Any thread. Pushes `v` and posts `drain(data)` to the loop unless a drain is already posted. False when the inbox is
// closed: `v` is still the caller's.
inbox_push :: proc(l: ^Loop, b: ^Inbox($T), v: T, drain: Task_Proc, data: rawptr, by := #caller_location) -> bool {
	defer sync.atomic_sub(&b.gate, INBOX_PRODUCER)
	if sync.atomic_add(&b.gate, INBOX_PRODUCER) & INBOX_CLOSED != 0 { return false }
	mpsc_push(&b.queue, v)
	if _, first := sync.atomic_compare_exchange_strong(&b.posted, false, true); first { post(l, drain, data, by) }
	return true
}

// Loop thread, first thing in the drain: a push from now on posts a drain of its own (this one finds it, or the next).
inbox_begin :: proc(b: ^Inbox($T)) { sync.atomic_store(&b.posted, false) }

// Loop thread (mpsc_mark, mpsc_pop).
inbox_mark :: proc(b: ^Inbox($T)) -> int { return mpsc_mark(&b.queue) }
inbox_pop :: proc(b: ^Inbox($T), before := max(int)) -> (v: T, ok: bool) { return mpsc_pop(&b.queue, before) }

// Loop thread. Once it returns, no push succeeds and none is under way (it waits for those inside, a few instructions
// each). Returns whether a drain is still posted: it will run, and must find the inbox's owner alive.
inbox_close :: proc(b: ^Inbox($T)) -> (drain_posted: bool) {
	sync.atomic_or(&b.gate, INBOX_CLOSED)
	for sync.atomic_load(&b.gate) != INBOX_CLOSED { thread.yield() }
	return bool(sync.atomic_load(&b.posted))
}

inbox_closed :: proc(b: ^Inbox($T)) -> bool { return sync.atomic_load(&b.gate) & INBOX_CLOSED != 0 }
