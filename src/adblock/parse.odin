package adblock

import "core:slice"
import "core:strings"

// Filter classes: each one is its own index (a request asks "is it blocked?" first and consults the others only when it
// has to).
Class :: enum u8 {
	Block,              // blocking filters (`$important` is a flag), `$redirect=` ones included
	Allow,              // `@@` exceptions
	Redirect,           // `$redirect=` / `$redirect-rule=`: which neutral resource answers a blocked request
	Redirect_Allow,     // `@@...$redirect=`
	Removeparam,        // `$removeparam=`
	Removeparam_Allow,
	Csp,                // `$csp=`
	Csp_Allow,
	Header,             // `$header=`: blocks when a response header matches
	Header_Allow,
	Replace,            // `$replace=/search/replacement/flags`: rewrites the text of the response
	Replace_Allow,
	Page,               // exceptions that switch filtering off for a whole page: `$document`, `$elemhide`, `$generichide`, `$specifichide`
}
CLASS_COUNT :: len(Class)

// Sorted hash lists of a `domain=` style option.
Domain_Spec :: struct {
	inc: [dynamic]u32,
	exc: [dynamic]u32,
}

Net_Draft :: struct {
	pattern:  string,
	flags:    Filter_Flags,
	types:    Resource_Set,
	methods:  Method_Set,
	src:      Domain_Spec,
	to:       Domain_Spec,
	arg:      string,
	class:    Class,
	redirect_blocks: bool,     // `$redirect=`: the filter blocks too (a copy goes to the Block class)
	list:     u8,
	text_off: u32,
	bad:      bool,            // `$badfilter`
	key:      u64,             // identity for `$badfilter`
}

Cos_Flag :: enum u16 {
	Exception,
	Procedural,    // needs the DOM evaluator (`:has-text()` ...)
	Scriptlet,     // `##+js(...)`
	Html,          // `##^...`
	Style_Inject,  // AdGuard `#$#sel { css }`
	Js_Raw,        // AdGuard `#%#javascript`
	Style,         // the selector ends with `:style(...)`
	Remove,        // the selector ends with `:remove()`
	Generic,       // no domain restriction (negated domains only)
	Keyed,         // a class / id the selector needs is known: `key` is set
}
Cos_Flags :: bit_set[Cos_Flag; u16]

Cos_Draft :: struct {
	selector: string,
	flags:    Cos_Flags,
	src:      Domain_Spec,
	key:      u32,         // hash of ".class" / "#id" the selector needs (Keyed)
	list:     u8,
	text_off: u32,
}

Parsed :: struct {
	kind: enum u8 { None, Net, Cos },
	net:  Net_Draft,
	cos:  Cos_Draft,
}

// A hosts-file line (`0.0.0.0 ads.example.com`): the host, or "".
@(private)
hosts_line_host :: proc(line: string) -> string {
	if len(line) < 9 { return "" }
	i := 0
	for i < len(line) && (line[i] == '.' || (line[i] >= '0' && line[i] <= '9')) { i += 1 }
	if i == 0 || i >= len(line) || (line[i] != ' ' && line[i] != '\t') { return "" }
	ip := line[:i]
	if ip != "0.0.0.0" && ip != "127.0.0.1" { return "" }
	rest := strings.trim_space(line[i:])
	if j := strings.index_any(rest, " \t#"); j >= 0 { rest = rest[:j] }
	if rest == "" || rest == "localhost" || rest == "localhost.localdomain" || rest == "local" || rest == "broadcasthost" || rest == "0.0.0.0" || rest == "ip6-localhost" { return "" }
	for k in 0 ..< len(rest) { c := rest[k]; if !(is_alnum(c) || c == '.' || c == '-' || c == '_') { return "" } }
	if strings.index_byte(rest, '.') < 0 { return "" }
	return rest
}

