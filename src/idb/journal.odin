package idb

import "base:runtime"
import "core:encoding/endian"
import "core:hash"
import "core:slice"
import "core:strconv"
import "core:strings"

// The file of an origin: a journal. After an 8-byte header ("WIDB", format 1) come records, each
//
//   u32 length | u32 CRC-32 of the payload | payload     (little endian)
//
// and a payload is a kind byte (1: one committed transaction) followed by ops (model.odin). A transaction is one record,
// so it is on the disk completely or not at all: a record cut short, or whose checksum is wrong (a write interrupted by
// a crash or a power cut), ends the journal there, and the next write starts at that point, over the damage.
//
// Opening does not read the whole journal when a checkpoint (checkpoint.odin) covers the start of it: the schema comes
// from the checkpoint, the records that follow it (the tail) are replayed over it, and a store's records are read from the
// checkpoint when a transaction needs them. Values are never kept by the replay: they are read from the journal when a request
// asks. When there is no usable checkpoint the journal is replayed from its start, in a stream (the file is not read into
// memory), each Put keeping where its value is.
//
// Files: `<origin>.widb` is the journal, `<origin>.widx` its checkpoint. A compaction writes a new generation, `<origin>~N.widb`
// and `<origin>~N.widx`, and the old files go once nothing reads them: the highest generation with a readable journal is the
// current one.

FILE_MAGIC   :: "WIDB"
FILE_FORMAT  :: 1
HEADER_SIZE  :: 8
FRAME_HEADER :: 8
RECORD_BATCH :: 1

Load_Result :: struct {
	data:      Data,
	good_len:  i64,    // the end of the last good record: where the next write goes
	file_size: i64,
	records:   int,
	damaged:   bool,   // bytes after good_len were not a record (they are overwritten by the next write)
	alien:   bool,   // the file is not a journal of this format (it is left alone and the origin starts empty, in memory)
}

file_header :: proc() -> [HEADER_SIZE]byte {
	h: [HEADER_SIZE]byte
	copy(h[:], FILE_MAGIC)
	endian.put_u32(h[4:], .Little, FILE_FORMAT)
	return h
}

// Appends the framing of a payload (kind + ops) to `out`.
frame_payload :: proc(out: ^[dynamic]byte, ops: []byte) {
	n := len(ops) + 1
	var_len: [4]byte
	endian.put_u32(var_len[:], .Little, u32(n))
	crc_in := make([]byte, n, context.temp_allocator)
	crc_in[0] = RECORD_BATCH
	copy(crc_in[1:], ops)
	var_crc: [4]byte
	endian.put_u32(var_crc[:], .Little, hash.crc32(crc_in))
	append(out, ..var_len[:])
	append(out, ..var_crc[:])
	append(out, ..crc_in)
}

////////////////////////////////
// Reading records in a stream

// Records of a journal file from an offset, through a read-ahead buffer: only the record being looked at (and what was read
// ahead of it) is in memory.
Frame_Reader :: struct {
	f:    File,
	size: i64,
	buf:  [dynamic]byte,
	base: i64,   // the file offset of buf[0]
	pos:  int,
	end:  i64,   // the end of the last good record
}

frame_reader_init :: proc(fr: ^Frame_Reader, f: File, size, from: i64, allocator: runtime.Allocator) {
	fr^ = {f = f, size = size, base = from, end = from}
	fr.buf = make([dynamic]byte, 0, 1 << 20, allocator)
}

frame_reader_destroy :: proc(fr: ^Frame_Reader) { delete(fr.buf) }

