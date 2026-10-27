package a11y

import "core:fmt"
import "core:testing"
import "toolkit:platform"
import "wb:base"
import "wb:dom"
import "wb:html"

// Incremental updates: after each change, the patch applied to what an adapter holds gives the same tree as a whole
// one (live_verify), every node it sends is reached from the root, and it sends few nodes.

@(private = "file")
Inc :: struct {
	doc:    ^dom.Document,
	live:   Live,
	out:    platform.A11y_Update,
	held:   map[u64][]u64,   // what an adapter holds: node -> children
	focus:  base.Handle,
	title:  string,
}

@(private = "file")
inc_open :: proc(f: ^Inc, src: string) {
	f.doc = dom.document_create()
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 100_000)
	dom.journal_enable(f.doc, 4096)
	f.live.hashes = true
	f.title = "T"
	whole := inc_update(f)
	assert(whole)
}

@(private = "file")
inc_close :: proc(f: ^Inc) {
	for _, k in f.held { delete(k) }
	delete(f.held)
	live_destroy(&f.live)
	platform.a11y_update_destroy(&f.out)
	dom.document_destroy(f.doc)
	free_all(context.temp_allocator)
}

@(private = "file")
inc_view :: proc(f: ^Inc) -> View {
	return View{src = {doc = f.doc}, title = f.title, url = "http://test/", focus = f.focus}
}

// Updates, applies the result to `held` as an adapter would (refusing what it would refuse), returns whether it was a
// whole tree.
@(private = "file")
inc_update :: proc(f: ^Inc) -> bool {
	v := inc_view(f)
	whole := live_update(&f.live, &v, &f.out)
	u := &f.out
	if whole {
		for _, k in f.held { delete(k) }
		clear(&f.held)
	}
	in_update := make(map[u64]bool, len(u.nodes), context.temp_allocator)
	for n in u.nodes {
		assert(n.id not_in in_update, "a node twice in one update")
		in_update[n.id] = true
	}
	reached := make(map[u64]bool, 64, context.temp_allocator)
	for i in 0 ..< len(u.nodes) {
		for c in platform.a11y_node_children(u, i) {
			assert(c in f.held || c in in_update, "a child that is nowhere")
			reached[c] = true
		}
	}
	for n in u.nodes {
		if n.id != u.root && n.id not_in f.held && n.id not_in reached {
			fmt.eprintfln("orphan node %x", n.id)
			assert(false, "a new node no parent reaches")
		}
	}
	for i in 0 ..< len(u.nodes) {
		id := u.nodes[i].id
		if old, ok := f.held[id]; ok { delete(old) }
		kids := platform.a11y_node_children(u, i)
		c := make([]u64, len(kids))
		copy(c, kids)
		f.held[id] = c
	}
	// what the root no longer reaches goes
	keep := make(map[u64]bool, len(f.held), context.temp_allocator)
	stack := make([dynamic]u64, context.temp_allocator)
	append(&stack, u.root)
	for len(stack) > 0 {
		id := pop(&stack)
		if keep[id] { continue }
		keep[id] = true
		if k, ok := f.held[id]; ok { append(&stack, ..k) }
	}
	gone := make([dynamic]u64, context.temp_allocator)
	for id in f.held { if !keep[id] { append(&gone, id) } }
	for id in gone { delete(f.held[id]); delete_key(&f.held, id) }
	return whole
}

@(private = "file")
inc_check :: proc(t: ^testing.T, f: ^Inc, what: string, max_nodes := 8, loc := #caller_location) {
	whole := inc_update(f)
	testing.expectf(t, !whole, "%s: a patch (fell back: %s)", what, f.live.fallback, loc = loc)
	v := inc_view(f)
	diff := live_verify(&f.live, &v)
	testing.expectf(t, diff == "", "%s: the patch differs from a whole tree: %s", what, diff, loc = loc)
	testing.expectf(t, len(f.held) == len(f.live.recs), "%s: the adapter holds %d nodes, the records %d", what, len(f.held), len(f.live.recs), loc = loc)
	testing.expectf(t, len(f.out.nodes) <= max_nodes, "%s: %d nodes sent", what, len(f.out.nodes), loc = loc)
}

