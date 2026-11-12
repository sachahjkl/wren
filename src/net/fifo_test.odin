package wren_net

import "core:testing"

// Taking from the head keeps the order and gives the space back: the array never holds more than the items waiting
// plus as many taken ones.
@(test)
fifo_keeps_order_and_gives_space_back :: proc(t: ^testing.T) {
	q: Fifo(int)
	defer fifo_destroy(&q)
	for i in 0 ..< 1000 { fifo_push(&q, i) }
	for i in 0 ..< 700 {
		testing.expect_value(t, fifo_pop(&q), i)
		testing.expect(t, len(q.items) <= 2 * fifo_len(&q) + 1, "the taken slots are given back")
	}
	testing.expect_value(t, fifo_len(&q), 300)
	testing.expect_value(t, fifo_front(&q)^, 700)
	testing.expect_value(t, fifo_back(&q)^, 999)
	fifo_push(&q, 1000)
	n := 0
	for v, i in fifo_slice(&q) { if v == 700 + i { n += 1 } }
	testing.expect_value(t, n, 301)
	for fifo_len(&q) > 0 { fifo_pop(&q) }
	testing.expect_value(t, len(q.items), 0)
	testing.expect_value(t, q.head, 0)
}
