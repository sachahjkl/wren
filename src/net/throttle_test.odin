package net

import "core:testing"

@(test)
throttle_rate_queues_pieces :: proc(t: ^testing.T) {
	l := Throttle_Link{down_bps = 8000}   // 64 kbit/s
	testing.expect_value(t, link_schedule(&l, 0, 4000, false), 500.0)
	testing.expect_value(t, link_schedule(&l, 0, 4000, false), 1000.0)   // the second piece waits for the first
	testing.expect_value(t, link_schedule(&l, 5000, 800, false), 5100.0) // a later piece starts when it arrives
	testing.expect_value(t, link_schedule(&l, 0, 8000, true), 0.0)       // no upload limit
}

@(test)
throttle_directions_are_independent :: proc(t: ^testing.T) {
	l := Throttle_Link{down_bps = 1000, up_bps = 4000}
	testing.expect_value(t, link_schedule(&l, 0, 1000, false), 1000.0)
	testing.expect_value(t, link_schedule(&l, 0, 1000, true), 250.0)
}

@(test)
throttle_loss_costs_timeouts :: proc(t: ^testing.T) {
	none := Throttle_Link{latency_ms = 100}
	testing.expect_value(t, link_loss_ms(&none, 5000), 0.0)
	all := Throttle_Link{latency_ms = 100, loss = 1}
	// every packet lost once: 3 packets of 1460 bytes, each costs 3 x latency
	testing.expect_value(t, link_loss_ms(&all, 3 * THROTTLE_PACKET), 900.0)
	short := Throttle_Link{latency_ms = 10, loss = 1}
	testing.expect_value(t, link_loss_ms(&short, 1), 200.0)   // at least 200 ms
	some := Throttle_Link{latency_ms = 100, loss = 0.5, rng = 12345}
	got := link_loss_ms(&some, 60 * THROTTLE_PACKET)
	testing.expect(t, got > 3000 && got < 15000, "half the packets: about 30 timeouts of 300 ms")
}

@(test)
throttle_active_only_when_it_changes_something :: proc(t: ^testing.T) {
	testing.expect(t, !link_active(nil))
	testing.expect(t, !link_active(&Throttle_Link{}))
	testing.expect(t, link_active(&Throttle_Link{latency_ms = 1}))
	testing.expect(t, link_active(&Throttle_Link{loss = 0.1}))
	testing.expect_value(t, throttle_kbps(8), 1000.0)
}
