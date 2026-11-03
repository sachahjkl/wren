package page

import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"

// The image elements a page follows are the <img> and <input type=image> of its tree, shadow trees included, found
// among those the document made: one inserted, one never inserted, a subtree removed, a type changed to image, an image
// in a shadow tree; a change of text alone finds nothing new.
@(test)
images_found_among_the_documents_images :: proc(t: ^testing.T) {
	test_pages(t)
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	settings := settings_default()
	defer settings_destroy(&settings)
	loader: fetch.Loader
	scope := base.scope_make("test")
	defer base.scope_close(scope)
	p := page_create(&loop, &loader, &settings, scope, "http://127.0.0.1:8765/t.html")
	defer page_close(p)
	d := p.doc
	dom.journal_enable(d, 1 << 10)
	body := dom.find_first_by_tag(d, "body")
	el :: proc(d: ^dom.Document, parent: base.Handle, name: string, type := "") -> base.Handle {
		h := dom.create_element(d, name)
		if type != "" { dom.set_attribute(d, h, "type", type) }
		if parent != base.NIL_HANDLE { dom.append_child(d, parent, h) }
		return h
	}
	followed :: proc(p: ^Page) -> int { images_sync(p); return len(p.images.elements) }
	box := el(d, body, "div")
	img := el(d, box, "img")
	_ = el(d, body, "input", "image")
	text_input := el(d, body, "input")
	words := dom.create_text(d, "words")
	dom.append_child(d, body, words)
	testing.expect_value(t, followed(p), 2)
	loose := el(d, base.NIL_HANDLE, "img")
	testing.expect_value(t, followed(p), 2)
	dom.append_child(d, box, loose)
	testing.expect_value(t, followed(p), 3)
	dom.remove_child(d, body, box)
	testing.expect_value(t, followed(p), 1)
	testing.expect(t, img not_in p.images.elements && loose not_in p.images.elements)
	dom.set_attribute(d, text_input, "type", "image")
	testing.expect_value(t, followed(p), 2)
	host_el := el(d, body, "div")
	root, err := dom.attach_shadow(d, host_el, {mode = .Open})
	testing.expect_value(t, err, dom.Error.None)
	_ = el(d, root, "img")
	testing.expect_value(t, followed(p), 3)
	pass := p.images.pass
	dom.set_data(d, words, "other words")
	testing.expect_value(t, followed(p), 3)
	testing.expect_value(t, p.images.pass, pass)   // (not looked for again)
}