// Parses one line of a list. Strings in the result are slices of `line` or allocated with `allocator`.
parse_line :: proc(line_in: string, list: u8, text_off: u32, allocator := context.allocator) -> (p: Parsed) {
	context.allocator = allocator
	line := strings.trim_space(line_in)
	if len(line) == 0 || len(line) > 8192 { return }
	switch line[0] {
	case '!': return
	case '[':
		if strings.has_prefix(line, "[Adblock") || strings.has_prefix(line, "[uBlock") { return }
	case '#':
		if len(line) > 1 && (line[1] == ' ' || line[1] == '\t') { return }   // a comment of a hosts file
	}
	if h := hosts_line_host(line); h != "" {
		d := Net_Draft{list = list, text_off = text_off, types = DEFAULT_TYPES, class = .Block}
		d.pattern = has_upper(h) ? strings.to_lower(h) : h
		d.flags = {.Host_Anchor, .Host_Only}
		finish_net(&d)
		return Parsed{kind = .Net, net = d}
	}
	if c, ok := parse_cosmetic(line, list, text_off); ok {
		return Parsed{kind = .Cos, cos = c}
	}
	d := Net_Draft{list = list, text_off = text_off}
	if parse_network(line, &d) {
		finish_net(&d)
		return Parsed{kind = .Net, net = d}
	}
	return
}

////////////////////////////////
// Network filters

@(private)
looks_like_options :: proc(o: string) -> bool {
	if len(o) == 0 { return false }
	i := 0
	if o[0] == '~' { i = 1 }
	j := i
	for j < len(o) && (is_alnum(o[j]) || o[j] == '_' || o[j] == '-') { j += 1 }
	if j == i { return false }
	return j == len(o) || o[j] == ',' || o[j] == '='
}

@(private)
parse_domain_spec :: proc(s: string, sep: u8, spec: ^Domain_Spec, all_exc := false) -> bool {
	if s == "" { return false }
	rest := s
	for len(rest) > 0 {
		i := strings.index_byte(rest, sep)
		item: string
		if i < 0 { item, rest = rest, "" } else { item, rest = rest[:i], rest[i + 1:] }
		item = strings.trim_space(item)
		if item == "" { continue }
		neg := all_exc
		if item[0] == '~' { neg = true; item = item[1:] }
		if len(item) == 0 || item[0] == '/' { return false }   // regular-expression domains: not supported
		entity := false
		if strings.has_suffix(item, ".*") { entity = true; item = item[:len(item) - 2] }
		if item == "" || item == "*" { return false }
		buf: [256]u8
		if len(item) > len(buf) { return false }
		lower_into(buf[:], item)
		h := entity ? hash_entity(string(buf[:len(item)])) : hash_str(string(buf[:len(item)]))
		if neg { append(&spec.exc, h) } else { append(&spec.inc, h) }
	}
	return len(spec.inc) + len(spec.exc) > 0
}

@(private)
spec_normalize :: proc(s: ^Domain_Spec) {
	norm :: proc(a: ^[dynamic]u32) {
		if len(a^) < 2 { return }
		slice.sort(a[:])
		w := 1
		for i in 1 ..< len(a^) { if a[i] != a[w - 1] { a[w] = a[i]; w += 1 } }
		resize(a, w)
	}
	norm(&s.inc); norm(&s.exc)
}

@(private)
abp_resource_alias :: proc(n: string) -> string {
	switch n {
	case "blank-css": return "noop.css"
	case "blank-js": return "noop.js"
	case "blank-html": return "noopframe"
	case "blank-mp3": return "noopmp3-0.1s"
	case "blank-mp4": return "noopmp4-1s"
	case "1x1-transparent-gif": return "1x1.gif"
	case "2x2-transparent-png": return "2x2.png"
	case "3x2-transparent-png": return "3x2.png"
	case "32x32-transparent-png": return "32x32.png"
	}
	return n
}

