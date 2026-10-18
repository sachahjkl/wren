// Package csp: Content Security Policy Level 3 — parsing and the URL / nonce matching algorithms.
//
// A document can carry several policies (several headers, comma separated lists, <meta>); every enforced policy must
// allow a request, report-only policies only produce violations. The fetch layer asks `check_request` before a request
// is sent and after each redirect; page code asks `check_nonce` for elements that carry a nonce.
//
// In this browser the document's behaviour *is* a Wasm module, so `script-src` governs which modules may be loaded;
// there is no inline script, no eval and no JavaScript, hence 'unsafe-inline', 'unsafe-eval' and 'strict-dynamic' are
// parsed (policies must be valid) but have nothing to enable.
package csp

import "core:strings"
import "wb:url"

Disposition :: enum u8 { Enforce, Report_Only }

Keyword :: enum u8 { None, Self, Unsafe_Inline, Unsafe_Eval, Wasm_Unsafe_Eval, Strict_Dynamic, Unsafe_Hashes, Report_Sample }

Source_Kind :: enum u8 { Keyword, Scheme, Host, Nonce, Hash }

Source :: struct {
	kind:    Source_Kind,
	keyword: Keyword,
	scheme:  string,   // Scheme: "https"; Host: optional scheme part
	host:    string,   // Host: lower case, may start with "*." or be "*"
	port:    string,   // Host: "", "*" or digits
	path:    string,   // Host: "" or a path (trailing "/" = prefix)
	value:   string,   // Nonce: base64 value; Hash: "sha256-..." digest in base64
	algo:    string,
}

Directive :: struct {
	name:    string,   // lower case
	sources: [dynamic]Source,
	raw:     string,   // the value, for violation reports
}

Policy :: struct {
	disposition: Disposition,
	directives:  [dynamic]Directive,
	raw:         string,
	warnings:    [dynamic]string,
}

Policy_List :: struct {
	policies: [dynamic]Policy,
}

list_destroy :: proc(l: ^Policy_List) {
	for &p in l.policies { policy_destroy(&p) }
	delete(l.policies)
	l^ = {}
}

policy_destroy :: proc(p: ^Policy) {
	for &d in p.directives {
		delete(d.name); delete(d.raw)
		for s in d.sources { delete(s.scheme); delete(s.host); delete(s.port); delete(s.path); delete(s.value); delete(s.algo) }
		delete(d.sources)
	}
	delete(p.directives)
	for w in p.warnings { delete(w) }
	delete(p.warnings)
	delete(p.raw)
	p^ = {}
}

////////////////////////////////
// Parsing

is_ascii_ws :: proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }

split_ws :: proc(s: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	i := 0
	for i < len(s) {
		for i < len(s) && is_ascii_ws(s[i]) { i += 1 }
		start := i
		for i < len(s) && !is_ascii_ws(s[i]) { i += 1 }
		if i > start { append(&out, s[start:i]) }
	}
	return out[:]
}

parse_policy :: proc(text: string, disposition: Disposition) -> Policy {
	p := Policy{disposition = disposition, raw = strings.clone(text)}
	for raw_dir in strings.split(text, ";", context.temp_allocator) {
		tokens := split_ws(raw_dir)
		if len(tokens) == 0 { continue }
		name := strings.to_lower(tokens[0], context.temp_allocator)
		dup := false
		for d in p.directives { if d.name == name { dup = true; break } }
		if dup { continue }   // only the first occurrence counts
		d := Directive{name = strings.clone(name), raw = strings.clone(strings.join(tokens[1:], " ", context.temp_allocator))}
		for tok in tokens[1:] {
			if src, ok := parse_source(tok); ok {
				append(&d.sources, src)
			} else {
				append(&p.warnings, strings.clone(strings.concatenate({"ignored invalid source ", tok, " in ", name}, context.temp_allocator)))
			}
		}
		append(&p.directives, d)
	}
	return p
}

// Parses a header value that may be a comma separated list of policies.
parse_header :: proc(l: ^Policy_List, value: string, disposition: Disposition) {
	for part in strings.split(value, ",", context.temp_allocator) {
		t := strings.trim(part, " \t\r\n")
		if t != "" { append(&l.policies, parse_policy(t, disposition)) }
	}
}

