package fetch

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:url"

// HTTP Strict Transport Security (RFC 6797): once a host said "https only", plain-http URLs for it (and for its
// subdomains, with includeSubDomains) are upgraded before anything leaves the machine.

Hsts_Entry :: struct {
	expires_ms:         i64,
	include_subdomains: bool,
}

Hsts :: struct {
	hosts:       map[string]Hsts_Entry,   // lower-case ASCII domain -> entry; keys are owned
	allocator:   runtime.Allocator,
	dirty:       bool,
	// every site visited may add a host: past this, the entry that expires first goes (network.hsts.max_entries)
	max_entries: int,
	max_age_ms:  i64,                     // a longer max-age is cut to this (network.hsts.max_age_s)
}

// The defaults of network.hsts.max_entries and network.hsts.max_age_s (settings.odin), for a store made without them.
HSTS_MAX_ENTRIES :: 10_000
HSTS_MAX_AGE_S :: 365 * 86_400

// `max_entries` / `max_age_s` 0: the defaults.
hsts_make :: proc(max_entries := 0, max_age_s: i64 = 0, allocator := context.allocator) -> Hsts {
	return Hsts{
		hosts = make(map[string]Hsts_Entry, allocator), allocator = allocator,
		max_entries = max_entries > 0 ? max_entries : HSTS_MAX_ENTRIES,
		max_age_ms = (max_age_s > 0 ? max_age_s : HSTS_MAX_AGE_S) * 1000,
	}
}

// Sets the entry of `host`, making room first when it is a new host and the store is full.
@(private)
hsts_put :: proc(h: ^Hsts, host: string, entry: Hsts_Entry, now: i64) {
	if v, exists := &h.hosts[host]; exists { v^ = entry; return }
	if len(h.hosts) >= h.max_entries {
		hsts_purge(h, now)
		// still full: the entry that expires first is the one the store would lose soonest anyway
		for len(h.hosts) >= h.max_entries && len(h.hosts) > 0 {
			first_key := ""
			first_exp := max(i64)
			for k, e in h.hosts { if e.expires_ms < first_exp { first_key, first_exp = k, e.expires_ms } }
			key, _ := delete_key(&h.hosts, first_key)
			delete(key, h.allocator)
		}
	}
	h.hosts[strings.clone(host, h.allocator)] = entry
}

hsts_destroy :: proc(h: ^Hsts) {
	for k in h.hosts { delete(k, h.allocator) }
	delete(h.hosts)
	h^ = {}
}

// Forgets every host (`wren ctl reset`); returns how many there were.
hsts_clear :: proc(h: ^Hsts) -> int {
	n := len(h.hosts)
	for k in h.hosts { delete(k, h.allocator) }
	clear(&h.hosts)
	if n > 0 { h.dirty = true }
	return n
}

now_ms :: proc() -> i64 { return time.to_unix_nanoseconds(base.wall_now()) / 1_000_000 }

// Processes a Strict-Transport-Security header received over a secure connection from `host`.
// Returns true when the store changed.
hsts_note :: proc(h: ^Hsts, host: string, header: string, now: i64) -> bool {
	if host == "" || strings.has_prefix(host, "[") || looks_like_ipv4(host) { return false }   // never for IP literals
	max_age: i64 = -1
	include := false
	seen_max_age := false
	for directive in strings.split(header, ";", context.temp_allocator) {
		d := strings.trim_space(directive)
		if d == "" { continue }
		name, value := d, ""
		if eq := strings.index_byte(d, '='); eq >= 0 { name, value = strings.trim_space(d[:eq]), strings.trim_space(d[eq + 1:]) }
		switch {
		case base.ascii_equal_fold(name, "max-age"):
			if seen_max_age { return false }   // duplicate directives make the whole header invalid
			seen_max_age = true
			if len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' { value = value[1:len(value) - 1] }
			v, ok := strconv.parse_i64(value, 10)
			if !ok || v < 0 { return false }
			max_age = v
		case base.ascii_equal_fold(name, "includesubdomains"):
			include = true
		}
	}
	if max_age < 0 { return false }   // max-age is required
	if max_age == 0 {
		if k, _ := delete_key(&h.hosts, host); k != "" { delete(k, h.allocator); h.dirty = true; return true }
		return false
	}
	// (in seconds first: a huge max-age times 1000 would overflow)
	age_ms := min(max_age, h.max_age_ms / 1000) * 1000
	hsts_put(h, host, Hsts_Entry{expires_ms = now + age_ms, include_subdomains = include}, now)
	h.dirty = true
	return true
}

