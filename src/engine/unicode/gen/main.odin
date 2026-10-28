package unicode_gen

// Generator for src/engine/unicode/tables_generated.odin.
//
// It reads the pinned Unicode Character Database (UCD) files from a local cache directory and emits flat Odin
// tables (sorted interval runs, a case table, folding map, decomposition/composition data). The fetching and
// SHA-256 pinning are done by tools/gen_unicode.ps1 (the same idiom as tools/build_js.ps1), which then runs this
// program. We intentionally do not copy QuickJS's libunicode-table.h; every number here is derived from the UCD.
//
// Usage: unicode_gen <ucd_dir> <out_file>
//   ucd_dir  directory holding UnicodeData.txt, DerivedCoreProperties.txt, PropList.txt, Scripts.txt,
//            ScriptExtensions.txt, CaseFolding.txt, SpecialCasing.txt, DerivedNormalizationProps.txt,
//            emoji/emoji-data.txt, extracted/DerivedGeneralCategory.txt, PropertyValueAliases.txt.
//   out_file path of the Odin file to write.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:strconv"
import "core:slice"

Run :: struct { lo, hi: u32 }

main :: proc() {
	args := os.args
	if len(args) < 3 {
		fmt.eprintln("usage: unicode_gen <ucd_dir> <out_file>")
		os.exit(2)
	}
	ucd := args[1]
	out := args[2]

	version := read_version(ucd)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	emit_header(&b, version)

	// General categories (from extracted/DerivedGeneralCategory.txt).
	gc := parse_prop_list(path(ucd, "extracted/DerivedGeneralCategory.txt"))
	emit_named_tables(&b, "general_category", gc)

	// Binary properties for \p{}: DerivedCoreProperties + PropList + DerivedNormalizationProps subset + emoji.
	props := map[string][dynamic]Run{}
	merge_props(&props, parse_prop_list(path(ucd, "DerivedCoreProperties.txt")))
	merge_props(&props, parse_prop_list(path(ucd, "PropList.txt")))
	merge_props(&props, parse_prop_list(path(ucd, "emoji/emoji-data.txt")))
	// A couple of normalization-derived binary props the regexp \p needs.
	merge_props(&props, filter_props(parse_prop_list(path(ucd, "DerivedNormalizationProps.txt")),
		{"Changes_When_NFKC_Casefolded"}))
	merge_props(&props, parse_bidi_mirrored(path(ucd, "UnicodeData.txt")))
	emit_named_tables_map(&b, "binary_prop", &props)

	// Scripts and Script_Extensions.
	scripts := parse_prop_list(path(ucd, "Scripts.txt"))
	emit_named_tables(&b, "script", scripts)
	sx := parse_script_extensions(path(ucd, "ScriptExtensions.txt"))
	emit_named_tables(&b, "script_ext", sx)

	// Case folding (simple + full) and special casing drive canonicalize and case_conv.
	emit_case(&b, ucd)

	// Normalization data.
	emit_normalization(&b, ucd)

	werr := os.write_entire_file(out, b.buf[:])
	if werr != nil {
		fmt.eprintfln("could not write %s", out)
		os.exit(1)
	}
	fmt.printfln("wrote %s (Unicode %s)", out, version)
}

path :: proc(dir, name: string) -> string {
	return fmt.aprintf("%s/%s", dir, name)
}

// Read a whole file, returning (data, ok). Wraps the nightly os.read_entire_file which now returns an Error.
read_file :: proc(name: string) -> (data: []byte, ok: bool) {
	d, err := os.read_entire_file_from_path(name, context.allocator)
	return d, err == nil
}

read_version :: proc(ucd: string) -> string {
	// ReadMe or the header of UnicodeData is not versioned; use the pinned VERSION file the ps1 writes.
	data, ok := read_file(path(ucd, "VERSION"))
	if !ok { return "unknown" }
	return strings.trim_space(string(data))
}

// ---- UCD line parsing --------------------------------------------------------------------------------------

