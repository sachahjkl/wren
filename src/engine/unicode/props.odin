package ucd

// Property, general-category and script lookups over the generated interval tables. These feed the regexp
// `\p{...}` / `\P{...}` escapes (Unicode mode) and the identifier/whitespace predicates the JS lexer and regexp
// need. Everything here is a binary search over sorted [lo, hi) runs: no decoder state, freestanding-friendly.

// Fill `cr` (initialized, empty) with every code point in the named general category. Returns false if the
// name is unknown. Accepts the short alias (Lu, Nd, ...) and the grouping categories L, M, N, P, S, Z, C, LC.
general_category :: proc(cr: ^Char_Range, name: string) -> bool {
	// Grouping categories expand to the union of their members.
	switch name {
	case "L", "Letter":
		return union_categories(cr, {"Lu", "Ll", "Lt", "Lm", "Lo"})
	case "LC", "Cased_Letter":
		return union_categories(cr, {"Lu", "Ll", "Lt"})
	case "M", "Mark":
		return union_categories(cr, {"Mn", "Mc", "Me"})
	case "N", "Number":
		return union_categories(cr, {"Nd", "Nl", "No"})
	case "P", "Punctuation":
		return union_categories(cr, {"Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po"})
	case "S", "Symbol":
		return union_categories(cr, {"Sm", "Sc", "Sk", "So"})
	case "Z", "Separator":
		return union_categories(cr, {"Zs", "Zl", "Zp"})
	case "C", "Other":
		return union_categories(cr, {"Cc", "Cf", "Cs", "Co", "Cn"})
	}
	runs := find_named(general_category_tables, name)
	if runs == nil { return false }
	add_runs(cr, runs)
	return true
}

@(private)
union_categories :: proc(cr: ^Char_Range, names: []string) -> bool {
	for n in names {
		runs := find_named(general_category_tables, n)
		if runs == nil { return false }
		add_runs(cr, runs)
	}
	cr_normalize(cr)
	return true
}

// Fill `cr` with every code point having the named binary property (DerivedCoreProperties / PropList / emoji).
binary_property :: proc(cr: ^Char_Range, name: string) -> bool {
	runs := find_named(binary_prop_tables, name)
	if runs == nil { return false }
	add_runs(cr, runs)
	return true
}

// Fill `cr` with the named script (is_ext=false) or Script_Extensions (is_ext=true).
script :: proc(cr: ^Char_Range, name: string, is_ext := false) -> bool {
	table := is_ext ? script_ext_tables : script_tables
	runs := find_named(table, name)
	if runs == nil {
		// Script_Extensions is a superset: a character with no explicit extension carries its own script, so
		// fall back to the base script table for names present only there.
		if is_ext {
			runs = find_named(script_tables, name)
		}
		if runs == nil { return false }
	}
	add_runs(cr, runs)
	// Script_Extensions must also include the base-script characters.
	if is_ext {
		base := find_named(script_tables, name)
		if base != nil { add_runs(cr, base); cr_normalize(cr) }
	}
	return true
}

// Resolve any of the regexp `\p{}` property forms: a lone name (binary property or general-category shorthand,
// e.g. \p{Letter}, \p{White_Space}) or "General_Category=Lu", "Script=Greek", "Script_Extensions=Greek".
property :: proc(cr: ^Char_Range, name, value: string) -> bool {
	if value == "" {
		// Lone name: try binary property, then general category shorthand.
		if binary_property(cr, name) { return true }
		cr_clear(cr)
		return general_category(cr, name)
	}
	switch name {
	case "General_Category", "gc":
		return general_category(cr, value)
	case "Script", "sc":
		return script(cr, value, false)
	case "Script_Extensions", "scx":
		return script(cr, value, true)
	}
	return false
}

@(private)
find_named :: proc(tables: []Named_Table, name: string) -> []Range_Run {
	for t in tables {
		if t.name == name { return t.runs }
	}
	return nil
}

@(private)
add_runs :: proc(cr: ^Char_Range, runs: []Range_Run) {
	for r in runs { cr_add_interval(cr, r.lo, r.hi) }
}

run_contains :: proc(runs: []Range_Run, c: u32) -> bool {
	lo, hi := 0, len(runs)
	for lo < hi {
		mid := (lo + hi) / 2
		if c < runs[mid].lo {
			hi = mid
		} else if c >= runs[mid].hi {
			lo = mid + 1
		} else {
			return true
		}
	}
	return false
}

// ---- Predicates the JS lexer / regexp use directly ------------------------------------------------------

is_id_start :: proc(c: u32) -> bool {
	if c < 128 {
		return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '$'
	}
	return run_contains_named(binary_prop_tables, "ID_Start", c)
}

is_id_continue :: proc(c: u32) -> bool {
	if c < 128 {
		return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
		       (c >= '0' && c <= '9') || c == '_' || c == '$'
	}
	// ZWNJ and ZWJ are accepted in identifiers per the lexer rules.
	if c == 0x200C || c == 0x200D { return true }
	return run_contains_named(binary_prop_tables, "ID_Continue", c)
}

is_white_space :: proc(c: u32) -> bool {
	if c < 128 {
		return c == 0x09 || c == 0x0A || c == 0x0B || c == 0x0C || c == 0x0D || c == 0x20
	}
	return run_contains_named(binary_prop_tables, "White_Space", c)
}

is_cased :: proc(c: u32) -> bool {
	if c < 128 { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') }
	return run_contains_named(binary_prop_tables, "Cased", c)
}

is_case_ignorable :: proc(c: u32) -> bool {
	return run_contains_named(binary_prop_tables, "Case_Ignorable", c)
}

@(private)
run_contains_named :: proc(tables: []Named_Table, name: string, c: u32) -> bool {
	runs := find_named(tables, name)
	if runs == nil { return false }
	return run_contains(runs, c)
}
