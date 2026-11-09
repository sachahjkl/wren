package browser

import "core:strings"
import "core:testing"

@(test)
setup_portable_marker :: proc(t: ^testing.T) {
	test_app(t)
	// the test executable has no wren.portable beside it
	testing.expect_value(t, portable_profile_dir(), "")
}

@(test)
setup_update_document_is_read_carefully :: proc(t: ^testing.T) {
	test_app(t)
	tag, page, ok := update_parse(transmute([]byte)string(`{"tag_name":"v0.4.0","html_url":"https://github.com/sachahjkl/wren/releases/tag/v0.4.0","draft":false}`))
	testing.expect(t, ok && tag == "v0.4.0" && strings.has_prefix(page, "https://github.com/"), "a release")
	_, _, ok = update_parse(transmute([]byte)string(`{"tag_name":"v0.5.0","prerelease":true}`))
	testing.expect(t, !ok, "a prerelease is not offered")
	_, _, ok = update_parse(transmute([]byte)string(`{"tag_name":"v0.5.0","draft":true}`))
	testing.expect(t, !ok, "a draft is not offered")
	_, _, ok = update_parse(transmute([]byte)string(`{"message":"Not Found"}`))
	testing.expect(t, !ok, "an error document")
	_, _, ok = update_parse(transmute([]byte)string(`<html>`))
	testing.expect(t, !ok, "not JSON")
	_, page, ok = update_parse(transmute([]byte)string(`{"tag_name":"v1","html_url":"javascript:alert(1)"}`))
	testing.expect(t, ok && page == "", "only an https page is kept")
	_, page, ok = update_parse(transmute([]byte)string(`{"tag_name":"v1"}`))
	testing.expect(t, ok && page == "", "no page")
}
