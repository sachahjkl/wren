package adblock

import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:strings"

BLOOM_MAX_BITS :: 1 << 23

Index :: struct {
	host:    []Slot,
	tok:     []Slot,
	src:     []Slot,
	gram:    []Slot,
	items:   []Item,
	notoken: u32,
	bloom:   []u64,
	bloom_shift: u32,
	gram_bloom: []u64,
	gram_shift: u32,
}

Engine :: struct {
	blob:     []byte,
	owned:    bool,
	hdr:      Header,
	pool:     []u8,
	filters:  []Filter,
	domains:  []u32,
	cos:      []Cos_Filter,
	cos_key:  []Slot,
	cos_host: []Slot,
	cos_items: []Item,
	sources:  []Source_Entry,
	source_names: []u8,
	idx:      [CLASS_COUNT]Index,

	// the only mutable parts: compiled regular expressions (filled on first use) and the VM's scratch memory
	regex:    map[u32]^Regex,
	scratch:  Regex_Scratch,
	allocator: runtime.Allocator,
}

Load_Error :: enum u8 { None, Too_Small, Bad_Magic, Bad_Version, Bad_Section, Bad_Checksum }

@(private)
section_of :: proc(blob: []byte, s: Sec, $T: typeid) -> (r: []T, ok: bool) {
	size := u64(size_of(T))
	end := u64(s.off) + u64(s.count) * size
	if end > u64(len(blob)) || u64(s.off) % u64(align_of(T)) != 0 { return nil, false }
	if s.count == 0 { return nil, true }
	return ([^]T)(raw_data(blob)[s.off:])[:s.count], true
}

// Reads a blob made by `builder_build`. The engine keeps using `blob` (it must stay valid until `engine_destroy`);
// with `own` the engine frees it. `verify` checks the checksum (reads every byte once).
engine_load :: proc(blob: []byte, own := false, verify := true, allocator := context.allocator) -> (e: ^Engine, err: Load_Error) {
	if len(blob) < size_of(Header) { return nil, .Too_Small }
	if uintptr(raw_data(blob)) % 8 != 0 { return nil, .Bad_Section }
	hdr := (^Header)(raw_data(blob))^
	if hdr.magic != MAGIC { return nil, .Bad_Magic }
	if hdr.version != VERSION { return nil, .Bad_Version }
	if hdr.total != u64(len(blob)) { return nil, .Too_Small }
	if verify && checksum_bytes(blob[size_of(Header):]) != hdr.checksum { return nil, .Bad_Checksum }

	context.allocator = allocator
	e = new(Engine)
	e.allocator = allocator
	e.blob, e.owned, e.hdr = blob, own, hdr
	ok: bool
	if e.pool, ok = section_of(blob, hdr.secs[SEC_STRINGS], u8); !ok { free(e); return nil, .Bad_Section }
	if e.filters, ok = section_of(blob, hdr.secs[SEC_FILTERS], Filter); !ok { free(e); return nil, .Bad_Section }
	if e.domains, ok = section_of(blob, hdr.secs[SEC_DOMAINS], u32); !ok { free(e); return nil, .Bad_Section }
	if e.cos, ok = section_of(blob, hdr.secs[SEC_COS], Cos_Filter); !ok { free(e); return nil, .Bad_Section }
	if e.cos_key, ok = section_of(blob, hdr.secs[SEC_COS_KEY], Slot); !ok { free(e); return nil, .Bad_Section }
	if e.cos_host, ok = section_of(blob, hdr.secs[SEC_COS_HOST], Slot); !ok { free(e); return nil, .Bad_Section }
	if e.cos_items, ok = section_of(blob, hdr.secs[SEC_COS_ITEMS], Item); !ok { free(e); return nil, .Bad_Section }
	if e.sources, ok = section_of(blob, hdr.secs[SEC_SOURCES], Source_Entry); !ok { free(e); return nil, .Bad_Section }
	if e.source_names, ok = section_of(blob, hdr.secs[SEC_SOURCE_NAMES], u8); !ok { free(e); return nil, .Bad_Section }
	for c in 0 ..< CLASS_COUNT {
		b := SEC_CLASS_BASE + c * SEC_CLASS_SECS
		ix := &e.idx[c]
		if ix.host, ok = section_of(blob, hdr.secs[b + 0], Slot); !ok { free(e); return nil, .Bad_Section }
		if ix.tok, ok = section_of(blob, hdr.secs[b + 1], Slot); !ok { free(e); return nil, .Bad_Section }
		if ix.src, ok = section_of(blob, hdr.secs[b + 2], Slot); !ok { free(e); return nil, .Bad_Section }
		if ix.gram, ok = section_of(blob, hdr.secs[b + 3], Slot); !ok { free(e); return nil, .Bad_Section }
		if ix.items, ok = section_of(blob, hdr.secs[b + 4], Item); !ok { free(e); return nil, .Bad_Section }
		ix.notoken = hdr.notoken[c]
		build_bloom(ix)
	}
	e.regex = make(map[u32]^Regex)
	return e, .None
}

