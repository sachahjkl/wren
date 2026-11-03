package style

import "core:strings"
import "wb:base"
import "wb:dom"

// Identical styles shared: a computed style is a value, and elements whose inputs are equal get one record.
//
// What an element's style is made of: its parent's style (the record: inherited values, custom properties, the query
// containers above it, the writing mode its flow-relative properties map by), the declarations that match it (its
// matched entries: rule, selector, encapsulation context; for the element and its styled pseudo-elements), its
// style attribute (by text), its encapsulation depth, and what is the same for the whole pass (the rules, the media
// environment and viewport, the page's color scheme, the settings). Two elements of one pass with equal inputs have
// equal styles; the second gets the record made for the first. The table maps the inputs to that record. It is not a
// cache: it holds the values the pass made, as long as the pass that made them, nothing in it is ever stale or
// invalidated, and a lookup that finds nothing costs what styling cost before it.
//
// Some styles depend on the element beyond those inputs; they are made for it alone and never put in the table:
// - the element: presentational hints (its attributes as declarations), a `lang` or `xml:lang` other than its parent's
//   language, an element the embedder hides, an ancestor of the top layer (share_eligible);
// - the style: a query container (its size is the element's), position-try fallbacks (tried against the element's own
//   anchors), a list marker that shows a counter, generated content with attr(), counters or quotes (resolved per
//   element in tree order) (share_value_ok).
// A record in the table is never written after it is put there: what generated content and markers resolve to is
// resolved when it is made (resolve_static), and the walks that resolve them again write only a value that differs
// (counters.odin), which for such a record never happens.

// The table's first size in slots (a power of two, small: a partial restyle of one element makes one too), and how full
// it gets (SHARE_LOAD_NUM / SHARE_LOAD_DEN) before it doubles.
SHARE_MIN_SLOTS :: 16
SHARE_LOAD_NUM :: 3
SHARE_LOAD_DEN :: 4
// FNV-1a over the key's words and the style attribute's bytes.
SHARE_HASH_SEED :: u64(0xcbf29ce484222325)
SHARE_HASH_PRIME :: u64(0x100000001b3)

@(private)
Share_Slot :: struct {
	hash:   u64,
	style:  ^Computed,   // nil: a free slot
	words:  [2]u32,      // its key: Share_Table.words[words[0]:words[1]]
	inline: string,      // its style attribute ("": none)
}

// The styles a pass made that others may share, by their inputs (open addressing, the slots a power of two long).
@(private)
Share_Table :: struct {
	slots: [dynamic]Share_Slot,
	count: int,                // records put so far
	words: [dynamic]uintptr,   // the keys of the slots, one after the other
	key:   [dynamic]uintptr,   // the key of the element being styled (share_key)
	hash:  u64,                // ... its hash, the style attribute's text included
	last:  int,                // the slot of the last one
}

@(private)
share_destroy :: proc(t: ^Share_Table) {
	delete(t.slots)
	delete(t.words)
	delete(t.key)
	t^ = {}
}

// The element's style depends on nothing of its own beyond what share_key puts in the key.
@(private)
share_eligible :: proc(p: ^Pass, h: base.Handle, n: ^dom.Node, parent: ^Computed, hinted: bool) -> bool {
	if hinted { return false }
	if len(p.e.forced_hidden) > 0 && h in p.e.forced_hidden { return false }
	if len(p.fs_chain) > 0 && h in p.fs_chain { return false }
	if in_top_layer(p, h) { return false }   // (its ::backdrop is its own)
	lv, has := attr(n, "lang")
	if !has { lv, has = attr(n, "xml:lang") }
	if has && strings.trim_space(lv) != (parent != nil ? parent.content_language : "") { return false }
	return true
}

// Nothing in the style made for an element is that element's alone.
@(private)
share_value_ok :: proc(c: ^Computed) -> bool {
	if c.container_type != .Normal || len(c.position_try_fallbacks) > 0 { return false }
	if c.display == .List_Item && marker_needs_counter(c.list_style) { return false }
	for x in ([3]^Computed{c, c.before, c.after}) {
		if x == nil { continue }
		for part in x.content.parts { if part.kind != .Text && part.kind != .Url { return false } }
	}
	return true
}

// The key of the element being styled: its parent's record, its encapsulation depth and what it matched (p.lists).
@(private)
share_key :: proc(t: ^Share_Table, parent: ^Computed, depth: u16, lists: ^[Entry_List][dynamic]Entry, inline: string) {
	clear(&t.key)
	append(&t.key, uintptr(rawptr(parent)), uintptr(depth))
	for &l in lists { append(&t.key, uintptr(len(l))) }
	for &l in lists {
		for &ent in l { append(&t.key, uintptr(rawptr(ent.rule)), uintptr(rawptr(ent.complex)), uintptr(ent.ctx)) }
	}
	h := SHARE_HASH_SEED
	for w in t.key { h = (h ~ u64(w)) * SHARE_HASH_PRIME }
	for i in 0 ..< len(inline) { h = (h ~ u64(inline[i])) * SHARE_HASH_PRIME }
	t.hash = h
}

// The record made for the inputs of the last share_key, if any.
@(private)
share_find :: proc(t: ^Share_Table, inline: string) -> ^Computed {
	if len(t.slots) == 0 { return nil }
	mask := len(t.slots) - 1
	for i := int(t.hash) & mask; ; i = (i + 1) & mask {
		sl := &t.slots[i]
		if sl.style == nil { return nil }
		if sl.hash != t.hash || sl.inline != inline || int(sl.words[1] - sl.words[0]) != len(t.key) { continue }
		if words_equal(t.words[sl.words[0]:sl.words[1]], t.key[:]) { return sl.style }
	}
}

// `c` is the style of the inputs of the last share_key.
@(private)
share_put :: proc(t: ^Share_Table, inline: string, c: ^Computed) {
	if (t.count + 1) * SHARE_LOAD_DEN > len(t.slots) * SHARE_LOAD_NUM { share_grow(t) }
	at := u32(len(t.words))
	append(&t.words, ..t.key[:])
	mask := len(t.slots) - 1
	i := int(t.hash) & mask
	for t.slots[i].style != nil { i = (i + 1) & mask }
	t.slots[i] = Share_Slot{hash = t.hash, style = c, words = {at, u32(len(t.words))}, inline = inline}
	t.count += 1
	t.last = i
}

// The record last put is replaced by `c`, a record of the same value (a restyle keeps the equal record in force and
// drops the memory of the one it made).
@(private)
share_replace_last :: proc(t: ^Share_Table, c: ^Computed) { t.slots[t.last].style = c }

@(private = "file")
share_grow :: proc(t: ^Share_Table) {
	old := t.slots
	t.slots = make([dynamic]Share_Slot, max(SHARE_MIN_SLOTS, 2 * len(old)))   // (the arrays are used on the thread of the pass)
	mask := len(t.slots) - 1
	for sl in old {
		if sl.style == nil { continue }
		i := int(sl.hash) & mask
		for t.slots[i].style != nil { i = (i + 1) & mask }
		t.slots[i] = sl
	}
	delete(old)
}

@(private = "file")
words_equal :: proc(a, b: []uintptr) -> bool {
	for w, i in a { if w != b[i] { return false } }
	return true
}
