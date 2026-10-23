// Package adblock: a content-blocking engine for the Adblock Plus / uBlock Origin / AdGuard filter syntax.
//
// It is a pure library (no I/O, no globals except the public-suffix hook): lists go in as text, a compact immutable
// binary index comes out (`build`), and requests are matched against that index in microseconds without allocating
// (`match`). The index is one contiguous byte blob (header, string pool, filter records, hash tables): it can be written
// to a file, mapped back, and used as is, so the filters are compiled only when a list changes.
//
//   * network filters  : `||host^`, `|`, `*`, `^`, `/regex/`, the type / party / domain / method options, exceptions,
//                        `$important`, `$badfilter`, `$redirect`, `$removeparam`, `$csp`, `$header`, `$denyallow`, `$to`...
//   * cosmetic filters : element hiding (generic, per domain, entities), procedural selectors, `:style()`, `:remove()`,
//                        scriptlet rules (`##+js(...)`), HTML filters (`##^`), and their exceptions
//   * preprocessor     : `!#include`, `!#if / !#else / !#endif`
//
// An `Engine` is read-only once built, except for a lazily filled regular-expression cache: use one engine from one
// thread at a time (the loop thread), and publish a new one to replace it (see package blocker).
//
// Matching algorithm (network): the URL is cut into tokens (runs of [a-z0-9%]); every filter is filed under its rarest
// token (chosen at build time from the token frequencies of the whole list), so a request looks up each of its tokens
// in a hash table and verifies only the few filters found there. Filters that are just `||host^` are filed by host in a
// table probed with the request host's label suffixes (a.b.c, b.c, c). A bitmap in front of the token table answers
// "no filter has this token" without touching the table. Regular expressions run on a Pike VM (linear time: filters
// cannot cause catastrophic backtracking).
package adblock

import "core:strings"

FNV_OFFSET :: u32(2166136261)
FNV_PRIME  :: u32(16777619)

// Hash of a string; never 0 (0 marks an empty hash-table slot).
hash_str :: #force_inline proc "contextless" (s: string) -> u32 {
	h := FNV_OFFSET
	for i in 0 ..< len(s) { h = (h ~ u32(s[i])) * FNV_PRIME }
	return h == 0 ? 1 : h
}

// The hash of `s` followed by ".*": the key of an entity (`google.*`) in a domain list.
hash_entity :: #force_inline proc "contextless" (s: string) -> u32 {
	h := FNV_OFFSET
	for i in 0 ..< len(s) { h = (h ~ u32(s[i])) * FNV_PRIME }
	h = (h ~ u32('.')) * FNV_PRIME
	h = (h ~ u32('*')) * FNV_PRIME
	return h == 0 ? 1 : h
}

@(private)
is_token_char :: #force_inline proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '%'
}

@(private)
is_alnum :: #force_inline proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// `^` in a filter matches any character that is not a letter, a digit, '_', '-', '.' or '%'.
@(private)
is_separator :: #force_inline proc "contextless" (c: u8) -> bool {
	return !(is_alnum(c) || c == '_' || c == '-' || c == '.' || c == '%')
}

@(private)
lower_byte :: #force_inline proc "contextless" (c: u8) -> u8 { return c >= 'A' && c <= 'Z' ? c + 32 : c }

// Lower-cases ASCII into `dst` (which must be at least as long as `s`).
@(private)
lower_into :: proc "contextless" (dst: []u8, s: string) {
	for i in 0 ..< len(s) { dst[i] = lower_byte(s[i]) }
}

@(private)
has_upper :: proc "contextless" (s: string) -> bool {
	for i in 0 ..< len(s) { if s[i] >= 'A' && s[i] <= 'Z' { return true } }
	return false
}

@(private)
trim_ws :: proc(s: string) -> string { return strings.trim_space(s) }

// Number of labels of the public suffix of a host (1 for "com", 2 for "co.uk"). The default knows nothing of the
// Public Suffix List and treats the last label as the suffix; the browser installs the real one (package blocker).
Suffix_Labels_Proc :: #type proc(host: string) -> int
suffix_labels_hook: Suffix_Labels_Proc

@(private)
suffix_labels :: proc(host: string) -> int {
	if suffix_labels_hook != nil { return suffix_labels_hook(host) }
	return 1
}

// Is the host an IPv4 / IPv6 literal (no registrable domain)?
is_ip_host :: proc "contextless" (h: string) -> bool {
	if len(h) == 0 { return false }
	if h[0] == '[' { return true }
	dots := 0
	for i in 0 ..< len(h) {
		c := h[i]
		if c == '.' { dots += 1; continue }
		if c < '0' || c > '9' { return false }
	}
	return dots == 3
}

// The registrable domain of a host ("a.b.example.co.uk" -> "example.co.uk"); the host itself for IPs and single labels.
registrable_domain :: proc(host: string) -> string {
	if host == "" || is_ip_host(host) { return host }
	n := 1
	for i in 0 ..< len(host) { if host[i] == '.' { n += 1 } }
	k := suffix_labels(host)
	if n <= k { return host }
	// keep k+1 labels from the right
	want := k + 1
	i := len(host)
	seen := 0
	for i > 0 {
		i -= 1
		if host[i] == '.' {
			seen += 1
			if seen == want { return host[i + 1:] }
		}
	}
	return host
}

// Splits a URL into scheme end, host range (without userinfo and port) without allocating. Returns false for URLs
// without an authority ("data:", "about:blank"...).
URL_Parts :: struct {
	host_start, host_end: int,   // in the URL string
	path_start:           int,   // index of the first '/' '?' or '#' after the authority (len when none)
	scheme_end:           int,
}

url_parts :: proc "contextless" (u: string) -> (p: URL_Parts, ok: bool) {
	n := len(u)
	i := 0
	for i < n && u[i] != ':' { c := u[i]; if !(is_alnum(c) || c == '+' || c == '-' || c == '.') { return {}, false }; i += 1 }
	if i == 0 || i + 2 >= n || u[i + 1] != '/' || u[i + 2] != '/' { return {}, false }
	p.scheme_end = i
	a := i + 3
	e := a
	for e < n && u[e] != '/' && u[e] != '?' && u[e] != '#' && u[e] != '\\' { e += 1 }
	p.path_start = e
	// userinfo
	hs := a
	for k := e - 1; k >= a; k -= 1 { if u[k] == '@' { hs = k + 1; break } }
	he := e
	if hs < he && u[hs] == '[' {
		for k := hs; k < e; k += 1 { if u[k] == ']' { he = k + 1; break } }
	} else {
		for k := e - 1; k >= hs; k -= 1 { if u[k] == ':' { he = k; break } }
	}
	p.host_start, p.host_end = hs, he
	return p, he > hs
}

url_host :: proc "contextless" (u: string) -> string {
	p, ok := url_parts(u)
	if !ok { return "" }
	return u[p.host_start:p.host_end]
}
