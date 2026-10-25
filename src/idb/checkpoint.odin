package idb

import "base:runtime"
import "core:bytes"
import "core:encoding/endian"
import "core:hash"
import "core:slice"

// The checkpoint of an origin: a file next to its journal (`<origin>.widx`) with the keys of every store, so that opening
// does not read the journal. It holds the schema (databases, stores, indexes, key generators) and, for each store, its records
// in key order: key, where the value is in the journal (offset and length), and index keys. Values are not in it.
//
//   header, 32 bytes:  "WIDX", u32 format, u64 journal length covered, u32 directory length, u32 directory CRC-32, 8 spare
//   directory:         the schema as ops (length prefixed), each database's next store and index ids, then for each store its
//                      database, id, section (offset after the directory, length, record count) and quota bytes
//   store sections:    blocks of about 256 KiB: u32 payload length, u32 CRC-32, u32 record count, then per record
//                      u32 key length, u32 value length, u64 value offset, u32 index key count, the key, and each index key
//                      (u32 index, u32 length, bytes)
//
// It stands for the state of the journal up to a length: opening replays what follows (the tail) over it, and a store is
// brought into memory from its section when a transaction needs it (ck_load_store). A damaged checkpoint is ignored: the
// journal alone says everything. A section has the same length whatever the offsets of the values it names (fixed-width
// fields), which a compaction relies on.

CK_MAGIC       :: "WIDX"
CK_FORMAT      :: 1
CK_HEADER      :: 32
CK_BLOCK_BYTES :: 256 << 10

// A store's records in the checkpoint file (offset from the start of the file).
Section :: struct { off, len: i64, count: int }

// A part of a checkpoint to write: bytes in memory, or a range of the checkpoint it replaces (the section of a store that is
// not in memory is copied as it is: nothing changed in it since).
Ck_Part :: struct {
	data:      []byte,
	from, len: i64,
}

Ck_Store :: struct {
	db:       string,
	store:    u32,
	rev:      u32,
	section:  Section,   // where it will be in the new file
}

Ck_Plan :: struct {
	schema:      []byte,   // the schema as ops (what a compaction writes at the start of the new journal)
	head:        []byte,
	parts:       [dynamic]Ck_Part,
	journal_len: i64,
	stores:      [dynamic]Ck_Store,
	total:       i64,
}

Ck_Entry :: struct {
	db:      string,
	store:   u32,
	section: Section,
	bytes:   i64,
}

Ck_Dir :: struct {
	journal_len: i64,
	schema:      []byte,   // ops
	next_ids:    [dynamic]Ck_Next,
	entries:     [dynamic]Ck_Entry,
	file_size:   i64,
}

Ck_Next :: struct { db: string, store, index: u32 }

////////////////////////////////
// Writing

// Encoder of a store's section: records added one by one, blocks made as they fill.
Sec_Writer :: struct {
	out:  [dynamic]byte,
	blk:  [dynamic]byte,
	nrec: int,
}

sec_writer_init :: proc(sw: ^Sec_Writer, allocator: runtime.Allocator, hint := 4096) {
	sw.out = make([dynamic]byte, 0, hint, allocator)
	sw.blk = make([dynamic]byte, 0, CK_BLOCK_BYTES + 4096, allocator)
}

@(private)
sec_flush :: proc(sw: ^Sec_Writer) {
	if sw.nrec == 0 { return }
	hdr: [12]byte
	endian.put_u32(hdr[0:], .Little, u32(len(sw.blk)))
	endian.put_u32(hdr[4:], .Little, hash.crc32(sw.blk[:]))
	endian.put_u32(hdr[8:], .Little, u32(sw.nrec))
	append(&sw.out, ..hdr[:])
	append(&sw.out, ..sw.blk[:])
	clear(&sw.blk)
	sw.nrec = 0
}

sec_add :: proc(sw: ^Sec_Writer, key: []byte, vlen: u32, voff: i64, ikeys: []Index_Key) {
	put32 :: proc(b: ^[dynamic]byte, v: u32) {
		t: [4]byte
		endian.put_u32(t[:], .Little, v)
		append(b, ..t[:])
	}
	put32(&sw.blk, u32(len(key)))
	put32(&sw.blk, vlen)
	t: [8]byte
	endian.put_u64(t[:], .Little, u64(voff))
	append(&sw.blk, ..t[:])
	put32(&sw.blk, u32(len(ikeys)))
	append(&sw.blk, ..key)
	for k in ikeys {
		put32(&sw.blk, k.index)
		put32(&sw.blk, u32(len(k.key)))
		append(&sw.blk, ..k.key)
	}
	sw.nrec += 1
	if len(sw.blk) >= CK_BLOCK_BYTES { sec_flush(sw) }
}

