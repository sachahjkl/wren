package idb

import "base:runtime"

// Values on the disk. A record's key and index keys are in memory; its value is, until the journal has it, and afterwards
// only when it is among the most recently used (a list through the records, Data.cache_limit bytes): any other is read from the
// journal at (voff, vlen) when a request asks for it, straight into the reply. A transaction keeps a Value_Ref for each value it
// put, and when its record is on the disk they get their place in the file (values_commit) and join the cache.

// Where the values are read from: the journal files by generation parity (during a compaction the old and the new one).
Value_Source :: struct {
	files: [2]File,
}

// A value put by a transaction: found again by store and key when the transaction is written; `ptr` tells that the record is
// still the one that was put (not replaced, not deleted meanwhile).
Value_Ref :: struct {
	store: u32,
	key:   []byte,   // a copy
	ptr:   rawptr,   // the record's value in memory
	rel:   int,      // where the value is in the transaction's ops
	len:   u32,
}

////////////////////////////////
// The cache of values

@(private)
cache_unlink :: proc(d: ^Data, r: ^Record) {
	if r.lru_prev != nil { r.lru_prev.lru_next = r.lru_next } else { d.lru_head = r.lru_next }
	if r.lru_next != nil { r.lru_next.lru_prev = r.lru_prev } else { d.lru_tail = r.lru_prev }
	r.lru_prev, r.lru_next = nil, nil
	r.cached = false
	d.cache_bytes -= i64(r.vlen)
}

@(private)
cache_push_front :: proc(d: ^Data, r: ^Record) {
	r.lru_prev = nil
	r.lru_next = d.lru_head
	if d.lru_head != nil { d.lru_head.lru_prev = r }
	d.lru_head = r
	if d.lru_tail == nil { d.lru_tail = r }
	r.cached = true
	d.cache_bytes += i64(r.vlen)
}

// A value on the disk that is also in memory (r.value set): counted, and the least recently used go when over the limit.
@(private)
cache_add :: proc(d: ^Data, r: ^Record) {
	if r.cached { cache_unlink(d, r) }
	cache_push_front(d, r)
	for d.cache_bytes > d.cache_limit && d.lru_tail != nil && d.lru_tail != r {
		v := d.lru_tail
		cache_unlink(d, v)
		delete(v.value, d.allocator)
		v.value = nil
	}
	if d.cache_bytes > d.cache_limit && d.lru_tail == r {   // alone and too big: not kept
		cache_unlink(d, r)
		delete(r.value, d.allocator)
		r.value = nil
	}
}

@(private)
cache_touch :: proc(d: ^Data, r: ^Record) {
	if d.lru_head == r { return }
	cache_unlink(d, r)
	cache_push_front(d, r)
}

// Drops every cached value (the files are about to change, or the data is).
@(private)
cache_drop_all :: proc(d: ^Data) {
	for d.lru_tail != nil {
		v := d.lru_tail
		cache_unlink(d, v)
		delete(v.value, d.allocator)
		v.value = nil
	}
}

////////////////////////////////
// Reading

// The value in a writer as a length-prefixed byte string (a reply): from memory, else from the journal straight into the
// writer. Small ones read from the disk join the cache.
w_value :: proc(d: ^Data, w: ^Writer, r: ^Record) -> Error {
	n := int(r.vlen)
	if r.value != nil || n == 0 || d.vsrc == nil {
		w_uv(w, u64(n))
		if n > 0 { append(&w.data, ..r.value[:n]) }
		if r.cached { cache_touch(d, r) }
		return .None
	}
	mark := len(w.data)
	w_uv(w, u64(n))
	start := len(w.data)
	resize(&w.data, start + n)
	if !file_read_at(d.vsrc.files[r.gen & 1], r.voff, w.data[start:]) {
		resize(&w.data, mark)
		return .Io
	}
	if i64(n) <= d.cache_limit / 16 {
		keep := make([]byte, n, d.allocator)
		copy(keep, w.data[start:])
		r.value = keep
		cache_add(d, r)
	}
	return .None
}

// The value as bytes (copied to `allocator` when read from the disk).
rec_value :: proc(d: ^Data, r: ^Record, allocator := context.temp_allocator) -> (value: []byte, ok: bool) {
	n := int(r.vlen)
	if r.value != nil { return r.value[:n], true }
	if n == 0 { return nil, true }
	if d.vsrc == nil { return nil, false }
	buf := make([]byte, n, allocator)
	if !file_read_at(d.vsrc.files[r.gen & 1], r.voff, buf) { delete(buf, allocator); return nil, false }
	return buf, true
}

_ :: runtime
