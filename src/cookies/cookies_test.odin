package cookies

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:url"

@(private = "file")
parse_default :: proc(h: string) -> (Parsed, bool) { return parse_set_cookie(h, settings_default()) }

@(private = "file")
NOW :: i64(1_760_000_000_000)   // a fixed "now" so expiry tests are deterministic

@(private = "file")
ctx_for :: proc(u: string, site := Site_Context.Same_Site, http := true) -> Context {
	parsed, _ := url.parse(u, nil, context.temp_allocator)
	return Context{url = parsed, site_context = site, http_api = http, now_ms = NOW}
}

@(private = "file")
cookie_header :: proc(j: ^Jar, u: string, site := Site_Context.Same_Site, http := true) -> string {
	return header_for(j, ctx_for(u, site, http), context.temp_allocator)
}

@(test)
cookie_dates :: proc(t: ^testing.T) {
	ms, ok := parse_cookie_date("Wed, 09 Jun 2021 10:18:14 GMT")
	testing.expect(t, ok)
	testing.expect_value(t, ms, i64(1623233894000))
	ms, ok = parse_cookie_date("Sunday, 06-Nov-94 08:49:37 GMT")   // two-digit year => 1994
	testing.expect(t, ok)
	testing.expect_value(t, ms, i64(784111777000))
	ms, ok = parse_cookie_date("Sun Nov  6 08:49:37 1994")          // asctime
	testing.expect(t, ok)
	testing.expect_value(t, ms, i64(784111777000))
	_, ok = parse_cookie_date("Wed, 31 Feb 2021 10:18:14 GMT")
	testing.expect(t, !ok, "invalid day for the month")
	_, ok = parse_cookie_date("garbage")
	testing.expect(t, !ok)
	_, ok = parse_cookie_date("Wed, 09 Jun 2021 25:18:14 GMT")
	testing.expect(t, !ok, "hour out of range")
}

@(test)
matching_rules :: proc(t: ^testing.T) {
	testing.expect(t, domain_match("www.example.com", "example.com"))
	testing.expect(t, domain_match("example.com", "example.com"))
	testing.expect(t, !domain_match("badexample.com", "example.com"))
	testing.expect(t, !domain_match("192.168.0.1", "0.1"), "IP hosts never domain-match")
	testing.expect_value(t, default_path("/a/b/c"), "/a/b")
	testing.expect_value(t, default_path("/a"), "/")
	testing.expect_value(t, default_path(""), "/")
	testing.expect(t, path_match("/a/b", "/a"))
	testing.expect(t, path_match("/a/b", "/a/"))
	testing.expect(t, !path_match("/ab", "/a"))
	testing.expect(t, path_match("/", "/"))
}

@(test)
parse_attributes :: proc(t: ^testing.T) {
	p, ok := parse_default("sid=abc123; Path=/app; Domain=.Example.com; Secure; HttpOnly; SameSite=Strict; Max-Age=60")
	testing.expect(t, ok)
	testing.expect_value(t, p.cookie.name, "sid")
	testing.expect_value(t, p.cookie.value, "abc123")
	testing.expect_value(t, p.path_attr, "/app")
	testing.expect_value(t, p.domain_attr, "Example.com")
	testing.expect(t, p.cookie.secure && p.cookie.http_only)
	testing.expect_value(t, p.cookie.same_site, Same_Site.Strict)
	testing.expect_value(t, p.max_age_ms, i64(60_000))

	p, ok = parse_default("novalue")
	testing.expect(t, ok)
	testing.expect_value(t, p.cookie.name, "")
	testing.expect_value(t, p.cookie.value, "novalue")

	_, ok = parse_default("=")
	testing.expect(t, !ok)
	_, ok = parse_default(strings.concatenate({strings.repeat("a", 5000, context.temp_allocator), "=b"}, context.temp_allocator))
	testing.expect(t, !ok, "name+value over 4096 bytes")
	p, _ = parse_default("a=b; Path=relative; Domain=")
	testing.expect(t, !p.has_path && !p.has_domain, "invalid Path and empty Domain are ignored")
	p, _ = parse_default("a=b; Max-Age=-5")
	testing.expect(t, p.max_age_set && p.max_age_ms == 0)
}

