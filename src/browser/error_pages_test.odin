package browser

import "core:strings"
import "core:testing"

// Each kind of failure gets its own words (and the TLS one its own security chip).
@(test)
error_page_kinds :: proc(t: ^testing.T) {
	e := classify_load_error("https://nonexistent.invalid/", .Transport, 12007, "host name could not be resolved")
	testing.expect_value(t, e.kind, Error_Kind.Dns)
	testing.expect(t, strings.contains(e.explain, "nonexistent.invalid"))
	testing.expect_value(t, classify_load_error("http://127.0.0.1:9/", .Transport, 12029, "").kind, Error_Kind.Refused)
	testing.expect_value(t, classify_load_error("http://a/", .Transport, 12002, "").kind, Error_Kind.Timeout)
	testing.expect_value(t, classify_load_error("https://a/", .Transport, 12175, "").kind, Error_Kind.Tls)
	testing.expect_value(t, classify_load_error("https://a/", .Transport, 12045, "").kind, Error_Kind.Tls)
	testing.expect_value(t, classify_load_error("http://a:1/", .Bad_Port, 0, "port 1 is blocked").kind, Error_Kind.Blocked)
	testing.expect_value(t, classify_load_error("https://a/", .Redirect_Loop, 0, "").kind, Error_Kind.Redirects)
	f := classify_load_error("file:///C:/dir/missing.html", .Transport, 0, `C:\dir\missing.html: no such file or folder`)
	testing.expect_value(t, f.kind, Error_Kind.File_Missing)
	testing.expect(t, strings.contains(f.explain, "missing.html"))
	testing.expect_value(t, classify_load_error("https://a/", .Body_Too_Large, 0, "").kind, Error_Kind.Too_Large)
	testing.expect_value(t, classify_load_error("https://a/", .Aborted, 0, "").kind, Error_Kind.Generic)

	testing.expect_value(t, error_tab_title("https://nonexistent.invalid/x"), "nonexistent.invalid")
	testing.expect_value(t, error_tab_title("file:///C:/dir/missing.html"), "missing.html")
}

// The page escapes what it shows (an address can hold anything).
@(test)
error_page_escapes :: proc(t: ^testing.T) {
	e := classify_load_error(`https://a/<script>`, .Transport, 12007, `<img src=x onerror=alert(1)>`)
	html := error_page_html(e, `https://a/<script>"`, `<b>`)
	testing.expect(t, !strings.contains(html, "<script>"))
	testing.expect(t, !strings.contains(html, "<img"))
	testing.expect(t, !strings.contains(html, "<b>"))
	testing.expect(t, strings.contains(html, "&lt;script&gt;&quot;"))
}
