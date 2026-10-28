package jsrt

// Atoms: interned property keys.
//
// An Atom is a 32-bit handle. Property lookups compare atoms by identity (a single integer compare)
// instead of by string content, which is what makes shape transitions and inline caches cheap. Two
// encodings share the 32-bit space, exactly as QuickJS does:
//   - Tagged integers: bit 31 set means the low 31 bits are an array index (0 .. 2^31-1). Array index
//     keys ("0", "1", ...) never allocate a string.
//   - Interned references: otherwise the value indexes `rt.atom_array`, a table of interned strings
//     and symbols. Indices 0 .. PREDEF_ATOM_COUNT-1 are the predefined atoms seeded at startup.
//
// The serialized bytecode references atoms by these same conventions (see atoms_table.odin and the
// reader), so the predefined set and their order must match quickjs-atom.h exactly.

Atom :: u32

ATOM_TAG_INT :: u32(1) << 31
ATOM_MAX_INT :: ATOM_TAG_INT - 1

atom_is_int :: #force_inline proc "contextless" (a: Atom) -> bool {
	return (a & ATOM_TAG_INT) != 0
}

atom_to_int :: #force_inline proc "contextless" (a: Atom) -> u32 {
	return a & ~ATOM_TAG_INT
}

atom_from_int :: #force_inline proc "contextless" (v: u32) -> Atom {
	return v | ATOM_TAG_INT
}

atom_is_const :: #force_inline proc "contextless" (a: Atom) -> bool {
	return !atom_is_int(a) && a < PREDEF_ATOM_COUNT
}

// An entry in the interned-atom table. For a string atom `str` holds the owned string and `sym` is
// nil; for a symbol atom `sym` holds the symbol. `hash_next` chains the open hash table.
Atom_Entry :: struct {
	str:       ^JS_String,
	sym:       ^Symbol,
	atom_type: Atom_Type,
	hash:      u32,
	hash_next: u32, // index of next entry in the same bucket, 0 = end
}

// Mirrors JS_ATOM_TYPE_* so serialized atoms round-trip.
Atom_Type :: enum u8 {
	string        = 1,
	global_symbol = 2,
	symbol        = 3,
	private       = 4,
}

// --- interning ---

// Intern a UTF-8 string, returning an owned atom reference. A predefined atom is returned directly.
atom_intern_utf8 :: proc(rt: ^Runtime, text: string) -> Atom {
	// Array-index fast path.
	if idx, ok := parse_array_index(text); ok {
		return atom_from_int(idx)
	}
	s := string_from_utf8(rt, text)
	if s == nil {return Atom(Predef_Atom.null_atom)}
	a := atom_intern_string(rt, s, .string)
	string_unref(rt, s)
	return a
}

// Intern an existing string cell (does not consume the reference). Reuses an equal interned entry.
atom_intern_string :: proc(rt: ^Runtime, s: ^JS_String, atom_type: Atom_Type) -> Atom {
	h := string_hash(rt, s)
	bucket := h & (u32(len(rt.atom_hash)) - 1)
	idx := rt.atom_hash[bucket]
	for idx != 0 {
		e := &rt.atom_array[idx]
		if e.atom_type == atom_type && e.str != nil && e.hash == h && string_equal(rt, e.str, s) {
			return Atom(idx)
		}
		idx = e.hash_next
	}
	// Not found: add a new entry.
	new_idx := atom_table_push(rt)
	e := &rt.atom_array[new_idx]
	e.str = string_ref(s)
	e.sym = nil
	e.atom_type = atom_type
	e.hash = h
	e.hash_next = rt.atom_hash[bucket]
	rt.atom_hash[bucket] = u32(new_idx)
	return Atom(new_idx)
}

// Resolve an atom to its backing string (for property enumeration, diagnostics, ToString of a key).
// Integer atoms synthesise a decimal string. Returns an owned reference.
atom_to_string :: proc(rt: ^Runtime, a: Atom) -> ^JS_String {
	if atom_is_int(a) {
		return string_from_u32(rt, atom_to_int(a))
	}
	e := &rt.atom_array[a]
	if e.str != nil {
		return string_ref(e.str)
	}
	if e.sym != nil && e.sym.description != nil {
		return string_ref(e.sym.description)
	}
	return string_empty(rt)
}

// Add an uninitialised slot to the atom array (growing it) and return its index.
@(private = "file")
atom_table_push :: proc(rt: ^Runtime) -> int {
	if rt.atom_count >= len(rt.atom_array) {
		old := rt.atom_array
		new_cap := len(old) == 0 ? 256 : len(old) * 2
		grown := make([]Atom_Entry, new_cap, rt.allocator)
		copy(grown, old)
		if len(old) != 0 {delete(old, rt.allocator)}
		rt.atom_array = grown
		// Growing the array does not rehash: hash_next indices stay valid.
	}
	idx := rt.atom_count
	rt.atom_count += 1
	return idx
}

// Parse "0".."2147483647" as an array index; rejects leading zeros (except "0") and overflow.
parse_array_index :: proc(text: string) -> (u32, bool) {
	if len(text) == 0 || len(text) > 10 {return 0, false}
	if text[0] == '0' {
		if len(text) == 1 {return 0, true}
		return 0, false
	}
	v: u64 = 0
	for c in text {
		if c < '0' || c > '9' {return 0, false}
		v = v * 10 + u64(c - '0')
		if v > u64(ATOM_MAX_INT) {return 0, false}
	}
	return u32(v), true
}

// --- predefined atom seeding ---

// Fill atom_array[1 .. PREDEF_ATOM_COUNT) with the predefined atoms and hash the string ones. Index 0
// is the NULL atom placeholder. Called once at runtime creation.
atom_seed_predefined :: proc(rt: ^Runtime) {
	rt.atom_array = make([]Atom_Entry, max(512, PREDEF_ATOM_COUNT + 64), rt.allocator)
	rt.atom_hash = make([]u32, 1024, rt.allocator)
	rt.atom_count = PREDEF_ATOM_COUNT

	for i in 1 ..< PREDEF_ATOM_COUNT {
		text := predef_atom_text[i]
		s := string_from_utf8(rt, text)
		e := &rt.atom_array[i]
		e.str = s
		e.atom_type = .string
		if s != nil {
			e.hash = string_hash(rt, s)
			bucket := e.hash & (u32(len(rt.atom_hash)) - 1)
			e.hash_next = rt.atom_hash[bucket]
			rt.atom_hash[bucket] = u32(i)
		}
	}
}

// Shorthand to use a predefined atom as an Atom value.
pa :: #force_inline proc "contextless" (p: Predef_Atom) -> Atom {
	return Atom(p)
}