@(test)
store_and_send :: proc(t: ^testing.T) {
	j := jar_make()
	defer jar_destroy(&j)
	st := ctx_for("https://shop.example.com/cart/view")
	testing.expect_value(t, store(&j, "a=1", st), Store_Result.Stored)                              // host-only, path /cart
	testing.expect_value(t, store(&j, "b=2; Domain=example.com; Path=/", st), Store_Result.Stored)
	testing.expect_value(t, store(&j, "c=3; Path=/other", st), Store_Result.Stored)

	testing.expect_value(t, cookie_header(&j, "https://shop.example.com/cart/x"), "a=1; b=2")   // longer path first
	testing.expect_value(t, cookie_header(&j, "https://www.example.com/"), "b=2")               // domain cookie only
	testing.expect_value(t, cookie_header(&j, "https://shop.example.com/other"), "c=3; b=2")
	testing.expect_value(t, cookie_header(&j, "https://evil.com/"), "")

	// replacement keeps one cookie per (name, domain, path)
	testing.expect_value(t, store(&j, "a=updated", st), Store_Result.Replaced)
	testing.expect_value(t, count(&j), 3)
}

@(test)
domain_attribute_security :: proc(t: ^testing.T) {
	j := jar_make()
	defer jar_destroy(&j)
	st := ctx_for("https://www.example.co.uk/")
	testing.expect_value(t, store(&j, "x=1; Domain=co.uk", st), Store_Result.Rejected_Domain)              // public suffix
	testing.expect_value(t, store(&j, "x=1; Domain=other.co.uk", st), Store_Result.Rejected_Domain)        // not a parent
	testing.expect_value(t, store(&j, "x=1; Domain=example.co.uk", st), Store_Result.Stored)
	st2 := ctx_for("https://user.github.io/")
	testing.expect_value(t, store(&j, "y=1; Domain=github.io", st2), Store_Result.Rejected_Domain)
	st3 := ctx_for("http://192.168.0.5/")
	testing.expect_value(t, store(&j, "z=1; Domain=0.5", st3), Store_Result.Rejected_Domain)
	testing.expect_value(t, store(&j, "z=1", st3), Store_Result.Stored)
	// a host that is itself a public suffix may only set host-only cookies
	st4 := ctx_for("https://github.io/")
	testing.expect_value(t, store(&j, "w=1; Domain=github.io", st4), Store_Result.Stored)
	testing.expect_value(t, cookie_header(&j, "https://user.github.io/"), "")
}

@(test)
secure_and_prefixes :: proc(t: ^testing.T) {
	j := jar_make()
	defer jar_destroy(&j)
	plain := ctx_for("http://example.com/")
	secure := ctx_for("https://example.com/")
	testing.expect_value(t, store(&j, "s=1; Secure", plain), Store_Result.Rejected_Secure_Origin)
	testing.expect_value(t, store(&j, "s=1; Secure", secure), Store_Result.Stored)
	testing.expect_value(t, cookie_header(&j, "http://example.com/"), "")   // Secure cookies are not sent over http
	testing.expect_value(t, cookie_header(&j, "https://example.com/"), "s=1")
	// an insecure origin cannot overwrite or shadow a Secure cookie
	testing.expect_value(t, store(&j, "s=evil", plain), Store_Result.Rejected_Secure_Overwrite)
	testing.expect_value(t, store(&j, "s=evil; Path=/sub", plain), Store_Result.Rejected_Secure_Overwrite)

	testing.expect_value(t, store(&j, "__Secure-id=1", secure), Store_Result.Rejected_Prefix)
	testing.expect_value(t, store(&j, "__Secure-id=1; Secure", secure), Store_Result.Stored)
	testing.expect_value(t, store(&j, "__secure-low=1", secure), Store_Result.Rejected_Prefix)   // prefix match is case-insensitive
	testing.expect_value(t, store(&j, "__Host-id=1; Secure; Path=/", secure), Store_Result.Stored)
	testing.expect_value(t, store(&j, "__Host-d=1; Secure; Path=/; Domain=example.com", secure), Store_Result.Rejected_Prefix)
	testing.expect_value(t, store(&j, "__Host-p=1; Secure; Path=/x", secure), Store_Result.Rejected_Prefix)

	// localhost is a secure context: Secure cookies work for development
	lh := ctx_for("http://localhost:8000/")
	testing.expect_value(t, store(&j, "dev=1; Secure", lh), Store_Result.Stored)
}

