package adblock

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

// Names that conditions of `!#if` may use. The defaults describe a uBlock-compatible content blocker that evaluates
// procedural cosmetic filters and scriptlets itself.
Env :: struct {
	defs: []string,
}

DEFAULT_ENV_DEFS := [?]string{
	"ext_ublock", "cap_html_filtering", "cap_user_stylesheet", "cap_ipaddress", "env_chromium", "env_mobile_false",
	"adguard", "adguard_ext_chromium", "ext_abp_false",
}

// Resolves `!#include path` of the list called `from`; the returned text must outlive the build.
Include_Proc :: #type proc(user: rawptr, from, path: string) -> (id: u8, name, text: string, ok: bool)

Source_Stat :: struct {
	id:      u8,
	name:    string,
	net:     u32,
	cosmetic: u32,
	invalid: u32,
	text:    string,    // the list's text (the caller keeps it alive until the build is over)
}

Builder :: struct {
	arena:        virtual.Arena,
	alloc:        mem.Allocator,
	env:          Env,
	include:      Include_Proc,
	include_user: rawptr,
	net:          [dynamic]Net_Draft,
	cos:          [dynamic]Cos_Draft,
	sources:      [dynamic]Source_Stat,
	texts:        [dynamic]string,
}

builder_init :: proc(b: ^Builder, env := Env{}) {
	_ = virtual.arena_init_growing(&b.arena)
	b.alloc = virtual.arena_allocator(&b.arena)
	b.env = env
	if b.env.defs == nil { b.env.defs = DEFAULT_ENV_DEFS[:] }
	b.net = make([dynamic]Net_Draft, 0, 1024)
	b.cos = make([dynamic]Cos_Draft, 0, 1024)
	b.sources = make([dynamic]Source_Stat)
}

builder_destroy :: proc(b: ^Builder) {
	delete(b.net); delete(b.cos); delete(b.sources); delete(b.texts)
	virtual.arena_destroy(&b.arena)
	b^ = {}
}

////////////////////////////////
// Preprocessor

@(private)
Cond :: struct { s: string, pos: int, defs: []string }

@(private)
cond_skip :: proc(c: ^Cond) { for c.pos < len(c.s) && (c.s[c.pos] == ' ' || c.s[c.pos] == '\t') { c.pos += 1 } }

@(private)
cond_or :: proc(c: ^Cond, depth: int) -> bool {
	v := cond_and(c, depth)
	for {
		cond_skip(c)
		if c.pos + 1 < len(c.s) && c.s[c.pos] == '|' && c.s[c.pos + 1] == '|' { c.pos += 2; r := cond_and(c, depth); v = v || r } else { break }
	}
	return v
}

@(private)
cond_and :: proc(c: ^Cond, depth: int) -> bool {
	v := cond_not(c, depth)
	for {
		cond_skip(c)
		if c.pos + 1 < len(c.s) && c.s[c.pos] == '&' && c.s[c.pos + 1] == '&' { c.pos += 2; r := cond_not(c, depth); v = v && r } else { break }
	}
	return v
}

@(private)
cond_not :: proc(c: ^Cond, depth: int) -> bool {
	cond_skip(c)
	if depth > 32 || c.pos >= len(c.s) { return false }
	switch c.s[c.pos] {
	case '!': c.pos += 1; return !cond_not(c, depth + 1)
	case '(':
		c.pos += 1
		v := cond_or(c, depth + 1)
		cond_skip(c)
		if c.pos < len(c.s) && c.s[c.pos] == ')' { c.pos += 1 }
		return v
	}
	st := c.pos
	for c.pos < len(c.s) && (is_alnum(c.s[c.pos]) || c.s[c.pos] == '_') { c.pos += 1 }
	if st == c.pos { c.pos += 1; return false }
	id := c.s[st:c.pos]
	for d in c.defs { if d == id { return true } }
	return false
}

eval_condition :: proc(expr: string, env: Env) -> bool {
	c := Cond{s = expr, defs = env.defs}
	return cond_or(&c, 0)
}

////////////////////////////////
// Adding lists

// Adds the text of a list. `id` identifies it in the results (Filter.list); `name` is shown to the user.
builder_add :: proc(b: ^Builder, id: u8, name, text: string) {
	builder_add_depth(b, id, name, text, 0)
}

