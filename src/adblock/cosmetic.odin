package adblock

import "core:slice"
import "core:strings"

// Cosmetic filters for one document.
//
// At the start of a document the engine gives the filters that apply to its host (`cosmetic_for_host`): the specific ones
// (`example.com##.ad`, entities like `google.*`), the generic ones that cannot be keyed to a class or an id, the
// scriptlets and the HTML filters, with the exceptions (`#@#`) already applied. The generic selectors that need a class
// or an id (the bulk of EasyList: `##.banner-ad`) are not handed out up front: the page asks for them by key
// (`cosmetic_keyed`) with the classes and ids its DOM really contains, so a page only pays for the selectors that can
// match something on it.

Cosmetic :: struct {
	host:        string,
	hashes:      [MAX_SUFFIXES * 2]u32,
	n_hashes:    int,
	active:      [dynamic]u32,    // specific and unkeyed generic filters of every kind, exceptions applied
	excepted:    [dynamic]u32,    // sorted selector hashes cancelled by exceptions
	no_scriptlets: bool,          // `#@#+js()`
	no_html:     bool,
	generic_hide: bool,           // generic selectors are applied (no `$generichide` / `$elemhide`)
	specific_hide: bool,
	cosmetic_hide: bool,          // element hiding at all (no `$elemhide` / `$document`)
}

cosmetic_destroy :: proc(c: ^Cosmetic) {
	delete(c.active); delete(c.excepted)
	c^ = {}
}

// Name-suffix hashes of a host, then the entity forms of its part left of the public suffix.
@(private)
host_hash_set :: proc(h: string, out: []u32) -> (n, n_names: int) {
	if h == "" { return }
	start := 0
	for n < MAX_SUFFIXES {
		out[n] = hash_str(h[start:])
		n += 1
		d := strings.index_byte(h[start:], '.')
		if d < 0 { break }
		start += d + 1
	}
	n_names = n
	if is_ip_host(h) { return }
	k := suffix_labels(h)
	labels := 1
	for i in 0 ..< len(h) { if h[i] == '.' { labels += 1 } }
	if labels <= k { return }
	cut := len(h)
	seen := 0
	for cut > 0 && seen < k { cut -= 1; if h[cut] == '.' { seen += 1 } }
	prefix := h[:cut]
	s := 0
	for ents := 0; ents < 6 && n < len(out); ents += 1 {
		out[n] = hash_entity(prefix[s:])
		n += 1
		d := strings.index_byte(prefix[s:], '.')
		if d < 0 { break }
		s += d + 1
	}
	return
}

Cos_View :: struct {
	selector: string,
	flags:    Cos_Flags,
	list:     u8,
	text_off: u32,
	id:       u32,
}

cosmetic_filter :: proc(e: ^Engine, id: u32) -> Cos_View {
	f := &e.cos[id]
	return Cos_View{selector = pool_str(e, f.sel_off, int(f.sel_len)), flags = f.flags, list = f.list, text_off = f.text_off, id = id}
}

@(private)
is_excepted :: proc(c: ^Cosmetic, hash: u32) -> bool { return bsearch(c.excepted[:], hash) }

