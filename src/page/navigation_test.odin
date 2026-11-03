package page

import "base:runtime"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"

// A document keeps the encoding it was decoded from: characterSet says it, and the links of the document resolve
// against its base URL with their query in it (HTML "encoding-parse a URL"); a UTF-8 document's stay UTF-8.
@(test)
links_of_a_document_in_a_legacy_encoding :: proc(t: ^testing.T) {
	test_pages(t)
	context.allocator = runtime.heap_allocator()   // the tree builder's Lexbor callbacks use the process heap (offthread_test.odin)
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	loader := fetch.Loader{loop = &loop}
	settings := settings_default()
	defer settings_destroy(&settings)
	settings.threads.parse_html = false
	scope := base.scope_make("test")
	defer base.scope_close(scope)

	p := page_create(&loop, &loader, &settings, scope, "http://example.test/dir/page.html")
	sjis := []byte{'<', 'b', 'a', 's', 'e', ' ', 'h', 'r', 'e', 'f', '=', '/', 'b', '/', '>', '<', 'p', '>', 0x93, 0xFA}
	parse_document(p, sjis, "shift_jis", proc(p: ^Page, user: rawptr, d: ^Parsed_Document) { adopt_document(p, d) }, nil)
	testing.expect_value(t, document_encoding(p), "Shift_JIS")
	u, ok := resolve_link(p, "x?q=日本&k=한#日", p.body)
	testing.expect(t, ok)
	testing.expect_value(t, u.href, "http://example.test/b/x?q=%93%FA%96{&k=%26%2354620%3B#%E6%97%A5")
	// a link of a document of its own (createHTMLDocument's): UTF-8
	own := dom.create_fragment(p.doc)
	dom.get(p.doc, own).as_document = true
	a := dom.create_element(p.doc, "a")
	dom.append_child(p.doc, own, a)
	u, ok = resolve_link(p, "x?q=日", a)
	testing.expect_value(t, u.href, "http://example.test/b/x?q=%E6%97%A5")
	// taken out of it, it stays that document's (DOM "node document"): still UTF-8; inserted in the page, the page's
	dom.remove_child(p.doc, own, a)
	testing.expect_value(t, node_document(p, a), own)
	u, ok = resolve_link(p, "x?q=日", a)
	testing.expect_value(t, u.href, "http://example.test/b/x?q=%E6%97%A5")
	dom.append_child(p.doc, p.body, a)
	dom.remove_child(p.doc, p.body, a)
	testing.expect_value(t, node_document(p, a), p.doc.root)
	u, ok = resolve_link(p, "x?q=日", a)
	testing.expect_value(t, u.href, "http://example.test/b/x?q=%93%FA")

	load_html(p, transmute([]byte)string("<p>utf-8"))
	testing.expect_value(t, document_encoding(p), "UTF-8")
	u, ok = resolve_link(p, "x?q=日", p.body)
	testing.expect_value(t, u.href, "http://example.test/dir/x?q=%E6%97%A5")
}

// Navigation API keys and ids: a key per entry (its place), an id per entry made; replacing keeps the key, makes a new
// id and drops the Navigation API state; the state of other entries stays.
@(test)
navigation_keys_and_ids :: proc(t: ^testing.T) {
	test_pages(t)
	sh: Session_History
	defer session_destroy(&sh)
	a := session_push(&sh, "https://a/1", 1)
	session_set_nav_state(&sh, "s1", true)
	b := session_push(&sh, "https://a/2", 1)
	testing.expect(t, a.id != b.id && a.nav_id != b.nav_id)
	testing.expect_value(t, b.has_nav_state, false)
	key, id := b.id, b.nav_id
	session_set_nav_state(&sh, "s2", true)
	session_replace(&sh, "https://a/3")
	cur := session_current(&sh)
	testing.expect_value(t, cur.id, key)
	testing.expect(t, cur.nav_id != id)
	testing.expect_value(t, cur.has_nav_state, false)
	testing.expect_value(t, a.nav_state, "s1")
	// session restore gives every entry an id of its own
	saved := []Saved_Entry{{id = 5, url = "https://a/x"}, {id = 6, parent = 5, url = "https://a/y"}}
	session_load(&sh, saved, 6, 50, 100)
	testing.expect_value(t, len(sh.entries), 2)
	testing.expect(t, sh.entries[0].nav_id != 0 && sh.entries[0].nav_id != sh.entries[1].nav_id)
}