@(private)
bloom_hash :: #force_inline proc "contextless" (key, shift: u32) -> u32 { return (key * 2654435761) >> shift }

@(private)
make_bloom :: proc(tab: []Slot) -> (bits: []u64, shift: u32) {
	n := 0
	for s in tab { if s.key != 0 { n += 1 } }
	if n == 0 { return nil, 0 }
	nb := 1 << 10
	for nb < n * 12 && nb < BLOOM_MAX_BITS { nb <<= 1 }
	log := u32(0)
	for (1 << log) < nb { log += 1 }
	bits = make([]u64, nb / 64)
	shift = 32 - log
	for s in tab {
		if s.key == 0 { continue }
		h := bloom_hash(s.key, shift)
		bits[h >> 6] |= 1 << (h & 63)
	}
	return
}

@(private)
build_bloom :: proc(ix: ^Index) {
	ix.bloom, ix.bloom_shift = make_bloom(ix.tok)
	ix.gram_bloom, ix.gram_shift = make_bloom(ix.gram)
}
engine_destroy :: proc(e: ^Engine) {
	if e == nil { return }
	context.allocator = e.allocator
	for _, r in e.regex { if r != nil { regex_destroy(r); free(r) } }
	delete(e.regex)
	regex_scratch_destroy(&e.scratch)
	for &ix in e.idx { delete(ix.bloom); delete(ix.gram_bloom) }
	if e.owned { delete(e.blob) }
	free(e)
}

engine_filter_count :: proc(e: ^Engine) -> int { return len(e.filters) }
engine_cosmetic_count :: proc(e: ^Engine) -> int { return len(e.cos) }
engine_size :: proc(e: ^Engine) -> int { return len(e.blob) }

// The lists the engine was built from (as given to `builder_add`) with what each contributed.
Source_Info :: struct { id: u8, name: string, net, cosmetic, invalid: u32 }

engine_sources :: proc(e: ^Engine, allocator := context.allocator) -> []Source_Info {
	out := make([]Source_Info, len(e.sources), allocator)
	for s, i in e.sources {
		out[i] = Source_Info{id = s.id, name = string(e.source_names[s.name_off:s.name_off + s.name_len]), net = s.net, cosmetic = s.cosmetic, invalid = s.invalid}
	}
	return out
}

@(private)
pool_str :: #force_inline proc "contextless" (e: ^Engine, off: u32, n: int) -> string {
	return string(e.pool[off:int(off) + n])
}

@(private)
pattern_of :: #force_inline proc "contextless" (e: ^Engine, f: ^Filter) -> string { return pool_str(e, f.pat_off, int(f.pat_len)) }