@(private)
builder_add_depth :: proc(b: ^Builder, id: u8, name, text: string, depth: int) {
	si := -1
	for s, i in b.sources { if s.id == id { si = i; break } }
	if si < 0 {
		append(&b.sources, Source_Stat{id = id, name = strings.clone(name, b.alloc), text = text})
		si = len(b.sources) - 1
	}
	Frame :: struct { active, taken, parent_active: bool }
	stack := make([dynamic]Frame, 0, 8, context.temp_allocator)
	active := true
	rest := text
	base_ptr := uintptr(raw_data(text))
	for len(rest) > 0 {
		nl := strings.index_byte(rest, '\n')
		line: string
		if nl < 0 { line, rest = rest, "" } else { line, rest = rest[:nl], rest[nl + 1:] }
		if len(line) > 0 && line[len(line) - 1] == '\r' { line = line[:len(line) - 1] }
		if len(line) == 0 { continue }
		if line[0] == '!' {
			if strings.has_prefix(line, "!#") {
				d := line[2:]
				switch {
				case strings.has_prefix(d, "if "):
					parent := active
					cond := parent && eval_condition(d[3:], b.env)
					append(&stack, Frame{active = cond, taken = cond, parent_active = parent})
					active = cond
				case d == "else":
					if len(stack) > 0 {
						f := &stack[len(stack) - 1]
						f.active = f.parent_active && !f.taken
						f.taken = f.taken || f.active
						active = f.active
					}
				case d == "endif":
					if len(stack) > 0 {
						f := pop(&stack)
						active = f.parent_active
					}
				case strings.has_prefix(d, "include "):
					if active && b.include != nil && depth < 8 {
						path := strings.trim_space(d[len("include "):])
						if iid, iname, itext, ok := b.include(b.include_user, name, path); ok {
							append(&b.texts, itext)
							builder_add_depth(b, iid, iname, itext, depth + 1)
						}
					}
				}
			}
			continue
		}
		if !active { continue }
		off := u32(uintptr(raw_data(line)) - base_ptr)
		p := parse_line(line, id, off, b.alloc)
		switch p.kind {
		case .None:
			if !is_comment_line(line) { b.sources[si].invalid += 1 }
		case .Net:
			append(&b.net, p.net)
			b.sources[si].net += 1
		case .Cos:
			append(&b.cos, p.cos)
			b.sources[si].cosmetic += 1
		}
	}
}

@(private)
is_comment_line :: proc(l: string) -> bool {
	t := strings.trim_space(l)
	return len(t) == 0 || t[0] == '!' || (t[0] == '[' && strings.has_prefix(t, "[")) || (t[0] == '#' && len(t) > 1 && (t[1] == ' ' || t[1] == '\t'))
}

////////////////////////////////
// Building

@(private)
Pair :: struct { key, id, meta: u32 }

@(private)
Out :: struct {
	buf: [dynamic]u8,
}

@(private)
out_align :: proc(o: ^Out) { for len(o.buf) % 8 != 0 { append(&o.buf, 0) } }

@(private)
out_put :: proc(o: ^Out, s: []$T) -> Sec {
	out_align(o)
	off := len(o.buf)
	if len(s) > 0 { append(&o.buf, ..slice.to_bytes(s)) }
	return Sec{u32(off), u32(len(s))}
}

// Builds the open-addressed table of the grouped pairs; the lists go to `items`.
@(private)
build_multi :: proc(pairs: []Pair, items: ^[dynamic]Item) -> []Slot {
	if len(pairs) == 0 { return nil }
	slice.sort_by(pairs, proc(a, b: Pair) -> bool { return a.key != b.key ? a.key < b.key : a.id < b.id })
	groups := 0
	for i in 0 ..< len(pairs) { if i == 0 || pairs[i].key != pairs[i - 1].key { groups += 1 } }
	capn := 4
	for capn < groups * 2 { capn *= 2 }
	tab := make([]Slot, capn)
	mask := u32(capn - 1)
	i := 0
	for i < len(pairs) {
		j := i
		start := u32(len(items^))
		for j < len(pairs) && pairs[j].key == pairs[i].key {
			// (the same filter twice under one key would only cost time)
			if j == i || pairs[j].id != pairs[j - 1].id {
				id := pairs[j].id
				append(items, Item{id, pairs[j].meta})
			}
			j += 1
		}
		items[len(items^) - 1].id |= LAST_BIT
		k := slot_index(pairs[i].key, mask)
		for tab[k].key != 0 { k = (k + 1) & mask }
		tab[k] = Slot{pairs[i].key, start}
		i = j
	}
	return tab
}

