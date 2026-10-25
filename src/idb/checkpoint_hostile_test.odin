package idb

import "core:encoding/endian"
import "core:hash"
import "core:os"
import "core:testing"

// A checkpoint file in the profile is read back at the next start. Its sizes are numbers of 64 bits from the file: none may be
// turned into a signed length or offset before it is checked (security review of 2026-10-25, finding 8).

@(private = "file")
hostile_checkpoint :: proc(journal_len: u64, section: [4]u64) -> []byte {
	dir: Writer
	dir.data = make([dynamic]byte, context.temp_allocator)
	w_bytes(&dir, nil)         // no schema operations
	w_uv(&dir, 0)              // no next ids
	w_uv(&dir, 1)              // one section
	w_str(&dir, "d"); w_uv(&dir, 1)
	for v in section { w_uv(&dir, v) }
	head := make([]byte, CK_HEADER + len(dir.data), context.temp_allocator)
	copy(head, CK_MAGIC)
	endian.put_u32(head[4:], .Little, CK_FORMAT)
	endian.put_u64(head[8:], .Little, journal_len)
	endian.put_u32(head[16:], .Little, u32(len(dir.data)))
	endian.put_u32(head[20:], .Little, hash.crc32(dir.data[:]))
	copy(head[CK_HEADER:], dir.data[:])
	return head
}

@(private = "file")
reads_as :: proc(t: ^testing.T, name: string, data: []byte, journal_size: i64) -> bool {
	_ = os.make_directory_all("build/tmp")
	path := "build/tmp/idb_hostile.widx"
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, data) == nil)
	f, ok := file_open(path, false, false)
	testing.expectf(t, ok, "%s: file", name)
	defer file_close(&f)
	dir, dok := ck_read_directory(f, journal_size, context.temp_allocator)
	_ = dir
	return dok
}

@(test)
a_hostile_checkpoint_is_refused_not_trusted :: proc(t: ^testing.T) {
	// the sane one is read (so that the refusals below are the sizes' and not the file's)
	good := hostile_checkpoint(8, {0, 0, 0, 0})
	testing.expect(t, reads_as(t, "sane", good, 100))

	top := u64(1) << 63
	// the journal length: a bit 63 makes it negative as an i64; it must be bigger than the journal, not smaller than it
	testing.expect(t, !reads_as(t, "journal length 1<<63", hostile_checkpoint(top, {0, 0, 0, 0}), 100))
	testing.expect(t, !reads_as(t, "journal length 1<<63 + 8", hostile_checkpoint(top + 8, {0, 0, 0, 0}), 100))
	testing.expect(t, !reads_as(t, "journal length max", hostile_checkpoint(max(u64), {0, 0, 0, 0}), 100))
	testing.expect(t, !reads_as(t, "journal length over the journal", hostile_checkpoint(101, {0, 0, 0, 0}), 100))
	testing.expect(t, !reads_as(t, "journal length under the header", hostile_checkpoint(7, {0, 0, 0, 0}), 100))
	testing.expect(t, !reads_as(t, "a journal size that is not one", hostile_checkpoint(8, {0, 0, 0, 0}), -1))
	// a section: offset, length, count, bytes
	for c in ([][4]u64{
		{top, 0, 0, 0}, {0, top, 0, 0}, {top, top, 0, 0}, {max(u64), 1, 0, 0}, {1, max(u64), 0, 0}, {max(u64) / 2, max(u64) / 2 + 2, 0, 0},
		{0, 0, 1, 0}, {0, 4, 5, 0}, {0, 0, 0, top}, {0, 0, 0, max(u64)}, {1 << 40, 0, 0, 0}, {0, 1 << 40, 0, 0},
	}) {
		testing.expectf(t, !reads_as(t, "section", hostile_checkpoint(8, c), 100), "section %v is refused", c)
	}
}

@(test)
a_section_inside_the_file_is_kept :: proc(t: ^testing.T) {
	// a directory of one section that lies in the file after it: 4 bytes, 2 records
	data := hostile_checkpoint(8, {0, 4, 2, 4})
	data = append_bytes(data, {1, 2, 3, 4})
	_ = os.make_directory_all("build/tmp")
	path := "build/tmp/idb_hostile_ok.widx"
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, data) == nil)
	f, ok := file_open(path, false, false)
	testing.expect(t, ok)
	defer file_close(&f)
	dir, dok := ck_read_directory(f, 100, context.temp_allocator)
	testing.expect(t, dok)
	if dok && len(dir.entries) == 1 {
		testing.expect_value(t, dir.entries[0].section.len, 4)
		testing.expect_value(t, dir.entries[0].section.count, 2)
		testing.expect_value(t, dir.entries[0].bytes, 4)
	}
}

@(private = "file")
append_bytes :: proc(a: []byte, b: []byte) -> []byte {
	out := make([]byte, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return out
}