package adblock

import "core:strings"

// Filters that change a request instead of blocking it: `$removeparam` (rewrites the URL), `$csp` (adds a policy to the
// document's answer) and `$header` (blocks on a response header).

@(private)
collect_matches :: proc(e: ^Engine, class: Class, c: ^Ctx, out: ^[dynamic]u32) {
	if class_empty(e, class) { return }
	scan(e, class, c, Scan_Opts{collect = out})
}

// Applies the `$removeparam` filters that match the request. Returns the new URL (allocated with `allocator`) and
// whether anything was removed. Exceptions (`@@...$removeparam[=name]`) cancel the removal of that parameter.
rewrite_url :: proc(e: ^Engine, req: ^Request, allocator := context.allocator) -> (out: string, changed: bool) {
	if e == nil || class_empty(e, .Removeparam) { return req.url, false }
	url := req.url
	q := strings.index_byte(url, '?')
	if q < 0 { return url, false }
	frag := len(url)
	if h := strings.index_byte(url[q:], '#'); h >= 0 { frag = q + h }

	buf: [MAX_URL]u8
	c: Ctx
	ctx_init(&c, req, buf[:])
	if c.he <= c.hs { return url, false }
	found := make([dynamic]u32, 0, 4, context.temp_allocator)
	collect_matches(e, .Removeparam, &c, &found)
	if len(found) == 0 { return url, false }
	allow := make([dynamic]u32, 0, 4, context.temp_allocator)
	collect_matches(e, .Removeparam_Allow, &c, &allow)
	for a in allow { if cstr_at(e, e.filters[a].arg_off) == "" { return url, false } }

	query := url[q + 1:frag]
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, url[:q])
	kept := 0
	rest := query
	for len(rest) > 0 {
		amp := strings.index_byte(rest, '&')
		param: string
		if amp < 0 { param, rest = rest, "" } else { param, rest = rest[:amp], rest[amp + 1:] }
		if param == "" { continue }
		remove := false
		name := param
		if eq := strings.index_byte(param, '='); eq >= 0 { name = param[:eq] }
		for fid in found {
			arg := cstr_at(e, e.filters[fid].arg_off)
			if !removal_applies(e, fid, arg, name, param) { continue }
			cancelled := false
			for a in allow { if cstr_at(e, e.filters[a].arg_off) == arg { cancelled = true; break } }
			if !cancelled { remove = true; break }
		}
		if remove { changed = true; continue }
		strings.write_byte(&sb, kept == 0 ? '?' : '&')
		strings.write_string(&sb, param)
		kept += 1
	}
	if !changed { return url, false }
	strings.write_string(&sb, url[frag:])
	return strings.clone(strings.to_string(sb), allocator), true
}

@(private)
removal_applies :: proc(e: ^Engine, fid: u32, arg, name, param: string) -> bool {
	if arg == "" { return true }
	if len(arg) > 2 && arg[0] == '/' {
		// /regex/ or /regex/i, tried against "name=value"
		last := strings.last_index_byte(arg, '/')
		if last > 0 {
			icase := strings.contains(arg[last + 1:], "i")
			key := fid | 0x80000000
			re, ok := e.regex[key]
			if !ok {
				r, good := regex_compile(arg[1:last], icase)
				if good { re = new_clone(r, e.allocator) }
				e.regex[key] = re
			}
			return re != nil && regex_match(re, &e.scratch, param)
		}
	}
	return arg == name
}

// The policies to add to the answer of a document request (`$csp=`), minus the cancelled ones.
csp_directives :: proc(e: ^Engine, req: ^Request, allocator := context.allocator) -> []string {
	if e == nil || class_empty(e, .Csp) { return nil }
	buf: [MAX_URL]u8
	c: Ctx
	ctx_init(&c, req, buf[:])
	if c.he <= c.hs { return nil }
	found := make([dynamic]u32, 0, 4, context.temp_allocator)
	collect_matches(e, .Csp, &c, &found)
	if len(found) == 0 { return nil }
	allow := make([dynamic]u32, 0, 4, context.temp_allocator)
	collect_matches(e, .Csp_Allow, &c, &allow)
	out := make([dynamic]string, 0, len(found), allocator)
	for fid in found {
		arg := cstr_at(e, e.filters[fid].arg_off)
		cancelled := false
		for a in allow {
			aa := cstr_at(e, e.filters[a].arg_off)
			if aa == "" || aa == arg { cancelled = true; break }
		}
		if cancelled { continue }
		dup := false
		for s in out { if s == arg { dup = true; break } }
		if !dup { append(&out, arg) }
	}
	return out[:]
}

Header_Lookup :: #type proc(user: rawptr, name: string) -> (value: string, ok: bool)

// `$header=name[:value]` filters that match the request and its response headers: the deciding filter or NO_FILTER.
// `value` may be a plain string, `/regex/` or negated with `~`.
match_response_headers :: proc(e: ^Engine, req: ^Request, lookup: Header_Lookup, user: rawptr) -> u32 {
	if e == nil || class_empty(e, .Header) { return NO_FILTER }
	buf: [MAX_URL]u8
	c: Ctx
	ctx_init(&c, req, buf[:])
	if c.he <= c.hs { return NO_FILTER }
	found := make([dynamic]u32, 0, 4, context.temp_allocator)
	collect_matches(e, .Header, &c, &found)
	for fid in found {
		arg := cstr_at(e, e.filters[fid].arg_off)
		name, want := arg, ""
		has_value := false
		if i := strings.index_byte(arg, ':'); i >= 0 { name, want, has_value = arg[:i], arg[i + 1:], true }
		neg := strings.has_prefix(want, "~")
		if neg { want = want[1:] }
		val, ok := lookup(user, strings.to_lower(name, context.temp_allocator))
		hit := ok
		if ok && has_value {
			if len(want) > 2 && want[0] == '/' && want[len(want) - 1] == '/' {
				key := fid | 0x80000000
				re, cached := e.regex[key]
				if !cached {
					r, good := regex_compile(want[1:len(want) - 1], true)
					if good { re = new_clone(r, e.allocator) }
					e.regex[key] = re
				}
				hit = re != nil && regex_match(re, &e.scratch, val)
			} else {
				hit = strings.equal_fold(val, want) || strings.contains(strings.to_lower(val, context.temp_allocator), strings.to_lower(want, context.temp_allocator))
			}
			if neg { hit = !hit }
		}
		if !hit { continue }
		if !class_empty(e, .Header_Allow) {
			allow := make([dynamic]u32, 0, 2, context.temp_allocator)
			collect_matches(e, .Header_Allow, &c, &allow)
			if len(allow) > 0 { continue }
		}
		if !class_empty(e, .Allow) {
			x := scan(e, .Allow, &c, {stop_first = true})
			if x.any != NO_FILTER { continue }
		}
		return fid
	}
	return NO_FILTER
}
