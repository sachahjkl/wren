package idb

import "base:runtime"
import "core:encoding/endian"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "wb:base"

// Compaction: when the journal is much larger than the data it holds (dead records: replaced and deleted values), the live
// values are copied into a new journal, in the background, without stopping anything.
//
//   1. Job: at a moment when nothing is uncommitted, the manager makes a checkpoint plan (the keys of every store and where
//      their values are: the same thing the checkpoint file holds). A pool thread copies the live values from the old journal
//      into `<origin>~N.widb.tmp`, in key order, and writes the new checkpoint (`~N.widx.tmp`) with the new places. Meanwhile
//      commits go on, appended to the old journal.
//   2. Settling: the writer is held until the write in flight is done; what was appended to the old journal since the plan (the
//      tail) is copied to the end of the new one, the new files are flushed and renamed to their names: from then on the
//      highest generation is the journal (a crash before leaves the old one whole, and the loader deletes leftovers).
//   3. Remap: new commits are appended to the new journal, and the records in memory that point into the old one get their new
//      places (a search in the list of moved values, or a shift for what was in the tail), a slice at a time; both files are
//      readable meanwhile (a record says which one it is in: its generation parity). Then the old files go.

Compaction_Stage :: enum u8 { Job, Settling, Copying, Remap }

Pair :: struct { old, new: i64 }

Compaction :: struct {
	stage:        Compaction_Stage,
	epoch:        u32,
	old_gen:      u32,
	new_gen:      u32,
	snapshot_len: i64,       // the old journal's length when the plan was made
	plan:         Ck_Plan,
	new_len:      i64,       // the new journal's length before the tail
	pairs:        []Pair,    // old offset of each moved value, with its new one, by old offset
	tail:         i64,
	abandoned:    b32,       // atomic: results of a job are dropped
	busy:         b32,       // atomic: a job is running
	jobs:         int,       // jobs submitted whose completion has not run
	renamed:      b32,       // atomic: the new files have their final names
	// the remap
	db_i, store_i: int,
	cursor:       []byte,    // the key to go on after in the store being remapped
	has_cursor:   bool,
	old_parity:   u8,
}

@(private)
Compact_Job :: struct {
	life:       ^Life,
	m:          ^Manager,
	o:          ^Origin,
	c:          ^Compaction,
	old_jpath:  string,
	old_ckpath: string,
	new_jpath:  string,   // final names (the work is in files with .tmp)
	new_ckpath: string,
	copy_from, copy_to: i64,
	ok:         bool,
	newfile:    File,
	pairs:      [dynamic]Pair,
	new_len:    i64,
}

@(private)
compact_job_free :: proc(j: ^Compact_Job) {
	pa := base.process_allocator()
	delete(j.old_jpath, pa); delete(j.old_ckpath, pa); delete(j.new_jpath, pa); delete(j.new_ckpath, pa)
	delete(j.pairs)
	life_unref(j.life)
	free(j, pa)
}

@(private)
compact_job_new :: proc(m: ^Manager, o: ^Origin, c: ^Compaction) -> ^Compact_Job {
	pa := base.process_allocator()
	job := new(Compact_Job, pa)
	job.life, job.m, job.o, job.c = m.life, m, o, c
	sync.atomic_add(&m.life.refs, 1)
	job.old_jpath = strings.clone(origin_file(o, c.old_gen, ".widb"), pa)
	job.old_ckpath = strings.clone(origin_file(o, c.old_gen, ".widx"), pa)
	job.new_jpath = strings.clone(origin_file(o, c.new_gen, ".widb"), pa)
	job.new_ckpath = strings.clone(origin_file(o, c.new_gen, ".widx"), pa)
	job.pairs = make([dynamic]Pair, pa)
	return job
}

@(private)
compact_submit :: proc(m: ^Manager, job: ^Compact_Job, run, done: proc(data: rawptr)) {
	sync.atomic_store(&job.c.busy, true)
	job.c.jobs += 1
	if m.submit != nil {
		m.submit(m.submit_user, run, done, job)
	} else {
		run(job)
		done(job)
	}
}

