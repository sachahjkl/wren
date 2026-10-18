package fetch

import "core:testing"

@(private = "file")
feed_all :: proc(p: ^Sse_Parser, chunks: ..string) -> (events: [dynamic]Sse_Event, ok: bool) {
	events = make([dynamic]Sse_Event, context.temp_allocator)
	ok = true
	for c in chunks { if !sse_feed(p, transmute([]byte)c, &events) { ok = false } }
	return
}

@(private = "file")
parse :: proc(chunks: ..string) -> [dynamic]Sse_Event {
	p: Sse_Parser
	sse_parser_init(&p, 1 << 20)
	defer sse_parser_destroy(&p)
	ev, _ := feed_all(&p, ..chunks)
	return ev
}

@(test)
sse_fields_and_dispatch :: proc(t: ^testing.T) {
	ev := parse("data: hello\n\nevent: ping\ndata: p\nid: 7\n\n: a comment\ndata:no-space\n\n")
	testing.expect_value(t, len(ev), 3)
	testing.expect_value(t, ev[0].type, "message")
	testing.expect_value(t, ev[0].data, "hello")
	testing.expect_value(t, ev[0].last_event_id, "")
	testing.expect_value(t, ev[1].type, "ping")
	testing.expect_value(t, ev[1].last_event_id, "7")
	testing.expect_value(t, ev[2].data, "no-space")
	testing.expect_value(t, ev[2].type, "message")       // the event type does not carry over
	testing.expect_value(t, ev[2].last_event_id, "7")    // the last event ID does
}

@(test)
sse_multiline_data_and_empty_fields :: proc(t: ^testing.T) {
	ev := parse("data: a\ndata\ndata: b\n\n", "data\n\n", "data:\ndata:\n\n", "event: x\n\n")
	testing.expect_value(t, len(ev), 3)
	testing.expect_value(t, ev[0].data, "a\n\nb")
	testing.expect_value(t, ev[1].data, "")           // one empty data line dispatches an empty message
	testing.expect_value(t, ev[2].data, "\n")
	// "event: x" with no data dispatches nothing (and resets the type)
	ev2 := parse("event: x\n\ndata: y\n\n")
	testing.expect_value(t, len(ev2), 1)
	testing.expect_value(t, ev2[0].type, "message")
	// "data:  two" keeps the second space; a field without a colon has an empty value
	ev3 := parse("data:  two\n\n")
	testing.expect_value(t, ev3[0].data, " two")
}

@(test)
sse_line_endings_mixed_and_split :: proc(t: ^testing.T) {
	ev := parse("data: a\r\ndata: b\rdata: c\n\r\n")
	testing.expect_value(t, len(ev), 1)
	testing.expect_value(t, ev[0].data, "a\nb\nc")
	// a CR LF cut between two chunks is still one line end
	ev2 := parse("data: x\r", "\ndata: y\r", "\n\r", "\n")
	testing.expect_value(t, len(ev2), 1)
	testing.expect_value(t, ev2[0].data, "x\ny")
	// CR alone, twice: two line ends = dispatch
	ev3 := parse("data: z\r\r")
	testing.expect_value(t, len(ev3), 1)
	// byte by byte
	s := "id: 1\r\ndata: one\r\n\r\ndata: two\n\n"
	p: Sse_Parser
	sse_parser_init(&p, 1 << 20)
	defer sse_parser_destroy(&p)
	out := make([dynamic]Sse_Event, context.temp_allocator)
	for i in 0 ..< len(s) { sse_feed(&p, transmute([]byte)s[i:i + 1], &out) }
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, out[1].data, "two")
	testing.expect_value(t, out[1].last_event_id, "1")
}

@(test)
sse_bom_and_utf8_streaming :: proc(t: ^testing.T) {
	ev := parse("\xEF\xBB\xBFdata: bom\n\n")
	testing.expect_value(t, len(ev), 1)
	testing.expect_value(t, ev[0].data, "bom")
	// a BOM split over chunks, and only the first one is dropped
	ev2 := parse("\xEF", "\xBB", "\xBF\xEF\xBB\xBFdata: x\n\n")
	testing.expect_value(t, len(ev2), 0)   // the second BOM makes the field name "\uFEFFdata": ignored
	// "é" (C3 A9) and "€" (E2 82 AC) cut between chunks
	ev3 := parse("data: caf\xC3", "\xA9 \xE2\x82", "\xAC\n\n")
	testing.expect_value(t, ev3[0].data, "café €")
	// invalid bytes become U+FFFD; a truncated sequence before ASCII yields one U+FFFD and keeps the ASCII byte
	ev4 := parse("data: \xFF\xE2\x82x\n\n")
	testing.expect_value(t, ev4[0].data, "\uFFFD\uFFFDx")
}

@(test)
sse_id_and_retry_rules :: proc(t: ^testing.T) {
	p: Sse_Parser
	sse_parser_init(&p, 1 << 20)
	defer sse_parser_destroy(&p)
	ev, _ := feed_all(&p, "id: good\ndata: 1\n\nid: bad\x00id\ndata: 2\n\n")
	testing.expect_value(t, ev[1].last_event_id, "good")   // an id with NUL is ignored
	feed_all(&p, "retry: 1500\n", "retry: 12x\n", "retry:\n", "retry: -5\n")
	testing.expect_value(t, p.retry_ms, 1500)               // non-numeric values are ignored
	testing.expect(t, p.retry_changed)
	ev2, _ := feed_all(&p, "id\ndata: 3\n\n")
	testing.expect_value(t, ev2[0].last_event_id, "")       // "id" alone resets it

	// an id followed by the end of the stream is not dispatched: the last event ID string does not change
	q: Sse_Parser
	sse_parser_init(&q, 1 << 20)
	defer sse_parser_destroy(&q)
	feed_all(&q, "id: 5\ndata: a\n\nid: 6\ndata: lost")
	sse_end(&q)
	testing.expect_value(t, q.last_event_id, "5")
	ev3, _ := feed_all(&q, "data: after\n\n")
	testing.expect_value(t, len(ev3), 1)
	testing.expect_value(t, ev3[0].data, "after")   // the cut event did not leak into the next stream
	testing.expect_value(t, ev3[0].last_event_id, "")   // a new stream starts with an empty id buffer
}

@(test)
sse_limits :: proc(t: ^testing.T) {
	p: Sse_Parser
	sse_parser_init(&p, 100)
	defer sse_parser_destroy(&p)
	big := "data: 0123456789012345678901234567890123456789\n"
	_, ok := feed_all(&p, big, big)
	testing.expect(t, ok, "two lines fit")
	_, ok = feed_all(&p, big)
	testing.expect(t, !ok, "the third overflows the data buffer")
	q: Sse_Parser
	sse_parser_init(&q, 100)
	defer sse_parser_destroy(&q)
	long := make([]u8, 200, context.temp_allocator)
	for &c in long { c = 'x' }
	_, ok = feed_all(&q, string(long))
	testing.expect(t, !ok, "a line without end is bounded too")
}
