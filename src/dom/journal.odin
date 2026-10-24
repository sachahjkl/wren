package dom

import "base:runtime"
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
	watch:    u64,           // Remove of an element that was in the document: which of the watched features (Watch) its subtree held, WATCH_KNOWN set; 0: not known
	watch_gen: u32,          // the Watch generation the bits are of
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
	watch:   Watch,
}

// Starts recording (again with a new bound: max_entries >= 16). The journal covers the mutations from now on.
journal_enable :: proc(d: ^Document, max_entries: int) {
	j := &d.journal
	j.max = max(max_entries, 16)
	if j.on { return }
	j.on = true
	j.from = d.mutations
	clear(&j.entries)
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
	watch_free(&j.watch)
	if j.names_ready { virtual.arena_destroy(&j.names); j.names_ready = false }
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
journal_record :: proc(d: ^Document, kind: Journal_Kind, node, parent: base.Handle, name := "", old := "", had_old := false, prev := base.NIL_HANDLE, next := base.NIL_HANDLE, watch := u64(0)) {
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
		remove_range(&j.entries, 0, drop)
		if j.names_ready && len(j.entries) == 0 { virtual.arena_free_all(&j.names) }
	}
	nm := ""
	if name != "" {
		if !j.names_ready { _ = virtual.arena_init_growing(&j.names, 4096); j.names_ready = true }
		if len(j.entries) == 0 {
			virtual.arena_free_all(&j.names)
		} else if int(j.names.total_used) > 64 * j.max + 4096 {
			// names of forgotten entries add up: keep only those still referenced
			fresh: virtual.Arena
			_ = virtual.arena_init_growing(&fresh, 4096)
			for &e in j.entries {
				if e.name != "" { e.name = strings.clone(e.name, virtual.arena_allocator(&fresh)) }
				if e.old != "" { e.old = strings.clone(e.old, virtual.arena_allocator(&fresh)) }
			}
			virtual.arena_destroy(&j.names)
			j.names = fresh
		}
		nm = strings.clone(name, virtual.arena_allocator(&j.names))
	}
	// the old data of a text change is for the hook only: readers of the journal do not need it
	ov := ""
	if old != "" && kind == .Attribute { ov = strings.clone(old, virtual.arena_allocator(&j.names)) }
	append(&j.entries, Journal_Entry{kind = kind, node = node, parent = parent, prev = prev, next = next, name = nm, old = ov, had_old = had_old, batch = d.batch, mutation = d.mutations, watch = watch, watch_gen = d.journal.watch.gen})
}

////////////////////////////////
// Watched features

// The features the style engine asks about when elements come and go: the keys of the arguments of its :has() anchors (tag
// names, attribute names, ids and classes). Each gets a bit (up to 62; the rest share the last one), and a Remove entry of the
// journal says which of them the removed subtree held: a node already destroyed when the engine looks at the journal has
// still told what it carried. Set by the style engine (watch_reset, watch_bit); a new generation when it changes them, and
// the entries of an older one say nothing.
Watch :: struct {
	gen:       u32,
	on:        bool,
	allocator: runtime.Allocator,
	tags, attrs, ids, classes: map[string]u64,
}

WATCH_KNOWN :: u64(1) << 63

@(private)
watch_free :: proc(w: ^Watch) {
	if w.allocator.procedure == nil { return }
	context.allocator = w.allocator
	for m in ([]^map[string]u64{&w.tags, &w.attrs, &w.ids, &w.classes}) {
		for k in m { delete(k) }
		delete(m^)
	}
	w^ = Watch{gen = w.gen}
}

// Forgets the features watched; the bits handed out so far mean nothing any more.
watch_reset :: proc(d: ^Document) {
	w := &d.journal.watch
	watch_free(w)
	w.gen += 1
	w.on = true
}

// The bit of a feature, watched from now on.
watch_bit :: proc(d: ^Document, kind: Feature, name: string) -> u64 {
	w := &d.journal.watch
	if w.allocator.procedure == nil { w.allocator = context.allocator }
	context.allocator = w.allocator
	m: ^map[string]u64
	switch kind {
	case .Tag: m = &w.tags
	case .Attr: m = &w.attrs
	case .Id: m = &w.ids
	case .Class: m = &w.classes
	}
	if b, ok := m[name]; ok { return b }
	n := len(w.tags) + len(w.attrs) + len(w.ids) + len(w.classes)
	b := u64(1) << u32(min(n, 62))
	m[strings.clone(name)] = b
	return b
}

Feature :: enum u8 { Tag, Attr, Id, Class }

// Which watched features the elements of the subtree of `root` carry (its own tree, not the shadow trees of its elements).
subtree_watch :: proc(d: ^Document, root: base.Handle) -> (bits: u64) {
	w := &d.journal.watch
	bits = WATCH_KNOWN
	if len(w.tags) + len(w.attrs) + len(w.ids) + len(w.classes) == 0 { return }
	stack := make([dynamic]base.Handle, 0, 32, context.temp_allocator)
	append(&stack, root)
	for len(stack) > 0 {
		h := pop(&stack)
		n := get(d, h)
		if n == nil || n.kind != .Element { continue }
		if b, ok := w.tags[n.name]; ok { bits |= b }
		for a in n.attrs {
			if b, ok := w.attrs[a.name]; ok { bits |= b }
			switch a.name {
			case "id": if b, ok := w.ids[a.value]; ok { bits |= b }
			case "class":
				if len(w.classes) == 0 { continue }
				rest := a.value
				for len(rest) > 0 {
					for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n' || rest[0] == '\r' || rest[0] == '\f') { rest = rest[1:] }
					end := 0
					for end < len(rest) && !(rest[end] == ' ' || rest[end] == '\t' || rest[end] == '\n' || rest[end] == '\r' || rest[end] == '\f') { end += 1 }
					if end > 0 { if b, ok := w.classes[rest[:end]]; ok { bits |= b } }
					rest = rest[end:]
				}
			}
		}
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = get(d, ch).next { append(&stack, ch) }
	}
	return
}