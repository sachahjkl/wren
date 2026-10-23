package idb

import "core:bytes"
import "core:fmt"
import "core:math/rand"
import "core:testing"

Fixture :: struct {
	d:        Data,
	settings: Settings,
	undo:     Undo_Log,
	redo:     Writer,
	x:         Exec,
	quota:    i64,
}

fixture_init :: proc(f: ^Fixture, db := "db") {
	data_init(&f.d, context.allocator)
	f.settings = settings_default()
	f.quota = 1 << 30
	apply(&f.d, Op{kind = .Db_Version, db = db, version = 1}, nil)
	fixture_begin(f, db)
}

fixture_destroy :: proc(f: ^Fixture) {
	undo_discard(&f.d, &f.undo)
	writer_destroy(&f.redo)
	data_destroy(&f.d)
}

// A new transaction's log (the previous one is kept: its changes stay).
fixture_begin :: proc(f: ^Fixture, db: string) {
	if f.undo.entries != nil { undo_discard(&f.d, &f.undo) }
	undo_log_init(&f.undo)
	clear(&f.redo.data)
	f.x = Exec{d = &f.d, db = find_db(&f.d, db), undo = &f.undo, redo = &f.redo, settings = &f.settings, quota = f.quota}
}

@(private)
str_key :: proc(s: string) -> []byte {
	b := Key_Builder{data = make([dynamic]byte, context.temp_allocator)}
	key_put_string(&b, s)
	return b.data[:]
}

@(private)
num_key :: proc(v: f64) -> []byte { return enc_number(v) }

// A canonical image of the whole data, for comparing states.
@(private)
dump :: proc(d: ^Data) -> string {
	w: Writer
	w.data = make([dynamic]byte, context.temp_allocator)
	snapshot_ops(d, 1 << 30, proc(user: rawptr, payload: []byte) { append(&(^Writer)(user).data, ..payload) }, &w)
	return string(w.data[:])
}

@(test)
put_get_replace_delete :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	sid, err := exec_create_store(&f.x, "s", nil, false)
	testing.expect_value(t, err, Error.None)
	k, e := exec_put(&f.x, sid, str_key("a"), transmute([]byte)string("one"), nil, false)
	testing.expect_value(t, e, Error.None)
	testing.expect(t, bytes.equal(k, str_key("a")), "key returned")
	_, e = exec_put(&f.x, sid, str_key("a"), transmute([]byte)string("two"), nil, true)
	testing.expect_value(t, e, Error.Constraint)   // add on an existing key
	_, e = exec_put(&f.x, sid, str_key("a"), transmute([]byte)string("two"), nil, false)
	testing.expect_value(t, e, Error.None)
	s := find_store(f.x.db, sid)
	hit, found := first_in_range(Source{store = s}, Range{lower = str_key("a"), upper = str_key("a"), has_lower = true, has_upper = true})
	testing.expect(t, found && string(hit.rec.value) == "two", "replaced")
	testing.expect_value(t, s.records.count, 1)
	testing.expect_value(t, e, Error.None)
	testing.expect_value(t, exec_delete_range(&f.x, sid, Range{lower = str_key("a"), upper = str_key("a"), has_lower = true, has_upper = true}), Error.None)
	testing.expect_value(t, s.records.count, 0)
	testing.expect_value(t, f.d.bytes, 0)
}

@(test)
key_generator_follows_explicit_numbers :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	sid, _ := exec_create_store(&f.x, "s", nil, true)
	k1, _ := exec_put(&f.x, sid, nil, nil, nil, false)
	n1, _ := key_number(k1)
	testing.expect_value(t, n1, 1)
	exec_put(&f.x, sid, num_key(10), nil, nil, false)
	k2, _ := exec_put(&f.x, sid, nil, nil, nil, false)
	n2, _ := key_number(k2)
	testing.expect_value(t, n2, 11)
	exec_put(&f.x, sid, num_key(3.7), nil, nil, false)   // below the generator: no change
	exec_put(&f.x, sid, str_key("x"), nil, nil, false)   // not a number: no change
	k3, _ := exec_put(&f.x, sid, nil, nil, nil, false)
	n3, _ := key_number(k3)
	testing.expect_value(t, n3, 12)
	exec_put(&f.x, sid, num_key(1e300), nil, nil, false)
	_, e := exec_put(&f.x, sid, nil, nil, nil, false)
	testing.expect_value(t, e, Error.Constraint)   // past 2^53
	// a store without a generator needs a key
	sid2, _ := exec_create_store(&f.x, "plain", nil, false)
	_, e = exec_put(&f.x, sid2, nil, nil, nil, false)
	testing.expect_value(t, e, Error.Data)
}

