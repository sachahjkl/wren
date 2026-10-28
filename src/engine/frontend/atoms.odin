package frontend

import "base:runtime"

// Atoms: interned strings and small integers, the currency of property names and variable names in the bytecode.
// QuickJS represents an atom as a 32-bit value. There are three kinds, distinguished by value range:
//
//   * tagged integer : the high bit (JS_ATOM_TAG_INT, 1<<31) is set; the low 31 bits are the integer. Used for
//     array-index property names ("0".."2147483646"). Never interned in a table.
//   * predefined     : 1 .. JS_ATOM_END-1, a fixed table compiled into QuickJS (quickjs-atom.h). Atom 0 is NULL.
//   * runtime string : JS_ATOM_END and above, allocated as the engine runs.
//
// The front-end needs atoms for two reasons: to put them in instruction operands and vardef/closure tables, and
// to serialize them. For byte-for-byte equality with QuickJS the *values* we assign must match: a predefined
// name must get its predefined value, an array-index name must get the tagged-integer encoding, and everything
// else must get a fresh runtime value assigned in first-seen order, because that is the order JS_WriteObjectAtoms
// records them. We reproduce all three.
//
// An Atom_Table owns the interning state for one compilation. It is allocated on the caller's allocator (an arena
// for a whole compile), so the whole package stays allocator-injected and freestanding-friendly.

Atom :: distinct u32

JS_ATOM_NULL :: Atom(0)
JS_ATOM_TAG_INT :: u32(1) << 31
JS_ATOM_MAX_INT :: JS_ATOM_TAG_INT - 1

// JS_ATOM_END is the first runtime atom value: one past the last predefined atom. It equals 1 + len(predefined
// names), because the enum in quickjs.c is { __JS_ATOM_NULL = 0, JS_ATOM_null = 1, ..., JS_ATOM_END }.
JS_ATOM_END :: Atom(1 + len(PREDEFINED_ATOMS))

atom_is_tagged_int :: #force_inline proc(a: Atom) -> bool {
	return (u32(a) & JS_ATOM_TAG_INT) != 0
}

atom_to_uint32 :: #force_inline proc(a: Atom) -> u32 {
	return u32(a) & JS_ATOM_MAX_INT
}

atom_from_uint32 :: #force_inline proc(n: u32) -> Atom {
	return Atom(n | JS_ATOM_TAG_INT)
}

atom_is_const :: #force_inline proc(a: Atom) -> bool {
	return i32(a) < i32(JS_ATOM_END)
}

// One interned runtime string: its bytes and the UTF-16 width flag the serializer needs. QuickJS stores strings
// as either Latin-1 (one byte per unit) or UTF-16 (two bytes per unit). We keep the canonical UTF-16 code units
// so JS_WriteString can reproduce the exact (len<<1 | is_wide) header and payload; a Latin-1 fast path is kept
// for the common all-ASCII name.
Interned_String :: struct {
	units:   []u16, // the UTF-16 code units (nil when all code units fit in a byte and `latin1` is used instead)
	latin1:  []u8,  // the bytes when every unit is < 256 (is_wide_char = 0); otherwise nil
	is_wide: bool,
}

Atom_Table :: struct {
	allocator: runtime.Allocator,
	// Runtime (non-predefined) atoms, in first-seen order. The value of the i-th entry is JS_ATOM_END + i.
	runtime:   [dynamic]Interned_String,
	// Hash map from a string key to its assigned atom, for both predefined and runtime strings. The key is the
	// string's bytes interpreted as the source identifier/literal; predefined atoms are pre-populated.
	index:     map[string]Atom,
	// Backing storage for the keys of `index` that we own (runtime strings copied into the arena). Predefined
	// keys point at the static PREDEFINED_ATOMS table and are not owned.
}

atom_table_init :: proc(t: ^Atom_Table, allocator: runtime.Allocator) {
	t.allocator = allocator
	t.runtime = make([dynamic]Interned_String, allocator)
	t.index = make(map[string]Atom, 256, allocator)
	for name, i in PREDEFINED_ATOMS {
		// Predefined atom i (0-based) has value i+1. Later duplicates in the table (e.g. "<brand>" appears as
		// both `brand` and `Private_brand`) keep the first index, matching __JS_FindAtom which returns the
		// lowest matching predefined atom.
		if name not_in t.index {
			t.index[name] = Atom(i + 1)
		}
	}
}

// intern returns the atom for an identifier or string-literal name. If the name is the decimal form of an
// array index (0 .. 2^31-2 with no leading zeros, and not "0" with a leading sign etc.), it returns the
// tagged-integer atom; QuickJS's JS_NewAtomLen does the same via JS_ATOM_TYPE detection. Otherwise it returns a
// predefined atom when the name matches one, or allocates a fresh runtime atom (first-seen order).
intern :: proc(t: ^Atom_Table, name: string) -> Atom {
	if idx, ok := string_to_array_index(name); ok {
		return atom_from_uint32(idx)
	}
	if a, ok := t.index[name]; ok {
		return a
	}
	// Fresh runtime atom. Copy the bytes into the arena so the key outlives the source buffer, and record the
	// UTF-16 form for serialization.
	key := clone_string(name, t.allocator)
	a := Atom(u32(JS_ATOM_END) + u32(len(t.runtime)))
	append(&t.runtime, encode_interned(name, t.allocator))
	t.index[key] = a
	return a
}

