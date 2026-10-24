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