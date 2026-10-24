package adblock

import "core:strings"
import "core:testing"

@(private = "file", init)
install_hook :: proc "contextless" () {
	suffix_labels_hook = proc(host: string) -> int { return strings.has_suffix(host, ".co.uk") ? 2 : 1 }
}

@(private = "file")
verdict :: proc(e: ^Engine, url, source: string, type: Resource, method := Method.Get) -> Verdict {
	r := make_request(url, source, type, method)
	return match(e, &r)
}

@(private = "file")
blocked :: proc(e: ^Engine, url, source: string, type: Resource) -> bool {
	v := verdict(e, url, source, type)
	return v.action == .Block || v.action == .Redirect
}

@(test)
test_host_anchor :: proc(t: ^testing.T) {
	e := engine_from_text("||ads.example.com^\n||tracker.net^$third-party\n")
	defer engine_destroy(e)
	testing.expect(t, blocked(e, "https://ads.example.com/x.js", "https://site.org/", .Script))
	testing.expect(t, blocked(e, "https://sub.ads.example.com/x.js", "https://site.org/", .Script))
	testing.expect(t, !blocked(e, "https://example.com/x.js", "https://site.org/", .Script))
	testing.expect(t, !blocked(e, "https://notads.example.com/", "https://site.org/", .Script))
	testing.expect(t, !blocked(e, "https://ads.example.com.evil.org/", "https://site.org/", .Script))
	testing.expect(t, blocked(e, "https://tracker.net/p", "https://site.org/", .Image))
	testing.expect(t, !blocked(e, "https://tracker.net/p", "https://www.tracker.net/", .Image))
}

@(test)
test_patterns :: proc(t: ^testing.T) {
	e := engine_from_text("/banner/*/img^\n||example.com/ads/*.gif\n|http://exact.com/|\n/adframe.\n&adtype=\n")
	defer engine_destroy(e)
	src := "https://site.org/"
	testing.expect(t, blocked(e, "https://x.org/banner/300/img?x=1", src, .Image))
	testing.expect(t, blocked(e, "https://x.org/banner/300/img", src, .Image))
	testing.expect(t, !blocked(e, "https://x.org/banner/300/imgs", src, .Image))
	testing.expect(t, blocked(e, "https://example.com/ads/foo/bar.gif", src, .Image))
	testing.expect(t, !blocked(e, "https://other.com/?u=example.com/ads/foo.gif", src, .Image))
	testing.expect(t, blocked(e, "http://exact.com/", src, .Document) == false)   // document is not a default type
	testing.expect(t, blocked(e, "http://exact.com/", src, .Image))
	testing.expect(t, !blocked(e, "http://exact.com/a", src, .Image))
	testing.expect(t, blocked(e, "https://a.com/adframe.html", src, .Subdocument))
	testing.expect(t, blocked(e, "https://a.com/x?y=1&adtype=top", src, .Xhr))
}

@(test)
test_types_and_party :: proc(t: ^testing.T) {
	e := engine_from_text("||cdn.example.com^$script\n||img.example.com^$image,third-party\n||media.example.com^$~script,~image\n||fp.example.com^$first-party\n")
	defer engine_destroy(e)
	src := "https://site.org/"
	testing.expect(t, blocked(e, "https://cdn.example.com/a.js", src, .Script))
	testing.expect(t, !blocked(e, "https://cdn.example.com/a.png", src, .Image))
	testing.expect(t, blocked(e, "https://img.example.com/a.png", src, .Image))
	testing.expect(t, !blocked(e, "https://img.example.com/a.png", "https://example.com/", .Image))
	testing.expect(t, blocked(e, "https://media.example.com/a", src, .Media))
	testing.expect(t, !blocked(e, "https://media.example.com/a", src, .Script))
	testing.expect(t, blocked(e, "https://fp.example.com/a", "https://fp.example.com/", .Script))
	testing.expect(t, !blocked(e, "https://fp.example.com/a", src, .Script))
}

