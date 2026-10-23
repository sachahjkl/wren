package adblock

import "core:bytes"

// Matching of ABP patterns: literals, `*` (anything), `^` (a separator or the end of the URL), `|` / `||` anchors.
// A pattern is a sequence of segments separated by `*`. Each segment has a fixed width, so the leftmost occurrence of
// each one, in order, finds a match whenever one exists: no backtracking, O(url x pattern) at worst.

// Matches one segment at exactly `pos`; returns where it ends.
@(private)
seg_at :: #force_inline proc "contextless" (seg, url: string, pos: int) -> (end: int, ok: bool) {
	p := pos
	n := len(url)
	for i in 0 ..< len(seg) {
		c := seg[i]
		if c == '^' {
			if p >= n { return p, i == len(seg) - 1 }   // the end of the URL, zero width, only as the last character
			if !is_separator(url[p]) { return 0, false }
			p += 1
		} else {
			if p >= n || url[p] != c { return 0, false }
			p += 1
		}
	}
	return p, true
}

// The leftmost match of `seg` starting at or after `from` (and ending at the end of the URL when `to_end`).
@(private)
seg_find :: proc "contextless" (seg, url: string, from: int, to_end: bool) -> (end: int, ok: bool) {
	n := len(url)
	if len(seg) == 0 { return to_end ? n : from, true }
	start := from
	if to_end {
		// the segment must end at n: it can only start in the last len(seg) positions
		start = max(from, n - len(seg))
	}
	if seg[0] != '^' {
		c := seg[0]
		for start <= n {
			rest := url[start:]
			j := bytes.index_byte(transmute([]byte)rest, c)
			if j < 0 { return 0, false }
			p := start + j
			e, m := seg_at(seg, url, p)
			if m && (!to_end || e == n) { return e, true }
			start = p + 1
		}
		return 0, false
	}
	for p := start; p <= n; p += 1 {
		e, m := seg_at(seg, url, p)
		if m && (!to_end || e == n) { return e, true }
	}
	return 0, false
}

// Does the pattern match the URL? `hs, he`: the host part of the URL (for `||`).
pattern_match :: proc "contextless" (pat: string, flags: Filter_Flags, url: string, hs, he: int) -> bool {
	n := len(url)
	if len(pat) == 0 { return true }
	right := .Right_Anchor in flags
	pos := 0
	seg_start := 0
	first := true
	for {
		seg_end := seg_start
		for seg_end < len(pat) && pat[seg_end] != '*' { seg_end += 1 }
		seg := pat[seg_start:seg_end]
		last := seg_end >= len(pat)
		to_end := last && right
		end: int
		ok: bool
		if first {
			switch {
			case .Host_Anchor in flags:
				if he <= hs { return false }
				p := hs
				for {
					e, m := seg_at(seg, url, p)
					if m && (!to_end || e == n) { end, ok = e, true; break }
					// next label start inside the host
					q := p
					for q < he && url[q] != '.' { q += 1 }
					if q >= he { break }
					p = q + 1
				}
			case .Left_Anchor in flags:
				e, m := seg_at(seg, url, 0)
				if m && (!to_end || e == n) { end, ok = e, true }
			case:
				end, ok = seg_find(seg, url, 0, to_end)
			}
			first = false
		} else {
			end, ok = seg_find(seg, url, pos, to_end)
		}
		if !ok { return false }
		pos = end
		if last { return true }
		seg_start = seg_end + 1
	}
}