// The journal is much larger than its data: copy the live values into a new one.
@(private)
maybe_compact :: proc(m: ^Manager, o: ^Origin) {
	if m.dir == "" || o.alien || o.state != .Ready || o.compaction != nil || !quiescent(o) { return }
	limit := m.settings.compact_min_bytes + i64(m.settings.compact_ratio * f64(o.data.bytes))
	if o.file_len <= limit { return }
	if o.compact_retry > 0 && o.file_len < o.compact_retry { return }
	context.allocator = m.allocator
	pa := base.process_allocator()
	c := new(Compaction, pa)
	c.epoch, c.old_gen, c.new_gen, c.snapshot_len = o.epoch, o.jgen, o.jgen + 1, o.file_len
	c.old_parity = u8(o.jgen & 1)
	c.plan = checkpoint_plan(&o.data, o.file_len, pa)
	o.compaction = c
	compact_submit(m, compact_job_new(m, o, c), compact_run, compact_done)
}

// Writes the compaction now if it is due (tests, shutdown).
manager_compact :: proc(m: ^Manager, origin: string) {
	sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
	context.allocator = m.allocator
	if o, ok := m.origins[origin]; ok { maybe_compact(m, o) }
}

////////////////////////////////
// 1. The copy of the live values (pool)

@(private)
Cmp_Held :: struct {
	key:   []byte,
	vlen:  u32,
	ikeys: []Index_Key,
	rel:   int,
}

@(private)
Cmp_Pend :: struct { pair: int, rel: int }

@(private)
Cmp_Work :: struct {
	oldj:  File,
	fnew:  File,
	db:    string,
	store: u32,
	batch: Writer,
	held:  [dynamic]Cmp_Held,
	pend:  [dynamic]Cmp_Pend,
	off:   i64,
	good:  bool,
	sw:    Sec_Writer,
	pairs: ^[dynamic]Pair,
	vbuf:  [dynamic]byte,
}

@(private)
cmp_flush :: proc(w: ^Cmp_Work) {
	if len(w.batch.data) == 0 { return }
	fr := make([dynamic]byte, 0, len(w.batch.data) + 16, context.temp_allocator)
	frame_payload(&fr, w.batch.data[:])
	if w.good { w.good = file_write_at(w.fnew, w.off, fr[:]) }
	vbase := w.off + FRAME_HEADER + 1
	w.off += i64(len(fr))
	for h in w.held {
		voff: i64
		if h.vlen > 0 { voff = vbase + i64(h.rel) }
		sec_add(&w.sw, h.key, h.vlen, voff, h.ikeys)
		delete(h.key)
		for k in h.ikeys { delete(k.key) }
		delete(h.ikeys)
	}
	for p in w.pend { w.pairs[p.pair].new = vbase + i64(p.rel) }
	clear(&w.held)
	clear(&w.pend)
	clear(&w.batch.data)
}

@(private)
cmp_visit :: proc(user: rawptr, key: []byte, vlen: u32, voff: i64, ikeys: []Index_Key) -> bool {
	w := (^Cmp_Work)(user)
	val: []byte
	if vlen > 0 {
		resize(&w.vbuf, int(vlen))
		if !file_read_at(w.oldj, voff, w.vbuf[:]) { w.good = false; return false }
		val = w.vbuf[:]
	}
	vp := op_encode(&w.batch, Op{kind = .Put, db = w.db, store = w.store, key = key, value = val, ikeys = ikeys})
	rel := max(vp, 0)
	// (key and index keys are valid for this call only: the section's record is added when the batch is written)
	h := Cmp_Held{vlen = vlen, rel = rel}
	h.key = make([]byte, len(key))
	copy(h.key, key)
	h.ikeys = make([]Index_Key, len(ikeys))
	for k, i in ikeys {
		b := make([]byte, len(k.key))
		copy(b, k.key)
		h.ikeys[i] = Index_Key{k.index, b}
	}
	append(&w.held, h)
	if vlen > 0 {
		append(w.pairs, Pair{old = voff})
		append(&w.pend, Cmp_Pend{pair = len(w.pairs) - 1, rel = rel})
	}
	if len(w.batch.data) >= 1 << 20 { cmp_flush(w) }
	return w.good
}

@(private)
compact_run :: proc(data: rawptr) {
	j := (^Compact_Job)(data)
	defer sync.atomic_store(&j.c.busy, false)
	j.ok = compact_copy(j)
}

