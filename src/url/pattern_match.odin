package url

// URLPattern — compiling a component's part list to a matcher and running it (URL Pattern Standard §1.4/§1.5,
// "generate a regular expression and name list" and "perform a match"). Rather than build an ECMAScript RegExp (Wren
// has no JS regexp in the host), a Compiled_Component holds the part list and, for each custom "regexp" part, a
// compiled Regexp (pattern_regexp.odin). Matching is a whole-string, backtracking walk over the parts that produces
// the per-group captures in the same order the specification's name list and RegExpBuiltinExec would. All matching is
// code-point based.

import "core:strings"
import "core:unicode/utf8"

Compiled_Component :: struct {
	pattern:         string,          // owned: the normalized pattern string (the component getter returns it)
	parts:           []Part,          // owned
	regexps:         []Regexp,        // one per part; valid only for Regexp parts
	group_names:     []string,        // owned: names in order (the name list)
	has_regexp_groups: bool,
	ignore_case:     bool,
	delimiter:       string,          // owned (one code point or "")
}

component_destroy :: proc(c: ^Compiled_Component) {
	delete(c.pattern)
	part_list_destroy(c.parts)
	for &rx in c.regexps { regexp_destroy(&rx) }
	delete(c.regexps)
	for n in c.group_names { delete(n) }
	delete(c.group_names)
	delete(c.delimiter)
	c^ = {}
}

// §1.5 "compile a component": parse the pattern, compile the custom regexps (failing here mirrors RegExpCreate
// throwing), and record the group names. ok=false is a TypeError upstream.
compile_component :: proc(input: string, encoding: Encoding, delimiter, prefix_cp: string, ignore_case: bool, allocator := context.allocator) -> (cc: Compiled_Component, ok: bool) {
	parts, pok := parse_pattern(input, encoding, delimiter, prefix_cp, allocator)
	if !pok { return {}, false }
	regexps := make([]Regexp, len(parts), allocator)
	names := make([dynamic]string, allocator)
	has_rx_groups := false
	for p, i in parts {
		if p.kind == .Regexp {
			has_rx_groups = true
			rx, rok := regexp_compile(p.value, ignore_case, allocator)
			if !rok {
				for j in 0 ..< i { regexp_destroy(&regexps[j]) }
				delete(regexps)
				for n in names { delete(n) }
				delete(names)
				part_list_destroy(parts)
				return {}, false
			}
			regexps[i] = rx
		}
		if p.kind != .Fixed_Text { append(&names, strings.clone(p.name, allocator)) }
	}
	pattern := generate_pattern_string(parts, delimiter, prefix_cp, allocator)
	return Compiled_Component{
		pattern = pattern, parts = parts, regexps = regexps,
		group_names = names[:], has_regexp_groups = has_rx_groups,
		ignore_case = ignore_case, delimiter = strings.clone(delimiter, allocator),
	}, true
}

// One captured group of a component match: the group name (not owned; points into group_names) and its value, or
// absent (an optional group that did not participate). Values are slices of the matched input.
Group_Capture :: struct {
	name:    string,
	value:   string,
	present: bool,
}

// §1.4 RegExpBuiltinExec, directly against the part list. Returns whether the whole input matched and, if so, the
// captures in group-name order (allocated with `allocator`). The capture values are cloned from `input`.
component_exec :: proc(cc: ^Compiled_Component, input: string, allocator := context.allocator) -> (captures: []Group_Capture, matched: bool) {
	runes := utf8.string_to_runes(input, context.temp_allocator)
	caps := make([]Match_Cap, len(cc.group_names), context.temp_allocator)
	m := Matcher{cc = cc, input = runes, caps = caps}
	if !match_parts(&m, 0, 0) { return nil, false }
	out := make([]Group_Capture, len(cc.group_names), allocator)
	for i in 0 ..< len(cc.group_names) {
		out[i].name = cc.group_names[i]
		if caps[i].present {
			out[i].present = true
			out[i].value = strings.clone(runes_to_string(runes[caps[i].lo:caps[i].hi], context.temp_allocator), allocator)
		}
	}
	return out, true
}

// Whether the whole input matches (test()): avoids allocating captures.
component_test :: proc(cc: ^Compiled_Component, input: string) -> bool {
	runes := utf8.string_to_runes(input, context.temp_allocator)
	caps := make([]Match_Cap, len(cc.group_names), context.temp_allocator)
	m := Matcher{cc = cc, input = runes, caps = caps}
	return match_parts(&m, 0, 0)
}

