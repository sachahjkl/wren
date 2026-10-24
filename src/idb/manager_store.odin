package idb

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:sync"
import "wb:base"

// What the manager does with the files of an origin: bringing a store into memory from its checkpoint section, the journal
// writer (commits are written by the thread that commits when they are small, grouped when they come in one task, by the pool
// when large or strict), the checkpoints, and the housekeeping of a timer (flush of the system's cache, dropping stores nobody
// uses). Compaction is in compaction.odin.

////////////////////////////////
// Stores in memory

// The private copy of what a store's schema says, for a read that happens on the pool.
@(private)
Index_Def :: struct { id: u32, unique, multi: bool }

@(private)
Store_Job :: struct {
	life:     ^Life,
	m:        ^Manager,
	o:        ^Origin,
	epoch:    u32,
	jgen:     u32,
	db:       string,
	store:    u32,
	section:  Section,
	has_section: bool,
	ck_path:  string,
	jpath:    string,
	ck_len:   i64,
	size_to:  i64,
	defs:     [dynamic]Index_Def,
	result:   ^Store,
	ok:       bool,
}

// Frees what a store holds in memory (records, index entries); the store itself stays.
@(private)
store_contents_free :: proc(d: ^Data, s: ^Store) {
	it := ordered_first(&s.records)
	for pos_valid(&s.records, it) {
		_, v := pos_entry(&s.records, it)
		record_free(d, (^Record)(v))
		pos_next(&s.records, &it)
	}
	ordered_clear(&s.records)
	for ix in s.indexes { ordered_clear(&ix.entries) }
}

// Starts reading a store that is not in memory (its section of the checkpoint, then the journal after the checkpoint).
@(private)
store_load_start :: proc(o: ^Origin, db: ^Database, s: ^Store) {
	if s.resident || s.loading || o.state != .Ready { return }
	m := o.m
	s.loading = true
	o.loads += 1
	pa := base.process_allocator()
	job := new(Store_Job, pa)
	job.life, job.m, job.o, job.epoch, job.jgen = m.life, m, o, o.epoch, o.jgen
	sync.atomic_add(&m.life.refs, 1)
	job.db = strings.clone(db.name, pa)
	job.store, job.section, job.has_section = s.id, s.section, s.has_section
	job.ck_path = strings.clone(origin_file(o, o.jgen, ".widx"), pa)
	job.jpath = strings.clone(origin_file(o, o.jgen, ".widb"), pa)
	job.ck_len, job.size_to = o.ck_len, o.file_len
	job.defs = make([dynamic]Index_Def, pa)
	for ix in s.indexes { append(&job.defs, Index_Def{ix.id, ix.unique, ix.multi}) }
	run :: proc(data: rawptr) {
		j := (^Store_Job)(data)
		a := base.process_allocator()
		context.allocator = a
		pd: Data
		data_init(&pd, a)
		pd.replay_gen = u8(j.jgen & 1)
		pdb := new(Database)
		pdb.name = clone_str(j.db, a)
		pdb.stores = make([dynamic]^Store)
		st := new(Store)
		st.id = j.store
		st.resident = true
		ordered_init(&st.records, a, true)
		st.indexes = make([dynamic]^Index)
		for def in j.defs {
			ix := new(Index)
			ix.id, ix.unique, ix.multi = def.id, def.unique, def.multi
			ordered_init(&ix.entries, a)
			append(&st.indexes, ix)
		}
		append(&pdb.stores, st)
		append(&pd.dbs, pdb)
		from := j.ck_len
		loaded_section := false
		if j.has_section {
			if ckf, cok := file_open(j.ck_path, false, false); cok {
				st.section = j.section
				loaded_section = ck_load_store(&pd, st, ckf)
				file_close(&ckf)
			}
		}
		if !loaded_section {
			// no usable section: this store's records are rebuilt from the journal alone
			store_contents_free(&pd, st)
			st.bytes = 0
			from = HEADER_SIZE
		}
		good := j.size_to <= from
		if jf, jok := file_open(j.jpath, false, false); jok {
			good = true
			fr: Frame_Reader
			frame_reader_init(&fr, jf, j.size_to, from, context.temp_allocator)
			for {
				payload, off, pok := frame_next(&fr)
				if !pok { break }
				if !replay_ops(&pd, payload[1:], off + 1, .Store_Only, j.db, j.store) { good = false; break }
			}
			file_close(&jf)
		}
		ok := good
		j.ok = ok
		j.result = st
		delete(pdb.stores)
		delete(pdb.name, a)
		free(pdb)
		delete(pd.dbs)
	}
	finish :: proc(data: rawptr) {
		j := (^Store_Job)(data)
		pa := base.process_allocator()
		defer {
			delete(j.db, pa); delete(j.ck_path, pa); delete(j.jpath, pa); delete(j.defs)
			life_unref(j.life)
			free(j, pa)
		}
		if !j.life.alive { return }
		m, o := j.m, j.o
		sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
		context.allocator = m.allocator
		o.loads -= 1
		st := j.result
		d := &o.data
		discard :: proc(d: ^Data, st: ^Store, pa: runtime.Allocator) {
			store_contents_free(d, st)
			for ix in st.indexes { ordered_destroy(&ix.entries); free(ix, pa) }
			delete(st.indexes)
			ordered_destroy(&st.records)
			free(st, pa)
		}
		db := find_db(d, j.db)
		var_s: ^Store
		if db != nil { var_s = find_store(db, j.store) }
		if var_s != nil { var_s.loading = false }
		if j.epoch != o.epoch || j.jgen != o.jgen || var_s == nil || var_s.resident || !j.ok {
			discard(d, st, pa)
			if j.epoch == o.epoch && var_s != nil && !var_s.resident && !j.ok && j.jgen == o.jgen {
				// the journal itself could not be read: what waits for this store fails
				store_failed(m, o, db, var_s)
			}
			for _, ds in o.dbs { schedule(ds); db_pump(o, ds) }
			return
		}
		ordered_destroy(&var_s.records)
		var_s.records = st.records
		for ix in var_s.indexes {
			for pix in st.indexes {
				if pix.id == ix.id {
					ordered_destroy(&ix.entries)
					ix.entries = pix.entries
					pix.entries = {}
				}
			}
		}
		d.bytes += st.bytes - var_s.bytes
		var_s.bytes = st.bytes
		var_s.rev, var_s.ck_rev = st.rev, 0
		var_s.resident = true
		if m.now_ms != nil { var_s.used_ms = m.now_ms() }
		for ix in st.indexes { ordered_destroy(&ix.entries); free(ix, pa) }
		delete(st.indexes)
		free(st, pa)
		for _, ds in o.dbs { schedule(ds); db_pump(o, ds) }
	}
	if m.submit != nil {
		m.submit(m.submit_user, run, finish, job)
	} else {
		run(job)
		finish(job)
	}
}

