package url

import "core:strings"
import "core:sync"
import "wb:base"

// The Public Suffix List (https://publicsuffix.org, MPL-2.0), embedded. Refresh: tools\update_psl.ps1.
@(private)
PSL_DATA :: #load("public_suffix_list.dat", string)

@(private)
Rule :: enum u8 { Normal = 1, Wildcard, Exception }

@(private)
psl_rules: map[string]Rule
@(private)
psl_once: sync.Once

// Rules are keyed by their ASCII (punycode) form without the leading "*." or "!".
@(private)
psl_init :: proc() {
	context.allocator = base.process_allocator()   // process-lifetime cache
	psl_rules = make(map[string]Rule, 16384, context.allocator)
	data := PSL_DATA
	for line in strings.split_lines_iterator(&data) {
		l := strings.trim_space(line)
		if l == "" || strings.has_prefix(l, "//") { continue }
		// a rule ends at the first whitespace
		if i := strings.index_any(l, " \t"); i >= 0 { l = l[:i] }
		kind := Rule.Normal
		switch {
		case strings.has_prefix(l, "!"): kind, l = .Exception, l[1:]
		case strings.has_prefix(l, "*."): kind, l = .Wildcard, l[2:]
		}
		key := to_ascii_host(l)
		if key == "" { continue }
		psl_rules[key] = kind
	}
}

// IDNA ToASCII through the URL parser; plain ASCII is lower-cased without a round trip.
@(private)
to_ascii_host :: proc(s: string) -> string {
	ascii := true
	for c in s { if c >= 0x80 { ascii = false; break } }
	if ascii { return strings.to_lower(s) }
	u, ok := parse(strings.concatenate({"https://", s, "/"}, context.temp_allocator), nil, context.temp_allocator)
	if !ok { return "" }
	return strings.clone(u.host)
}

// Number of labels of the public suffix of `host` (an ASCII, lower-case domain), per the PSL algorithm.
public_suffix_labels :: proc(host: string) -> int {
	sync.once_do(&psl_once, psl_init)
	labels := strings.split(host, ".", context.temp_allocator)
	n := len(labels)
	best := 1   // the implicit "*" rule
	for i in 0 ..< n {
		suffix := host_from(host, labels, i)
		count := n - i
		if r, ok := psl_rules[suffix]; ok {
			if r == .Exception { return count - 1 }
			if r == .Normal && count > best { best = count }
		}
		// "*.example" matches any name with one more label below `example`
		if i + 1 < n {
			parent := host_from(host, labels, i + 1)
			if r, ok := psl_rules[parent]; ok && r == .Wildcard && count > best { best = count }
		}
	}
	return min(best, n)
}

@(private)
host_from :: proc(host: string, labels: []string, i: int) -> string {
	off := 0
	for j in 0 ..< i { off += len(labels[j]) + 1 }
	return host[off:]
}

// The public suffix itself ("co.uk" for "www.example.co.uk").
public_suffix :: proc(host: string) -> string {
	labels := strings.split(host, ".", context.temp_allocator)
	return host_from(host, labels, len(labels) - public_suffix_labels(host))
}

// The registrable domain ("example.co.uk"): the public suffix plus one label. ok = false for IPs, bare suffixes and
// single-label hosts.
registrable_domain :: proc(host: string) -> (domain: string, ok: bool) {
	if host == "" || strings.has_prefix(host, "[") { return "", false }
	if looks_ipv4(host) { return "", false }
	labels := strings.split(host, ".", context.temp_allocator)
	n := len(labels)
	k := public_suffix_labels(host)
	if n <= k { return "", false }
	return host_from(host, labels, n - k - 1), true
}

// Is `host` itself a public suffix (cookies may not be set for it)?
is_public_suffix :: proc(host: string) -> bool {
	labels := strings.split(host, ".", context.temp_allocator)
	return len(labels) == public_suffix_labels(host)
}