// Strip a trailing comment (after '#') and surrounding whitespace.
strip :: proc(line: string) -> string {
	s := line
	if idx := strings.index_byte(s, '#'); idx >= 0 { s = s[:idx] }
	return strings.trim_space(s)
}

parse_hex :: proc(s: string) -> u32 {
	v, _ := strconv.parse_u64_of_base(strings.trim_space(s), 16)
	return u32(v)
}

// Parse a "range" field which is either "XXXX" or "XXXX..YYYY".
parse_range_field :: proc(s: string) -> (lo, hi: u32) {
	t := strings.trim_space(s)
	if idx := strings.index(t, ".."); idx >= 0 {
		lo = parse_hex(t[:idx])
		hi = parse_hex(t[idx + 2:])
	} else {
		lo = parse_hex(t)
		hi = lo
	}
	return
}

// A file of lines "range ; Property" (DerivedCoreProperties, PropList, Scripts, DerivedGeneralCategory, emoji).
parse_prop_list :: proc(file: string) -> map[string][dynamic]Run {
	out := map[string][dynamic]Run{}
	data, ok := read_file(file)
	if !ok {
		fmt.eprintfln("warning: missing %s", file)
		return out
	}
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		s := strip(line)
		if len(s) == 0 { continue }
		semi := strings.index_byte(s, ';')
		if semi < 0 { continue }
		lo, hi := parse_range_field(s[:semi])
		name := strings.clone(strings.trim_space(s[semi + 1:]))
		// A property line may have further ';' fields (emoji-data has none meaningful); keep the first token.
		if sp := strings.index_byte(name, ';'); sp >= 0 { name = name[:sp] }
		runs, found := &out[name]
		if !found {
			out[name] = make([dynamic]Run)
			runs = &out[name]
		}
		append(runs, Run{lo, hi})
	}
	return out
}

// Bidi_Mirrored is UnicodeData.txt field 9 ('Y'); no First/Last range carries it.
parse_bidi_mirrored :: proc(file: string) -> map[string][dynamic]Run {
	out := map[string][dynamic]Run{}
	data, ok := read_file(file)
	if !ok { return out }
	runs := make([dynamic]Run)
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		fields := strings.split(line, ";")
		defer delete(fields)
		if len(fields) < 10 || strings.trim_space(fields[9]) != "Y" { continue }
		c := parse_hex(fields[0])
		append(&runs, Run{c, c})
	}
	out["Bidi_Mirrored"] = runs
	return out
}

filter_props :: proc(m: map[string][dynamic]Run, keep: []string) -> map[string][dynamic]Run {
	out := map[string][dynamic]Run{}
	for k, v in m {
		for want in keep {
			if k == want { out[k] = v; break }
		}
	}
	return out
}

merge_props :: proc(dst: ^map[string][dynamic]Run, src: map[string][dynamic]Run) {
	for k, v in src {
		existing, found := &dst[k]
		if !found {
			dst[k] = v
		} else {
			for r in v { append(existing, r) }
		}
	}
}

// ScriptExtensions.txt: "range ; Script1 Script2 ...". We invert to per-script run lists.
parse_script_extensions :: proc(file: string) -> map[string][dynamic]Run {
	out := map[string][dynamic]Run{}
	data, ok := read_file(file)
	if !ok { return out }
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		s := strip(line)
		if len(s) == 0 { continue }
		semi := strings.index_byte(s, ';')
		if semi < 0 { continue }
		lo, hi := parse_range_field(s[:semi])
		names := strings.fields(s[semi + 1:])
		for nm in names {
			key := strings.clone(nm)
			runs, found := &out[key]
			if !found { out[key] = make([dynamic]Run); runs = &out[key] }
			append(runs, Run{lo, hi})
		}
		delete(names)
	}
	return out
}

// ---- Normalization and sorting helpers --------------------------------------------------------------------

