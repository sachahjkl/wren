package browser

import "core:strings"
import "core:testing"

@(test)
session_round_trip :: proc(t: ^testing.T) {
	text := session_serialize({"https://a.org/", "about:config", "file:///C:/x.html"}, 1, 1024)
	urls, cur, ok := session_parse(text, 100, 1024)
	testing.expect(t, ok)
	testing.expect_value(t, len(urls), 3)
	testing.expect_value(t, cur, 1)
	if len(urls) == 3 {
		testing.expect_value(t, urls[0], "https://a.org/")
		testing.expect_value(t, urls[1], "about:config")
		testing.expect_value(t, urls[2], "file:///C:/x.html")
	}
	// addresses that cannot be written are left out, and `current` follows its tab
	text = session_serialize({"", "https://a/\nb", strings.repeat("x", 50, context.temp_allocator), "https://kept/"}, 3, 40)
	urls, cur, ok = session_parse(text, 100, 1024)
	testing.expect(t, ok)
	testing.expect_value(t, len(urls), 1)
	testing.expect_value(t, cur, 0)
}

// Whatever is in the file, the browser starts.
@(test)
session_damaged_files :: proc(t: ^testing.T) {
	_, _, ok := session_parse("", 100, 1024)
	testing.expect(t, !ok)
	_, _, ok = session_parse("garbage\ntab https://a/\n", 100, 1024)
	testing.expect(t, !ok)
	_, _, ok = session_parse("\x00\xff\xfe binary", 100, 1024)
	testing.expect(t, !ok)
	urls, cur, ok2 := session_parse("wren-session 1\r\ncurrent 99\r\ntab not a url\r\nunknown line\r\ntab https://ok/\r\ntab \r\ncurrent -3", 100, 1024)
	testing.expect(t, ok2)
	testing.expect_value(t, len(urls), 1)
	testing.expect_value(t, cur, 0)
	// the tab count is capped
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "wren-session 1\n")
	for _ in 0 ..< 50 { strings.write_string(&sb, "tab https://a/\n") }
	urls, _, _ = session_parse(strings.to_string(sb), 10, 1024)
	testing.expect_value(t, len(urls), 10)
	// a header and nothing else: a session with no tab
	urls, cur, ok = session_parse("wren-session 1\n", 10, 1024)
	testing.expect(t, ok)
	testing.expect_value(t, len(urls), 0)
}
