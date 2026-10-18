package cookies

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:url"

Jar :: struct {
	cookies:      [dynamic]Cookie,   // every string is owned by the jar
	settings:     Settings,
	dirty:        bool,              // changed since the last save
	allocator:    runtime.Allocator,
}

// `settings` zero value = the defaults.
jar_make :: proc(settings: Settings = {}, allocator := context.allocator) -> Jar {
	s := settings.max_total == 0 ? settings_default() : settings
	return Jar{cookies = make([dynamic]Cookie, allocator), settings = s, allocator = allocator}
}

jar_destroy :: proc(j: ^Jar) {
	for &c in j.cookies { free_cookie(j, &c) }
	delete(j.cookies)
	j^ = {}
}

@(private)
free_cookie :: proc(j: ^Jar, c: ^Cookie) {
	a := j.allocator
	delete(c.name, a); delete(c.value, a); delete(c.domain, a); delete(c.path, a)
	c^ = {}
}

count :: proc(j: ^Jar) -> int { return len(j.cookies) }

now_ms :: proc() -> i64 { return time.to_unix_nanoseconds(time.now()) / 1_000_000 }

Store_Result :: enum u8 {
	Stored,
	Replaced,
	Deleted,                   // an expired cookie removed the existing one
	Rejected_Syntax,
	Rejected_Domain,           // Domain attribute does not match the host, or is a public suffix
	Rejected_Secure_Origin,    // Secure cookie from an insecure origin
	Rejected_Prefix,           // __Secure- / __Host- rules
	Rejected_Same_Site,        // SameSite cookie set from a cross-site context, or SameSite=None without Secure
	Rejected_Http_Only,        // script tried to create or overwrite an HttpOnly cookie
	Rejected_Secure_Overwrite, // would shadow a Secure cookie from an insecure origin
	Rejected_Expired,          // already expired and nothing to delete
	Rejected_Disabled,         // cookies are switched off in the configuration
}

// Applies one `Set-Cookie` header value (or a `document.cookie = ...` string) per the storage model.
store :: proc(j: ^Jar, header: string, ctx: Context) -> Store_Result {
	if !j.settings.enabled { return .Rejected_Disabled }
	p, ok := parse_set_cookie(header, j.settings)
	if !ok { return .Rejected_Syntax }
	c := p.cookie
	u := ctx.url
	host := u.host
	secure_origin := url.is_potentially_trustworthy(u)

	if !ctx.http_api && c.http_only { return .Rejected_Http_Only }

	// domain
	if p.has_domain {
		d := strings.to_lower(p.domain_attr, context.temp_allocator)
		if url.is_ip_host(u) {
			if d != host { return .Rejected_Domain }
			c.domain, c.host_only = host, true
		} else if url.is_public_suffix(d) {
			if d != host { return .Rejected_Domain }
			c.domain, c.host_only = host, true
		} else if !domain_match(host, d) {
			return .Rejected_Domain
		} else {
			c.domain, c.host_only = d, false
		}
	} else {
		c.domain, c.host_only = host, true
	}
	c.path = p.has_path ? p.path_attr : default_path(u.path)

	// lifetime: Max-Age wins over Expires; both capped
	now := ctx.now_ms
	expired := false
	switch {
	case p.max_age_set:
		c.expires_ms = now + p.max_age_ms
		expired = p.max_age_ms <= 0
	case p.expires_set:
		c.expires_ms = min(p.expires_ms, now + j.settings.max_age_ms)
		expired = p.expires_ms <= now
	}

	if c.secure && !secure_origin { return .Rejected_Secure_Origin }
	if !prefix_ok_ci(c, secure_origin) { return .Rejected_Prefix }
	if c.same_site == .None && !c.secure { return .Rejected_Same_Site }
	eff := c.same_site == .Unspecified ? j.settings.same_site_default : c.same_site
	if eff != .None && ctx.site_context == .Cross_Site { return .Rejected_Same_Site }

	idx := find(j, c.name, c.domain, c.path)
	if idx >= 0 && j.cookies[idx].http_only && !ctx.http_api { return .Rejected_Http_Only }

	if expired {
		if idx >= 0 { remove_at(j, idx); return .Deleted }
		return .Rejected_Expired
	}

	// "Leave Secure Cookies Alone": an insecure origin must not shadow or replace a Secure cookie
	if !secure_origin {
		for o in j.cookies {
			if o.secure && o.name == c.name &&
			   (domain_match(c.domain, o.domain) || domain_match(o.domain, c.domain)) &&
			   (path_match(c.path, o.path) || path_match(o.path, c.path)) {
				return .Rejected_Secure_Overwrite
			}
		}
	}

	a := j.allocator
	c.name = strings.clone(c.name, a)
	c.value = strings.clone(c.value, a)
	c.domain = strings.clone(c.domain, a)
	c.path = strings.clone(c.path, a)
	c.accessed_ms = now
	c.created_ms = now
	result := Store_Result.Stored
	if idx >= 0 {
		c.created_ms = j.cookies[idx].created_ms
		free_cookie(j, &j.cookies[idx])
		j.cookies[idx] = c
		result = .Replaced
	} else {
		append(&j.cookies, c)
	}
	j.dirty = true
	evict(j, now, c.domain)
	return result
}

