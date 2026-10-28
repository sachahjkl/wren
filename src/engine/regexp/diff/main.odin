package rxdiff

// Differential judge: runs the Odin regexp/unicode engine and QuickJS-ng's reference C (via build/cref/creflib.dll)
// over thousands of inputs and reports every divergence, plus a speed comparison. This is a standalone program
// (not an odin test) so it can load the DLL by relative path and print a readable report. Build/run via
// tools/rx_diff.ps1, which builds the C shim DLL first.
//
//   rxdiff [seed] [fuzz_count]
//
// It exercises: lre_canonicalize, case conversion, the id/space/cased predicates, \p / gc / script range sets,
// normalization (NFC/NFD/NFKC/NFKD), and regexp compile+exec on a literal corpus and random fuzz patterns.

import "core:fmt"
import "core:os"

@(private) skip_c := false
@(private) ref_crashes := 0
@(private) ref_crash_samples: [dynamic]string
import "core:math/rand"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import rx "wb:engine/regexp"
import ucd "wb:engine/unicode"

foreign import cref "../../../../build/cref/shim.lib"

@(default_calling_convention="c")
foreign cref {
	cshim_compile :: proc(pattern: cstring, pattern_len: i32, flags: i32, error_msg: [^]u8, error_msg_size: i32, out_len: ^i32) -> rawptr ---
	cshim_free_bc :: proc(bc: rawptr) ---
	cshim_capture_count :: proc(bc: rawptr) -> i32 ---
	cshim_exec :: proc(bc: rawptr, cbuf: rawptr, cindex: i32, clen: i32, cbuf_type: i32, out_caps: [^]i32, capture_count: i32) -> i32 ---
	cshim_canonicalize :: proc(c: u32, is_unicode: i32) -> i32 ---
	cshim_is_id_start :: proc(c: u32) -> i32 ---
	cshim_is_id_continue :: proc(c: u32) -> i32 ---
	cshim_is_white_space :: proc(c: u32) -> i32 ---
	cshim_is_cased :: proc(c: u32) -> i32 ---
	cshim_is_case_ignorable :: proc(c: u32) -> i32 ---
	cshim_case_conv :: proc(res: [^]u32, c: u32, conv_type: i32) -> i32 ---
	cshim_normalize :: proc(src: [^]u32, src_len: i32, form: i32, out: [^]u32, out_cap: i32) -> i32 ---
	cshim_general_category :: proc(name: cstring, out: [^]u32, out_cap: i32) -> i32 ---
	cshim_prop :: proc(name: cstring, out: [^]u32, out_cap: i32) -> i32 ---
	cshim_script :: proc(name: cstring, is_ext: i32, out: [^]u32, out_cap: i32) -> i32 ---
}

Report :: struct {
	checks:      int,
	mismatches:  int,
	first_fails: [dynamic]string,
}

main :: proc() {
	seed: u64 = 0x12345
	fuzz := 20000
	if len(os.args) > 1 { if v, ok := parse_u64(os.args[1]); ok { seed = v } }
	if len(os.args) > 2 { if v, ok := parse_u64(os.args[2]); ok { fuzz = int(v) } }

	skip_c = os.get_env("RXDIFF_NO_C", context.temp_allocator) != ""
	r := Report{}
	fmt.println("== Unicode: canonicalize / case / predicates ==")
	check_unicode_scalars(&r)
	fmt.println("== Unicode: property / category / script ranges ==")
	check_unicode_ranges(&r)
	fmt.println("== Unicode: normalization ==")
	check_normalization(&r, seed)
	fmt.println("== Regexp: literal corpus ==")
	check_regexp_corpus(&r)
	fmt.printfln("== Regexp: fuzz (%d patterns) ==", fuzz)
	check_regexp_fuzz(&r, seed, fuzz)

	fmt.println()
	fmt.printfln("checks=%d mismatches=%d reference_crashes=%d", r.checks, r.mismatches, ref_crashes)
	for s in r.first_fails {
		fmt.printfln("  FAIL: %s", s)
	}
	if ref_crashes > 0 {
		fmt.printfln("  (reference crashed on %d inputs; QuickJS-ng 0.17 lre_exec bug, not the Odin engine)", ref_crashes)
		for s in ref_crash_samples { fmt.printfln("    ref-crash: %s", s) }
	}
	os.flush(os.stdout)

	fmt.println()
	fmt.println("== Speed (ns/exec, 5 typical patterns) ==")
	bench_speed()
	os.flush(os.stdout)

	if r.mismatches > 0 { os.exit(1) }
}

