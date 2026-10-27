package idb

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "wb:base"

// The engine under the manager: values read from the journal, checkpoints, the stores that come into memory when needed, and
// compaction (with commits going on meanwhile).

@(private)
engine_store :: proc(h: ^Harness, name := "d") -> ^Store {
	o := h.m.origins["http://a.test"]
	db := find_db(&o.data, name)
	if db == nil { return nil }
	return find_store(db, test_store)
}

@(private)
fill :: proc(h: ^Harness, c: ^Client, conn: u64, store: u32, from, n: int, size := 1024, tag := "v") {
	tx := txn(c, conn, {store}, .Read_Write)
	drain(h, c)
	for i in from ..< from + n {
		key := str_key(fmt.tprintf("k%06d", i))
		v := make([]byte, size, context.temp_allocator)
		for j in 0 ..< size { v[j] = byte('a' + (i + j) % 26) }
		copy(v, fmt.tprintf("%s%d:", tag, i))
		if e := put(c, tx, store, key, string(v)); e != .None { fmt.printf("fill: put %d failed: %v\n", i, e); break }
	}
	tx_commit(c, tx)
	drain(h, c)
}

@(private)
expect_value_of :: proc(t: ^testing.T, h: ^Harness, c: ^Client, conn: u64, store: u32, i: int, size := 1024, tag := "v") {
	tx := txn(c, conn, {store}, .Read_Only)
	drain(h, c)
	got, found, err := get(c, tx, store, str_key(fmt.tprintf("k%06d", i)))
	testing.expect(t, found && err == .None, fmt.tprintf("record %d is there (%v)", i, err))
	testing.expect_value(t, len(got), size)
	testing.expect(t, len(got) > 8 && got[:len(fmt.tprintf("%s%d:", tag, i))] == fmt.tprintf("%s%d:", tag, i), fmt.tprintf("record %d starts with its tag", i))
	tx_commit(c, tx)
	drain(h, c)
}

@(test)
values_are_read_from_the_journal_and_stores_come_back_on_demand :: proc(t: ^testing.T) {
	s := settings_default()
	s.value_cache_bytes = 0
	h: Harness
	harness_init(&h, "paged", settings = s)
	c := new_client(&h)
	conn, _ := open_and_upgrade(&h, c, "d", 1, true, make_store)
	store := test_store
	fill(&h, c, conn, store, 0, 200)
	st := engine_store(&h)
	testing.expect_value(t, st.records.count, 200)
	in_memory := 0
	it := ordered_first(&st.records)
	for pos_valid(&st.records, it) {
		_, v := pos_entry(&st.records, it)
		if (^Record)(v).value != nil { in_memory += 1 }
		pos_next(&st.records, &it)
	}
	testing.expect_value(t, in_memory, 0)   // (no cache: every value is on the disk only)
	for i in ([]int{0, 77, 199}) { expect_value_of(t, &h, c, conn, store, i) }
	client_destroy(c)
	harness_destroy(&h)   // (writes the checkpoint)

	// a new process: the keys come from the checkpoint, when a transaction needs them
	harness_init(&h, "paged", fresh = false)
	defer harness_destroy(&h)
	c = new_client(&h)
	defer client_destroy(c)
	conn2, evs := open_and_upgrade(&h, c, "d", 0, false, nil)
	testing.expect_value(t, kinds(evs), "Open_Done")
	st = engine_store(&h)
	testing.expect(t, st != nil && !st.resident, "the store is not in memory after the open")
	testing.expect_value(t, st.records.count, 0)
	expect_value_of(t, &h, c, conn2, store, 123)
	testing.expect(t, st.resident, "it was read for the transaction")
	testing.expect_value(t, st.records.count, 200)
	expect_value_of(t, &h, c, conn2, store, 0)
	expect_value_of(t, &h, c, conn2, store, 199)
}