// The section's bytes (the writer's buffers are freed).
sec_finish :: proc(sw: ^Sec_Writer) -> []byte {
	sec_flush(sw)
	delete(sw.blk)
	return sw.out[:]
}

// One store's records as blocks (the caller's allocator).
ck_encode_store :: proc(d: ^Data, s: ^Store, allocator: runtime.Allocator) -> []byte {
	sw: Sec_Writer
	sec_writer_init(&sw, allocator, 4096 + s.records.count * 40)
	it := ordered_first(&s.records)
	for pos_valid(&s.records, it) {
		_, v := pos_entry(&s.records, it)
		r := (^Record)(v)
		sec_add(&sw, r.key, r.vlen, r.voff, r.ikeys[:])
		pos_next(&s.records, &it)
	}
	return sec_finish(&sw)
}

// The checkpoint of `d` as of the journal length `journal_len`: the schema, the sections of the stores in memory (encoded
// now) and, for the others, ranges of the checkpoint they came from. The data must be at rest (nothing uncommitted).
checkpoint_plan :: proc(d: ^Data, journal_len: i64, allocator: runtime.Allocator) -> (plan: Ck_Plan) {
	context.allocator = allocator
	plan.journal_len = journal_len
	plan.parts = make([dynamic]Ck_Part)
	plan.stores = make([dynamic]Ck_Store)
	schema: Writer
	schema.data = make([dynamic]byte, context.temp_allocator)
	for db in d.dbs {
		op_encode(&schema, Op{kind = .Db_Version, db = db.name, version = db.version})
		for s in db.stores {
			op_encode(&schema, Op{kind = .Store_Create, db = db.name, store = s.id, name = s.name, key_path = s.key_path, flags = 1 if s.auto_increment else 0})
			for ix in s.indexes {
				f: u8 = (1 if ix.unique else 0) | (2 if ix.multi else 0)
				op_encode(&schema, Op{kind = .Index_Create, db = db.name, store = s.id, index = ix.id, name = ix.name, key_path = ix.key_path, flags = f})
			}
			op_encode(&schema, Op{kind = .Key_Gen, db = db.name, store = s.id, gen = s.gen})
		}
	}
	plan.schema = make([]byte, len(schema.data))
	copy(plan.schema, schema.data[:])
	dir: Writer
	dir.data = make([dynamic]byte, context.temp_allocator)
	w_bytes(&dir, schema.data[:])
	w_uv(&dir, u64(len(d.dbs)))
	for db in d.dbs { w_str(&dir, db.name); w_uv(&dir, u64(db.next_store_id)); w_uv(&dir, u64(db.next_index_id)) }
	n := 0
	for db in d.dbs { n += len(db.stores) }
	w_uv(&dir, u64(n))
	rel: i64
	for db in d.dbs {
		for s in db.stores {
			part: Ck_Part
			sec := Section{count = s.records.count}
			if s.resident {
				part.data = ck_encode_store(d, s, allocator)
				part.len = i64(len(part.data))
			} else {
				part.from, part.len = s.section.off, s.section.len
				sec.count = s.section.count
			}
			sec.off, sec.len = rel, part.len   // (relative to the end of the directory until the head is made)
			w_str(&dir, db.name); w_uv(&dir, u64(s.id))
			w_uv(&dir, u64(sec.off)); w_uv(&dir, u64(sec.len)); w_uv(&dir, u64(sec.count)); w_uv(&dir, u64(max(s.bytes, 0)))
			append(&plan.parts, part)
			append(&plan.stores, Ck_Store{db = db.name, store = s.id, rev = s.rev, section = sec})
			rel += part.len
		}
	}
	base := i64(CK_HEADER + len(dir.data))
	for &c in plan.stores { c.section.off += base }
	plan.total = base + rel
	plan.head = make([]byte, CK_HEADER + len(dir.data))
	copy(plan.head, CK_MAGIC)
	endian.put_u32(plan.head[4:], .Little, CK_FORMAT)
	endian.put_u64(plan.head[8:], .Little, u64(journal_len))
	endian.put_u32(plan.head[16:], .Little, u32(len(dir.data)))
	endian.put_u32(plan.head[20:], .Little, hash.crc32(dir.data[:]))
	copy(plan.head[CK_HEADER:], dir.data[:])
	// (the store names in the plan are the database's: they live as long as the data does; copies for a job on another thread)
	for &c in plan.stores { c.db = clone_str(c.db, allocator) }
	return
}

