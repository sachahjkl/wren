package style

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:html"

// The matching of a chain (match.odin): the three-state answers against the backtracking matcher they replace, the step budget,
// :has() bounded by its anchor; and what the restyle keeps between passes (hints, var() texts, class words, key sets).

@(private = "file")
DEEP :: 200

@(private = "file")
sel :: proc(text: string) -> css.Selector_List {
	opt := css.Parse_Options{max_nesting_depth = 64, max_rules = 100, max_errors_kept = 0}
	vs := css.parse_component_values(text, opt, context.temp_allocator)
	list, ok := css.parse_selector_list(css.trim_values(vs), context.temp_allocator, nil)
	assert(ok, text)
	return list
}

@(private = "file")
doc_of :: proc(src: string) -> ^dom.Document {
	doc := dom.document_create(nil)
	html.parse_into(doc, doc.root, transmute([]byte)src, 2_000_000)
	return doc
}

// The matcher before the three-state answers: every ancestor and sibling tried again for each choice below it (the reference).
@(private = "file")
ref_chain :: proc(m: ^Match_Ctx, el: base.Handle, c: ^css.Complex, idx: int) -> bool {
	if !matches_compound(m, el, c.compounds[idx]) { return false }
	if idx == 0 { return true }
	switch c.combinators[idx - 1] {
	case .Child:
		p := parent_for_match(m, el)
		return p != base.NIL_HANDLE && ref_chain(m, p, c, idx - 1)
	case .Descendant:
		for p := parent_for_match(m, el); p != base.NIL_HANDLE; p = parent_for_match(m, p) { if ref_chain(m, p, c, idx - 1) { return true } }
		return false
	case .Next_Sibling:
		p := prev_element(m, el)
		return p != base.NIL_HANDLE && ref_chain(m, p, c, idx - 1)
	case .Subsequent_Sibling:
		for p := prev_element(m, el); p != base.NIL_HANDLE; p = prev_element(m, p) { if ref_chain(m, p, c, idx - 1) { return true } }
		return false
	}
	return false
}

@(private = "file")
elements_of :: proc(doc: ^dom.Document) -> []base.Handle {
	out := make([dynamic]base.Handle, context.temp_allocator)
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, doc.root)
	for len(stack) > 0 {
		h := pop(&stack)
		n := dom.get(doc, h)
		if n.kind == .Element { append(&out, h) }
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
	}
	return out[:]
}

// A document of a few hundred elements, nested and side by side, with classes drawn from a fixed sequence.
@(private = "file")
mixed_doc :: proc() -> string {
	CLASSES :: [?]string{"a", "b", "c", "a b", "b c", ""}
	sb := strings.builder_make(context.temp_allocator)
	seed := u32(12345)
	next :: proc(s: ^u32) -> u32 { s^ = s^ * 1103515245 + 12345; return (s^ >> 16) & 0x7fff }
	depth := 0
	for _ in 0 ..< 400 {
		r := next(&seed) % 4
		if r == 0 && depth > 0 { strings.write_string(&sb, "</div>"); depth -= 1; continue }
		classes := CLASSES
		cls := classes[next(&seed) % len(classes)]
		if r == 1 { fmt.sbprintf(&sb, `<p class="%s"></p>`, cls) } else { fmt.sbprintf(&sb, `<div class="%s">`, cls); depth += 1 }
	}
	for ; depth > 0; depth -= 1 { strings.write_string(&sb, "</div>") }
	return strings.to_string(sb)
}

// The design's day-one test: on every element of a mixed tree, every chain answers as the backtracking matcher does.
@(test)
chain_matches_as_backtracking_does :: proc(t: ^testing.T) {
	doc := doc_of(mixed_doc())
	defer dom.document_destroy(doc)
	m: Match_Ctx
	match_ctx_init(&m, doc, {}, context.temp_allocator)
	SELECTORS :: [?]string{
		".a .b .c", ".a > .b .c", ".a ~ .b > .c", ".b + .a .c", ".a .a .a .b", "div.a > p.b", ".c ~ .c ~ .a", ".a .b + .c ~ div",
		":is(.a, .c) .b > :not(.a)", ".a > .a > .a", "p + p ~ .c", ".b .c + p", "div > div > div .a ~ p",
	}
	matched := 0
	for text in SELECTORS {
		list := sel(text)
		for el in elements_of(doc) {
			for &c in list {
				want := ref_chain(&m, el, &c, len(c.compounds) - 1)
				got := matches_complex(&m, el, &c)
				if want { matched += 1 }
				testing.expectf(t, got == want, "%q on element %v: %v, backtracking %v", text, el, got, want)
			}
		}
	}
	testing.expect(t, matched > 0, "some selectors match (the tree is not trivial)")
}