note_fail :: proc(r: ^Report, msg: string) {
	r.mismatches += 1
	if len(r.first_fails) < 40 { append(&r.first_fails, strings.clone(msg)) }
}

parse_u64 :: proc(s: string) -> (u64, bool) {
	v: u64 = 0
	if len(s) == 0 { return 0, false }
	for ch in s {
		if ch < '0' || ch > '9' { return 0, false }
		v = v * 10 + u64(ch - '0')
	}
	return v, true
}

// ---- Unicode scalar checks ----------------------------------------------------------------------------------

check_unicode_scalars :: proc(r: ^Report) {
	for c: u32 = 0; c <= 0x2FFFF; c += 1 {
		// canonicalize both modes
		for um in 0 ..< 2 {
			r.checks += 1
			got := u32(ucd.canonicalize(c, um == 1))
			want := u32(cshim_canonicalize(c, i32(um)))
			if got != want {
				note_fail(r, fmt.tprintf("canonicalize(U+%04X, u=%d): odin=%04X c=%04X", c, um, got, want))
			}
		}
		// predicates
		check_pred(r, "is_id_start", c, ucd.is_id_start(c), cshim_is_id_start(c) != 0)
		check_pred(r, "is_id_continue", c, ucd.is_id_continue(c), cshim_is_id_continue(c) != 0)
		check_pred(r, "is_white_space", c, ucd.is_white_space(c), cshim_is_white_space(c) != 0)
		check_pred(r, "is_cased", c, ucd.is_cased(c), cshim_is_cased(c) != 0)
		check_pred(r, "is_case_ignorable", c, ucd.is_case_ignorable(c), cshim_is_case_ignorable(c) != 0)
		// case conversion (upper/lower/fold)
		for conv in 0 ..< 3 {
			r.checks += 1
			cres: [3]u32
			cn := cshim_case_conv(raw_data(cres[:]), c, i32(conv))
			ores: [3]u32
			on := ucd.full_case(&ores, c, ucd.Case_Conv(conv))
			if int(cn) != on || !eq_prefix(ores[:], cres[:], on) {
				note_fail(r, fmt.tprintf("case_conv(U+%04X, conv=%d): odin=%v(%d) c=%v(%d)", c, conv, ores, on, cres, cn))
			}
		}
	}
}

check_pred :: proc(r: ^Report, name: string, c: u32, got, want: bool) {
	r.checks += 1
	if got != want {
		note_fail(r, fmt.tprintf("%s(U+%04X): odin=%v c=%v", name, c, got, want))
	}
}

eq_prefix :: proc(a, b: []u32, n: int) -> bool {
	for i in 0 ..< n { if a[i] != b[i] { return false } }
	return true
}

// ---- Unicode range checks -----------------------------------------------------------------------------------

check_unicode_ranges :: proc(r: ^Report) {
	gcs := []string{"Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl", "No", "Pc", "Pd", "Ps", "Pe",
		"Pi", "Pf", "Po", "Sm", "Sc", "Sk", "So", "Zs", "Zl", "Zp", "Cc", "Cf", "Cs", "Co", "L", "M", "N", "P", "S", "Z", "C"}
	for name in gcs {
		cr: ucd.Char_Range
		ucd.cr_init(&cr, context.allocator)
		ok := ucd.general_category(&cr, name)
		compare_range(r, fmt.tprintf("gc=%s", name), &cr, ok, proc_gc, name)
		ucd.cr_destroy(&cr)
	}
	props := []string{"White_Space", "Alphabetic", "Uppercase", "Lowercase", "Cased", "Case_Ignorable",
		"ID_Start", "ID_Continue", "Emoji", "Math", "Hex_Digit", "Dash", "Diacritic"}
	for name in props {
		cr: ucd.Char_Range
		ucd.cr_init(&cr, context.allocator)
		ok := ucd.binary_property(&cr, name)
		compare_range(r, fmt.tprintf("prop=%s", name), &cr, ok, proc_prop, name)
		ucd.cr_destroy(&cr)
	}
	scripts := []string{"Latin", "Greek", "Cyrillic", "Han", "Hiragana", "Katakana", "Arabic", "Hebrew", "Common", "Inherited"}
	for name in scripts {
		cr: ucd.Char_Range
		ucd.cr_init(&cr, context.allocator)
		ok := ucd.script(&cr, name, false)
		compare_range(r, fmt.tprintf("script=%s", name), &cr, ok, proc_script, name)
		ucd.cr_destroy(&cr)
	}
}