@(private = "file")
by_id :: proc(f: ^Inc, id: string) -> base.Handle { return dom.find_by_id(f.doc, id) }

@(test)
patches_follow_mutations :: proc(t: ^testing.T) {
	f: Inc
	inc_open(&f, SAMPLE)
	defer inc_close(&f)
	whole := len(f.live.recs)
	testing.expect(t, whole > 50, "the sample has a tree")

	// nothing changed: nothing sent
	inc_check(t, &f, "no change", max_nodes = 0)

	// text of a heading: its text node, the heading (named by its content), what is named by it
	h1 := by_id(&f, "title")
	dom.set_text_content(f.doc, h1, "Renamed")
	inc_check(t, &f, "heading text")

	// an attribute: a button's label
	dom.set_attribute(f.doc, by_id(&f, "save"), "aria-label", "Store")
	inc_check(t, &f, "aria-label")

	// a node inserted in a list: the item, the list, the other items (their place in the set)
	menu := by_id(&f, "menu")
	li := dom.create_element(f.doc, "li")
	dom.append_child(f.doc, li, dom.create_text(f.doc, "Fourth"))
	dom.append_child(f.doc, menu, li)
	inc_check(t, &f, "list item inserted")
	dom.remove_child(f.doc, menu, li)
	inc_check(t, &f, "list item removed")

	// a role-less wrapper of new nodes inserted at the top of the body: the root's children, not a whole tree
	body := dom.get(f.doc, by_id(&f, "top")).parent
	wrap := dom.create_element(f.doc, "div")
	b := dom.create_element(f.doc, "button")
	dom.append_child(f.doc, b, dom.create_text(f.doc, "Toast"))
	dom.append_child(f.doc, wrap, b)
	dom.append_child(f.doc, body, wrap)
	inc_check(t, &f, "toast inserted", max_nodes = 6)
	dom.remove_child(f.doc, body, wrap)
	inc_check(t, &f, "toast removed")

	// aria-hidden hides a subtree; taking it away brings it back
	nav := by_id(&f, "nav")
	dom.set_attribute(f.doc, nav, "aria-hidden", "true")
	inc_check(t, &f, "aria-hidden set")
	dom.remove_attribute(f.doc, nav, "aria-hidden")
	inc_check(t, &f, "aria-hidden removed", max_nodes = 32)

	// a role changed
	dom.set_attribute(f.doc, by_id(&f, "intro"), "role", "note")
	inc_check(t, &f, "role changed")

	// an element pointed at by aria-labelledby / -describedby changes: the elements that point at it
	lab := dom.create_element(f.doc, "span")
	dom.set_attribute(f.doc, lab, "id", "ext-label")
	dom.append_child(f.doc, lab, dom.create_text(f.doc, "External"))
	dom.append_child(f.doc, body, lab)
	b2 := dom.create_element(f.doc, "button")
	dom.set_attribute(f.doc, b2, "aria-labelledby", "ext-label")
	dom.append_child(f.doc, body, b2)
	inc_check(t, &f, "labelled button inserted")
	dom.set_text_content(f.doc, lab, "Changed label")
	inc_check(t, &f, "the label of a labelledby changed")
	dom.remove_child(f.doc, body, lab)
	inc_check(t, &f, "the label of a labelledby removed")

	// a <label for> changes: the control it names
	name_label := dom.create_element(f.doc, "label")
	dom.set_attribute(f.doc, name_label, "for", "email")
	dom.append_child(f.doc, name_label, dom.create_text(f.doc, "Mail"))
	dom.append_child(f.doc, body, name_label)
	inc_check(t, &f, "a label for a field inserted")
	dom.set_text_content(f.doc, name_label, "Courriel")
	inc_check(t, &f, "the label's text changed")
	dom.remove_child(f.doc, body, name_label)
	inc_check(t, &f, "the label removed")

	// a table row inserted: the rows after it, the table's counts
	rows := 0
	for cur := dom.next_in_tree(f.doc, f.doc.root, f.doc.root); cur != base.NIL_HANDLE; cur = dom.next_in_tree(f.doc, cur, f.doc.root) {
		n := dom.get(f.doc, cur)
		if n.kind == .Element && n.name == "tbody" {
			tr := dom.create_element(f.doc, "tr")
			for _ in 0 ..< 2 {
				td := dom.create_element(f.doc, "td")
				dom.append_child(f.doc, td, dom.create_text(f.doc, "x"))
				dom.append_child(f.doc, tr, td)
			}
			dom.insert_before(f.doc, cur, tr, n.first_child)
			rows += 1
			break
		}
	}
	testing.expect(t, rows == 1, "the sample has a tbody")
	inc_check(t, &f, "table row inserted", max_nodes = 40)

	// the title and the focus
	f.title = "Other title"
	inc_check(t, &f, "title", max_nodes = 1)
	f.focus = by_id(&f, "name")
	inc_check(t, &f, "focus", max_nodes = 0)
	testing.expect(t, f.out.focus == u64(f.focus), "the focus is on the field")

	// a listener makes an element clickable
	p := by_id(&f, "intro")
	_, _ = dom.add_listener(f.doc, p, "click", 1, 0, false, false, false)
	inc_check(t, &f, "click listener")

	testing.expect(t, f.live.full_builds == 1, "one whole tree only")
}