@(private)
compact_copy :: proc(j: ^Compact_Job) -> bool {
	a := base.process_allocator()
	context.allocator = a
	plan := &j.c.plan
	oldj, ok1 := file_open(j.old_jpath, false, false)
	if !ok1 { return false }
	defer file_close(&oldj)
	oldck, _ := file_open(j.old_ckpath, false, false)
	defer file_close(&oldck)
	jtmp := join2(j.new_jpath, ".tmp")
	defer delete(jtmp)
	fnew, ok2 := file_open(jtmp, true, true)
	if !ok2 { return false }
	good := file_truncate(fnew, 0)
	hdr := file_header()
	if good { good = file_write_at(fnew, 0, hdr[:]) }
	off := i64(HEADER_SIZE)
	{
		fr := make([dynamic]byte, context.temp_allocator)
		frame_payload(&fr, plan.schema)
		if good { good = file_write_at(fnew, off, fr[:]) }
		off += i64(len(fr))
	}
	w := Cmp_Work{oldj = oldj, fnew = fnew, off = off, good = good, pairs = &j.pairs}
	w.batch.data = make([dynamic]byte, 0, 1 << 20)
	w.held = make([dynamic]Cmp_Held)
	w.pend = make([dynamic]Cmp_Pend)
	w.vbuf = make([dynamic]byte)
	defer {
		delete(w.batch.data); delete(w.held); delete(w.pend); delete(w.vbuf)
	}
	sections := make([dynamic][]byte, context.temp_allocator)
	for part, i in plan.parts {
		if !w.good { break }
		cs := plan.stores[i]
		w.db, w.store = cs.db, cs.store
		sec_writer_init(&w.sw, context.temp_allocator, 4096)
		if part.len > 0 {
			src: Ck_Src
			sec: Section
			if part.data != nil {
				src, sec = Ck_Src{mem = part.data}, Section{0, i64(len(part.data)), cs.section.count}
			} else {
				src, sec = Ck_Src{f = oldck}, Section{part.from, part.len, cs.section.count}
			}
			if !ck_read_section(src, sec, &w, cmp_visit, context.temp_allocator) { w.good = false }
		}
		cmp_flush(&w)
		bytes := sec_finish(&w.sw)
		if i64(len(bytes)) != part.len { w.good = false }   // (fixed-width records: the new section is as long as the old)
		append(&sections, bytes)
	}
	if w.good { w.good = file_sync(fnew) }
	file_close(&fnew)
	if !w.good { file_delete(jtmp); return false }
	// the new checkpoint: the plan's directory (same sections' sizes), the new length, the sections with the new places
	p2 := Ck_Plan{}
	p2.head = make([]byte, len(plan.head))
	copy(p2.head, plan.head)
	endian.put_u64(p2.head[8:], .Little, u64(w.off))
	p2.parts = make([dynamic]Ck_Part)
	for s in sections { append(&p2.parts, Ck_Part{data = s, len = i64(len(s))}) }
	ok := ck_write(&p2, "", j.new_ckpath, true, false)
	delete(p2.head)
	delete(p2.parts)
	if !ok { file_delete(jtmp); return false }
	slice.sort_by(j.pairs[:], proc(a, b: Pair) -> bool { return a.old < b.old })
	j.new_len = w.off
	return true
}

// Job 1 is over (UI thread).
@(private)
compact_done :: proc(data: rawptr) {
	j := (^Compact_Job)(data)
	defer compact_job_free(j)
	if !j.life.alive { return }
	m, o, c := j.m, j.o, j.c
	sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
	context.allocator = m.allocator
	c.jobs -= 1
	if sync.atomic_load(&c.abandoned) || o.compaction != c {
		compact_discard_tmp(j)
		compaction_free(c)
		return
	}
	if !j.ok {
		compact_discard_tmp(j)
		o.compact_retry = o.file_len + o.file_len / 4
		o.compaction = nil
		compaction_free(c)
		return
	}
	pa := base.process_allocator()
	c.new_len = j.new_len
	c.pairs = make([]Pair, len(j.pairs), pa)
	copy(c.pairs, j.pairs[:])
	c.stage = .Settling
	o.hold_writes = true
	compaction_writes_settled(m, o)
}

@(private)
compact_discard_tmp :: proc(j: ^Compact_Job) {
	file_delete(join2(j.new_jpath, ".tmp"))
	file_delete(join2(j.new_ckpath, ".tmp"))
}

@(private)
compaction_free :: proc(c: ^Compaction) {
	pa := base.process_allocator()
	ck_plan_destroy(&c.plan, pa)
	delete(c.pairs, pa)
	delete(c.cursor)
	free(c, pa)
}

