package idb

import "core:fmt"
import "core:os"
import "core:testing"
import "wb:base"

@(private)
temp_path :: proc(name: string) -> string {
	dir := fmt.tprintf("%s/wren_idb_test", base.temp_dir(context.temp_allocator))
	os.make_directory_all(dir)
	return fmt.tprintf("%s/%s", dir, name)
}

// A Fixture with a store and `n` records, its changes as one journal record (the redo stream of its transaction).
@(private)
populate :: proc(f: ^Fixture, n: int) -> (redo: []byte) {
	sid, _ := exec_create_store(&f.x, "s", {1, 'k'}, true)
	iid, _ := exec_create_index(&f.x, sid, "i", nil, false, true)
	for i in 0 ..< n {
		exec_put(&f.x, sid, nil, transmute([]byte)fmt.tprintf("value %d", i),
			[]Index_Key{{iid, str_key(fmt.tprintf("a%d", i % 5))}, {iid, str_key("common")}}, false)
	}
	return clone_bytes(f.redo.data[:], context.temp_allocator)
}

@(test)
journal_round_trip :: proc(t: ^testing.T) {
	path := temp_path("round_trip.widb")
	defer os.remove(path)
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	// version record, then the transaction's
	w: Writer
	defer writer_destroy(&w)
	op_encode(&w, Op{kind = .Db_Version, db = "db", version = 1})
	redo := populate(&f, 100)
	out := make([dynamic]byte, context.temp_allocator)
	h := file_header()
	append(&out, ..h[:])
	frame_payload(&out, w.data[:])
	frame_payload(&out, redo)
	testing.expect(t, replace_file(path, out[:], false), "written")

	res := load_file(path, context.allocator)
	defer data_destroy(&res.data)
	testing.expect_value(t, res.records, 2)
	testing.expect(t, !res.damaged && !res.alien, "clean")
	testing.expect_value(t, res.good_len, i64(len(out)))
	testing.expect_value(t, dump(&res.data), dump(&f.d))
	testing.expect_value(t, res.data.bytes, f.d.bytes)

	// a snapshot of the data is the same data
	snap := snapshot_file(&res.data, context.temp_allocator)
	testing.expect(t, replace_file(path, snap, true), "snapshot written")
	res2 := load_file(path, context.allocator)
	defer data_destroy(&res2.data)
	testing.expect_value(t, dump(&res2.data), dump(&f.d))
	testing.expect_value(t, res2.data.bytes, f.d.bytes)
}

@(test)
a_journal_cut_anywhere_loads_a_prefix :: proc(t: ^testing.T) {
	path := temp_path("cut.widb")
	defer os.remove(path)
	// three committed transactions, then every possible truncation of the file
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	out := make([dynamic]byte, context.temp_allocator)
	h := file_header()
	append(&out, ..h[:])
	ends := make([dynamic]int, context.temp_allocator)
	states := make([dynamic]string, context.temp_allocator)
	w: Writer
	defer writer_destroy(&w)
	op_encode(&w, Op{kind = .Db_Version, db = "db", version = 1})
	frame_payload(&out, w.data[:])
	append(&ends, len(out)); append(&states, "")
	redo := populate(&f, 10)
	frame_payload(&out, redo)
	append(&ends, len(out))
	for round in 0 ..< 2 {
		fixture_begin(&f, "db")
		s := f.x.db.stores[0]
		exec_put(&f.x, s.id, nil, transmute([]byte)fmt.tprintf("more %d", round), nil, false)
		frame_payload(&out, clone_bytes(f.redo.data[:], context.temp_allocator))
		append(&ends, len(out))
	}
	// expected state after each complete record, by loading the exact prefix
	full := out[:]
	for cut in 0 ..= len(full) {
		_ = os.write_entire_file(path, full[:cut])
		res := load_file(path, context.allocator)
		complete := 0
		for e in ends { if e <= cut { complete += 1 } }
		testing.expectf(t, res.records == complete, "cut at %d: %d records, want %d", cut, res.records, complete)
		if cut >= HEADER_SIZE {
			want_len := i64(HEADER_SIZE) if complete == 0 else i64(ends[complete - 1])
			testing.expectf(t, res.good_len == want_len, "cut at %d: good_len %d want %d", cut, res.good_len, want_len)
		}
		testing.expect(t, ordered_check_all(&res.data), "consistent")
		data_destroy(&res.data)
	}
	// the damage is overwritten by the next append
	cut := ends[2] - 5
	_ = os.write_entire_file(path, full[:cut])
	res := load_file(path, context.allocator)
	testing.expect(t, res.damaged, "damage seen")
	next := make([dynamic]byte, context.temp_allocator)
	frame_payload(&next, w.data[:])   // any valid record
	testing.expect(t, append_file(path, res.good_len, next[:], true), "appended")
	res2 := load_file(path, context.allocator)
	testing.expect_value(t, res2.records, res.records + 1)
	testing.expect(t, !res2.damaged, "clean again")
	data_destroy(&res.data)
	data_destroy(&res2.data)
}