ck_plan_destroy :: proc(plan: ^Ck_Plan, allocator: runtime.Allocator) {
	delete(plan.head, allocator)
	delete(plan.schema, allocator)
	for p in plan.parts { delete(p.data, allocator) }
	delete(plan.parts)
	for c in plan.stores { delete(c.db, allocator) }
	delete(plan.stores)
	plan^ = {}
}

// Writes the plan to `path` through a temporary file (flushed if asked, then renamed over the old one unless `rename` is false:
// the file stays at `path`.tmp). `old` is the checkpoint the copied ranges come from. Any thread.
ck_write :: proc(plan: ^Ck_Plan, old_path: string, path: string, flush: bool, rename := true) -> bool {
	tmp := join2(path, ".tmp")
	defer delete(tmp)
	f, ok := file_open(tmp, true, true)
	if !ok { return false }
	good := file_truncate(f, 0)
	off: i64
	if good { good = file_write_at(f, 0, plan.head) }
	off = i64(len(plan.head))
	buf: []byte
	defer delete(buf)
	old: File
	defer file_close(&old)   // (closed before the rename: a file that is open cannot be replaced)
	for p in plan.parts {
		if !good { break }
		if p.data != nil || p.len == 0 {
			good = file_write_at(f, off, p.data)
			off += i64(len(p.data))
			continue
		}
		if buf == nil {
			buf = make([]byte, 1 << 20)
			ok2: bool
			old, ok2 = file_open(old_path, false, false)
			if !ok2 { good = false; break }
		}
		for done := i64(0); done < p.len && good; {
			n := int(min(i64(len(buf)), p.len - done))
			good = file_read_at(old, p.from + done, buf[:n]) && file_write_at(f, off, buf[:n])
			done += i64(n)
			off += i64(n)
		}
	}
	if good && flush { good = file_sync(f) }
	file_close(&f)
	file_close(&old)
	if !good { file_delete(tmp); return false }
	if rename && !file_rename(tmp, path) { file_delete(tmp); return false }
	return true
}

////////////////////////////////
// Reading

// The directory of the checkpoint in `f` (a small read), or ok false if it is damaged or of another format.
// `journal_size`: the journal's size (a checkpoint that claims more than the journal has is not trusted).
ck_read_directory :: proc(f: File, journal_size: i64, allocator: runtime.Allocator) -> (dir: Ck_Dir, ok: bool) {
	size, sok := file_size(f)
	if !sok || size < CK_HEADER { return }
	head: [CK_HEADER]byte
	if !file_read_at(f, 0, head[:]) { return }
	if string(head[:4]) != CK_MAGIC { return }
	if v, _ := endian.get_u32(head[4:], .Little); v != CK_FORMAT { return }
	jl, _ := endian.get_u64(head[8:], .Little)
	dl, _ := endian.get_u32(head[16:], .Little)
	dcrc, _ := endian.get_u32(head[20:], .Little)
	// (compared as unsigned: a 64-bit length with the top bit set is negative as an i64 and passed these tests)
	if i64(dl) > size - CK_HEADER || journal_size < 0 || jl > u64(journal_size) || jl < HEADER_SIZE { return }
	raw := make([]byte, int(dl), context.temp_allocator)
	if !file_read_at(f, CK_HEADER, raw) { return }
	if hash.crc32(raw) != dcrc { return }
	r := Reader{data = raw}
	dir.journal_len = i64(jl)
	dir.file_size = size
	schema := r_bytes(&r)
	dir.schema = make([]byte, len(schema), allocator)
	copy(dir.schema, schema)
	nd_u := r_uv(&r)
	if r.bad || nd_u > u64(len(raw)) { delete(dir.schema, allocator); return }
	nd := int(nd_u)
	dir.next_ids = make([dynamic]Ck_Next, 0, nd, allocator)
	for _ in 0 ..< nd {
		name := r_str(&r)
		append(&dir.next_ids, Ck_Next{db = clone_str(name, allocator), store = u32(r_uv(&r)), index = u32(r_uv(&r))})
	}
	ns_u := r_uv(&r)
	if r.bad || ns_u > u64(len(raw)) { ck_dir_destroy(&dir, allocator); return }
	ns := int(ns_u)
	dir.entries = make([dynamic]Ck_Entry, 0, ns, allocator)
	base := i64(CK_HEADER) + i64(dl)
	for _ in 0 ..< ns {
		name := r_str(&r)
		e := Ck_Entry{db = clone_str(name, allocator), store = u32(r_uv(&r))}
		// (every number is checked as unsigned against the file before it is turned into a signed offset or length that sums can overflow)
		rel, length, count, bytes := r_uv(&r), r_uv(&r), r_uv(&r), r_uv(&r)
		avail := u64(size - base)
		if r.bad || base > size || rel > avail || length > avail - rel || count > length || bytes > 1 << 62 {
			delete(e.db, allocator); ck_dir_destroy(&dir, allocator); return
		}
		e.section.off, e.section.len, e.section.count, e.bytes = base + i64(rel), i64(length), int(count), i64(bytes)
		append(&dir.entries, e)
	}
	if r.bad { ck_dir_destroy(&dir, allocator); return }
	return dir, true
}