normalize_runs :: proc(runs: ^[dynamic]Run) {
	slice.sort_by(runs[:], proc(a, b: Run) -> bool { return a.lo < b.lo })
	w := 0
	for i in 0 ..< len(runs) {
		if w > 0 && runs[i].lo <= runs[w - 1].hi + 1 {
			if runs[i].hi > runs[w - 1].hi { runs[w - 1].hi = runs[i].hi }
		} else {
			runs[w] = runs[i]
			w += 1
		}
	}
	resize(runs, w)
}

// ---- Emission ----------------------------------------------------------------------------------------------

emit_header :: proc(b: ^strings.Builder, version: string) {
	fmt.sbprintln(b, "package ucd")
	fmt.sbprintln(b, "")
	fmt.sbprintfln(b, "// GENERATED by src/engine/unicode/gen. Do not edit. Unicode %s.", version)
	fmt.sbprintfln(b, "UNICODE_VERSION :: %q", version)
	fmt.sbprintln(b, "")
}

emit_named_tables :: proc(b: ^strings.Builder, prefix: string, m: map[string][dynamic]Run) {
	mm := m
	emit_named_tables_map(b, prefix, &mm)
}

emit_named_tables_map :: proc(b: ^strings.Builder, prefix: string, m: ^map[string][dynamic]Run) {
	keys := make([dynamic]string)
	defer delete(keys)
	for k in m { append(&keys, k) }
	slice.sort(keys[:])
	fmt.sbprintfln(b, "%s_tables := []Named_Table{{", prefix)
	for k in keys {
		runs := &m[k]
		normalize_runs(runs)
		fmt.sbprintf(b, "\t{{%q, []Range_Run{{", k)
		for r, i in runs {
			if i > 0 { fmt.sbprint(b, ", ") }
			fmt.sbprintf(b, "{{0x%x, 0x%x}}", r.lo, r.hi + 1) // store half-open [lo, hi+1)
		}
		fmt.sbprintln(b, "}},")
	}
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "")
}

// Case folding: CaseFolding.txt has lines "code; status; mapping; # name". status C/S are the common/simple
// 1:1 fold; F is full (1:n). We emit the simple fold map and the full fold list.
emit_case :: proc(b: ^strings.Builder, ucd: string) {
	data, ok := read_file(path(ucd, "CaseFolding.txt"))
	if !ok { fmt.eprintln("warning: missing CaseFolding.txt") }
	simple := make([dynamic]Fold)
	full := make([dynamic]FullFold)
	defer delete(simple)
	defer delete(full)
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		s := strip(line)
		if len(s) == 0 { continue }
		parts := strings.split(s, ";")
		defer delete(parts)
		if len(parts) < 3 { continue }
		code := parse_hex(parts[0])
		status := strings.trim_space(parts[1])
		maps := strings.fields(parts[2])
		defer delete(maps)
		if status == "C" || status == "S" {
			append(&simple, Fold{code, parse_hex(maps[0])})
		} else if status == "F" {
			ff := FullFold{ source = code }
			for m, i in maps { if i < 3 { ff.mapped[i] = parse_hex(m); ff.n += 1 } }
			append(&full, ff)
		}
	}
	slice.sort_by(simple[:], proc(a, b: Fold) -> bool { return a.from < b.from })
	slice.sort_by(full[:], proc(a, b: FullFold) -> bool { return a.source < b.source })

	fmt.sbprintln(b, "simple_fold_table := []Fold_Entry{")
	for f in simple { fmt.sbprintfln(b, "\t{{0x%x, 0x%x}},", f.from, f.to) }
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "")

	fmt.sbprintln(b, "full_fold_table := []Full_Case{")
	for f in full {
		fmt.sbprintf(b, "\t{{0x%x, []u32{{", f.source)
		for i in 0 ..< f.n { if i > 0 { fmt.sbprint(b, ", ") }; fmt.sbprintf(b, "0x%x", f.mapped[i]) }
		fmt.sbprintln(b, "}},")
	}
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "")

	emit_special_casing(b, ucd)
}