////////////////////////////////
// 2. The tail, the switch

// The writes in flight are done: the tail of the old journal goes to the new one.
@(private)
compaction_writes_settled :: proc(m: ^Manager, o: ^Origin) {
	c := o.compaction
	if c == nil || c.stage != .Settling || o.writing || o.sync_busy { return }
	c.stage = .Copying
	c.tail = o.file_len - c.snapshot_len
	job := compact_job_new(m, o, c)
	job.copy_from, job.copy_to, job.new_len = c.snapshot_len, o.file_len, c.new_len
	compact_submit(m, job, compact_tail_run, compact_tail_done)
}

// On the pool: copies the old journal's tail after the new one's records, flushes, and gives both new files their names.
@(private)
compact_tail_run :: proc(data: rawptr) {
	j := (^Compact_Job)(data)
	defer sync.atomic_store(&j.c.busy, false)
	a := base.process_allocator()
	context.allocator = a
	jtmp := join2(j.new_jpath, ".tmp")
	defer delete(jtmp)
	cktmp := join2(j.new_ckpath, ".tmp")
	defer delete(cktmp)
	fnew, ok := file_open(jtmp, true, true)
	if !ok { return }
	oldj, ok1 := file_open(j.old_jpath, false, false)
	if !ok1 { file_close(&fnew); return }
	defer file_close(&oldj)
	good := true
	buf := make([]byte, 1 << 20)
	defer delete(buf)
	for at := j.copy_from; at < j.copy_to && good; {
		n := int(min(i64(len(buf)), j.copy_to - at))
		good = file_read_at(oldj, at, buf[:n]) && file_write_at(fnew, j.new_len + (at - j.copy_from), buf[:n])
		at += i64(n)
	}
	if good { good = file_truncate_to_end(fnew, j.new_len + (j.copy_to - j.copy_from)) }
	if good { good = file_sync(fnew) }
	if good && sync.atomic_load(&j.c.abandoned) { good = false }
	if good { good = file_rename(jtmp, j.new_jpath) }
	if good {
		sync.atomic_store(&j.c.renamed, true)
		good = file_rename(cktmp, j.new_ckpath) || true   // (without its checkpoint the new journal is replayed whole: slower, whole)
	}
	if !good { file_close(&fnew); file_delete(jtmp); return }
	j.newfile = fnew
	j.ok = true
}

@(private)
file_truncate_to_end :: proc(f: File, size: i64) -> bool { return file_truncate(f, size) }

// The new files are in place (UI thread): the new journal is the current one, the records are remapped a slice at a time.
@(private)
compact_tail_done :: proc(data: rawptr) {
	j := (^Compact_Job)(data)
	defer compact_job_free(j)
	if !j.life.alive { file_close(&j.newfile); return }
	m, o, c := j.m, j.o, j.c
	sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
	context.allocator = m.allocator
	c.jobs -= 1
	if sync.atomic_load(&c.abandoned) || o.compaction != c {
		file_close(&j.newfile)
		if sync.atomic_load(&c.renamed) { compact_delete_new(j) }
		compaction_free(c)
		return
	}
	if !j.ok {
		if sync.atomic_load(&c.renamed) { compact_delete_new(j) }
		o.compact_retry = o.file_len + o.file_len / 4
		o.compaction = nil
		o.hold_writes = false
		compaction_free(c)
		request_flush(m, o)
		return
	}
	// the switch
	new_parity := u8(c.new_gen & 1)
	file_close(&o.vsrc.files[new_parity])
	o.vsrc.files[new_parity] = j.newfile
	o.jfile = j.newfile
	o.jgen = c.new_gen
	o.file_len = c.new_len + c.tail
	o.ck_len = c.new_len
	o.unsynced = 0
	o.data.replay_gen = new_parity
	checkpoint_adopt(o, &c.plan)
	o.ck_len = c.new_len
	c.stage = .Remap
	o.hold_writes = false
	request_flush(m, o)
	compaction_remap(m, o)
}

@(private)
compact_delete_new :: proc(j: ^Compact_Job) {
	file_delete(j.new_jpath)
	file_delete(j.new_ckpath)
}

////////////////////////////////
// 3. The remap

@(private)
Remap_Task :: struct {
	life: ^Life,
	m:    ^Manager,
	key:  string,
}

