package frontend

import "base:runtime"

// Atoms: interned strings and small integers, the currency of property names and variable names in the bytecode.
// QuickJS represents an atom as a 32-bit value. There are three kinds, distinguished by value range:
//
//   * tagged integer : the high bit (JS_ATOM_TAG_INT, 1<<31) is set; the low 31 bits are the integer. Used for
//     array-index property names ("0".."2147483647"). Never interned in a table.
//   * predefined     : 1 .. JS_ATOM_END-1, a fixed table compiled into QuickJS (quickjs-atom.h). Atom 0 is NULL.
//   * runtime string : JS_ATOM_END and above, allocated as the compiler runs.
//
// Runtime atom values are local to one compilation: JS_WriteObjectAtoms renumbers them in first-use order while
// writing, so only their identity matters, not the value we hand out. Identity is by content, exactly like
// JS_NewAtomStr: a string made only of code units < 256 is Latin-1, anything else is UTF-16, and two strings with
// the same units are the same atom. The private-name and symbol atoms at the end of quickjs-atom.h are symbols in
// QuickJS, so a string with the same spelling ("Symbol.iterator") must NOT resolve to them.

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
	return !atom_is_tagged_int(a) && a < JS_ATOM_END
}

// One interned runtime string in the shape JS_WriteString needs: Latin-1 bytes or UTF-16 units.
Interned_String :: String_Value

Atom_Table :: struct {
	allocator: runtime.Allocator,
	// Runtime (non-predefined) atoms; the value of the i-th entry is JS_ATOM_END + i.
	runtime:   [dynamic]Interned_String,
	// Latin-1 strings by their bytes (predefined string atoms are pre-populated), UTF-16 strings by their raw
	// unit bytes. Two maps so a Latin-1 key can never collide with the byte view of a wide string.
	index:     map[string]Atom,
	windex:    map[string]Atom,
}

atom_table_init :: proc(t: ^Atom_Table, allocator: runtime.Allocator) {
	t.allocator = allocator
	t.runtime = make([dynamic]Interned_String, allocator)
	t.index = make(map[string]Atom, 512, allocator)
	t.windex = make(map[string]Atom, 16, allocator)
	for name, i in PREDEFINED_ATOMS {
		if name in t.index {
			// The second "<brand>" is Private_brand: it and everything after it are symbols, not strings.
			if name == "<brand>" {break}
			continue
		}
		t.index[name] = Atom(i + 1)
	}
}

// is_num_string: the JS_NewAtomStr array-index test. The canonical decimal form of an integer up to 2^32-1; the
// atom is a tagged int only when the value also fits the 31-bit atom integer range.
@(private = "file")
is_num_string :: proc(b: []u8) -> (u32, bool) {
	n := len(b)
	if n == 0 || n > 10 {return 0, false}
	c := b[0]
	if c < '0' || c > '9' {return 0, false}
	if c == '0' {
		if n != 1 {return 0, false}
		return 0, true
	}
	v := u64(c - '0')
	for i in 1 ..< n {
		c = b[i]
		if c < '0' || c > '9' {return 0, false}
		v = v * 10 + u64(c - '0')
		if v >= (u64(1) << 32) {return 0, false}
	}
	return u32(v), true
}

// atom_from_string returns the atom of a JS string value (JS_NewAtomStr).
atom_from_string :: proc(t: ^Atom_Table, sv: String_Value) -> Atom {
	if !sv.is_wide {
		if n, ok := is_num_string(sv.latin1); ok && n <= JS_ATOM_MAX_INT {
			return atom_from_uint32(n)
		}
		key := string(sv.latin1)
		if a, ok := t.index[key]; ok {return a}
		owned := make([]u8, len(sv.latin1), t.allocator)
		copy(owned, sv.latin1)
		a := Atom(u32(JS_ATOM_END) + u32(len(t.runtime)))
		append(&t.runtime, String_Value{latin1 = owned})
		t.index[string(owned)] = a
		return a
	}
	key := string(transmute([]u8)sv.units)
	if a, ok := t.windex[key]; ok {return a}
	owned := make([]u16, len(sv.units), t.allocator)
	copy(owned, sv.units)
	a := Atom(u32(JS_ATOM_END) + u32(len(t.runtime)))
	append(&t.runtime, String_Value{units = owned, is_wide = true})
	t.windex[string(transmute([]u8)owned)] = a
	return a
}

// intern returns the atom of a UTF-8 name (JS_NewAtomLen).
intern :: proc(t: ^Atom_Table, name: string) -> Atom {
	return atom_from_string(t, string_from_utf8(name, t.allocator))
}

// atom_to_string is JS_AtomToString: the string value an atom denotes (a tagged int becomes its decimal form).
atom_to_string :: proc(t: ^Atom_Table, a: Atom) -> String_Value {
	if atom_is_tagged_int(a) {
		buf: [16]u8
		n := atom_to_uint32(a)
		i := len(buf)
		for {
			i -= 1
			buf[i] = u8('0' + n % 10)
			n /= 10
			if n == 0 {break}
		}
		out := make([]u8, len(buf) - i, t.allocator)
		copy(out, buf[i:])
		return String_Value{latin1 = out}
	}
	if a < JS_ATOM_END {
		if a == JS_ATOM_NULL {return String_Value{}}
		return String_Value{latin1 = transmute([]u8)PREDEFINED_ATOMS[int(a) - 1]}
	}
	return t.runtime[int(a) - int(JS_ATOM_END)]
}

// atom_concat appends an ASCII suffix to an atom's string (js_atom_concat_str).
atom_concat :: proc(t: ^Atom_Table, a: Atom, suffix: string) -> Atom {
	s := atom_to_string(t, a)
	units := make([dynamic]u16, 0, string_len(s) + len(suffix), t.allocator)
	for i in 0 ..< string_len(s) {append(&units, string_at(s, i))}
	for c in transmute([]u8)suffix {append(&units, u16(c))}
	return atom_from_string(t, string_from_units(units[:], t.allocator))
}

// atom_concat_num appends a decimal number (js_atom_concat_num).
atom_concat_num :: proc(t: ^Atom_Table, a: Atom, n: int) -> Atom {
	buf: [24]u8
	i := len(buf)
	v := n
	for {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
		if v == 0 {break}
	}
	return atom_concat(t, a, string(buf[i:]))
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

// predef_atom returns the predefined atom value for a name known to be in PREDEFINED_ATOMS (first match).
predef_atom :: proc(name: string) -> Atom {
	for n, i in PREDEFINED_ATOMS {
		if n == name {
			return Atom(i + 1)
		}
	}
	return JS_ATOM_NULL
}
