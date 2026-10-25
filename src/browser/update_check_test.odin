package browser

import "core:strings"
import "core:testing"

// The release document and update.txt are text from outside: a version is a version, a page is an https address on one line
// (security review of 2026-10-25, finding 10: a tag with a line break wrote a `url=` line of its own into update.txt).
@(test)
update_versions_and_pages_are_checked :: proc(t: ^testing.T) {
	for v in ([]string{"0.3.0", "1.2.3-beta.1", "10.0.0+build.5", "0.3.0-rc1"}) { testing.expectf(t, update_version_ok(v), "%q", v) }
	for v in ([]string{"", "99\nurl=file://attacker/s/x.html", "1.0\r", "1 0", "1/2", "v1\n", "1.0;", "é", "1\x00", "x\ty"}) { testing.expectf(t, !update_version_ok(v), "%q", v) }
	testing.expect(t, !update_version_ok(strings.repeat("1", 70, context.temp_allocator)))
	testing.expect(t, update_version_ok(strings.repeat("1", 64, context.temp_allocator)))
	testing.expect(t, update_page_ok("https://github.com/sachahjkl/wren/releases/tag/v0.4.0"))
	for a in ([]string{"", "http://x.example/", "file://attacker/s/x.html", "https://x.example/ a", "https://x.example/\nurl=file://a", "https://x.example/\r", "https://x.example/\x7f", "javascript:alert(1)"}) {
		testing.expectf(t, !update_page_ok(a), "%q", a)
	}
}

@(test)
a_release_with_a_hostile_tag_is_not_one :: proc(t: ^testing.T) {
	good := `{"tag_name":"v0.4.0","html_url":"https://github.com/sachahjkl/wren/releases/tag/v0.4.0"}`
	tag, page, ok := update_parse(transmute([]byte)good)
	testing.expect(t, ok)
	testing.expect_value(t, tag, "v0.4.0")
	testing.expect_value(t, page, "https://github.com/sachahjkl/wren/releases/tag/v0.4.0")
	evil := `{"tag_name":"99\nurl=file://attacker/s/x.html","html_url":"https://github.com/x"}`
	_, _, ok = update_parse(transmute([]byte)evil)
	testing.expect(t, !ok, "a tag with a line break is refused")
	line := `{"tag_name":"v1.0","html_url":"https://github.com/x\nurl=file://attacker/s/x.html"}`
	tag, page, ok = update_parse(transmute([]byte)line)
	testing.expect(t, ok && page == "", "a page with a line break is dropped, the release stays")
}