@(test)
test_domain_option :: proc(t: ^testing.T) {
	e := engine_from_text("/tracking.js$domain=a.com|b.org|~sub.a.com\n||ads.net^$domain=c.*\n")
	defer engine_destroy(e)
	u := "https://x.net/tracking.js"
	testing.expect(t, blocked(e, u, "https://a.com/", .Script))
	testing.expect(t, blocked(e, u, "https://www.a.com/", .Script))
	testing.expect(t, blocked(e, u, "https://b.org/p", .Script))
	testing.expect(t, !blocked(e, u, "https://sub.a.com/", .Script))
	testing.expect(t, !blocked(e, u, "https://d.com/", .Script))
	testing.expect(t, blocked(e, "https://ads.net/z", "https://c.com/", .Image))
	testing.expect(t, blocked(e, "https://ads.net/z", "https://c.co.uk/", .Image))   // the entity c.* spans the public suffix co.uk
	testing.expect(t, !blocked(e, "https://ads.net/z", "https://d.com/", .Image))
}

@(test)
test_exceptions_and_important :: proc(t: ^testing.T) {
	e := engine_from_text("||ads.com^\n@@||ads.com/ok.js\n||imp.com^$important\n@@||imp.com^\n@@||imp.com^$important,domain=safe.org\n")
	defer engine_destroy(e)
	src := "https://site.org/"
	testing.expect(t, blocked(e, "https://ads.com/x.js", src, .Script))
	v := verdict(e, "https://ads.com/ok.js", src, .Script)
	testing.expect_value(t, v.action, Action.Exception)
	testing.expect(t, blocked(e, "https://imp.com/x", src, .Script))
	testing.expect(t, !blocked(e, "https://imp.com/x", "https://safe.org/", .Script))
}

@(test)
test_badfilter :: proc(t: ^testing.T) {
	e := engine_from_text("||ads.com^$script\n||ads.com^$script,badfilter\n||other.com^\n")
	defer engine_destroy(e)
	testing.expect(t, !blocked(e, "https://ads.com/x.js", "https://site.org/", .Script))
	testing.expect(t, blocked(e, "https://other.com/x.js", "https://site.org/", .Script))
}

@(test)
test_regex_filters :: proc(t: ^testing.T) {
	e := engine_from_text("/\\/ads?\\/\\d+\\.js/\n/^https?:\\/\\/[a-z]+\\.cdn\\.example\\.com\\//$image\n")
	defer engine_destroy(e)
	src := "https://site.org/"
	testing.expect(t, blocked(e, "https://x.org/ad/123.js", src, .Script))
	testing.expect(t, blocked(e, "https://x.org/ads/9.js", src, .Script))
	testing.expect(t, !blocked(e, "https://x.org/ads/x.js", src, .Script))
	testing.expect(t, blocked(e, "https://foo.cdn.example.com/a.png", src, .Image))
	testing.expect(t, !blocked(e, "https://foo1.cdn.example.com/a.png", src, .Image))
}

