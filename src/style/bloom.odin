package style

import "core:slice"
import "wb:base"
import "wb:css"
import "wb:dom"

// The ancestor hashes an Entry keeps (Entry.anc), and how deep inside selector lists they are looked for.
BLOOM_ENTRY_ANCESTORS :: 4
BLOOM_MAX_LIST_DEPTH :: 8

// Ancestor filter. While the tree is walked, every element adds the hashes of its tag, id and classes to a small Bloom
// filter that its descendants inherit. A rule whose selector needs `.sec`, `article` or `#nav` on an ancestor is rejected
// when the filter says that name is not on the way up, before any ancestor is visited. A false positive only costs the
// normal check; there are no false negatives, so results are exactly those of plain matching.

Bloom :: [4]u64   // 256 bits, two bits per hash

CLASS_BIT_MASK :: 63   // Match_Ctx.class_bits: the bit of a class hash in a u64
CLASS_BITS_READ :: u64(1) << CLASS_BIT_MASK   // ... the element's classes are in its word (a class of this bit is then only looked at by name, as any false hit is)

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

// The classes of every element of `doc`, for a full pass (Match_Ctx.class_bits): a bit per class, from its hash.
class_bits_fill :: proc(e: ^Engine, doc: ^dom.Document) {
	class_bits_reset(e, doc)
	it: u32
	for h, n in base.pool_next(&doc.nodes, &it) {
		if n.kind != .Element { continue }
		e.class_bits[base.handle_index(h)] = class_bits_of(n)
	}
}

// Every word read again (0: not read).
@(private = "file")
class_bits_reset :: proc(e: ^Engine, doc: ^dom.Document) {
	resize(&e.class_bits, int(doc.nodes.used))
	slice.zero(e.class_bits[:])
	e.class_bits_doc, e.class_bits_at = doc, doc.mutations   // (the document does not change while a pass reads it)
	e.class_bits_live = true
}

// For a partial pass: the elements' classes are read as they are met, ancestors above all (matches_simple). A rule of `.a .b` is tried
// on the ancestors of `.b`, and class attributes read again and again were a quarter of what a restyle cost on cnn.com. The words
// read by the pass before, which covered the document up to `since`, stay, but for the elements `entries` (the journal since
// then) name: a class attribute set, or inserted with what they hold (a node in a slot freed by another). Clearing every word made
// a restyle of one element cost a pass over the whole document's nodes.
@(private)
class_bits_begin :: proc(e: ^Engine, doc: ^dom.Document, since: u64, entries: []dom.Journal_Entry) {
	if e.class_bits_doc != doc || e.class_bits_at != since || len(e.class_bits) == 0 {
		class_bits_reset(e, doc)
		return
	}
	old := len(e.class_bits)
	resize(&e.class_bits, int(doc.nodes.used))
	if len(e.class_bits) > old { slice.zero(e.class_bits[old:]) }
	stack := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
	for &en in entries {
		#partial switch en.kind {
		case .Attribute:
			if en.name == "class" { class_bits_drop(e, en.node) }
		case .Insert:
			clear(&stack)
			append(&stack, en.node)
			for len(stack) > 0 {
				h := pop(&stack)
				n := dom.get(doc, h)
				if n == nil { continue }
				class_bits_drop(e, h)
				for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
			}
		}
	}
	e.class_bits_doc, e.class_bits_at = doc, doc.mutations
	e.class_bits_live = true
}

// For a pass that reads no journal (an @media block that flipped, a sheet that came): the words stay if the document did not change
// since they were read, else every word is read again.
@(private)
class_bits_resume :: proc(e: ^Engine, doc: ^dom.Document) {
	class_bits_begin(e, doc, doc.mutations, nil)
}

@(private = "file")
class_bits_drop :: #force_inline proc(e: ^Engine, h: base.Handle) {
	if i := int(base.handle_index(h)); i < len(e.class_bits) { e.class_bits[i] = 0 }
}

// The bits of the classes of `n`; never 0.
@(private)
class_bits_of :: proc(n: ^dom.Node) -> u64 {
	bits := CLASS_BITS_READ
	rest, _ := attr(n, "class")
	for c in token_next(&rest) { bits |= 1 << (css.class_hash(c) & CLASS_BIT_MASK) }
	return bits
}

bloom_add_element :: proc(b: ^Bloom, n: ^dom.Node) {
	bloom_add(b, hash_name(n.name, SALT_TAG))
	if id, ok := attr(n, "id"); ok && id != "" { bloom_add(b, hash_name(id, SALT_ID)) }
	if cls, ok := attr(n, "class"); ok {
		rest := cls
		for c in token_next(&rest) { bloom_add(b, hash_name(c, SALT_CLASS)) }
	}
}

// Hashes of what ancestors must have, taken from the compounds reachable from the subject through child and descendant
// combinators only (past a sibling combinator the relation to the subject's ancestors is no longer direct).
compute_ancestor_hashes :: proc(ent: ^Entry) {
	c := ent.complex
	if c.relative || len(c.compounds) < 2 { return }
	idx := len(c.compounds) - 2
	for idx >= 0 && ent.n_anc < BLOOM_ENTRY_ANCESTORS {
		comb := c.combinators[idx]
		if comb != .Child && comb != .Descendant { break }
		for s in c.compounds[idx].simples {
			if ent.n_anc >= BLOOM_ENTRY_ANCESTORS { break }
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
			case .Fullscreen: kinds += {.Fullscreen}
			case .Visited, .Link, .Any_Link: kinds += {.Visited}
			case .Not, .Is, .Where, .Nth_Child, .Nth_Last_Child, .Host, .Host_Context:
				if s.list != nil && depth < BLOOM_MAX_LIST_DEPTH {
					k, h := list_state(s.list^, depth + 1)
					kinds += k
					uses_has ||= h
				}
			case .Has:
				if s.list != nil && depth < BLOOM_MAX_LIST_DEPTH {
					k, _ := list_state(s.list^, depth + 1)
					if k != {} { kinds += k; uses_has = true }
				}
			}
		case .Nesting:
			if s.list != nil && depth < BLOOM_MAX_LIST_DEPTH {
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
