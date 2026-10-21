// Package httpcache: the browser's HTTP cache (RFC 9111, as the Fetch Standard uses it), shared by every document of
// a profile. This file is the rule book, pure functions of headers and clocks: what may be stored, how long a stored
// response stays fresh, how old it is, whether a stored response fits a new request (Vary), how a 304 refreshes it.
// store.odin keeps the entries (memory, LRU), disk.odin writes them to the profile; package fetch decides, per request
// and cache mode, when to look and what to do with what it finds (fetch/http_cache.odin).
//
// The cache is a private one (a browser's): s-maxage and proxy-revalidate concern shared caches and are ignored,
// `private` responses are stored. Times are unix seconds (HTTP dates have no finer grain) unless named `_ms`.
package httpcache

import "core:strconv"
import "core:strings"
import "wb:cookies"
import "wb:http"

// The directives of a Cache-Control header (RFC 9111 §5.2), request and response ones together. Unknown directives
// are ignored; a directive given twice keeps its first value; an invalid delta-seconds makes the directive count as
// present with the most cautious value (max-age=abc is max-age=0).
Cache_Control :: struct {
	max_age:                i64,    // -1: absent
	s_maxage:               i64,    // -1: absent (shared caches only; parsed for about:cache)
	stale_while_revalidate: i64,    // -1: absent
	stale_if_error:         i64,    // -1: absent
	max_stale:              i64,    // request: -1 absent, max(i64) "any staleness"
	min_fresh:              i64,    // request: -1 absent
	no_cache:               bool,   // response: with or without field names (a private cache revalidates either way)
	no_store:               bool,
	private:                bool,
	public:                 bool,
	must_revalidate:        bool,
	proxy_revalidate:       bool,
	immutable:              bool,
	only_if_cached:         bool,
	no_transform:           bool,
	must_understand:        bool,
}

DELTA_MAX :: i64(2147483648)   // RFC 9111 §1.2.2: larger delta-seconds are this

parse_cache_control :: proc(value: string) -> Cache_Control {
	cc := Cache_Control{max_age = -1, s_maxage = -1, stale_while_revalidate = -1, stale_if_error = -1, max_stale = -1, min_fresh = -1}
	seen: bit_set[0 ..< 16]
	rest := value
	for len(rest) > 0 {
		// one directive: token [ "=" ( token / quoted-string ) ], commas between (a quoted value may hold commas)
		rest = strings.trim_left(rest, " \t,")
		if rest == "" { break }
		i := 0
		for i < len(rest) && rest[i] != '=' && rest[i] != ',' { i += 1 }
		name := strings.trim_space(rest[:i])
		arg := ""
		has_arg := false
		rest = rest[i:]
		if len(rest) > 0 && rest[0] == '=' {
			rest = strings.trim_left(rest[1:], " \t")
			has_arg = true
			if len(rest) > 0 && rest[0] == '"' {
				j := 1
				for j < len(rest) && rest[j] != '"' { if rest[j] == '\\' { j += 1 }; j += 1 }
				arg = rest[1:min(j, len(rest))]
				rest = rest[min(j + 1, len(rest)):]
				if k := strings.index_byte(rest, ','); k >= 0 { rest = rest[k:] } else { rest = "" }
			} else {
				k := strings.index_byte(rest, ',')
				if k < 0 { k = len(rest) }
				arg = strings.trim_space(rest[:k])
				rest = rest[k:]
			}
		}
		lower := strings.to_lower(name, context.temp_allocator)
		delta :: proc(arg: string, has: bool) -> i64 {
			if !has { return 0 }
			n := 0
			for n < len(arg) && arg[n] >= '0' && arg[n] <= '9' { n += 1 }
			if n == 0 || n != len(arg) { return 0 }   // not delta-seconds: the most cautious reading
			if n > 10 { return DELTA_MAX }
			v, _ := strconv.parse_i64(arg)
			return min(v, DELTA_MAX)
		}
		once :: proc(seen: ^bit_set[0 ..< 16], bit: int) -> bool {
			if bit in seen^ { return false }
			seen^ += {bit}
			return true
		}
		switch lower {
		case "max-age":                if once(&seen, 0) { cc.max_age = delta(arg, has_arg) }
		case "s-maxage":               if once(&seen, 1) { cc.s_maxage = delta(arg, has_arg) }
		case "stale-while-revalidate": if once(&seen, 2) { cc.stale_while_revalidate = delta(arg, has_arg) }
		case "stale-if-error":         if once(&seen, 3) { cc.stale_if_error = delta(arg, has_arg) }
		case "max-stale":              if once(&seen, 4) { cc.max_stale = has_arg ? delta(arg, true) : max(i64) }
		case "min-fresh":              if once(&seen, 5) { cc.min_fresh = delta(arg, has_arg) }
		case "no-cache":               cc.no_cache = true
		case "no-store":               cc.no_store = true
		case "private":                cc.private = true
		case "public":                 cc.public = true
		case "must-revalidate":        cc.must_revalidate = true
		case "proxy-revalidate":       cc.proxy_revalidate = true
		case "immutable":              cc.immutable = true
		case "only-if-cached":         cc.only_if_cached = true
		case "no-transform":           cc.no_transform = true
		case "must-understand":        cc.must_understand = true
		}
	}
	return cc
}