// intern_utf16 is intern for a name already decoded to UTF-16 units (template cooked values, string literals with
// surrogate pairs). It builds the Interned_String directly and looks the name up by a byte view of the units so
// two identical wide strings share one atom.
intern_utf16 :: proc(t: ^Atom_Table, units: []u16) -> Atom {
	// Array-index detection only matters for all-ASCII digit strings; a wide string is never an index.
	key_bytes := transmute([]u8)units
	key := string(key_bytes)
	if a, ok := t.index[key]; ok {
		return a
	}
	owned_units := make([]u16, len(units), t.allocator)
	copy(owned_units, units)
	is_wide := false
	for u in units {
		if u >= 256 {
			is_wide = true
			break
		}
	}
	entry: Interned_String
	if is_wide {
		entry = {units = owned_units, is_wide = true}
	} else {
		b := make([]u8, len(units), t.allocator)
		for u, i in units {
			b[i] = u8(u)
		}
		entry = {latin1 = b, is_wide = false}
	}
	a := Atom(u32(JS_ATOM_END) + u32(len(t.runtime)))
	append(&t.runtime, entry)
	// The key must be stable: keep the owned_units bytes as the map key.
	t.index[string(transmute([]u8)owned_units)] = a
	return a
}

// encode_interned builds the serializer-ready form of a UTF-8 identifier/literal. QuickJS decides is_wide_char by
// whether any code point exceeds 0xFF; an identifier is almost always Latin-1, so the common path copies bytes.
@(private = "file")
encode_interned :: proc(name: string, allocator: runtime.Allocator) -> Interned_String {
	wide := false
	for i := 0; i < len(name); {
		r, w := decode_rune_utf8(name[i:])
		if r > 0xFF {
			wide = true
		}
		i += w
	}
	if !wide {
		// Latin-1: one byte per code point. For pure ASCII this is the bytes verbatim; for U+0080..U+00FF we
		// must collapse the two UTF-8 bytes into one Latin-1 byte.
		b := make([dynamic]u8, 0, len(name), allocator)
		for i := 0; i < len(name); {
			r, w := decode_rune_utf8(name[i:])
			append(&b, u8(r))
			i += w
		}
		return {latin1 = b[:], is_wide = false}
	}
	// Wide: UTF-16 code units, with surrogate pairs for astral code points.
	units := make([dynamic]u16, 0, len(name), allocator)
	for i := 0; i < len(name); {
		r, w := decode_rune_utf8(name[i:])
		if r > 0xFFFF {
			c := u32(r) - 0x10000
			append(&units, u16(0xD800 + (c >> 10)))
			append(&units, u16(0xDC00 + (c & 0x3FF)))
		} else {
			append(&units, u16(r))
		}
		i += w
	}
	return {units = units[:], is_wide = true}
}

// string_to_array_index implements QuickJS's array-index test (JS_AtomIsArrayIndex path): the canonical decimal
// form of an integer in 0 .. 2^31-2, with no leading zeros (except "0" itself) and no sign. "4294967295"
// (2^32-1) is the array length limit but is NOT a valid *atom* integer because atoms top out at 2^31-1.
@(private = "file")
string_to_array_index :: proc(s: string) -> (idx: u32, ok: bool) {
	if len(s) == 0 || len(s) > 10 {
		return 0, false
	}
	if s[0] == '0' {
		if s == "0" {
			return 0, true
		}
		return 0, false
	}
	n: u64 = 0
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + u64(c - '0')
	}
	if n > u64(JS_ATOM_MAX_INT) {
		return 0, false
	}
	return u32(n), true
}

@(private = "file")
clone_string :: proc(s: string, allocator: runtime.Allocator) -> string {
	b := make([]u8, len(s), allocator)
	copy(b, s)
	return string(b)
}

@(private = "file")
decode_rune_utf8 :: proc(b: string) -> (r: rune, size: int) {
	bs := transmute([]u8)b
	if len(bs) == 0 {
		return 0xFFFD, 0
	}
	c := bs[0]
	if c < 0x80 {
		return rune(c), 1
	} else if c < 0xC0 {
		return 0xFFFD, 1
	} else if c < 0xE0 {
		if len(bs) < 2 {return 0xFFFD, 1}
		return rune(u32(c & 0x1F) << 6 | u32(bs[1] & 0x3F)), 2
	} else if c < 0xF0 {
		if len(bs) < 3 {return 0xFFFD, 1}
		return rune(u32(c & 0x0F) << 12 | u32(bs[1] & 0x3F) << 6 | u32(bs[2] & 0x3F)), 3
	} else if c < 0xF8 {
		if len(bs) < 4 {return 0xFFFD, 1}
		return rune(u32(c & 0x07) << 18 | u32(bs[1] & 0x3F) << 12 | u32(bs[2] & 0x3F) << 6 | u32(bs[3] & 0x3F)), 4
	}
	return 0xFFFD, 1
}

