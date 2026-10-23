package adblock

// The binary index: one blob, written by `build`, read by `load` without any conversion. Every section is an array of
// fixed-size records at an 8-byte aligned offset; hash tables are open-addressed with linear probing.

MAGIC   :: [8]u8{'W', 'R', 'E', 'N', 'A', 'B', 'L', 'X'}
VERSION :: u32(3)

LAST_BIT :: u32(1) << 31          // marks the last item of a list in an `items` array
NO_LIST  :: u32(0xFFFFFFFF)

Slot :: struct { key, val: u32 }   // key 0 = empty

Sec :: struct { off, count: u32 }  // byte offset from the start of the blob, number of records

// The sections, in order. The per-class ones follow SEC_CLASS_BASE: host, token, source-domain tables and the items.
SEC_STRINGS    :: 0
SEC_FILTERS    :: 1
SEC_DOMAINS    :: 2
SEC_COS        :: 3
SEC_COS_KEY    :: 4
SEC_COS_HOST   :: 5
SEC_COS_ITEMS  :: 6
SEC_SOURCES    :: 7
SEC_SOURCE_NAMES :: 8
SEC_CLASS_BASE :: 9
SEC_COUNT      :: SEC_CLASS_BASE + CLASS_COUNT * 4

Header :: struct #packed {
	magic:       [8]u8,
	version:     u32,
	n_filters:   u32,
	n_cos:       u32,
	cos_generic: u32,          // start in the cosmetic items of the unkeyed generic filters (always applied)
	cos_generic_exc: u32,      // ... of the generic exceptions
	checksum:    u64,          // of everything after the header
	total:       u64,
	notoken:     [CLASS_COUNT]u32,
	secs:        [SEC_COUNT]Sec,
}

// A cosmetic filter record (28 bytes).
Cos_Filter :: struct {
	sel_off:  u32,
	sel_len:  u32,
	flags:    Cos_Flags,
	list:     u8,
	_:        u8,
	src_off:  u32,
	sel_hash: u32,
	key:      u32,
	text_off: u32,
}

// One list the index was built from.
Source_Entry :: struct {
	name_off, name_len: u32,
	id:                 u8,
	_:                  [3]u8,
	net:                u32,    // network filters accepted
	cosmetic:           u32,
	invalid:            u32,    // lines that were not valid or not supported
	_pad:               u32,
}

@(private)
slot_index :: #force_inline proc "contextless" (key, mask: u32) -> u32 {
	return (key ~ (key >> 15)) & mask
}

// The start of the list stored under `key`.
multi_find :: #force_inline proc "contextless" (tab: []Slot, key: u32) -> (start: u32, ok: bool) {
	if len(tab) == 0 { return 0, false }
	mask := u32(len(tab) - 1)
	i := slot_index(key, mask)
	for {
		s := tab[i]
		if s.key == key { return s.val, true }
		if s.key == 0 { return 0, false }
		i = (i + 1) & mask
	}
}

checksum_bytes :: proc "contextless" (b: []byte) -> u64 {
	h := u64(0xcbf29ce484222325)
	n := len(b) / 8
	words := ([^]u64)(raw_data(b))[:n]
	for w in words { h = (h ~ w) * 0x100000001b3; h ~= h >> 29 }
	for i in n * 8 ..< len(b) { h = (h ~ u64(b[i])) * 0x100000001b3 }
	return h
}