// The Cache-Control of a header list (every Cache-Control field, joined).
cache_control_of :: proc(h: http.Headers) -> Cache_Control {
	v, _ := http.get_header(h, "cache-control")
	return parse_cache_control(v)
}

// An HTTP-date (IMF-fixdate, the obsolete RFC 850 and asctime forms, and what servers really send: the lenient cookie
// date algorithm reads them all). Unix seconds.
parse_http_date :: proc(s: string) -> (seconds: i64, ok: bool) {
	t := strings.trim_space(s)
	if t == "" { return 0, false }
	ms, good := cookies.parse_cookie_date(t)
	if !good { return 0, false }
	return ms / 1000, true
}

// Status codes a response may be stored for without explicit freshness (RFC 9110 §15.1 "heuristically cacheable").
is_heuristically_cacheable_status :: proc(status: int) -> bool {
	switch status {
	case 200, 203, 204, 206, 300, 301, 308, 404, 405, 410, 414, 501: return true
	}
	return false
}

// Statuses this cache understands well enough to store (RFC 9111 §3: "the response status code is final" and
// understood). 206 is not stored: partial content would need range merging (a later full request fetches it whole).
is_storable_status :: proc(status: int) -> bool {
	switch status {
	case 200, 203, 204, 300, 301, 302, 303, 307, 308, 404, 405, 410, 414, 501: return true
	}
	return false
}

Store_Verdict :: enum u8 {
	Store,
	Method,           // not GET (POST responses are only reused for history in other browsers; not here)
	Status,           // not final, partial, or not understood
	No_Store,         // Cache-Control: no-store on the request or the response
	Authorization,    // the request had credentials and the response does not say it may be shared
	No_Freshness,     // neither explicit freshness, a validator, nor heuristic freshness: nothing could ever reuse it
	Vary_Star,        // Vary: * never matches a later request
	Too_Large,
}

// RFC 9111 §3: may the response to this request be stored? `authorization`: the request carried an Authorization
// header. Entries without any freshness but with a validator are kept (they save the body on a 304); entries with
// neither are kept only when `keep_unvalidated` (back / forward navigations prefer the cache, as other browsers do).
storable :: proc(method: string, status: int, req_cc, resp_cc: Cache_Control, resp: http.Headers, authorization: bool, keep_unvalidated: bool) -> Store_Verdict {
	if method != "GET" { return .Method }
	if !is_storable_status(status) { return .Status }
	if req_cc.no_store || resp_cc.no_store { return .No_Store }
	if authorization && !(resp_cc.public || resp_cc.must_revalidate || resp_cc.s_maxage >= 0) { return .Authorization }
	if v, ok := http.get_header(resp, "vary"); ok {
		for f in strings.split(v, ",", context.temp_allocator) { if strings.trim_space(f) == "*" { return .Vary_Star } }
	}
	explicit := resp_cc.max_age >= 0 || http.has_header(resp, "expires")
	validator := http.has_header(resp, "etag") || http.has_header(resp, "last-modified")
	heuristic := resp_cc.public || is_heuristically_cacheable_status(status)
	if !explicit && !validator && !(heuristic && keep_unvalidated) {
		// redirects and errors without any of it would be reused by nobody
		return .No_Freshness
	}
	return .Store
}