@(private)
parse_network :: proc(line: string, d: ^Net_Draft) -> bool {
	s := line
	if strings.has_prefix(s, "@@") { d.flags += {.Exception}; s = s[2:] }
	if len(s) == 0 { return false }

	opts := ""
	pat := s
	dollar := len(s)
	for dollar > 0 {
		dollar = strings.last_index_byte(s[:dollar], '$')
		if dollar < 0 { break }
		if looks_like_options(s[dollar + 1:]) { opts = s[dollar + 1:]; pat = s[:dollar]; break }
	}

	pos, neg: Resource_Set
	has_pos := false
	exception := .Exception in d.flags
	redirect_name, redirect_rule, removeparam, csp_arg, header_arg, replace_arg: string
	has_redirect, has_redirect_rule, has_removeparam, has_csp, has_header, has_replace := false, false, false, false, false, false
	match_case := false
	set_party :: proc(d: ^Net_Draft, third: bool) { d.flags += {third ? .Third_Party : .First_Party} }

	if opts != "" {
		rest := opts
		for len(rest) > 0 {
			i := strings.index_byte(rest, ',')
			o: string
			if i < 0 { o, rest = rest, "" } else { o, rest = rest[:i], rest[i + 1:] }
			o = strings.trim_space(o)
			if o == "" { continue }
			negated := false
			if o[0] == '~' { negated = true; o = o[1:] }
			name, value := o, ""
			has_value := false
			if e := strings.index_byte(o, '='); e >= 0 { name, value = o[:e], o[e + 1:]; has_value = true }
			add_type :: proc(r: Resource, negated: bool, pos, neg: ^Resource_Set, has_pos: ^bool) {
				if negated { neg^ += {r} } else { pos^ += {r}; has_pos^ = true }
			}
			switch name {
			case "script": add_type(.Script, negated, &pos, &neg, &has_pos)
			case "image": add_type(.Image, negated, &pos, &neg, &has_pos)
			case "stylesheet", "css": add_type(.Stylesheet, negated, &pos, &neg, &has_pos)
			case "subdocument", "frame": add_type(.Subdocument, negated, &pos, &neg, &has_pos)
			case "xmlhttprequest", "xhr": add_type(.Xhr, negated, &pos, &neg, &has_pos)
			case "object", "object-subrequest": add_type(.Object, negated, &pos, &neg, &has_pos)
			case "font": add_type(.Font, negated, &pos, &neg, &has_pos)
			case "media": add_type(.Media, negated, &pos, &neg, &has_pos)
			case "ping": add_type(.Ping, negated, &pos, &neg, &has_pos)
			case "websocket": add_type(.Websocket, negated, &pos, &neg, &has_pos)
			case "other": add_type(.Other, negated, &pos, &neg, &has_pos)
			case "document", "doc": add_type(.Document, negated, &pos, &neg, &has_pos)
			case "popup": add_type(.Popup, negated, &pos, &neg, &has_pos)
			case "webrtc": add_type(.Webrtc, negated, &pos, &neg, &has_pos)
			case "csp_report": add_type(.Csp_Report, negated, &pos, &neg, &has_pos)
			case "inline-script":
				add_type(.Inline_Script, negated, &pos, &neg, &has_pos)
				if !negated { has_csp = true; csp_arg = "script-src 'unsafe-eval' * blob: data:" }
			case "inline-font":
				add_type(.Inline_Font, negated, &pos, &neg, &has_pos)
				if !negated { has_csp = true; csp_arg = "font-src *" }
			case "cname": // resolved names are not looked at: the filter applies to the request's own host
			case "all":
				if negated { return false }
				pos += ALL_TYPES; has_pos = true
				if exception { pos += PAGE_SWITCHES }
			case "elemhide", "ehide": if negated { return false }; pos += {.Elemhide}; has_pos = true
			case "generichide", "ghide": if negated { return false }; pos += {.Generichide}; has_pos = true
			case "specifichide", "shide": if negated { return false }; pos += {.Specifichide}; has_pos = true
			case "genericblock": // accepted, does nothing
			case "third-party", "3p": set_party(d, !negated)
			case "first-party", "1p": set_party(d, negated)
			case "strict3p": set_party(d, true)
			case "strict1p": set_party(d, false)
			case "important": d.flags += {.Important}
			case "match-case": match_case = true
			case "badfilter": d.bad = true
			case "domain", "from":
				if !has_value || !parse_domain_spec(value, '|', &d.src) { return false }
			case "to":
				if !has_value || !parse_domain_spec(value, '|', &d.to) { return false }
			case "denyallow":
				if !has_value || !parse_domain_spec(value, '|', &d.to, true) { return false }
			case "method":
				if !has_value { return false }
				ms: Method_Set
				mneg: Method_Set
				for m in strings.split(value, "|", context.temp_allocator) {
					mm := m
					isneg := false
					if strings.has_prefix(mm, "~") { isneg = true; mm = mm[1:] }
					switch strings.to_lower(mm, context.temp_allocator) {
					case "get": if isneg { mneg += {.Get} } else { ms += {.Get} }
					case "post": if isneg { mneg += {.Post} } else { ms += {.Post} }
					case "put": if isneg { mneg += {.Put} } else { ms += {.Put} }
					case "delete": if isneg { mneg += {.Delete} } else { ms += {.Delete} }
					case "head": if isneg { mneg += {.Head} } else { ms += {.Head} }
					case "options": if isneg { mneg += {.Options} } else { ms += {.Options} }
					case "patch": if isneg { mneg += {.Patch} } else { ms += {.Patch} }
					case "connect": if isneg { mneg += {.Connect} } else { ms += {.Connect} }
					case "trace": if isneg { mneg += {.Trace} } else { ms += {.Trace} }
					case: return false
					}
				}
				if ms == {} { ms = Method_Set{.Get, .Post, .Put, .Delete, .Head, .Options, .Patch, .Connect, .Trace} }
				d.methods = ms - mneg
				if d.methods == {} { return false }
			case "redirect", "redirect-rule", "rewrite":
				v := value
				if name == "rewrite" {
					if !strings.has_prefix(v, "abp-resource:") { return false }
					v = abp_resource_alias(v[len("abp-resource:"):])
				}
				if c := strings.last_index_byte(v, ':'); c > 0 && c + 1 < len(v) && v[c + 1] >= '0' && v[c + 1] <= '9' { v = v[:c] }   // a priority
				if name == "redirect-rule" { has_redirect_rule = true; redirect_rule = v } else { has_redirect = true; redirect_name = v }
				if v == "" && !exception { return false }
			case "empty": has_redirect = true; redirect_name = "empty"
			case "mp4": has_redirect = true; redirect_name = "noopmp4-1s"
			case "removeparam", "queryprune":
				has_removeparam = true; removeparam = value
				if negated { return false }
			case "replace":
				if negated || (!has_value && !exception) { return false }
				has_replace = true; replace_arg = value
			case "csp":
				has_csp = true; csp_arg = value
			case "header":
				if !has_value { return false }
				has_header = true; header_arg = value
			case: return false   // unknown or unsupported (`replace=`, `cookie=`, `permissions=`...): the filter is dropped
			}
		}
	}

	// the pattern
	p := pat
	regex := false
	if len(p) > 2 && p[0] == '/' && p[len(p) - 1] == '/' {
		regex = true
		p = p[1:len(p) - 1]
	} else {
		if strings.has_prefix(p, "||") { d.flags += {.Host_Anchor}; p = p[2:] } else if strings.has_prefix(p, "|") { d.flags += {.Left_Anchor}; p = p[1:] }
		if len(p) > 0 && p[len(p) - 1] == '|' { d.flags += {.Right_Anchor}; p = p[:len(p) - 1] }
		for len(p) > 0 && p[0] == '*' { p = p[1:]; d.flags -= {.Host_Anchor, .Left_Anchor} }
		for len(p) > 0 && p[len(p) - 1] == '*' { p = p[:len(p) - 1]; d.flags -= {.Right_Anchor} }
	}
	if len(p) > 4096 { return false }
	if match_case { d.flags += {.Match_Case} }
	if regex {
		d.flags += {.Regex, .Needs_Original}
		re, ok := regex_compile(p, !match_case)
		if !ok { return false }
		regex_destroy(&re)
		d.pattern = p
	} else {
		if match_case && has_upper(p) { d.flags += {.Needs_Original} }
		d.pattern = (!match_case && has_upper(p)) ? strings.to_lower(p) : p
	}
	if len(d.pattern) == 0 {
		if opts == "" && !regex { return false }
		d.flags += {.Empty_Pattern}
		d.flags -= {.Host_Anchor, .Left_Anchor, .Right_Anchor}
	}
	// `||host^`
	if .Host_Anchor in d.flags && !regex && d.flags & {.Left_Anchor, .Right_Anchor} == {} && len(d.pattern) > 1 && d.pattern[len(d.pattern) - 1] == '^' {
		host := d.pattern[:len(d.pattern) - 1]
		ok := len(host) > 0 && host[0] != '.' && host[len(host) - 1] != '.'
		for k in 0 ..< len(host) {
			c := host[k]
			if !(is_alnum(c) || c == '.' || c == '-' || c == '_') || (c == '.' && k > 0 && host[k - 1] == '.') { ok = false; break }
		}
		if ok { d.flags += {.Host_Only}; d.pattern = host }
	}

	// the class and the types
	types := has_pos ? pos : DEFAULT_TYPES
	switch {
	case has_csp:
		types = has_pos ? pos : FRAME_TYPES
		if types - {.Inline_Script, .Inline_Font} == {} { types = FRAME_TYPES }
		d.arg = csp_arg
		d.class = exception ? .Csp_Allow : .Csp
	case has_replace:
		if !has_pos { types = DEFAULT_TYPES + {.Document} }
		d.arg = replace_arg
		d.class = exception ? .Replace_Allow : .Replace
	case has_removeparam:
		if !has_pos { types = DEFAULT_TYPES + {.Document} }
		d.arg = removeparam
		d.class = exception ? .Removeparam_Allow : .Removeparam
	case has_header:
		d.arg = header_arg
		d.class = exception ? .Header_Allow : .Header
	case has_redirect:
		d.arg = redirect_name
		d.class = exception ? .Redirect_Allow : .Redirect
		d.redirect_blocks = !exception
	case has_redirect_rule:
		d.arg = redirect_rule
		d.class = exception ? .Redirect_Allow : .Redirect
		d.flags += {.Redirect_Rule}
	case exception:
		d.class = .Allow
	case:
		d.class = .Block
	}
	types -= neg
	if has_pos && types == {} { return false }
	d.types = types   // an exception with a page switch (or `document`) also acts on the page itself: the builder files it twice
	if .Third_Party in d.flags && .First_Party in d.flags { return false }
	if d.class == .Block && d.types == {} { return false }
	return true
}