@(private)
parse_source :: proc(tok: string) -> (s: Source, ok: bool) {
	if len(tok) >= 2 && tok[0] == '\'' && tok[len(tok) - 1] == '\'' {
		inner := tok[1:len(tok) - 1]
		lower := strings.to_lower(inner, context.temp_allocator)
		switch lower {
		case "none":             return Source{kind = .Keyword, keyword = .None}, true
		case "self":             return Source{kind = .Keyword, keyword = .Self}, true
		case "unsafe-inline":    return Source{kind = .Keyword, keyword = .Unsafe_Inline}, true
		case "unsafe-eval":      return Source{kind = .Keyword, keyword = .Unsafe_Eval}, true
		case "wasm-unsafe-eval": return Source{kind = .Keyword, keyword = .Wasm_Unsafe_Eval}, true
		case "strict-dynamic":   return Source{kind = .Keyword, keyword = .Strict_Dynamic}, true
		case "unsafe-hashes":    return Source{kind = .Keyword, keyword = .Unsafe_Hashes}, true
		case "report-sample":    return Source{kind = .Keyword, keyword = .Report_Sample}, true
		}
		if strings.has_prefix(lower, "nonce-") && is_base64_value(inner[6:]) {
			return Source{kind = .Nonce, value = strings.clone(inner[6:])}, true
		}
		for algo in ([]string{"sha256", "sha384", "sha512"}) {
			if strings.has_prefix(lower, strings.concatenate({algo, "-"}, context.temp_allocator)) && is_base64_value(inner[len(algo) + 1:]) {
				return Source{kind = .Hash, algo = strings.clone(algo), value = strings.clone(inner[len(algo) + 1:])}, true
			}
		}
		return {}, false
	}
	// scheme-source: "https:"
	if len(tok) > 1 && tok[len(tok) - 1] == ':' && is_scheme_name(tok[:len(tok) - 1]) {
		return Source{kind = .Scheme, scheme = strings.to_lower(tok[:len(tok) - 1])}, true
	}
	return parse_host_source(tok)
}

@(private)
is_base64_value :: proc(s: string) -> bool {
	if s == "" { return false }
	for c in transmute([]u8)s {
		ok := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '-' || c == '_' || c == '='
		if !ok { return false }
	}
	return true
}