// The times a stored response is judged by (RFC 9111 §4.2.3).
Response_Times :: struct {
	request_time:  i64,   // when the request that got it was sent
	response_time: i64,   // when it arrived
}

Freshness_Settings :: struct {
	heuristic_fraction: f64,   // of the time since Last-Modified (RFC 9111 §4.2.2: typically 10 %)
	heuristic_max_s:    i64,   // upper bound of a heuristic lifetime
}

// How long the response stays fresh after it was generated (RFC 9111 §4.2.1). `heuristic`: the lifetime is a guess
// (no max-age, no Expires).
freshness_lifetime :: proc(status: int, resp: http.Headers, cc: Cache_Control, s: Freshness_Settings) -> (lifetime: i64, heuristic: bool) {
	if cc.max_age >= 0 { return cc.max_age, false }
	date, has_date := response_date(resp)
	if ev, ok := http.get_header(resp, "expires"); ok {
		// an invalid date (Expires: 0, -1) means "already expired"
		exp, good := parse_http_date(ev)
		if !good || !has_date { return 0, false }
		return max(exp - date, 0), false
	}
	if !(cc.public || is_heuristically_cacheable_status(status)) { return 0, false }
	if lm, ok := http.get_header(resp, "last-modified"); ok && has_date {
		if t, good := parse_http_date(lm); good && t < date {
			life := i64(f64(date - t) * s.heuristic_fraction)
			return clamp(life, 0, s.heuristic_max_s), true
		}
	}
	return 0, true
}

// The Date of a response. A stored response always has one: the cache adds the arrival time when the server sent none
// (RFC 9110 §6.6.1: a recipient with a clock assigns one).
response_date :: proc(resp: http.Headers) -> (i64, bool) {
	v, ok := http.get_header(resp, "date")
	if !ok { return 0, false }
	return parse_http_date(v)
}

// RFC 9111 §4.2.3: the age of a stored response now.
current_age :: proc(resp: http.Headers, times: Response_Times, now: i64) -> i64 {
	age_value: i64 = 0
	if v, ok := http.get_header(resp, "age"); ok {
		// the first value; a malformed one is ignored
		first := strings.trim_space(strings.split(v, ",", context.temp_allocator)[0])
		if n, good := strconv.parse_i64(first); good && n >= 0 { age_value = n }
	}
	date_value, has := response_date(resp)
	if !has { date_value = times.response_time }
	apparent_age := max(i64(0), times.response_time - date_value)
	response_delay := max(i64(0), times.response_time - times.request_time)
	corrected_age_value := age_value + response_delay
	corrected_initial_age := max(apparent_age, corrected_age_value)
	resident_time := max(i64(0), now - times.response_time)
	return corrected_initial_age + resident_time
}

// What may be done with a stored response for a request, now (RFC 9111 §4.2, §4.2.4; RFC 5861 stale-while-revalidate).
Use :: enum u8 {
	Fresh,              // serve it
	Stale_Revalidate,   // serve it and refresh it in the background (stale-while-revalidate)
	Validate,           // ask the server (conditionally when it has validators)
}

Judgement :: struct {
	use:       Use,
	age:       i64,
	lifetime:  i64,
	heuristic: bool,
}

judge :: proc(status: int, resp: http.Headers, times: Response_Times, req_cc: Cache_Control, now: i64, s: Freshness_Settings, allow_swr := true) -> Judgement {
	cc := cache_control_of(resp)
	j: Judgement
	j.lifetime, j.heuristic = freshness_lifetime(status, resp, cc, s)
	j.age = current_age(resp, times, now)
	if cc.no_cache || req_cc.no_cache { j.use = .Validate; return j }
	// a request's max-age and min-fresh tighten the lifetime; max-stale loosens it (unless the response forbids)
	life := j.lifetime
	if req_cc.max_age >= 0 && j.age > req_cc.max_age { j.use = .Validate; return j }
	if req_cc.min_fresh >= 0 { life -= req_cc.min_fresh }
	if j.age < life { j.use = .Fresh; return j }
	staleness := j.age - j.lifetime
	if staleness < 0 { j.use = .Validate; return j }   // fresh, but not for as long as min-fresh asks
	if cc.must_revalidate { j.use = .Validate; return j }
	if req_cc.max_stale >= 0 && staleness <= req_cc.max_stale { j.use = .Fresh; return j }
	if allow_swr && cc.stale_while_revalidate > 0 && staleness <= cc.stale_while_revalidate && req_cc.max_age < 0 { j.use = .Stale_Revalidate; return j }
	j.use = .Validate
	return j
}

