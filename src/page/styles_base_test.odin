package page

import "base:runtime"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"

// A document's <style> sheets resolve their URLs (@font-face sources, url() images, @import) against its base URL, not
// its address: a saved copy of a Google page (<base href="https://www.google.com/">) asks Google Sans at
// //fonts.gstatic.com, which is https://fonts.gstatic.com there and file://fonts.gstatic.com from the file's address.
@(test)
style_sheets_resolve_against_the_base_url :: proc(t: ^testing.T) {
	test_pages(t)
	context.allocator = runtime.heap_allocator()   // (the tree builder's heap: offthread_test.odin)
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	settings := settings_default()
	defer settings_destroy(&settings)
	settings.threads.style_threads = 0
	loader: fetch.Loader
	scope := base.scope_make("test")
	defer base.scope_close(scope)
	p := page_create(&loop, &loader, &settings, scope, "file:///C:/saved/page.html")
	defer page_close(p)
	load_html(p, transmute([]byte)string(`<!doctype html><head><base href="https://www.example.test/a/"><style>p { color: red }</style></head><p>x`))
	sync_styles(p)
	owner := dom.find_first_by_tag(p.doc, "style")
	found := false
	for s in p.engine.sheets {
		if s.owner != owner { continue }
		found = true
		testing.expectf(t, s.base_url == "https://www.example.test/a/", "the sheet's base: %q", s.base_url)
		abs, ok := resolve_against("//fonts.example.test/x.ttf", s.base_url)
		defer delete(abs)
		testing.expectf(t, ok && abs == "https://fonts.example.test/x.ttf", "a scheme-relative source: %q", abs)
	}
	testing.expect(t, found, "the <style> sheet is registered")
}