@(private)
is_scheme_name :: proc(s: string) -> bool {
	if s == "" { return false }
	for c, i in transmute([]u8)s {
		alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
		if i == 0 && !alpha { return false }
		if !(alpha || (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.') { return false }
	}
	return true
}

@(private)
parse_host_source :: proc(tok: string) -> (s: Source, ok: bool) {
	rest := tok
	s.kind = .Host
	if i := strings.index(rest, "://"); i >= 0 {
		if !is_scheme_name(rest[:i]) { return {}, false }
		s.scheme = strings.to_lower(rest[:i])
		rest = rest[i + 3:]
	}
	// path
	if i := strings.index_byte(rest, '/'); i >= 0 { s.path = rest[i:]; rest = rest[:i] }
	// port
	if i := strings.last_index_byte(rest, ':'); i >= 0 {
		port := rest[i + 1:]
		rest = rest[:i]
		if port != "*" { for c in transmute([]u8)port { if c < '0' || c > '9' { return {}, false } } }
		if port == "" { return {}, false }
		s.port = port
	}
	host := rest
	if host == "" { return {}, false }
	if host == "*" {
		// ok
	} else {
		h := host
		if strings.has_prefix(h, "*.") { h = h[2:] }
		if h == "" { return {}, false }
		for c in transmute([]u8)h {
			valid := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_'
			if !valid { return {}, false }
		}
	}
	// clone strings (slices of `tok` so far)
	s.scheme = strings.clone(s.scheme)
	s.host = strings.to_lower(host)
	s.port = strings.clone(s.port)
	s.path = strings.clone(s.path)
	return s, true
}

////////////////////////////////
// Directives and fallbacks

Directive_Kind :: enum u8 {
	Default_Src, Script_Src, Script_Src_Elem, Connect_Src, Img_Src, Style_Src, Style_Src_Elem, Font_Src, Media_Src,
	Manifest_Src, Object_Src, Worker_Src, Frame_Src, Child_Src, Base_Uri, Form_Action,
}

directive_name :: proc(k: Directive_Kind) -> string {
	switch k {
	case .Default_Src: return "default-src"
	case .Script_Src: return "script-src"
	case .Script_Src_Elem: return "script-src-elem"
	case .Connect_Src: return "connect-src"
	case .Img_Src: return "img-src"
	case .Style_Src: return "style-src"
	case .Style_Src_Elem: return "style-src-elem"
	case .Font_Src: return "font-src"
	case .Media_Src: return "media-src"
	case .Manifest_Src: return "manifest-src"
	case .Object_Src: return "object-src"
	case .Worker_Src: return "worker-src"
	case .Frame_Src: return "frame-src"
	case .Child_Src: return "child-src"
	case .Base_Uri: return "base-uri"
	case .Form_Action: return "form-action"
	}
	return ""
}

// The directive that applies to `k` in `p`, following the fallback chain ("get the effective directive's value").
@(private)
effective :: proc(p: ^Policy, k: Directive_Kind) -> (d: ^Directive, name: string) {
	chain: []Directive_Kind
	switch k {
	case .Script_Src_Elem: chain = {.Script_Src_Elem, .Script_Src, .Default_Src}
	case .Script_Src:      chain = {.Script_Src, .Default_Src}
	case .Style_Src_Elem:  chain = {.Style_Src_Elem, .Style_Src, .Default_Src}
	case .Style_Src:       chain = {.Style_Src, .Default_Src}
	case .Worker_Src:      chain = {.Worker_Src, .Child_Src, .Script_Src, .Default_Src}
	case .Frame_Src:       chain = {.Frame_Src, .Child_Src, .Default_Src}
	case .Child_Src:       chain = {.Child_Src, .Default_Src}
	case .Connect_Src, .Img_Src, .Font_Src, .Media_Src, .Manifest_Src, .Object_Src: chain = {k, .Default_Src}
	case .Default_Src:     chain = {.Default_Src}
	case .Base_Uri, .Form_Action: chain = {k}
	}
	for c in chain {
		n := directive_name(c)
		for &dir in p.directives { if dir.name == n { return &dir, n } }
	}
	return nil, ""
}

////////////////////////////////
// Matching (CSP3 §6.7.2)

@(private)
scheme_matches :: proc(a, b: string) -> bool {
	if a == b { return true }
	switch a {
	case "http":  return b == "https"
	case "ws":    return b == "wss" || b == "http" || b == "https"
	case "wss":   return b == "https"
	}
	return false
}

@(private)
port_for :: proc(u: url.URL) -> int { return url.effective_port(u) }

@(private)
host_matches :: proc(pattern, host: string) -> bool {
	if pattern == "*" { return true }
	if strings.has_prefix(pattern, "*.") {
		suffix := pattern[1:]   // ".example.com"
		return len(host) > len(suffix) && strings.has_suffix(host, suffix)
	}
	return pattern == host
}

@(private)
path_matches :: proc(pattern, path: string, redirected: bool) -> bool {
	if pattern == "" || redirected { return true }
	if pattern == "/" { return true }
	if strings.has_suffix(pattern, "/") { return strings.has_prefix(path, pattern) }
	return pattern == path
}

@(private)
matches_self :: proc(self: url.Origin, u: url.URL) -> bool {
	if self.opaque { return false }
	if self.host != u.host { return false }
	up := port_for(u)
	if self.port == up && scheme_matches(self.scheme, u.scheme) { return true }
	// an http self may upgrade to https on the default port (and ws to wss)
	if scheme_matches(self.scheme, u.scheme) && self.port == url.default_port(self.scheme) && up == url.default_port(u.scheme) { return true }
	return false
}

@(private)
source_matches_url :: proc(s: Source, self: url.Origin, u: url.URL, redirected: bool) -> bool {
	switch s.kind {
	case .Keyword:
		return s.keyword == .Self && matches_self(self, u)
	case .Scheme:
		return scheme_matches(s.scheme, u.scheme)
	case .Host:
		// scheme part (defaults to the protected resource's scheme)
		if s.scheme != "" {
			if !scheme_matches(s.scheme, u.scheme) { return false }
		} else if !self.opaque && !scheme_matches(self.scheme, u.scheme) {
			return false
		}
		if u.host == "" || !host_matches(s.host, u.host) { return false }
		if !port_ok(s, self, u) { return false }
		return path_matches(s.path, u.path, redirected)
	case .Nonce, .Hash:
		return false
	}
	return false
}

@(private)
port_ok :: proc(s: Source, self: url.Origin, u: url.URL) -> bool {
	up := port_for(u)
	switch {
	case s.port == "":  return up == url.default_port(u.scheme)
	case s.port == "*": return true
	}
	if s.port == itoa(up) { return true }
	// 443 written for an https source also covers the default port of the scheme it was upgraded to
	scheme := s.scheme != "" ? s.scheme : self.scheme
	return s.port == itoa(url.default_port(scheme)) && up == url.default_port(u.scheme)
}

@(private)
itoa :: proc(n: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_int(&sb, n)
	return strings.to_string(sb)
}

Violation :: struct {
	directive: string,     // the effective directive that was violated ("script-src-elem"...)
	original:  string,     // the policy text
	blocked:   string,     // the blocked URL
	enforced:  bool,       // false for report-only policies
}

Verdict :: struct {
	allowed:    bool,                // no *enforced* policy blocked it
	violations: [dynamic]Violation,  // temp-allocated: enforced and report-only
}

// May a request for `u` of kind `k` proceed? `self` is the protected document's origin.
check_request :: proc(l: ^Policy_List, k: Directive_Kind, u: url.URL, self: url.Origin, redirected := false, nonce := "") -> Verdict {
	v := Verdict{allowed = true, violations = make([dynamic]Violation, context.temp_allocator)}
	for &p in l.policies {
		d, name := effective(&p, k)
		if d == nil { continue }   // the policy says nothing about this kind of request
		if directive_allows(d, self, u, redirected, nonce) { continue }
		append(&v.violations, Violation{directive = name, original = p.raw, blocked = u.href, enforced = p.disposition == .Enforce})
		if p.disposition == .Enforce { v.allowed = false }
	}
	return v
}

@(private)
directive_allows :: proc(d: ^Directive, self: url.Origin, u: url.URL, redirected: bool, nonce: string) -> bool {
	if len(d.sources) == 0 { return false }   // an empty list is equivalent to 'none'
	has_none := false
	for s in d.sources {
		if s.kind == .Keyword && s.keyword == .None { has_none = true; continue }
		if s.kind == .Nonce && nonce != "" && s.value == nonce { return true }
		if source_matches_url(s, self, u, redirected) { return true }
	}
	_ = has_none   // 'none' never matches anything; kept to make the intent explicit
	return false
}

// Does a nonce (from the element's nonce attribute) satisfy the policies for kind `k`?
check_nonce :: proc(l: ^Policy_List, k: Directive_Kind, nonce: string) -> Verdict {
	v := Verdict{allowed = true, violations = make([dynamic]Violation, context.temp_allocator)}
	for &p in l.policies {
		d, name := effective(&p, k)
		if d == nil { continue }
		ok := false
		for s in d.sources { if s.kind == .Nonce && nonce != "" && s.value == nonce { ok = true } }
		if ok { continue }
		append(&v.violations, Violation{directive = name, original = p.raw, blocked = "nonce", enforced = p.disposition == .Enforce})
		if p.disposition == .Enforce { v.allowed = false }
	}
	return v
}

// Does any enforced policy contain this directive (upgrade-insecure-requests, block-all-mixed-content)?
has_directive :: proc(l: ^Policy_List, name: string) -> bool {
	for &p in l.policies {
		if p.disposition != .Enforce { continue }
		for d in p.directives { if d.name == name { return true } }
	}
	return false
}