@(test)
unique_index_and_multi_entry :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	sid, _ := exec_create_store(&f.x, "s", nil, false)
	uid, _ := exec_create_index(&f.x, sid, "by_u", nil, true, false)
	mid, _ := exec_create_index(&f.x, sid, "by_m", nil, false, true)
	ik := []Index_Key{{uid, str_key("u1")}, {mid, str_key("t1")}, {mid, str_key("t2")}}
	_, e := exec_put(&f.x, sid, num_key(1), nil, ik, false)
	testing.expect_value(t, e, Error.None)
	_, e = exec_put(&f.x, sid, num_key(2), nil, []Index_Key{{uid, str_key("u1")}}, false)
	testing.expect_value(t, e, Error.Constraint)
	_, e = exec_put(&f.x, sid, num_key(1), nil, []Index_Key{{uid, str_key("u1")}}, false)
	testing.expect_value(t, e, Error.None)   // the same record may keep its own key
	s := find_store(f.x.db, sid)
	mi := find_index(s, mid)
	testing.expect_value(t, mi.entries.count, 0)   // replaced without the multi entries
	_, e = exec_put(&f.x, sid, num_key(3), nil, ik[1:], false)
	testing.expect_value(t, e, Error.None)
	testing.expect_value(t, mi.entries.count, 2)
	// a binary key that begins another's is not "the same key"
	bid, _ := exec_create_index(&f.x, sid, "by_b", nil, true, false)
	empty := enc_binary({})
	zero := enc_binary({0})
	_, e = exec_put(&f.x, sid, num_key(4), nil, []Index_Key{{bid, empty}}, false)
	testing.expect_value(t, e, Error.None)
	_, e = exec_put(&f.x, sid, num_key(5), nil, []Index_Key{{bid, zero}}, false)
	testing.expect_value(t, e, Error.None)
	_, e = exec_put(&f.x, sid, num_key(6), nil, []Index_Key{{bid, zero}}, false)
	testing.expect_value(t, e, Error.Constraint)
}

@(test)
rollback_restores_everything :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	sid, _ := exec_create_store(&f.x, "s", {1, 'k'}, true)
	iid, _ := exec_create_index(&f.x, sid, "i", nil, false, false)
	for i in 0 ..< 50 {
		exec_put(&f.x, sid, num_key(f64(i)), transmute([]byte)fmt.tprintf("value %d", i), []Index_Key{{iid, str_key(fmt.tprintf("%d", i % 7))}}, false)
	}
	fixture_begin(&f, "db")   // the schema and 50 records are committed
	before := dump(&f.d)
	before_bytes := f.d.bytes
	// a transaction that changes everything it can, then aborts
	s := find_store(f.x.db, sid)
	exec_put(&f.x, sid, num_key(5), transmute([]byte)string("replaced"), nil, false)
	exec_put(&f.x, sid, nil, transmute([]byte)string("generated"), []Index_Key{{iid, str_key("g")}}, false)
	exec_delete_range(&f.x, sid, Range{lower = num_key(10), upper = num_key(20), has_lower = true, has_upper = true})
	exec_index_put(&f.x, sid, iid, num_key(30), {str_key("extra")})
	exec_rename_store(&f.x, sid, "renamed")
	exec_rename_index(&f.x, sid, iid, "renamed_i")
	nid, _ := exec_create_store(&f.x, "n", nil, false)
	exec_put(&f.x, nid, num_key(1), nil, nil, false)
	exec_clear(&f.x, sid)
	exec_put(&f.x, sid, num_key(99), transmute([]byte)string("after clear"), nil, false)
	exec_delete_index(&f.x, sid, iid)
	exec_delete_store(&f.x, sid)
	testing.expect(t, dump(&f.d) != before, "changed")
	_ = s
	undo_rollback(&f.d, &f.undo)
	testing.expect_value(t, dump(&f.d), before)
	testing.expect_value(t, f.d.bytes, before_bytes)
	s = find_store(find_db(&f.d, "db"), sid)
	testing.expect(t, s != nil && s.name == "s", "the store is back under its name")
	testing.expect_value(t, s.records.count, 50)
	testing.expect_value(t, find_index(s, iid).entries.count, 50)
	testing.expect_value(t, s.gen, 50)
	f.undo = {}   // rolled back: nothing to discard
}

