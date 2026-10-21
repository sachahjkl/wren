package httpcache

import "core:strings"
import "core:testing"
import "wb:http"

@(private = "file")
hdrs :: proc(block: string) -> http.Headers { return http.parse_header_block(block, context.temp_allocator) }

@(private = "file")
dated :: proc(t: i64, rest: string) -> string { return strings.concatenate({"Date: ", format_http_date(t), rest}, context.temp_allocator) }

@(private = "file")
FS :: Freshness_Settings{heuristic_fraction = 0.1, heuristic_max_s = 7 * 86400}

@(test)
test_cache_control_parse :: proc(t: ^testing.T) {
	cc := parse_cache_control(`public, max-age=3600, stale-while-revalidate=60, immutable, no-cache="set-cookie, foo", must-revalidate`)
	testing.expect_value(t, cc.max_age, 3600)
	testing.expect_value(t, cc.stale_while_revalidate, 60)
	testing.expect(t, cc.public && cc.immutable && cc.no_cache && cc.must_revalidate)
	testing.expect_value(t, cc.s_maxage, -1)
	// invalid delta-seconds: the most cautious value; first occurrence wins; case-insensitive names
	bad := parse_cache_control("MAX-AGE=abc, max-age=100")
	testing.expect_value(t, bad.max_age, 0)
	big := parse_cache_control("max-age=99999999999999")
	testing.expect_value(t, big.max_age, DELTA_MAX)
	q := parse_cache_control(`max-age="60"`)
	testing.expect_value(t, q.max_age, 60)
	ms := parse_cache_control("max-stale")
	testing.expect_value(t, ms.max_stale, max(i64))
	empty := parse_cache_control("")
	testing.expect(t, empty.max_age == -1 && !empty.no_store)
}

@(test)
test_http_dates :: proc(t: ^testing.T) {
	a, ok1 := parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT")
	b, ok2 := parse_http_date("Sunday, 06-Nov-94 08:49:37 GMT")
	c, ok3 := parse_http_date("Sun Nov  6 08:49:37 1994")
	testing.expect(t, ok1 && ok2 && ok3)
	testing.expect_value(t, a, 784111777)
	testing.expect_value(t, b, a)
	testing.expect_value(t, c, a)
	_, bad := parse_http_date("0")
	testing.expect(t, !bad)
	testing.expect_value(t, format_http_date(784111777), "Sun, 06 Nov 1994 08:49:37 GMT")
	testing.expect_value(t, format_http_date(0), "Thu, 01 Jan 1970 00:00:00 GMT")
	testing.expect_value(t, format_http_date(951782400), "Tue, 29 Feb 2000 00:00:00 GMT")
}

@(test)
test_freshness_lifetime :: proc(t: ^testing.T) {
	date :: "Date: Sun, 06 Nov 1994 08:49:37 GMT\r\n"
	l, h := freshness_lifetime(200, hdrs(date + "Cache-Control: max-age=60\r\nExpires: Sun, 06 Nov 1994 10:00:00 GMT\r\n"), parse_cache_control("max-age=60"), FS)
	testing.expect(t, l == 60 && !h)   // max-age wins over Expires
	r := hdrs(date + "Expires: Sun, 06 Nov 1994 08:59:37 GMT\r\n")
	l, h = freshness_lifetime(200, r, cache_control_of(r), FS)
	testing.expect(t, l == 600 && !h)
	r = hdrs(date + "Expires: 0\r\n")   // invalid: already expired
	l, _ = freshness_lifetime(200, r, cache_control_of(r), FS)
	testing.expect_value(t, l, 0)
	// heuristic: 10 % of Date - Last-Modified (1000 s -> 100 s)
	r = hdrs(date + "Last-Modified: Sun, 06 Nov 1994 08:32:57 GMT\r\n")
	l, h = freshness_lifetime(200, r, cache_control_of(r), FS)
	testing.expect(t, l == 100 && h)
	// not heuristically cacheable (302) unless public
	l, _ = freshness_lifetime(302, r, cache_control_of(r), FS)
	testing.expect_value(t, l, 0)
	r = hdrs(date + "Last-Modified: Sun, 06 Nov 1994 08:32:57 GMT\r\nCache-Control: public\r\n")
	l, _ = freshness_lifetime(302, r, cache_control_of(r), FS)
	testing.expect_value(t, l, 100)
	// capped
	r = hdrs(date + "Last-Modified: Sun, 06 Nov 1984 08:49:37 GMT\r\n")
	l, _ = freshness_lifetime(200, r, cache_control_of(r), FS)
	testing.expect_value(t, l, 7 * 86400)
}

@(test)
test_current_age :: proc(t: ^testing.T) {
	// generated at 1000, requested at 1005, received at 1010 with Age 3, now 1100
	r := hdrs(dated(1000, "\r\nAge: 3\r\n"))
	age := current_age(r, {request_time = 1005, response_time = 1010}, 1100)
	// apparent 10, corrected age value 3 + 5 = 8, initial 10, resident 90
	testing.expect_value(t, age, 100)
	// a clock-skewed Date in the future: apparent age 0
	r = hdrs(dated(5000, "\r\n"))
	testing.expect_value(t, current_age(r, {request_time = 1000, response_time = 1000}, 1010), 10)
	// a malformed Age is ignored
	r = hdrs(dated(1000, "\r\nAge: abc\r\n"))
	testing.expect_value(t, current_age(r, {request_time = 1000, response_time = 1000}, 1000), 0)
}