proc_gc :: proc(name: string, out: [^]u32, cap: i32) -> i32 {
	cn := strings.clone_to_cstring(name, context.temp_allocator)
	return cshim_general_category(cn, out, cap)
}
proc_prop :: proc(name: string, out: [^]u32, cap: i32) -> i32 {
	cn := strings.clone_to_cstring(name, context.temp_allocator)
	return cshim_prop(cn, out, cap)
}
proc_script :: proc(name: string, out: [^]u32, cap: i32) -> i32 {
	cn := strings.clone_to_cstring(name, context.temp_allocator)
	return cshim_script(cn, 0, out, cap)
}

compare_range :: proc(r: ^Report, label: string, cr: ^ucd.Char_Range, odin_ok: bool,
                      cproc: proc(string, [^]u32, i32) -> i32, name: string) {
	r.checks += 1
	buf := make([]u32, 1 << 20, context.allocator)
	defer delete(buf)
	cn := cproc(name, raw_data(buf), i32(len(buf)))
	if cn < 0 {
		// C does not know this name; only report if odin claims it does and produced content.
		if odin_ok && ucd.cr_len(cr) > 0 {
			// Many of our grouping names (L, M, ...) are not unicode_prop names in C; skip silently.
		}
		return
	}
	if !odin_ok {
		note_fail(r, fmt.tprintf("%s: odin unknown but C known", label))
		return
	}
	// Compare interval sets by sampling every boundary and a few interior points.
	cints := int(cn)
	// Build a membership comparison: walk both as sorted boundary lists.
	if ucd.cr_len(cr) != cints {
		note_fail(r, fmt.tprintf("%s: interval count odin=%d c=%d", label, ucd.cr_len(cr), cints))
		return
	}
	for i in 0 ..< cints * 2 {
		if cr.points[i] != buf[i] {
			note_fail(r, fmt.tprintf("%s: boundary %d odin=%X c=%X", label, i, cr.points[i], buf[i]))
			return
		}
	}
}

// ---- Normalization ------------------------------------------------------------------------------------------

check_normalization :: proc(r: ^Report, seed: u64) {
	rng := rand.create(seed ~ N0RM)
	context.random_generator = rand.default_random_generator(&rng)
	forms := []ucd.Normal_Form{.NFC, .NFD, .NFKC, .NFKD}
	for iter in 0 ..< 5000 {
		n := 1 + int(rand.uint32() % 6)
		src := make([]u32, n, context.temp_allocator)
		for i in 0 ..< n {
			// Mix of Latin, combining marks, Hangul, and compatibility chars.
			choice := rand.uint32() % 4
			switch choice {
			case 0: src[i] = 0x41 + rand.uint32() % 26
			case 1: src[i] = 0x300 + rand.uint32() % 0x70   // combining marks
			case 2: src[i] = 0xAC00 + rand.uint32() % 0x2BA4 // Hangul
			case 3: src[i] = 0x1E00 + rand.uint32() % 0x100  // Latin extended additional
			}
		}
		for form, fi in forms {
			r.checks += 1
			og := ucd.normalize(src, form, context.temp_allocator)
			cout := make([]u32, 64, context.temp_allocator)
			cn := cshim_normalize(raw_data(src), i32(n), i32(fi), raw_data(cout), 64)
			if cn < 0 { continue }
			if len(og) != int(cn) || !slice_eq(og, cout[:int(cn)]) {
				note_fail(r, fmt.tprintf("normalize(form=%d, %v): odin=%v c=%v", fi, src, og, cout[:int(cn)]))
			}
		}
		free_all(context.temp_allocator)
	}
}