@(test)
patches_survive_many_random_changes :: proc(t: ^testing.T) {
	f: Inc
	inc_open(&f, SAMPLE)
	defer inc_close(&f)
	// a deterministic sequence of edits all over the document, each checked against a whole tree
	els := make([dynamic]base.Handle, context.temp_allocator)
	for cur := dom.next_in_tree(f.doc, f.doc.root, f.doc.root); cur != base.NIL_HANDLE; cur = dom.next_in_tree(f.doc, cur, f.doc.root) {
		if n := dom.get(f.doc, cur); n.kind == .Element && n.name != "html" && n.name != "head" && n.name != "body" { append(&els, cur) }
	}
	seed: u32 = 12345
	rnd :: proc(s: ^u32, n: int) -> int { s^ = s^ * 1103515245 + 12345; return int((s^ >> 8) % u32(max(n, 1))) }
	attrs := [?]string{"aria-label", "aria-hidden", "role", "title", "hidden", "aria-expanded", "aria-checked", "tabindex"}
	values := [?]string{"x", "true", "button", "false", "list", "listitem", "none", "0"}
	for step in 0 ..< 60 {
		el := els[rnd(&seed, len(els))]
		if dom.get(f.doc, el) == nil || !connected(f.doc, el) { continue }
		switch rnd(&seed, 4) {
		case 0: dom.set_attribute(f.doc, el, attrs[rnd(&seed, len(attrs))], values[rnd(&seed, len(values))])
		case 1: dom.remove_attribute(f.doc, el, attrs[rnd(&seed, len(attrs))])
		case 2:
			c := dom.create_element(f.doc, rnd(&seed, 2) == 0 ? "span" : "button")
			dom.append_child(f.doc, c, dom.create_text(f.doc, "n"))
			dom.append_child(f.doc, el, c)
		case 3:
			if n := dom.get(f.doc, el); n.first_child != base.NIL_HANDLE { dom.remove_child(f.doc, el, n.first_child) }
		}
		inc_check(t, &f, fmt.tprintf("step %d", step), max_nodes = 1 << 20)
		if testing.failed(t) { break }
	}
}
