// Package cookies: the HTTP state model (RFC 6265bis): parsing `Set-Cookie`, the storage model with its eviction and
// "leave Secure cookies alone" rules, and building the `Cookie` request header. The jar knows nothing about the network:
// callers (the fetch layer, `document.cookie`) pass a Context describing the request, so the policy decisions about
// third parties live in one place (fetch) and the jar only enforces what the specification says about a cookie.
package cookies

import "core:strconv"
import "core:strings"
import "wb:url"

Same_Site :: enum u8 { Unspecified, None, Lax, Strict }

Cookie :: struct {
	name:        string,
	value:       string,
	domain:      string,   // lower case, no leading dot
	path:        string,
	expires_ms:  i64,      // unix ms; 0 = session cookie
	created_ms:  i64,
	accessed_ms: i64,
	host_only:   bool,
	secure:      bool,
	http_only:   bool,
	same_site:   Same_Site,
	partition:   string,   // the top-level site it was set under in a third-party context ("": first-party, unpartitioned)
}

// What kind of request a cookie is attached to / received from, as far as SameSite is concerned.
Site_Context :: enum u8 {
	Same_Site,                  // the request is same-site with the top-level site
	Cross_Site_Top_Level_Safe,  // a cross-site top-level navigation with a safe method (Lax cookies are sent)
	Cross_Site,                 // everything else
}

Context :: struct {
	url:          url.URL,       // the request URL (or the document URL for document.cookie)
	site_context: Site_Context,
	http_api:     bool,          // true: HTTP request/response; false: script (document.cookie)
	now_ms:       i64,
	// the cookie partition of the context (storage partitioning, as Firefox's Total Cookie Protection): "" for a first-
	// party context, else the top-level site; a context only sees and sets the cookies of its own partition
	partition:    string,
}

////////////////////////////////
// Cookie dates (RFC 6265 §5.1.1)

