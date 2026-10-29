package jsrt

// Atoms: interned property keys.
//
// An Atom is a u32. Bit 31 set: an array index (0 .. 2^31-2) that never allocates a string. Otherwise
// it indexes `rt.atoms`: a string, a symbol or a private name. Indices below PREDEF_ATOM_COUNT are the
// predefined atoms, numbered exactly as quickjs-atom.h so serialized bytecode references them
// directly; the last ones are the well-known symbols themselves (Symbol.iterator is an atom).
//
// Interned strings and symbols used as keys are pinned for the runtime's lifetime (QuickJS refcounts
// atoms; pinning keeps property keys free of any bookkeeping on the hot paths).

Atom :: u32

ATOM_NULL :: Atom(0)
ATOM_TAG_INT :: u32(1) << 31
ATOM_MAX_INT :: ATOM_TAG_INT - 2

Atom_Kind :: enum u8 {
	string,
	global_symbol,
	symbol,
	private,
}

Atom_Entry :: struct {
	str:  ^JS_String, // string atoms
	sym:  ^Symbol,    // symbol / private atoms
	kind: Atom_Kind,
}

Symbol :: struct {
	using cell:  Cell,
	description: Value, // a string or undefined
	atom:        Atom,  // 0 until used as a key
	is_private:  bool,
	is_registered: bool, // created by Symbol.for
}

atom_is_int :: #force_inline proc "contextless" (a: Atom) -> bool {return a & ATOM_TAG_INT != 0}
atom_int :: #force_inline proc "contextless" (a: Atom) -> u32 {return a & ~ATOM_TAG_INT}
atom_from_u32 :: #force_inline proc "contextless" (v: u32) -> Atom {return v | ATOM_TAG_INT}
pa :: #force_inline proc "contextless" (p: Predef_Atom) -> Atom {return Atom(p)}

atom_kind :: #force_inline proc(rt: ^Runtime, a: Atom) -> Atom_Kind {
	if atom_is_int(a) {return .string}
	return rt.atoms[a].kind
}

atom_is_symbol :: #force_inline proc(rt: ^Runtime, a: Atom) -> bool {
	if atom_is_int(a) {return false}
	k := rt.atoms[a].kind
	return k == .symbol || k == .global_symbol || k == .private
}

atom_is_private :: #force_inline proc(rt: ^Runtime, a: Atom) -> bool {
	return !atom_is_int(a) && rt.atoms[a].kind == .private
}

atom_array_index :: #force_inline proc "contextless" (a: Atom) -> (u32, bool) {
	if a & ATOM_TAG_INT != 0 {return a & ~ATOM_TAG_INT, true}
	return 0, false
}

// Any array index (0 .. 2^32-2): an int atom, or a string atom spelling an index above ATOM_MAX_INT.
atom_index :: proc(rt: ^Runtime, a: Atom) -> (u32, bool) {
	if a & ATOM_TAG_INT != 0 {return a & ~ATOM_TAG_INT, true}
	if a == ATOM_NULL || int(a) >= len(rt.atoms) {return 0, false}
	e := &rt.atoms[a]
	if e.kind != .string || e.str == nil || e.str.len != 10 {return 0, false}
	return str_index_u32(rt, e.str, 0xfffffffe)
}

// --- table ---

