package fetch

// The text/event-stream parser (HTML §9.2.6), streaming: bytes arrive in arbitrary chunks and every boundary case of the
// format (a CR at the end of one chunk and its LF in the next, a UTF-8 sequence cut in two, a BOM) behaves as if the
// stream had arrived in one piece.
//
//   * Decoding: the WHATWG UTF-8 decoder (invalid sequences become U+FFFD), one leading BOM stripped per stream.
//   * Lines end with CR LF, LF or CR. An empty line dispatches; a line starting with ':' is a comment.
//   * Fields: data (appended with a LF), event, id (ignored when it contains NUL), retry (ASCII digits only); others are
//     ignored. The last event ID survives reconnections, the rest of the state does not (`sse_reset_stream`).
//   * Memory: a line or an event's data longer than `max_bytes` makes `sse_feed` fail (the caller fails the connection).

import "core:strings"
import "core:unicode/utf8"

Sse_Event :: struct {
	type:          string,   // "message" unless the event named itself
	data:          string,
	last_event_id: string,
}

Sse_Parser :: struct {
	max_bytes:      int,
	// decoder (WHATWG UTF-8 decode)
	code_point:     rune,
	bytes_needed:   int,
	bytes_seen:     int,
	lower, upper:   u8,
	at_start:       bool,   // nothing decoded yet in this stream: a BOM is dropped
	// lines
	line:           [dynamic]u8,
	last_cr:        bool,
	// event being built
	data:           [dynamic]u8,
	event_type:     [dynamic]u8,
	id_buffer:      [dynamic]u8,
	// survives reconnection
	last_event_id:  string,   // owned
	retry_ms:       int,      // -1 until a retry field arrived
	retry_changed:  bool,     // set by a retry field, cleared by the caller
}

sse_parser_init :: proc(p: ^Sse_Parser, max_bytes: int) {
	p.max_bytes = max(max_bytes, 64)
	p.retry_ms = -1
	sse_reset_stream(p)
}

sse_parser_destroy :: proc(p: ^Sse_Parser) {
	delete(p.line); delete(p.data); delete(p.event_type); delete(p.id_buffer)
	delete(p.last_event_id)
	p^ = {}
}

// A new response begins (reconnection): decoder, line and the three buffers start over (the specification initialises
// them to the empty string per stream). The last event ID string stays until a dispatch overwrites it.
sse_reset_stream :: proc(p: ^Sse_Parser) {
	p.code_point, p.bytes_needed, p.bytes_seen = 0, 0, 0
	p.lower, p.upper = 0x80, 0xBF
	p.at_start = true
	p.last_cr = false
	clear(&p.line)
	clear(&p.data)
	clear(&p.event_type)
	clear(&p.id_buffer)
}

// Parses a chunk; dispatched events are appended to `out` (strings from `allocator`). False when a bound was exceeded.
sse_feed :: proc(p: ^Sse_Parser, chunk: []byte, out: ^[dynamic]Sse_Event, allocator := context.temp_allocator) -> bool {
	for i := 0; i < len(chunk); {
		b := chunk[i]
		if p.bytes_needed == 0 {
			i += 1
			switch b {
			case 0x00 ..= 0x7F:
				if !sse_char(p, rune(b), out, allocator) { return false }
			case 0xC2 ..= 0xDF:
				p.bytes_needed, p.code_point = 1, rune(b & 0x1F)
			case 0xE0 ..= 0xEF:
				if b == 0xE0 { p.lower = 0xA0 }
				if b == 0xED { p.upper = 0x9F }
				p.bytes_needed, p.code_point = 2, rune(b & 0x0F)
			case 0xF0 ..= 0xF4:
				if b == 0xF0 { p.lower = 0x90 }
				if b == 0xF4 { p.upper = 0x8F }
				p.bytes_needed, p.code_point = 3, rune(b & 0x07)
			case:
				if !sse_char(p, utf8.RUNE_ERROR, out, allocator) { return false }
			}
			continue
		}
		if b < p.lower || b > p.upper {
			// the byte is not consumed: it starts over as a lead byte
			p.code_point, p.bytes_needed, p.bytes_seen = 0, 0, 0
			p.lower, p.upper = 0x80, 0xBF
			if !sse_char(p, utf8.RUNE_ERROR, out, allocator) { return false }
			continue
		}
		i += 1
		p.lower, p.upper = 0x80, 0xBF
		p.code_point = p.code_point << 6 | rune(b & 0x3F)
		p.bytes_seen += 1
		if p.bytes_seen == p.bytes_needed {
			r := p.code_point
			p.code_point, p.bytes_needed, p.bytes_seen = 0, 0, 0
			if !sse_char(p, r, out, allocator) { return false }
		}
	}
	return true
}