@(test)
quota_and_size_limits :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	sid, _ := exec_create_store(&f.x, "s", nil, false)
	f.x.quota = 1000
	big := make([]byte, 600, context.temp_allocator)
	_, e := exec_put(&f.x, sid, num_key(1), big, nil, false)
	testing.expect_value(t, e, Error.None)
	_, e = exec_put(&f.x, sid, num_key(2), big, nil, false)
	testing.expect_value(t, e, Error.Quota)
	_, e = exec_put(&f.x, sid, num_key(1), big, nil, false)
	testing.expect_value(t, e, Error.None)   // a replacement of the same size fits
	f.x.quota = 1 << 30
	f.settings.max_value_bytes = 100
	_, e = exec_put(&f.x, sid, num_key(3), big, nil, false)
	testing.expect_value(t, e, Error.Too_Large)
	f.settings.max_key_bytes = 4
	_, e = exec_put(&f.x, sid, num_key(3), nil, nil, false)
	testing.expect_value(t, e, Error.Too_Large)
	_, e = exec_put(&f.x, sid, []byte{1, 2}, nil, nil, false)
	testing.expect_value(t, e, Error.Data)   // not a key
}

@(test)
ops_round_trip_through_the_encoding :: proc(t: ^testing.T) {
	ops := []Op{
		{kind = .Db_Version, db = "d", version = 77},
		{kind = .Store_Create, db = "d", store = 3, name = "s", key_path = {1, 2}, flags = 1},
		{kind = .Index_Create, db = "d", store = 3, index = 9, name = "i", key_path = {1}, flags = 3},
		{kind = .Put, db = "d", store = 3, key = {1, 2, 3}, value = {9, 9}, ikeys = {{9, {5}}, {9, {6, 7}}}},
		{kind = .Delete, db = "d", store = 3, key = {1, 2, 3}},
		{kind = .Index_Put, db = "d", store = 3, key = {1}, ikeys = {{9, {5}}}},
		{kind = .Key_Gen, db = "d", store = 3, gen = 12.5},
		{kind = .Store_Rename, db = "d", store = 3, name = "ß"},
		{kind = .Db_Delete, db = "d"},
	}
	w: Writer
	defer writer_destroy(&w)
	for op in ops { op_encode(&w, op) }
	r := Reader{data = w.data[:]}
	for want in ops {
		got, ok := op_decode(&r, context.allocator)
		testing.expect(t, ok, "decodes")
		testing.expect_value(t, got.kind, want.kind)
		testing.expect_value(t, got.db, want.db)
		testing.expect_value(t, got.store, want.store)
		testing.expect_value(t, got.name, want.name)
		testing.expect_value(t, got.version, want.version)
		testing.expect_value(t, got.gen, want.gen)
		testing.expect_value(t, len(got.ikeys), len(want.ikeys))
		testing.expect(t, bytes.equal(got.key, want.key) && bytes.equal(got.value, want.value), "bytes")
		delete(got.ikeys)
	}
	testing.expect_value(t, r.pos, len(w.data))
	// a truncated stream never decodes
	for n in 0 ..< len(w.data) {
		rr := Reader{data = w.data[:n]}
		cnt := 0
		for rr.pos < n {
			op, ok := op_decode(&rr, context.allocator)
			if !ok { break }
			delete(op.ikeys)
			cnt += 1
		}
		testing.expect(t, cnt < len(ops), "cut stream gives fewer ops")
	}
}