@(test)
test_judge :: proc(t: ^testing.T) {
	r := hdrs(dated(1000, "\r\nCache-Control: max-age=100, stale-while-revalidate=50\r\n"))
	times := Response_Times{1000, 1000}
	none := parse_cache_control("")
	testing.expect_value(t, judge(200, r, times, none, 1050, FS).use, Use.Fresh)
	testing.expect_value(t, judge(200, r, times, none, 1120, FS).use, Use.Stale_Revalidate)
	testing.expect_value(t, judge(200, r, times, none, 1120, FS, allow_swr = false).use, Use.Validate)
	testing.expect_value(t, judge(200, r, times, none, 1200, FS).use, Use.Validate)
	// request directives
	testing.expect_value(t, judge(200, r, times, parse_cache_control("no-cache"), 1010, FS).use, Use.Validate)
	testing.expect_value(t, judge(200, r, times, parse_cache_control("max-age=0"), 1010, FS).use, Use.Validate)
	testing.expect_value(t, judge(200, r, times, parse_cache_control("min-fresh=80"), 1050, FS).use, Use.Validate)
	testing.expect_value(t, judge(200, r, times, parse_cache_control("max-stale=500"), 1300, FS).use, Use.Fresh)
	// must-revalidate forbids serving stale, even with max-stale
	m := hdrs(dated(1000, "\r\nCache-Control: max-age=10, must-revalidate\r\n"))
	testing.expect_value(t, judge(200, m, times, parse_cache_control("max-stale"), 1100, FS).use, Use.Validate)
	// no-cache response: always validated
	n := hdrs(dated(1000, "\r\nCache-Control: no-cache, max-age=1000\r\n"))
	testing.expect_value(t, judge(200, n, times, none, 1001, FS).use, Use.Validate)
}

@(test)
test_storable :: proc(t: ^testing.T) {
	ok := hdrs("Cache-Control: max-age=60\r\n")
	none := parse_cache_control("")
	testing.expect_value(t, storable("GET", 200, none, cache_control_of(ok), ok, false, false), Store_Verdict.Store)
	testing.expect_value(t, storable("POST", 200, none, cache_control_of(ok), ok, false, false), Store_Verdict.Method)
	testing.expect_value(t, storable("GET", 206, none, cache_control_of(ok), ok, false, false), Store_Verdict.Status)
	ns := hdrs("Cache-Control: no-store, max-age=60\r\n")
	testing.expect_value(t, storable("GET", 200, none, cache_control_of(ns), ns, false, false), Store_Verdict.No_Store)
	testing.expect_value(t, storable("GET", 200, parse_cache_control("no-store"), cache_control_of(ok), ok, false, false), Store_Verdict.No_Store)
	testing.expect_value(t, storable("GET", 200, none, cache_control_of(ok), ok, true, false), Store_Verdict.Authorization)
	pub := hdrs("Cache-Control: public, max-age=60\r\n")
	testing.expect_value(t, storable("GET", 200, none, cache_control_of(pub), pub, true, false), Store_Verdict.Store)
	star := hdrs("Cache-Control: max-age=60\r\nVary: Accept, *\r\n")
	testing.expect_value(t, storable("GET", 200, none, cache_control_of(star), star, false, false), Store_Verdict.Vary_Star)
	bare := hdrs("Content-Type: text/html\r\n")
	testing.expect_value(t, storable("GET", 200, none, cache_control_of(bare), bare, false, false), Store_Verdict.No_Freshness)
	testing.expect_value(t, storable("GET", 200, none, cache_control_of(bare), bare, false, true), Store_Verdict.Store)
	etag := hdrs("ETag: \"x\"\r\n")
	testing.expect_value(t, storable("GET", 200, none, cache_control_of(etag), etag, false, false), Store_Verdict.Store)
}

@(test)
test_merge_304 :: proc(t: ^testing.T) {
	stored := hdrs("Content-Type: text/css\r\nContent-Length: 10\r\nETag: \"a\"\r\nCache-Control: max-age=10\r\nX-Old: 1\r\n")
	fresh := hdrs("ETag: \"b\"\r\nCache-Control: max-age=99\r\nContent-Length: 0\r\nSet-Cookie: a=b\r\nConnection: close\r\n")
	m := merge_304(stored, fresh, context.temp_allocator)
	v, _ := http.get_header(m, "cache-control")
	testing.expect_value(t, v, "max-age=99")
	v, _ = http.get_header(m, "etag")
	testing.expect_value(t, v, `"b"`)
	v, _ = http.get_header(m, "content-length")
	testing.expect_value(t, v, "10")   // the stored body's framing stays
	testing.expect(t, http.has_header(m, "x-old"))
	testing.expect(t, !http.has_header(m, "set-cookie") && !http.has_header(m, "connection"))
}

@(test)
test_vary :: proc(t: ^testing.T) {
	r := hdrs("Vary: Accept-Language, origin\r\nVary: accept-language\r\n")
	names, star := vary_names(r)
	testing.expect(t, !star && len(names) == 2 && names[0] == "accept-language" && names[1] == "origin")
	req := hdrs("Accept-Language: fr ,  en\r\n")
	v, present := vary_value(req, "accept-language")
	testing.expect(t, present && v == "fr,en")
	_, present = vary_value(req, "origin")
	testing.expect(t, !present)
}