// The filters of a host. `flags`: what the page's own exceptions already switch off (page_flags).
cosmetic_for_host :: proc(e: ^Engine, host: string, flags: Page_Flags, allocator := context.allocator) -> Cosmetic {
	c := Cosmetic{host = host}
	c.active = make([dynamic]u32, 0, 16, allocator)
	c.excepted = make([dynamic]u32, 0, 4, allocator)
	c.cosmetic_hide = .Elemhide not_in flags && .Document not_in flags
	c.generic_hide = c.cosmetic_hide && .Generichide not_in flags
	c.specific_hide = c.cosmetic_hide && .Specifichide not_in flags
	if e == nil || len(e.cos) == 0 { return c }
	if .Document in flags { c.no_scriptlets = true; c.no_html = true }
	c.n_hashes, _ = host_hash_set(host, c.hashes[:])
	hs := c.hashes[:c.n_hashes]

	specific := make([dynamic]u32, 0, 16, context.temp_allocator)
	for h in hs {
		start, ok := multi_find(e.cos_host, h)
		if !ok { continue }
		i := start
		for {
			v := e.cos_items[i]
			id := v & ~LAST_BIT
			dup := false
			for s in specific { if s == id { dup = true; break } }
			if !dup && domain_list_ok(e, e.cos[id].src_off, hs) { append(&specific, id) }
			if v & LAST_BIT != 0 { break }
			i += 1
		}
	}
	// exceptions: specific ones found above, generic ones in their own list
	note_exception :: proc(e: ^Engine, c: ^Cosmetic, id: u32) {
		f := &e.cos[id]
		if .Scriptlet in f.flags && f.sel_len == 0 { c.no_scriptlets = true; return }
		if .Html in f.flags && f.sel_len == 0 { c.no_html = true; return }
		append(&c.excepted, f.sel_hash)
	}
	for id in specific { if .Exception in e.cos[id].flags { note_exception(e, &c, id) } }
	if e.hdr.cos_generic_exc != NO_LIST {
		i := e.hdr.cos_generic_exc
		for {
			v := e.cos_items[i]
			id := v & ~LAST_BIT
			if domain_list_ok(e, e.cos[id].src_off, hs) || e.cos[id].src_off == 0 { note_exception(e, &c, id) }
			if v & LAST_BIT != 0 { break }
			i += 1
		}
	}
	slice.sort(c.excepted[:])

	hiding :: proc(f: ^Cos_Filter) -> bool {
		return f.flags & {.Scriptlet, .Html, .Js_Raw} == {}
	}
	for id in specific {
		f := &e.cos[id]
		if .Exception in f.flags { continue }
		if is_excepted(&c, f.sel_hash) { continue }
		if .Scriptlet in f.flags && c.no_scriptlets { continue }
		if .Html in f.flags && c.no_html { continue }
		if hiding(f) && !c.specific_hide { continue }
		append(&c.active, id)
	}
	if e.hdr.cos_generic != NO_LIST {
		i := e.hdr.cos_generic
		for {
			v := e.cos_items[i]
			id := v & ~LAST_BIT
			f := &e.cos[id]
			ok := f.src_off == 0 || domain_list_ok(e, f.src_off, hs)
			if ok && !is_excepted(&c, f.sel_hash) {
				switch {
				case .Scriptlet in f.flags: ok = !c.no_scriptlets
				case .Html in f.flags: ok = !c.no_html
				case .Js_Raw in f.flags: ok = !c.no_scriptlets
				case: ok = c.generic_hide
				}
				if ok { append(&c.active, id) }
			}
			if v & LAST_BIT != 0 { break }
			i += 1
		}
	}
	return c
}

// The generic selectors that need the class / id `key` (class_key), applicable to the host.
cosmetic_keyed :: proc(e: ^Engine, c: ^Cosmetic, key: u32, out: ^[dynamic]u32) {
	if e == nil || !c.generic_hide || len(e.cos_key) == 0 { return }
	start, ok := multi_find(e.cos_key, key)
	if !ok { return }
	hs := c.hashes[:c.n_hashes]
	i := start
	for {
		v := e.cos_items[i]
		id := v & ~LAST_BIT
		f := &e.cos[id]
		if (f.src_off == 0 || domain_list_ok(e, f.src_off, hs)) && !is_excepted(c, f.sel_hash) { append(out, id) }
		if v & LAST_BIT != 0 { break }
		i += 1
	}
}

// Number of keyed generic selectors (for statistics).
cosmetic_keyed_count :: proc(e: ^Engine) -> int {
	n := 0
	for f in e.cos { if .Keyed in f.flags && .Exception not_in f.flags && f.src_off == 0 { n += 1 } }
	return n
}