// What an Item remembers of a filter: the types it applies to and the party it needs.
@(private)
filter_meta :: proc(f: Filter) -> u32 {
	m := transmute(u32)f.types & 0x1FFFFF
	if .Third_Party in f.flags { m |= META_THIRD_PARTY }
	if .First_Party in f.flags { m |= META_FIRST_PARTY }
	return m
}

// The 4-byte windows (as little-endian words) of a literal run, lower-cased.
@(private)
add_run_grams :: proc(run: string, out: ^[dynamic]u32) {
	for i in 0 ..< max(len(run) - 3, 0) {
		w := u32(lower_byte(run[i])) | u32(lower_byte(run[i + 1])) << 8 | u32(lower_byte(run[i + 2])) << 16 | u32(lower_byte(run[i + 3])) << 24
		append(out, w)
	}
}

@(private)
Tok_Cand :: struct { hash: u32, len: u8 }

// Tokens of a plain pattern that every URL it matches must contain as whole tokens.
@(private)
pattern_tokens :: proc(p: string, flags: Filter_Flags, out: ^[dynamic]Tok_Cand) {
	n := len(p)
	i := 0
	for i < n {
		if !is_token_char(p[i]) { i += 1; continue }
		j := i
		for j < n && is_token_char(p[j]) { j += 1 }
		left := i == 0 ? (flags & {.Left_Anchor, .Host_Anchor} != {}) : p[i - 1] != '*'
		right := j == n ? (.Right_Anchor in flags) : p[j] != '*'
		if left && right { append(out, Tok_Cand{hash_str(p[i:j]), u8(min(j - i, 255))}) }
		i = j
	}
}

// Tokens of a regular expression, only when it is simple enough to be sure (no alternation, no groups).
@(private)
regex_tokens :: proc(p: string, icase: bool, out: ^[dynamic]Tok_Cand) {
	for k in 0 ..< len(p) { if p[k] == '|' || p[k] == '(' || p[k] == '[' || p[k] == '{' { return } }
	n := len(p)
	i := 0
	for i < n {
		c := p[i]
		if c == '\\' { i += 2; continue }
		if !is_alnum(c) { i += 1; continue }
		j := i
		for j < n && is_alnum(p[j]) { j += 1 }
		// a delimiter must follow and precede: a literal non-token character, or an anchor
		before_ok := i == 0 ? false : (p[i - 1] == '/' || p[i - 1] == '.' && i >= 2 && p[i - 2] == '\\' || p[i - 1] == '_' || p[i - 1] == '-' || p[i - 1] == '=' || p[i - 1] == '&' || p[i - 1] == ':' || (p[i - 1] == '^' && i == 1))
		if i >= 2 && p[i - 2] == '\\' && !is_alnum(p[i - 1]) { before_ok = true }
		after_ok := false
		if j >= n { after_ok = p[n - 1] == '$' ? true : false } else {
			d := p[j]
			after_ok = d == '/' || d == '_' || d == '-' || d == '=' || d == '&' || d == ':' || d == '$'
			if d == '\\' && j + 1 < n && !is_alnum(p[j + 1]) { after_ok = true }
			if d == '.' || d == '*' || d == '+' { after_ok = false }
		}
		if before_ok && after_ok {
			buf: [64]u8
			if j - i <= len(buf) {
				for k in 0 ..< j - i { buf[k] = icase ? lower_byte(p[i + k]) : p[i + k] }
				append(out, Tok_Cand{hash_str(string(buf[:j - i])), u8(j - i)})
			}
		}
		i = j
	}
}

@(private)
BAD_TOKENS := [?]string{"http", "https", "www", "com", "net", "org", "js", "html", "php", "png", "jpg", "gif", "css", "co", "io", "de", "fr", "cdn", "static", "assets", "image", "images", "img", "ads", "ad", "api", "json"}

@(private)
Pool :: struct {
	data:   [dynamic]u8,
	interned: map[string]u32,
}