atoms_init :: proc(rt: ^Runtime) {
	rt.atoms = make([dynamic]Atom_Entry, 0, 1024, rt.allocator)
	rt.atom_hash = make([]u32, 2048, rt.allocator)
	append(&rt.atoms, Atom_Entry{}) // ATOM_NULL
	// one-character strings and "" first, so seeding below reuses them
	for i in 0 ..< 256 {
		s := str_alloc(rt, 1, false)
		str_u8(s)[0] = u8(i)
		s.pinned = true
		rt.char_strings[i] = s
	}
	rt.empty_string = str_alloc(rt, 0, false)
	rt.empty_string.pinned = true
	wk_index := 0
	for i in 1 ..< PREDEF_ATOM_COUNT {
		text := predef_atom_text[i]
		if i == int(Predef_Atom.A_Private_brand) {
			sym := symbol_new_raw(rt, mk_str(str_from_utf8(rt, text)), true)
			sym.pinned = true
			sym.atom = Atom(i)
			append(&rt.atoms, Atom_Entry{sym = sym, kind = .private})
		} else if i >= int(Predef_Atom.A_Symbol_toPrimitive) {
			sym := symbol_new_raw(rt, mk_str(str_from_utf8(rt, text)), false)
			sym.pinned = true
			sym.atom = Atom(i)
			rt.well_known[Well_Known(wk_index)] = sym
			wk_index += 1
			append(&rt.atoms, Atom_Entry{sym = sym, kind = .symbol})
		} else {
			s: ^JS_String
			if text == "" {s = rt.empty_string} else if len(text) == 1 {s = rt.char_strings[text[0]]} else {s = str_from_utf8(rt, text)}
			s.pinned = true
			s.atom = Atom(i)
			append(&rt.atoms, Atom_Entry{str = s, kind = .string})
			atom_hash_insert(rt, Atom(i))
		}
	}
	clear(&rt.temp_roots)
}

atoms_free :: proc(rt: ^Runtime) {
	delete(rt.atoms)
	delete(rt.atom_hash, rt.allocator)
}

@(private = "file")
atom_hash_insert :: proc(rt: ^Runtime, a: Atom) {
	if (len(rt.atoms) * 2) > len(rt.atom_hash) {
		atom_rehash(rt, len(rt.atom_hash) * 2)
		return // rehash inserted every string atom, including a
	}
	s := rt.atoms[a].str
	mask := u32(len(rt.atom_hash) - 1)
	i := str_hash(rt, s) & mask
	for rt.atom_hash[i] != 0 {i = (i + 1) & mask}
	rt.atom_hash[i] = a
}

@(private = "file")
atom_rehash :: proc(rt: ^Runtime, size: int) {
	delete(rt.atom_hash, rt.allocator)
	rt.atom_hash = make([]u32, size, rt.allocator)
	mask := u32(size - 1)
	for &e, idx in rt.atoms {
		if e.kind != .string || e.str == nil {continue}
		i := str_hash(rt, e.str) & mask
		for rt.atom_hash[i] != 0 {i = (i + 1) & mask}
		rt.atom_hash[i] = u32(idx)
	}
}

// Parse a canonical array index ("0", "17", not "017", < 2^32-1).
str_array_index :: proc(rt: ^Runtime, s: ^JS_String) -> (u32, bool) {
	return str_index_u32(rt, s, u64(ATOM_MAX_INT))
}

str_index_u32 :: proc(rt: ^Runtime, s: ^JS_String, max_v: u64) -> (u32, bool) {
	n := int(s.len)
	if n == 0 || n > 10 {return 0, false}
	f := str_flat(rt, s)
	c0 := str_at(f, 0)
	if c0 < '0' || c0 > '9' {return 0, false}
	if c0 == '0' {return 0, n == 1}
	v: u64 = 0
	for i in 0 ..< n {
		c := str_at(f, i)
		if c < '0' || c > '9' {return 0, false}
		v = v * 10 + u64(c - '0')
	}
	if v > max_v {return 0, false}
	return u32(v), true
}

// Intern a string as an atom (the string itself becomes the pinned atom text).
atom_from_string :: proc(rt: ^Runtime, s: ^JS_String) -> Atom {
	if s.atom != 0 {return s.atom}
	if idx, ok := str_array_index(rt, s); ok {return atom_from_u32(idx)}
	f := str_flat(rt, s)
	h := str_hash(rt, f)
	mask := u32(len(rt.atom_hash) - 1)
	i := h & mask
	for {
		a := rt.atom_hash[i]
		if a == 0 {break}
		e := &rt.atoms[a]
		if e.str.hash == h && str_eq(rt, e.str, f) {
			if !f.pinned {f.atom = a} // cache on the probe string too
			return a
		}
		i = (i + 1) & mask
	}
	a := Atom(len(rt.atoms))
	f.pinned = true
	f.atom = a
	append(&rt.atoms, Atom_Entry{str = f, kind = .string})
	atom_hash_insert(rt, a)
	return a
}

