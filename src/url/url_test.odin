package url

import "core:testing"

@(private = "file")
href :: proc(input: string, base := "") -> string {
	b: URL
	bp: ^URL
	if base != "" {
		ok: bool
		b, ok = parse(base, nil, context.temp_allocator)
		if !ok { return "<invalid base>" }
		bp = &b
	}
	u, ok := parse(input, bp, context.temp_allocator)
	if !ok { return "<invalid>" }
	return u.href
}

@(test)
normalisation :: proc(t: ^testing.T) {
	testing.expect_value(t, href("HTTP://EXAMPLE.com:80/a/./b/../c?Q=1#F"), "http://example.com/a/c?Q=1#F")
	testing.expect_value(t, href("https://example.com:443/"), "https://example.com/")
	testing.expect_value(t, href("https://example.com:8443"), "https://example.com:8443/")
	testing.expect_value(t, href("http://0x7f.1/"), "http://127.0.0.1/")
	testing.expect_value(t, href("http://[0:0:0:0:0:0:0:1]/"), "http://[::1]/")
	testing.expect_value(t, href("https://bücher.example/"), "https://xn--bcher-kva.example/")
	testing.expect_value(t, href("https://example.com/a b?c d#e f"), "https://example.com/a%20b?c%20d#e%20f")
	testing.expect_value(t, href("https://user:pw@example.com/"), "https://user:pw@example.com/")
	testing.expect_value(t, href("  https://example.com/\t\n"), "https://example.com/")
}

// The query of a special URL in the document's encoding: bytes of the encoding percent-encoded, "&#N;" for what it
// cannot represent; the path, a non-special URL and ws: stay in UTF-8.
@(test)
query_in_a_legacy_encoding :: proc(t: ^testing.T) {
	enc :: proc(input, encoding: string) -> string {
		u, ok := parse(input, nil, context.temp_allocator, encoding)
		return ok ? u.href : "<invalid>"
	}
	testing.expect_value(t, enc("https://example.com/?日本", "Shift_JIS"), "https://example.com/?%93%FA%96{")
	testing.expect_value(t, enc("https://example.com/?日本", "shift-jis"), "https://example.com/?%93%FA%96{")
	testing.expect_value(t, enc("https://example.com/?한", "Shift_JIS"), "https://example.com/?%26%2354620%3B")
	testing.expect_value(t, enc("https://example.com/?한", "EUC-KR"), "https://example.com/?%C7%D1")
	testing.expect_value(t, enc("https://example.com/é?é#é", "windows-1252"), "https://example.com/%C3%A9?%E9#%C3%A9")
	testing.expect_value(t, enc("https://example.com/?é", "UTF-16LE"), "https://example.com/?%C3%A9")
	testing.expect_value(t, enc("https://example.com/?é", ""), "https://example.com/?%C3%A9")
	testing.expect_value(t, enc("wss://example.com/?é", "windows-1252"), "wss://example.com/?%C3%A9")
	testing.expect_value(t, enc("x-custom:a?é", "windows-1252"), "x-custom:a?%C3%A9")
	// the IBM extensions of Shift_JIS (not the NEC selected ones Lexbor takes), GB18030-2005's private use code points that
	// GB18030-2022 moved (a byte of the query outside its percent-encode set stays as it is)
	testing.expect_value(t, enc("https://example.com/?aⅰ#ⅰ", "Shift_JIS"), "https://example.com/?a%FA@#%E2%85%B0")
	testing.expect_value(t, enc("https://example.com/?", "GBK"), "https://example.com/?%A6%D9%FEY")
}

// Form submission's encoder: what an encoding cannot represent becomes "&#N;", which takes ISO-2022-JP back to ASCII.
@(test)
encode_text_in_legacy_encodings :: proc(t: ^testing.T) {
	enc :: proc(s, encoding: string) -> string {
		r, ok := encode_text(s, encoding, context.temp_allocator)
		return ok ? r : "<failed>"
	}
	testing.expect_value(t, enc("a日b", "Shift_JIS"), "a\x93\xfab")
	testing.expect_value(t, enc("ⅰ", "Shift_JIS"), "\xfa\x40")
	testing.expect_value(t, enc("", "gb18030"), "\xa6\xd9")
	testing.expect_value(t, enc("€한", "windows-1252"), "\x80&#54620;")
	testing.expect_value(t, enc("日한", "ISO-2022-JP"), "\x1b$BF|\x1b(B&#54620;")
	testing.expect_value(t, enc("é", "UTF-16BE"), "é")
	testing.expect_value(t, enc("", "Big5"), "")
}