@(private)
remap_record :: proc(c: ^Compaction, r: ^Record) {
	if r.gen != c.old_parity || r.voff < 0 || r.vlen == 0 { return }
	if r.voff >= c.snapshot_len {
		r.voff += c.new_len - c.snapshot_len
	} else {
		lo, hi := 0, len(c.pairs)
		for lo < hi {
			mid := (lo + hi) / 2
			if c.pairs[mid].old < r.voff { lo = mid + 1 } else { hi = mid }
		}
		if lo < len(c.pairs) && c.pairs[lo].old == r.voff { r.voff = c.pairs[lo].new } else { return }
	}
	r.gen = u8(c.new_gen & 1)
}

// Remaps the resident records in slices of a few thousand: between slices the shell's loop runs (m.post), the stores may change
// (what is written meanwhile goes to the new journal).
@(private)
compaction_remap :: proc(m: ^Manager, o: ^Origin) {
	c := o.compaction
	if c == nil || c.stage != .Remap { return }
	context.allocator = m.allocator
	budget := 20000
	for c.db_i < len(o.data.dbs) {
		db := o.data.dbs[c.db_i]
		for c.store_i < len(db.stores) {
			s := db.stores[c.store_i]
			if s.resident {
				p := ordered_first(&s.records)
				if c.has_cursor { p = ordered_seek(&s.records, c.cursor, true) }
				for pos_valid(&s.records, p) {
					_, v := pos_entry(&s.records, p)
					r := (^Record)(v)
					remap_record(c, r)
					budget -= 1
					if budget <= 0 {
						delete(c.cursor)
						c.cursor = clone_bytes(r.key, m.allocator)
						c.has_cursor = true
						remap_next_slice(m, o)
						return
					}
					pos_next(&s.records, &p)
				}
			}
			c.store_i += 1
			c.has_cursor = false
		}
		c.db_i += 1
		c.store_i = 0
	}
	compaction_finish(m, o)
}

@(private)
remap_next_slice :: proc(m: ^Manager, o: ^Origin) {
	if m.post == nil {
		compaction_remap(m, o)
		return
	}
	t := new(Remap_Task, base.process_allocator())
	t.life, t.m = m.life, m
	t.key = strings.clone(o.key, base.process_allocator())
	sync.atomic_add(&m.life.refs, 1)
	m.post(m.post_user, proc(data: rawptr) {
		t := (^Remap_Task)(data)
		defer {
			delete(t.key, base.process_allocator())
			life_unref(t.life)
			free(t, base.process_allocator())
		}
		if !t.life.alive { return }
		m := t.m
		sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
		if o, ok := m.origins[t.key]; ok { compaction_remap(m, o) }
	}, t)
}

// Every record points into the new journal: the old files go.
@(private)
compaction_finish :: proc(m: ^Manager, o: ^Origin) {
	c := o.compaction
	file_close(&o.vsrc.files[c.old_parity])
	file_delete(origin_file(o, c.old_gen, ".widb"))
	file_delete(origin_file(o, c.old_gen, ".widx"))
	o.compaction = nil
	o.compact_retry = 0
	m.stats.snapshots += 1
	compaction_free(c)
	maybe_checkpoint(m, o, false)
}

// The origin is going or being cleared: a job's result will be dropped, a remap in progress is finished at once.
@(private)
compaction_abandon :: proc(m: ^Manager, o: ^Origin) {
	c := o.compaction
	if c == nil { return }
	context.allocator = m.allocator
	if c.stage == .Remap {
		// finish synchronously: no posting
		saved := m.post
		m.post = nil
		compaction_remap(m, o)
		m.post = saved
		return
	}
	sync.atomic_store(&c.abandoned, true)
	// a job that may give the new files their names must be over before the old journal is written again
	waited := 0
	for sync.atomic_load(&c.busy) && waited < 20000 {
		time.sleep(time.Millisecond)
		waited += 1
	}
	if sync.atomic_load(&c.renamed) {
		file_delete(origin_file(o, c.new_gen, ".widb"))
		file_delete(origin_file(o, c.new_gen, ".widx"))
	}
	o.compaction = nil
	o.hold_writes = false
	// (the job's own completion frees what it holds; the plan and the pairs go with it)
	if c.jobs == 0 { compaction_free(c) }   // else the completion of the job that is still to run frees it
}

_ :: runtime
