package net

import "core:testing"

@(test)
url_basic :: proc(t: ^testing.T) {
	u, err := url_parse("https://Example.com/a/b?x=1#frag")
	testing.expect_value(t, err, URL_Error.None)
	testing.expect_value(t, u.scheme, "https")
	testing.expect_value(t, u.host, "Example.com")
	testing.expect_value(t, u.port, u16(443))
	testing.expect_value(t, u.target, "/a/b?x=1")
	testing.expect_value(t, u.fragment, "frag")
	testing.expect(t, u.secure)
}

@(test)
url_defaults_and_ports :: proc(t: ^testing.T) {
	u, err := url_parse("HTTP://localhost:8080")
	testing.expect_value(t, err, URL_Error.None)
	testing.expect_value(t, u.port, u16(8080))
	testing.expect_value(t, u.target, "")
	rt := request_target(u)
	defer delete(rt)
	testing.expect_value(t, rt, "/")

	u, err = url_parse("http://h?q=1")
	testing.expect_value(t, err, URL_Error.None)
	rt2 := request_target(u)
	defer delete(rt2)
	testing.expect_value(t, rt2, "/?q=1")
}

@(test)
url_ipv6_and_userinfo :: proc(t: ^testing.T) {
	u, err := url_parse("http://user:pw@[::1]:3000/x")
	testing.expect_value(t, err, URL_Error.None)
	testing.expect_value(t, u.host, "::1")
	testing.expect_value(t, u.port, u16(3000))
}

@(test)
url_resolution :: proc(t: ^testing.T) {
	cases := [][3]string{
		{"https://a.com/x/y.html", "z.wasm", "https://a.com/x/z.wasm"},
		{"https://a.com/x/y.html?q=1#f", "z.wasm", "https://a.com/x/z.wasm"},
		{"https://a.com/x/y.html", "../z.wasm", "https://a.com/z.wasm"},
		{"https://a.com/x/y.html", "../../../z", "https://a.com/z"},
		{"https://a.com/x/y.html", "/abs/p", "https://a.com/abs/p"},
		{"https://a.com/x/y.html", "//b.com/p", "https://b.com/p"},
		{"https://a.com/x/y.html", "http://c.org/q", "http://c.org/q"},
		{"https://a.com/x/y.html", "?s=2", "https://a.com/x/y.html?s=2"},
		{"https://a.com/x/y.html?q=1", "#top", "https://a.com/x/y.html?q=1#top"},
		{"https://a.com", "p", "https://a.com/p"},
		{"https://a.com/x/", "./p/./q", "https://a.com/x/p/q"},
		{"file:///S:/site/index.html", "app.wasm", "file:///S:/site/app.wasm"},
		{"file:///S:/site/index.html", "C:\\other\\a.wasm", "C:\\other\\a.wasm"},
	}
	for c in cases {
		got := url_resolve(c[0], c[1])
		defer delete(got)
		testing.expect_value(t, got, c[2])
	}
}

@(test)
url_errors :: proc(t: ^testing.T) {
	_, e := url_parse("")
	testing.expect_value(t, e, URL_Error.Empty)
	_, e = url_parse("ftp://x")
	testing.expect_value(t, e, URL_Error.Unsupported_Scheme)
	_, e = url_parse("https:///path")
	testing.expect_value(t, e, URL_Error.No_Host)
	_, e = url_parse("http://h:99999/")
	testing.expect_value(t, e, URL_Error.Bad_Port)
	_, e = url_parse("http://a b/")
	testing.expect_value(t, e, URL_Error.Has_Whitespace)
}