@(test)
cursor_matches_a_naive_walk :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	gen := rand.create(99)
	context.random_generator = rand.default_random_generator(&gen)
	sid, _ := exec_create_store(&f.x, "s", nil, false)
	iid, _ := exec_create_index(&f.x, sid, "i", nil, false, false)
	// records: pk 0..199, index key pk % 13 (with gaps in the pks)
	Rec :: struct { pk, ik: int }
	recs := make([dynamic]Rec, context.temp_allocator)
	for i in 0 ..< 200 {
		if rand.int_max(4) == 0 { continue }
		ik := rand.int_max(13)
		append(&recs, Rec{i, ik})
		exec_put(&f.x, sid, num_key(f64(i)), nil, []Index_Key{{iid, num_key(f64(ik))}}, false)
	}
	s := find_store(f.x.db, sid)
	src_store := Source{store = s}
	src_index := Source{store = s, index = find_index(s, iid)}
	// the model: sort recs by (ik, pk) for the index, by pk for the store
	less_index :: proc(a, b: Rec) -> bool { return a.ik < b.ik || (a.ik == b.ik && a.pk < b.pk) }
	sorted := make([dynamic]Rec, len(recs), context.temp_allocator)
	copy(sorted[:], recs[:])
	for i in 1 ..< len(sorted) {
		for j := i; j > 0 && less_index(sorted[j], sorted[j - 1]); j -= 1 { sorted[j], sorted[j - 1] = sorted[j - 1], sorted[j] }
	}
	// forward walk of the whole index
	{
		cur: Cursor_Hit
		have := false
		idx := 0
		for {
			q := Cursor_Request{direction = .Next, has_cur = have, cur_key = cur.key, cur_pk = cur.pk}
			hit, found := cursor_step(src_index, q)
			if !found { break }
			testing.expect(t, idx < len(sorted), "not past the end")
			if idx >= len(sorted) { break }
			wk, _ := key_number(hit.key)
			wp, _ := key_number(hit.pk)
			testing.expect_value(t, int(wk), sorted[idx].ik)
			testing.expect_value(t, int(wp), sorted[idx].pk)
			cur, have = hit, true
			idx += 1
		}
		testing.expect_value(t, idx, len(sorted))
	}
	// backward walk
	{
		cur: Cursor_Hit
		have := false
		idx := len(sorted) - 1
		for {
			q := Cursor_Request{direction = .Prev, has_cur = have, cur_key = cur.key, cur_pk = cur.pk}
			hit, found := cursor_step(src_index, q)
			if !found { break }
			if idx < 0 { testing.expect(t, false, "past the start"); break }
			wk, _ := key_number(hit.key)
			wp, _ := key_number(hit.pk)
			testing.expect_value(t, int(wk), sorted[idx].ik)
			testing.expect_value(t, int(wp), sorted[idx].pk)
			cur, have = hit, true
			idx -= 1
		}
		testing.expect_value(t, idx, -1)
	}
	// unique directions: the first (lowest pk) entry of each distinct index key
	{
		firsts := make([dynamic]Rec, context.temp_allocator)
		for r, i in sorted { if i == 0 || sorted[i - 1].ik != r.ik { append(&firsts, r) } }
		for dir in ([]Direction{.Next_Unique, .Prev_Unique}) {
			cur: Cursor_Hit
			have := false
			n := 0
			for {
				q := Cursor_Request{direction = dir, has_cur = have, cur_key = cur.key, cur_pk = cur.pk}
				hit, found := cursor_step(src_index, q)
				if !found { break }
				want := firsts[n] if dir == .Next_Unique else firsts[len(firsts) - 1 - n]
				wk, _ := key_number(hit.key)
				wp, _ := key_number(hit.pk)
				testing.expect_value(t, int(wk), want.ik)
				testing.expect_value(t, int(wp), want.pk)
				cur, have = hit, true
				n += 1
			}
			testing.expect_value(t, n, len(firsts))
		}
	}
	// a range, and continue(key) / continuePrimaryKey / advance
	{
		r := Range{lower = num_key(3), upper = num_key(8), has_lower = true, has_upper = true, lower_open = true}
		count := 0
		for x in sorted { if x.ik > 3 && x.ik <= 8 { count += 1 } }
		testing.expect_value(t, count_range(src_index, r), count)
		hit, found := cursor_step(src_index, Cursor_Request{range = r, direction = .Next, has_cur = false})
		testing.expect(t, found, "first in range")
		wk, _ := key_number(hit.key)
		testing.expect(t, int(wk) > 3, "after the open lower bound")
		// continue(key 6) from the first: lands on the first entry with index key >= 6
		hit2, found2 := cursor_step(src_index, Cursor_Request{range = r, direction = .Next, has_cur = true, cur_key = hit.key, cur_pk = hit.pk, has_target = true, target = num_key(6)})
		testing.expect(t, found2, "continue(key)")
		k2, _ := key_number(hit2.key)
		testing.expect(t, int(k2) >= 6 && int(k2) <= 8, "continue lands at >= 6")
		// advance(5)
		hit3, found3 := cursor_step(src_index, Cursor_Request{range = r, direction = .Next, has_cur = true, cur_key = hit.key, cur_pk = hit.pk, count = 5})
		inrange := make([dynamic]Rec, context.temp_allocator)
		for x in sorted { if x.ik > 3 && x.ik <= 8 { append(&inrange, x) } }
		testing.expect(t, found3 && len(inrange) > 5, "advance finds an entry")
		if found3 && len(inrange) > 5 {
			p3, _ := key_number(hit3.pk)
			testing.expect_value(t, int(p3), inrange[5].pk)
		}
	}
	// the store itself, backwards
	{
		cur: Cursor_Hit
		have := false
		idx := len(recs) - 1
		for {
			hit, found := cursor_step(src_store, Cursor_Request{direction = .Prev, has_cur = have, cur_key = cur.key})
			if !found { break }
			p, _ := key_number(hit.key)
			testing.expect_value(t, int(p), recs[idx].pk)
			cur, have = hit, true
			idx -= 1
		}
		testing.expect_value(t, idx, -1)
	}
}