Fold :: struct { from, to: u32 }
FullFold :: struct { source: u32, mapped: [3]u32, n: int }

// SpecialCasing.txt gives full upper/lower/title mappings (1:n). We only need unconditional entries (no locale
// or context conditions) for ECMAScript canonicalize and String.prototype.to{Upper,Lower}Case parity.
emit_special_casing :: proc(b: ^strings.Builder, ucd: string) {
	data, ok := read_file(path(ucd, "SpecialCasing.txt"))
	lowers := make([dynamic]FullFold)
	uppers := make([dynamic]FullFold)
	defer delete(lowers)
	defer delete(uppers)
	if ok {
		it := string(data)
		for line in strings.split_lines_iterator(&it) {
			s := strip(line)
			if len(s) == 0 { continue }
			parts := strings.split(s, ";")
			defer delete(parts)
			if len(parts) < 4 { continue }
			// Skip conditional mappings (5th field present and non-empty).
			if len(parts) >= 5 && len(strings.trim_space(parts[4])) > 0 { continue }
			code := parse_hex(parts[0])
			lower := strings.fields(parts[1]); defer delete(lower)
			upper := strings.fields(parts[3]); defer delete(upper)
			lf := FullFold{source = code}
			for m, i in lower { if i < 3 { lf.mapped[i] = parse_hex(m); lf.n += 1 } }
			uf := FullFold{source = code}
			for m, i in upper { if i < 3 { uf.mapped[i] = parse_hex(m); uf.n += 1 } }
			append(&lowers, lf)
			append(&uppers, uf)
		}
	}
	slice.sort_by(lowers[:], proc(a, b: FullFold) -> bool { return a.source < b.source })
	slice.sort_by(uppers[:], proc(a, b: FullFold) -> bool { return a.source < b.source })
	emit_fullcase_list(b, "special_lower_table", lowers[:])
	emit_fullcase_list(b, "special_upper_table", uppers[:])

	// Simple one-to-one upper/lower from UnicodeData.txt (fields 12 uppercase, 13 lowercase).
	emit_simple_casing(b, ucd)
}

emit_fullcase_list :: proc(b: ^strings.Builder, name: string, list: []FullFold) {
	fmt.sbprintfln(b, "%s := []Full_Case{{", name)
	for f in list {
		fmt.sbprintf(b, "\t{{0x%x, []u32{{", f.source)
		for i in 0 ..< f.n { if i > 0 { fmt.sbprint(b, ", ") }; fmt.sbprintf(b, "0x%x", f.mapped[i]) }
		fmt.sbprintln(b, "}},")
	}
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "")
}

emit_simple_casing :: proc(b: ^strings.Builder, ucd: string) {
	data, _ := read_file(path(ucd, "UnicodeData.txt"))
	ups := make([dynamic]Fold)
	los := make([dynamic]Fold)
	defer delete(ups)
	defer delete(los)
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		s := strings.trim_space(line)
		if len(s) == 0 { continue }
		parts := strings.split(s, ";")
		defer delete(parts)
		if len(parts) < 15 { continue }
		code := parse_hex(parts[0])
		up := strings.trim_space(parts[12])
		lo := strings.trim_space(parts[13])
		if len(up) > 0 { append(&ups, Fold{code, parse_hex(up)}) }
		if len(lo) > 0 { append(&los, Fold{code, parse_hex(lo)}) }
	}
	slice.sort_by(ups[:], proc(a, b: Fold) -> bool { return a.from < b.from })
	slice.sort_by(los[:], proc(a, b: Fold) -> bool { return a.from < b.from })
	emit_fold_list(b, "simple_upper_table", ups[:])
	emit_fold_list(b, "simple_lower_table", los[:])
}

emit_fold_list :: proc(b: ^strings.Builder, name: string, list: []Fold) {
	fmt.sbprintfln(b, "%s := []Fold_Entry{{", name)
	for f in list { fmt.sbprintfln(b, "\t{{0x%x, 0x%x}},", f.from, f.to) }
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "")
}

