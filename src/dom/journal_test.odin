package dom

import "core:testing"

@(test)
journal_records_mutations :: proc(t: ^testing.T) {
	d := document_create(nil)
	defer document_destroy(d)
	a := create_element(d, "div")
	append_child(d, d.root, a)
	_, ok := journal_since(d, 0)
	testing.expect(t, !ok, "off until a reader turns it on")
	testing.expect(t, len(d.journal.entries) == 0, "nothing recorded while off")

	journal_enable(d, 64)
	start := d.mutations
	b := create_element(d, "p")
	append_child(d, a, b)
	txt := create_text(d, "x")
	append_child(d, b, txt)
	set_text_content(d, txt, "y")
	set_attribute(d, b, "Class", "k")
	remove_attribute(d, b, "class")
	remove_child(d, a, b)
	es, ok2 := journal_since(d, start)
	testing.expect(t, ok2)
	kinds := [?]Journal_Kind{.Insert, .Insert, .Text, .Attribute, .Attribute, .Remove}
	testing.expect_value(t, len(es), len(kinds))
	if len(es) == len(kinds) {
		for k, i in kinds { testing.expect(t, es[i].kind == k) }
		testing.expect(t, es[0].node == b && es[0].parent == a)
		testing.expect(t, es[2].node == txt && es[2].parent == b)
		testing.expect(t, es[3].name == "class", "attribute names lower case")
		testing.expect(t, es[5].node == b && es[5].parent == a)
		for i in 1 ..< len(es) { testing.expect(t, es[i].mutation > es[i - 1].mutation) }
		testing.expect(t, es[len(es) - 1].mutation == d.mutations)
	}
	// a reader that caught up sees only what comes after
	mid := es[2].mutation
	later, ok3 := journal_since(d, mid)
	testing.expect(t, ok3 && len(later) == 3)
	release(d, b)
}

@(test)
journal_is_bounded :: proc(t: ^testing.T) {
	d := document_create(nil)
	defer document_destroy(d)
	journal_enable(d, 16)
	start := d.mutations
	e := create_element(d, "div")
	append_child(d, d.root, e)
	for i in 0 ..< 100 { set_attribute(d, e, "data-n", i % 2 == 0 ? "a" : "b") }
	testing.expect(t, len(d.journal.entries) <= 16, "older half forgotten past the bound")
	_, ok := journal_since(d, start)
	testing.expect(t, !ok, "a reader older than what is kept must start over")
	es, ok2 := journal_since(d, d.mutations - 3)
	testing.expect(t, ok2 && len(es) == 3, "a recent reader still reads")
	journal_disable(d)
	_, ok4 := journal_since(d, d.mutations)
	testing.expect(t, !ok4)
}
