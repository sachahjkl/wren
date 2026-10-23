package blocker

import "wb:adblock"

// The request log of the dashboard: a ring of the last requests with what became of them. It records only while a
// dashboard shows it (`armed`) or when blocker.log.always says so: a closed log costs nothing.

Log_Entry :: struct {
	time:    i64,                 // unix ms
	tab:     u64,
	type:    adblock.Resource,
	outcome: Outcome,
	url:     string,              // owned
	doc:     string,              // owned: the document that made the request
	rule:    string,              // owned: the filter text, or the dynamic rule / policy that decided
	filter:  u32,                 // the engine's filter id (adblock.NO_FILTER if none)
	list:    u8,
	engine:  u64,                 // the engine generation `filter` belongs to
}

Journal :: struct {
	entries: [dynamic]Log_Entry,
	start:   int,                 // index of the oldest entry
	cap:     int,
	armed:   bool,
	version: u64,
	total:   u64,                 // entries ever added
}

journal_init :: proc(j: ^Journal, cap: int) {
	j.cap = max(cap, 1)
	j.entries = make([dynamic]Log_Entry, 0, min(j.cap, 1024))
}

journal_destroy :: proc(j: ^Journal) {
	journal_clear(j)
	delete(j.entries)
}

@(private)
log_entry_free :: proc(e: ^Log_Entry) {
	delete(e.url); delete(e.doc); delete(e.rule)
	e^ = {}
}

journal_clear :: proc(j: ^Journal) {
	for &e in j.entries { log_entry_free(&e) }
	clear(&j.entries)
	j.start = 0
	j.version += 1
}

journal_len :: proc(j: ^Journal) -> int { return len(j.entries) }

// 0 = the oldest.
journal_get :: proc(j: ^Journal, i: int) -> ^Log_Entry {
	if i < 0 || i >= len(j.entries) { return nil }
	return &j.entries[(j.start + i) % len(j.entries)]
}

journal_add :: proc(j: ^Journal, e: Log_Entry) {
	c := e
	c.url, c.doc, c.rule = clone_str(e.url), clone_str(e.doc), clone_str(e.rule)
	if len(j.entries) < j.cap {
		append(&j.entries, c)
	} else {
		slot := &j.entries[j.start]
		log_entry_free(slot)
		slot^ = c
		j.start = (j.start + 1) % len(j.entries)
	}
	j.version += 1
	j.total += 1
}

journal_resize :: proc(j: ^Journal, cap: int) {
	// compact into chronological order, then drop the oldest beyond the new capacity
	ordered := make([dynamic]Log_Entry, 0, len(j.entries), context.temp_allocator)
	for i in 0 ..< len(j.entries) { append(&ordered, j.entries[(j.start + i) % len(j.entries)]) }
	drop := max(len(ordered) - max(cap, 1), 0)
	for i in 0 ..< drop { log_entry_free(&ordered[i]) }
	clear(&j.entries)
	append(&j.entries, ..ordered[drop:])
	j.start = 0
	j.cap = max(cap, 1)
	j.version += 1
}