// The predefined atom table, in the exact order of quickjs-atom.h for BC_VERSION 28. The index of a name in this
// slice plus one is its atom value (PREDEFINED_ATOMS[0] == "null" has atom value 1). Keeping it as data (not a
// generated enum) lets the atom table and the keyword recognizer share one source of truth.
PREDEFINED_ATOMS := [?]string {
	"null", "false", "true", "if", "else", "return", "var", "this", "delete", "void", "typeof", "new", "in",
	"instanceof", "do", "while", "for", "break", "continue", "switch", "case", "default", "throw", "try",
	"catch", "finally", "function", "debugger", "with",
	"class", "const", "enum", "export", "extends", "import", "super", "using",
	"implements", "interface", "let", "package", "private", "protected", "public", "static", "yield", "await",
	"", // empty_string
	"keys", "size", "length", "message", "cause", "errors", "error", "suppressed", "stack", "name", "toString",
	"toLocaleString", "valueOf", "eval", "prototype", "constructor", "configurable", "writable", "enumerable",
	"value", "get", "set", "of", "__proto__", "undefined", "number", "boolean", "string", "object", "symbol",
	"integer", "unknown", "arguments", "callee", "caller", "<eval>", "<ret>", "<var>", "<arg_var>", "<with>",
	"<using_dispose>", "use", "dispose", "disposeAsync", "lastIndex", "target", "index", "input",
	"defineProperties", "apply", "join", "concat", "split", "construct", "getPrototypeOf", "setPrototypeOf",
	"isExtensible", "preventExtensions", "has", "deleteProperty", "defineProperty", "getOwnPropertyDescriptor",
	"ownKeys", "add", "done", "next", "values", "source", "flags", "global", "unicode", "raw", "rawJSON",
	"new.target", "this.active_func", "<home_object>", "<computed_field>", "<static_computed_field>",
	"<class_fields_init>", "<brand>", "#constructor", "as", "from", "fromAsync", "meta", "*default*", "*",
	"Module", "then", "resolve", "reject", "promise", "proxy", "revoke", "async", "exec", "groups", "indices",
	"status", "reason", "globalThis", "bigint", "not-equal", "timed-out", "ok", "toJSON", "maxByteLength", "zip",
	"zipKeyed",
	"Object", "Array", "Error", "Number", "String", "Boolean", "Symbol", "Arguments", "Math", "JSON", "Date",
	"Function", "GeneratorFunction", "ForInIterator", "RegExp", "ArrayBuffer", "SharedArrayBuffer",
	"Uint8ClampedArray", "Int8Array", "Uint8Array", "Int16Array", "Uint16Array", "Int32Array", "Uint32Array",
	"BigInt64Array", "BigUint64Array", "Float16Array", "Float32Array", "Float64Array", "DataView", "BigInt",
	"WeakRef", "FinalizationRegistry", "Map", "Set", "WeakMap", "WeakSet", "Iterator", "Iterator Concat",
	"Iterator Helper", "Iterator Wrap", "Map Iterator", "Set Iterator", "Array Iterator", "String Iterator",
	"RegExp String Iterator", "Generator", "Proxy", "Promise", "PromiseResolveFunction", "PromiseRejectFunction",
	"AsyncFunction", "AsyncFunctionResolve", "AsyncFunctionReject", "AsyncGeneratorFunction", "AsyncGenerator",
	"EvalError", "RangeError", "ReferenceError", "SyntaxError", "TypeError", "URIError", "InternalError",
	"DOMException", "CallSite", "DisposableStack", "AsyncDisposableStack", "SuppressedError",
	"<brand>", // Private_brand
	"Symbol.toPrimitive", "Symbol.iterator", "Symbol.match", "Symbol.matchAll", "Symbol.replace", "Symbol.search",
	"Symbol.split", "Symbol.toStringTag", "Symbol.isConcatSpreadable", "Symbol.hasInstance", "Symbol.species",
	"Symbol.unscopables", "Symbol.asyncIterator", "Symbol.dispose", "Symbol.asyncDispose",
}

// predef_atom returns the predefined atom value for a name known to be in PREDEFINED_ATOMS. It is a comptime-safe
// linear scan over the static table, so the compiler can refer to a well-known atom by its spelling without
// hand-counting an index (hand-counted indices drift the moment the table changes). Panics in debug if the name
// is absent, which can only happen from a typo in compiler source.
predef_atom :: proc(name: string) -> Atom {
	for n, i in PREDEFINED_ATOMS {
		if n == name {
			return Atom(i + 1)
		}
	}
	return JS_ATOM_NULL
}
