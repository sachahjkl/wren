package idb

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// A manager whose disk work is queued and run on demand, to see the order things happen in.
Job :: struct { work, done: proc(rawptr), data: rawptr }

@(private, thread_local)
jobs: [dynamic]Job
@(private, thread_local)
clock: f64

@(private)
test_submit :: proc(user: rawptr, work, done: proc(data: rawptr), data: rawptr) { append(&jobs, Job{work, done, data}) }

@(private)
run_jobs :: proc() -> int {
	n := 0
	for len(jobs) > 0 {
		j := jobs[0]
		ordered_remove(&jobs, 0)
		j.work(j.data)
		j.done(j.data)
		n += 1
	}
	return n
}

@(private)
test_now :: proc() -> f64 { return clock }

Harness :: struct {
	m:       Manager,
	dir:     string,
	events:  map[u64][dynamic]Event,   // per client id
}

@(private)
harness_init :: proc(h: ^Harness, name: string, async := false, settings: Maybe(Settings) = nil, fresh := true) {
	h.dir = fmt.aprintf("%s/wren_idb_test/%s", os.get_env("TEMP", context.temp_allocator), name)
	if fresh {
		os.remove(fmt.tprintf("%s/idb/http_3A_2F_2Fa.test.widb", h.dir))
		os.remove(fmt.tprintf("%s/idb/http_3A_2F_2Fb.test.widb", h.dir))
	}
	s, ok := settings.?
	if !ok { s = settings_default() }
	clear(&jobs)
	manager_init(&h.m, s, h.dir, test_submit if async else nil, nil, test_now, context.allocator)
	h.events = make(map[u64][dynamic]Event)
}

@(private)
harness_destroy :: proc(h: ^Harness) {
	for _, &list in h.events { for &e in list { delete(e.data) }; delete(list) }
	delete(h.events)
	manager_destroy(&h.m)
	delete(jobs); jobs = nil
	delete(h.dir)
}

@(private)
new_client :: proc(h: ^Harness, origin := "http://a.test") -> ^Client {
	return client_create(&h.m, origin, proc(c: ^Client) {}, nil)
}

// Everything that arrived for the client since the last call, as "kind req/conn/tx" strings.
@(private)
drain :: proc(h: ^Harness, c: ^Client) -> [dynamic]Event {
	out := make([dynamic]Event, context.temp_allocator)
	for {
		ev, ok := client_pop(c)
		if !ok { break }
		// the data is copied to the temp allocator and the event released
		cp := ev
		cp.data = clone_bytes(ev.data, context.temp_allocator)
		append(&out, cp)
		event_free(c, &ev)
	}
	return out
}

@(private)
kinds :: proc(evs: [dynamic]Event) -> string {
	b := strings.builder_make(context.temp_allocator)
	for e, i in evs {
		if i > 0 { strings.write_byte(&b, ' ') }
		strings.write_string(&b, fmt.tprintf("%v", e.kind))
	}
	return strings.to_string(b)
}

@(private)
last_of :: proc(evs: [dynamic]Event, k: Event_Kind) -> Event {
	#reverse for e in evs { if e.kind == k { return e } }
	return {}
}

// Request builders
@(private)
rq :: proc(op: Request_Op) -> Writer {
	w := Writer{data = make([dynamic]byte, context.temp_allocator)}
	w_u8(&w, u8(op))
	return w
}

@(private)
w_all :: proc(w: ^Writer) { w_u8(w, 0) }   // an empty range

@(private)
call :: proc(c: ^Client, tx: u64, w: Writer) -> (reply: []byte, err: Error) {
	out := Writer{data = make([dynamic]byte, context.temp_allocator)}
	err = tx_exec(c, tx, w.data[:], &out)
	return out.data[:], err
}

@(private)
create_store :: proc(c: ^Client, tx: u64, name: string, auto := false) -> u32 {
	w := rq(.Create_Store)
	w_str(&w, name); w_bytes(&w, nil); w_u8(&w, 1 if auto else 0)
	rep, err := call(c, tx, w)
	if err != .None { return 0 }
	r := Reader{data = rep}
	return u32(r_uv(&r))
}

