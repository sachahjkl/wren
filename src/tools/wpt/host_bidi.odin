package wpt

import "core:unicode/utf8"

// The Unicode Bidirectional Algorithm for the layout of reference tests (Text_Api.bidi): the runner has no text backend. UAX #9: explicit
// levels and directional runs (X1-X8), weak types (W1-W7), neutrals (N1-N2), implicit levels (I1-I2), on a table of character classes
// enough for tests: Hebrew and Arabic letters, digits, the explicit controls, marks; no bracket pairs (N0), which their test pages do not need.

@(private = "file") BIDI_MAX_DEPTH :: 125

@(private = "file")
Bidi_Class :: enum u8 { L, R, AL, EN, AN, ES, ET, CS, NSM, BN, B, S, WS, ON, LRE, RLE, LRO, RLO, PDF, LRI, RLI, FSI, PDI }

@(private = "file")
bidi_class :: proc(r: rune) -> Bidi_Class {
	switch r {
	case 0x202A: return .LRE
	case 0x202B: return .RLE
	case 0x202C: return .PDF
	case 0x202D: return .LRO
	case 0x202E: return .RLO
	case 0x2066: return .LRI
	case 0x2067: return .RLI
	case 0x2068: return .FSI
	case 0x2069: return .PDI
	case 0x200E: return .L
	case 0x200F: return .R
	case 0x061C: return .AL
	case 0x200B, 0x200C, 0x200D, 0xFEFF: return .BN
	case '\n', '\r', 0x2029: return .B
	case '\t': return .S
	case ' ', 0x2000 ..= 0x200A, 0x3000: return .WS
	case '+', '-': return .ES
	case '#', '$', '%', 0xA2, 0xA3, 0xA4, 0xA5, 0xB0, 0xB1: return .ET
	case ',', '.', '/', ':', 0xA0: return .CS
	case '0' ..= '9': return .EN
	}
	switch {
	case r >= 0x0590 && r <= 0x05FF:
		if r >= 0x0591 && r <= 0x05BD { return .NSM }
		return .R
	case r >= 0x07C0 && r <= 0x085F, r >= 0xFB1D && r <= 0xFB4F: return .R
	case r >= 0x0660 && r <= 0x0669: return .AN
	case r >= 0x064B && r <= 0x065F, r >= 0x0300 && r <= 0x036F: return .NSM
	case r >= 0x0600 && r <= 0x07BF, r >= 0xFB50 && r <= 0xFDFF, r >= 0xFE70 && r <= 0xFEFF: return .AL
	case r < 0x41, r > 0x5A && r < 0x61, r > 0x7A && r < 0xAA, r >= 0x2010 && r <= 0x2BFF: return .ON
	}
	return .L
}

@(private = "file")
Bidi_Entry :: struct { level: u8, override: i8, isolate: bool }   // override: 0 none, 1 L, -1 R

// `levels`: per byte of `text`.
host_bidi :: proc(user: rawptr, text: string, rtl: bool, levels: []u8) {
	n := utf8.rune_count_in_string(text)
	if n == 0 { return }
	runes := make([]rune, n, context.temp_allocator)
	starts := make([]int, n + 1, context.temp_allocator)
	types := make([]Bidi_Class, n, context.temp_allocator)
	lv := make([]u8, n, context.temp_allocator)
	{
		i := 0
		for r, at in text {
			runes[i], starts[i], types[i] = r, at, bidi_class(r)
			i += 1
		}
		starts[n] = len(text)
	}
	base := u8(rtl ? 1 : 0)
	orig := make([]Bidi_Class, n, context.temp_allocator)
	copy(orig, types)
	// X1-X8
	stack := make([dynamic]Bidi_Entry, 0, 16, context.temp_allocator)
	append(&stack, Bidi_Entry{level = base})
	over_isolate, over_embed, valid_isolate := 0, 0, 0
	next_odd :: proc(l: u8) -> u8 { return (l + 1) | 1 }
	next_even :: proc(l: u8) -> u8 { return (l + 2) &~ 1 }
	for i in 0 ..< n {
		top := stack[len(stack) - 1]
		c := orig[i]
		#partial switch c {
		case .LRE, .RLE, .LRO, .RLO, .LRI, .RLI, .FSI:
			isolate := c == .LRI || c == .RLI || c == .FSI
			want_r := c == .RLE || c == .RLO || c == .RLI
			if c == .FSI {
				// the first strong character inside
				depth := 0
				for k in i + 1 ..< n {
					o := orig[k]
					if o == .LRI || o == .RLI || o == .FSI { depth += 1 } else if o == .PDI { if depth == 0 { break }; depth -= 1 }
					if depth == 0 && (o == .L || o == .R || o == .AL) { want_r = o != .L; break }
				}
			}
			lv[i] = top.level
			if isolate && top.override != 0 { types[i] = top.override > 0 ? .L : .R }
			nl := want_r ? next_odd(top.level) : next_even(top.level)
			if nl <= BIDI_MAX_DEPTH && over_isolate == 0 && over_embed == 0 {
				ov: i8 = c == .LRO ? 1 : (c == .RLO ? -1 : 0)
				append(&stack, Bidi_Entry{level = nl, override = ov, isolate = isolate})
				if isolate { valid_isolate += 1 }
			} else if isolate { over_isolate += 1 } else if over_isolate == 0 { over_embed += 1 }
		case .PDI:
			if over_isolate > 0 {
				over_isolate -= 1
			} else if valid_isolate > 0 {
				over_embed = 0
				for !stack[len(stack) - 1].isolate { pop(&stack) }
				pop(&stack)
				valid_isolate -= 1
			}
			top = stack[len(stack) - 1]
			lv[i] = top.level
			if top.override != 0 { types[i] = top.override > 0 ? .L : .R }
		case .PDF:
			if over_isolate == 0 {
				if over_embed > 0 { over_embed -= 1 } else if !top.isolate && len(stack) >= 2 { pop(&stack) }
			}
			lv[i] = stack[len(stack) - 1].level
		case .BN, .B:
			lv[i] = top.level
		case:
			lv[i] = top.level
			if top.override != 0 { types[i] = top.override > 0 ? .L : .R }
		}
	}
	// the level runs, in order: controls that X9 removes take the level of what comes before, and do not break a run
	removed :: proc(c: Bidi_Class) -> bool { #partial switch c { case .LRE, .RLE, .LRO, .RLO, .PDF, .BN: return true }; return false }
	start := 0
	for start < n {
		end := start
		for end < n && (lv[end] == lv[start] || removed(orig[end])) { end += 1 }
		prev_lv := base
		for k := start - 1; k >= 0; k -= 1 { if !removed(orig[k]) { prev_lv = lv[k]; break } }
		next_lv := base
		for k := end; k < n; k += 1 { if !removed(orig[k]) { next_lv = lv[k]; break } }
		sos := (max(prev_lv, lv[start]) & 1) == 1 ? Bidi_Class.R : Bidi_Class.L
		eos := (max(next_lv, lv[start]) & 1) == 1 ? Bidi_Class.R : Bidi_Class.L
		bidi_run(types[start:end], orig[start:end], lv[start:end], sos, eos)
		start = end
	}
	// L1: separators and trailing white space at the paragraph level (the paragraph is one line here: its layout splits it later)
	for i := n - 1; i >= 0; i -= 1 {
		#partial switch orig[i] {
		case .WS, .S, .B, .LRI, .RLI, .FSI, .PDI, .LRE, .RLE, .LRO, .RLO, .PDF, .BN: lv[i] = base; continue
		}
		break
	}
	for i in 0 ..< n {
		for b in starts[i] ..< starts[i + 1] { if b < len(levels) { levels[b] = lv[i] } }
	}
}

