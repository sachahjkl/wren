package csp

import "core:strings"
import "wb:url"

// CSP Embedded Enforcement §4.2 "subsumption": whether the policies a response enforces are at least as strict as the policy
// its frame requires. Each directive of the required policy must be matched, in one enforced policy of the list, by a
// directive (its effective one, through the fetch directives' fallbacks) that allows nothing it does not:
//   * a source list: each of its URL expressions ('self', schemes, hosts with their wildcards, ports and paths) within one
//     of the required list's, its nonces and hashes among the required list's, no keyword ('unsafe-inline', 'unsafe-eval',
//     'strict-dynamic'...) the required list lacks; 'none' within anything;
//   * a required default-src: the policy's default-src and each fetch directive it sets of its own (one the required policy
//     does not name);
//   * sandbox: a sandbox that allows nothing more (its tokens among the required ones);
//   * any other directive (upgrade-insecure-requests...): present.
// `self`: the origin of the response, for 'self'.

// The fetch directives default-src stands for.
@(private = "file")
FETCH_DIRECTIVES :: [?]string{"script-src", "script-src-elem", "script-src-attr", "style-src", "style-src-elem", "style-src-attr",
	"connect-src", "img-src", "font-src", "media-src", "manifest-src", "object-src", "worker-src", "frame-src", "child-src"}

// The keywords that allow more than a list without them (the others say nothing of what loads).
@(private = "file")
WIDENING_KEYWORDS :: [?]Keyword{.Unsafe_Inline, .Unsafe_Eval, .Wasm_Unsafe_Eval, .Strict_Dynamic, .Unsafe_Hashes}

policy_list_subsumes :: proc(l: ^Policy_List, required: ^Policy, self: url.Origin) -> bool {
	for &want in required.directives {
		found := false
		for &pol in l.policies {
			if pol.disposition != .Enforce { continue }
			if directive_subsumed(&pol, &want, required, self) { found = true; break }
		}
		if !found { return false }
	}
	return true
}

// Is `want` (a directive of `required`) at least as strict in `pol`?
@(private = "file")
directive_subsumed :: proc(pol: ^Policy, want: ^Directive, required: ^Policy, self: url.Origin) -> bool {
	switch want.name {
	case "sandbox":
		have := find(pol, "sandbox")
		if have == nil { return false }
		allowed := split_ws(want.raw)
		next: for tok in split_ws(have.raw) {
			for a in allowed { if a == tok { continue next } }
			return false
		}
		return true
	case "default-src":
		have := find(pol, "default-src")
		if have == nil || !sources_subsumed(have, want, self) { return false }
		for name in FETCH_DIRECTIVES {
			if find(required, name) != nil { continue }   // (its own directive of the required policy decides)
			if own := find(pol, name); own != nil && !sources_subsumed(own, want, self) { return false }
		}
		return true
	}
	have := effective_named(pol, want.name)
	if have == nil { return false }
	if !is_source_list(want.name) { return true }
	return sources_subsumed(have, want, self)
}

@(private = "file")
find :: proc(p: ^Policy, name: string) -> ^Directive {
	for &d in p.directives { if d.name == name { return &d } }
	return nil
}

// The directive of `p` that governs `name`: itself, else the fetch directives' fallbacks (CSP 3 §6.8.3).
@(private = "file")
effective_named :: proc(p: ^Policy, name: string) -> ^Directive {
	chain: []string
	switch name {
	case "script-src-elem", "script-src-attr": chain = {name, "script-src", "default-src"}
	case "style-src-elem", "style-src-attr":   chain = {name, "style-src", "default-src"}
	case "worker-src":                         chain = {name, "child-src", "script-src", "default-src"}
	case "frame-src":                          chain = {name, "child-src", "default-src"}
	case:
		chain = {name}
		for f in FETCH_DIRECTIVES { if f == name { chain = {name, "default-src"}; break } }
	}
	for n in chain { if d := find(p, n); d != nil { return d } }
	return nil
}

@(private = "file")
is_source_list :: proc(name: string) -> bool {
	switch name {
	case "default-src", "base-uri", "form-action", "frame-ancestors", "navigate-to": return true
	}
	for f in FETCH_DIRECTIVES { if f == name { return true } }
	return false
}

