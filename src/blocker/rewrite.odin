package blocker

import "core:encoding/json"
import "core:strings"
import "wb:adblock"
import "wb:fetch"
import "wb:http"

// The scriptlets that rewrite what the page is about to read (route .Network, scriptlet_route.odin), done by the loader on the response
// body, before the page sees it, with no JavaScript:
//
//   json-prune, json-prune-fetch-response, json-prune-xhr-response   remove properties from a JSON response (by path)
//   replace-fetch-response / replace-xhr-response (trusted-replace-*)  a regular-expression replacement in the text of a response
//   xml-prune                                                        remove elements from an XML response (a DASH manifest...)
//   set-constant / json-prune on the HTML itself                     `var ytInitialPlayerResponse = {...}` in a page's own markup: the
//                                                                    literal is pruned (or its property set) in the stream, before the parser
//                                                                    reads it, when a rule names that variable
//
// The rules are those of the document's host (the same cosmetic result the page's other filters come from), looked up once per host; a
// request that no rule targets costs a map lookup and nothing else. The bodies are rewritten in the stream (fetch.Body_Filter): a JSON or
// XML response is held until it is complete (its reader needs all of it), an HTML page flows through with only a few bytes held back.

Prune_Rule :: struct {
	paths:    [][]string,
	required: [][]string,
	url:      Needle,
	keys:     []string,      // the last token of each path: a body that holds none of them is not parsed
}

Replace_Rule :: struct {
	url:     Needle,
	method:  string,         // "" for any
	pat:     ^Jsre,
	repl:    string,
}

Xml_Rule :: struct {
	selector: string,
	check:    string,
	url:      Needle,
}

Embed_Action :: enum u8 { Delete, Set }

Embed_Rule :: struct {
	var:    string,
	path:   []string,
	action: Embed_Action,
	value:  string,          // JSON text of the value to set
}

Host_Rules :: struct {
	generation: u64,
	prune:   [dynamic]Prune_Rule,
	replace: [dynamic]Replace_Rule,
	xml:     [dynamic]Xml_Rule,
	embed:   [dynamic]Embed_Rule,
	html:    [dynamic]Html_Rule,   // `##^` HTML filters of the host (html_filter.odin)
	refs:    int,           // filters of requests in flight that point at the rules
	dead:    bool,          // replaced by a newer entry: destroyed when the last filter lets go
}

host_rules_destroy :: proc(h: ^Host_Rules) {
	for &r in h.prune {
		for p in r.paths { for s in p { delete(s) }; delete(p) }
		for p in r.required { for s in p { delete(s) }; delete(p) }
		delete(r.paths); delete(r.required)
		for k in r.keys { delete(k) }
		delete(r.keys)
		needle_destroy(&r.url)
	}
	delete(h.prune)
	for &r in h.replace { needle_destroy(&r.url); delete(r.method); jsre_destroy(r.pat); delete(r.repl) }
	delete(h.replace)
	for &r in h.xml { needle_destroy(&r.url); delete(r.selector); delete(r.check) }
	delete(h.xml)
	for &r in h.embed { embed_destroy(&r) }
	delete(h.embed)
	for &r in h.html { html_rule_destroy(&r) }
	delete(h.html)
	free(h)
}

@(private = "file")
embed_destroy :: proc(r: ^Embed_Rule) {
	delete(r.var)
	for s in r.path { delete(s) }
	delete(r.path)
	delete(r.value)
}

@(private = "file")
embed_clone :: proc(r: Embed_Rule) -> Embed_Rule {
	c := r
	c.var = strings.clone(r.var)
	c.path = make([]string, len(r.path))
	for s, i in r.path { c.path[i] = strings.clone(s) }
	c.value = strings.clone(r.value)
	return c
}

// A list of paths: `a.b.c d.*.e`, each token a key, or `*` / `[]` / `[-]` for every key or element.
parse_paths :: proc(text: string) -> [][]string {
	out := make([dynamic][]string)
	for word in strings.fields(text, context.temp_allocator) {
		toks := strings.split(word, ".", context.temp_allocator)
		path := make([]string, len(toks))
		for t, i in toks { path[i] = strings.clone(t) }
		append(&out, path)
	}
	return out[:]
}

@(private = "file")
url_part :: proc(arg: string) -> string {
	// "url:/player" or "/player": the pattern after the key
	if strings.has_prefix(arg, "url:") { return arg[4:] }
	return arg
}