@(private)
pool_add :: proc(p: ^Pool, s: string) -> u32 {
	off := u32(len(p.data))
	append(&p.data, s)
	return off
}

@(private)
pool_add_z :: proc(p: ^Pool, s: string) -> u32 {
	if o, ok := p.interned[s]; ok { return o }
	off := u32(len(p.data))
	append(&p.data, s)
	append(&p.data, 0)
	p.interned[strings.clone(s, context.temp_allocator)] = off
	return off
}

@(private)
Domains :: struct {
	data:   [dynamic]u32,
	interned: map[u64]u32,
}

// Stores a domain list ([n_inc | n_exc << 16][inc...][exc...]); 0 = no list.
@(private)
domains_add :: proc(d: ^Domains, s: Domain_Spec) -> u32 {
	if len(s.inc) == 0 && len(s.exc) == 0 { return 0 }
	h := u64(14695981039346656037)
	for v in s.inc { h = (h ~ u64(v)) * 1099511628211 }
	h = (h ~ 0xdeadbeef) * 1099511628211
	for v in s.exc { h = (h ~ u64(v)) * 1099511628211 }
	if o, ok := d.interned[h]; ok { return o }
	off := u32(len(d.data))
	append(&d.data, u32(min(len(s.inc), 65535)) | u32(min(len(s.exc), 65535)) << 16)
	append(&d.data, ..s.inc[:min(len(s.inc), 65535)])
	append(&d.data, ..s.exc[:min(len(s.exc), 65535)])
	d.interned[h] = off
	return off
}