ck_dir_destroy :: proc(d: ^Ck_Dir, allocator: runtime.Allocator) {
	delete(d.schema, allocator)
	for n in d.next_ids { delete(n.db, allocator) }
	delete(d.next_ids)
	for e in d.entries { delete(e.db, allocator) }
	delete(d.entries)
	d^ = {}
}

// Builds the schema of `d` from a directory: the databases, stores (not in memory, with their sections) and indexes.
ck_apply_directory :: proc(d: ^Data, dir: ^Ck_Dir) -> bool {
	r := Reader{data = dir.schema}
	for r.pos < len(dir.schema) {
		op, ok := op_decode(&r, d.allocator)
		if !ok { return false }
		apply(d, op, nil)
		delete(op.ikeys, d.allocator)
	}
	for n in dir.next_ids {
		if db := find_db(d, n.db); db != nil {
			db.next_store_id = max(db.next_store_id, n.store)
			db.next_index_id = max(db.next_index_id, n.index)
		}
	}
	for e in dir.entries {
		db := find_db(d, e.db)
		if db == nil { return false }
		s := find_store(db, e.store)
		if s == nil { return false }
		s.resident, s.has_section, s.section = false, true, e.section
		s.bytes = e.bytes
		d.bytes += e.bytes
	}
	return true
}

// Where a section is read from: a file, or bytes in memory (offsets are then in the bytes).
Ck_Src :: struct {
	f:   File,
	mem: []byte,
}

@(private)
src_read :: proc(src: Ck_Src, off: i64, buf: []byte) -> bool {
	if src.mem != nil {
		if off < 0 || off + i64(len(buf)) > i64(len(src.mem)) { return false }
		copy(buf, src.mem[off:][:len(buf)])
		return true
	}
	return file_read_at(src.f, off, buf)
}

// Each record of a section, in order, goes to `visit`(key, value length, value offset, index keys); false stops it. The key and
// index key bytes are valid until `visit` returns. ok false when the section is damaged.
ck_read_section :: proc(src: Ck_Src, sec: Section, user: rawptr, visit: proc(user: rawptr, key: []byte, vlen: u32, voff: i64, ikeys: []Index_Key) -> bool, allocator: runtime.Allocator) -> (ok: bool) {
	buf := make([dynamic]byte, 0, 1 << 20, allocator)
	defer delete(buf)
	ikeys := make([dynamic]Index_Key, 0, 8, allocator)
	defer delete(ikeys)
	pos := sec.off
	end := sec.off + sec.len
	seen := 0
	for pos < end {
		if end - pos < 12 { return false }
		hdr: [12]byte
		if !src_read(src, pos, hdr[:]) { return false }
		plen, _ := endian.get_u32(hdr[0:], .Little)
		crc, _ := endian.get_u32(hdr[4:], .Little)
		nrec, _ := endian.get_u32(hdr[8:], .Little)
		if i64(plen) > end - pos - 12 { return false }
		resize(&buf, int(plen))
		if !src_read(src, pos + 12, buf[:]) { return false }
		if hash.crc32(buf[:]) != crc { return false }
		p := 0
		for _ in 0 ..< int(nrec) {
			if len(buf) - p < 20 { return false }
			klen, _ := endian.get_u32(buf[p:], .Little)
			vlen, _ := endian.get_u32(buf[p + 4:], .Little)
			voff, _ := endian.get_u64(buf[p + 8:], .Little)
			nik, _ := endian.get_u32(buf[p + 16:], .Little)
			p += 20
			if int(klen) > len(buf) - p { return false }
			key := buf[p:][:klen]
			p += int(klen)
			clear(&ikeys)
			for _ in 0 ..< int(nik) {
				if len(buf) - p < 8 { return false }
				idx, _ := endian.get_u32(buf[p:], .Little)
				kl, _ := endian.get_u32(buf[p + 4:], .Little)
				p += 8
				if int(kl) > len(buf) - p { return false }
				append(&ikeys, Index_Key{idx, buf[p:][:kl]})
				p += int(kl)
			}
			if !visit(user, key, vlen, i64(voff), ikeys[:]) { return true }
			seen += 1
		}
		pos += 12 + i64(plen)
	}
	return seen == sec.count
}