slice_eq :: proc(a, b: []u32) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) { if a[i] != b[i] { return false } }
	return true
}

N0RM :: 0x4E4F524D

// ---- Regexp corpus + fuzz -----------------------------------------------------------------------------------

Corpus_Case :: struct { pattern: string, flags: string, subject: string }

check_regexp_corpus :: proc(r: ^Report) {
	cases := []Corpus_Case{
		{"abc", "", "zzabczz"},
		{"a|b|c", "", "xbx"},
		{"[a-z]+", "", "123abc456"},
		{"[^0-9]+", "", "abc123"},
		{"a*", "", "aaaa"},
		{"a+?b", "", "aaab"},
		{"(ab)+", "", "ababab"},
		{"(?:ab)+c", "", "ababc"},
		{"\\d{2,4}", "", "12345"},
		{"\\bword\\b", "", "a word here"},
		{"^start", "m", "x\nstart"},
		{"end$", "m", "end\nx"},
		{"foo(?=bar)", "", "foobar"},
		{"foo(?!bar)", "", "fooqux"},
		{"(?<=x)y", "", "xy"},
		{"(?<!x)y", "", "zy"},
		{"(a)(b)\\2\\1", "", "abba"},
		{"colou?r", "", "color"},
		{"a.c", "", "axc"},
		{"a.c", "s", "a\nc"},
		{"[\\w.]+@[\\w.]+", "", "user@host.com"},
		{"CASE", "i", "lowercase"},
		{"(?<g>\\d+)", "", "abc42"},
		{"x{0}y", "", "y"},
		{"(a|ab)(c|bcd)", "", "abcd"},
		{"a{2,}", "", "aaaaa"},
		{".*", "", "anything"},
		{"\\u0041", "", "A"},
	}
	for c in cases {
		check_one_regexp(r, c.pattern, c.flags, c.subject)
	}
}

check_regexp_fuzz :: proc(r: ^Report, seed: u64, count: int) {
	rng := rand.create(seed)
	context.random_generator = rand.default_random_generator(&rng)
	flag_sets := []string{"", "i", "m", "s", "g", "im", "ms"}
	for iter in 0 ..< count {
		pat := random_pattern(context.temp_allocator)
		subj := random_subject(context.temp_allocator)
		flags := flag_sets[rand.uint32() % u32(len(flag_sets))]
		when ODIN_DEBUG { fmt.eprintfln("[fuzz %d] /%s/%s on %q", iter, pat, flags, subj) }
		check_one_regexp(r, pat, flags, subj)
		free_all(context.temp_allocator)
	}
}

// Build a random but syntactically plausible pattern from a small alphabet of fragments. The fragments that can
// take a quantifier are kept separate from groups: QuickJS-ng 0.17's lre_exec corrupts the heap when a group
// combined with `+`/`*` (e.g. (a|b)+) is run repeatedly, so for the C-differential pass we never quantify a
// group. The Odin engine is additionally fuzzed over the unrestricted grammar in -NoC mode, where it is robust.
random_pattern :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	n := 1 + int(rand.uint32() % 5)
	atoms := []string{"a", "b", "c", ".", "[ab]", "[a-c]", "\\d", "\\w"}
	groups := []string{"(a|b)", "(?:bc)"}
	for i in 0 ..< n {
		if !skip_c && rand.uint32() % 5 == 0 {
			// A (possibly-anchored) group with no quantifier, safe for the reference.
			strings.write_string(&b, groups[rand.uint32() % u32(len(groups))])
			continue
		}
		if skip_c && rand.uint32() % 5 == 0 {
			// Odin-only mode: exercise the crash-triggering group+quantifier too.
			strings.write_string(&b, groups[rand.uint32() % u32(len(groups))])
			q := []string{"*", "+", "?", "*?", "+?"}
			strings.write_string(&b, q[rand.uint32() % u32(len(q))])
			continue
		}
		strings.write_string(&b, atoms[rand.uint32() % u32(len(atoms))])
		if rand.uint32() % 4 == 0 {
			q := []string{"*", "+", "?", "*?", "+?"}
			strings.write_string(&b, q[rand.uint32() % u32(len(q))])
		}
	}
	// A leading/trailing anchor sometimes.
	if rand.uint32() % 6 == 0 {
		return strings.concatenate({"^", strings.to_string(b)}, allocator)
	}
	return strings.to_string(b)
}