// Canonical/compat decomposition (UnicodeData field 5), combining classes (field 3), and the composition
// exclusions for recomposition.
emit_normalization :: proc(b: ^strings.Builder, ucd: string) {
	data, _ := read_file(path(ucd, "UnicodeData.txt"))
	excl := load_composition_exclusions(ucd)
	decomps := make([dynamic]DecompRow)
	ccs := make([dynamic]CCRow)
	defer delete(decomps)
	defer delete(ccs)
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		s := strings.trim_space(line)
		if len(s) == 0 { continue }
		parts := strings.split(s, ";")
		defer delete(parts)
		if len(parts) < 6 { continue }
		code := parse_hex(parts[0])
		cc_s := strings.trim_space(parts[3])
		if cc_s != "0" && len(cc_s) > 0 {
			cc, _ := strconv.parse_int(cc_s)
			append(&ccs, CCRow{code, u8(cc)})
		}
		decomp := strings.trim_space(parts[5])
		if len(decomp) > 0 {
			compat := false
			d := decomp
			if strings.has_prefix(d, "<") {
				compat = true
				if idx := strings.index_byte(d, '>'); idx >= 0 { d = strings.trim_space(d[idx + 1:]) }
			}
			toks := strings.fields(d); defer delete(toks)
			row := DecompRow{code = code, compat = compat}
			for t, i in toks { if i < 18 { row.mapped[i] = parse_hex(t); row.n += 1 } }
			append(&decomps, row)
		}
	}

	fmt.sbprintln(b, "decomp_table := []Decomp_Entry{")
	for d in decomps {
		fmt.sbprintf(b, "\t{{0x%x, %v, []u32{{", d.code, d.compat)
		for i in 0 ..< d.n { if i > 0 { fmt.sbprint(b, ", ") }; fmt.sbprintf(b, "0x%x", d.mapped[i]) }
		fmt.sbprintln(b, "}},")
	}
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "")

	fmt.sbprintln(b, "combining_class_table := []Combining_Entry{")
	for c in ccs { fmt.sbprintfln(b, "\t{{0x%x, 0x%x, %d}},", c.code, c.code + 1, c.cc) }
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "")

	// Precompute the composition table: canonical (non-compat, length-2) decompositions whose starter is not in
	// the composition-exclusion set recompose.
	fmt.sbprintln(b, "compose_table := []Compose_Entry{")
	comps := make([dynamic]ComposeRow); defer delete(comps)
	for d in decomps {
		if d.compat || d.n != 2 { continue }
		if _, ex := excl[d.code]; ex { continue }
		append(&comps, ComposeRow{d.mapped[0], d.mapped[1], d.code})
	}
	slice.sort_by(comps[:], proc(a, b: ComposeRow) -> bool {
		if a.a != b.a { return a.a < b.a }
		return a.b < b.b
	})
	for c in comps { fmt.sbprintfln(b, "\t{{0x%x, 0x%x, 0x%x}},", c.a, c.b, c.result) }
	fmt.sbprintln(b, "}")
	fmt.sbprintln(b, "")
}

DecompRow :: struct { code: u32, compat: bool, mapped: [18]u32, n: int }
CCRow :: struct { code: u32, cc: u8 }
ComposeRow :: struct { a, b, result: u32 }

load_composition_exclusions :: proc(ucd: string) -> map[u32]bool {
	out := map[u32]bool{}
	data, ok := read_file(path(ucd, "DerivedNormalizationProps.txt"))
	if !ok { return out }
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		s := strip(line)
		if len(s) == 0 { continue }
		semi := strings.index_byte(s, ';')
		if semi < 0 { continue }
		prop := strings.trim_space(s[semi + 1:])
		if sp := strings.index_byte(prop, ';'); sp >= 0 { prop = strings.trim_space(prop[:sp]) }
		if prop != "Full_Composition_Exclusion" { continue }
		lo, hi := parse_range_field(s[:semi])
		for c in lo ..= hi { out[c] = true }
	}
	return out
}
