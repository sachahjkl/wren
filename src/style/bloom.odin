package style

import "wb:css"
import "wb:dom"

// Ancestor filter. While the tree is walked, every element adds the hashes of its tag, id and classes to a small Bloom
// filter that its descendants inherit. A rule whose selector needs `.sec`, `article` or `#nav` on an ancestor is rejected
// when the filter says that name is not on the way up, before any ancestor is visited. A false positive only costs the
// normal check; there are no false negatives, so results are exactly those of plain matching.

Bloom :: [4]u64   // 256 bits, two bits per hash

SALT_TAG   :: 0x9e3779b1
SALT_ID    :: 0x85ebca6b
SALT_CLASS :: 0xc2b2ae35

hash_name :: proc(s: string, salt: u32) -> u32 {
	h := u32(2166136261) ~ salt
	for i in 0 ..< len(s) { h = (h ~ u32(s[i])) * 16777619 }
	return h ~ (h >> 15)
}

bloom_add :: #force_inline proc(b: ^Bloom, h: u32) {
	i, j := h & 255, (h >> 8) & 255
	b[i >> 6] |= u64(1) << (i & 63)
	b[j >> 6] |= u64(1) << (j & 63)
}

bloom_has :: #force_inline proc(b: ^Bloom, h: u32) -> bool {
	i, j := h & 255, (h >> 8) & 255
	return (b[i >> 6] >> (i & 63)) & (b[j >> 6] >> (j & 63)) & 1 == 1
}

bloom_add_element :: proc(b: ^Bloom, n: ^dom.Node) {
	bloom_add(b, hash_name(n.name, SALT_TAG))
	if id, ok := attr(n, "id"); ok && id != "" { bloom_add(b, hash_name(id, SALT_ID)) }
	if cls, ok := attr(n, "class"); ok {
		rest := cls
		for len(rest) > 0 {
			for len(rest) > 0 && is_space(rest[0]) { rest = rest[1:] }
			end := 0
			for end < len(rest) && !is_space(rest[end]) { end += 1 }
			if end > 0 { bloom_add(b, hash_name(rest[:end], SALT_CLASS)) }
			rest = rest[end:]
		}
	}
}

// Hashes of what ancestors must have, taken from the compounds reachable from the subject through child and descendant
// combinators only (past a sibling combinator the relation to the subject's ancestors is no longer direct).
compute_ancestor_hashes :: proc(ent: ^Entry) {
	c := ent.complex
	if c.relative || len(c.compounds) < 2 { return }
	idx := len(c.compounds) - 2
	for idx >= 0 && ent.n_anc < 4 {
		comb := c.combinators[idx]
		if comb != .Child && comb != .Descendant { break }
		for s in c.compounds[idx].simples {
			if ent.n_anc >= 4 { break }
			h: u32
			#partial switch s.kind {
			case .Id: h = hash_name(s.name, SALT_ID)
			case .Class: h = hash_name(s.name, SALT_CLASS)
			case .Type: h = hash_name(s.name, SALT_TAG)
			case: continue
			}
			ent.anc[ent.n_anc] = h
			ent.n_anc += 1
		}
		idx -= 1
	}
}

////////////////////////////////
// Which dynamic state a selector depends on

compound_state :: proc(comp: css.Compound, depth := 0) -> (kinds: State_Kinds, uses_has: bool) {
	for s in comp.simples {
		#partial switch s.kind {
		case .Pseudo_Class:
			#partial switch s.pseudo {
			case .Hover: kinds += {.Hover}
			case .Active: kinds += {.Active}
			case .Focus, .Focus_Visible, .Focus_Within: kinds += {.Focus}
			case .Target: kinds += {.Target}
			case .Not, .Is, .Where, .Nth_Child, .Nth_Last_Child, .Host, .Host_Context:
				if s.list != nil && depth < 8 {
					k, h := list_state(s.list^, depth + 1)
					kinds += k
					uses_has ||= h
				}
			case .Has:
				if s.list != nil && depth < 8 {
					k, _ := list_state(s.list^, depth + 1)
					if k != {} { kinds += k; uses_has = true }
				}
			}
		case .Nesting:
			if s.list != nil && depth < 8 {
				k, h := list_state(s.list^, depth + 1)
				kinds += k
				uses_has ||= h
			}
		}
	}
	return
}

list_state :: proc(list: css.Selector_List, depth := 0) -> (kinds: State_Kinds, uses_has: bool) {
	for &c in list {
		k, h := complex_state_depth(&c, depth)
		kinds += k
		uses_has ||= h
	}
	return
}

@(private)
complex_state_depth :: proc(c: ^css.Complex, depth: int) -> (kinds: State_Kinds, uses_has: bool) {
	for comp in c.compounds {
		k, h := compound_state(comp, depth)
		kinds += k
		uses_has ||= h
	}
	return
}

complex_state :: proc(c: ^css.Complex) -> (kinds: State_Kinds, uses_has: bool) { return complex_state_depth(c, 0) }
