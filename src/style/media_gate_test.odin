package style

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:dom"
import "wb:html"
import "wb:host"

// The restyle after a media query changed value on several threads, over a document with counters, inherited values that change
// (a font size, em lengths below it) and an element that shows and hides: the styles must be those of a full pass.
@(test)
media_flip_on_several_threads_gives_the_full_result :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<style>
		body { counter-reset: sec; margin: 0 }
		section { counter-increment: sec; padding: 1em }
		section::before { content: "S" counter(sec) " " }
		li { margin-left: 1em }
		.w { margin-top: 1px }
		@media (min-width: 900px) {
			.w { margin-top: 2px; font-size: 20px; line-height: 1.5 }
			.h { display: none }
			li.n { display: inline-block }
		}
		@media (max-width: 899px) { .s { font-size: 11px } }
	</style><body>`)
	for i in 0 ..< 60 {
		fmt.sbprintf(&sb, `<section class="%s"><p class=w>a <em>b</em></p><ul><li>x<li class=n>y<li class=h>z</ul><span class=s>c</span></section>`, i % 3 == 0 ? "w" : "")
	}
	strings.write_string(&sb, `</body>`)
	src := strings.to_string(sb)

	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, transmute([]byte)src, 2_000_000)
	settings := settings_default()
	settings.media_parallel_min = 1
	defer settings_destroy(&settings)
	e := engine_make(settings)
	defer engine_destroy(e)
	sync_document_sheets(e, doc, "about:test")
	s := compute_styles(e, doc, {})
	defer styled_destroy(s)
	e.restyle_needed = false
	pool := host.thread_pool_make(3)
	defer host.thread_pool_destroy(pool)

	for width, i in ([?]f64{600, 1000, 800, 1000}) {
		env := e.env
		env.width = width
		engine_set_environment(e, env)
		testing.expect(t, e.gates_pending && !e.dirty && !e.restyle_needed, "the gates flipped")
		_, ok := restyle_media(e, doc, s, pool)
		testing.expectf(t, ok, "step %d: restyle_media: %s", i, e.last_restyle.fallback)
		testing.expectf(t, e.last_restyle.marked > 100, "step %d: marked %d", i, e.last_restyle.marked)
		testing.expect_value(t, verify_styles(e, doc, s, context.temp_allocator), "")
	}
}