// Compiles everything added so far to an index blob (allocated with `allocator`, 8-byte aligned).
builder_build :: proc(b: ^Builder, allocator := context.allocator) -> []byte {
	context.allocator = allocator
	tmp := context.temp_allocator

	////// 1. $badfilter and duplicates
	bad := make(map[u64]struct{}, 16, tmp)
	for d in b.net { if d.bad { bad[d.key] = {} } }
	seen := make(map[u64]struct{}, len(b.net), tmp)
	keep := make([dynamic]int, 0, len(b.net), tmp)
	for d, i in b.net {
		if d.bad { continue }
		if d.key in bad { continue }
		if d.key in seen { continue }
		seen[d.key] = {}
		append(&keep, i)
	}

	////// 2. records
	pool := Pool{data = make([dynamic]u8, 0, 1 << 20, tmp), interned = make(map[string]u32, 64, tmp)}
	append(&pool.data, 0)   // offset 0 = "no string"
	doms := Domains{data = make([dynamic]u32, 0, 1024, tmp), interned = make(map[u64]u32, 64, tmp)}
	append(&doms.data, 0)   // offset 0 = "no list"

	filters := make([dynamic]Filter, 0, len(keep) + 64, tmp)
	fclass := make([dynamic]Class, 0, len(keep) + 64, tmp)
	fdraft := make([dynamic]int, 0, len(keep) + 64, tmp)

	add_filter :: proc(filters: ^[dynamic]Filter, fclass: ^[dynamic]Class, fdraft: ^[dynamic]int, pool: ^Pool, doms: ^Domains, d: ^Net_Draft, di: int, class: Class, types: Resource_Set, flags: Filter_Flags) {
		f := Filter{
			pat_off = pool_add(pool, d.pattern), pat_len = u16(min(len(d.pattern), 65535)), flags = flags, types = types,
			methods = d.methods, list = d.list, src_off = domains_add(doms, d.src), to_off = domains_add(doms, d.to),
			arg_off = d.arg == "" ? 0 : pool_add_z(pool, d.arg), text_off = d.text_off,
		}
		append(filters, f)
		append(fclass, class)
		append(fdraft, di)
	}

	for di in keep {
		d := &b.net[di]
		flags := d.flags
		switch d.class {
		case .Allow:
			if d.types & (PAGE_SWITCHES + {.Document}) != {} {
				add_filter(&filters, &fclass, &fdraft, &pool, &doms, d, di, .Page, d.types & (PAGE_SWITCHES + {.Document}), flags)
			}
			if t := d.types - PAGE_SWITCHES; t != {} {
				add_filter(&filters, &fclass, &fdraft, &pool, &doms, d, di, .Allow, t, flags)
			}
		case .Redirect:
			add_filter(&filters, &fclass, &fdraft, &pool, &doms, d, di, .Redirect, d.types, flags)
			if d.redirect_blocks { add_filter(&filters, &fclass, &fdraft, &pool, &doms, d, di, .Block, d.types, flags) }
		case .Block, .Redirect_Allow, .Removeparam, .Removeparam_Allow, .Csp, .Csp_Allow, .Header, .Header_Allow, .Page, .Replace, .Replace_Allow:
			add_filter(&filters, &fclass, &fdraft, &pool, &doms, d, di, d.class, d.types, flags)
		}
	}

	////// 3. tokens: frequency over all candidates, then the rarest per filter
	cands := make([dynamic]Tok_Cand, 0, 16, tmp)
	freq := make(map[u32]u32, len(filters), tmp)
	for f, i in filters {
		if .Host_Only in f.flags || .Empty_Pattern in f.flags { continue }
		clear(&cands)
		pat := string_at_n(pool.data[:], f.pat_off, int(f.pat_len))
		if .Regex in f.flags { regex_tokens(pat, .Match_Case not_in f.flags, &cands) } else { pattern_tokens(pat, f.flags, &cands) }
		for c in cands { freq[c.hash] += 1 }
		_ = i
	}
	bad_hash := make(map[u32]struct{}, 32, tmp)
	for t in BAD_TOKENS { bad_hash[hash_str(t)] = {} }

	idx_host: [CLASS_COUNT][dynamic]Pair
	idx_tok:  [CLASS_COUNT][dynamic]Pair
	idx_gram: [CLASS_COUNT][dynamic]Pair
	idx_src:  [CLASS_COUNT][dynamic]Pair
	idx_none: [CLASS_COUNT][dynamic]Item
	for c in 0 ..< CLASS_COUNT {
		idx_host[c] = make([dynamic]Pair, 0, 64, tmp)
		idx_tok[c] = make([dynamic]Pair, 0, 64, tmp)
		idx_gram[c] = make([dynamic]Pair, 0, 16, tmp)
		idx_src[c] = make([dynamic]Pair, 0, 16, tmp)
		idx_none[c] = make([dynamic]Item, 0, 16, tmp)
	}
	tokenless := make([dynamic]u32, 0, 1024, tmp)
	for f, i in filters {
		c := int(fclass[i])
		id := u32(i)
		meta := filter_meta(f)
		if .Host_Only in f.flags {
			pat := string_at_n(pool.data[:], f.pat_off, int(f.pat_len))
			append(&idx_host[c], Pair{hash_str(pat), id, meta})
			continue
		}
		best := Tok_Cand{}
		best_score := max(u64)
		if .Empty_Pattern not_in f.flags {
			clear(&cands)
			pat := string_at_n(pool.data[:], f.pat_off, int(f.pat_len))
			if .Regex in f.flags { regex_tokens(pat, .Match_Case not_in f.flags, &cands) } else { pattern_tokens(pat, f.flags, &cands) }
			for cd in cands {
				score := u64(freq[cd.hash]) * 8
				if cd.len == 1 { score += 1 << 40 }
				if cd.len == 2 { score += 1 << 20 }
				if cd.hash in bad_hash { score += 1 << 30 }
				score = score * 4 + u64(255 - cd.len) / 64
				if score < best_score { best_score, best = score, cd }
			}
		}
		if best.hash != 0 {
			append(&idx_tok[c], Pair{best.hash, id, meta})
			continue
		}
		append(&tokenless, id)
	}

	// Filters without a token are filed under the rarest 4-byte window of a literal part of their pattern; those
	// without one (short patterns, nothing literal), under their source domains; the rest are checked every time.
	gram_freq := make(map[u32]u32, len(tokenless) * 8, tmp)
	grams := make([dynamic]u32, 0, 32, tmp)
	filter_grams :: proc(f: Filter, pool: []u8, out: ^[dynamic]u32) {
		clear(out)
		if .Empty_Pattern in f.flags { return }
		pat := string_at_n(pool, f.pat_off, int(f.pat_len))
		if .Regex in f.flags {
			re, ok := regex_compile(pat, .Match_Case not_in f.flags)
			if !ok { return }
			defer regex_destroy(&re)
			add_run_grams(re.literal, out)
			return
		}
		start := 0
		for i in 0 ..= len(pat) {
			if i == len(pat) || pat[i] == '*' || pat[i] == '^' {
				add_run_grams(pat[start:i], out)
				start = i + 1
			}
		}
	}
	for id in tokenless {
		filter_grams(filters[id], pool.data[:], &grams)
		for g in grams { gram_freq[g] += 1 }
	}
	for id in tokenless {
		f := filters[id]
		c := int(fclass[id])
		meta := filter_meta(f)
		filter_grams(f, pool.data[:], &grams)
		if len(grams) > 0 {
			best := grams[0]
			for g in grams { if gram_freq[g] < gram_freq[best] { best = g } }
			append(&idx_gram[c], Pair{best, id, meta})
			continue
		}
		if f.src_off != 0 {
			n_inc := int(doms.data[f.src_off] & 0xFFFF)
			if n_inc > 0 {
				for k in 0 ..< n_inc { append(&idx_src[c], Pair{doms.data[int(f.src_off) + 1 + k], id, meta}) }
				continue
			}
		}
		append(&idx_none[c], Item{id, meta})
	}

	////// 4. cosmetic filters
	cos_records := make([dynamic]Cos_Filter, 0, len(b.cos), tmp)
	cos_key_pairs := make([dynamic]Pair, 0, 1024, tmp)
	cos_host_pairs := make([dynamic]Pair, 0, 1024, tmp)
	cos_generic := make([dynamic]u32, 0, 64, tmp)
	cos_generic_exc := make([dynamic]u32, 0, 64, tmp)
	cos_seen := make(map[u64]struct{}, len(b.cos), tmp)
	for d in b.cos {
		// duplicates (the same selector, flags and domains from several lists)
		h := u64(14695981039346656037)
		for i in 0 ..< len(d.selector) { h = (h ~ u64(d.selector[i])) * 1099511628211 }
		h = (h ~ u64(transmute(u16)d.flags)) * 1099511628211
		for v in d.src.inc { h = (h ~ u64(v)) * 1099511628211 }
		h = (h ~ 0xabcd) * 1099511628211
		for v in d.src.exc { h = (h ~ u64(v)) * 1099511628211 }
		if h in cos_seen { continue }
		cos_seen[h] = {}
		cf := Cos_Filter{
			sel_off = pool_add(&pool, d.selector), sel_len = u32(len(d.selector)), flags = d.flags, list = d.list,
			src_off = domains_add(&doms, d.src), sel_hash = hash_str(d.selector), key = d.key, text_off = d.text_off,
		}
		append(&cos_records, cf)
		id := u32(len(cos_records) - 1)
		if len(d.src.inc) > 0 {
			// specific: filed under each included domain; entity hashes (`google.*`) share the table, their key space
			// cannot collide with a host name's (a host has no '*')
			for v in d.src.inc { append(&cos_host_pairs, Pair{v, id, 0}) }
		} else if .Exception in d.flags {
			append(&cos_generic_exc, id)
		} else if .Keyed in d.flags {
			append(&cos_key_pairs, Pair{d.key, id, 0})
		} else {
			append(&cos_generic, id)
		}
	}

	////// 5. write
	o := Out{buf = make([dynamic]u8, 0, 1 << 20)}
	defer delete(o.buf)
	hdr := Header{magic = MAGIC, version = VERSION, n_filters = u32(len(filters)), n_cos = u32(len(cos_records))}
	append(&o.buf, ..mem.ptr_to_bytes(&hdr))
	hdr.secs[SEC_STRINGS] = out_put(&o, pool.data[:])
	hdr.secs[SEC_FILTERS] = out_put(&o, filters[:])
	hdr.secs[SEC_DOMAINS] = out_put(&o, doms.data[:])
	hdr.secs[SEC_COS] = out_put(&o, cos_records[:])

	cos_items := make([dynamic]Item, 0, 1024, tmp)
	ck := build_multi(cos_key_pairs[:], &cos_items)
	ch := build_multi(cos_host_pairs[:], &cos_items)
	hdr.cos_generic = NO_LIST
	if len(cos_generic) > 0 {
		hdr.cos_generic = u32(len(cos_items))
		for g in cos_generic { append(&cos_items, Item{g, 0}) }
		cos_items[len(cos_items) - 1].id |= LAST_BIT
	}
	hdr.cos_generic_exc = NO_LIST
	if len(cos_generic_exc) > 0 {
		hdr.cos_generic_exc = u32(len(cos_items))
		for g in cos_generic_exc { append(&cos_items, Item{g, 0}) }
		cos_items[len(cos_items) - 1].id |= LAST_BIT
	}
	hdr.secs[SEC_COS_KEY] = out_put(&o, ck)
	hdr.secs[SEC_COS_HOST] = out_put(&o, ch)
	hdr.secs[SEC_COS_ITEMS] = out_put(&o, cos_items[:])

	// sources
	name_blob := make([dynamic]u8, 0, 256, tmp)
	ents := make([dynamic]Source_Entry, 0, len(b.sources), tmp)
	base: u32
	for s in b.sources {
		append(&ents, Source_Entry{name_off = u32(len(name_blob)), name_len = u32(len(s.name)), id = s.id, net = s.net, cosmetic = s.cosmetic, invalid = s.invalid, text_base = base, text_len = u32(len(s.text))})
		base += u32(len(s.text))
		append(&name_blob, s.name)
	}
	hdr.secs[SEC_SOURCES] = out_put(&o, ents[:])
	hdr.secs[SEC_SOURCE_NAMES] = out_put(&o, name_blob[:])

	for c in 0 ..< CLASS_COUNT {
		items := make([dynamic]Item, 0, 1024, tmp)
		th := build_multi(idx_host[c][:], &items)
		tt := build_multi(idx_tok[c][:], &items)
		ts := build_multi(idx_src[c][:], &items)
		tg := build_multi(idx_gram[c][:], &items)
		hdr.notoken[c] = NO_LIST
		if len(idx_none[c]) > 0 {
			hdr.notoken[c] = u32(len(items))
			append(&items, ..idx_none[c][:])
			items[len(items) - 1].id |= LAST_BIT
		}
		base_s := SEC_CLASS_BASE + c * SEC_CLASS_SECS
		hdr.secs[base_s + 0] = out_put(&o, th)
		hdr.secs[base_s + 1] = out_put(&o, tt)
		hdr.secs[base_s + 2] = out_put(&o, ts)
		hdr.secs[base_s + 3] = out_put(&o, tg)
		hdr.secs[base_s + 4] = out_put(&o, items[:])
		delete(th); delete(tt); delete(ts); delete(tg)
	}
	delete(ck); delete(ch)

	out_align(&o)
	hdr.total = u64(len(o.buf))
	hdr.checksum = checksum_bytes(o.buf[size_of(Header):])
	mem.copy(raw_data(o.buf), &hdr, size_of(Header))

	// 8-byte aligned, so that the records can be read in place
	words := make([]u64, (len(o.buf) + 7) / 8)
	mem.copy(raw_data(words), raw_data(o.buf), len(o.buf))
	return ([^]byte)(raw_data(words))[:len(o.buf)]
}