@(private)
put :: proc(c: ^Client, tx: u64, store: u32, key: []byte, value: string, no_overwrite := false) -> Error {
	w := rq(.Put)
	w_uv(&w, u64(store))
	flags: u8 = 0
	if no_overwrite { flags |= 1 }
	if key != nil { flags |= 2 }
	w_u8(&w, flags)
	if key != nil { w_bytes(&w, key) }
	w_str(&w, value)
	w_uv(&w, 0)
	_, err := call(c, tx, w)
	return err
}

@(private)
get :: proc(c: ^Client, tx: u64, store: u32, key: []byte) -> (value: string, found: bool, err: Error) {
	w := rq(.Get)
	w_uv(&w, u64(store)); w_uv(&w, 0)
	w_u8(&w, 3); w_bytes(&w, key); w_bytes(&w, key)   // [key, key]
	w_u8(&w, 0)
	rep, e := call(c, tx, w)
	if e != .None { return "", false, e }
	r := Reader{data = rep}
	if r_u8(&r) == 0 { return "", false, .None }
	r_bytes(&r)
	return string(r_bytes(&r)), true, .None
}

@(private, thread_local)
test_store: u32

// Opens `name` and runs the upgrade (if one is asked for) with `upgrade`, committing it. Returns the connection.
@(private)
open_and_upgrade :: proc(h: ^Harness, c: ^Client, name: string, version: u64, has_version: bool, upgrade: proc(c: ^Client, tx: u64)) -> (conn: u64, evs: [dynamic]Event) {
	open_database(c, name, version, has_version)
	run_jobs()
	evs = drain(h, c)
	up := last_of(evs, .Open_Upgrade)
	if up.kind == .Open_Upgrade {
		if upgrade != nil { upgrade(c, up.tx) }
		tx_commit(c, up.tx)
		run_jobs()
		for e in drain(h, c) { append(&evs, e) }
	}
	return last_of(evs, .Open_Done).conn, evs
}

@(private)
txn :: proc(c: ^Client, conn: u64, scope: []u32, mode: Tx_Mode) -> u64 {
	id, _ := begin_transaction(c, conn, scope, mode, false)
	return id
}

@(private)
make_store :: proc(c: ^Client, tx: u64) { test_store = create_store(c, tx, "msgs") }

@(test)
open_create_put_get_and_reload :: proc(t: ^testing.T) {
	h: Harness
	harness_init(&h, "reload")
	c := new_client(&h)
	conn, evs := open_and_upgrade(&h, c, "chat", 1, true, make_store)
	testing.expect_value(t, kinds(evs), "Open_Upgrade Tx_Complete Open_Done")
	store := test_store
	testing.expect(t, conn != 0 && store != 0, "connection and store")
	tx := txn(c, conn, {store}, .Read_Write)
	testing.expect_value(t, kinds(drain(&h, c)), "Tx_Started")
	testing.expect_value(t, put(c, tx, store, str_key("a"), "one"), Error.None)
	testing.expect_value(t, put(c, tx, store, str_key("b"), "two"), Error.None)
	testing.expect_value(t, put(c, tx, store, str_key("a"), "again", true), Error.Constraint)
	tx_commit(c, tx)
	testing.expect_value(t, kinds(drain(&h, c)), "Tx_Complete")
	tx2 := txn(c, conn, {store}, .Read_Only)
	drain(&h, c)
	v, found, err := get(c, tx2, store, str_key("b"))
	testing.expect(t, found && v == "two" && err == .None, "read back")
	_, found, _ = get(c, tx2, store, str_key("zzz"))
	testing.expect(t, !found, "absent")
	testing.expect_value(t, put(c, tx2, store, str_key("c"), "x"), Error.Read_Only)
	tx_commit(c, tx2)
	drain(&h, c)
	client_destroy(c)
	harness_destroy(&h)

	// a new process: the same file
	harness_init(&h, "reload", fresh = false)
	defer harness_destroy(&h)
	c = new_client(&h)
	defer client_destroy(c)
	conn2, evs2 := open_and_upgrade(&h, c, "chat", 0, false, nil)
	testing.expect_value(t, kinds(evs2), "Open_Done")
	meta := Reader{data = last_of(evs2, .Open_Done).data}
	testing.expect_value(t, r_uv(&meta), 1)           // version
	testing.expect_value(t, r_uv(&meta), 1)           // one store
	r3 := txn(c, conn2, {store}, .Read_Only)
	drain(&h, c)
	v, found, err = get(c, r3, store, str_key("a"))
	testing.expect(t, found && v == "one" && err == .None, "the data survived")
	tx_commit(c, r3)
	// version 1 asked again: no upgrade; a lower version fails
	drain(&h, c)
	open_database(c, "chat", 0, false)
	testing.expect_value(t, kinds(drain(&h, c)), "Open_Done")
	open_database(c, "chat", 1, true)
	testing.expect_value(t, kinds(drain(&h, c)), "Open_Done")
}

