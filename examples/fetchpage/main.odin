// The site's "Write a page" example (site/write/index.html): fetch a text and show it, as fetch(url).then(r => r.text())
// would. e2e web_page.odin loads it from examples/site/fetchpage.html.
package fetchpage

import "wren:core"
import "wren:dom"
import "wren:fetch"
import "wren:net"

out: dom.Element

@(export)
wb_main :: proc "contextless" () {
	out = dom.Document_getElementById("out")

	// fetch(url): a Promise of the Response
	p, err := fetch.promise("message.txt")
	if err != .None { dom.Node_setTextContent(out, "fetch refused"); return }
	core.Promise_then(p, on_response)
}

on_response :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	if st == .Rejected { dom.Node_setTextContent(out, "network error"); return }
	resp := net.Response(core.Promise_value(p))
	core.Promise_then(fetch.Response_text(resp), on_text)   // response.text()
}

on_text :: proc "contextless" (user: i32, p: core.Promise, st: core.PromiseState) {
	buf: [4096]u8
	text, _ := core.Promise_text(p, buf[:])
	dom.Node_setTextContent(out, text)
}