@(test)
invalid_urls :: proc(t: ^testing.T) {
	testing.expect_value(t, href("https://"), "<invalid>")
	testing.expect_value(t, href("https://exa mple.com/"), "<invalid>")
	testing.expect_value(t, href("http://[::1/"), "<invalid>")
	testing.expect_value(t, href("http://a:99999/"), "<invalid>")
	testing.expect_value(t, href("/relative-without-base"), "<invalid>")
	testing.expect_value(t, href(""), "<invalid>")
}

@(test)
relative_resolution :: proc(t: ^testing.T) {
	b := "https://a.com/x/y/z.html?q#f"
	testing.expect_value(t, href("w.wasm", b), "https://a.com/x/y/w.wasm")
	testing.expect_value(t, href("../w", b), "https://a.com/x/w")
	testing.expect_value(t, href("../../../../w", b), "https://a.com/w")
	testing.expect_value(t, href("/r", b), "https://a.com/r")
	testing.expect_value(t, href("//b.org/p", b), "https://b.org/p")
	testing.expect_value(t, href("?n=2", b), "https://a.com/x/y/z.html?n=2")
	testing.expect_value(t, href("#top", b), "https://a.com/x/y/z.html?q#top")
	testing.expect_value(t, href("", b), "https://a.com/x/y/z.html?q")
	testing.expect_value(t, href("https:other", b), "https://a.com/x/y/other")   // same special scheme as the base: relative`n	testing.expect_value(t, href("http:other", b), "http://other/")            // different scheme: "other" is the host
	testing.expect_value(t, href("mailto:a@b.c", b), "mailto:a@b.c")
	testing.expect_value(t, href("\\evil\\p", b), "https://a.com/evil/p")      // backslash is a slash in special URLs
	testing.expect_value(t, href("app.wasm", "file:///S:/site/index.html"), "file:///S:/site/app.wasm")
}

@(test)
components :: proc(t: ^testing.T) {
	u, ok := parse("https://u:p@Sub.Example.com:8443/p/a?x=1&y=2#frag", nil, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, u.scheme, "https")
	testing.expect_value(t, u.username, "u")
	testing.expect_value(t, u.password, "p")
	testing.expect_value(t, u.host, "sub.example.com")
	testing.expect_value(t, u.port, 8443)
	testing.expect_value(t, u.path, "/p/a")
	testing.expect_value(t, u.query, "x=1&y=2")
	testing.expect_value(t, u.fragment, "frag")
	testing.expect_value(t, u.host_kind, Host_Kind.Domain)
	testing.expect_value(t, effective_port(u), 8443)

	m, _ := parse("mailto:Alice@Example.com?subject=x", nil, context.temp_allocator)
	testing.expect(t, m.opaque_path)
	testing.expect_value(t, m.host_kind, Host_Kind.None)
	testing.expect_value(t, m.path, "Alice@Example.com")

	f, _ := parse("file:///C:/dir/a.txt", nil, context.temp_allocator)
	testing.expect_value(t, f.host_kind, Host_Kind.Empty)
	testing.expect_value(t, f.path, "/C:/dir/a.txt")
	testing.expect(t, f.special)

	v6, _ := parse("http://[2001:db8::1]:81/", nil, context.temp_allocator)
	testing.expect_value(t, v6.host, "[2001:db8::1]")
	testing.expect_value(t, v6.host_kind, Host_Kind.IPv6)
	testing.expect_value(t, v6.port, 81)

	v4, _ := parse("http://192.168.0.1/", nil, context.temp_allocator)
	testing.expect_value(t, v4.host_kind, Host_Kind.IPv4)
}