// End of the response body. An event not terminated by an empty line is discarded, as the specification says; a
// sequence cut by the end becomes U+FFFD in a line that is never completed, so nothing is dispatched either.
sse_end :: proc(p: ^Sse_Parser) {
	sse_reset_stream(p)
}

@(private)
sse_char :: proc(p: ^Sse_Parser, r: rune, out: ^[dynamic]Sse_Event, allocator := context.temp_allocator) -> bool {
	if p.at_start {
		p.at_start = false
		if r == 0xFEFF { return true }
	}
	switch r {
	case '\r':
		p.last_cr = true
		return sse_line(p, out, allocator)
	case '\n':
		if p.last_cr { p.last_cr = false; return true }   // the LF of a CR LF pair
		return sse_line(p, out, allocator)
	}
	p.last_cr = false
	if len(p.line) + 4 > p.max_bytes { return false }
	if r < 0x80 {
		append(&p.line, u8(r))
	} else {
		bytes, n := utf8.encode_rune(r)
		append(&p.line, ..bytes[:n])
	}
	return true
}

@(private)
sse_line :: proc(p: ^Sse_Parser, out: ^[dynamic]Sse_Event, allocator := context.temp_allocator) -> bool {
	line := string(p.line[:])
	defer clear(&p.line)
	if line == "" { sse_dispatch(p, out, allocator); return true }
	if line[0] == ':' { return true }
	field, value := line, ""
	if c := strings.index_byte(line, ':'); c >= 0 {
		field, value = line[:c], line[c + 1:]
		if len(value) > 0 && value[0] == ' ' { value = value[1:] }
	}
	switch field {
	case "event":
		clear(&p.event_type)
		append(&p.event_type, value)
	case "data":
		if len(p.data) + len(value) + 1 > p.max_bytes { return false }
		append(&p.data, value)
		append(&p.data, '\n')
	case "id":
		if strings.index_byte(value, 0) < 0 {
			clear(&p.id_buffer)
			append(&p.id_buffer, value)
		}
	case "retry":
		if value == "" { break }
		n := 0
		for c in transmute([]u8)value {
			if c < '0' || c > '9' { return true }
			n = n > (max(int) - 9) / 10 ? max(int) : n * 10 + int(c - '0')
		}
		p.retry_ms = n
		p.retry_changed = true
	}
	return true
}

@(private)
sse_dispatch :: proc(p: ^Sse_Parser, out: ^[dynamic]Sse_Event, allocator := context.temp_allocator) {
	if string(p.id_buffer[:]) != p.last_event_id {
		delete(p.last_event_id)
		p.last_event_id = strings.clone(string(p.id_buffer[:]))
	}
	defer { clear(&p.data); clear(&p.event_type) }
	if len(p.data) == 0 { return }
	data := string(p.data[:len(p.data) - 1])   // the last LF
	type := len(p.event_type) > 0 ? string(p.event_type[:]) : "message"
	append(out, Sse_Event{
		type = strings.clone(type, allocator), data = strings.clone(data, allocator),
		last_event_id = strings.clone(p.last_event_id, allocator),
	})
}
