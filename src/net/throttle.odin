package net

// Network throttling (the developer tools' Network speed): a link a request (or a WebSocket) goes through, with a download
// and an upload rate shared by everything that uses it, a latency added to each request, and a loss rate. Nothing here
// slows the OS down: the answer's events (headers, pieces of the body, the end) are delivered to the page later, when the
// bytes would have crossed such a link, and a request starts after its latency and the time its body needs to go up. The
// link is the caller's (one per tab); a request holds a pointer to it from its start to its end.
//
//   * Rate: the bytes of a direction go one after the other through the link; a piece of n bytes leaves at
//     max(now, when the link is free) + n / rate. The link is free again at that moment.
//   * Latency: added once to the start of each request (a round trip for the request and the first byte of its answer).
//   * Loss: each packet (1460 bytes) of a piece is lost with probability `loss`; a lost packet is sent again after a
//     retransmission timeout (3 x the latency, at least 200 ms), which delays the piece.

Throttle_Link :: struct {
	down_bps, up_bps:   f64,   // bytes per second; 0 = no limit
	latency_ms:         f32,
	loss:               f32,   // 0 .. 1, per packet
	down_free, up_free: f64,   // when (loop clock, ms) the link can take the next byte
	rng:                u64,   // the lost packets' pseudo-random numbers (xorshift)
}

THROTTLE_PACKET :: 1460

// kbit/s to bytes/s.
throttle_kbps :: proc(kbps: f64) -> f64 { return kbps * 1000 / 8 }

link_random :: proc(l: ^Throttle_Link) -> f32 {
	if l.rng == 0 { l.rng = 0x9E3779B97F4A7C15 }
	x := l.rng
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	l.rng = x
	return f32(x >> 40) / f32(1 << 24)
}

// The extra time lost packets add to a piece of `bytes` bytes.
link_loss_ms :: proc(l: ^Throttle_Link, bytes: int) -> f64 {
	if l.loss <= 0 || bytes <= 0 { return 0 }
	packets := min((bytes + THROTTLE_PACKET - 1) / THROTTLE_PACKET, 64)
	rto := f64(max(l.latency_ms * 3, 200))
	extra: f64
	for _ in 0 ..< packets { if link_random(l) < l.loss { extra += rto } }
	return min(extra, 5000)
}

// When a piece of `bytes` bytes is through the link in the given direction (loop clock, ms); the link is busy until then.
link_schedule :: proc(l: ^Throttle_Link, now: f64, bytes: int, up: bool) -> f64 {
	rate := up ? l.up_bps : l.down_bps
	free := up ? &l.up_free : &l.down_free
	start := max(now, free^)
	end := start
	if rate > 0 { end += f64(bytes) / rate * 1000 }
	free^ = end
	return end + link_loss_ms(l, bytes)
}

// Whether the link changes anything.
link_active :: proc(l: ^Throttle_Link) -> bool {
	return l != nil && (l.down_bps > 0 || l.up_bps > 0 || l.latency_ms > 0 || l.loss > 0)
}