// The value of `set-constant` as JSON text; "" when the constant is not data (a function, a getter...).
@(private = "file")
constant_json :: proc(v: string) -> (text: string, ok: bool) {
	switch v {
	case "undefined": return "", true     // the property is removed
	case "false", "true", "null": return v, true
	case "emptyObj": return "{}", true
	case "emptyArr": return "[]", true
	case "": return "\"\"", true
	case "NaN", "Infinity", "-Infinity", "noopFunc", "trueFunc", "falseFunc", "throwFunc", "noopPromiseResolve", "noopPromiseReject": return "", false
	}
	if len(v) > 0 && (v[0] == '-' || (v[0] >= '0' && v[0] <= '9')) { return v, true }
	if v == "yes" || v == "no" { return strings.concatenate({"\"", v, "\""}, context.temp_allocator), true }
	return "", false
}

// The rules of a host, built from its scriptlets (cosmetic filters of kind scriptlet).
@(private)
host_rules_for :: proc(b: ^Blocker, host: string, pf: adblock.Page_Flags) -> ^Host_Rules {
	if b.engine == nil { return nil }
	if h, ok := b.net_rules[host]; ok && h.generation == b.generation { return h }
	if old, ok := b.net_rules[host]; ok { net_rules_drop(b, host, old) }
	e := b.engine.engine
	cos := adblock.cosmetic_for_host(e, host, pf)
	defer adblock.cosmetic_destroy(&cos)
	h := new(Host_Rules)
	h.generation = b.generation
	if !cos.no_scriptlets {
		for id in cos.active {
			v := adblock.cosmetic_filter(e, id)
			if .Scriptlet not_in v.flags { continue }
			args := split_args(v.selector)
			if len(args) == 0 { continue }
			canon := scriptlet_canonical(args[0])
			a := proc(args: []string, i: int) -> string { return i < len(args) ? args[i] : "" }
			switch canon {
			case "json-prune", "json-prune-fetch-response", "json-prune-xhr-response":
				r := Prune_Rule{paths = parse_paths(a(args, 1)), required = parse_paths(a(args, 2))}
				if canon != "json-prune" { r.url = needle_make(url_part(a(args, 3))) } else { r.url = needle_make("") }
				if len(r.paths) == 0 { delete(r.paths); delete(r.required); continue }
				r.keys = make([]string, len(r.paths))
				for p, i in r.paths { r.keys[i] = strings.clone(p[len(p) - 1]) }
				append(&h.prune, r)
			case "replace-fetch-response", "replace-xhr-response":
				re := pattern_regex(a(args, 1), "g")
				if re == nil { continue }
				r := Replace_Rule{pat = re, repl = strings.clone(a(args, 2))}
				urlp := ""
				props := strings.trim_space(a(args, 3))
				if strings.has_prefix(props, "url:") || strings.has_prefix(props, "method:") {
					for word in strings.fields(props, context.temp_allocator) {
						if strings.has_prefix(word, "url:") { urlp = word[4:] } else if strings.has_prefix(word, "method:") { r.method = strings.clone(word[7:]) }
					}
				} else {
					urlp = props   // a bare pattern is the URL's (a /regex/ may hold colons and spaces)
				}
				r.url = needle_make(urlp)
				append(&h.replace, r)
			case "xml-prune":
				if a(args, 1) == "" { continue }
				append(&h.xml, Xml_Rule{selector = strings.clone(a(args, 1)), check = strings.clone(a(args, 2)), url = needle_make(url_part(a(args, 3)))})
			case "set-constant":
				chain := strings.split(a(args, 1), ".", context.temp_allocator)
				if len(chain) < 2 { continue }
				text, ok := constant_json(a(args, 2))
				if !ok { continue }
				er := Embed_Rule{var = strings.clone(chain[0]), action = text == "" ? .Delete : .Set, value = strings.clone(text)}
				er.path = make([]string, len(chain) - 1)
				for s, i in chain[1:] { er.path[i] = strings.clone(s) }
				// `ytInitialPlayerResponse` in the page is what `/youtubei/v1/player` answers to the page's own requests (the next video
				// of the same page, a reload by script): the property removed from the variable is removed from those answers too
				if er.action == .Delete && er.var == "ytInitialPlayerResponse" {
					pr := Prune_Rule{url = needle_make("/youtubei/v1/player")}
					pr.paths = make([][]string, 1)
					pr.paths[0] = make([]string, len(er.path))
					for s, i in er.path { pr.paths[0][i] = strings.clone(s) }
					pr.keys = make([]string, 1)
					pr.keys[0] = strings.clone(er.path[len(er.path) - 1])
					append(&h.prune, pr)
				}
				append(&h.embed, er)
			}
		}
	}
	// `##^` HTML filters of the host (deleted from the document's markup, html_filter.odin). Gated by `no_html` (the
	// `#@#^` exceptions), independent of the scriptlets switch.
	if !cos.no_html && b.cfg.html_filters {
		for id in cos.active {
			v := adblock.cosmetic_filter(e, id)
			if .Html not_in v.flags { continue }
			if r, ok := html_rule_parse(v.selector); ok { append(&h.html, r) }
		}
	}
	if b.net_rules == nil { b.net_rules = make(map[string]^Host_Rules) }
	b.net_rules[strings.clone(host)] = h
	return h
}

