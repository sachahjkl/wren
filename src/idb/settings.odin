package idb

import "wb:config"

// IndexedDB knobs (about:config, `indexeddb.*`). The data model (databases, object stores, indexes, key order) is the
// specification's and is not configurable; limits, durability and the life of the in-memory copy are.

Durability :: enum u8 {
	Relaxed,   // a transaction is complete once its journal record is written to the file (the operating system flushes later)
	Strict,    // ... once the file is flushed to the disk (FlushFileBuffers)
}

Settings :: struct {
	enabled:           bool,
	quota_bytes:       i64,    // per origin: keys, values and index keys
	max_value_bytes:   int,    // one serialized value
	max_key_bytes:     int,    // one encoded key
	max_databases:     int,    // per origin
	max_objects:       int,    // object stores and indexes per database
	durability:        Durability,
	compact_min_bytes: i64,    // a journal smaller than this is never rewritten
	compact_ratio:     f64,    // the journal is rewritten when it is this many times the live data (plus compact_min_bytes)
	idle_unload_ms:    f64,    // an origin nobody uses is dropped from memory after this long (its file stays)
	write_batch_bytes: int,    // queued commits written together up to about this many bytes
	value_cache_bytes: i64,    // values of records kept in memory after they are on the disk (the most recently used)
	checkpoint_tail_bytes: i64,   // a checkpoint is written when the journal has grown this much past the last one
	sync_write_bytes:  int,    // a batch of commits up to this size is written on the thread that commits (a write to the system's cache is faster than a hand-over); a larger one on the pool
	sync_interval_ms:  f64,    // relaxed durability: what the system holds is flushed to the disk this often (0: never, but at exit)
	resident_bytes:    i64,    // the stores that are in memory are dropped (the idle ones first) when their keys take more than this
}

PREFS := [?]config.Def{
	{name = "indexeddb.enabled", kind = .Bool, default = {b = true},
		description = "Provide IndexedDB (indexedDB, IDBDatabase...). Off: the interface is absent from pages."},
	{name = "indexeddb.quota", kind = .Int, default = {i = 256 << 20}, bounded = true, min = 0, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Most data one origin may keep in IndexedDB (keys, values, index keys). A transaction that would go past it fails with QuotaExceededError. The whole database of an origin in use is kept in memory."},
	{name = "indexeddb.max_value_bytes", kind = .Int, default = {i = 128 << 20}, bounded = true, min = 1024, max = 1 << 31, bytes = true, unit = "bytes",
		description = "Largest serialized value one record may have."},
	{name = "indexeddb.max_key_bytes", kind = .Int, default = {i = 1 << 20}, bounded = true, min = 64, max = 1 << 26, bytes = true, unit = "bytes",
		description = "Largest encoded key (primary or index)."},
	{name = "indexeddb.max_databases", kind = .Int, default = {i = 256}, bounded = true, min = 1, max = 100_000,
		description = "Most databases one origin may have."},
	{name = "indexeddb.max_objects", kind = .Int, default = {i = 4096}, bounded = true, min = 1, max = 1_000_000,
		description = "Most object stores, and most indexes, one database may have."},
	{name = "indexeddb.durability", kind = .String, default = {s = "relaxed"}, choices = {"relaxed", "strict"},
		description = "relaxed: a transaction completes once its changes are written to the file. strict: once they are flushed to the disk (slower, survives a power cut)."},
	{name = "indexeddb.compact_min_bytes", kind = .Int, default = {i = 1 << 20}, bounded = true, min = 0, max = 1 << 40, bytes = true, unit = "bytes",
		description = "A journal smaller than this is never rewritten."},
	{name = "indexeddb.compact_ratio", kind = .Float, default = {f = 2.0}, bounded = true, min = 1.0, max = 1000.0,
		description = "The journal of an origin is rewritten (dead records dropped) when it is this many times the size of its live data, plus indexeddb.compact_min_bytes."},
	{name = "indexeddb.idle_unload_ms", kind = .Float, default = {f = 30_000}, bounded = true, min = 0, max = 86_400_000, unit = "ms",
		description = "An origin with no open database is dropped from memory after this long (its file stays and is read again at the next use)."},
	{name = "indexeddb.value_cache_bytes", kind = .Int, default = {i = 64 << 20}, bounded = true, min = 0, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Values of IndexedDB records kept in memory once they are on the disk (the most recently used; the others are read from the journal when asked for). Per origin in use."},
	{name = "indexeddb.checkpoint_tail_bytes", kind = .Int, default = {i = 8 << 20}, bounded = true, min = 0, max = 1 << 40, bytes = true, unit = "bytes",
		description = "A checkpoint (the keys of every store, so that opening does not read the journal) is written when the journal has grown this much past the last one."},
	{name = "indexeddb.sync_write_bytes", kind = .Int, default = {i = 256 << 10}, bounded = true, min = 0, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Commits waiting to be written, up to this size together, are written by the thread that commits (a write to the system's cache costs less than handing it to another thread); larger ones, and strict ones, on a background thread. 0: always in the background."},
	{name = "indexeddb.sync_interval_ms", kind = .Float, default = {f = 1000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "With relaxed durability a transaction completes once the system has its bytes; they are flushed to the disk at this interval (0: only at exit). strict flushes before completing."},
	{name = "indexeddb.resident_bytes", kind = .Int, default = {i = 1 << 30}, bounded = true, min = 0, max = 1 << 42, bytes = true, unit = "bytes",
		description = "Memory the keys of the IndexedDB stores in use may take; past it the stores nobody uses are dropped from memory (read again from the checkpoint when needed)."},
	{name = "indexeddb.write_batch_bytes", kind = .Int, default = {i = 4 << 20}, bounded = true, min = 4096, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Commits waiting for the disk are written together up to about this many bytes per write."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	return Settings{
		enabled = config.bool_of(p, "indexeddb.enabled"),
		quota_bytes = config.int_of(p, "indexeddb.quota"),
		max_value_bytes = int(config.int_of(p, "indexeddb.max_value_bytes")),
		max_key_bytes = int(config.int_of(p, "indexeddb.max_key_bytes")),
		max_databases = int(config.int_of(p, "indexeddb.max_databases")),
		max_objects = int(config.int_of(p, "indexeddb.max_objects")),
		durability = config.string_of(p, "indexeddb.durability") == "strict" ? .Strict : .Relaxed,
		compact_min_bytes = config.int_of(p, "indexeddb.compact_min_bytes"),
		compact_ratio = config.float_of(p, "indexeddb.compact_ratio"),
		idle_unload_ms = config.float_of(p, "indexeddb.idle_unload_ms"),
		write_batch_bytes = int(config.int_of(p, "indexeddb.write_batch_bytes")),
		value_cache_bytes = config.int_of(p, "indexeddb.value_cache_bytes"),
		checkpoint_tail_bytes = config.int_of(p, "indexeddb.checkpoint_tail_bytes"),
		sync_write_bytes = int(config.int_of(p, "indexeddb.sync_write_bytes")),
		sync_interval_ms = config.float_of(p, "indexeddb.sync_interval_ms"),
		resident_bytes = config.int_of(p, "indexeddb.resident_bytes"),
	}
}

settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}