// The validators of a stored response, for a conditional request (RFC 9110 §13.1; RFC 9111 §4.3.1).
conditional_headers :: proc(resp: http.Headers) -> (if_none_match, if_modified_since: string) {
	if v, ok := http.get_header(resp, "etag"); ok { if_none_match = v }
	if v, ok := http.get_header(resp, "last-modified"); ok { if_modified_since = v }
	return
}

has_validator :: proc(resp: http.Headers) -> bool { return http.has_header(resp, "etag") || http.has_header(resp, "last-modified") }

// Header fields a 304 never replaces in the stored response (RFC 9111 §3.2: the framing of the stored body).
@(private)
is_not_updated_by_304 :: proc(name: string) -> bool {
	for n in ([]string{"content-length", "content-encoding", "transfer-encoding", "content-range", "content-type"}) {
		if strings.equal_fold(name, n) { return true }
	}
	return false
}

// RFC 9111 §4.3.4: the stored response's headers, refreshed with those of the 304 (each field the 304 has replaces the
// stored ones of that name). New list, in `allocator`.
merge_304 :: proc(stored, fresh: http.Headers, allocator := context.allocator) -> http.Headers {
	out := http.headers_make(allocator)
	for e in stored.list {
		if !is_not_updated_by_304(e.name) && http.has_header(fresh, e.name) { continue }
		http.append_header(&out, e.name, e.value)
	}
	for e in fresh.list {
		if is_not_updated_by_304(e.name) || is_hop_by_hop(e.name) || is_never_stored(e.name) { continue }
		http.append_header(&out, e.name, e.value)
	}
	return out
}

// Connection-level fields: they describe one hop, never a stored response (RFC 9111 §3.1).
is_hop_by_hop :: proc(name: string) -> bool {
	for n in ([]string{"connection", "keep-alive", "proxy-connection", "te", "transfer-encoding", "upgrade", "proxy-authenticate", "proxy-authorization", "trailer"}) {
		if strings.equal_fold(name, n) { return true }
	}
	return false
}

// Fields a stored response does not keep: cookies are set by the network response that carried them, never again by
// a stored copy (as Chromium persists headers "sans cookies"); the transport's own fields.
is_never_stored :: proc(name: string) -> bool {
	return strings.equal_fold(name, "set-cookie") || strings.equal_fold(name, "set-cookie2") || strings.equal_fold(name, "alt-svc")
}

// The Vary field names of a response, lower case. `star`: Vary: * (never matches).
vary_names :: proc(resp: http.Headers, allocator := context.temp_allocator) -> (names: []string, star: bool) {
	out := make([dynamic]string, allocator)
	for v in http.get_all(resp, "vary") {
		for f in strings.split(v, ",", context.temp_allocator) {
			n := strings.trim_space(f)
			if n == "" { continue }
			if n == "*" { star = true; continue }
			l := strings.to_lower(n, allocator)
			dup := false
			for o in out { if o == l { dup = true; break } }
			if !dup { append(&out, l) }
		}
	}
	return out[:], star
}

// The value a request has for a field, normalized for Vary matching (RFC 9111 §4.1: combined, whitespace around
// commas removed). `present` tells an absent field from an empty one.
vary_value :: proc(req: http.Headers, name: string, allocator := context.temp_allocator) -> (value: string, present: bool) {
	vals := http.get_all(req, name, context.temp_allocator)
	if len(vals) == 0 { return "", false }
	sb := strings.builder_make(allocator)
	n := 0
	for v in vals {
		for part in strings.split(v, ",", context.temp_allocator) {
			if n > 0 { strings.write_byte(&sb, ',') }
			strings.write_string(&sb, strings.trim_space(part))
			n += 1
		}
	}
	return strings.to_string(sb), true
}