@(test)
a_flipped_byte_ends_the_journal_there :: proc(t: ^testing.T) {
	path := temp_path("flip.widb")
	defer os.remove(path)
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	out := make([dynamic]byte, context.temp_allocator)
	h := file_header()
	append(&out, ..h[:])
	w: Writer
	defer writer_destroy(&w)
	op_encode(&w, Op{kind = .Db_Version, db = "db", version = 1})
	frame_payload(&out, w.data[:])
	first_end := len(out)
	redo := populate(&f, 20)
	frame_payload(&out, redo)
	for pos in first_end ..< len(out) {
		bad := make([]byte, len(out), context.temp_allocator)
		copy(bad, out[:])
		bad[pos] ~= 0x40
		_ = os.write_entire_file(path, bad)
		res := load_file(path, context.allocator)
		testing.expectf(t, res.records == 1 && res.damaged, "flip at %d: %d records", pos, res.records)
		data_destroy(&res.data)
		if t.error_count > 0 { break }
	}
	// not a journal at all
	_ = os.write_entire_file(path, transmute([]byte)string("this is not an IndexedDB journal"))
	res := load_file(path, context.allocator)
	testing.expect(t, res.alien, "alien file")
	data_destroy(&res.data)
	// a missing file is an empty origin
	os.remove(path)
	res = load_file(path, context.allocator)
	testing.expect(t, res.records == 0 && !res.alien && res.good_len == 0, "missing is empty")
	data_destroy(&res.data)
}

@(test)
append_after_a_failed_write_keeps_the_file :: proc(t: ^testing.T) {
	path := temp_path("append.widb")
	defer os.remove(path)
	os.remove(path)
	out := make([dynamic]byte, context.temp_allocator)
	h := file_header()
	append(&out, ..h[:])
	w: Writer
	defer writer_destroy(&w)
	op_encode(&w, Op{kind = .Db_Version, db = "db", version = 3})
	frame_payload(&out, w.data[:])
	testing.expect(t, append_file(path, 0, out[:], false), "first write")
	more := make([dynamic]byte, context.temp_allocator)
	w2: Writer
	defer writer_destroy(&w2)
	op_encode(&w2, Op{kind = .Db_Version, db = "db", version = 4})
	frame_payload(&more, w2.data[:])
	testing.expect(t, append_file(path, i64(len(out)), more[:], false), "second write")
	res := load_file(path, context.allocator)
	defer data_destroy(&res.data)
	testing.expect_value(t, res.records, 2)
	testing.expect_value(t, find_db(&res.data, "db").version, 4)
}

// Every ordered structure of the data is well formed, every record is in every index it says.
@(private)
ordered_check_all :: proc(d: ^Data) -> bool {
	for db in d.dbs {
		for s in db.stores {
			if !ordered_check(&s.records) { return false }
			for ix in s.indexes {
				if !ordered_check(&ix.entries) { return false }
			}
			it := ordered_first(&s.records)
			for pos_valid(&s.records, it) {
				_, v := pos_entry(&s.records, it)
				r := (^Record)(v)
				for k in r.ikeys {
					ix := find_index(s, k.index)
					if ix == nil { return false }
					if _, found := ordered_get(&ix.entries, composite_key(k.key, r.key, context.temp_allocator)); !found { return false }
				}
				pos_next(&s.records, &it)
			}
		}
	}
	return true
}
