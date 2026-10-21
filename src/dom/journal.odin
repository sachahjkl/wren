package dom

import "core:mem/virtual"
import "core:strings"
import "wb:base"

// The mutation journal: what changed in the tree, node by node, for readers that update a derived structure instead of
// rebuilding it (an incremental layout). Off until a reader turns it on (`journal_enable`): a document nobody watches
// records nothing.
//
// Each entry carries the value of `Document.mutations` right after its change. A reader remembers the counter it last
// caught up with and takes the entries above it (`journal_since`); any number of readers can share the journal. It is
// bounded: past `max` entries the oldest half is forgotten, and a reader that had not read them is told to start over.

Journal_Kind :: enum u8 {
	Insert,      // `node` was inserted under `parent`
	Remove,      // `node` was removed from `parent` (it may be destroyed since)
	Text,        // the data of text or comment node `node` changed
	Attribute,   // attribute `name` of element `node` was set or removed
	Reslot,      // the flat tree changed without a node-tree mutation (shadow.odin). `parent` NIL: the flat children of
	             // `node` changed (a slot whose assigned nodes did, an element that became a shadow host); else `node`
	             // left its place under `parent` in the flat tree (unassigned, or a fallback child no longer shown).
	             // Readers only: MutationObserver does not see it.
}

Journal_Entry :: struct {
	kind:     Journal_Kind,
	node:     base.Handle,
	parent:   base.Handle,   // Insert / Remove; Text: the node's parent
	prev:     base.Handle,   // Insert / Remove: the node's siblings right after the insertion / before the removal
	next:     base.Handle,
	name:     string,        // Attribute: the name, lower case (owned by the journal)
	old:      string,        // Attribute: the value before the change (owned by the journal), when `had_old`; Text:
	                         // the data before, given to the Mutation_Hook only (not kept in the journal)
	had_old:  bool,          // Attribute: the attribute existed before the change; Text: always
	batch:    u32,           // entries of one DOM operation share it (Document.batch), 0 = an operation of its own
	mutation: u64,
}

// Called for every mutation as it happens, journal on or off (Document.observer). The entry's strings are valid
// during the call only.
Mutation_Hook :: #type proc(user: rawptr, d: ^Document, e: ^Journal_Entry)

Journal :: struct {
	on:      bool,
	max:     int,
	from:    u64,                      // complete for every mutation after this value of `mutations`
	entries: [dynamic]Journal_Entry,
	names:   virtual.Arena,            // attribute names of the entries
	names_ready: bool,
	live_bytes: int,                   // bytes of the names and old values the entries still hold (the rest of the arena is garbage)
	compactions: int,                  // times the names were copied to a fresh arena (tests)
}

// Starts recording (again with a new bound: max_entries >= 16). The journal covers the mutations from now on.
journal_enable :: proc(d: ^Document, max_entries: int) {
	j := &d.journal
	j.max = max(max_entries, 16)
	if j.on { return }
	j.on = true
	j.from = d.mutations
	clear(&j.entries)
	j.live_bytes = 0
}

journal_disable :: proc(d: ^Document) {
	journal_free(d)
	d.journal.on = false
}

@(private)
journal_free :: proc(d: ^Document) {
	j := &d.journal
	delete(j.entries)
	j.entries = nil
	if j.names_ready { virtual.arena_destroy(&j.names); j.names_ready = false }
	j.live_bytes = 0
}

// The entries after `since` (a value of `mutations` the reader caught up with), and whether they are all there (false:
// the journal is off or forgot some; the reader must assume anything changed).
journal_since :: proc(d: ^Document, since: u64) -> ([]Journal_Entry, bool) {
	j := &d.journal
	if !j.on || since < j.from || since > d.mutations { return nil, false }
	lo, hi := 0, len(j.entries)
	for lo < hi {
		mid := (lo + hi) / 2
		if j.entries[mid].mutation <= since { lo = mid + 1 } else { hi = mid }
	}
	return j.entries[lo:], true
}

@(private)
journal_record :: proc(d: ^Document, kind: Journal_Kind, node, parent: base.Handle, name := "", old := "", had_old := false, prev := base.NIL_HANDLE, next := base.NIL_HANDLE) {
	if d.observer != nil && kind != .Reslot && !(kind == .Attribute && name == CUSTOM_STATE_ATTRIBUTE) {
		e := Journal_Entry{kind = kind, node = node, parent = parent, prev = prev, next = next, name = name, old = old, had_old = had_old, batch = d.batch, mutation = d.mutations}
		d.observer(d.observer_user, d, &e)
	}
	j := &d.journal
	if !j.on { return }
	if len(j.entries) >= j.max {
		// forget the older half; names of dropped entries stay in the arena until it is emptied below
		drop := len(j.entries) / 2
		j.from = j.entries[drop - 1].mutation
		for drop < len(j.entries) && j.entries[drop].mutation == j.from { drop += 1 }
		for e in j.entries[:drop] { j.live_bytes -= len(e.name) + len(e.old) }
		remove_range(&j.entries, 0, drop)
		if j.names_ready && len(j.entries) == 0 { virtual.arena_free_all(&j.names) }
	}
	nm := ""
	if name != "" {
		if !j.names_ready { _ = virtual.arena_init_growing(&j.names, 4096); j.names_ready = true }
		if len(j.entries) == 0 {
			virtual.arena_free_all(&j.names)
			j.live_bytes = 0
		} else if int(j.names.total_used) > max(64 * j.max + 4096, 2 * j.live_bytes) {
			// names of forgotten entries add up: keep only those still referenced (when they are at least half of the
			// arena: a journal whose live names alone pass the bound copied them all at every record)
			fresh: virtual.Arena
			_ = virtual.arena_init_growing(&fresh, 4096)
			for &e in j.entries {
				if e.name != "" { e.name = strings.clone(e.name, virtual.arena_allocator(&fresh)) }
				if e.old != "" { e.old = strings.clone(e.old, virtual.arena_allocator(&fresh)) }
			}
			virtual.arena_destroy(&j.names)
			j.names = fresh
			j.compactions += 1
		}
		nm = strings.clone(name, virtual.arena_allocator(&j.names))
	}
	// the old data of a text change is for the hook only: readers of the journal do not need it
	ov := ""
	if old != "" && kind == .Attribute { ov = strings.clone(old, virtual.arena_allocator(&j.names)) }
	j.live_bytes += len(nm) + len(ov)
	append(&j.entries, Journal_Entry{kind = kind, node = node, parent = parent, prev = prev, next = next, name = nm, old = ov, had_old = had_old, batch = d.batch, mutation = d.mutations})
}