@(private)
looks_like_ipv4 :: proc(host: string) -> bool {
	dots := 0
	for c in host { if c == '.' { dots += 1 } else if c < '0' || c > '9' { return false } }
	return dots == 3
}

// Should a plain-http request to `host` be upgraded to https?
hsts_should_upgrade :: proc(h: ^Hsts, host: string, now: i64) -> bool {
	if len(h.hosts) == 0 { return false }
	// the host itself, then each parent domain that asked for includeSubDomains
	rest := host
	first := true
	for rest != "" {
		if e, ok := h.hosts[rest]; ok {
			if e.expires_ms > now && (first || e.include_subdomains) { return true }
		}
		dot := strings.index_byte(rest, '.')
		if dot < 0 { break }
		rest = rest[dot + 1:]
		first = false
	}
	return false
}

// Drops expired entries.
hsts_purge :: proc(h: ^Hsts, now: i64) {
	expired := make([dynamic]string, context.temp_allocator)
	for k, e in h.hosts { if e.expires_ms <= now { append(&expired, k) } }
	for k in expired {
		key, _ := delete_key(&h.hosts, k)
		delete(key, h.allocator)
		h.dirty = true
	}
}

HSTS_MAGIC :: "wbhsts 1"

// The text of the profile's HSTS file, the hosts expired at `now` dropped first. The profile's writer writes it
// (host.File_Writer).
hsts_serialize :: proc(h: ^Hsts, now: i64, allocator := context.allocator) -> string {
	hsts_purge(h, now)
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, HSTS_MAGIC)
	strings.write_byte(&sb, '\n')
	for k, e in h.hosts { fmt.sbprintf(&sb, "%s\t%d\t%d\n", k, e.expires_ms, e.include_subdomains ? 1 : 0) }
	return strings.to_string(sb)
}

hsts_load :: proc(h: ^Hsts, path: string, now: i64) -> (loaded: int, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return 0, false }
	text := string(data)
	first := true
	for line in strings.split_lines_iterator(&text) {
		if first { first = false; if line != HSTS_MAGIC { return 0, false }; continue }
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) != 3 { continue }
		exp, ok1 := strconv.parse_i64(f[1], 10)
		inc, ok2 := strconv.parse_int(f[2], 10)
		if !ok1 || !ok2 || exp <= now || f[0] == "" { continue }
		// (a file written before the cap, or under a larger one, keeps no entry longer than the cap from now)
		hsts_put(h, f[0], Hsts_Entry{min(exp, now + h.max_age_ms), inc != 0}, now)
		loaded += 1
	}
	return loaded, true
}

// The URL with plain http replaced by https (port 80 becomes the default https port). Input must be an http URL.
upgrade_to_https :: proc(u: url.URL, allocator := context.allocator) -> (url.URL, bool) {
	port := u.port
	s := strings.builder_make(context.temp_allocator)
	strings.write_string(&s, "https://")
	if u.username != "" {
		strings.write_string(&s, u.username)
		if u.password != "" { strings.write_byte(&s, ':'); strings.write_string(&s, u.password) }
		strings.write_byte(&s, '@')
	}
	strings.write_string(&s, u.host)
	if port >= 0 && port != 80 { strings.write_byte(&s, ':'); strings.write_int(&s, port) }
	strings.write_string(&s, u.path)
	if u.has_query { strings.write_byte(&s, '?'); strings.write_string(&s, u.query) }
	if u.has_fragment { strings.write_byte(&s, '#'); strings.write_string(&s, u.fragment) }
	return url.parse_absolute(strings.to_string(s), allocator)
}