@(test)
version_errors_and_unknown_databases :: proc(t: ^testing.T) {
	h: Harness
	harness_init(&h, "versions")
	defer harness_destroy(&h)
	c := new_client(&h)
	defer client_destroy(c)
	conn, _ := open_and_upgrade(&h, c, "d", 3, true, nil)
	close_connection(c, conn)
	open_database(c, "d", 2, true)
	evs := drain(&h, c)
	testing.expect_value(t, kinds(evs), "Open_Error")
	testing.expect_value(t, evs[0].err, Error.Version)
	// unspecified version of a database that does not exist: version 1
	_, evs = open_and_upgrade(&h, c, "fresh", 0, false, nil)
	testing.expect_value(t, last_of(evs, .Open_Upgrade).v2, 1)
	// databases()
	list_databases(c)
	l := last_of(drain(&h, c), .List)
	r := Reader{data = l.data}
	testing.expect_value(t, r_uv(&r), 2)
	// delete: nothing to delete is a success with version 0
	delete_database(c, "nope")
	d := last_of(drain(&h, c), .Delete_Done)
	testing.expect(t, d.kind == .Delete_Done && d.v1 == 0, "deleting an absent database")
}

@(test)
versionchange_blocked_and_close :: proc(t: ^testing.T) {
	h: Harness
	harness_init(&h, "versionchange")
	defer harness_destroy(&h)
	a := new_client(&h)
	b := new_client(&h)
	defer client_destroy(a)
	defer client_destroy(b)
	conn_a, _ := open_and_upgrade(&h, a, "d", 1, true, nil)
	// B wants version 2: A hears versionchange, B waits
	open_database(b, "d", 2, true)
	run_jobs()
	testing.expect_value(t, kinds(drain(&h, b)), "")
	ea := drain(&h, a)
	testing.expect_value(t, kinds(ea), "Version_Change")
	testing.expect_value(t, ea[0].v1, 1)
	testing.expect_value(t, ea[0].v2, 2)
	// A's handlers ran and it did not close: B is blocked
	versionchange_done(a, conn_a)
	testing.expect_value(t, kinds(drain(&h, b)), "Blocked")
	// A closes: B upgrades
	close_connection(a, conn_a)
	eb := drain(&h, b)
	testing.expect_value(t, kinds(eb), "Open_Upgrade")
	tx_commit(b, eb[0].tx)
	run_jobs()
	testing.expect_value(t, kinds(drain(&h, b)), "Tx_Complete Open_Done")

	// C wants 3: B closes in its versionchange handler, so there is no blocked event
	c := new_client(&h)
	defer client_destroy(c)
	conn_b := last_of(eb, .Open_Upgrade).conn
	open_database(c, "d", 3, true)
	testing.expect_value(t, kinds(drain(&h, b)), "Version_Change")
	close_connection(b, conn_b)
	versionchange_done(b, conn_b)
	ec := drain(&h, c)
	testing.expect_value(t, kinds(ec), "Open_Upgrade")
}