@(private)
prefix_ok_ci :: proc(c: Cookie, secure_origin: bool) -> bool {
	n := strings.to_lower(c.name, context.temp_allocator)
	if strings.has_prefix(n, "__secure-") && !(c.secure && secure_origin) { return false }
	if strings.has_prefix(n, "__host-") && !(c.secure && secure_origin && c.host_only && c.path == "/") { return false }
	return true
}

@(private)
find :: proc(j: ^Jar, name, domain, path: string) -> int {
	for c, i in j.cookies { if c.name == name && c.domain == domain && c.path == path { return i } }
	return -1
}

@(private)
remove_at :: proc(j: ^Jar, i: int) {
	free_cookie(j, &j.cookies[i])
	ordered_remove(&j.cookies, i)
	j.dirty = true
}

// Drops expired cookies, then enforces the per-site and global limits (least recently used first).
@(private)
evict :: proc(j: ^Jar, now: i64, domain: string) {
	for i := len(j.cookies) - 1; i >= 0; i -= 1 {
		if e := j.cookies[i].expires_ms; e != 0 && e <= now { remove_at(j, i) }
	}
	site_key := registrable_or_host(domain)
	for {
		n := 0
		oldest := -1
		for c, i in j.cookies {
			if registrable_or_host(c.domain) != site_key { continue }
			n += 1
			if oldest < 0 || c.accessed_ms < j.cookies[oldest].accessed_ms { oldest = i }
		}
		if n <= j.settings.max_per_site || oldest < 0 { break }
		remove_at(j, oldest)
	}
	for len(j.cookies) > j.settings.max_total {
		oldest := 0
		for c, i in j.cookies { if c.accessed_ms < j.cookies[oldest].accessed_ms { oldest = i } }
		remove_at(j, oldest)
	}
}

@(private)
registrable_or_host :: proc(host: string) -> string {
	if d, ok := url.registrable_domain(host); ok { return d }
	return host
}

// The value of the `Cookie` request header for `ctx.url`, "" when no cookie applies.
header_for :: proc(j: ^Jar, ctx: Context, allocator := context.allocator) -> string {
	if !j.settings.enabled { return "" }
	u := ctx.url
	secure_origin := url.is_potentially_trustworthy(u)
	Match :: struct { i: int, path_len: int, created: i64 }
	matches := make([dynamic]Match, context.temp_allocator)

	for &c, i in j.cookies {
		if c.expires_ms != 0 && c.expires_ms <= ctx.now_ms { continue }
		if c.host_only { if u.host != c.domain { continue } } else if !domain_match(u.host, c.domain) { continue }
		if !path_match(u.path, c.path) { continue }
		if c.secure && !secure_origin { continue }
		if c.http_only && !ctx.http_api { continue }
		eff := c.same_site == .Unspecified ? j.settings.same_site_default : c.same_site
		switch eff {
		case .Strict: if ctx.site_context != .Same_Site { continue }
		case .Lax:    if ctx.site_context == .Cross_Site { continue }
		case .None, .Unspecified:
		}
		append(&matches, Match{i, len(c.path), c.created_ms})
	}
	if len(matches) == 0 { return "" }
	slice.sort_by(matches[:], proc(a, b: Match) -> bool {
		if a.path_len != b.path_len { return a.path_len > b.path_len }
		return a.created < b.created
	})
	sb := strings.builder_make(allocator)
	for m, k in matches {
		c := &j.cookies[m.i]
		c.accessed_ms = ctx.now_ms
		if k > 0 { strings.write_string(&sb, "; ") }
		if c.name != "" { strings.write_string(&sb, c.name); strings.write_byte(&sb, '=') }
		strings.write_string(&sb, c.value)
	}
	return strings.to_string(sb)
}