// A store could not be read: the transactions that wait for it abort with an I/O error.
@(private)
store_failed :: proc(m: ^Manager, o: ^Origin, db: ^Database, s: ^Store) {
	for _, ds in o.dbs {
		if ds.name != db.name { continue }
		txs := slice.clone(ds.txs[:], context.temp_allocator)
		for tx in txs {
			if tx.state == .Pending {
				for sid in tx.scope { if sid == s.id { tx_finish(m, tx, false, .Io); break } }
			}
		}
	}
}

// Whether every store a transaction names is in memory; the ones that are not start loading.
@(private)
tx_stores_ready :: proc(o: ^Origin, tx: ^Tx) -> bool {
	db := find_db(&o.data, tx.ds.name)
	if db == nil { return true }
	ready := true
	for sid in tx.scope {
		s := find_store(db, sid)
		if s == nil || s.resident { continue }
		ready = false
		store_load_start(o, db, s)
	}
	if o.state == .Ready && ready && o.m.now_ms != nil {
		now := o.m.now_ms()
		for sid in tx.scope { if s := find_store(db, sid); s != nil { s.used_ms = now } }
	}
	return ready
}

// Whether every store of the database is in memory (an upgrade may touch them all); the ones that are not start loading.
@(private)
db_resident :: proc(o: ^Origin, name: string) -> bool {
	db := find_db(&o.data, name)
	if db == nil { return true }
	ready := true
	for s in db.stores {
		if s.resident { continue }
		ready = false
		store_load_start(o, db, s)
	}
	return ready
}

