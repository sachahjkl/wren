package idb

import "base:runtime"
import "core:bytes"

// An ordered map from byte strings to pointers: a sorted list of small sorted blocks (a two-level B-tree).
//
// Keys are compared as bytes (encoded IndexedDB keys are made to sort that way, key.odin). A lookup is a binary search
// over the blocks' last keys and one inside a block; an insertion moves at most BLOCK_MAX entries and, rarely, splits a
// block. It does not keep pointers into itself across changes: a cursor of a script is a pair of keys that the host
// searches again at each step, which is also what keeps it correct when its records change under it.
//
// The map owns a copy of every key; values are the caller's.

BLOCK_MAX :: 128

Block :: struct {
	keys: [dynamic][]byte,
	vals: [dynamic]rawptr,
}

Ordered :: struct {
	blocks:    [dynamic]^Block,
	count:     int,
	allocator: runtime.Allocator,
}

// A position between entries: `block` == len(blocks) is the end.
Pos :: struct { block, index: int }

ordered_init :: proc(o: ^Ordered, allocator: runtime.Allocator) {
	o^ = {allocator = allocator}
	o.blocks = make([dynamic]^Block, allocator)
}

// Frees keys and blocks (not the values).
ordered_destroy :: proc(o: ^Ordered) {
	ordered_clear(o)
	delete(o.blocks)
	o^ = {}
}

ordered_clear :: proc(o: ^Ordered) {
	for b in o.blocks { block_free(o, b) }
	clear(&o.blocks)
	o.count = 0
}

@(private)
block_free :: proc(o: ^Ordered, b: ^Block) {
	for k in b.keys { delete(k, o.allocator) }
	delete(b.keys)
	delete(b.vals)
	free(b, o.allocator)
}

// First entry whose key is >= `key` (> with `strict`); the end when there is none.
ordered_seek :: proc(o: ^Ordered, key: []byte, strict := false) -> Pos {
	lo, hi := 0, len(o.blocks)
	for lo < hi {
		mid := (lo + hi) / 2
		b := o.blocks[mid]
		c := bytes.compare(b.keys[len(b.keys) - 1], key)
		if c < 0 || (strict && c == 0) { lo = mid + 1 } else { hi = mid }
	}
	if lo == len(o.blocks) { return Pos{lo, 0} }
	b := o.blocks[lo]
	l, h := 0, len(b.keys)
	for l < h {
		mid := (l + h) / 2
		c := bytes.compare(b.keys[mid], key)
		if c < 0 || (strict && c == 0) { l = mid + 1 } else { h = mid }
	}
	return Pos{lo, l}
}

ordered_first :: proc(o: ^Ordered) -> Pos { return Pos{0, 0} if len(o.blocks) > 0 else Pos{0, 0} }

ordered_end :: proc(o: ^Ordered) -> Pos { return Pos{len(o.blocks), 0} }

pos_valid :: proc(o: ^Ordered, p: Pos) -> bool { return p.block >= 0 && p.block < len(o.blocks) }

pos_entry :: proc(o: ^Ordered, p: Pos) -> (key: []byte, val: rawptr) {
	b := o.blocks[p.block]
	return b.keys[p.index], b.vals[p.index]
}

pos_next :: proc(o: ^Ordered, p: ^Pos) {
	if p.block >= len(o.blocks) { return }
	p.index += 1
	if p.index >= len(o.blocks[p.block].keys) { p.block += 1; p.index = 0 }
}

// Moves to the entry before; false (and no move) at the first entry. From the end it goes to the last entry.
pos_prev :: proc(o: ^Ordered, p: ^Pos) -> bool {
	if p.index > 0 { p.index -= 1; return true }
	if p.block == 0 { return false }
	p.block -= 1
	p.index = len(o.blocks[p.block].keys) - 1
	return true
}

ordered_get :: proc(o: ^Ordered, key: []byte) -> (val: rawptr, found: bool) {
	p := ordered_seek(o, key)
	if !pos_valid(o, p) { return nil, false }
	k, v := pos_entry(o, p)
	if bytes.equal(k, key) { return v, true }
	return nil, false
}

// Inserts or replaces; returns the value replaced.
ordered_put :: proc(o: ^Ordered, key: []byte, val: rawptr) -> (old: rawptr, replaced: bool) {
	context.allocator = o.allocator
	p := ordered_seek(o, key)
	if len(o.blocks) == 0 {
		b := new(Block)
		b.keys = make([dynamic][]byte)
		b.vals = make([dynamic]rawptr)
		append(&o.blocks, b)
		p = Pos{0, 0}
	} else if p.block == len(o.blocks) {
		p = Pos{len(o.blocks) - 1, len(o.blocks[len(o.blocks) - 1].keys)}   // past every key: the end of the last block
	}
	b := o.blocks[p.block]
	if p.index < len(b.keys) && bytes.equal(b.keys[p.index], key) {
		old = b.vals[p.index]
		b.vals[p.index] = val
		return old, true
	}
	owned := make([]byte, len(key))
	copy(owned, key)
	inject_at(&b.keys, p.index, owned)
	inject_at(&b.vals, p.index, val)
	o.count += 1
	if len(b.keys) > BLOCK_MAX {
		half := len(b.keys) / 2
		nb := new(Block)
		nb.keys = make([dynamic][]byte, 0, BLOCK_MAX)
		nb.vals = make([dynamic]rawptr, 0, BLOCK_MAX)
		append(&nb.keys, ..b.keys[half:])
		append(&nb.vals, ..b.vals[half:])
		resize(&b.keys, half)
		resize(&b.vals, half)
		inject_at(&o.blocks, p.block + 1, nb)
	}
	return nil, false
}

ordered_delete :: proc(o: ^Ordered, key: []byte) -> (old: rawptr, found: bool) {
	p := ordered_seek(o, key)
	if !pos_valid(o, p) { return nil, false }
	b := o.blocks[p.block]
	if !bytes.equal(b.keys[p.index], key) { return nil, false }
	old = b.vals[p.index]
	delete(b.keys[p.index], o.allocator)
	ordered_remove(&b.keys, p.index)
	ordered_remove(&b.vals, p.index)
	o.count -= 1
	if len(b.keys) == 0 {
		block_free(o, b)
		ordered_remove(&o.blocks, p.block)
	}
	return old, true
}

// Checks the invariants (tests): blocks non-empty and sorted, keys strictly increasing across blocks, count right.
ordered_check :: proc(o: ^Ordered) -> bool {
	n := 0
	prev: []byte
	have := false
	for b in o.blocks {
		if len(b.keys) == 0 || len(b.keys) != len(b.vals) || len(b.keys) > BLOCK_MAX { return false }
		for k in b.keys {
			if have && bytes.compare(prev, k) >= 0 { return false }
			prev, have = k, true
			n += 1
		}
	}
	return n == o.count
}
