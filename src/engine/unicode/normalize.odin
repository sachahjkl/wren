package ucd

// Unicode normalization: NFD, NFC, NFKD, NFKC. The algorithm is the standard one (recursive canonical/compat
// decomposition, canonical ordering by combining class, then canonical composition for the C forms), driven by
// the generated decomp/combining/compose tables plus the algorithmic Hangul rules. Output is a freshly allocated
// []u32 of code points on the caller's allocator.

Normal_Form :: enum u8 { NFC, NFD, NFKC, NFKD }

// Hangul syllable algorithmic constants (Unicode §3.12).
@(private) HANGUL_SBASE :: 0xAC00
@(private) HANGUL_LBASE :: 0x1100
@(private) HANGUL_VBASE :: 0x1161
@(private) HANGUL_TBASE :: 0x11A7
@(private) HANGUL_LCOUNT :: 19
@(private) HANGUL_VCOUNT :: 21
@(private) HANGUL_TCOUNT :: 28
@(private) HANGUL_NCOUNT :: HANGUL_VCOUNT * HANGUL_TCOUNT // 588
@(private) HANGUL_SCOUNT :: HANGUL_LCOUNT * HANGUL_NCOUNT  // 11172

normalize :: proc(src: []u32, form: Normal_Form, allocator := context.allocator) -> []u32 {
	is_compat := form == .NFKC || form == .NFKD
	do_compose := form == .NFC || form == .NFKC

	buf := make([dynamic]u32, 0, len(src) * 2, allocator)
	for c in src {
		decompose_rec(&buf, c, is_compat)
	}
	canonical_order(buf[:])

	if !do_compose {
		return buf[:]
	}
	compose(&buf)
	return buf[:]
}

@(private)
decompose_rec :: proc(buf: ^[dynamic]u32, c: u32, is_compat: bool) {
	// Hangul: algorithmic full canonical decomposition.
	if c >= HANGUL_SBASE && c < HANGUL_SBASE + HANGUL_SCOUNT {
		s := c - HANGUL_SBASE
		append(buf, u32(HANGUL_LBASE + s / HANGUL_NCOUNT))
		append(buf, u32(HANGUL_VBASE + (s % HANGUL_NCOUNT) / HANGUL_TCOUNT))
		t := s % HANGUL_TCOUNT
		if t != 0 { append(buf, u32(HANGUL_TBASE + t)) }
		return
	}
	if mapped, compat, ok := decomp_lookup(c); ok {
		if compat && !is_compat {
			append(buf, c)
			return
		}
		for m in mapped {
			decompose_rec(buf, m, is_compat)
		}
		return
	}
	append(buf, c)
}

@(private)
decomp_lookup :: proc(c: u32) -> (mapped: []u32, compat: bool, ok: bool) {
	lo, hi := 0, len(decomp_table)
	for lo < hi {
		mid := (lo + hi) / 2
		if c < decomp_table[mid].code {
			hi = mid
		} else if c > decomp_table[mid].code {
			lo = mid + 1
		} else {
			return decomp_table[mid].mapped, decomp_table[mid].compat, true
		}
	}
	return nil, false, false
}

// Stable sort of combining marks by canonical combining class (insertion sort keeps it stable).
@(private)
canonical_order :: proc(buf: []u32) {
	n := len(buf)
	for i := 1; i < n; i += 1 {
		cc := combining_class(buf[i])
		if cc == 0 { continue }
		c := buf[i]
		j := i - 1
		for j >= 0 {
			cj := combining_class(buf[j])
			if cj == 0 || cj <= cc { break }
			buf[j + 1] = buf[j]
			j -= 1
		}
		buf[j + 1] = c
	}
}

combining_class :: proc(c: u32) -> u8 {
	lo, hi := 0, len(combining_class_table)
	for lo < hi {
		mid := (lo + hi) / 2
		if c < combining_class_table[mid].lo {
			hi = mid
		} else if c >= combining_class_table[mid].hi {
			lo = mid + 1
		} else {
			return combining_class_table[mid].cc
		}
	}
	return 0
}

@(private)
compose :: proc(buf: ^[dynamic]u32) {
	n := len(buf)
	if n <= 1 { return }
	out := 1
	// starter_pos indexes into `buf` at the current starter being considered for composition.
	starter_pos := 0
	last_cc := i32(-1)
	for i := 1; i < n; i += 1 {
		c := buf[i]
		cc := i32(combining_class(c))
		if starter_pos >= 0 && last_cc < cc {
			if p, ok := compose_pair(buf[starter_pos], c); ok {
				buf[starter_pos] = p
				continue
			}
		}
		if cc == 0 {
			starter_pos = out
			last_cc = -1
		} else {
			last_cc = cc
		}
		buf[out] = c
		out += 1
	}
	resize(buf, out)
}

@(private)
compose_pair :: proc(a, b: u32) -> (u32, bool) {
	// Hangul LV and LVT composition.
	if a >= HANGUL_LBASE && a < HANGUL_LBASE + HANGUL_LCOUNT &&
	   b >= HANGUL_VBASE && b < HANGUL_VBASE + HANGUL_VCOUNT {
		li := a - HANGUL_LBASE
		vi := b - HANGUL_VBASE
		return u32(HANGUL_SBASE + (li * HANGUL_VCOUNT + vi) * HANGUL_TCOUNT), true
	}
	if a >= HANGUL_SBASE && a < HANGUL_SBASE + HANGUL_SCOUNT &&
	   (a - HANGUL_SBASE) % HANGUL_TCOUNT == 0 &&
	   b > HANGUL_TBASE && b < HANGUL_TBASE + HANGUL_TCOUNT {
		return a + (b - HANGUL_TBASE), true
	}
	// Table lookup, sorted by (a, b).
	lo, hi := 0, len(compose_table)
	for lo < hi {
		mid := (lo + hi) / 2
		e := compose_table[mid]
		if a < e.a || (a == e.a && b < e.b) {
			hi = mid
		} else if a > e.a || (a == e.a && b > e.b) {
			lo = mid + 1
		} else {
			return e.result, true
		}
	}
	return 0, false
}