net_rules_drop :: proc(b: ^Blocker, host: string, h: ^Host_Rules) {
	for k in b.net_rules { if k == host { key := k; delete_key(&b.net_rules, host); delete(key); break } }
	if h.refs > 0 { h.dead = true } else { host_rules_destroy(h) }
}

net_rules_clear :: proc(b: ^Blocker) {
	for k, h in b.net_rules {
		if h.refs > 0 { h.dead = true } else { host_rules_destroy(h) }
		delete(k)
	}
	clear(&b.net_rules)
}

////////////////////////////////
// JSON

@(private = "file")
is_wild :: #force_inline proc(s: string) -> bool { return s == "*" || s == "[]" || s == "[-]" }

@(private = "file")
index_of :: proc(s: string) -> (int, bool) {
	if s == "" { return 0, false }
	n := 0
	for c in transmute([]u8)s { if c < '0' || c > '9' { return 0, false }; n = n * 10 + int(c - '0'); if n > 1 << 30 { return 0, false } }
	return n, true
}

// Does the path exist in the value, and with `del`, remove what it names. Wildcards walk every key or element.
@(private = "file")
path_walk :: proc(v: ^json.Value, path: []string, del: bool) -> bool {
	if len(path) == 0 { return true }
	key := path[0]
	last := len(path) == 1
	#partial switch &val in v {
	case json.Object:
		if is_wild(key) {
			keys := make([dynamic]string, context.temp_allocator)
			for k in val { append(&keys, k) }
			hit := false
			for k in keys {
				if last { hit = true; if del { delete_key(&val, k) } } else {
					child := val[k]
					if path_walk(&child, path[1:], del) { hit = true; val[k] = child }
				}
			}
			return hit
		}
		if _, ok := val[key]; !ok { return false }
		if last { if del { delete_key(&val, key) }; return true }
		child := val[key]
		if path_walk(&child, path[1:], del) { val[key] = child; return true }
		return false
	case json.Array:
		if is_wild(key) {
			hit := false
			if last {
				if len(val) > 0 { hit = true; if del { clear(&val) } }
				return hit
			}
			for i in 0 ..< len(val) {
				if path_walk(&val[i], path[1:], del) { hit = true }
			}
			return hit
		}
		i, ok := index_of(key)
		if !ok || i >= len(val) { return false }
		if last { if del { ordered_remove(&val, i) }; return true }
		return path_walk(&val[i], path[1:], del)
	}
	return false
}

// Sets the property at `path` (its parents must exist) to `value`.
@(private = "file")
path_set :: proc(v: ^json.Value, path: []string, value: json.Value) -> bool {
	if len(path) == 0 { return false }
	key := path[0]
	#partial switch &val in v {
	case json.Object:
		if len(path) == 1 { val[strings.clone(key, context.temp_allocator)] = value; return true }
		if child, ok := val[key]; ok { c := child; if path_set(&c, path[1:], value) { val[key] = c; return true } }
	case json.Array:
		i, ok := index_of(key)
		if !ok || i >= len(val) { return false }
		if len(path) == 1 { val[i] = value; return true }
		return path_set(&val[i], path[1:], value)
	}
	return false
}

@(private = "file")
first_byte :: proc(s: string) -> u8 {
	for c in transmute([]u8)s { if c != ' ' && c != '\t' && c != '\n' && c != '\r' && c != 0xef && c != 0xbb && c != 0xbf { return c } }
	return 0
}

// The text of a JSON response with the rules' properties removed. `changed` is false when nothing matched (the text is returned as is).
prune_json_text :: proc(text: string, rules: []^Prune_Rule) -> (out: string, changed: bool) {
	// a body that mentions none of the properties is not parsed at all
	any := false
	for r in rules { for k in r.keys { if k == "" || is_wild(k) || strings.contains(text, k) { any = true } else if _, num := index_of(k); num { any = true } } }
	if !any { return text, false }
	val, err := json.parse(transmute([]byte)text, .JSON, true, context.temp_allocator)
	if err != nil { return text, false }
	hit := false
	for r in rules {
		ok := true
		for req in r.required { if !path_walk(&val, req, false) { ok = false; break } }
		if !ok { continue }
		for p in r.paths { if path_walk(&val, p, true) { hit = true } }
	}
	if !hit { return text, false }
	data, merr := json.marshal(val, {}, context.temp_allocator)
	if merr != nil { return text, false }
	return string(data), true
}