@(test)
origins :: proc(t: ^testing.T) {
	mk :: proc(s: string) -> Origin {
		u, _ := parse(s, nil, context.temp_allocator)
		return origin_of(u, context.temp_allocator)
	}
	a := mk("https://example.com/a")
	testing.expect(t, same_origin(a, mk("https://example.com:443/b?c")))
	testing.expect(t, !same_origin(a, mk("http://example.com/")))
	testing.expect(t, !same_origin(a, mk("https://example.com:444/")))
	testing.expect(t, !same_origin(a, mk("https://www.example.com/")))
	testing.expect_value(t, origin_serialize(a, context.temp_allocator), "https://example.com")
	testing.expect_value(t, origin_serialize(mk("http://h:8080/x"), context.temp_allocator), "http://h:8080")

	f1, f2 := mk("file:///a.html"), mk("file:///a.html")
	testing.expect(t, f1.opaque && f2.opaque)
	testing.expect(t, !same_origin(f1, f2), "opaque origins are only equal to themselves")
	testing.expect(t, same_origin(f1, f1))
	testing.expect_value(t, origin_serialize(f1, context.temp_allocator), "null")

	testing.expect(t, same_origin(mk("blob:https://example.com/3f2"), a), "blob: keeps the origin of its URL")

	o, ok := origin_parse("https://example.com", context.temp_allocator)
	testing.expect(t, ok && same_origin(o, a))
	_, bad := origin_parse("https://example.com/path", context.temp_allocator)
	testing.expect(t, !bad)
}

@(test)
trustworthy :: proc(t: ^testing.T) {
	chk :: proc(s: string) -> bool {
		u, _ := parse(s, nil, context.temp_allocator)
		return is_potentially_trustworthy(u)
	}
	testing.expect(t, chk("https://example.com/"))
	testing.expect(t, chk("http://localhost:3000/"))
	testing.expect(t, chk("http://app.localhost/"))
	testing.expect(t, chk("http://127.0.0.1/"))
	testing.expect(t, chk("http://127.9.9.9/"))
	testing.expect(t, chk("http://[::1]/"))
	testing.expect(t, chk("file:///x"))
	testing.expect(t, !chk("http://example.com/"))
	testing.expect(t, !chk("http://127.example.com/"))
	testing.expect(t, !chk("ftp://example.com/"))
}

@(test)
public_suffix_list :: proc(t: ^testing.T) {
	reg :: proc(h: string) -> string {
		d, ok := registrable_domain(h)
		return ok ? d : "<none>"
	}
	testing.expect_value(t, reg("www.example.com"), "example.com")
	testing.expect_value(t, reg("example.com"), "example.com")
	testing.expect_value(t, reg("a.b.example.co.uk"), "example.co.uk")
	testing.expect_value(t, reg("com"), "<none>")
	testing.expect_value(t, reg("co.uk"), "<none>")
	testing.expect_value(t, reg("user.github.io"), "user.github.io")      // private section: github.io is a suffix
	testing.expect_value(t, reg("a.user.github.io"), "user.github.io")
	testing.expect_value(t, reg("github.io"), "<none>")
	testing.expect_value(t, reg("foo.bar.ck"), "foo.bar.ck")               // *.ck wildcard
	testing.expect_value(t, reg("www.ck"), "www.ck")                       // !www.ck exception
	testing.expect_value(t, reg("sub.www.ck"), "www.ck")
	testing.expect_value(t, reg("localhost"), "<none>")
	testing.expect_value(t, reg("127.0.0.1"), "<none>")
	testing.expect_value(t, reg("[::1]"), "<none>")
	testing.expect_value(t, reg("unknowntld.zzzz"), "unknowntld.zzzz")     // implicit "*" rule
	testing.expect_value(t, reg("xn--bcher-kva.example"), "xn--bcher-kva.example")
	testing.expect_value(t, reg("www.食狮.中国"[:0] + "www.xn--85x722f.xn--fiqs8s"), "xn--85x722f.xn--fiqs8s")   // IDN suffix rule, punycode
	testing.expect(t, is_public_suffix("co.uk"))
	testing.expect(t, !is_public_suffix("example.co.uk"))
	testing.expect_value(t, public_suffix("www.example.co.uk"), "co.uk")
}

