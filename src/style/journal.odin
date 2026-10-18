package style

import "wb:base"
import "wb:host"

// The layout journal of a style pass: which elements changed style since an earlier pass, and how much layout work
// each change invalidates (Change_Level). An incremental layout reads it to lay out again only what changed.
//
// Entries are added by every way styles change: a full pass compared to the previous one (`journal_diff`), a partial
// restyle after a change of state, a tick of the timeline that moves values layout reads. Each entry carries the serial
// of the styles it is part of; a reader that last saw serial S takes the entries above S. The journal is complete for
// the changes after `from`: a reader older than that must assume everything changed. It only records when the engine
// was asked to (`engine_set_journal`): nobody pays for it otherwise.

Journal_Entry :: struct {
	node:   base.Handle,
	level:  Change_Level,   // Layout or Box (paint-only changes are not recorded: readers re-read every value)
	serial: u64,            // the Styled.serial this change belongs to (0 while the change is being made)
}

Layout_Journal :: struct {
	on:      bool,
	max:     int,               // entries kept at most; past it the oldest are forgotten
	from:    u64,               // complete for every change after the styles of this serial (max(u64): after the next one)
	entries: [dynamic]Journal_Entry,
}

@(private) JOURNAL_PENDING :: max(u64)

// Records layout journals in the passes of `e` from now on (max_entries <= 0: off).
engine_set_journal :: proc(e: ^Engine, max_entries: int) {
	e.journal_max = max(max_entries, 0)
}

@(private)
journal_init :: proc(e: ^Engine, s: ^Styled) {
	s.journal.on = e.journal_max > 0
	s.journal.max = e.journal_max
	s.journal.from = JOURNAL_PENDING   // a new pass knows nothing of what came before, unless journal_diff says
}

@(private)
journal_destroy :: proc(s: ^Styled) {
	delete(s.journal.entries)
	s.journal.entries = nil
}

journal_add :: proc(s: ^Styled, h: base.Handle, level: Change_Level) {
	j := &s.journal
	if !j.on || level < .Layout { return }
	if len(j.entries) >= j.max {
		// too much at once: forget the history; only readers that come after this change can trust the journal
		clear(&j.entries)
		j.from = JOURNAL_PENDING
		return
	}
	append(&j.entries, Journal_Entry{node = h, level = level})
}

// The styles got serial `s.serial`: the changes recorded meanwhile belong to it.
@(private)
journal_stamp :: proc(s: ^Styled) {
	j := &s.journal
	if !j.on { return }
	if j.from == JOURNAL_PENDING { j.from = s.serial }
	for i := len(j.entries) - 1; i >= 0 && j.entries[i].serial == 0; i -= 1 { j.entries[i].serial = s.serial }
	// keep memory bounded: when full, drop the older half (readers that lag behind start over)
	if len(j.entries) > j.max / 2 + j.max / 4 {
		drop := len(j.entries) / 2
		j.from = j.entries[drop - 1].serial
		for drop < len(j.entries) && j.entries[drop].serial == j.from { drop += 1 }
		remove_range(&j.entries, 0, drop)
	}
}

// The changes after serial `since`, and whether the journal covers them all (false: the reader must assume everything
// changed).
journal_since :: proc(s: ^Styled, since: u64) -> ([]Journal_Entry, bool) {
	j := &s.journal
	if !j.on || j.from == JOURNAL_PENDING || since < j.from || since > s.serial { return nil, false }
	lo, hi := 0, len(j.entries)
	for lo < hi {   // entries are in serial order: the first one above `since`
		mid := (lo + hi) / 2
		if j.entries[mid].serial != 0 && j.entries[mid].serial <= since { lo = mid + 1 } else { hi = mid }
	}
	return j.entries[lo:], true
}

////////////////////////////////
// A full pass compared with the previous one

@(private = "file")
Diff_Job :: struct {
	old, new: ^Styled,
	n:        int,
	chunk:    int,
	out:      [][dynamic]Journal_Entry,
}

@(private = "file")
diff_chunk :: proc(data: rawptr, index: int) {
	job := (^Diff_Job)(data)
	lo := index * job.chunk
	hi := min(lo + job.chunk, job.n)
	out := &job.out[index]
	for i in lo ..< hi {
		c := job.new.by_node[i]
		if c == nil { continue }
		h := c.node
		old := i < len(job.old.by_node) ? job.old.by_node[i] : nil
		if old != nil && old.node != h { old = nil }
		if old != nil && len(job.old.overlaid) > 0 { if b, ok := job.old.overlaid[h]; ok { old = b } }
		level := layout_level(old, c)
		if level >= .Layout {
			if out^ == nil { out^ = make([dynamic]Journal_Entry, 0, 16) }   // heap: the workers' temp memory is freed per round
			append(out, Journal_Entry{node = h, level = level})
		}
	}
}

// Fills the journal of `new` (a full pass) with what differs from `old` (the pass it replaces, cascaded values: the
// timeline records the animated ones when it ticks). The comparison of a large document is shared by the pool's
// threads.
journal_diff :: proc(old, new: ^Styled, pool: ^host.Thread_Pool = nil) {
	j := &new.journal
	if !j.on || old == nil { return }
	n := len(new.by_node)
	chunk := 1024
	count := (n + chunk - 1) / chunk
	job := Diff_Job{old = old, new = new, n = n, chunk = chunk, out = make([][dynamic]Journal_Entry, count, context.temp_allocator)}
	host.parallel_for(pool, count, diff_chunk, &job)
	total := 0
	for &o in job.out { total += len(o) }
	if total > j.max {
		clear(&j.entries)
		j.from = JOURNAL_PENDING
	} else {
		for &o in job.out { append(&j.entries, ..o[:]) }
		// changes of the old pass a reader may not have seen are not carried: such a reader is older than `from`
		j.from = old.serial
		for &e in j.entries { e.serial = new.serial }
	}
	for &o in job.out { delete(o) }
}