// Fills the (empty) store `s` from its section: the records, and the entries of each of its indexes, built in order. `s`'s
// indexes must be there (their ids say which index keys of a record still count). The records' values stay on the disk.
ck_load_store :: proc(d: ^Data, s: ^Store, f: File) -> bool {
	Ctx :: struct {
		d:     ^Data,
		s:     ^Store,
		keys:  [dynamic][]byte,
		vals:  [dynamic]rawptr,
		bytes: i64,
		gen:   u8,
	}
	ctx := Ctx{d = d, s = s, gen = d.replay_gen}
	ctx.keys = make([dynamic][]byte, 0, s.section.count, context.temp_allocator)
	ctx.vals = make([dynamic]rawptr, 0, s.section.count, context.temp_allocator)
	visit :: proc(user: rawptr, key: []byte, vlen: u32, voff: i64, ikeys: []Index_Key) -> bool {
		c := (^Ctx)(user)
		a := c.d.allocator
		r := new(Record, a)
		r.key = make([]byte, len(key), a)
		copy(r.key, key)
		r.vlen, r.voff, r.gen = vlen, voff, c.gen
		if len(ikeys) > 0 {
			r.ikeys = make([dynamic]Index_Key, 0, len(ikeys), a)
			for k in ikeys {
				if find_index(c.s, k.index) == nil { continue }   // (an index that is gone)
				kk := make([]byte, len(k.key), a)
				copy(kk, k.key)
				append(&r.ikeys, Index_Key{k.index, kk})
			}
		}
		append(&c.keys, r.key)
		append(&c.vals, rawptr(r))
		c.bytes += record_cost(r)
		return true
	}
	if !ck_read_section(Ck_Src{f = f}, s.section, &ctx, visit, context.temp_allocator) {
		for v in ctx.vals { record_free(d, (^Record)(v)) }
		return false
	}
	// strictly increasing keys, as written: anything else is a damaged file
	for i in 1 ..< len(ctx.keys) {
		if bytes.compare(ctx.keys[i - 1], ctx.keys[i]) >= 0 {
			for v in ctx.vals { record_free(d, (^Record)(v)) }
			return false
		}
	}
	ordered_clear(&s.records)
	ordered_bulk_load(&s.records, ctx.keys[:], ctx.vals[:])
	s.bytes = ctx.bytes
	// the index entries: one list per index, sorted
	Entry :: struct { key: []byte, rec: rawptr }
	for ix in s.indexes {
		list := make([dynamic]Entry, 0, len(ctx.vals), context.temp_allocator)
		for v in ctx.vals {
			r := (^Record)(v)
			for k in r.ikeys {
				if k.index == ix.id { append(&list, Entry{composite_key(k.key, r.key, d.allocator), v}) }
			}
		}
		slice.sort_by(list[:], proc(a, b: Entry) -> bool { return bytes.compare(a.key, b.key) < 0 })
		ks := make([][]byte, len(list), context.temp_allocator)
		vs := make([]rawptr, len(list), context.temp_allocator)
		for e, i in list { ks[i], vs[i] = e.key, e.rec }
		ordered_clear(&ix.entries)
		ordered_bulk_load(&ix.entries, ks, vs, take = true)
	}
	s.resident = true
	return true
}