@(test)
a_committed_rename_frees_the_old_names :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer fixture_destroy(&f)
	sid, _ := exec_create_store(&f.x, "before", nil, false)
	iid, _ := exec_create_index(&f.x, sid, "ibefore", nil, false, false)
	fixture_begin(&f, "db")
	testing.expect_value(t, exec_rename_store(&f.x, sid, "after"), Error.None)
	testing.expect_value(t, exec_rename_index(&f.x, sid, iid, "iafter"), Error.None)
	testing.expect_value(t, exec_rename_store(&f.x, sid, "after"), Error.None)
	fixture_begin(&f, "db")   // commits: the old names go (the test's tracker reports a leak otherwise)
	s := find_store(f.x.db, sid)
	testing.expect_value(t, s.name, "after")
	testing.expect_value(t, find_index(s, iid).name, "iafter")
	_, e := exec_create_store(&f.x, "after", nil, false)
	testing.expect_value(t, e, Error.Constraint)
}

@(test)
replaying_a_journal_keeps_nothing_it_does_not_own :: proc(t: ^testing.T) {
	d: Data
	data_init(&d, context.allocator)
	defer data_destroy(&d)
	ik := []Index_Key{{1, str_key("x")}}
	ops := []Op{
		{kind = .Db_Version, db = "db", version = 1},
		{kind = .Store_Create, db = "db", store = 1, name = "s", key_path = []byte{1, 2, 3, 4, 5}},
		{kind = .Put, db = "db", store = 1, key = str_key("a"), value = []byte{1, 2}},
		{kind = .Index_Create, db = "db", store = 1, index = 1, name = "i", key_path = []byte{9, 9}},
		{kind = .Index_Put, db = "db", store = 1, key = str_key("a"), ikeys = ik},
		{kind = .Key_Gen, db = "db", store = 1, gen = 5},
		{kind = .Store_Rename, db = "db", store = 1, name = "t"},
		{kind = .Index_Rename, db = "db", store = 1, index = 1, name = "j"},
		{kind = .Delete, db = "db", store = 1, key = str_key("a")},
		{kind = .Put, db = "db", store = 1, key = str_key("b"), value = []byte{1, 2}, ikeys = ik},
		{kind = .Store_Clear, db = "db", store = 1},
		{kind = .Index_Delete, db = "db", store = 1, index = 1},
		{kind = .Store_Delete, db = "db", store = 1},
		{kind = .Db_Version, db = "db", version = 2},
		{kind = .Db_Delete, db = "db"},
		{kind = .Db_Version, db = "keep", version = 1},
		{kind = .Store_Create, db = "keep", store = 1, name = "s"},
	}
	for op in ops { testing.expect_value(t, apply(&d, op, nil), Error.None) }
	testing.expect_value(t, len(d.dbs), 1)
}