@(test)
a_damaged_checkpoint_is_ignored_and_a_damaged_section_rebuilt :: proc(t: ^testing.T) {
	for damage in 0 ..< 2 {
		h: Harness
		harness_init(&h, "damaged")
		c := new_client(&h)
		conn, _ := open_and_upgrade(&h, c, "d", 1, true, make_store)
		store := test_store
		fill(&h, c, conn, store, 0, 50, 300)
		client_destroy(c)
		harness_destroy(&h)
		path := fmt.tprintf("%s.widx", origin_stem(&h.m, "http://a.test"))
		_ = path
		h2: Harness
		harness_init(&h2, "damaged", fresh = false)
		stem := origin_stem(&h2.m, "http://a.test")
		ck := fmt.tprintf("%s.widx", stem)
		// (a compaction on a pool thread may have moved the checkpoint to a later generation by now, and deleted the first)
		for g := u32(16); g > 0; g -= 1 {
			if p := generation_name(stem, g, ".widx", context.temp_allocator); os.exists(p) { ck = p; break }
		}
		data, err := os.read_entire_file(ck, context.temp_allocator)
		testing.expect(t, err == nil && len(data) > CK_HEADER, "a checkpoint was written")
		harness_destroy(&h2)
		// damage 0: a byte of the directory; 1: a byte of the last section
		at := CK_HEADER + 4 if damage == 0 else len(data) - 20
		data[at] ~= 0x5A
		_ = os.write_entire_file(ck, data)
		harness_init(&h, "damaged", fresh = false)
		c = new_client(&h)
		conn2, evs := open_and_upgrade(&h, c, "d", 0, false, nil)
		testing.expect_value(t, kinds(evs), "Open_Done")
		for i in ([]int{0, 25, 49}) { expect_value_of(t, &h, c, conn2, store, i, 300) }
		st := engine_store(&h)
		testing.expect_value(t, st.records.count, 50)
		client_destroy(c)
		harness_destroy(&h)
	}
}

@(test)
compaction_keeps_the_data_and_the_files_shrink :: proc(t: ^testing.T) {
	s := settings_default()
	s.compact_min_bytes = 8192
	s.compact_ratio = 1.0
	s.value_cache_bytes = 1 << 20
	h: Harness
	harness_init(&h, "engine_compact", settings = s)
	c := new_client(&h)
	conn, _ := open_and_upgrade(&h, c, "d", 1, true, make_store)
	store := test_store
	for round in 0 ..< 12 { fill(&h, c, conn, store, 0, 40, 1024, fmt.tprintf("r%d-", round)) }
	o := h.m.origins["http://a.test"]
	testing.expect(t, o.jgen >= 1, fmt.tprintf("the journal was rewritten (generation %d)", o.jgen))
	testing.expect(t, o.file_len < 120_000, fmt.tprintf("the file is small (%d bytes) for 40 live values", o.file_len))
	testing.expect(t, o.compaction == nil, "the compaction is over")
	for i in ([]int{0, 17, 39}) { expect_value_of(t, &h, c, conn, store, i, 1024, "r11-") }
	stem := origin_stem(&h.m, "http://a.test")
	testing.expect(t, !file_exists(generation_name(stem, 0, ".widb", context.temp_allocator)), "the old journal is gone")
	testing.expect(t, file_exists(generation_name(stem, o.jgen, ".widb", context.temp_allocator)), "the new one is there")
	client_destroy(c)
	harness_destroy(&h)
	// reopened: the latest generation, the data
	harness_init(&h, "engine_compact", fresh = false)
	defer harness_destroy(&h)
	c = new_client(&h)
	defer client_destroy(c)
	conn2, _ := open_and_upgrade(&h, c, "d", 0, false, nil)
	for i in ([]int{0, 17, 39}) { expect_value_of(t, &h, c, conn2, store, i, 1024, "r11-") }
}

@(test)
compaction_in_the_background_with_commits_meanwhile :: proc(t: ^testing.T) {
	s := settings_default()
	s.compact_min_bytes = 8192
	s.compact_ratio = 1.0
	h: Harness
	harness_init(&h, "compact_async", async = true, settings = s)
	defer harness_destroy(&h)
	c := new_client(&h)
	defer client_destroy(c)
	run_jobs()   // the origin loads
	conn, _ := open_and_upgrade(&h, c, "d", 1, true, make_store)
	store := test_store
	o := h.m.origins["http://a.test"]
	round := 0
	for o.compaction == nil && round < 40 {
		fill(&h, c, conn, store, 0, 40, 1024, fmt.tprintf("r%d-", round))
		for len(jobs) > 0 && o.compaction == nil { _ = run_next_job() }   // (the write, then maybe_compact queues the compaction's job)
		round += 1
	}
	testing.expect(t, o.compaction != nil, "a compaction started")
	testing.expect_value(t, len(jobs), 1)   // its copy of the live values
	// commits while its job is queued: they go to the old journal, and are carried over
	fill(&h, c, conn, store, 100, 10, 1024, "late-")
	for _ in 0 ..< 3 { _ = run_next_job() }   // the copy, its completion, then the write of the commit above (the writer was free)
	fill(&h, c, conn, store, 0, 5, 1024, "again-")
	for run_jobs() > 0 { }
	testing.expect(t, o.compaction == nil, "the compaction ended")
	testing.expect(t, o.jgen >= 1, "the new journal is the current one")
	for i in ([]int{100, 105, 109}) { expect_value_of(t, &h, c, conn, store, i, 1024, "late-") }
	for i in ([]int{0, 3, 4}) { expect_value_of(t, &h, c, conn, store, i, 1024, "again-") }
	expect_value_of(t, &h, c, conn, store, 20, 1024, fmt.tprintf("r%d-", round - 1))
}

