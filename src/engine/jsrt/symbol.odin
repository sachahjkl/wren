package jsrt

// Symbols: unique, non-string property keys (ECMAScript Symbol).
//
// A Symbol cell carries an optional description string and, for the well-known symbols
// (Symbol.iterator, Symbol.toPrimitive, ...), a stable identity the runtime seeds at startup. Symbols
// are heap cells so they are reference counted; they never form cycles. When a symbol is used as a
// property key it is first interned into the atom table (atom_type = .symbol), so key comparison stays
// a single integer compare like string keys.

JS_Symbol :: Symbol

Symbol :: struct {
	using header: GC_Header,
	description:  ^JS_String, // may be nil (Symbol() with no description)
	atom:         Atom,       // the interned atom for this symbol, or null_atom until interned
	is_well_known: bool,
}

symbol_create :: proc(rt: ^Runtime, description: ^JS_String) -> ^Symbol {
	sym := gc_new_cell(rt, Symbol, .symbol)
	if sym == nil {return nil}
	if description != nil {
		sym.description = string_ref(description)
	}
	sym.atom = Atom(Predef_Atom.null_atom)
	return sym
}

symbol_destroy :: proc(rt: ^Runtime, sym: ^Symbol) {
	if sym.description != nil {
		string_unref(rt, sym.description)
	}
	gc_raw_free(rt, sym, size_of(Symbol))
}
