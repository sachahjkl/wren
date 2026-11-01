package dom

import "core:testing"
import "wb:base"

// A node's handle names its document: given to another document it resolves to nothing, whatever the slot there holds.
@(test)
a_handle_of_another_document_resolves_to_nothing :: proc(t: ^testing.T) {
	a := document_create()
	defer document_destroy(a)
	b := document_create()
	defer document_destroy(b)
	testing.expect(t, a.tag != b.tag && a.tag != 0 && b.tag != 0)
	ea := create_element(a, "div")
	eb := create_element(b, "div")
	testing.expect_value(t, base.handle_index(ea), base.handle_index(eb))   // same slot, same generation of the slot
	testing.expect_value(t, base.handle_tag(u64(ea)), a.tag)
	testing.expect(t, get(a, ea) != nil)
	testing.expect(t, get(b, ea) == nil, "a's handle must not resolve in b")
	testing.expect(t, get(a, eb) == nil, "b's handle must not resolve in a")
	testing.expect_value(t, append_child(b, b.root, ea), Error.Invalid_Handle)
}

// A slot reused until its generation is exhausted is retired: its last handle stays dead for good, and the tag is intact.
@(test)
a_slot_at_its_last_generation_is_retired :: proc(t: ^testing.T) {
	d := document_create()
	defer document_destroy(d)
	first := create_element(d, "p")
	last := first
	for {
		index := base.handle_index(last)
		if base.handle_gen(last) & base.HANDLE_GEN_MASK == base.HANDLE_GEN_MASK { break }
		destroy_unpinned(d, last)
		last = create_element(d, "p")
		testing.expect_value(t, base.handle_index(last), index)
		testing.expect_value(t, base.handle_tag(u64(last)), d.tag)
	}
	index := base.handle_index(last)
	destroy_unpinned(d, last)
	next := create_element(d, "p")
	testing.expect(t, base.handle_index(next) != index, "the slot must not be reused")
	testing.expect_value(t, base.handle_tag(u64(next)), d.tag)
	testing.expect(t, get(d, last) == nil)
	testing.expect(t, get(d, first) == nil)
}

// The document made to replace another (parsed off the thread) keeps its tag.
@(test)
a_document_may_be_given_its_tag :: proc(t: ^testing.T) {
	a := document_create()
	defer document_destroy(a)
	b := document_create(nil, a.tag)
	defer document_destroy(b)
	testing.expect_value(t, b.tag, a.tag)
	testing.expect_value(t, base.handle_tag(u64(b.root)), a.tag)
}

// copy_across gives a node of another document its name, namespace, attributes, text and template contents.
@(test)
a_node_copied_across_documents :: proc(t: ^testing.T) {
	a := document_create()
	defer document_destroy(a)
	b := document_create()
	defer document_destroy(b)
	el := create_element(a, "section")
	set_attribute(a, el, "id", "s")
	c := copy_across(a, b, el)
	testing.expect_value(t, base.handle_tag(u64(c)), b.tag)
	testing.expect_value(t, get(b, c).name, "section")
	v, ok := get_attribute(b, c, "id")
	testing.expect(t, ok && v == "s")
	txt := copy_across(a, b, create_text(a, "hello"))
	testing.expect_value(t, get(b, txt).text, "hello")
	testing.expect_value(t, copy_across(a, b, a.root), base.NIL_HANDLE)
}