@(private)
fr_fill :: proc(fr: ^Frame_Reader, need: int) -> bool {
	have := len(fr.buf) - fr.pos
	if have >= need { return true }
	if fr.pos > 0 && (fr.pos >= len(fr.buf) / 2 || fr.pos > 1 << 20) {
		copy(fr.buf[:], fr.buf[fr.pos:])
		resize(&fr.buf, have)
		fr.base += i64(fr.pos)
		fr.pos = 0
	}
	at := fr.base + i64(len(fr.buf))
	left := fr.size - at
	if left < i64(need - have) { return false }
	n := int(min(left, i64(max(need - have, 1 << 20))))
	old := len(fr.buf)
	resize(&fr.buf, old + n)
	if !file_read_at(fr.f, at, fr.buf[old:]) { resize(&fr.buf, old); return false }
	return true
}

// The next good record: its payload (kind byte first), valid until the next call, and its offset in the file. False at the end
// of the file or of the good records (a record cut short, or with a wrong checksum).
frame_next :: proc(fr: ^Frame_Reader) -> (payload: []byte, payload_off: i64, ok: bool) {
	if !fr_fill(fr, FRAME_HEADER) { return }
	n, _ := endian.get_u32(fr.buf[fr.pos:], .Little)
	crc, _ := endian.get_u32(fr.buf[fr.pos + 4:], .Little)
	if n < 1 { return }
	at := fr.base + i64(fr.pos)
	if i64(n) > fr.size - at - FRAME_HEADER { return }
	if !fr_fill(fr, FRAME_HEADER + int(n)) { return }
	payload = fr.buf[fr.pos + FRAME_HEADER:][:n]
	if hash.crc32(payload) != crc || payload[0] != RECORD_BATCH { return nil, 0, false }
	payload_off = at + FRAME_HEADER
	fr.pos += FRAME_HEADER + int(n)
	fr.end = at + FRAME_HEADER + i64(n)
	return payload, payload_off, true
}

Replay_Mode :: enum u8 {
	All,           // every op
	Origin_Tail,   // the records after a checkpoint: schema ops, and the data ops of the stores that are in memory (the others are read with their section)
	Store_Only,    // the data ops of one store (the records after its section)
}

// Applies the ops of one record's payload. `ops_off`: the file offset of the ops, when values are not kept (paged replay), else < 0.
// False if one is malformed (the record, though its checksum was right, is not used: ops applied before the bad one stay,
// which cannot happen with a record this code wrote).
replay_ops :: proc(d: ^Data, ops: []byte, ops_off: i64, mode: Replay_Mode, db: string = "", store: u32 = 0) -> bool {
	r := Reader{data = ops}
	d.replay_base = ops_off
	defer d.replay_base = -1
	for r.pos < len(ops) {
		op, ok := op_decode(&r, d.allocator)
		if !ok { return false }
		data_op := op.kind == .Put || op.kind == .Delete || op.kind == .Index_Put || op.kind == .Store_Clear
		switch mode {
		case .All:
			apply(d, op, nil)
		case .Origin_Tail:
			if data_op {
				if dbp := find_db(d, op.db); dbp != nil {
					if s := find_store(dbp, op.store); s != nil && s.resident { apply(d, op, nil) }
				}
			} else {
				apply(d, op, nil)
			}
		case .Store_Only:
			if data_op && op.db == db && op.store == store { apply(d, op, nil) }
		}
		delete(op.ikeys, d.allocator)
	}
	return true
}

// Reads and replays the whole journal at `path` (a missing file is an empty origin). `paged`: the values stay in the file (the data
// then holds where they are, and needs Data.vsrc to read them); else they are read into memory. Any thread; memory from
// `allocator`.
load_file :: proc(path: string, allocator: runtime.Allocator, paged := false) -> (res: Load_Result) {
	data_init(&res.data, allocator)
	f, ok := file_open(path, false, false)
	if !ok { return }
	defer file_close(&f)
	size, _ := file_size(f)
	res.file_size = size
	// shorter than a header: a file whose creation was interrupted, nothing in it (rewritten); another content: not ours
	if size < HEADER_SIZE { return }
	hdr: [HEADER_SIZE]byte
	if !file_read_at(f, 0, hdr[:]) { return }
	if string(hdr[:4]) != FILE_MAGIC { res.alien = true; return }
	if v, _ := endian.get_u32(hdr[4:], .Little); v != FILE_FORMAT { res.alien = true; return }
	fr: Frame_Reader
	frame_reader_init(&fr, f, size, HEADER_SIZE, context.temp_allocator)
	res.good_len = HEADER_SIZE
	for {
		payload, off, fok := frame_next(&fr)
		if !fok { break }
		if !replay_ops(&res.data, payload[1:], off + 1 if paged else -1, .All) { break }
		res.good_len = fr.end
		res.records += 1
	}
	res.damaged = res.good_len < res.file_size
	return
}