@(private)
string_at_n :: proc(data: []u8, off: u32, n: int) -> string {
	return string(data[off:int(off) + n])
}

_ :: runtime

// How many lines of a downloaded list are filters (and how many are not understood): a body that is not a list
// (an error page, a login wall) has none, and replaces nothing.
validate_list :: proc(text: string) -> (valid, invalid: int) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)
	rest := text
	n := 0
	for len(rest) > 0 {
		nl := strings.index_byte(rest, '\n')
		line: string
		if nl < 0 { line, rest = rest, "" } else { line, rest = rest[:nl], rest[nl + 1:] }
		t := strings.trim_space(line)
		if len(t) == 0 || t[0] == '!' { continue }
		p := parse_line(t, 0, 0, alloc)
		if p.kind == .None { if !is_comment_line(t) { invalid += 1 } } else { valid += 1 }
		n += 1
		if n % 4096 == 0 { virtual.arena_free_all(&arena) }
	}
	return
}

// The line that starts at `offset` of a list's text (what Filter_Ref points to).
line_at :: proc(text: string, offset: u32) -> string {
	if int(offset) >= len(text) { return "" }
	s := text[offset:]
	if nl := strings.index_byte(s, '\n'); nl >= 0 { s = s[:nl] }
	return strings.trim_right_space(s)
}

// The lists added so far, in order (their texts are what the .src file next to an index is made of).
builder_sources :: proc(b: ^Builder) -> []Source_Stat { return b.sources[:] }