@(test)
an_aborted_upgrade_leaves_nothing :: proc(t: ^testing.T) {
	h: Harness
	harness_init(&h, "abort_upgrade")
	defer harness_destroy(&h)
	c := new_client(&h)
	defer client_destroy(c)
	open_database(c, "d", 1, true)
	ev := last_of(drain(&h, c), .Open_Upgrade)
	create_store(c, ev.tx, "s")
	testing.expect_value(t, tx_abort(c, ev.tx, .Aborted), Error.None)
	testing.expect_value(t, kinds(drain(&h, c)), "Tx_Aborted Open_Error")
	list_databases(c)
	l := Reader{data = last_of(drain(&h, c), .List).data}
	testing.expect_value(t, r_uv(&l), 0)
	// the database can be opened again, from scratch
	_, evs := open_and_upgrade(&h, c, "d", 1, true, make_store)
	testing.expect_value(t, kinds(evs), "Open_Upgrade Tx_Complete Open_Done")
	testing.expect_value(t, test_store, 1)   // the abort gave the id back
}

@(test)
transactions_start_in_creation_order :: proc(t: ^testing.T) {
	h: Harness
	harness_init(&h, "schedule")
	defer harness_destroy(&h)
	c := new_client(&h)
	defer client_destroy(c)
	two_stores :: proc(c: ^Client, tx: u64) { test_store = create_store(c, tx, "a"); create_store(c, tx, "b") }
	conn, _ := open_and_upgrade(&h, c, "d", 1, true, two_stores)
	sa := test_store
	sb := sa + 1
	w1 := txn(c, conn, {sa}, .Read_Write)
	w2 := txn(c, conn, {sa}, .Read_Write)
	r1 := txn(c, conn, {sa}, .Read_Only)
	other := txn(c, conn, {sb}, .Read_Write)
	both := txn(c, conn, {sa, sb}, .Read_Only)
	started := make([dynamic]u64, context.temp_allocator)
	collect :: proc(started: ^[dynamic]u64, evs: [dynamic]Event) { for e in evs { if e.kind == .Tx_Started { append(started, e.tx) } } }
	collect(&started, drain(&h, c))
	// w1 and the transaction on the other store start; w2 waits for w1, r1 for w2, both for other and w2
	testing.expect_value(t, len(started), 2)
	testing.expect(t, started[0] == w1 && started[1] == other, "first wave")
	tx_commit(c, w1)
	run_jobs()
	started = make([dynamic]u64, context.temp_allocator)
	collect(&started, drain(&h, c))
	testing.expect(t, len(started) == 1 && started[0] == w2, "w2 after w1")
	tx_commit(c, w2)
	run_jobs()
	started = make([dynamic]u64, context.temp_allocator)
	collect(&started, drain(&h, c))
	testing.expect_value(t, len(started), 1)   // r1 starts; "both" waits for the write on b
	testing.expect(t, started[0] == r1, "r1 after w2")
	tx_commit(c, other)
	run_jobs()
	started = make([dynamic]u64, context.temp_allocator)
	collect(&started, drain(&h, c))
	testing.expect(t, len(started) == 1 && started[0] == both, "readers share")
	// read-only transactions never hold each other up
	tx_commit(c, r1)
	tx_commit(c, both)
	run_jobs()
	drain(&h, c)
	// requests of a transaction that did not start are refused
	late := txn(c, conn, {sa}, .Read_Write)
	late2 := txn(c, conn, {sa}, .Read_Write)
	drain(&h, c)
	testing.expect_value(t, put(c, late2, sa, str_key("x"), "y"), Error.Invalid_State)
	_ = late
}

@(test)
the_write_waits_for_the_disk :: proc(t: ^testing.T) {
	h: Harness
	harness_init(&h, "async", async = true)
	defer harness_destroy(&h)
	c := new_client(&h)
	defer client_destroy(c)
	run_jobs()   // the origin loads
	conn, _ := open_and_upgrade(&h, c, "d", 1, true, make_store)
	store := test_store
	w1 := txn(c, conn, {store}, .Read_Write)
	w2 := txn(c, conn, {store}, .Read_Write)
	drain(&h, c)
	put(c, w1, store, str_key("k"), "v1")
	tx_commit(c, w1)
	testing.expect_value(t, kinds(drain(&h, c)), "")        // not complete: the record is not written
	testing.expect_value(t, len(jobs), 1)
	run_jobs()
	testing.expect_value(t, kinds(drain(&h, c)), "Tx_Complete Tx_Started")   // w2 starts once w1 is on the disk
	v, found, _ := get(c, w2, store, str_key("k"))
	testing.expect(t, found && v == "v1", "w2 sees w1")
	put(c, w2, store, str_key("k"), "v2")
	tx_commit(c, w2)
	run_jobs()
	testing.expect_value(t, kinds(drain(&h, c)), "Tx_Complete")
}