@(private = "file")
Match_Cap :: struct { lo, hi: int, present: bool }

@(private = "file")
Matcher :: struct {
	cc:    ^Compiled_Component,
	input: []rune,
	caps:  []Match_Cap,
	steps: int,
}

@(private = "file")
MATCH_BUDGET :: 2_000_000

// Matches parts[pi..] against input[sp..], anchored to the end. group_index tracks the position in group_names (one
// per non-fixed part, in order). Backtracking: wildcards and modifiers try alternatives.
@(private = "file")
match_parts :: proc(m: ^Matcher, pi, sp: int) -> bool {
	if pi == len(m.cc.parts) { return sp == len(m.input) }
	m.steps += 1
	if m.steps > MATCH_BUDGET { return false }
	part := m.cc.parts[pi]
	gi := group_index_of(m.cc, pi)

	if part.kind == .Fixed_Text {
		switch part.modifier {
		case .None:
			np, ok := match_literal(m, sp, part.value)
			if !ok { return false }
			return match_parts(m, pi + 1, np)
		case .Optional:
			// zero or one occurrence (greedy: try one first)
			if np, ok := match_literal(m, sp, part.value); ok {
				if match_parts(m, pi + 1, np) { return true }
			}
			return match_parts(m, pi + 1, sp)
		case .Zero_Or_More, .One_Or_More:
			return match_fixed_repeat(m, pi, sp, part)
		}
		return false
	}

	// a matching-group part: prefix, the group body (one unit), suffix, under the modifier
	return match_group_part(m, pi, sp, part, gi)
}

@(private = "file")
group_index_of :: proc(cc: ^Compiled_Component, pi: int) -> int {
	gi := 0
	for i in 0 ..< pi { if cc.parts[i].kind != .Fixed_Text { gi += 1 } }
	return gi
}

@(private = "file")
match_literal :: proc(m: ^Matcher, sp: int, text: string) -> (int, bool) {
	np := sp
	for r in text {
		if np >= len(m.input) { return sp, false }
		a := m.input[np]
		if a == r { np += 1; continue }
		if m.cc.ignore_case && fold(a) == fold(r) { np += 1; continue }
		return sp, false
	}
	return np, true
}

@(private = "file")
fold :: proc(r: rune) -> rune { return (r >= 'A' && r <= 'Z') ? r + 32 : r }

@(private = "file")
match_fixed_repeat :: proc(m: ^Matcher, pi, sp: int, part: Part) -> bool {
	// greedy: consume as many copies as possible, then backtrack
	positions := make([dynamic]int, context.temp_allocator)
	append(&positions, sp)
	cur := sp
	for {
		np, ok := match_literal(m, cur, part.value)
		if !ok || np == cur { break }
		cur = np
		append(&positions, cur)
	}
	min_count := part.modifier == .One_Or_More ? 1 : 0
	for idx := len(positions) - 1; idx >= min_count; idx -= 1 {
		if match_parts(m, pi + 1, positions[idx]) { return true }
	}
	return false
}

// A single matching-group occurrence consumes prefix + (segment/full/regexp body) + suffix. Modifiers wrap the whole
// unit. Captures record the body only (the specification captures the group, not the prefix/suffix).
@(private = "file")
match_group_part :: proc(m: ^Matcher, pi, sp: int, part: Part, gi: int) -> bool {
	switch part.modifier {
	case .None:
		return match_group_once(m, pi, sp, part, gi, true)
	case .Optional:
		if match_group_once(m, pi, sp, part, gi, true) { return true }
		// did not participate
		if gi >= 0 && gi < len(m.caps) { m.caps[gi].present = false }
		return match_parts(m, pi + 1, sp)
	case .Zero_Or_More, .One_Or_More:
		return match_group_repeat(m, pi, sp, part, gi)
	}
	return false
}

// Try to match exactly one occurrence here (prefix+body+suffix) and continue; records the capture for the body.
@(private = "file")
match_group_once :: proc(m: ^Matcher, pi, sp: int, part: Part, gi: int, continue_after: bool) -> bool {
	after_prefix, ok := match_literal(m, sp, part.prefix)
	if !ok { return false }
	// the body can match several lengths; try them (greedy longest first for full-wildcard, shortest-first for
	// segment is achieved by the regexp being lazy — but here we enumerate and let continuation decide)
	return match_body(m, pi, after_prefix, part, gi, continue_after)
}