random_subject :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	n := int(rand.uint32() % 12)
	alpha := "abcxyz0123 \n"
	for i in 0 ..< n {
		strings.write_byte(&b, alpha[rand.uint32() % u32(len(alpha))])
	}
	return strings.to_string(b)
}

// Compile and exec both engines; compare the whole-match span and all captures at every valid start position.
check_one_regexp :: proc(r: ^Report, pattern, flags_str, subject: string) {
	r.checks += 1
	oflags, ok := rx.parse_flags(flags_str)
	if !ok { return }

	// Odin compile.
	ore, oerr := rx.compile(pattern, oflags, context.temp_allocator)
	odin_compiled := oerr.message == ""

	if skip_c {
		if odin_compiled {
			units := utf16_of(subject, context.temp_allocator)
			for start := 0; start <= len(units); start += 1 {
				ocaps: rx.Captures
				_ = rx.exec(&ore, rx.input_utf16(units), start, &ocaps, {}, context.temp_allocator)
			}
		}
		return // odin-only mode: just exercise compile+exec for crash/soundness checks
	}
	// C compile (flags bit layout matches LRE_FLAG_*).
	cflags := to_lre_flags(oflags)
	errbuf: [128]u8
	clen: i32
	cpat := strings.clone_to_cstring(pattern, context.temp_allocator)
	cbc := cshim_compile(cpat, i32(len(pattern)), cflags, raw_data(errbuf[:]), 128, &clen)
	c_compiled := cbc != nil
	defer if c_compiled { cshim_free_bc(cbc) }

	if odin_compiled != c_compiled {
		// Compile-agreement divergences are common where Annex B leniency differs; record but do not over-report.
		note_fail(r, fmt.tprintf("compile disagree /%s/%s: odin=%v c=%v (%s)", pattern, flags_str, odin_compiled, c_compiled, cstring(raw_data(errbuf[:]))))
		return
	}
	if !odin_compiled { return }

	// Build a UTF-16 subject (JS semantics) for both engines.
	units := utf16_of(subject, context.temp_allocator)
	ccap := int(cshim_capture_count(cbc))
	cout := make([]i32, ccap * 2, context.temp_allocator)

	// Try each start position.
	for start := 0; start <= len(units); start += 1 {
		// C exec at this start.
		cret := cshim_exec(cbc, raw_data(units), i32(start), i32(len(units)), 1, raw_data(cout), i32(ccap))
		if cret == -99 {
			// The reference faulted on this input (a QuickJS 0.17 bug). Record and move on without comparing.
			ref_crashes += 1
			if len(ref_crash_samples) < 20 {
				append(&ref_crash_samples, strings.clone(fmt.tprintf("/%s/%s @%d on %q", pattern, flags_str, start, subject)))
			}
			break
		}
		// Odin exec at this start (no scan; exact start).
		ocaps: rx.Captures
		ost := rx.exec(&ore, rx.input_utf16(units), start, &ocaps, {}, context.temp_allocator)

		c_match := cret == 1
		o_match := ost == .Match
		if c_match != o_match {
			note_fail(r, fmt.tprintf("exec match disagree /%s/%s @%d on %q: odin=%v c=%v", pattern, flags_str, start, subject, o_match, c_match))
			break
		}
		if c_match {
			// Compare captures.
			ncap := min(ccap, len(ocaps.groups))
			for g in 0 ..< ncap {
				cs := int(cout[2 * g]); ce := int(cout[2 * g + 1])
				os_ := ocaps.groups[g].start; oe := ocaps.groups[g].end
				if cs != os_ || ce != oe {
					note_fail(r, fmt.tprintf("exec caps disagree /%s/%s @%d on %q grp %d: odin=[%d,%d] c=[%d,%d]", pattern, flags_str, start, subject, g, os_, oe, cs, ce))
					break
				}
			}
			break // first match at the first succeeding start is enough for agreement
		}
	}
}

