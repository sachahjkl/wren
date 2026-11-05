package e2e_scenarios

// A document's requests leave while its bytes arrive, in the shell (page/preload_scan.odin; the scanner itself is tested in web_jsload.odin): the server holds the end of
// the document until a script its beginning names was asked for, and says in that end whether it was. Parsing starts when the document is complete, so only the
// scanner can have asked.

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:e2e"
import "wb:remote/api"
import "wb:url"

// The script of the beginning of the document; the server's own limit, far above what a request takes.
@(private = "file") ARRIVAL_SCRIPT :: "/jsload/gen?code=window.ran%3D1&k=arrival"
@(private = "file") ARRIVAL_HOLD_MS :: 8000

@(test)
a_document_s_requests_leave_while_its_end_is_held :: proc(t: ^testing.T) {
	head := strings.concatenate({`<!doctype html><title>held</title><script src="`, ARRIVAL_SCRIPT, `"></script>`}, context.temp_allocator)
	address := fmt.tprintf("/jsload/held?ms=%d&until=%s&head=%s", ARRIVAL_HOLD_MS, url.percent_encoded(ARRIVAL_SCRIPT, url.UNRESERVED), url.percent_encoded(head, url.UNRESERVED))
	p := e2e.launch(t)
	api.navigate(p.s, e2e.url(e2e.test_server(t), address))
	asked, _ := api.eval(p.s, `document.body.dataset.asked`)
	ran, _ := api.eval(p.s, `String(window.ran)`)
	testing.expectf(t, asked == "yes", "the server saw the request while it held the end of the document: %q", asked)
	testing.expectf(t, ran == "1", "and the element ran what that request brought: %q", ran)
	e2e.quit(p)
}