// Computes the identity that `$badfilter` refers to: everything but the badfilter option itself.
@(private)
finish_net :: proc(d: ^Net_Draft) {
	spec_normalize(&d.src)
	spec_normalize(&d.to)
	h := u64(14695981039346656037)
	mix :: proc(h: ^u64, v: u64) { h^ = (h^ ~ v) * 1099511628211 }
	mix(&h, u64(d.class)); mix(&h, u64(transmute(u16)d.flags)); mix(&h, u64(transmute(u32)d.types)); mix(&h, u64(transmute(u16)d.methods))
	for i in 0 ..< len(d.pattern) { mix(&h, u64(d.pattern[i])) }
	mix(&h, 0xff)
	for i in 0 ..< len(d.arg) { mix(&h, u64(d.arg[i])) }
	mix(&h, 0xfe)
	for v in d.src.inc { mix(&h, u64(v)) }
	mix(&h, 0xfd)
	for v in d.src.exc { mix(&h, u64(v)) }
	mix(&h, 0xfc)
	for v in d.to.inc { mix(&h, u64(v)) }
	mix(&h, 0xfb)
	for v in d.to.exc { mix(&h, u64(v)) }
	d.key = h
}

////////////////////////////////
// Cosmetic filters

@(private)
Cos_Sep :: struct { len: int, exception: bool, procedural: bool, style_inject: bool, js_raw: bool }