////////////////////////////////
// XML (a small element scanner: names, attributes, nesting)

@(private = "file")
Xml_El :: struct {
	name:   string,
	attrs:  string,       // the text between the name and `>`
	start:  int,          // `<`
	end:    int,          // after the closing `>` of the element
	parent: int,
}

@(private = "file")
xml_scan :: proc(text: string) -> []Xml_El {
	els := make([dynamic]Xml_El, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	i := 0
	for i < len(text) {
		lt := strings.index_byte(text[i:], '<')
		if lt < 0 { break }
		i += lt
		switch {
		case strings.has_prefix(text[i:], "<!--"):
			e := strings.index(text[i:], "-->")
			if e < 0 { return els[:] }
			i += e + 3
		case strings.has_prefix(text[i:], "<![CDATA["):
			e := strings.index(text[i:], "]]>")
			if e < 0 { return els[:] }
			i += e + 3
		case strings.has_prefix(text[i:], "<?") || strings.has_prefix(text[i:], "<!"):
			e := strings.index_byte(text[i:], '>')
			if e < 0 { return els[:] }
			i += e + 1
		case strings.has_prefix(text[i:], "</"):
			e := strings.index_byte(text[i:], '>')
			if e < 0 { return els[:] }
			if len(stack) > 0 { els[pop(&stack)].end = i + e + 1 }
			i += e + 1
		case:
			// a start tag: find its `>` outside quotes
			j := i + 1
			quote: u8 = 0
			for j < len(text) {
				c := text[j]
				if quote != 0 { if c == quote { quote = 0 } } else if c == '"' || c == '\'' { quote = c } else if c == '>' { break }
				j += 1
			}
			if j >= len(text) { return els[:] }
			inner := text[i + 1:j]
			self_closing := strings.has_suffix(inner, "/")
			if self_closing { inner = inner[:len(inner) - 1] }
			sp := 0
			for sp < len(inner) && inner[sp] != ' ' && inner[sp] != '\t' && inner[sp] != '\n' && inner[sp] != '\r' { sp += 1 }
			el := Xml_El{name = inner[:sp], attrs = inner[sp:], start = i, end = j + 1, parent = len(stack) > 0 ? stack[len(stack) - 1] : -1}
			append(&els, el)
			if !self_closing { append(&stack, len(els) - 1) }
			i = j + 1
		}
	}
	return els[:]
}

@(private = "file")
xml_attr :: proc(attrs, name: string) -> (string, bool) {
	rest := attrs
	for {
		k := strings.index(rest, name)
		if k < 0 { return "", false }
		before := k == 0 ? u8(' ') : rest[k - 1]
		after := rest[k + len(name):]
		if (before == ' ' || before == '\t' || before == '\n' || before == '\r') && strings.has_prefix(strings.trim_left_space(after), "=") {
			after = strings.trim_left_space(strings.trim_left_space(after)[1:])
			if len(after) > 0 && (after[0] == '"' || after[0] == '\'') {
				e := strings.index_byte(after[1:], after[0])
				if e >= 0 { return after[1:1 + e], true }
			}
			return "", false
		}
		rest = rest[k + len(name):]
	}
}

// One compound selector: `name`, `*`, and `[attr]`, `[attr=v]`, `[attr*=v]`, `[attr^=v]`, `[attr$=v]`, `[attr~=v]`.
@(private = "file")
xml_compound :: proc(el: ^Xml_El, comp: string) -> bool {
	c := comp
	nm := c
	if i := strings.index_byte(c, '['); i >= 0 { nm, c = c[:i], c[i:] } else { c = "" }
	if nm != "" && nm != "*" && nm != el.name { return false }
	for len(c) > 0 && c[0] == '[' {
		e := strings.index_byte(c, ']')
		if e < 0 { return false }
		test := c[1:e]
		c = c[e + 1:]
		op, opi := "", -1
		for cand in ([]string{"*=", "^=", "$=", "~=", "="}) { if i := strings.index(test, cand); i >= 0 && (opi < 0 || i < opi) { op, opi = cand, i } }
		if opi < 0 { if _, has := xml_attr(el.attrs, test); !has { return false }; continue }
		name := strings.trim_space(test[:opi])
		want := strings.trim(strings.trim_space(test[opi + len(op):]), "\"'")
		got, has := xml_attr(el.attrs, name)
		if !has { return false }
		switch op {
		case "=": if got != want { return false }
		case "*=": if !strings.contains(got, want) { return false }
		case "^=": if !strings.has_prefix(got, want) { return false }
		case "$=": if !strings.has_suffix(got, want) { return false }
		case "~=": if !contains_word(got, want) { return false }
		}
	}
	return true
}

@(private = "file")
contains_word :: proc(s, w: string) -> bool {
	for part in strings.fields(s, context.temp_allocator) { if part == w { return true } }
	return false
}

// Does the element match one selector with descendant (` `) and child (`>`) combinators, read right to left?
@(private = "file")
xml_matches :: proc(els: []Xml_El, i: int, sel: string) -> bool {
	// split into compounds and combinators
	parts := make([dynamic]string, context.temp_allocator)
	combs := make([dynamic]u8, context.temp_allocator)   // the combinator before parts[k] (0 for the first)
	cur := strings.builder_make(context.temp_allocator)
	pending: u8 = 0
	depth := 0
	flush :: proc(parts: ^[dynamic]string, combs: ^[dynamic]u8, cur: ^strings.Builder, pending: ^u8) {
		if strings.builder_len(cur^) == 0 { return }
		append(parts, strings.clone(strings.to_string(cur^), context.temp_allocator))
		append(combs, pending^)
		strings.builder_reset(cur)
		pending^ = ' '
	}
	for c in transmute([]u8)sel {
		switch {
		case c == '[': depth += 1; strings.write_byte(&cur, c)
		case c == ']': depth -= 1; strings.write_byte(&cur, c)
		case depth == 0 && (c == ' ' || c == '\t'): flush(&parts, &combs, &cur, &pending)
		case depth == 0 && c == '>': flush(&parts, &combs, &cur, &pending); pending = '>'
		case: strings.write_byte(&cur, c)
		}
	}
	flush(&parts, &combs, &cur, &pending)
	if len(parts) == 0 { return false }
	combs[0] = 0
	return xml_match_from(els, i, parts[:], combs[:], len(parts) - 1)
}

@(private = "file")
xml_match_from :: proc(els: []Xml_El, i: int, parts: []string, combs: []u8, k: int) -> bool {
	if !xml_compound(&els[i], parts[k]) { return false }
	if k == 0 { return true }
	if combs[k] == '>' {
		p := els[i].parent
		return p >= 0 && xml_match_from(els, p, parts, combs, k - 1)
	}
	for p := els[i].parent; p >= 0; p = els[p].parent { if xml_match_from(els, p, parts, combs, k - 1) { return true } }
	return false
}

xml_prune_text :: proc(text: string, rules: []^Xml_Rule) -> (out: string, changed: bool) {
	els := xml_scan(text)
	if len(els) == 0 { return text, false }
	drop := make([]bool, len(els), context.temp_allocator)
	any := false
	for r in rules {
		if r.check != "" {
			found := false
			for sel in strings.split(r.check, ",", context.temp_allocator) { for i in 0 ..< len(els) { if xml_matches(els, i, strings.trim_space(sel)) { found = true; break } }; if found { break } }
			if !found { continue }
		}
		for sel in strings.split(r.selector, ",", context.temp_allocator) {
			s := strings.trim_space(sel)
			for i in 0 ..< len(els) { if !drop[i] && xml_matches(els, i, s) { drop[i] = true; any = true } }
		}
	}
	if !any { return text, false }
	sb := strings.builder_make(context.temp_allocator)
	at := 0
	for el, i in els {
		if !drop[i] || el.start < at { continue }
		strings.write_string(&sb, text[at:el.start])
		at = max(el.end, el.start)
	}
	strings.write_string(&sb, text[at:])
	return strings.to_string(sb), true
}

////////////////////////////////
// Body filters

REWRITE_MAX_BODY :: 16 << 20

// fetch / XHR: the body is held until complete, then rewritten once by the rules that target the URL.
Buf_Filter :: struct {
	prune:   [dynamic]^Prune_Rule,
	replace: [dynamic]^Replace_Rule,
	xml:     [dynamic]^Xml_Rule,
	hold:    [dynamic]byte,
	through: bool,
	own:     [dynamic]^Replace_Rule,   // the rules this filter owns ($replace filters: made for the request)
	h:       ^Host_Rules,         // kept alive by `refs`
	b:       ^Blocker,
}

@(private = "file")
buf_push :: proc(user: rawptr, chunk: []byte, out: ^[dynamic]byte) {
	f := (^Buf_Filter)(user)
	if f.through { append(out, ..chunk); return }
	append(&f.hold, ..chunk)
	if len(f.hold) > REWRITE_MAX_BODY {
		f.through = true
		append(out, ..f.hold[:])
		clear(&f.hold)
	}
}

@(private = "file")
buf_finish :: proc(user: rawptr, out: ^[dynamic]byte) {
	f := (^Buf_Filter)(user)

	if f.through || len(f.hold) == 0 { return }
	text := string(f.hold[:])
	changed := false
	switch first_byte(text) {
	case '{', '[':
		if len(f.prune) > 0 { text, changed = prune_json_text(text, f.prune[:]) }
	case '<':
		if len(f.xml) > 0 { text, changed = xml_prune_text(text, f.xml[:]) }
	}
	for r in f.replace {
		if out2, n := jsre_replace(r.pat, text, r.repl, 0, context.temp_allocator); n > 0 && out2 != text { text, changed = out2, true }
	}
	append(out, ..transmute([]byte)text)
	_ = changed
	clear(&f.hold)
}

@(private = "file")
buf_destroy :: proc(user: rawptr) {
	f := (^Buf_Filter)(user)
	delete(f.prune); delete(f.replace); delete(f.xml); delete(f.hold)
	for r in f.own { needle_destroy(&r.url); delete(r.method); jsre_destroy(r.pat); delete(r.repl); free(r) }
	delete(f.own)
	engine_ref_drop_rules(f)
	free(f)
}

// The rules a filter points at belong to a host entry that an engine change destroys: the filter works on copies of nothing, so the entry
// is kept until the filter is destroyed.
@(private = "file")
engine_ref_drop_rules :: proc(f: ^Buf_Filter) {
	if f.h == nil { return }
	f.h.refs -= 1
	if f.h.refs <= 0 && f.h.dead { host_rules_destroy(f.h) }
}

// HTML: a page's own markup, with the JSON literals the embed rules name rewritten as they pass.
Html_Filter :: struct {
	rules:   [dynamic]Embed_Rule,     // clones
	vars:    [dynamic]string,         // each variable once (points into rules)
	pending: [dynamic]byte,
	hold:    int,
}

@(private = "file")
html_destroy :: proc(user: rawptr) {
	f := (^Html_Filter)(user)
	for &r in f.rules { embed_destroy(&r) }
	delete(f.rules); delete(f.vars); delete(f.pending)
	free(f)
}

@(private = "file")
is_ident :: #force_inline proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$' }

// After the variable's name: optional quote and `]`, spaces, `=` (not `==`), spaces, then `{`. 0: not an assignment, 1: the literal starts
// at `start`, 2: the buffer ends before it can be said.
@(private = "file")
literal_start :: proc(buf: []byte, from: int) -> (start: int, state: int) {
	i := from
	skip :: proc(buf: []byte, i: ^int) { for i^ < len(buf) && (buf[i^] == ' ' || buf[i^] == '\t' || buf[i^] == '\n' || buf[i^] == '\r') { i^ += 1 } }
	if i < len(buf) && (buf[i] == '"' || buf[i] == '\'') { i += 1; if i < len(buf) && buf[i] == ']' { i += 1 } }
	skip(buf, &i)
	if i >= len(buf) { return 0, 2 }
	if buf[i] != '=' { return 0, 0 }
	i += 1
	if i >= len(buf) { return 0, 2 }
	if buf[i] == '=' { return 0, 0 }
	skip(buf, &i)
	if i >= len(buf) { return 0, 2 }
	if buf[i] != '{' { return 0, 0 }
	return i, 1
}

// The end (inclusive) of the JSON object that starts at buf[start], aware of strings; complete=false when the buffer ends first.
@(private = "file")
literal_end :: proc(buf: []byte, start: int) -> (end: int, complete: bool) {
	depth := 0
	in_str := false
	i := start
	for i < len(buf) {
		c := buf[i]
		if in_str {
			if c == '\\' { i += 2; continue }
			if c == '"' { in_str = false }
		} else {
			switch c {
			case '"': in_str = true
			case '{', '[': depth += 1
			case '}', ']':
				depth -= 1
				if depth == 0 { return i, true }
			}
		}
		i += 1
	}
	return 0, false
}

@(private = "file")
embed_rewrite :: proc(f: ^Html_Filter, var: string, literal: []byte) -> (out: []byte, changed: bool) {
	val, err := json.parse(literal, .JSON, true, context.temp_allocator)
	if err != nil { return literal, false }
	hit := false
	for &r in f.rules {
		if r.var != var { continue }
		switch r.action {
		case .Delete: if path_walk(&val, r.path, true) { hit = true }
		case .Set:
			nv, e := json.parse(transmute([]byte)r.value, .JSON, true, context.temp_allocator)
			if e == nil && path_set(&val, r.path, nv) { hit = true }
		}
	}
	if !hit { return literal, false }
	data, merr := json.marshal(val, {}, context.temp_allocator)
	if merr != nil { return literal, false }
	return data, true
}

@(private = "file")
html_scan :: proc(f: ^Html_Filter, out: ^[dynamic]byte, final: bool) {
	buf := f.pending[:]
	emitted := 0
	from := 0
	for {
		best, bvar := -1, ""
		text := string(buf[from:])
		for v in f.vars {
			if i := strings.index(text, v); i >= 0 && (best < 0 || i < best) { best, bvar = i, v }
		}
		if best < 0 { break }
		at := from + best
		after := at + len(bvar)
		if at > 0 && is_ident(buf[at - 1]) || (after < len(buf) && is_ident(buf[after])) { from = after; continue }
		start, state := literal_start(buf, after)
		if state == 0 { from = after; continue }
		if state == 2 {
			if final { break }
			append(out, ..buf[emitted:at])
			emitted = at
			from = len(buf) + 1
			break
		}
		end, complete := literal_end(buf, start)
		if !complete {
			if final { break }
			append(out, ..buf[emitted:at])
			emitted = at
			from = len(buf) + 1
			break
		}
		nl, changed := embed_rewrite(f, bvar, buf[start:end + 1])
		append(out, ..buf[emitted:start])
		if changed { append(out, ..nl) } else { append(out, ..buf[start:end + 1]) }
		emitted = end + 1
		from = emitted
	}
	// nothing more is pending: everything but the last few bytes (a name cut by the chunk) goes out
	if from <= len(buf) {
		safe := final ? len(buf) : max(emitted, len(buf) - f.hold)
		append(out, ..buf[emitted:safe])
		emitted = safe
	}
	n := copy(f.pending[:], buf[emitted:])
	resize(&f.pending, n)
}

@(private = "file")
html_push :: proc(user: rawptr, chunk: []byte, out: ^[dynamic]byte) {
	f := (^Html_Filter)(user)
	append(&f.pending, ..chunk)
	html_scan(f, out, false)
}

@(private = "file")
html_finish :: proc(user: rawptr, out: ^[dynamic]byte) {
	f := (^Html_Filter)(user)
	html_scan(f, out, true)
}

// `/search/replacement/flags`, the argument of a `$replace=` filter (an escaped slash stays inside its part).
@(private = "file")
split_replace :: proc(arg: string) -> (search, repl, flags: string, ok: bool) {
	if len(arg) < 2 || arg[0] != '/' { return }
	parts: [2]string
	n, start, i := 0, 1, 1
	for n < 2 {
		if i >= len(arg) { return }
		if arg[i] == '\\' { i += 2; continue }
		if arg[i] == '/' { parts[n] = arg[start:i]; n += 1; start = i + 1 }
		i += 1
	}
	return parts[0], parts[1], arg[start:], true
}

// A filter that rewrites the text of a response by the `$replace=` filters that matched it.
replace_filter_make :: proc(args: []string) -> fetch.Body_Filter {
	f: ^Buf_Filter
	for a in args {
		search, repl, flags, ok := split_replace(a)
		if !ok { continue }
		re := jsre_compile(search, flags)
		if re == nil { continue }
		r := new(Replace_Rule)
		r.pat = re
		unescaped, _ := strings.replace_all(repl, "\\/", "/", context.temp_allocator)
		unescaped, _ = strings.replace_all(unescaped, "\\,", ",", context.temp_allocator)
		r.repl = strings.clone(unescaped)
		if f == nil { f = new(Buf_Filter) }
		append(&f.own, r)
		append(&f.replace, r)
	}
	if f == nil { return {} }
	return fetch.Body_Filter{user = f, push = buf_push, finish = buf_finish, destroy = buf_destroy}
}

// Two filters one after the other: the first one's output is the second one's input.
Chain_Filter :: struct { a, b: fetch.Body_Filter, mid: [dynamic]byte }

@(private = "file")
chain_push :: proc(user: rawptr, chunk: []byte, out: ^[dynamic]byte) {
	c := (^Chain_Filter)(user)
	clear(&c.mid)
	c.a.push(c.a.user, chunk, &c.mid)
	if len(c.mid) > 0 { c.b.push(c.b.user, c.mid[:], out) }
}

@(private = "file")
chain_finish :: proc(user: rawptr, out: ^[dynamic]byte) {
	c := (^Chain_Filter)(user)
	clear(&c.mid)
	if c.a.finish != nil { c.a.finish(c.a.user, &c.mid) }
	if len(c.mid) > 0 { c.b.push(c.b.user, c.mid[:], out) }
	if c.b.finish != nil { c.b.finish(c.b.user, out) }
}

@(private = "file")
chain_destroy :: proc(user: rawptr) {
	c := (^Chain_Filter)(user)
	if c.a.destroy != nil { c.a.destroy(c.a.user) }
	if c.b.destroy != nil { c.b.destroy(c.b.user) }
	delete(c.mid)
	free(c)
}

chain_make :: proc(a, b: fetch.Body_Filter) -> fetch.Body_Filter {
	if a.push == nil { return b }
	if b.push == nil { return a }
	c := new(Chain_Filter)
	c.a, c.b = a, b
	return fetch.Body_Filter{user = c, push = chain_push, finish = chain_finish, destroy = chain_destroy}
}

// A filter for a page's markup: the JSON literals the rules name are rewritten as they pass.
html_filter_make :: proc(rules: []Embed_Rule) -> fetch.Body_Filter {
	f := new(Html_Filter)
	for r in rules { append(&f.rules, embed_clone(r)) }
	for &r in f.rules {
		seen := false
		for v in f.vars { if v == r.var { seen = true } }
		if !seen { append(&f.vars, r.var); f.hold = max(f.hold, len(r.var) + 16) }
	}
	return fetch.Body_Filter{user = f, push = html_push, finish = html_finish, destroy = html_destroy}
}

// Decides, from the response of a request, whether its body is rewritten, and returns the filter: the `$replace=` filters that matched
// (`replace`), then what the scriptlets of the document's host ask for (when `scriptlets`).
@(private)
rewrite_filter :: proc(b: ^Blocker, q: ^fetch.Intercept_Query, host: string, pf: adblock.Page_Flags, headers: http.Headers, scriptlets: bool, replace: []string) -> fetch.Body_Filter {
	first := replace_filter_make(replace)
	second: fetch.Body_Filter
	nav := q.destination == .Document || fetch.is_frame_destination(q.destination)
	// the HTML filters (`##^`) run on a document / frame response even when scriptlets are off, as long as the blocker and
	// the HTML-filters switch are on; the scriptlet rewrites below still need `scriptlets`
	want_rules := scriptlets || (nav && b.cfg.html_filters && b.cfg.enabled)
	if want_rules {
		if h := host_rules_for(b, host, pf); h != nil {
			switch {
			case scriptlets && q.destination == .Empty && !q.ping:
				if len(h.prune) + len(h.replace) + len(h.xml) > 0 {
					f := new(Buf_Filter)
					for &r in h.prune { if needle_test(&r.url, q.url) { append(&f.prune, &r) } }
					for &r in h.replace {
						if !needle_test(&r.url, q.url) { continue }
						if r.method != "" && !strings.equal_fold(r.method, q.method) { continue }
						append(&f.replace, &r)
					}
					for &r in h.xml { if needle_test(&r.url, q.url) { append(&f.xml, &r) } }
					if len(f.prune) + len(f.replace) + len(f.xml) == 0 { free(f) } else {
						f.h, f.b = h, b
						h.refs += 1
						second = fetch.Body_Filter{user = f, push = buf_push, finish = buf_finish, destroy = buf_destroy}
					}
				}
			case nav:
				// only for HTML answers (never JSON, images, other types)
				ct, _ := http.get_header(headers, "content-type")
				is_html := strings.contains(ct, "html") || (ct == "" && q.destination == .Document)
				if is_html {
					embed_f: fetch.Body_Filter
					if scriptlets && len(h.embed) > 0 { embed_f = html_filter_make(h.embed[:]) }
					html_f: fetch.Body_Filter
					if b.cfg.html_filters && len(h.html) > 0 {
						html_f = html_doc_filter_make(h.html[:], b.cfg.html_max_body, q.url, html_hit_cb, b)
					}
					// the embed rewrite (JSON literals) before the HTML element removal: removing an element never changes a
					// JSON literal, and the embed scan only holds a few bytes while the HTML filter holds the whole body
					second = chain_make(embed_f, html_f)
				}
			}
		}
	}
	// the scriptlets' rewrite first: a `$replace=` filter that renames `adPlacements` (`"no_ads"`) would otherwise hide the property from
	// the pruning that removes its content
	return chain_make(second, first)
}