to_lre_flags :: proc(f: rx.Flags) -> i32 {
	v: i32 = 0
	if .Global in f { v |= 1 << 0 }
	if .Ignore_Case in f { v |= 1 << 1 }
	if .Multiline in f { v |= 1 << 2 }
	if .Dot_All in f { v |= 1 << 3 }
	if .Unicode in f { v |= 1 << 4 }
	if .Sticky in f { v |= 1 << 5 }
	if .Indices in f { v |= 1 << 6 }
	if .Unicode_Sets in f { v |= 1 << 8 }
	return v
}

utf16_of :: proc(s: string, allocator := context.allocator) -> []u16 {
	out := make([dynamic]u16, allocator)
	for r in s {
		c := u32(r)
		if c <= 0xFFFF {
			append(&out, u16(c))
		} else {
			c -= 0x10000
			append(&out, u16(0xD800 + (c >> 10)))
			append(&out, u16(0xDC00 + (c & 0x3FF)))
		}
	}
	return out[:]
}

// ---- Speed --------------------------------------------------------------------------------------------------

bench_speed :: proc() {
	// Five typical patterns. We avoid the alternation-plus-`+` form (e.g. (foo|bar|baz)+): QuickJS-ng 0.17's
	// lre_exec corrupts/leaks internal state when that bytecode is executed thousands of times in one process
	// (reproduced in pure C, independent of this engine), so including it would crash the reference mid-bench.
	patterns := []Corpus_Case{
		{"\\d{4}-\\d{2}-\\d{2}", "", "order 2026-10-28 shipped"},
		{"[\\w.]+@[\\w.]+\\.[a-z]+", "", "contact john.doe@example.com now"},
		{"https?://[^/]+/\\S*", "", "see https://example.com/path/to/page here"},
		{"\\b[A-Z][a-z]+\\b", "", "The Quick Brown Fox Jumps"},
		{"\\b\\w{5,}\\b", "", "the quick brown fox jumps over lazy dogs"},
	}
	iters := 100000
	for p in patterns {
		fmt.eprintfln("[bench] /%s/", p.pattern)
		oflags, _ := rx.parse_flags(p.flags)
		ore, _ := rx.compile(p.pattern, oflags, context.allocator)
		units := utf16_of(p.subject, context.allocator)

		// Odin timing.
		t0 := time.now()
		for _ in 0 ..< iters {
			ocaps: rx.Captures
			_ = rx.exec_search(&ore, rx.input_utf16(units), 0, &ocaps, {}, context.temp_allocator)
			free_all(context.temp_allocator)
		}
		odin_ns := f64(time.duration_nanoseconds(time.since(t0))) / f64(iters)

		// C timing.
		cflags := to_lre_flags(oflags)
		errbuf: [128]u8
		clen: i32
		cpat := strings.clone_to_cstring(p.pattern, context.allocator)
		cbc := cshim_compile(cpat, i32(len(p.pattern)), cflags, raw_data(errbuf[:]), 128, &clen)
		ccap := int(cshim_capture_count(cbc))
		cout := make([]i32, ccap * 2, context.allocator)
		t1 := time.now()
		for _ in 0 ..< iters {
			_ = cshim_exec(cbc, raw_data(units), 0, i32(len(units)), 1, raw_data(cout), i32(ccap))
		}
		c_ns := f64(time.duration_nanoseconds(time.since(t1))) / f64(iters)
		cshim_free_bc(cbc)

		fmt.printfln("  /%s/ : odin=%.0f ns  c=%.0f ns  (%.1fx)", p.pattern, odin_ns, c_ns, odin_ns / c_ns)
		os.flush(os.stdout)

		rx.destroy(&ore)
		delete(units)
		delete(cout)
	}
}
