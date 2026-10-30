package csp

// Content Security Policy for JavaScript (CSP 3 §6.7, "script-src", "script-src-elem", "script-src-attr"):
//   * external scripts: nonces, and 'strict-dynamic' (only nonces and hashes count for parser-inserted scripts; a
//     script inserted by another script is trusted);
//   * inline code: a script element's text, an event handler attribute, a javascript: URL. Allowed by a nonce
//     (elements only), by a hash of the code ('sha256-...', for attributes and javascript: URLs only with
//     'unsafe-hashes'), or by 'unsafe-inline' when the list has no nonce, no hash and no 'strict-dynamic';
//   * eval() and its relatives: 'unsafe-eval'.
// Hashing is the caller's (a digest of the code's UTF-8, base64): this package does no cryptography.

import "core:strings"
import "wb:url"

Inline_Kind :: enum u8 {
	Script_Element,   // <script> text: script-src-elem, script-src, default-src
	Script_Attribute, // onclick="...": script-src-attr, script-src, default-src
	Navigation,       // javascript: URL: script-src-elem, script-src, default-src
}

// The base64 digest of `source` with `algo` ("sha256", "sha384", "sha512"), "" when unavailable.
Digest_Proc :: #type proc(user: rawptr, algo: string, source: string) -> string

@(private = "file")
find_directive :: proc(p: ^Policy, names: []string) -> (^Directive, string) {
	for n in names {
		for &d in p.directives { if d.name == n { return &d, n } }
	}
	return nil, ""
}

@(private = "file")
has_keyword :: proc(d: ^Directive, k: Keyword) -> bool {
	for s in d.sources { if s.kind == .Keyword && s.keyword == k { return true } }
	return false
}

@(private = "file")
nonce_matches :: proc(d: ^Directive, nonce: string) -> bool {
	if nonce == "" { return false }
	for s in d.sources { if s.kind == .Nonce && s.value == nonce { return true } }
	return false
}

// base64url and base64 name the same digest
@(private = "file")
same_digest :: proc(a_in, b_in: string) -> bool {
	// padding may be left out on either side
	a, b := strings.trim_right(a_in, "="), strings.trim_right(b_in, "=")
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if x == '-' { x = '+' }
		if x == '_' { x = '/' }
		if y == '-' { y = '+' }
		if y == '_' { y = '/' }
		if x != y { return false }
	}
	return true
}

@(private = "file")
hash_matches :: proc(d: ^Directive, source: string, digest: Digest_Proc, user: rawptr) -> bool {
	if digest == nil { return false }
	for s in d.sources {
		if s.kind != .Hash { continue }
		got := digest(user, s.algo, source)
		if got != "" && same_digest(got, s.value) { return true }
	}
	return false
}

// "Does a source list allow all inline behavior for type?"
@(private = "file")
allows_all_inline :: proc(d: ^Directive) -> bool {
	inline := false
	for s in d.sources {
		switch s.kind {
		case .Nonce, .Hash: return false
		case .Keyword:
			if s.keyword == .Strict_Dynamic { return false }
			if s.keyword == .Unsafe_Inline { inline = true }
		case .Scheme, .Host:
		}
	}
	return inline
}

// May the external script at `u` be fetched? `parser_inserted`: the parser inserted its element.
check_script_request :: proc(l: ^Policy_List, u: url.URL, self: url.Origin, redirected: bool, nonce: string, parser_inserted: bool) -> Verdict {
	v := Verdict{allowed = true, violations = make([dynamic]Violation, context.temp_allocator)}
	for &p in l.policies {
		d, name := find_directive(&p, {"script-src-elem", "script-src", "default-src"})
		if d == nil { continue }
		ok := false
		if nonce_matches(d, nonce) {
			ok = true
		} else if has_keyword(d, .Strict_Dynamic) {
			// host and scheme sources, 'self' and 'unsafe-inline' are ignored
			ok = !parser_inserted
		} else {
			ok = directive_allows(d, self, u, redirected, nonce)
		}
		if ok { continue }
		append(&v.violations, Violation{directive = name, original = p.raw, blocked = u.href, enforced = p.disposition == .Enforce})
		if p.disposition == .Enforce { v.allowed = false }
	}
	return v
}

// May this inline code run? `nonce`: the element's (script elements only).
check_inline :: proc(l: ^Policy_List, kind: Inline_Kind, source: string, nonce: string, digest: Digest_Proc, user: rawptr) -> Verdict {
	v := Verdict{allowed = true, violations = make([dynamic]Violation, context.temp_allocator)}
	for &p in l.policies {
		d: ^Directive
		name: string
		switch kind {
		case .Script_Element, .Navigation: d, name = find_directive(&p, {"script-src-elem", "script-src", "default-src"})
		case .Script_Attribute:            d, name = find_directive(&p, {"script-src-attr", "script-src", "default-src"})
		}
		if d == nil { continue }
		ok := false
		switch {
		case kind == .Script_Element && nonce_matches(d, nonce): ok = true
		case (kind == .Script_Element || has_keyword(d, .Unsafe_Hashes)) && hash_matches(d, source, digest, user): ok = true
		case allows_all_inline(d): ok = true
		}
		if ok { continue }
		append(&v.violations, Violation{directive = name, original = p.raw, blocked = "inline", enforced = p.disposition == .Enforce})
		if p.disposition == .Enforce { v.allowed = false }
	}
	return v
}

// May a page compile a WebAssembly module? 'wasm-unsafe-eval' or 'unsafe-eval' (CSP 3 §6.7.2.6).
check_wasm_eval :: proc(l: ^Policy_List) -> Verdict {
	v := Verdict{allowed = true, violations = make([dynamic]Violation, context.temp_allocator)}
	for &p in l.policies {
		d, name := find_directive(&p, {"script-src", "default-src"})
		if d == nil || has_keyword(d, .Unsafe_Eval) || has_keyword(d, .Wasm_Unsafe_Eval) { continue }
		append(&v.violations, Violation{directive = name, original = p.raw, blocked = "wasm-eval", enforced = p.disposition == .Enforce})
		if p.disposition == .Enforce { v.allowed = false }
	}
	return v
}

// May code be compiled from a string (eval, new Function, setTimeout(string))?
check_eval :: proc(l: ^Policy_List) -> Verdict {
	v := Verdict{allowed = true, violations = make([dynamic]Violation, context.temp_allocator)}
	for &p in l.policies {
		d, name := find_directive(&p, {"script-src", "default-src"})
		if d == nil || has_keyword(d, .Unsafe_Eval) { continue }
		append(&v.violations, Violation{directive = name, original = p.raw, blocked = "eval", enforced = p.disposition == .Enforce})
		if p.disposition == .Enforce { v.allowed = false }
	}
	return v
}