// Writes `data` at `offset` of the file (created if needed), cutting whatever follows, optionally flushed to the disk.
// `data` begins with the header when offset is 0. False if it could not be written; the file is then cut back to `offset`.
append_file :: proc(path: string, offset: i64, data: []byte, flush: bool) -> bool {
	f, ok := file_open(path, true, true)
	if !ok { return false }
	defer file_close(&f)
	if size, sok := file_size(f); sok && size > offset {
		if !file_truncate(f, offset) { return false }
	}
	if !file_write_at(f, offset, data) {
		file_truncate(f, offset)
		return false
	}
	if flush && !file_sync(f) {
		file_truncate(f, offset)   // (the transaction is rolled back: its record must not come back at the next load)
		return false
	}
	return true
}

// Replaces the file by `data` (header included) atomically: a temporary file, flushed, renamed over it.
replace_file :: proc(path: string, data: []byte, flush: bool) -> bool {
	parts := [][]byte{data}
	return file_replace_parts(path, parts, flush)
}

@(private)
join2 :: proc(a, b: string) -> string {
	out := make([]byte, len(a) + len(b))
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

// The image of a fresh journal holding exactly `d` (every store in memory): header and records.
snapshot_file :: proc(d: ^Data, allocator: runtime.Allocator) -> []byte {
	out := make([dynamic]byte, 0, 4096, allocator)
	h := file_header()
	append(&out, ..h[:])
	Ctx :: struct { out: ^[dynamic]byte }
	c := Ctx{&out}
	snapshot_ops(d, 1 << 20, proc(user: rawptr, payload: []byte) {
		frame_payload((^Ctx)(user).out, payload)
	}, &c)
	return out[:]
}

////////////////////////////////
// Opening an origin

// `<stem>.widb` (generation 0) or `<stem>~N.widb`; the checkpoint's likewise with `.widx`.
generation_name :: proc(stem: string, gen: u32, ext: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, stem)
	if gen > 0 {
		strings.write_byte(&b, '~')
		strings.write_u64(&b, u64(gen))
	}
	strings.write_string(&b, ext)
	return strings.to_string(b)
}

// The generation a file name of this origin stands for (after the stem: ".widb", or "~N.widb"; with ext ".widx" for the checkpoint).
@(private)
generation_of :: proc(rest, ext: string) -> (gen: u32, ok: bool) {
	if rest == ext { return 0, true }
	if !strings.has_prefix(rest, "~") || !strings.has_suffix(rest, ext) { return 0, false }
	digits := rest[1:len(rest) - len(ext)]
	if len(digits) == 0 { return 0, false }
	n, parsed := strconv.parse_u64(digits)
	if !parsed || n == 0 || n > 0xFFFF_FFFF { return 0, false }
	return u32(n), true
}

Origin_Load :: struct {
	data:       Data,
	jfile:      File,      // the journal, open for reading and writing (invalid: there is none yet)
	jgen:       u32,
	good_len:   i64,       // where the next record goes (0: the header is still to write)
	size:       i64,
	records:    int,       // records replayed
	alien:      bool,
	damaged:    bool,
	ck_len:     i64,       // the journal length the checkpoint stands for (0: no usable checkpoint)
	ck_gen:     u32,
	full:       bool,      // no checkpoint: every store is in memory
	tail_bytes: i64,       // journal after the checkpoint
}

