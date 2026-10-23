package idb

import "base:runtime"
import "core:encoding/endian"
import "core:hash"
import "core:os"

// The file of an origin: a journal. After an 8-byte header ("WIDB", format 1) come records, each
//
//   u32 length | u32 CRC-32 of the payload | payload     (little endian)
//
// and a payload is a kind byte (1: one committed transaction) followed by ops (model.odin). A transaction is one record,
// so it is on the disk completely or not at all: a record cut short, or whose checksum is wrong (a write interrupted by
// a crash or a power cut), ends the journal there, and the next write starts at that point, over the damage. Opening
// replays the records in order into an empty Data. When the dead records outweigh the live ones the whole file is
// rewritten from a snapshot of the data (to a temporary file, flushed, renamed over the old one).

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

// Reads and replays the file at `path` (a missing file is an empty origin). Any thread; memory from `allocator`.
load_file :: proc(path: string, allocator: runtime.Allocator) -> (res: Load_Result) {
	data_init(&res.data, allocator)
	raw, err := os.read_entire_file(path, allocator)
	defer delete(raw, allocator)
	if err != nil { return }
	res.file_size = i64(len(raw))
	// shorter than a header: a file whose creation was interrupted, nothing in it (rewritten); another content: not ours
	if len(raw) < HEADER_SIZE { return }
	if string(raw[:4]) != FILE_MAGIC { res.alien = true; return }
	if v, _ := endian.get_u32(raw[4:], .Little); v != FILE_FORMAT { res.alien = true; return }
	o := HEADER_SIZE
	res.good_len = HEADER_SIZE
	for o + FRAME_HEADER <= len(raw) {
		n, _ := endian.get_u32(raw[o:], .Little)
		crc, _ := endian.get_u32(raw[o + 4:], .Little)
		if n < 1 || int(n) > len(raw) - o - FRAME_HEADER { break }
		payload := raw[o + FRAME_HEADER:][:n]
		if hash.crc32(payload) != crc || payload[0] != RECORD_BATCH { break }
		if !replay(&res.data, payload[1:]) { break }
		o += FRAME_HEADER + int(n)
		res.good_len = i64(o)
		res.records += 1
	}
	res.damaged = res.good_len < res.file_size
	return
}

// Applies the ops of one record. False if one is malformed (the record, though its checksum was right, is not used:
// ops applied before the bad one stay, which cannot happen with a record this code wrote).
@(private)
replay :: proc(d: ^Data, ops: []byte) -> bool {
	r := Reader{data = ops}
	for r.pos < len(ops) {
		op, ok := op_decode(&r, d.allocator)
		if !ok { return false }
		// a store or index missing is an inconsistent journal; the ops that can still be applied are
		apply(d, op, nil)
		delete(op.ikeys, d.allocator)
	}
	return true
}

// Writes `data` at `offset` of the file (created if needed), cutting whatever follows, optionally flushed to the disk.
// `data` begins with the header when offset is 0. False if it could not be written; the file is then cut back to `offset`.
append_file :: proc(path: string, offset: i64, data: []byte, flush: bool) -> bool {
	f, err := os.open(path, {.Read, .Write, .Create})
	if err != nil { return false }
	defer os.close(f)
	if size, serr := os.file_size(f); serr == nil && size > offset {
		if os.truncate(f, offset) != nil { return false }
	}
	if _, serr := os.seek(f, offset, .Start); serr != nil { return false }
	n, werr := os.write(f, data)
	if werr != nil || n != len(data) {
		os.truncate(f, offset)
		return false
	}
	if flush && os.sync(f) != nil { return false }
	return true
}

// Replaces the file by `data` (header included) atomically: a temporary file, flushed, renamed over it.
replace_file :: proc(path: string, data: []byte, flush: bool) -> bool {
	tmp := join2(path, ".tmp")
	defer delete(tmp)
	f, err := os.open(tmp, {.Write, .Create, .Trunc})
	if err != nil { return false }
	n, werr := os.write(f, data)
	ok := werr == nil && n == len(data)
	if ok && flush { ok = os.sync(f) == nil }
	os.close(f)
	if !ok { os.remove(tmp); return false }
	if os.rename(tmp, path) != nil {
		os.remove(path)
		if os.rename(tmp, path) != nil { os.remove(tmp); return false }
	}
	return true
}

@(private)
join2 :: proc(a, b: string) -> string {
	out := make([]byte, len(a) + len(b))
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

// The image of a fresh journal holding exactly `d`: header and records.
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