@(test)
test_regex_engine :: proc(t: ^testing.T) {
	cases := []struct { re, text: string, want: bool }{
		{"abc", "xxabcxx", true}, {"a.c", "abc", true}, {"a.c", "ac", false}, {"^abc", "abcd", true}, {"^abc", "xabc", false},
		{"abc$", "xabc", true}, {"abc$", "abcx", false}, {"a|b", "xbx", true}, {"(ab)+c", "ababc", true}, {"(ab)+c", "ac", false},
		{"a{2,3}b", "aab", true}, {"a{2,3}b", "ab", false}, {"a{2}b", "aaab", true}, {"[a-c]+d", "xabd", true}, {"[^a-c]d", "ad", false},
		{"\\d+", "abc123", true}, {"\\d+", "abc", false}, {"\\bfoo\\b", "a foo b", true}, {"\\bfoo\\b", "afoob", false},
		{"colou?r", "color", true}, {"colou?r", "colour", true}, {"foo(?=bar)", "foobar", true}, {"foo(?=bar)", "foobaz", false},
		{"foo(?!bar)", "foobaz", true}, {"foo(?!bar)", "foobar", false}, {"(a*)*b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", false},
		{"(a|aa)+$", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab", false}, {"\\.js$", "a.js", true}, {"[\\w.]+@", "me.x@", true},
	}
	for c in cases {
		re, ok := regex_compile(c.re, false)
		testing.expectf(t, ok, "compile %q", c.re)
		if !ok { continue }
		s: Regex_Scratch
		got := regex_match(&re, &s, c.text)
		testing.expectf(t, got == c.want, "/%s/ on %q: got %v want %v", c.re, c.text, got, c.want)
		regex_scratch_destroy(&s)
		regex_destroy(&re)
	}
	for bad in ([]string{"(", "a{3,2}", "[a", "*a", "\\1", "(?<=a)b", "a**", "a{1001}"}) {
		re, ok := regex_compile(bad, false)
		if ok { regex_destroy(&re) }
		testing.expectf(t, !ok, "%q must not compile", bad)
	}
	re, ok := regex_compile("HeLLo", true)
	testing.expect(t, ok)
	s: Regex_Scratch
	testing.expect(t, regex_match(&re, &s, "say hello"))
	regex_scratch_destroy(&s)
	regex_destroy(&re)
}

@(test)
test_redirect :: proc(t: ^testing.T) {
	e := engine_from_text("||ads.com/ga.js$script,redirect=google-analytics.com/ga.js\n||x.com^$redirect-rule=noop.js\n||x.com/block.js\n||z.com^$script,redirect=noop.js\n@@||z.com/ok.js$redirect=noop.js\n")
	defer engine_destroy(e)
	src := "https://site.org/"
	v := verdict(e, "https://ads.com/ga.js", src, .Script)
	testing.expect_value(t, v.action, Action.Redirect)
	testing.expect_value(t, v.resource, "google-analytics.com/ga.js")
	v = verdict(e, "https://x.com/block.js", src, .Script)
	testing.expect_value(t, v.action, Action.Redirect)
	testing.expect_value(t, v.resource, "noop.js")
	v = verdict(e, "https://x.com/other.js", src, .Script)
	testing.expect_value(t, v.action, Action.Allow)   // a redirect-rule alone does not block
	v = verdict(e, "https://z.com/a.js", src, .Script)
	testing.expect_value(t, v.action, Action.Redirect)
	v = verdict(e, "https://z.com/ok.js", src, .Script)
	testing.expect_value(t, v.action, Action.Block)   // the redirect is cancelled, the block stays
}

@(test)
test_removeparam_and_csp :: proc(t: ^testing.T) {
	e := engine_from_text("||shop.com^$removeparam=utm_source\n||shop.com^$removeparam=/^utm_/i\n@@||shop.com/keep$removeparam\n||news.com^$csp=script-src 'none'\n||news.com^$removeparam\n")
	defer engine_destroy(e)
	r := make_request("https://shop.com/p?a=1&utm_source=x&UTM_medium=y&b=2#frag", "https://site.org/", .Document)
	out, changed := rewrite_url(e, &r, context.temp_allocator)
	testing.expect(t, changed)
	testing.expect_value(t, out, "https://shop.com/p?a=1&b=2#frag")
	r2 := make_request("https://shop.com/keep?utm_source=x", "https://site.org/", .Document)
	_, changed2 := rewrite_url(e, &r2, context.temp_allocator)
	testing.expect(t, !changed2)
	r3 := make_request("https://news.com/a?x=1", "https://news.com/", .Document)
	out3, ch3 := rewrite_url(e, &r3, context.temp_allocator)
	testing.expect(t, ch3)
	testing.expect_value(t, out3, "https://news.com/a")
	pol := csp_directives(e, &r3, context.temp_allocator)
	testing.expect_value(t, len(pol), 1)
	if len(pol) == 1 { testing.expect_value(t, pol[0], "script-src 'none'") }
}

@(test)
test_page_flags :: proc(t: ^testing.T) {
	e := engine_from_text("@@||site.org^$generichide\n@@||all.org^$document\n@@||half.org^$elemhide,specifichide\n")
	defer engine_destroy(e)
	f, _ := page_flags(e, "https://www.site.org/page")
	testing.expect_value(t, f, Page_Flags{.Generichide})
	f, _ = page_flags(e, "https://all.org/")
	testing.expect(t, .Document in f)
	f, _ = page_flags(e, "https://half.org/")
	testing.expect_value(t, f, Page_Flags{.Elemhide, .Specifichide})
	f, _ = page_flags(e, "https://other.org/")
	testing.expect_value(t, f, Page_Flags{})
}

@(test)
test_cosmetic :: proc(t: ^testing.T) {
	text := `##.banner
example.com###sidebar-ad
example.com,~sub.example.com##div.promo:has-text(Ad)
##a[href*="/click?"]
~news.org##.sponsored
example.com#@#.banner
google.*##+js(set-constant, x, true)
example.com##.x:style(display: none !important)
`
	e := engine_from_text(text)
	defer engine_destroy(e)
	c := cosmetic_for_host(e, "example.com", {})
	defer cosmetic_destroy(&c)
	sels := make([dynamic]string, context.temp_allocator)
	for id in c.active { append(&sels, cosmetic_filter(e, id).selector) }
	has :: proc(l: [dynamic]string, s: string) -> bool { for x in l { if x == s { return true } }; return false }
	testing.expect(t, has(sels, "#sidebar-ad"))
	testing.expect(t, has(sels, "div.promo:has-text(Ad)"))
	testing.expect(t, has(sels, "a[href*=\"/click?\"]"))
	testing.expect(t, has(sels, ".x:style(display: none !important)"))
	keyed := make([dynamic]u32, context.temp_allocator)
	cosmetic_keyed(e, &c, class_key('.', "banner"), &keyed)
	testing.expect_value(t, len(keyed), 0)   // excepted on example.com
	cosmetic_keyed(e, &c, class_key('.', "sponsored"), &keyed)
	testing.expect_value(t, len(keyed), 1)
	c2 := cosmetic_for_host(e, "other.com", {})
	defer cosmetic_destroy(&c2)
	keyed2 := make([dynamic]u32, context.temp_allocator)
	cosmetic_keyed(e, &c2, class_key('.', "banner"), &keyed2)
	testing.expect_value(t, len(keyed2), 1)
	c3 := cosmetic_for_host(e, "news.org", {})
	defer cosmetic_destroy(&c3)
	k3 := make([dynamic]u32, context.temp_allocator)
	cosmetic_keyed(e, &c3, class_key('.', "sponsored"), &k3)
	testing.expect_value(t, len(k3), 0)
	c4 := cosmetic_for_host(e, "www.google.co.uk", {})
	defer cosmetic_destroy(&c4)
	found := false
	for id in c4.active { if .Scriptlet in cosmetic_filter(e, id).flags { found = true } }
	testing.expect(t, found)
}

@(test)
test_preprocessor :: proc(t: ^testing.T) {
	text := `!#if env_chromium
||yes.com^
!#else
||no.com^
!#endif
!#if env_firefox
||ff.com^
!#endif
!#if ext_ublock && !env_firefox
||both.com^
!#endif
`
	e := engine_from_text(text)
	defer engine_destroy(e)
	s := "https://site.org/"
	testing.expect(t, blocked(e, "https://yes.com/", s, .Image))
	testing.expect(t, !blocked(e, "https://no.com/", s, .Image))
	testing.expect(t, !blocked(e, "https://ff.com/", s, .Image))
	testing.expect(t, blocked(e, "https://both.com/", s, .Image))
}

@(test)
test_hosts_format :: proc(t: ^testing.T) {
	e := engine_from_text("# a comment\n127.0.0.1 localhost\n0.0.0.0 bad.example.net\n0.0.0.0 worse.example.net # why\n")
	defer engine_destroy(e)
	testing.expect(t, blocked(e, "https://bad.example.net/x", "https://s.org/", .Script))
	testing.expect(t, blocked(e, "https://worse.example.net/x", "https://s.org/", .Script))
	testing.expect(t, !blocked(e, "https://localhost/x", "https://s.org/", .Script))
}

@(test)
test_denyallow_and_to :: proc(t: ^testing.T) {
	e := engine_from_text("*$script,3p,denyallow=cdn.good.com|api.good.com,domain=bad.org\n")
	defer engine_destroy(e)
	s := "https://bad.org/"
	testing.expect(t, blocked(e, "https://evil.net/a.js", s, .Script))
	testing.expect(t, !blocked(e, "https://cdn.good.com/a.js", s, .Script))
	testing.expect(t, !blocked(e, "https://evil.net/a.js", "https://fine.org/", .Script))
}

@(test)
test_invalid_lines :: proc(t: ^testing.T) {
	e := engine_from_text("||ok.com^\n$unknownoption\n||x.com^$nonsense\n||y.com^$cookie=x\n!comment\n[Adblock Plus 2.0]\n\n||z.com^$domain=\n")
	defer engine_destroy(e)
	testing.expect_value(t, engine_filter_count(e), 1)
	srcs := engine_sources(e, context.temp_allocator)
	testing.expect_value(t, len(srcs), 1)
	testing.expect(t, srcs[0].invalid >= 3)
}

@(test)
test_blob_roundtrip :: proc(t: ^testing.T) {
	blob := compile([]List_Text{{1, "a", "||ads.com^\n##.ad\n"}, {2, "b", "||trk.net^$script\n"}})
	e, err := engine_load(blob, true, true)
	testing.expect_value(t, err, Load_Error.None)
	if e == nil { return }
	defer engine_destroy(e)
	testing.expect(t, blocked(e, "https://trk.net/a.js", "https://s.org/", .Script))
	srcs := engine_sources(e, context.temp_allocator)
	testing.expect_value(t, len(srcs), 2)
	// a corrupted blob is refused
	bad := make([]byte, len(blob) + 8)
	words := make([]u64, (len(blob) + 7) / 8)
	copy(([^]byte)(raw_data(words))[:len(blob)], blob)
	cb := ([^]byte)(raw_data(words))[:len(blob)]
	cb[len(cb) - 3] ~= 0xff
	_, err2 := engine_load(cb, false, true)
	testing.expect_value(t, err2, Load_Error.Bad_Checksum)
	delete(bad); delete(words)
}

@(test)
test_pathological :: proc(t: ^testing.T) {
	e := engine_from_text("||a.com^\n/(x+x+)+y/\n*$script,domain=zz.com\n")
	defer engine_destroy(e)
	long := strings.repeat("x", 5000, context.temp_allocator)
	_ = blocked(e, strings.concatenate({"https://q.org/", long}, context.temp_allocator), "https://s.org/", .Script)
	_ = blocked(e, "", "", .Script)
	_ = blocked(e, "https://", "", .Script)
	_ = blocked(e, "data:text/plain,hello", "", .Script)
	many := strings.repeat("a/", 3000, context.temp_allocator)
	_ = blocked(e, strings.concatenate({"https://q.org/", many}, context.temp_allocator), "https://s.org/", .Script)
}

@(test)
test_replace_filters :: proc(t: ^testing.T) {
	e := engine_from_text("||api.test/v1/*$xhr,replace=/\"ads\":\\[.*?\\]/\"ads\":[]/g\n@@||api.test/v1/keep$replace\n||all.test^$replace=/x/y/\n@@||all.test^$replace=/x/y/\n||doc.test^$replace=/a/b/i\n")
	defer engine_destroy(e)
	testing.expect(t, has_replace_filters(e))
	r := make_request("https://api.test/v1/list", "https://site.org/", .Xhr)
	args := replace_args(e, &r, context.temp_allocator)
	testing.expect_value(t, len(args), 1)
	if len(args) == 1 { testing.expect_value(t, args[0], "/\"ads\":\\[.*?\\]/\"ads\":[]/g") }
	r2 := make_request("https://api.test/v1/keep", "https://site.org/", .Xhr)
	testing.expect_value(t, len(replace_args(e, &r2, context.temp_allocator)), 0)
	r3 := make_request("https://all.test/a", "https://site.org/", .Xhr)
	testing.expect_value(t, len(replace_args(e, &r3, context.temp_allocator)), 0)
	r4 := make_request("https://doc.test/", "https://doc.test/", .Document)
	testing.expect_value(t, len(replace_args(e, &r4, context.temp_allocator)), 1)
	r5 := make_request("https://other.test/", "https://site.org/", .Xhr)
	testing.expect_value(t, len(replace_args(e, &r5, context.temp_allocator)), 0)
}
