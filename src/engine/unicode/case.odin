package ucd

// Case conversion, case folding and the ECMAScript regexp `canonicalize` operation. These back the regexp `i`
// flag (both the Annex-B legacy rule and the `u`/`v` full-folding rule) and String.prototype.to{Upper,Lower}Case
// parity. The data comes from the generated tables (simple upper/lower from UnicodeData, full mappings from
// SpecialCasing, foldings from CaseFolding).

Case_Conv :: enum u8 {
	To_Upper, // 0
	To_Lower, // 1
	Fold,     // 2: case folding (lower with the CaseFolding-specific tweaks)
}

// Simple (1:1) case conversion of a single code point. Returns the mapped code point (== c if none).
simple_case :: proc(c: u32, conv: Case_Conv) -> u32 {
	if c < 128 {
		switch conv {
		case .To_Upper:
			if c >= 'a' && c <= 'z' { return c - 'a' + 'A' }
		case .To_Lower, .Fold:
			if c >= 'A' && c <= 'Z' { return c - 'A' + 'a' }
		}
		return c
	}
	switch conv {
	case .To_Upper:
		if v, ok := fold_lookup(simple_upper_table, c); ok { return v }
	case .To_Lower:
		if v, ok := fold_lookup(simple_lower_table, c); ok { return v }
	case .Fold:
		if v, ok := fold_lookup(simple_fold_table, c); ok { return v }
	}
	return c
}

// Full case conversion: writes 1..3 code points into `res`, returns the count. Full mappings come from
// SpecialCasing (upper/lower) and CaseFolding status F (folding); where none applies, falls back to the simple
// 1:1 mapping.
full_case :: proc(res: ^[3]u32, c: u32, conv: Case_Conv) -> int {
	table: []Full_Case
	switch conv {
	case .To_Upper: table = special_upper_table
	case .To_Lower: table = special_lower_table
	case .Fold:     table = full_fold_table
	}
	if mapped, ok := fullcase_lookup(table, c); ok {
		n := min(len(mapped), 3)
		for i in 0 ..< n { res[i] = mapped[i] }
		return n
	}
	res[0] = simple_case(c, conv)
	return 1
}

// ECMAScript 22.2.2.9 Canonicalize. In unicode (u/v) mode this is the simple case folding; in legacy mode it is
// the "to upper" of a single-character uppercasing, with the ASCII and >=128 guards from the spec (a lowercase
// that maps to a shorter or ASCII result is left unchanged).
canonicalize :: proc(c: u32, is_unicode: bool) -> u32 {
	if c < 128 {
		if is_unicode {
			if c >= 'A' && c <= 'Z' { return c - 'A' + 'a' }
		} else {
			if c >= 'a' && c <= 'z' { return c - 'a' + 'A' }
		}
		return c
	}
	if is_unicode {
		// Simple folding; a handful of code points whose full fold differs from their simple fold are handled
		// via the simple_fold_table which already carries the C/S status entries.
		return simple_case(c, .Fold)
	}
	// Legacy (non-unicode) rule: uppercase via the simple mapping, but only adopt it when the result stays a
	// single code point >= 128 (the spec's "if u does not consist of a single code unit / < 128, return ch").
	u := simple_case(c, .To_Upper)
	if u >= 128 { return u }
	return c
}

@(private)
fold_lookup :: proc(table: []Fold_Entry, c: u32) -> (u32, bool) {
	lo, hi := 0, len(table)
	for lo < hi {
		mid := (lo + hi) / 2
		if c < table[mid].from {
			hi = mid
		} else if c > table[mid].from {
			lo = mid + 1
		} else {
			return table[mid].to, true
		}
	}
	return c, false
}

@(private)
fullcase_lookup :: proc(table: []Full_Case, c: u32) -> ([]u32, bool) {
	lo, hi := 0, len(table)
	for lo < hi {
		mid := (lo + hi) / 2
		if c < table[mid].source {
			hi = mid
		} else if c > table[mid].source {
			lo = mid + 1
		} else {
			return table[mid].mapped, true
		}
	}
	return nil, false
}

// Canonicalize an entire character set under the regexp `i` rules. For every code point in `cr`, add its
// canonical form. Used when compiling a case-insensitive character class: QuickJS's cr_regexp_canonicalize.
cr_canonicalize :: proc(cr: ^Char_Range, is_unicode: bool) {
	extra: Char_Range
	cr_init(&extra, cr.allocator)
	defer cr_destroy(&extra)
	// Walk the (small) runs. For large ranges this is bounded by the number of cased code points, which is why
	// we only canonicalize code points that actually have a case mapping; everything else maps to itself.
	for i := 0; i < len(cr.points); i += 2 {
		lo := cr.points[i]
		hi := cr.points[i + 1]
		for c := lo; c < hi; c += 1 {
			d := canonicalize(c, is_unicode)
			if d != c { cr_add_interval(&extra, d, d + 1) }
		}
	}
	cr_normalize(&extra)
	cr_op_inplace(cr, &extra, .Union)
}