// A NUL-terminated string of the pool ("" for offset 0).
@(private)
cstr_at :: proc "contextless" (e: ^Engine, off: u32) -> string {
	if off == 0 { return "" }
	end := int(off)
	for end < len(e.pool) && e.pool[end] != 0 { end += 1 }
	return string(e.pool[off:end])
}

filter_arg :: proc(e: ^Engine, id: u32) -> string { return cstr_at(e, e.filters[id].arg_off) }
filter_ref :: proc(e: ^Engine, id: u32) -> Filter_Ref {
	if int(id) >= len(e.filters) { return {} }
	f := &e.filters[id]
	return Filter_Ref{f.list, f.text_off}
}

////////////////////////////////
// The request context

MAX_TOKENS :: 96
MAX_URL    :: 8192
MAX_SUFFIXES :: 12
GRAM_WINDOWS :: 2048   // 4-byte windows of a URL looked up in the gram table

@(private)
Ctx :: struct {
	req:     ^Request,
	page_mode: bool,            // matching a page's own URL against the page switches (page_flags)
	type_bit: u32,              // 1 << request type: tested against Item.meta
	party_skip: u32,            // the META_ bit of the party this request is not
	url_l:   string,            // lower case
	url_o:   string,            // as given
	hs, he:  int,
	host:    string,            // lower-case request host
	n_tok:   int,
	tokens:  [MAX_TOKENS]u32,

	n_dst:   int,               // label suffixes of the request host
	dst_h:   [MAX_SUFFIXES]u32,
	dst_at:  [MAX_SUFFIXES]u16,

	src_ready: bool,
	n_src:   int,               // label suffixes of the source host + entity forms
	src_h:   [MAX_SUFFIXES * 2]u32,
	src_at:  [MAX_SUFFIXES]u16, // (only the name suffixes)
	n_src_names: int,
}

@(private)
ctx_init :: proc(c: ^Ctx, req: ^Request, buf: []u8) {
	c.req = req
	c.type_bit = u32(1) << u32(req.type)
	c.party_skip = req.third_party ? META_FIRST_PARTY : META_THIRD_PARTY
	n := min(len(req.url), len(buf))
	lower_into(buf[:n], req.url[:n])
	c.url_l = string(buf[:n])
	c.url_o = req.url[:n]
	if p, ok := url_parts(c.url_l); ok { c.hs, c.he = p.host_start, p.host_end }
	c.host = c.url_l[c.hs:c.he]

	// tokens
	i := 0
	for i < n && c.n_tok < MAX_TOKENS {
		ch := buf[i]
		if !is_token_char(ch) { i += 1; continue }
		h := FNV_OFFSET
		for i < n && is_token_char(buf[i]) { h = (h ~ u32(buf[i])) * FNV_PRIME; i += 1 }
		c.tokens[c.n_tok] = h == 0 ? 1 : h
		c.n_tok += 1
	}

	// label suffixes of the host
	host := c.host
	start := 0
	for start <= len(host) && c.n_dst < MAX_SUFFIXES && len(host) > 0 {
		c.dst_h[c.n_dst] = hash_str(host[start:])
		c.dst_at[c.n_dst] = u16(start)
		c.n_dst += 1
		d := strings.index_byte(host[start:], '.')
		if d < 0 { break }
		start += d + 1
	}
}

@(private)
ctx_source :: proc(c: ^Ctx) {
	if c.src_ready { return }
	c.src_ready = true
	c.n_src, c.n_src_names = host_hash_set(c.req.source_host, c.src_h[:])
}

@(private)
bsearch :: #force_inline proc "contextless" (a: []u32, v: u32) -> bool {
	lo, hi := 0, len(a)
	for lo < hi {
		mid := (lo + hi) >> 1
		if a[mid] < v { lo = mid + 1 } else { hi = mid }
	}
	return lo < len(a) && a[lo] == v
}

