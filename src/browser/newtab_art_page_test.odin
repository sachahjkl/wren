package browser

import "core:strings"
import "core:testing"

// Until the first painting is there, the page says that one is on its way (a spinner and a sentence), not only a bare gradient.
@(test)
the_art_page_says_that_a_painting_is_on_its_way :: proc(t: ^testing.T) {
	app := test_app(t)
	app.art.fails = 0
	app.art.cfg.show_caption = true
	html := art_page_html(app, nil, true)
	testing.expect(t, strings.contains(html, `<div class="art-loading">`), "a loading indicator")
	testing.expect(t, strings.contains(html, "Fetching a painting"), "and its sentence")
	// after a failure it says it tries again instead (the spinner is not shown for good)
	app.art.fails = 1
	html2 := art_page_html(app, nil, true)
	testing.expect(t, !strings.contains(html2, `<div class="art-loading">`), "no spinner after a failure")
	testing.expect(t, strings.contains(html2, "Trying again"), "it says it tries again")
}