// Memory the keys of a store in memory take, about.
@(private)
store_memory :: proc(s: ^Store) -> i64 {
	n := i64(s.records.count) * 168
	for ix in s.indexes { n += i64(ix.entries.count) * 72 }
	return n
}

// Drops from memory the stores that can be read again as they are (their checkpoint section is current) and that nobody
// uses: the ones idle for idle_unload_ms, and the least recently used while the keys take more than resident_bytes.
@(private)
evict_stores :: proc(m: ^Manager, o: ^Origin, now: f64) {
	if o.ck_len == 0 || o.compaction != nil || o.ck_busy { return }
	total: i64
	Cand :: struct { db: ^Database, s: ^Store }
	cands := make([dynamic]Cand, context.temp_allocator)
	for db in o.data.dbs {
		for s in db.stores {
			if !s.resident { continue }
			total += store_memory(s)
			if !s.has_section || s.rev != s.ck_rev || s.loading { continue }
			used := false
			if ds, ok := o.dbs[db.name]; ok {
				for tx in ds.txs { for sid in tx.scope { if sid == s.id || tx.mode == .Version_Change { used = true } } }
				if len(ds.conns) > 0 && ds.active != nil { used = true }
			}
			if !used { append(&cands, Cand{db, s}) }
		}
	}
	slice.sort_by(cands[:], proc(a, b: Cand) -> bool { return a.s.used_ms < b.s.used_ms })
	for c in cands {
		idle := now - c.s.used_ms >= m.settings.idle_unload_ms
		if !idle && total <= m.settings.resident_bytes { continue }
		total -= store_memory(c.s)
		store_contents_free(&o.data, c.s)
		c.s.resident = false
	}
}

////////////////////////////////
// The journal writer

@(private)
Flush_Task :: struct {
	life: ^Life,
	m:    ^Manager,
	key:  string,
}

@(private)
queued_bytes :: proc(o: ^Origin) -> int {
	n := 0
	for it in o.wq { n += len(it.data) }
	return n
}

// Something is queued: it is written at once when it is already a full batch, or when nothing can run the writer later, else by a
// task of the shell's loop (every commit of the current task is then written together).
@(private)
request_flush :: proc(m: ^Manager, o: ^Origin) {
	if o.writing || o.hold_writes || len(o.wq) == 0 { return }
	if m.post == nil || queued_bytes(o) >= m.settings.write_batch_bytes {
		flush_now(m, o)
		return
	}
	if o.flush_posted { return }
	o.flush_posted = true
	t := new(Flush_Task, base.process_allocator())
	t.life, t.m = m.life, m
	t.key = strings.clone(o.key, base.process_allocator())
	sync.atomic_add(&m.life.refs, 1)
	m.post(m.post_user, proc(data: rawptr) {
		t := (^Flush_Task)(data)
		defer {
			delete(t.key, base.process_allocator())
			life_unref(t.life)
			free(t, base.process_allocator())
		}
		if !t.life.alive { return }
		m := t.m
		sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
		if o, ok := m.origins[t.key]; ok {
			o.flush_posted = false
			flush_now(m, o)
		}
	}, t)
}

@(private)
Write_Job :: struct {
	file:    File,
	offset:  i64,
	data:    []byte,
	flush:   bool,
	items:   [dynamic]^Tx,
	offs:    [dynamic]i64,   // the file offset of each item's record
	ok:      bool,
	life:    ^Life,
	o:       ^Origin,
	m:       ^Manager,
}

// The journal of the current generation, open for writing (made when the first record is written).
@(private)
ensure_journal :: proc(o: ^Origin) -> bool {
	if file_valid(o.jfile) { return true }
	f, ok := file_open(origin_file(o, o.jgen), true, true)
	if !ok { return false }
	o.jfile = f
	file_close(&o.vsrc.files[o.jgen & 1])
	o.vsrc.files[o.jgen & 1] = f
	return true
}