// Enumerate possible body spans [after_prefix, end], require the suffix, then continue to the next part.
@(private = "file")
match_body :: proc(m: ^Matcher, pi, after_prefix: int, part: Part, gi: int, continue_after: bool) -> bool {
	delim_rune := rune(-1)
	if part.kind == .Segment_Wildcard && len(m.cc.delimiter) > 0 {
		delim_rune = utf8.rune_at_pos(m.cc.delimiter, 0)
	}
	n := len(m.input)
	// candidate end positions. For a regexp body, test the regexp on each span. For segment/full wildcard, the body
	// is any run (segment stops at a delimiter). We try longer spans first (greedy), matching ECMAScript's default.
	// We must also respect the minimum: segment/full/regexp require at least one code point? Segment and full
	// wildcard use "+?"/".*" so full allows empty, segment requires >=1. Regexp depends on its own source.
	min_len := part.kind == .Segment_Wildcard ? 1 : 0
	max_end := n
	if part.kind == .Segment_Wildcard && delim_rune >= 0 {
		// stop at first delimiter
		e := after_prefix
		for e < n && m.input[e] != delim_rune { e += 1 }
		max_end = e
	}
	// greedy: longest body first
	for end := max_end; end >= after_prefix + min_len; end -= 1 {
		body := m.input[after_prefix:end]
		if part.kind == .Regexp {
			if !regexp_full_match(&m.cc.regexps[pi], body, m.cc.ignore_case) { continue }
		}
		after_suffix, ok := match_literal(m, end, part.suffix)
		if !ok { continue }
		// record capture
		if gi >= 0 && gi < len(m.caps) { m.caps[gi] = Match_Cap{lo = after_prefix, hi = end, present = true} }
		if !continue_after { return true }
		if match_parts(m, pi + 1, after_suffix) { return true }
	}
	return false
}

// Repeating group (zero/one-or-more): each repetition is prefix+body+suffix; the capture holds the LAST body matched
// (as RegExpBuiltinExec would for a repeated capture group). Greedy.
@(private = "file")
match_group_repeat :: proc(m: ^Matcher, pi, sp: int, part: Part, gi: int) -> bool {
	min_count := part.modifier == .One_Or_More ? 1 : 0
	return repeat_take(m, pi, sp, 0, min_count, part, gi)
}

// Greedy recursion: try taking one more occurrence first, else stop and continue past the part.
@(private = "file")
repeat_take :: proc(m: ^Matcher, pi, sp, count, min_count: int, part: Part, gi: int) -> bool {
	m.steps += 1
	if m.steps > MATCH_BUDGET { return false }
	after_prefix, ok := match_literal(m, sp, part.prefix)
	if ok {
		delim_rune := rune(-1)
		if part.kind == .Segment_Wildcard && len(m.cc.delimiter) > 0 { delim_rune = utf8.rune_at_pos(m.cc.delimiter, 0) }
		n := len(m.input)
		min_len := part.kind == .Segment_Wildcard ? 1 : 0
		max_end := n
		if part.kind == .Segment_Wildcard && delim_rune >= 0 {
			e := after_prefix
			for e < n && m.input[e] != delim_rune { e += 1 }
			max_end = e
		}
		for end := max_end; end >= after_prefix + min_len; end -= 1 {
			body := m.input[after_prefix:end]
			if part.kind == .Regexp { if !regexp_full_match(&m.cc.regexps[pi], body, m.cc.ignore_case) { continue } }
			after_suffix, sok := match_literal(m, end, part.suffix)
			if !sok { continue }
			if after_suffix == sp { continue }   // guard against empty-progress loops
			saved := gi >= 0 && gi < len(m.caps) ? m.caps[gi] : Match_Cap{}
			if gi >= 0 && gi < len(m.caps) { m.caps[gi] = Match_Cap{lo = after_prefix, hi = end, present = true} }
			if repeat_take(m, pi, after_suffix, count + 1, min_count, part, gi) { return true }
			if gi >= 0 && gi < len(m.caps) { m.caps[gi] = saved }
		}
	}
	if count < min_count { return false }
	return match_parts(m, pi + 1, sp)
}

@(private = "file")
runes_to_string :: proc(rs: []rune, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for r in rs { strings.write_rune(&b, r) }
	return strings.to_string(b)
}