@(test)
a_failed_write_rolls_the_transaction_back :: proc(t: ^testing.T) {
	h: Harness
	harness_init(&h, "iofail")
	defer harness_destroy(&h)
	c := new_client(&h)
	defer client_destroy(c)
	conn, _ := open_and_upgrade(&h, c, "d", 1, true, make_store)
	store := test_store
	w := txn(c, conn, {store}, .Read_Write)
	drain(&h, c)
	put(c, w, store, str_key("k"), "v")
	// make the file unwritable: the path becomes a directory
	path := origin_key_path(&h.m, "http://a.test")
	os.remove(path)
	os.make_directory(path)
	defer os.remove(path)
	tx_commit(c, w)
	evs := drain(&h, c)
	testing.expect_value(t, kinds(evs), "Tx_Aborted")
	testing.expect_value(t, evs[0].err, Error.Io)
	r := txn(c, conn, {store}, .Read_Only)
	drain(&h, c)
	_, found, _ := get(c, r, store, str_key("k"))
	testing.expect(t, !found, "rolled back in memory")
	tx_commit(c, r)
}

@(test)
a_closed_page_loses_its_open_transaction :: proc(t: ^testing.T) {
	h: Harness
	harness_init(&h, "gone")
	defer harness_destroy(&h)
	a := new_client(&h)
	b := new_client(&h)
	defer client_destroy(b)
	conn_a, _ := open_and_upgrade(&h, a, "d", 1, true, make_store)
	store := test_store
	w := txn(a, conn_a, {store}, .Read_Write)
	drain(&h, a)
	put(a, w, store, str_key("k"), "lost")
	// B waits to upgrade; A's page closes
	open_database(b, "d", 2, true)
	testing.expect_value(t, kinds(drain(&h, a)), "Version_Change")
	client_destroy(a)
	eb := drain(&h, b)
	testing.expect_value(t, kinds(eb), "Open_Upgrade")
	tx_commit(b, eb[0].tx)
	run_jobs()
	drain(&h, b)
	conn_b := last_of(eb, .Open_Upgrade).conn
	r := txn(b, conn_b, {store}, .Read_Only)
	drain(&h, b)
	_, found, _ := get(b, r, store, str_key("k"))
	testing.expect(t, !found, "the uncommitted write was rolled back")
	tx_commit(b, r)
}

@(test)
delete_database_closes_and_removes :: proc(t: ^testing.T) {
	h: Harness
	harness_init(&h, "delete")
	defer harness_destroy(&h)
	a := new_client(&h)
	b := new_client(&h)
	defer client_destroy(a)
	defer client_destroy(b)
	conn_a, _ := open_and_upgrade(&h, a, "d", 1, true, make_store)
	delete_database(b, "d")
	ea := drain(&h, a)
	testing.expect_value(t, kinds(ea), "Version_Change")
	testing.expect_value(t, ea[0].v2, 0)
	versionchange_done(a, conn_a)
	testing.expect_value(t, kinds(drain(&h, b)), "Blocked")
	close_connection(a, conn_a)
	run_jobs()
	d := last_of(drain(&h, b), .Delete_Done)
	testing.expect(t, d.kind == .Delete_Done && d.v1 == 1, "deleted version 1")
	list_databases(b)
	l := Reader{data = last_of(drain(&h, b), .List).data}
	testing.expect_value(t, r_uv(&l), 0)
}

