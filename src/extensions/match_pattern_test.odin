package extensions

import "core:testing"
import "wb:url"

@(private = "file")
matches :: proc(pattern, href: string) -> bool {
	p, ok := pattern_parse(pattern)
	if !ok { return false }
	u, uok := url.parse(href, nil, context.temp_allocator)
	return uok && pattern_matches(p, u)
}

// The table of Chrome's "Match patterns" page.
@(test)
test_match_patterns_chrome_table :: proc(t: ^testing.T) {
	Case :: struct { pattern, href: string, want: bool }
	cases := [?]Case{
		{"https://*/*", "https://www.google.com/", true},
		{"https://*/*", "https://example.org/foo/bar.html", true},
		{"https://*/*", "http://example.org/", false},
		{"https://*/foo*", "https://example.com/foo/bar.html", true},
		{"https://*/foo*", "https://www.google.com/foo", true},
		{"https://*/foo*", "https://www.google.com/bar", false},
		{"https://*.google.com/foo*bar", "https://www.google.com/foo/baz/bar", true},
		{"https://*.google.com/foo*bar", "https://docs.google.com/foobar", true},
		{"https://*.google.com/foo*bar", "https://google.com/foobar", true},
		{"https://*.google.com/foo*bar", "https://evilgoogle.com/foobar", false},
		{"https://example.org/foo/bar.html", "https://example.org/foo/bar.html", true},
		{"https://example.org/foo/bar.html", "https://example.org/foo/baz.html", false},
		{"http://127.0.0.1/*", "http://127.0.0.1/", true},
		{"http://127.0.0.1/*", "http://127.0.0.1/foo/bar.html", true},
		{"*://mail.google.com/*", "http://mail.google.com/foo/baz/bar", true},
		{"*://mail.google.com/*", "https://mail.google.com/foobar", true},
		{"*://mail.google.com/*", "ftp://mail.google.com/", false},
		{"urn:*", "urn:uuid:54723bea-c94e-480e-80c8-a69846c3f582", false},   // (no "://": refused as a pattern here)
		{"<all_urls>", "http://example.org/foo/bar.html", true},
		{"<all_urls>", "file:///bar/baz.html", true},
		{"<all_urls>", "chrome://settings/", false},
		{"file:///foo*", "file:///foo/bar.html", true},
		{"file:///foo*", "file:///foo", true},
		{"file:///foo*", "file:///bar", false},
		{"http://localhost:8080/*", "http://localhost:8080/a", true},
		{"http://localhost:8080/*", "http://localhost:9090/a", false},
		{"http://localhost:*/*", "http://localhost:9090/a", true},
		{"*://*/*.xml*", "https://example.com/feed.xml", true},
		{"*://*/*.xml*", "https://example.com/feed.html", false},
		{"https://*/*", "https://example.com/a?b=c", true},
		{"https://example.com/a?b=*", "https://example.com/a?b=c", true},
	}
	for c in cases {
		got := matches(c.pattern, c.href)
		testing.expectf(t, got == c.want, "%s against %s: %v, expected %v", c.pattern, c.href, got, c.want)
	}
}

@(test)
test_match_patterns_invalid :: proc(t: ^testing.T) {
	for s in ([?]string{"", "https://*.example.com", "https://www.*.com/*", "https://foo.*.bar/baz", "http:/bar", "foo://*", "https://*foo/*", "file://host/*", "http://host:99999/*"}) {
		_, ok := pattern_parse(s)
		testing.expectf(t, !ok, "%q must not parse", s)
	}
}

@(test)
test_glob :: proc(t: ^testing.T) {
	testing.expect(t, glob_match("*", ""))
	testing.expect(t, glob_match("a*b*c", "aXXbYYc"))
	testing.expect(t, !glob_match("a*b*c", "aXXbYY"))
	testing.expect(t, glob_match("popup/fonts/*", "popup/fonts/inter.woff2"))
	testing.expect(t, !glob_match("popup/fonts/*", "popup/index.html"))
	testing.expect(t, glob_match_question("a?c", "abc"))
	testing.expect(t, !glob_match("a?c", "abc"))   // ('?' is a character of a match pattern's path)
	// a hostile pattern stays linear enough: no recursion, no exponential walk
	long := "a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*a*b"
	subject := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	testing.expect(t, !glob_match(long, subject))
}