@(private)
cos_separator :: proc(rest: string) -> (sep: Cos_Sep, ok: bool) {
	// longest forms first
	forms := [?]struct { s: string, ex, pr, st, js: bool }{
		{"#@$?#", true, true, true, false}, {"#$?#", false, true, true, false},
		{"#@?#", true, true, false, false}, {"#?#", false, true, false, false},
		{"#@$#", true, false, true, false}, {"#$#", false, false, true, false},
		{"#@%#", true, false, false, true}, {"#%#", false, false, false, true},
		{"#@#", true, false, false, false}, {"##", false, false, false, false},
	}
	for f in forms {
		if strings.has_prefix(rest, f.s) { return Cos_Sep{len(f.s), f.ex, f.pr, f.st, f.js}, true }
	}
	return {}, false
}

@(private)
PROCEDURAL_OPS :: [?]string{
	":has-text(", ":contains(", ":-abp-contains(", ":-abp-has(", ":-abp-properties(", ":matches-css(", ":matches-css-before(", ":matches-css-after(",
	":matches-media(", ":matches-path(", ":matches-attr(", ":matches-property(", ":min-text-length(", ":nth-ancestor(", ":upward(",
	":xpath(", ":others(", ":watch-attr(", ":remove-attr(", ":remove-class(", ":-abp-contains (",
}