// Writes what is queued (one batch: the records of consecutive commits together).
@(private)
flush_now :: proc(m: ^Manager, o: ^Origin) {
	if o.writing || o.hold_writes || len(o.wq) == 0 { return }
	context.allocator = m.allocator
	if o.clear_pending { return }
	pa := base.process_allocator()
	strict := false
	buf := make([dynamic]byte, 0, 1024, pa)
	items := make([dynamic]^Tx, pa)
	offs := make([dynamic]i64, pa)
	base_off := o.file_len
	if o.file_len == 0 { h := file_header(); append(&buf, ..h[:]) }
	taken := 0
	for taken < len(o.wq) && (taken == 0 || len(buf) < m.settings.write_batch_bytes) {
		item := o.wq[taken]
		append(&offs, base_off + i64(len(buf)))
		append(&buf, ..item.data)
		append(&items, item.tx)
		if item.strict || m.settings.durability == .Strict { strict = true }
		delete(item.data)
		taken += 1
	}
	remove_range(&o.wq, 0, taken)
	if !ensure_journal(o) {
		complete_batch(m, o, items[:], offs[:], base_off, buf[:], false, false)
		delete(buf); delete(items); delete(offs)
		return
	}
	if !strict && len(buf) <= m.settings.sync_write_bytes {
		ok := file_write_at(o.jfile, base_off, buf[:])
		if !ok { file_truncate(o.jfile, base_off) }
		complete_batch(m, o, items[:], offs[:], base_off, buf[:], ok, false)
		delete(buf); delete(items); delete(offs)
		return
	}
	job := new(Write_Job, pa)
	job.file, job.offset, job.data, job.flush = o.jfile, base_off, buf[:], strict
	job.items, job.offs = items, offs
	job.life, job.o, job.m = m.life, o, m
	sync.atomic_add(&m.life.refs, 1)
	o.writing = true
	run :: proc(data: rawptr) {
		j := (^Write_Job)(data)
		j.ok = file_write_at(j.file, j.offset, j.data)
		if !j.ok { file_truncate(j.file, j.offset) }
		if j.ok && j.flush && !file_sync(j.file) { j.ok = false; file_truncate(j.file, j.offset) }
	}
	finish :: proc(data: rawptr) {
		j := (^Write_Job)(data)
		pa := base.process_allocator()
		defer {
			delete(j.data, pa); delete(j.items); delete(j.offs)
			life_unref(j.life)
			free(j, pa)
		}
		if !j.life.alive { return }
		m, o := j.m, j.o
		sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
		context.allocator = m.allocator
		o.writing = false
		complete_batch(m, o, j.items[:], j.offs[:], j.offset, j.data, j.ok, j.flush)
	}
	if m.submit != nil {
		m.submit(m.submit_user, run, finish, job)
	} else {
		run(job)
		finish(job)
	}
}

// A batch has been written (or not): its transactions end, the values they put get their place in the file.
@(private)
complete_batch :: proc(m: ^Manager, o: ^Origin, items: []^Tx, offs: []i64, base_off: i64, data: []byte, ok: bool, flushed: bool) {
	if ok {
		o.file_len = base_off + i64(len(data))
		m.stats.appends += 1
		m.stats.bytes_written += u64(len(data))
		if flushed { o.unsynced = 0 } else { o.unsynced += i64(len(data)) }
	}
	for tx, i in items {
		if ok { values_commit(o, tx, offs[i]) }
		tx_finish(m, tx, ok, .Io)
	}
	if o.clear_pending {
		o.clear_pending = false
		origin_wipe_files(m, o)
		return
	}
	if o.compaction != nil { compaction_writes_settled(m, o) }
	if len(o.wq) > 0 { request_flush(m, o) }
	maybe_checkpoint(m, o, false)
	maybe_compact(m, o)
}

// The values a transaction put are in the file now: they know where, and join the cache of values.
@(private)
values_commit :: proc(o: ^Origin, tx: ^Tx, frame_off: i64) {
	d := &o.data
	if len(tx.values) == 0 { return }
	db := find_db(d, tx.ds.name)
	for ref in tx.values {
		if db == nil { break }
		s := find_store(db, ref.store)
		if s == nil { continue }
		cur, found := ordered_get(&s.records, ref.key)
		if !found { continue }
		rec := (^Record)(cur)
		if rec.value == nil || raw_data(rec.value) != ref.ptr { continue }   // replaced meanwhile
		rec.voff = frame_off + FRAME_HEADER + 1 + i64(ref.rel)
		rec.gen = u8(o.jgen & 1)
		cache_add(d, rec)
	}
}

////////////////////////////////
// Checkpoints