// W1-W7, N1-N2, I1-I2 on a level run.
@(private = "file")
bidi_run :: proc(t, orig: []Bidi_Class, lv: []u8, sos, eos: Bidi_Class) {
	n := len(t)
	level := lv[0]
	removed :: proc(c: Bidi_Class) -> bool { #partial switch c { case .LRE, .RLE, .LRO, .RLO, .PDF, .BN: return true }; return false }
	// W1
	prev := sos
	for i in 0 ..< n {
		if removed(orig[i]) { continue }
		if t[i] == .NSM {
			t[i] = (prev == .LRI || prev == .RLI || prev == .FSI || prev == .PDI) ? .ON : prev
		}
		prev = t[i]
	}
	// W2, W3
	strong := sos
	for i in 0 ..< n {
		if removed(orig[i]) { continue }
		if t[i] == .EN && strong == .AL { t[i] = .AN }
		if t[i] == .L || t[i] == .R || t[i] == .AL { strong = t[i] }
		if t[i] == .AL { t[i] = .R }
	}
	// W4
	for i in 1 ..< max(n - 1, 1) {
		if t[i] == .ES && t[i - 1] == .EN && t[i + 1] == .EN { t[i] = .EN }
		if t[i] == .CS && t[i - 1] == t[i + 1] && (t[i - 1] == .EN || t[i - 1] == .AN) { t[i] = t[i - 1] }
	}
	// W5, W6
	for i := 0; i < n; i += 1 {
		if t[i] != .ET { continue }
		j := i
		for j < n && t[j] == .ET { j += 1 }
		en := (i > 0 && t[i - 1] == .EN) || (j < n && t[j] == .EN)
		for k in i ..< j { t[k] = en ? .EN : .ON }
		i = j - 1
	}
	for i in 0 ..< n { if t[i] == .ES || t[i] == .CS { t[i] = .ON } }
	// W7
	strong = sos
	for i in 0 ..< n {
		if t[i] == .L || t[i] == .R { strong = t[i] }
		if t[i] == .EN && strong == .L { t[i] = .L }
	}
	// N1, N2
	neutral :: proc(c: Bidi_Class) -> bool {
		#partial switch c { case .B, .S, .WS, .ON, .LRI, .RLI, .FSI, .PDI: return true }
		return false
	}
	embedding := level & 1 == 1 ? Bidi_Class.R : Bidi_Class.L
	for i := 0; i < n; i += 1 {
		if !neutral(t[i]) && !removed(orig[i]) { continue }
		j := i
		for j < n && (neutral(t[j]) || removed(orig[j])) { j += 1 }
		side :: proc(c: Bidi_Class) -> Bidi_Class { return c == .L ? .L : .R }
		before := i > 0 ? side(t[i - 1]) : side(sos)
		after := j < n ? side(t[j]) : side(eos)
		fill := before == after ? before : embedding
		for k in i ..< j { t[k] = fill }
		i = j - 1
	}
	// I1, I2
	for i in 0 ..< n {
		if level & 1 == 0 {
			if t[i] == .R { lv[i] = level + 1 } else if t[i] == .AN || t[i] == .EN { lv[i] = level + 2 }
		} else if t[i] != .R {
			lv[i] = level + 1
		}
	}
}