@(test)
sites :: proc(t: ^testing.T) {
	mk :: proc(s: string) -> Site {
		u, _ := parse(s, nil, context.temp_allocator)
		return site_of(origin_of(u, context.temp_allocator), context.temp_allocator)
	}
	testing.expect(t, same_site(mk("https://a.example.com/"), mk("https://b.example.com:8443/x")))
	testing.expect(t, !same_site(mk("https://a.example.com/"), mk("http://a.example.com/")), "schemeful")
	testing.expect(t, !same_site(mk("https://a.github.io/"), mk("https://b.github.io/")), "github.io is a public suffix")
	testing.expect(t, same_site(mk("https://www.example.co.uk/"), mk("https://example.co.uk/")))
	testing.expect(t, !same_site(mk("https://example.co.uk/"), mk("https://other.co.uk/")))
	testing.expect(t, same_site(mk("http://localhost:1/"), mk("http://localhost:2/")))
	testing.expect(t, !same_site(mk("file:///a"), mk("file:///a")))
}

@(test)
test_public_suffix_fast_agrees :: proc(t: ^testing.T) {
	for h in ([]string{"com", "example.com", "a.b.example.co.uk", "foo.github.io", "x.y.city.kawasaki.jp", "a.b.c.ck", "www.ck", "localhost", "a.b", "x.compute.amazonaws.com", "1.2.3.4", "sub.example.pvt.k12.ma.us"}) {
		testing.expectf(t, public_suffix_labels(h) == public_suffix_labels_fast(h), "%s: %d vs %d", h, public_suffix_labels(h), public_suffix_labels_fast(h))
	}
}
// The URL Standard's domain to ASCII (src/shim/wb_idna.c): an ASCII domain is lower-cased only (its xn-- labels are not
// decoded to be checked), no length is verified, a label may not begin with a combining mark, a joiner needs its context.
@(test)
domain_to_ascii :: proc(t: ^testing.T) {
	testing.expect_value(t, href("https://XN--ZN7C.com/x"), "https://xn--zn7c.com/x")
	testing.expect_value(t, href("https://xn--a/x"), "https://xn--a/x")
	testing.expect_value(t, href("https://xn--unicode-.org/x"), "https://xn--unicode-.org/x")
	testing.expect_value(t, href("https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/x"), "https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/x")
	testing.expect_value(t, href("https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.\u00E4aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/x"), "https://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.xn--aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-4hf/x")
	testing.expect_value(t, href("https://a.b.\u0308c.d/x"), "<invalid>")                       // a combining mark first
	testing.expect_value(t, href("https://a\u200Cb/x"), "<invalid>")                           // ZWNJ out of context
	testing.expect_value(t, href("https://\u0628\u200C\u0628/x"), "https://xn--ngba799q/x")         // ZWNJ between two dual-joining letters
	testing.expect_value(t, href("https://\u0915\u094D\u200D\u0937/x"), "https://xn--11b2ezcw70k/x")  // ZWJ after a virama
	testing.expect_value(t, href("https://a\u200Db/x"), "<invalid>")                           // ZWJ out of context
	testing.expect_value(t, href("https://b\u00FCcher.example/x"), "https://xn--bcher-kva.example/x")
}

// Where Lexbor 3.0.1 parses otherwise than the URL Standard (LEXBOR_PATCHES of the Lexbor build, wb_url_fix of the shim):
// a last label of digits past 2^32 then letters is a domain; a dot segment ended by '?' or '#' keeps what follows; '^' of
// a path is percent-encoded; the last space of an opaque path before a fragment is "%20"; a path that begins with an empty
// segment is serialized after "/.", which is not the pathname's.
@(test)
parsed_as_the_standard_says :: proc(t: ^testing.T) {
	testing.expect_value(t, href("http://1.12345678901c/"), "http://1.12345678901c/")
	testing.expect_value(t, href("http://12345678901/"), "<invalid>")
	testing.expect_value(t, href("https://example.com/aaa/bbb/%2e%2e?query"), "https://example.com/aaa/?query")
	testing.expect_value(t, href("https://example.com/aaa/bbb/..#hash"), "https://example.com/aaa/#hash")
	testing.expect_value(t, href("https://example.com/a^b"), "https://example.com/a%5Eb")
	testing.expect_value(t, href("non-special:opaque  #hi"), "non-special:opaque %20#hi")
	testing.expect_value(t, href("non-special:opaque  "), "non-special:opaque")
	u, ok := parse("non-spec:/..//p", nil, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, u.href, "non-spec:/.//p")
	testing.expect_value(t, u.path, "//p")
}