// Parses the lenient cookie-date format. Returns unix milliseconds.
parse_cookie_date :: proc(s: string) -> (ms: i64, ok: bool) {
	delims :: proc(c: u8) -> bool {
		return c == 0x09 || (c >= 0x20 && c <= 0x2F) || (c >= 0x3B && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
	}
	found_time, found_day, found_month, found_year: bool
	hour, minute, second, day, month, year: int

	i := 0
	for i < len(s) {
		for i < len(s) && delims(s[i]) { i += 1 }
		start := i
		for i < len(s) && !delims(s[i]) { i += 1 }
		tok := s[start:i]
		if tok == "" { continue }

		if !found_time {
			if h, m, sec, good := parse_time_token(tok); good {
				found_time, hour, minute, second = true, h, m, sec
				continue
			}
		}
		if !found_day {
			if d, good := leading_digits(tok, 1, 2); good {
				found_day, day = true, d
				continue
			}
		}
		if !found_month && len(tok) >= 3 {
			if mi := month_index(tok[:3]); mi > 0 {
				found_month, month = true, mi
				continue
			}
		}
		if !found_year {
			if y, good := leading_digits(tok, 2, 4); good {
				found_year, year = true, y
				continue
			}
		}
	}
	if !(found_time && found_day && found_month && found_year) { return 0, false }
	if year >= 70 && year <= 99 { year += 1900 } else if year >= 0 && year <= 69 { year += 2000 }
	if day < 1 || day > 31 || year < 1601 || hour > 23 || minute > 59 || second > 59 { return 0, false }
	days_in := days_in_month(year, month)
	if day > days_in { return 0, false }
	return unix_ms(year, month, day, hour, minute, second), true
}

@(private)
parse_time_token :: proc(tok: string) -> (h, m, s: int, ok: bool) {
	parts := strings.split(tok, ":", context.temp_allocator)
	if len(parts) != 3 { return }
	vals: [3]int
	for p, i in parts {
		// 1*2DIGIT, followed by anything that is not a digit (trailing junk is allowed on the last)
		n, good := leading_digits(p, 1, 2)
		if !good { return }
		if i < 2 && len(p) > 2 && is_digit(p[2]) { return }
		vals[i] = n
	}
	return vals[0], vals[1], vals[2], true
}

@(private)
is_digit :: proc(c: u8) -> bool { return c >= '0' && c <= '9' }

// `min`..`max` leading digits, then end of token or a non-digit.
@(private)
leading_digits :: proc(s: string, min_n, max_n: int) -> (v: int, ok: bool) {
	n := 0
	for n < len(s) && is_digit(s[n]) { n += 1 }
	if n < min_n || n > max_n { return 0, false }
	if n < len(s) && is_digit(s[n]) { return 0, false }
	return strconv.parse_int(s[:n], 10)
}

@(private)
month_index :: proc(m: string) -> int {
	names := [?]string{"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}
	for n, i in names { if strings.equal_fold(n, m) { return i + 1 } }
	return 0
}

@(private)
days_in_month :: proc(year, month: int) -> int {
	switch month {
	case 1, 3, 5, 7, 8, 10, 12: return 31
	case 4, 6, 9, 11: return 30
	}
	leap := (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
	return leap ? 29 : 28
}

@(private)
unix_ms :: proc(year, month, day, h, m, s: int) -> i64 {
	// days from civil (H. Hinnant)
	y := year
	if month <= 2 { y -= 1 }
	era := (y >= 0 ? y : y - 399) / 400
	yoe := y - era * 400
	mp := (month + 9) % 12
	doy := (153 * mp + 2) / 5 + day - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	days := i64(era) * 146097 + i64(doe) - 719468
	return ((days * 24 + i64(h)) * 60 + i64(m)) * 60 * 1000 + i64(s) * 1000
}

////////////////////////////////
// Matching (RFC 6265 §5.1.3, §5.1.4)

domain_match :: proc(host, domain: string) -> bool {
	if host == domain { return true }
	return len(host) > len(domain) && strings.has_suffix(host, domain) && host[len(host) - len(domain) - 1] == '.' && !is_ip_string(host)
}

@(private)
is_ip_string :: proc(host: string) -> bool {
	if strings.has_prefix(host, "[") { return true }
	dots := 0
	for c in host { if c == '.' { dots += 1 } else if !is_digit(u8(c)) { return false } }
	return dots == 3
}

default_path :: proc(request_path: string) -> string {
	if request_path == "" || request_path[0] != '/' { return "/" }
	i := strings.last_index_byte(request_path, '/')
	if i == 0 { return "/" }
	return request_path[:i]
}

path_match :: proc(request_path, cookie_path: string) -> bool {
	rp := request_path == "" ? "/" : request_path
	if rp == cookie_path { return true }
	if strings.has_prefix(rp, cookie_path) {
		if strings.has_suffix(cookie_path, "/") { return true }
		if rp[len(cookie_path)] == '/' { return true }
	}
	return false
}

////////////////////////////////
// Set-Cookie parsing (RFC 6265bis §5.6)

Parsed :: struct {
	cookie:       Cookie,           // strings are slices of the header (cloned when stored)
	domain_attr:  string,
	path_attr:    string,
	has_domain:   bool,
	has_path:     bool,
	max_age_set:  bool,
	max_age_ms:   i64,
	expires_set:  bool,
	expires_ms:   i64,
}

parse_set_cookie :: proc(header: string, lim: Settings) -> (p: Parsed, ok: bool) {
	s := header
	// the name-value pair is everything before the first ';'
	first, rest := s, ""
	if i := strings.index_byte(s, ';'); i >= 0 { first, rest = s[:i], s[i + 1:] }
	nv := strings.trim_space(first)

	name, value := "", nv
	if eq := strings.index_byte(nv, '='); eq >= 0 {
		name = strings.trim_space(nv[:eq])
		value = strings.trim_space(nv[eq + 1:])
	}
	if len(name) + len(value) > lim.max_name_value_bytes { return {}, false }
	if name == "" && value == "" { return {}, false }
	if contains_ctl(name) || contains_ctl(value) { return {}, false }
	p.cookie.name, p.cookie.value = name, value

	for len(rest) > 0 {
		attr := rest
		if i := strings.index_byte(rest, ';'); i >= 0 { attr, rest = rest[:i], rest[i + 1:] } else { rest = "" }
		attr = strings.trim_space(attr)
		if attr == "" { continue }
		aname, avalue := attr, ""
		if eq := strings.index_byte(attr, '='); eq >= 0 {
			aname = strings.trim_space(attr[:eq])
			avalue = strings.trim_space(attr[eq + 1:])
		}
		if len(avalue) > lim.max_attribute_bytes { continue }
		switch {
		case strings.equal_fold(aname, "expires"):
			if ms, good := parse_cookie_date(avalue); good { p.expires_set, p.expires_ms = true, ms }
		case strings.equal_fold(aname, "max-age"):
			if ms, good := parse_max_age(avalue, lim.max_age_ms); good { p.max_age_set, p.max_age_ms = true, ms }
		case strings.equal_fold(aname, "domain"):
			d := avalue
			if strings.has_prefix(d, ".") { d = d[1:] }
			if d != "" { p.has_domain, p.domain_attr = true, d } else { p.has_domain, p.domain_attr = false, "" }
		case strings.equal_fold(aname, "path"):
			if avalue != "" && avalue[0] == '/' { p.has_path, p.path_attr = true, avalue } else { p.has_path, p.path_attr = false, "" }
		case strings.equal_fold(aname, "secure"):
			p.cookie.secure = true
		case strings.equal_fold(aname, "httponly"):
			p.cookie.http_only = true
		case strings.equal_fold(aname, "samesite"):
			switch {
			case strings.equal_fold(avalue, "strict"): p.cookie.same_site = .Strict
			case strings.equal_fold(avalue, "lax"):    p.cookie.same_site = .Lax
			case strings.equal_fold(avalue, "none"):   p.cookie.same_site = .None
			case: p.cookie.same_site = .Unspecified
			}
		}
	}
	return p, true
}

@(private)
contains_ctl :: proc(s: string) -> bool {
	for c in transmute([]u8)s { if c < 0x20 && c != 0x09 || c == 0x7f { return true } }
	return false
}

@(private)
parse_max_age :: proc(s: string, cap_ms: i64) -> (ms: i64, ok: bool) {
	if s == "" { return 0, false }
	i := 0
	neg := false
	if s[0] == '-' { neg = true; i = 1 }
	if i >= len(s) { return 0, false }
	for j in i ..< len(s) { if !is_digit(s[j]) { return 0, false } }
	v, good := strconv.parse_i64(s[i:], 10)
	if !good { v = max(i64) / 2000 }   // absurdly large: saturates below
	if neg { return 0, true }          // <= 0: expire immediately
	return min(v, cap_ms / 1000) * 1000, true
}

// Does the host (or the Cookie-Name prefix) forbid this cookie? Cookie name prefixes: RFC 6265bis §4.1.3.
@(private)
prefix_ok :: proc(c: Cookie, secure_origin: bool) -> bool {
	if strings.has_prefix(c.name, "__Secure-") && !(c.secure && secure_origin) { return false }
	if strings.has_prefix(c.name, "__Host-") && !(c.secure && secure_origin && c.host_only && c.path == "/") { return false }
	return true
}