@(test)
same_site_semantics :: proc(t: ^testing.T) {
	j := jar_make()
	defer jar_destroy(&j)
	st := ctx_for("https://example.com/")
	store(&j, "strict=1; SameSite=Strict", st)
	store(&j, "lax=1; SameSite=Lax", st)
	store(&j, "none=1; SameSite=None; Secure", st)
	store(&j, "default=1", st)   // unspecified behaves as Lax

	testing.expect_value(t, cookie_header(&j, "https://example.com/", .Same_Site), "strict=1; lax=1; none=1; default=1")
	testing.expect_value(t, cookie_header(&j, "https://example.com/", .Cross_Site_Top_Level_Safe), "lax=1; none=1; default=1")
	testing.expect_value(t, cookie_header(&j, "https://example.com/", .Cross_Site), "none=1")

	testing.expect_value(t, store(&j, "x=1; SameSite=None", st), Store_Result.Rejected_Same_Site)   // None requires Secure
	cross := ctx_for("https://example.com/", .Cross_Site)
	testing.expect_value(t, store(&j, "y=1", cross), Store_Result.Rejected_Same_Site)   // default Lax cannot be set cross-site
	testing.expect_value(t, store(&j, "y=1; SameSite=None; Secure", cross), Store_Result.Stored)
}

@(test)
http_only_and_script_access :: proc(t: ^testing.T) {
	j := jar_make()
	defer jar_destroy(&j)
	http := ctx_for("https://example.com/")
	script := ctx_for("https://example.com/", .Same_Site, false)
	testing.expect_value(t, store(&j, "h=1; HttpOnly", http), Store_Result.Stored)
	testing.expect_value(t, store(&j, "v=2", http), Store_Result.Stored)
	testing.expect_value(t, cookie_header(&j, "https://example.com/", .Same_Site, false), "v=2")   // script cannot read HttpOnly
	testing.expect_value(t, store(&j, "h=pwned", script), Store_Result.Rejected_Http_Only)   // script cannot overwrite HttpOnly
	testing.expect_value(t, store(&j, "n=1; HttpOnly", script), Store_Result.Rejected_Http_Only)   // script cannot create HttpOnly
	testing.expect_value(t, cookie_header(&j, "https://example.com/"), "h=1; v=2")
}

@(test)
expiry :: proc(t: ^testing.T) {
	j := jar_make()
	defer jar_destroy(&j)
	st := ctx_for("https://example.com/")
	store(&j, "s=1", st)
	store(&j, "m=1; Max-Age=100", st)
	store(&j, "e=1; Expires=Wed, 09 Jun 2999 10:18:14 GMT", st)
	testing.expect_value(t, count(&j), 3)
	// later: Max-Age cookie expired, the others live
	later := ctx_for("https://example.com/")
	later.now_ms = NOW + 200_000
	testing.expect_value(t, header_for(&j, later, context.temp_allocator), "s=1; e=1")
	// Max-Age=0 deletes
	testing.expect_value(t, store(&j, "s=gone; Max-Age=0", st), Store_Result.Deleted)
	testing.expect_value(t, store(&j, "never=1; Max-Age=0", st), Store_Result.Rejected_Expired)
	// Expires in the past deletes too; Max-Age beats Expires
	testing.expect_value(t, store(&j, "e=1; Expires=Wed, 09 Jun 2001 10:18:14 GMT", st), Store_Result.Deleted)
	testing.expect_value(t, store(&j, "k=1; Max-Age=60; Expires=Wed, 09 Jun 2001 10:18:14 GMT", st), Store_Result.Stored)
	// the 400-day cap
	store(&j, "long=1; Max-Age=999999999", st)
	for c in all(&j) { if c.name == "long" { testing.expect(t, c.expires_ms <= NOW + settings_default().max_age_ms) } }
}