// A chain of descendant compounds on a deep element costs the depth times the compounds, and the step budget stops the rest.
@(test)
chain_steps_are_bounded :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<div class=top>`)
	for _ in 0 ..< DEEP { strings.write_string(&sb, `<div class=x>`) }
	strings.write_string(&sb, `<i id=t class=d></i>`)
	doc := doc_of(strings.to_string(sb))
	defer dom.document_destroy(doc)
	m: Match_Ctx
	match_ctx_init(&m, doc, {}, context.temp_allocator)
	el := dom.find_by_id(doc, "t")
	Case :: struct { text: string, want: bool }
	for c in ([?]Case{
		{".a .b .c .d", false}, {".x .x .x .d", true}, {".top .x .d", true}, {".x > .x > .d", true},
		{".top > .x .d", true}, {".x + .d", false}, {".top > .d", false}, {".top .zz .x .d", false},
	}) {
		testing.expectf(t, matches_list(&m, el, sel(c.text)) == c.want, "%q", c.text)
		testing.expectf(t, m.steps <= 4 * (DEEP + 4), "%q took %d steps", c.text, m.steps)
	}
	m.max_steps = 50
	testing.expect(t, !matches_list(&m, el, sel(".top .x .d")), "past the budget: no match")
	m.max_steps = MATCH_MAX_STEPS_DEFAULT
	testing.expect(t, matches_list(&m, el, sel(".top .x .d")), "within it: the match")
}

// :has() led by a child or descendant combinator looks under its anchor only: what is above the anchor never takes part.
@(test)
has_stays_under_its_anchor :: proc(t: ^testing.T) {
	doc := doc_of(`<section class=s><div id=o class=o><div class=a><p class=b></p></div><p class=a></p><p class=b></p></div><div class=a></div></section>`)
	defer dom.document_destroy(doc)
	m: Match_Ctx
	match_ctx_init(&m, doc, {}, context.temp_allocator)
	o := dom.find_by_id(doc, "o")
	Case :: struct { text: string, want: bool }
	for c in ([?]Case{
		{"#o:has(.a .b)", true}, {"#o:has(> .b)", true}, {"#o:has(> .a > .b)", true}, {"#o:has(.o .b)", false},
		{"#o:has(.s .b)", false}, {"#o:has(+ .a)", true}, {"#o:has(~ .a)", true}, {"#o:has(.a ~ .b)", true}, {"#o:has(> .b ~ .a)", false},
	}) {
		testing.expectf(t, matches_list(&m, o, sel(c.text)) == c.want, "%q", c.text)
	}
}

// Cells with the same presentational hints get one compiled rule, and share their computed style; an element with none gets no text.
@(test)
hints_compiled_once_and_shared :: proc(t: ^testing.T) {
	f := fixture_load(`<!doctype html><table><tr><td align=center id=c1>x</td><td align=center id=c2>y</td><td align=left id=c3>z</td></tr></table><div id=plain>w</div>`)
	defer fixture_unload(f)
	c1, c2, c3 := style_of(f.st, dom.find_by_id(f.doc, "c1")), style_of(f.st, dom.find_by_id(f.doc, "c2")), style_of(f.st, dom.find_by_id(f.doc, "c3"))
	testing.expect(t, c1 != nil && c1 == c2, "the same hints: one record")
	testing.expect(t, c3 != c1, "other hints: another record")
	testing.expect(t, "text-align:-webkit-center;" in f.st.hint_rules, "kept by text")
	plain := dom.find_by_id(f.doc, "plain")
	testing.expect_value(t, hint_text(f.doc, plain, dom.get(f.doc, plain)), "")
}

// var() reads its texts from the pass's table: the styles are those of a parse at every var(), the table dropped at every text too.
@(test)
var_parsed_texts_change_nothing :: proc(t: ^testing.T) {
	SRC :: `<!doctype html><html style="--w: 10px; --c: rgb(1, 2, 3)"><body><div id=a style="width: var(--w); color: var(--c)"></div><div id=b style="height: calc(var(--w) * 2); border: 1px solid var(--c)"></div><p id=c style="--w: 3em; width: var(--w)"></p>`
	s := settings_default()
	defer settings_destroy(&s)
	kept := fixture_load(SRC)
	defer fixture_unload(kept)
	s.var_parsed_bytes = 0
	plain := fixture_load(SRC, {set = &s})
	defer fixture_unload(plain)
	s.var_parsed_bytes = 1
	dropped := fixture_load(SRC, {set = &s})
	defer fixture_unload(dropped)
	for id in ([?]string{"a", "b", "c"}) {
		k := style_of(kept.st, dom.find_by_id(kept.doc, id))
		testing.expectf(t, computed_equal(k, style_of(plain.st, dom.find_by_id(plain.doc, id))), "#%s as parsed at every var()", id)
		testing.expectf(t, computed_equal(k, style_of(dropped.st, dom.find_by_id(dropped.doc, id))), "#%s with the table dropped", id)
	}
}

// A partial restyle clears the class words of what its journal names only, and its styles are those of a full pass.
@(test)
class_words_follow_the_journal :: proc(t: ^testing.T) {
	f := fixture_load(`<!doctype html><style>.on .t { color: rgb(255, 0, 0) } .t.k { color: rgb(0, 0, 255) }</style><div id=w><p id=p class=t>x</p></div><div class=on><p class=t>y</p></div>`, {partial = true})
	defer fixture_unload(f)
	w, p := dom.find_by_id(f.doc, "w"), dom.find_by_id(f.doc, "p")
	steps := [?]struct { el: base.Handle, class: string } {{w, "on"}, {p, "t k"}, {w, ""}, {p, "t"}}
	for step in steps {
		dom.set_attribute(f.doc, step.el, "class", step.class)
		_, ok := restyle_dom(f.eng, f.doc, f.st)
		testing.expect(t, ok, "partial")
		testing.expect(t, f.eng.class_bits_doc == f.doc && f.eng.class_bits_at == f.doc.mutations, "the words are of the document as it is")
		testing.expect_value(t, verify_styles(f.eng, f.doc, f.st, context.temp_allocator), "")
	}
	// a subtree inserted (its nodes may take the slots of others): read again
	div := dom.create_element(f.doc, "div")
	dom.set_attribute(f.doc, div, "class", "on")
	q := dom.create_element(f.doc, "p")
	dom.set_attribute(f.doc, q, "class", "t")
	dom.append_child(f.doc, div, q)
	dom.append_child(f.doc, dom.find_first_by_tag(f.doc, "body"), div)
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	testing.expect(t, ok, "partial")
	testing.expect_value(t, style_of(f.st, q).color, css.Color{1, 0, 0, 1})
	testing.expect_value(t, verify_styles(f.eng, f.doc, f.st, context.temp_allocator), "")
}

// Past their bound the key sets go at the next rebuild, and the invalidation index is made again with the new numbers.
@(test)
key_sets_dropped_past_their_bound :: proc(t: ^testing.T) {
	f := fixture_load(`<!doctype html><style>.a .x { color: red } .a .y { color: blue }</style><p class=a>`)
	defer fixture_unload(f)
	ix := inv_index(f.eng)
	gen := f.eng.key_sets.gen
	testing.expect(t, ix.keys_gen == gen && len(f.eng.key_sets.sets) > 0, "made")
	engine_rebuild(f.eng, f.doc)
	testing.expect_value(t, f.eng.key_sets.gen, gen)   // (within the bound: kept)
	f.eng.settings.key_sets_max_bytes = 0
	engine_rebuild(f.eng, f.doc)
	testing.expect_value(t, f.eng.key_sets.gen, gen + 1)
	ix = inv_index(f.eng)
	testing.expect(t, ix.keys_gen == gen + 1 && len(f.eng.key_sets.sets) > 0, "made again with new sets")
}

// Every serial is new (one atomic counter for every site).
@(test)
styled_serials_are_new :: proc(t: ^testing.T) {
	a := styled_next_serial()
	b := styled_next_serial()
	testing.expect(t, b > a, "increasing")
}