@(private)
working_set :: proc() -> i64 {
	return base.process_memory().resident
}

// The target database: 1,000,000 records and 1 GiB of values. Run with WREN_IDB_BIG=1 (WREN_IDB_BIG_RECORDS=n for another count):
// it takes a minute and a gigabyte of disk, so it is not part of the normal run.
@(test)
a_big_database_opens_fast_and_stays_bounded :: proc(t: ^testing.T) {
	if os.get_env("WREN_IDB_BIG", context.temp_allocator) == "" { return }
	n := 1_000_000
	if v := os.get_env("WREN_IDB_BIG_RECORDS", context.temp_allocator); v != "" {
		x := 0
		for ch in v { x = x * 10 + int(ch - '0') }
		if x > 0 { n = x }
	}
	size := 1024
	s := settings_default()
	s.quota_bytes = 8 << 30
	h: Harness
	harness_init(&h, "big", settings = s)
	c := new_client(&h)
	start := time.tick_now()
	conn, _ := open_and_upgrade(&h, c, "d", 1, true, make_store)
	store := test_store
	chunk := 2000
	for from := 0; from < n; from += chunk {
		fill(&h, c, conn, store, from, min(chunk, n - from), size)
		free_all(context.temp_allocator)
	}
	fmt.printf("BIG built %d records of %d bytes in %.1f s, working set %d MiB\n", n, size, time.duration_seconds(time.tick_since(start)), working_set() >> 20)
	o := h.m.origins["http://a.test"]
	fmt.printf("BIG journal %d MiB, cache %d MiB, resident store %d MiB estimated\n", o.file_len >> 20, o.data.cache_bytes >> 20, store_memory(engine_store(&h)) >> 20)
	client_destroy(c)
	t0 := time.tick_now()
	harness_destroy(&h)   // the checkpoint
	fmt.printf("BIG shutdown (checkpoint) %.0f ms\n", time.duration_milliseconds(time.tick_since(t0)))

	ws0 := working_set()
	harness_init(&h, "big", settings = s, fresh = false)
	defer harness_destroy(&h)
	c = new_client(&h)
	defer client_destroy(c)
	t1 := time.tick_now()
	open_database(c, "d", 0, false)
	evs := drain(&h, c)
	open_ms := time.duration_milliseconds(time.tick_since(t1))
	fmt.printf("BIG open: %s in %.1f ms (the keys are not read yet), working set +%d MiB\n", kinds(evs), open_ms, (working_set() - ws0) >> 20)
	testing.expect(t, open_ms < 100, "the open takes under 100 ms")
	conn2 := last_of(evs, .Open_Done).conn
	t2 := time.tick_now()
	tx := txn(c, conn2, {store}, .Read_Only)
	drain(&h, c)
	fmt.printf("BIG first transaction started after %.0f ms (the keys of the store are read), working set +%d MiB\n", time.duration_milliseconds(time.tick_since(t2)), (working_set() - ws0) >> 20)
	got, found, _ := get(c, tx, store, str_key(fmt.tprintf("k%06d", n / 2)))
	testing.expect(t, found && len(got) == size, "a value in the middle")
	t3 := time.tick_now()
	for i in 0 ..< 1000 { _, _, _ = get(c, tx, store, str_key(fmt.tprintf("k%06d", (i * 7919) % n))) }
	fmt.printf("BIG 1000 random gets (cold values) %.1f ms\n", time.duration_milliseconds(time.tick_since(t3)))
	tx_commit(c, tx)
	drain(&h, c)
	fmt.printf("BIG working set after the reads: +%d MiB over the idle manager\n", (working_set() - ws0) >> 20)
}