// A domain list against a set of hashes: none of the excluded ones, and (when there are included ones) at least one.
@(private)
domain_list_ok :: proc(e: ^Engine, off: u32, hashes: []u32) -> bool {
	head := e.domains[off]
	n_inc := int(head & 0xFFFF)
	n_exc := int(head >> 16)
	inc := e.domains[int(off) + 1:int(off) + 1 + n_inc]
	exc := e.domains[int(off) + 1 + n_inc:int(off) + 1 + n_inc + n_exc]
	if n_exc > 0 { for h in hashes { if bsearch(exc, h) { return false } } }
	if n_inc == 0 { return true }
	for h in hashes { if bsearch(inc, h) { return true } }
	return false
}

@(private)
get_regex :: proc(e: ^Engine, fid: u32) -> ^Regex {
	if r, ok := e.regex[fid]; ok { return r }
	f := &e.filters[fid]
	re, ok := regex_compile(pattern_of(e, f), .Match_Case not_in f.flags)
	if !ok { e.regex[fid] = nil; return nil }
	p := new_clone(re, e.allocator)
	e.regex[fid] = p
	return p
}

// Everything but the pattern: type, party, method, then the pattern, then the domain lists.
@(private)
check_filter :: proc(e: ^Engine, c: ^Ctx, fid: u32, skip_pattern: bool) -> bool {
	f := &e.filters[fid]
	req := c.req
	if !c.page_mode {
		if req.type not_in f.types { return false }
		if .Third_Party in f.flags && !req.third_party { return false }
		if .First_Party in f.flags && req.third_party { return false }
	}
	if f.methods != {} && req.method not_in f.methods { return false }
	// the domain lists are cheaper than a pattern (and than a regular expression by far): first
	if f.to_off != 0 && !domain_list_ok(e, f.to_off, c.dst_h[:c.n_dst]) { return false }
	if f.src_off != 0 {
		ctx_source(c)
		if !domain_list_ok(e, f.src_off, c.src_h[:c.n_src]) { return false }
	}
	if !skip_pattern && .Empty_Pattern not_in f.flags {
		pat := pattern_of(e, f)
		if .Regex in f.flags {
			re := get_regex(e, fid)
			if re == nil || !regex_match(re, &e.scratch, c.url_o) { return false }
		} else {
			url := .Needs_Original in f.flags ? c.url_o : c.url_l
			if !pattern_match(pat, f.flags, url, c.hs, c.he) { return false }
		}
	}
	return true
}

// Sizes of the always-checked list and the biggest token buckets of a class (diagnostics).
Index_Stats :: struct { notoken, hosts, tokens, srcs, grams: int, biggest: [8]int }

engine_index_stats :: proc(e: ^Engine, class: Class) -> (s: Index_Stats) {
	ix := &e.idx[class]
	list_len :: proc(ix: ^Index, start: u32) -> int {
		n := 0
		i := start
		for { n += 1; if ix.items[i].id & LAST_BIT != 0 { break }; i += 1 }
		return n
	}
	if ix.notoken != NO_LIST { s.notoken = list_len(ix, ix.notoken) }
	for sl in ix.host { if sl.key != 0 { s.hosts += 1 } }
	for sl in ix.src { if sl.key != 0 { s.srcs += 1 } }
	for sl in ix.gram { if sl.key != 0 { s.grams += 1 } }
	for sl in ix.tok {
		if sl.key == 0 { continue }
		s.tokens += 1
		n := list_len(ix, sl.val)
		for k in 0 ..< 8 { if n > s.biggest[k] { copy(s.biggest[k + 1:], s.biggest[k:7]); s.biggest[k] = n; break } }
	}
	return
}


@(private)
Scan_Result :: struct { any, important: u32 }

@(private)
Scan_Opts :: struct {
	stop_first:     bool,            // return at the first match
	important_only: bool,            // only filters with `$important`
	use_arg:        bool,            // only filters whose argument is empty or equals `arg` (exceptions of redirect / removeparam / csp)
	arg:            string,
	collect:        ^[dynamic]u32,   // every match is appended (nothing stops the walk)
}

