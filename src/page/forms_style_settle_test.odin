package page

import "base:runtime"
import "core:testing"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:style"

// What the style threads of a parallel pass ask of the forms model only reads once the pass's thread settled it
// (forms_style_settle): no control made, no checkedness synced, no radio group's list rebuilt by a query after it. Before,
// two threads building the list of a radio group at once freed it twice (a crash on Linux).
@(test)
forms_queries_only_read_after_the_settle :: proc(t: ^testing.T) {
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

	p := page_create(&loop, &loader, &settings, scope, "http://example.test/forms.html")
	load_html(p, transmute([]byte)string(`<form><input type=radio name=a checked><input type=radio name=a><input type=checkbox checked>
<input required><select><option selected>x</select><progress></progress></form><input type=radio name=b>`))
	f := p.formctl.model
	testing.expect(t, len(f.controls) == 0 || !f.radio_cache_valid, "nothing settled before the pass (else the test proves nothing)")

	forms_style_settle(p)
	controls, valid, at, serial := len(f.controls), f.radio_cache_valid, f.radio_cache_at, f.serial
	testing.expect(t, controls > 0 && valid, "the settle made the controls and the radio groups' list")
	it: u32
	for h, n in base.pool_next(&p.doc.nodes, &it) {
		if n.kind != .Element { continue }
		for q in style.Control_Query { _, _ = forms_style_query(p, h, q) }
	}
	testing.expect_value(t, len(f.controls), controls)
	testing.expect_value(t, f.radio_cache_valid, valid)
	testing.expect_value(t, f.radio_cache_at, at)
	testing.expect_value(t, f.serial, serial)
}