// Does the selector use an operator that the style engine cannot evaluate?
@(private)
selector_is_procedural :: proc(sel: string) -> bool {
	if strings.index_byte(sel, ':') < 0 { return false }
	for op in PROCEDURAL_OPS { if strings.contains(sel, op) { return true } }
	return false
}

// The class or id (as ".name" / "#name" hashed) that an element must carry for the selector to match: from the last
// compound selector. ok = false when it has none (tag and attribute selectors).
@(private)
selector_key :: proc(sel: string) -> (key: u32, ok: bool) {
	// find the last compound: after the last combinator outside brackets, parentheses and quotes
	depth_b, depth_p := 0, 0
	quote: u8 = 0
	last := 0
	for i in 0 ..< len(sel) {
		c := sel[i]
		if quote != 0 { if c == quote && (i == 0 || sel[i - 1] != '\\') { quote = 0 }; continue }
		switch c {
		case '"', '\'': quote = c
		case '[': depth_b += 1
		case ']': depth_b -= 1
		case '(': depth_p += 1
		case ')': depth_p -= 1
		case ' ', '>', '+', '~', ',':
			if depth_b == 0 && depth_p == 0 { last = i + 1 }
		}
	}
	comp := sel[last:]
	if strings.contains(sel, ",") { return 0, false }   // a selector list: not a single compound (kept un-keyed)
	// the first .class / #id of the compound outside brackets and parentheses
	depth_b, depth_p = 0, 0
	quote = 0
	i := 0
	for i < len(comp) {
		c := comp[i]
		if quote != 0 { if c == quote { quote = 0 }; i += 1; continue }
		switch c {
		case '"', '\'': quote = c
		case '[': depth_b += 1
		case ']': depth_b -= 1
		case '(': depth_p += 1
		case ')': depth_p -= 1
		case '\\': return 0, false   // an escape: give up on keying exotic names
		case '.', '#':
			if depth_b == 0 && depth_p == 0 {
				j := i + 1
				for j < len(comp) && (is_alnum(comp[j]) || comp[j] == '_' || comp[j] == '-' || comp[j] >= 0x80) { j += 1 }
				if j == i + 1 { return 0, false }
				return class_key(c, comp[i + 1:j]), true
			}
		}
		i += 1
	}
	return 0, false
}

// Hash of "." + name or "#" + name.
class_key :: proc "contextless" (prefix: u8, name: string) -> u32 {
	h := FNV_OFFSET
	h = (h ~ u32(prefix)) * FNV_PRIME
	for i in 0 ..< len(name) { h = (h ~ u32(name[i])) * FNV_PRIME }
	return h == 0 ? 1 : h
}