// Tests one candidate; true when the walk must stop.
@(private)
try_candidate :: proc(e: ^Engine, c: ^Ctx, it: Item, skip_pattern: bool, res: ^Scan_Result, o: ^Scan_Opts) -> bool {
	// the cheap discards come from the item itself, without reading the filter record
	if it.meta & c.type_bit == 0 || it.meta & c.party_skip != 0 { return false }
	fid := it.id & ~LAST_BIT
	f := &e.filters[fid]
	if o.important_only && .Important not_in f.flags { return false }
	if o.use_arg {
		a := cstr_at(e, f.arg_off)
		if a != "" && a != o.arg { return false }
	}
	if !check_filter(e, c, fid, skip_pattern) { return false }
	if o.collect != nil { append(o.collect, fid); return false }
	if res.any == NO_FILTER { res.any = fid }
	if .Important in f.flags { res.important = fid; return true }
	return o.stop_first
}

@(private)
visit :: proc(e: ^Engine, ix: ^Index, c: ^Ctx, start: u32, res: ^Scan_Result, o: ^Scan_Opts) -> bool {
	i := start
	for {
		it := ix.items[i]
		if try_candidate(e, c, it, false, res, o) { return true }
		if it.id & LAST_BIT != 0 { break }
		i += 1
	}
	return false
}

// Walks the candidates of a class for a request: the host table (probed with each label suffix of the request host),
// the token table (each token of the URL, behind a bloom filter), the 4-byte-gram table (for filters without a token),
// the table of source domains, and the few filters without any hook.
@(private)
scan :: proc(e: ^Engine, class: Class, c: ^Ctx, opts: Scan_Opts) -> Scan_Result {
	ix := &e.idx[class]
	o := opts
	res := Scan_Result{NO_FILTER, NO_FILTER}

	if len(ix.host) > 0 {
		host := c.host
		for k in 0 ..< c.n_dst {
			start, found := multi_find(ix.host, c.dst_h[k])
			if !found { continue }
			suffix := host[c.dst_at[k]:]
			i := start
			for {
				it := ix.items[i]
				// the pattern is the host: verified, a hash collision must not block
				if pattern_of(e, &e.filters[it.id & ~LAST_BIT]) == suffix && try_candidate(e, c, it, true, &res, &o) { return res }
				if it.id & LAST_BIT != 0 { break }
				i += 1
			}
		}
	}
	if len(ix.tok) > 0 {
		for t in 0 ..< c.n_tok {
			key := c.tokens[t]
			bh := bloom_hash(key, ix.bloom_shift)
			if ix.bloom[bh >> 6] & (1 << (bh & 63)) == 0 { continue }
			if start, found := multi_find(ix.tok, key); found && visit(e, ix, c, start, &res, &o) { return res }
		}
	}
	if len(ix.gram) > 0 {
		n := min(len(c.url_l) - 3, GRAM_WINDOWS)
		p := raw_data(c.url_l)
		for i in 0 ..< n {
			key := intrinsics.unaligned_load((^u32)(rawptr(uintptr(p) + uintptr(i))))
			bh := bloom_hash(key, ix.gram_shift)
			if ix.gram_bloom[bh >> 6] & (1 << (bh & 63)) == 0 { continue }
			if start, found := multi_find(ix.gram, key); found && visit(e, ix, c, start, &res, &o) { return res }
		}
	}
	if len(ix.src) > 0 {
		ctx_source(c)
		for k in 0 ..< c.n_src {
			if start, found := multi_find(ix.src, c.src_h[k]); found && visit(e, ix, c, start, &res, &o) { return res }
		}
	}
	if ix.notoken != NO_LIST && visit(e, ix, c, ix.notoken, &res, &o) { return res }
	return res
}