@(test)
the_quota_is_enforced_per_origin :: proc(t: ^testing.T) {
	s := settings_default()
	s.quota_bytes = 2000
	h: Harness
	harness_init(&h, "quota", settings = s)
	defer harness_destroy(&h)
	c := new_client(&h)
	defer client_destroy(c)
	conn, _ := open_and_upgrade(&h, c, "d", 1, true, make_store)
	store := test_store
	tx := txn(c, conn, {store}, .Read_Write)
	drain(&h, c)
	big := strings.repeat("x", 700, context.temp_allocator)
	testing.expect_value(t, put(c, tx, store, str_key("a"), big), Error.None)
	testing.expect_value(t, put(c, tx, store, str_key("b"), big), Error.None)
	testing.expect_value(t, put(c, tx, store, str_key("c"), big), Error.Quota)
	tx_commit(c, tx)
	drain(&h, c)
	// another origin has its own quota
	d := new_client(&h, "http://b.test")
	defer client_destroy(d)
	conn_d, _ := open_and_upgrade(&h, d, "d", 1, true, make_store)
	tx_d := txn(d, conn_d, {test_store}, .Read_Write)
	drain(&h, d)
	testing.expect_value(t, put(d, tx_d, test_store, str_key("a"), big), Error.None)
	tx_commit(d, tx_d)
}

@(test)
the_journal_is_compacted_when_dead_records_pile_up :: proc(t: ^testing.T) {
	s := settings_default()
	s.compact_min_bytes = 4000
	s.compact_ratio = 1.5
	h: Harness
	harness_init(&h, "compact", settings = s)
	defer harness_destroy(&h)
	c := new_client(&h)
	defer client_destroy(c)
	conn, _ := open_and_upgrade(&h, c, "d", 1, true, make_store)
	store := test_store
	for i in 0 ..< 60 {
		tx := txn(c, conn, {store}, .Read_Write)
		drain(&h, c)
		put(c, tx, store, str_key("same"), strings.repeat(fmt.tprintf("%d", i % 10), 300, context.temp_allocator))
		tx_commit(c, tx)
		drain(&h, c)
	}
	testing.expect(t, h.m.stats.snapshots > 0, "compacted at least once")
	o := h.m.origins["http://a.test"]
	testing.expect(t, o.file_len < 20_000, "the file stays small")
	// and the data are intact after reading the file again
	client_destroy(c)
	harness_destroy(&h)
	harness_init(&h, "compact", settings = s, fresh = false)
	c = new_client(&h)
	conn2, _ := open_and_upgrade(&h, c, "d", 0, false, nil)
	tx := txn(c, conn2, {store}, .Read_Only)
	drain(&h, c)
	v, found, _ := get(c, tx, store, str_key("same"))
	testing.expect(t, found && len(v) == 300 && v[0] == '9', "last value kept")
	tx_commit(c, tx)
}

@(test)
idle_origins_are_unloaded :: proc(t: ^testing.T) {
	h: Harness
	harness_init(&h, "idle")
	defer harness_destroy(&h)
	c := new_client(&h)
	conn, _ := open_and_upgrade(&h, c, "d", 1, true, make_store)
	close_connection(c, conn)
	client_destroy(c)
	clock = 1000
	manager_tick(&h.m)                       // starts the idle clock
	testing.expect_value(t, len(h.m.origins), 1)
	clock = 1000 + h.m.settings.idle_unload_ms + 1
	manager_tick(&h.m)
	testing.expect_value(t, len(h.m.origins), 0)
	// used again, it loads again
	c = new_client(&h)
	defer client_destroy(c)
	_, evs := open_and_upgrade(&h, c, "d", 0, false, nil)
	testing.expect_value(t, kinds(evs), "Open_Done")
}

@(test)
clearing_site_data_closes_everything :: proc(t: ^testing.T) {
	h: Harness
	harness_init(&h, "clear")
	defer harness_destroy(&h)
	c := new_client(&h)
	defer client_destroy(c)
	conn, _ := open_and_upgrade(&h, c, "d", 1, true, make_store)
	store := test_store
	w := txn(c, conn, {store}, .Read_Write)
	drain(&h, c)
	put(c, w, store, str_key("k"), "v")
	manager_clear_origin(&h.m, "http://a.test")
	run_jobs()
	evs := drain(&h, c)
	testing.expect_value(t, kinds(evs), "Tx_Aborted Conn_Closed")
	list_databases(c)
	l := Reader{data = last_of(drain(&h, c), .List).data}
	testing.expect_value(t, r_uv(&l), 0)
	// nothing is left on the disk
	path := origin_key_path(&h.m, "http://a.test")
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err != nil || len(data) <= HEADER_SIZE, "the file is empty")
}