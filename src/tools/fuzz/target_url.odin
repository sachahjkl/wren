package fuzz

import "wb:url"

// A base with every component set: a relative input can replace each of them.
URL_BASE :: "https://user:pass@example.org:8080/a/b/c?q=1#f"

URL_SEEDS := []string{
	"https://example.org/",
	"http://user:pass@[2001:db8::1]:8080/p/a/t/h?query=1&b=2#frag",
	"http://0x7f.0.0.1/", "http://127.1/", "http://0300.0250.0.1/", "http://4294967295/", "http://[::ffff:192.168.0.1]/",
	"https://xn--nxasmq6b.example/", "https://ÉXAMPLE.org/über", "https://a.b.c.d.example.co.uk./",
	"file:///C:/Windows/../x", "file://host/share/f", "file:/a/b", "data:text/html;base64,PGI+", "blob:https://e.org/uuid",
	"javascript:alert(1)", "mailto:a@b", "about:blank", "wren://settings", "view-source:https://e.org",
	"//other.org/x", "/abs/path", "rel/../../path", "?only-query", "#only-hash", "..", "./a/./b/%2e%2E/c",
	"https://e.org/%zz%%41%C3%A9 space\ttab\nnewline", "  https://e.org/  ", "HTTPS://E.ORG:443/", "http://e.org:65536/",
	"ws://e.org/socket", "wss://e.org:0/", "non-special://host/p", "non-special:opaque path", "https:e.org", "http:\\\\e.org\\a",
}

URL_TOKENS := []string{
	"://", "//", "/", "\\", ":", "@", "?", "#", "%", "%2e", "%00", "%ff", "[", "]", "::", ".", "..", "xn--", "0x", "0",
	"http", "https", "file", "data", "blob", "ws", "javascript", "localhost", "127.0.0.1", "\t", "\n", " ", "\u00E9", "\uFF0E", "\u3002",
}

target_url :: proc(data: []u8) {
	text := string(data)
	u, ok := url.parse(text)
	if ok {
		for c in url.Component { _ = url.component(u, c, context.temp_allocator) }
		o := url.origin_of(u)
		_ = url.origin_serialize(o, context.temp_allocator)
		url.origin_destroy(&o)
	}
	url.destroy(&u)

	base_url, _ := url.parse(URL_BASE)
	defer url.destroy(&base_url)
	r, _ := url.parse(text, &base_url)
	url.destroy(&r)
}
