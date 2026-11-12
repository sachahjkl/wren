package wren_net

// A first-in first-out queue over a dynamic array and a head index: taking the first item is an index step, not a move
// of every item behind it (ordered_remove(..., 0) made draining a queue of n items cost n^2 / 2 moves). The slots before
// the head are given back when the queue empties, or when they are more than half of it: each item moves at most once.
Fifo :: struct($T: typeid) {
	items: [dynamic]T,
	head:  int,
}

fifo_len :: proc(q: ^Fifo($T)) -> int { return len(q.items) - q.head }

fifo_push :: proc(q: ^Fifo($T), v: T) { append(&q.items, v) }

// The first item (the queue must not be empty).
fifo_front :: proc(q: ^Fifo($T)) -> ^T { return &q.items[q.head] }

// The last item (the queue must not be empty).
fifo_back :: proc(q: ^Fifo($T)) -> ^T { return &q.items[len(q.items) - 1] }

// The items, first to last.
fifo_slice :: proc(q: ^Fifo($T)) -> []T { return q.items[q.head:] }

// Takes the first item (the queue must not be empty).
fifo_pop :: proc(q: ^Fifo($T)) -> T {
	v := q.items[q.head]
	q.items[q.head] = {}
	q.head += 1
	if q.head == len(q.items) {
		clear(&q.items)
		q.head = 0
	} else if q.head > len(q.items) / 2 {
		n := copy(q.items[:], q.items[q.head:])
		resize(&q.items, n)
		q.head = 0
	}
	return v
}

// Forgets every item (what they own is the caller's to free first).
fifo_clear :: proc(q: ^Fifo($T)) {
	clear(&q.items)
	q.head = 0
}

fifo_destroy :: proc(q: ^Fifo($T)) {
	delete(q.items)
	q^ = {}
}