// `s`, or the string of the atom with the same text when there is one: the name of a function that is also a
// property key is then one string, not two (thousands of native functions).
str_interned :: proc(rt: ^Runtime, s: ^JS_String) -> ^JS_String {
	if s.atom != 0 {return s}
	f := str_flat(rt, s)
	h := str_hash(rt, f)
	mask := u32(len(rt.atom_hash) - 1)
	i := h & mask
	for {
		a := rt.atom_hash[i]
		if a == 0 {return s}
		e := &rt.atoms[a]
		if e.str.hash == h && str_eq(rt, e.str, f) {return e.str}
		i = (i + 1) & mask
	}
}

atom_from_utf8 :: proc(rt: ^Runtime, text: string) -> Atom {
	return atom_from_string(rt, str_from_utf8(rt, text))
}

atom_from_symbol :: proc(rt: ^Runtime, sym: ^Symbol) -> Atom {
	if sym.atom != 0 {return sym.atom}
	a := Atom(len(rt.atoms))
	sym.atom = a
	kind: Atom_Kind = sym.is_private ? .private : (sym.is_registered ? .global_symbol : .symbol)
	append(&rt.atoms, Atom_Entry{sym = sym, kind = kind})
	return a
}

// The text of an atom: the string for string atoms, the decimal form of an index, the
// description of a symbol (empty if none).
atom_to_string :: proc(rt: ^Runtime, a: Atom) -> ^JS_String {
	if atom_is_int(a) {return str_from_u64(rt, u64(atom_int(a)))}
	e := &rt.atoms[a]
	if e.str != nil {return e.str}
	if e.sym != nil && is_string(e.sym.description) {return as_str(e.sym.description)}
	return rt.empty_string
}

// The property key as a script-visible value (a string or a symbol).
atom_to_value :: proc(rt: ^Runtime, a: Atom) -> Value {
	if atom_is_int(a) {return mk_str(str_from_u64(rt, u64(atom_int(a))))}
	e := &rt.atoms[a]
	if e.sym != nil {return mk_sym(e.sym)}
	if e.str == nil {return mk_str(rt.empty_string)} // ATOM_NULL (only malformed bytecode asks)
	return mk_str(e.str)
}

atom_symbol :: #force_inline proc(rt: ^Runtime, a: Atom) -> ^Symbol {
	if atom_is_int(a) {return nil}
	return rt.atoms[a].sym
}

// UTF-8 text for diagnostics (temp allocator).
atom_utf8 :: proc(rt: ^Runtime, a: Atom) -> string {
	return str_to_utf8(rt, atom_to_string(rt, a), tmp(rt))
}

str_from_u64 :: proc(rt: ^Runtime, v: u64) -> ^JS_String {
	if v < 10 {return rt.char_strings['0' + v]}
	buf: [24]u8
	n := 0
	x := v
	for x > 0 {
		buf[23 - n] = u8('0' + x % 10)
		x /= 10
		n += 1
	}
	return str_from_latin1(rt, buf[24 - n:])
}

symbol_new_raw :: proc(rt: ^Runtime, description: Value, private: bool) -> ^Symbol {
	sym := cell_new(rt, Symbol, .symbol)
	sym.description = description
	sym.is_private = private
	return sym
}

well_known_atom :: proc(w: Well_Known) -> Atom {
	return Atom(int(Predef_Atom.A_Symbol_toPrimitive) + int(w))
}

// CanonicalNumericIndexString for integer-indexed exotic objects: is the key a string that
// ToString(ToNumber(key)) reproduces (or "-0")? Returns the numeric value.
atom_canonical_numeric :: proc(ctx: ^Context, a: Atom) -> (f64, bool) {
	rt := ctx.rt
	if atom_is_int(a) {return f64(atom_int(a)), true}
	e := &rt.atoms[a]
	if e.str == nil {return 0, false}
	s := e.str
	if s.len == 0 {return 0, false}
	c0 := str_char_at(rt, s, 0)
	if !((c0 >= '0' && c0 <= '9') || c0 == '-' || c0 == 'I' || c0 == 'N') {return 0, false}
	if str_eq_ascii(rt, s, "-0") {return -0.0, true}
	d := string_to_number(rt, s)
	back := number_to_string(rt, d)
	if str_eq(rt, back, s) {return d, true}
	return 0, false
}
