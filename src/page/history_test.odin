package page

import "core:fmt"
import "core:testing"

@(private = "file")
urls_of :: proc(sh: ^Session_History) -> string {
	s := ""
	for e, i in sh.entries { s = fmt.tprintf("%s%s%s%s", s, i > 0 ? " " : "", i == sh.index ? "*" : "", e.url) }
	return s
}

// Back then elsewhere: the old forward entries become a branch; the web sees the active path only.
@(test)
history_tree_branches :: proc(t: ^testing.T) {
	sh: Session_History
	defer session_destroy(&sh)
	session_push(&sh, "a", 1)
	session_push(&sh, "b", 2)
	session_push(&sh, "c", 3)
	testing.expect_value(t, urls_of(&sh), "a b *c")
	session_go(&sh, -2)
	testing.expect_value(t, urls_of(&sh), "*a b c")
	session_push(&sh, "x", 4)
	testing.expect_value(t, urls_of(&sh), "a *x")
	testing.expect_value(t, sh.count, 4)   // b and c kept
	a := sh.entries[0]
	testing.expect_value(t, len(a.children), 2)
	testing.expect_value(t, session_active_child(a).url, "x")
	// back to a: forward is x (the branch visited last)
	session_go(&sh, -1)
	testing.expect_value(t, urls_of(&sh), "*a x")
	// the tree view goes to c: the path to it is active again, x a branch
	c: ^History_Entry
	for e in session_flatten(&sh) { if e.url == "c" { c = e } }
	testing.expect(t, c != nil)
	session_goto(&sh, c)
	testing.expect_value(t, urls_of(&sh), "a b *c")
	testing.expect_value(t, session_length(&sh), 3)
	d, ok := session_delta_of(&sh, sh.entries[0])
	testing.expect(t, ok && d == -2)
	// go(n) across: from a, go(2) reaches c through b
	session_go(&sh, -2)
	e, gok := session_go(&sh, 2)
	testing.expect(t, gok && e.url == "c")
	_, gok = session_go(&sh, 1)
	testing.expect(t, !gok)
}

@(test)
history_tree_push_state_and_replace :: proc(t: ^testing.T) {
	sh: Session_History
	defer session_destroy(&sh)
	session_push(&sh, "https://a/", 7)
	session_push(&sh, "https://a/#1", 7, "s1", true, dedupe = false)
	session_push(&sh, "https://a/#1", 7, "s2", true, dedupe = false)   // pushState with the same URL is a new entry
	testing.expect_value(t, session_length(&sh), 3)
	session_replace(&sh, "https://a/#r", "rs", true)
	cur := session_current(&sh)
	testing.expect(t, cur.url == "https://a/#r" && cur.state == "rs" && cur.doc == 7)
	testing.expect_value(t, session_length(&sh), 3)
	// dropping the current leaf (a navigation that turned into a download)
	session_drop_current(&sh)
	testing.expect_value(t, session_current(&sh).url, "https://a/#1")
	testing.expect_value(t, session_length(&sh), 2)
}

// The web's window and the tree's size limit.
@(test)
history_tree_limits :: proc(t: ^testing.T) {
	sh: Session_History
	defer session_destroy(&sh)
	session_set_limits(&sh, 3, 5)
	for i in 0 ..< 4 { session_push(&sh, fmt.tprintf("p%d", i), 1, max_entries = 3) }
	testing.expect_value(t, urls_of(&sh), "p1 p2 *p3")   // p0 hidden from the web, kept in the tree
	testing.expect_value(t, sh.count, 4)
	session_go(&sh, -2)
	testing.expect_value(t, urls_of(&sh), "*p1 p2 p3")
	session_push(&sh, "q", 1, max_entries = 3)   // p2, p3 a branch
	session_push(&sh, "r", 1, max_entries = 3)
	testing.expect(t, sh.count <= 5)
	testing.expect_value(t, session_current(&sh).url, "r")
	// the leaf off the path visited least recently went: p3
	for e in session_flatten(&sh) { testing.expect(t, e.url != "p3") }
}

@(test)
history_tree_load :: proc(t: ^testing.T) {
	sh: Session_History
	defer session_destroy(&sh)
	saved := []Saved_Entry{
		{id = 1, url = "a", seq = 1},
		{id = 2, parent = 1, url = "b", seq = 5},
		{id = 3, parent = 1, url = "c", seq = 9, scroll = {0, 120}},
		{id = 3, parent = 1, url = "dup"},          // repeated id: skipped
		{id = 4, parent = 99, url = "orphan", seq = 2},   // unknown parent: top level
	}
	session_load(&sh, saved, 2, 50, 100)
	testing.expect_value(t, sh.count, 4)
	testing.expect_value(t, urls_of(&sh), "a *b")   // the current one's path is active, whatever the saved seq
	c := session_find(&sh, 3)
	testing.expect(t, c != nil && c.persisted.saved && c.persisted.scroll.y == 120)
	session_push(&sh, "new", 0)
	testing.expect_value(t, session_current(&sh).id, 5)   // ids go on after the loaded ones
}