// Does the source list of `have` allow nothing that `want`'s does not?
@(private = "file")
sources_subsumed :: proc(have, want: ^Directive, self: url.Origin) -> bool {
	if allows_none(have) { return true }
	if allows_none(want) { return false }
	for k in WIDENING_KEYWORDS {
		if has_keyword(have, k) && !has_keyword(want, k) { return false }
	}
	next: for &s in have.sources {
		switch s.kind {
		case .Keyword:
			if s.keyword != .Self { continue }
			for &w in want.sources { if self_within(w, self) { continue next } }
			return false
		case .Nonce, .Hash:
			for &w in want.sources { if w.kind == s.kind && w.value == s.value && w.algo == s.algo { continue next } }
			return false
		case .Scheme, .Host:
			for &w in want.sources { if source_within(s, w, self) { continue next } }
			return false
		}
	}
	return true
}

// 'none', or a list with no source (an empty directive allows nothing).
@(private = "file")
allows_none :: proc(d: ^Directive) -> bool {
	for s in d.sources { if !(s.kind == .Keyword && (s.keyword == .None || s.keyword == .Report_Sample)) { return false } }
	return true
}

// Does the required expression `w` allow the response's own origin ('self')?
@(private = "file")
self_within :: proc(w: Source, self: url.Origin) -> bool {
	if w.kind == .Keyword { return w.keyword == .Self }
	if self.opaque || (w.kind != .Scheme && w.kind != .Host) { return false }
	u := url.URL{scheme = self.scheme, host = self.host, port = self.port == url.default_port(self.scheme) ? -1 : self.port}
	return source_matches_url(w, self, u, false)
}

// Does the required expression `w` allow everything the returned scheme or host expression `s` allows?
@(private = "file")
source_within :: proc(s, w: Source, self: url.Origin) -> bool {
	// a bare *: every network scheme, which only another bare * allows
	bare :: proc(x: Source) -> bool { return x.kind == .Host && x.host == "*" && x.scheme == "" && x.port == "" && x.path == "" }
	if bare(s) { return bare(w) }
	// the scheme `s` stands for: its own, else the protected resource's
	scheme := s.scheme != "" ? s.scheme : (self.opaque ? "" : self.scheme)
	network := scheme == "http" || scheme == "https" || scheme == "ws" || scheme == "wss"
	switch w.kind {
	case .Keyword:
		// 'self': a host source of exactly the protected origin (any of its paths)
		if w.keyword != .Self || s.kind != .Host || s.host == "*" || strings.has_prefix(s.host, "*.") || s.port == "*" { return false }
		return matches_self(self, url.URL{scheme = scheme, host = s.host, port = port_number(s.port, scheme)})
	case .Nonce, .Hash:
		return false
	case .Scheme:
		return scheme != "" && scheme_matches(w.scheme, scheme)
	case .Host:
		if bare(w) { return network || (s.kind == .Scheme && scheme == self.scheme) }
		if s.kind == .Scheme { return false }   // a whole scheme within one host
		ws := w.scheme != "" ? w.scheme : (self.opaque ? "" : self.scheme)
		if !scheme_matches(ws, scheme) { return false }
		if !host_within(s.host, w.host) { return false }
		if w.port != "*" && (s.port == "*" || port_number(s.port, scheme) != port_number(w.port, ws)) { return false }
		return w.path == "" || w.path == "/" || (strings.has_suffix(w.path, "/") ? strings.has_prefix(s.path, w.path) : s.path == w.path)
	}
	return false
}

// Is every host the pattern `h` names one that the pattern `w` names?
@(private = "file")
host_within :: proc(h, w: string) -> bool {
	if w == "*" { return true }
	if h == "*" { return false }
	if strings.has_prefix(w, "*.") {
		suffix := w[1:]   // ".example.com"
		return strings.has_suffix(h, suffix) && len(h) > len(suffix)
	}
	return h == w
}

// A port expression as a number ("" the scheme's default).
@(private = "file")
port_number :: proc(p, scheme: string) -> int {
	if p == "" { return url.default_port(scheme) }
	n := 0
	for c in transmute([]u8)p { n = n * 10 + int(c - '0') }
	return n
}