@(private)
class_empty :: #force_inline proc "contextless" (e: ^Engine, class: Class) -> bool {
	ix := &e.idx[class]
	return len(ix.host) == 0 && len(ix.tok) == 0 && len(ix.gram) == 0 && len(ix.src) == 0 && ix.notoken == NO_LIST
}
////////////////////////////////
// Matching

// The decision for a request: is it blocked, and by what?
match :: proc(e: ^Engine, req: ^Request) -> Verdict {
	v := Verdict{filter = NO_FILTER, blocker = NO_FILTER, redirect = NO_FILTER}
	if e == nil || len(req.url) < 8 || req.type == .Elemhide { return v }
	// only network schemes are ever filtered
	switch req.url[0] {
	case 'h', 'H', 'w', 'W', 'f', 'F': // http(s), ws(s), ftp
	case: return v
	}
	buf: [MAX_URL]u8
	c: Ctx
	ctx_init(&c, req, buf[:])
	if c.he <= c.hs { return v }

	r := scan(e, .Block, &c, {})
	blocker := r.important != NO_FILTER ? r.important : r.any
	if blocker == NO_FILTER { return v }
	v.blocker = blocker
	important := r.important != NO_FILTER
	if !class_empty(e, .Allow) {
		x := scan(e, .Allow, &c, {stop_first = true, important_only = important})
		if x.any != NO_FILTER {
			v.action, v.filter = .Exception, x.any
			return v
		}
	}
	v.action, v.filter = .Block, blocker
	// a neutral resource instead of an error?
	rd := scan(e, .Redirect, &c, {stop_first = true})
	if rd.any != NO_FILTER {
		name := cstr_at(e, e.filters[rd.any].arg_off)
		if name != "" {
			cancelled := false
			if !class_empty(e, .Redirect_Allow) {
				x := scan(e, .Redirect_Allow, &c, {stop_first = true, use_arg = true, arg = name})
				cancelled = x.any != NO_FILTER
			}
			if !cancelled {
				v.action, v.redirect, v.resource = .Redirect, rd.any, name
			}
		}
	}
	return v
}

// Would a request be blocked, ignoring exceptions? (for tools that explain a page)
match_blocking :: proc(e: ^Engine, req: ^Request) -> u32 {
	if e == nil { return NO_FILTER }
	buf: [MAX_URL]u8
	c: Ctx
	ctx_init(&c, req, buf[:])
	r := scan(e, .Block, &c, {})
	return r.important != NO_FILTER ? r.important : r.any
}

Page_Flag :: enum u8 { Document, Elemhide, Generichide, Specifichide }
Page_Flags :: bit_set[Page_Flag; u8]

// What a page's own URL switches off for the whole page (`@@||site^$document`, `$elemhide`, `$generichide`, `$specifichide`).
page_flags :: proc(e: ^Engine, page_url: string) -> (flags: Page_Flags, filter: u32) {
	filter = NO_FILTER
	if e == nil || class_empty(e, .Page) { return }
	req := make_request(page_url, "", .Document)
	buf: [MAX_URL]u8
	c: Ctx
	ctx_init(&c, &req, buf[:])
	if c.he <= c.hs { return }
	// the filters' types are the switches, not request types: nothing is discarded by type or party
	c.page_mode = true
	c.type_bit = ~u32(0)
	c.party_skip = 0
	found := make([dynamic]u32, 0, 4, context.temp_allocator)
	scan(e, .Page, &c, Scan_Opts{collect = &found})
	for fid in found {
		t := e.filters[fid].types
		if .Document in t { flags += {.Document} }
		if .Elemhide in t { flags += {.Elemhide} }
		if .Generichide in t { flags += {.Generichide} }
		if .Specifichide in t { flags += {.Specifichide} }
		if filter == NO_FILTER { filter = fid }
	}
	return
}
_ :: mem