@(test)
eviction :: proc(t: ^testing.T) {
	j := jar_make()
	defer jar_destroy(&j)
	j.settings.max_per_site = 5
	j.settings.max_total = 8
	for i in 0 ..< 20 {
		c := ctx_for("https://a.example.com/")
		c.now_ms = NOW + i64(i)
		store(&j, fmt.tprintf("c%02d=1", i), c)
	}
	n := 0
	for c in all(&j) { if strings.has_suffix(c.domain, "example.com") { n += 1 } }
	testing.expect_value(t, n, 5)                                       // per registrable domain
	// the oldest were evicted, the newest survive
	testing.expect(t, strings.contains(cookie_header(&j, "https://a.example.com/"), "c19=1"))
	testing.expect(t, !strings.contains(cookie_header(&j, "https://a.example.com/"), "c00=1"))
	for i in 0 ..< 10 {
		c := ctx_for("https://other.org/")
		c.now_ms = NOW + 100 + i64(i)
		store(&j, fmt.tprintf("x%02d=1", i), c)
	}
	testing.expect(t, count(&j) <= 8, "global limit")
}

@(test)
persistence_roundtrip :: proc(t: ^testing.T) {
	j := jar_make()
	defer jar_destroy(&j)
	st := ctx_for("https://example.com/")
	store(&j, "session=1", st)
	store(&j, "tab\tname=va%lue\nx; Max-Age=3600; Path=/p; Secure; HttpOnly; SameSite=Lax", ctx_for("https://example.com/p/"))
	path := "build/cookies_test.tsv"
	defer os.remove(path)
	testing.expect(t, save(&j, path, NOW))
	j2 := jar_make()
	defer jar_destroy(&j2)
	n, ok := load(&j2, path, NOW)
	testing.expect(t, ok)
	testing.expect_value(t, n, 0)   // the name above contains a control character: it was rejected, never stored
	store(&j, "persist=v%41; Max-Age=3600; Path=/p; Secure; HttpOnly; SameSite=Lax", ctx_for("https://example.com/p/"))
	testing.expect(t, save(&j, path, NOW))
	n, ok = load(&j2, path, NOW)
	testing.expect(t, ok)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, cookie_header(&j2, "https://example.com/p/x"), "persist=v%41")
	testing.expect_value(t, count(&j2), 1)   // the session cookie was not persisted
	n, ok = load(&j2, path, NOW + 4_000_000)
	testing.expect_value(t, n, 0)            // expired by then
}

@(test)
cookies_of_a_host_can_be_counted_and_cleared :: proc(t: ^testing.T) {
	j := jar_make()
	defer jar_destroy(&j)
	st := ctx_for("https://shop.example.com/")
	store(&j, "a=1", st)                              // host-only for shop.example.com
	store(&j, "b=2; Domain=example.com", st)          // applies to every subdomain
	store(&j, "c=3", ctx_for("https://other.org/"))
	testing.expect_value(t, count_for_host(&j, "shop.example.com"), 2)
	testing.expect_value(t, count_for_host(&j, "www.example.com"), 1)   // only the domain cookie
	testing.expect_value(t, count_for_host(&j, "other.org"), 1)
	testing.expect_value(t, delete_for_host(&j, "shop.example.com"), 2)
	testing.expect_value(t, count(&j), 1)
}