@(private)
quiescent :: proc(o: ^Origin) -> bool {
	if o.writing || len(o.wq) > 0 || o.hold_writes || o.ck_busy || o.sync_busy || o.state != .Ready { return false }
	for _, ds in o.dbs { for tx in ds.txs { if tx.x.changed || tx.state == .Committing { return false } } }
	return true
}

@(private)
origin_checkpoint_due :: proc(m: ^Manager, o: ^Origin, force: bool) -> bool {
	if m.dir == "" || o.alien || o.state != .Ready || o.file_len <= HEADER_SIZE { return false }
	tail := o.file_len - max(o.ck_len, HEADER_SIZE)
	if tail <= 0 { return false }
	return force || tail >= m.settings.checkpoint_tail_bytes
}

@(private)
Ck_Job :: struct {
	life:    ^Life,
	m:       ^Manager,
	o:       ^Origin,
	epoch:   u32,
	jgen:    u32,
	plan:    Ck_Plan,
	old:     string,
	path:    string,
	ok:      bool,
}

// Writes a checkpoint of the origin (in the background) when the journal has grown enough past the last one and nothing is
// uncommitted: what a later opening reads instead of the journal.
@(private)
maybe_checkpoint :: proc(m: ^Manager, o: ^Origin, force: bool) {
	if !origin_checkpoint_due(m, o, force) || !quiescent(o) || o.compaction != nil { return }
	context.allocator = m.allocator
	pa := base.process_allocator()
	job := new(Ck_Job, pa)
	job.life, job.m, job.o, job.epoch, job.jgen = m.life, m, o, o.epoch, o.jgen
	sync.atomic_add(&m.life.refs, 1)
	job.plan = checkpoint_plan(&o.data, o.file_len, pa)
	job.old = strings.clone(origin_file(o, o.jgen, ".widx"), pa)
	job.path = strings.clone(job.old, pa)
	o.ck_busy = true
	run :: proc(data: rawptr) {
		j := (^Ck_Job)(data)
		j.ok = ck_write(&j.plan, j.old, j.path, true)
	}
	finish :: proc(data: rawptr) {
		j := (^Ck_Job)(data)
		pa := base.process_allocator()
		defer {
			ck_plan_destroy(&j.plan, pa)
			delete(j.old, pa); delete(j.path, pa)
			life_unref(j.life)
			free(j, pa)
		}
		if !j.life.alive { return }
		m, o := j.m, j.o
		sync.recursive_mutex_lock(&m.mu); defer sync.recursive_mutex_unlock(&m.mu)
		o.ck_busy = false
		if j.epoch != o.epoch || j.jgen != o.jgen { return }
		if j.ok { checkpoint_adopt(o, &j.plan) }
		maybe_compact(m, o)
	}
	if m.submit != nil {
		m.submit(m.submit_user, run, finish, job)
	} else {
		run(job)
		finish(job)
	}
}

// The checkpoint of `plan` is on the disk: the stores hold their new sections.
@(private)
checkpoint_adopt :: proc(o: ^Origin, plan: ^Ck_Plan) {
	o.ck_len = plan.journal_len
	for c in plan.stores {
		db := find_db(&o.data, c.db)
		if db == nil { continue }
		s := find_store(db, c.store)
		if s == nil { continue }
		s.section, s.has_section, s.ck_rev = c.section, true, c.rev
	}
}

////////////////////////////////
// Housekeeping

// Relaxed durability: what the system holds of the journal is flushed now and then, on the pool.
@(private)
origin_sync_maybe :: proc(m: ^Manager, o: ^Origin, now: f64) {
	if o.unsynced <= 0 || o.sync_busy || o.writing || m.settings.sync_interval_ms <= 0 || !file_valid(o.jfile) { return }
	if m.submit == nil { file_sync(o.jfile); o.unsynced = 0; return }
	o.sync_busy = true
	pa := base.process_allocator()
	Sync_Job :: struct { file: File, life: ^Life, m: ^Manager, o: ^Origin, bytes: i64 }
	job := new(Sync_Job, pa)
	job.file, job.life, job.m, job.o, job.bytes = o.jfile, m.life, m, o, o.unsynced
	sync.atomic_add(&m.life.refs, 1)
	m.submit(m.submit_user, proc(data: rawptr) {
		j := (^Sync_Job)(data)
		file_sync(j.file)
	}, proc(data: rawptr) {
		j := (^Sync_Job)(data)
		defer {
			life_unref(j.life)
			free(j, base.process_allocator())
		}
		if !j.life.alive { return }
		sync.recursive_mutex_lock(&j.m.mu); defer sync.recursive_mutex_unlock(&j.m.mu)
		j.o.sync_busy = false
		j.o.unsynced = max(j.o.unsynced - j.bytes, 0)
		if j.o.compaction != nil { compaction_writes_settled(j.m, j.o) }
	}, job)
}