// Opens the origin whose files are `<dir>/<stem>...`: picks the current generation (removing the older ones), reads the
// checkpoint's directory and the tail of the journal, or replays the journal in a stream. Any thread; memory from `allocator`.
load_origin :: proc(dir, stem: string, allocator: runtime.Allocator) -> (res: Origin_Load) {
	data_init(&res.data, allocator)
	res.data.replay_gen = 0
	names := dir_files_with_prefix(dir, stem)
	gens := make([dynamic]u32, context.temp_allocator)
	for n in names {
		rest := n[len(stem):]
		if g, ok := generation_of(rest, ".widb"); ok { append(&gens, g) }
		if strings.has_suffix(rest, ".tmp") && (strings.has_prefix(rest, ".wid") || strings.has_prefix(rest, "~")) {
			file_delete(strings.concatenate({dir, "\\", n}, context.temp_allocator))   // a write that never finished
		}
	}
	if len(gens) == 0 { return }
	slice.sort_by(gens[:], proc(a, b: u32) -> bool { return a > b })
	res.jgen = gens[0]
	res.data.replay_gen = u8(res.jgen & 1)
	// older generations: what a finished compaction left (or one that died: the highest generation is complete)
	for g in gens[1:] {
		file_delete(strings.concatenate({dir, "\\", generation_name(stem, g, ".widb", context.temp_allocator)}, context.temp_allocator))
		file_delete(strings.concatenate({dir, "\\", generation_name(stem, g, ".widx", context.temp_allocator)}, context.temp_allocator))
	}
	for n in names {
		rest := n[len(stem):]
		if g, ok := generation_of(rest, ".widx"); ok && g != res.jgen {
			file_delete(strings.concatenate({dir, "\\", n}, context.temp_allocator))
		}
	}
	jpath := strings.concatenate({dir, "\\", generation_name(stem, res.jgen, ".widb", context.temp_allocator)}, context.temp_allocator)
	f, ok := file_open(jpath, true, false)
	if !ok { return }
	size, _ := file_size(f)
	res.size = size
	res.jfile = f
	if size < HEADER_SIZE { return }   // creation interrupted: nothing in it (the first write starts it again)
	hdr: [HEADER_SIZE]byte
	if !file_read_at(f, 0, hdr[:]) { return }
	if string(hdr[:4]) != FILE_MAGIC { res.alien = true; file_close(&res.jfile); return }
	if v, _ := endian.get_u32(hdr[4:], .Little); v != FILE_FORMAT { res.alien = true; file_close(&res.jfile); return }

	// the checkpoint
	from := i64(HEADER_SIZE)
	ckpath := strings.concatenate({dir, "\\", generation_name(stem, res.jgen, ".widx", context.temp_allocator)}, context.temp_allocator)
	if ckf, cok := file_open(ckpath, false, false); cok {
		if cd, dok := ck_read_directory(ckf, size, context.temp_allocator); dok {
			if ck_apply_directory(&res.data, &cd) {
				res.ck_len, res.ck_gen = cd.journal_len, res.jgen
				from = cd.journal_len
			} else {
				data_destroy(&res.data)
				data_init(&res.data, allocator)
				res.data.replay_gen = u8(res.jgen & 1)
			}
		}
		file_close(&ckf)
	}
	res.full = res.ck_len == 0
	fr: Frame_Reader
	frame_reader_init(&fr, f, size, from, context.temp_allocator)
	res.good_len = from
	for {
		payload, off, pok := frame_next(&fr)
		if !pok { break }
		mode := Replay_Mode.All if res.full else Replay_Mode.Origin_Tail
		if !replay_ops(&res.data, payload[1:], off + 1, mode) { break }
		res.good_len = fr.end
		res.records += 1
	}
	if res.full && res.good_len < HEADER_SIZE { res.good_len = HEADER_SIZE }
	res.tail_bytes = res.good_len - from
	res.damaged = res.good_len < size
	if res.damaged { file_truncate(f, res.good_len) }   // (the next record starts there)
	return
}