// All cookies, for the cookie manager UI.
all :: proc(j: ^Jar) -> []Cookie { return j.cookies[:] }

delete_matching :: proc(j: ^Jar, domain: string) -> int {
	n := 0
	for i := len(j.cookies) - 1; i >= 0; i -= 1 {
		if j.cookies[i].domain == domain || domain_match(j.cookies[i].domain, domain) { remove_at(j, i); n += 1 }
	}
	return n
}

clear_all :: proc(j: ^Jar) {
	for len(j.cookies) > 0 { remove_at(j, len(j.cookies) - 1) }
}

////////////////////////////////
// Persistence: one line per persistent cookie, written atomically.

MAGIC :: "wbcookies 1"

@(private)
escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for c in transmute([]u8)s {
		switch c {
		case '%', '\t', '\n', '\r': fmt.sbprintf(&sb, "%%%02X", c)
		case: strings.write_byte(&sb, c)
		}
	}
	return strings.to_string(sb)
}

@(private)
unescape :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			if v, ok := strconv.parse_int(s[i + 1:i + 3], 16); ok { strings.write_byte(&sb, u8(v)); i += 2; continue }
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

save :: proc(j: ^Jar, path: string, now: i64 = 0) -> bool {
	nowv := now == 0 ? now_ms() : now
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, MAGIC)
	strings.write_byte(&sb, '\n')
	for c in j.cookies {
		if c.expires_ms == 0 || c.expires_ms <= nowv { continue }   // session and expired cookies are not persisted
		flags := 0
		if c.host_only { flags |= 1 }
		if c.secure { flags |= 2 }
		if c.http_only { flags |= 4 }
		fmt.sbprintf(&sb, "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\n", escape(c.name), escape(c.value), escape(c.domain), escape(c.path),
			c.expires_ms, c.created_ms, c.accessed_ms, flags, int(c.same_site))
	}
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, transmute([]byte)strings.to_string(sb)); err != nil { return false }
	if err := os.rename(tmp, path); err != nil {
		_ = os.remove(path)   // Windows refuses to rename over an existing file
		if err2 := os.rename(tmp, path); err2 != nil { return false }
	}
	j.dirty = false
	return true
}

// Merges the persistent cookies found in `path`. Malformed lines are skipped.
load :: proc(j: ^Jar, path: string, now: i64 = 0) -> (loaded: int, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return 0, false }
	nowv := now == 0 ? now_ms() : now
	text := string(data)
	first := true
	a := j.allocator
	for line in strings.split_lines_iterator(&text) {
		if first { first = false; if line != MAGIC { return 0, false }; continue }
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) != 9 { continue }
		c: Cookie
		exp, ok1 := strconv.parse_i64(f[4], 10)
		cre, ok2 := strconv.parse_i64(f[5], 10)
		acc, ok3 := strconv.parse_i64(f[6], 10)
		flags, ok4 := strconv.parse_int(f[7], 10)
		ss, ok5 := strconv.parse_int(f[8], 10)
		if !(ok1 && ok2 && ok3 && ok4 && ok5) || exp <= nowv || ss < 0 || ss > int(Same_Site.Strict) { continue }
		c.name = strings.clone(unescape(f[0]), a)
		c.value = strings.clone(unescape(f[1]), a)
		c.domain = strings.clone(unescape(f[2]), a)
		c.path = strings.clone(unescape(f[3]), a)
		c.expires_ms, c.created_ms, c.accessed_ms = exp, cre, acc
		c.host_only, c.secure, c.http_only = flags & 1 != 0, flags & 2 != 0, flags & 4 != 0
		c.same_site = Same_Site(ss)
		if idx := find(j, c.name, c.domain, c.path); idx >= 0 { free_cookie(j, &j.cookies[idx]); j.cookies[idx] = c } else { append(&j.cookies, c) }
		loaded += 1
	}
	return loaded, true
}