@(private)
parse_cosmetic :: proc(line: string, list: u8, text_off: u32) -> (c: Cos_Draft, ok: bool) {
	// the first '#' that opens a cosmetic separator after a plausible domain list
	at := 0
	for {
		i := strings.index_byte(line[at:], '#')
		if i < 0 { return {}, false }
		i += at
		dom := line[:i]
		valid := true
		for k in 0 ..< len(dom) {
			ch := dom[k]
			if !(is_alnum(ch) || ch == '.' || ch == ',' || ch == '~' || ch == '*' || ch == '_' || ch == '-') { valid = false; break }
		}
		if !valid { return {}, false }
		sep, found := cos_separator(line[i:])
		if !found { at = i + 1; continue }
		body := strings.trim_space(line[i + sep.len:])
		if body == "" || len(body) > 4096 { return {}, false }
		c = Cos_Draft{list = list, text_off = text_off}
		if sep.exception { c.flags += {.Exception} }
		if dom != "" {
			if !parse_domain_spec(dom, ',', &c.src) { return {}, false }
			spec_normalize(&c.src)
			if len(c.src.inc) == 0 { c.flags += {.Generic} }
		} else {
			c.flags += {.Generic}
		}
		switch {
		case sep.js_raw:
			if strings.has_prefix(body, "//scriptlet(") && strings.has_suffix(body, ")") {
				// AdGuard scriptlet: //scriptlet('ubo-name', 'arg'...) -> a uBO scriptlet rule
				inner := body[len("//scriptlet(") : len(body) - 1]
				c.selector = adguard_scriptlet(inner)
				if c.selector == "" { return {}, false }
				c.flags += {.Scriptlet}
			} else {
				c.selector = body
				c.flags += {.Js_Raw}
			}
		case sep.style_inject:
			if strings.index_byte(body, '{') < 0 { return {}, false }   // ABP snippets: not supported
			c.selector = body
			c.flags += {.Style_Inject}
		case strings.has_prefix(body, "+js(") && strings.has_suffix(body, ")"):
			c.selector = body[len("+js(") : len(body) - 1]
			c.flags += {.Scriptlet}
		case body[0] == '^':
			c.selector = body[1:]
			c.flags += {.Html}
		case:
			if strings.has_prefix(body, "script:inject(") && strings.has_suffix(body, ")") {   // ABP legacy
				c.selector = body[len("script:inject(") : len(body) - 1]
				c.flags += {.Scriptlet}
				break
			}
			if strings.index_any(body, "{}") >= 0 { return {}, false }
			c.selector = body
			if sep.procedural || selector_is_procedural(body) { c.flags += {.Procedural} }
			if strings.contains(body, ":style(") { c.flags += {.Style} }
			if strings.has_suffix(body, ":remove()") { c.flags += {.Remove} }
			if .Procedural not_in c.flags && .Style not_in c.flags && .Remove not_in c.flags {
				if k, has := selector_key(body); has { c.key = k; c.flags += {.Keyed} }
			}
		}
		return c, true
	}
}

// `'ubo-set-constant.js', 'a', 'b'` -> `set-constant, a, b`
@(private)
adguard_scriptlet :: proc(inner: string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	rest := inner
	for len(rest) > 0 {
		rest = strings.trim_left_space(rest)
		if len(rest) == 0 { break }
		q := rest[0]
		if q != '\'' && q != '"' { return "" }
		end := 1
		for end < len(rest) && rest[end] != q { if rest[end] == '\\' { end += 1 }; end += 1 }
		if end >= len(rest) { return "" }
		append(&parts, rest[1:end])
		rest = strings.trim_left_space(rest[end + 1:])
		if len(rest) > 0 { if rest[0] != ',' { return "" }; rest = rest[1:] }
	}
	if len(parts) == 0 { return "" }
	name := parts[0]
	for pre in ([]string{"ubo-", "abp-"}) { if strings.has_prefix(name, pre) { name = name[len(pre):] } }
	name = strings.trim_suffix(name, ".js")
	sb := strings.builder_make()
	strings.write_string(&sb, name)
	for a in parts[1:] { strings.write_string(&sb, ", "); strings.write_string(&sb, a) }
	return strings.to_string(sb)
}