// The origin is being dropped (or the manager is going): what is queued is written, the system's cache flushed, the checkpoint
// brought up to date, all synchronously.
@(private)
origin_shutdown :: proc(m: ^Manager, o: ^Origin) {
	context.allocator = m.allocator
	if m.dir == "" || o.alien || o.state != .Ready { return }
	// what has not been written yet
	if len(o.wq) > 0 {
		o.hold_writes = false
		o.writing = false
		items := make([dynamic]^Tx, context.temp_allocator)
		offs := make([dynamic]i64, context.temp_allocator)
		buf := make([dynamic]byte, context.temp_allocator)
		base_off := o.file_len
		if o.file_len == 0 { h := file_header(); append(&buf, ..h[:]) }
		for it in o.wq {
			append(&offs, base_off + i64(len(buf)))
			append(&buf, ..it.data)
			append(&items, it.tx)
			delete(it.data)
		}
		clear(&o.wq)
		ok := ensure_journal(o) && file_write_at(o.jfile, base_off, buf[:])
		complete_batch(m, o, items[:], offs[:], base_off, buf[:], ok, false)
	}
	if o.compaction != nil { compaction_abandon(m, o) }
	if file_valid(o.jfile) && o.unsynced > 0 { file_sync(o.jfile); o.unsynced = 0 }
	if origin_checkpoint_due(m, o, true) && o.loads == 0 {
		all_resident := true
		for db in o.data.dbs { for s in db.stores { if !s.resident && s.loading { all_resident = false } } }
		if all_resident {
			plan := checkpoint_plan(&o.data, o.file_len, context.temp_allocator)
			if ck_write(&plan, origin_file(o, o.jgen, ".widx"), origin_file(o, o.jgen, ".widx"), true) { checkpoint_adopt(o, &plan) }
		}
	}
}

// Removes the files of the origin (every generation) and forgets what was known of them.
@(private)
origin_wipe_files :: proc(m: ^Manager, o: ^Origin) {
	for i in 0 ..< 2 { file_close(&o.vsrc.files[i]) }
	o.jfile = {}
	if m.dir != "" {
		slash := strings.last_index_byte(o.stem, '/')
		dir, name := o.stem[:slash], o.stem[slash + 1:]
		for n in dir_files_with_prefix(dir, name) {
			rest := n[len(name):]
			_, is_j := generation_of(rest, ".widb")
			_, is_c := generation_of(rest, ".widx")
			if is_j || is_c || strings.has_suffix(rest, ".tmp") {
				file_delete(strings.concatenate({dir, "\\", n}, context.temp_allocator))
			}
		}
	}
	o.file_len, o.ck_len, o.jgen, o.unsynced = 0, 0, 0, 0
}

// Everything the origin keeps is gone: the data, the files. A write on the pool finishes first (it uses the journal's handle).
@(private)
origin_wipe :: proc(m: ^Manager, o: ^Origin) {
	context.allocator = m.allocator
	o.epoch += 1
	if o.compaction != nil { compaction_abandon(m, o) }
	data_destroy(&o.data)
	data_init(&o.data, m.allocator)
	o.data.vsrc = &o.vsrc
	o.data.cache_limit = m.settings.value_cache_bytes
	if o.writing {
		o.clear_pending = true
		return
	}
	// queued commits (their data is gone anyway) end as committed
	items := slice.clone(o.wq[:], context.temp_allocator)
	clear(&o.wq)
	for it in items {
		delete(it.data)
		if it.tx != nil { tx_finish(m, it.tx, true, .None) }
	}
	origin_wipe_files(m, o)
}

_ :: runtime
