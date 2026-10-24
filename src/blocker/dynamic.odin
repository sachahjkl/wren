package blocker

import "core:fmt"
import "core:slice"
import "core:strings"
import "wb:adblock"
import "wb:fetch"
import "wb:i18n"

// Dynamic rules: the matrix of the panel. A rule says what to do with the requests that a source (a site, or `*` for all)
// makes to a destination (a host and its subdomains, or `*`) of a kind. They are evaluated before the filter lists and
// win over them: `allow` lets the request through without the lists being asked, `block` stops it, `noop` (no rule)
// leaves the decision to the lists.
//
// Among several rules the most specific wins: first by destination (the host itself before its parent domains, then
// `*`), then by kind (script from a third party before script before third-party before all), then by source (the page's
// host before its parent domains, then `*`).

Dyn_Type :: enum u8 { All, First_Party, Third_Party, Script, Script_1p, Script_3p, Frame, Frame_3p, Image, Css, Media, Font, Xhr, Other }
Dyn_Action :: enum u8 { Noop, Allow, Block }
Dyn_Result :: enum u8 { Noop, Allow, Block }

DYN_TYPE_NAMES := [Dyn_Type]string{
	.All = "*", .First_Party = "1p", .Third_Party = "3p", .Script = "script", .Script_1p = "1p-script", .Script_3p = "3p-script",
	.Frame = "frame", .Frame_3p = "3p-frame", .Image = "image", .Css = "css", .Media = "media", .Font = "font", .Xhr = "xhr", .Other = "other",
}

Dyn_Rule :: struct {
	src, dst: string,     // owned
	type:     Dyn_Type,
	action:   Dyn_Action,
}

Dyn_Rules :: struct {
	rules:   [dynamic]Dyn_Rule,
	index:   map[u64]Dyn_Action,
	src_set: map[u32]int,
	dst_set: map[u32]int,
	version: u64,
}

dyn_active :: #force_inline proc(d: ^Dyn_Rules) -> bool { return len(d.rules) > 0 }

dyn_destroy :: proc(d: ^Dyn_Rules) {
	for r in d.rules { delete(r.src); delete(r.dst) }
	delete(d.rules); delete(d.index); delete(d.src_set); delete(d.dst_set)
	d^ = {}
}

@(private)
dyn_key :: #force_inline proc "contextless" (src, dst: u32, t: Dyn_Type) -> u64 {
	return u64(src) << 32 ~ u64(dst) * 0x9E3779B97F4A7C15 ~ u64(t) * 0x100000001B3
}

dyn_type_from_name :: proc(s: string) -> (Dyn_Type, bool) {
	for n, t in DYN_TYPE_NAMES { if n == s { return t, true } }
	return .All, false
}

// Sets (or, with Noop, removes) a rule. `src` and `dst` are lower-case hosts or "*".
dyn_set :: proc(d: ^Dyn_Rules, src, dst: string, t: Dyn_Type, action: Dyn_Action) {
	if d.index == nil { d.index = make(map[u64]Dyn_Action) }
	sh, dh := adblock.hash_str(src), adblock.hash_str(dst)
	key := dyn_key(sh, dh, t)
	for &r, i in d.rules {
		if r.src == src && r.dst == dst && r.type == t {
			if action == .Noop {
				delete(r.src); delete(r.dst)
				ordered_remove(&d.rules, i)
				delete_key(&d.index, key)
			} else { r.action = action; d.index[key] = action }
			dyn_rebuild_sets(d)
			d.version += 1
			return
		}
	}
	if action == .Noop { return }
	append(&d.rules, Dyn_Rule{strings.clone(src), strings.clone(dst), t, action})
	d.index[key] = action
	dyn_rebuild_sets(d)
	d.version += 1
}

dyn_get :: proc(d: ^Dyn_Rules, src, dst: string, t: Dyn_Type) -> Dyn_Action {
	if a, ok := d.index[dyn_key(adblock.hash_str(src), adblock.hash_str(dst), t)]; ok { return a }
	return .Noop
}

@(private)
dyn_rebuild_sets :: proc(d: ^Dyn_Rules) {
	clear(&d.src_set); clear(&d.dst_set)
	if d.index == nil { d.index = make(map[u64]Dyn_Action) }
	if d.src_set == nil { d.src_set = make(map[u32]int) }
	if d.dst_set == nil { d.dst_set = make(map[u32]int) }
	for r in d.rules {
		d.src_set[adblock.hash_str(r.src)] += 1
		d.dst_set[adblock.hash_str(r.dst)] += 1
	}
}

dyn_clear :: proc(d: ^Dyn_Rules) {
	for r in d.rules { delete(r.src); delete(r.dst) }
	clear(&d.rules); clear(&d.index); clear(&d.src_set); clear(&d.dst_set)
	d.version += 1
}

// Rules sorted for display: by source, destination, kind.
dyn_sorted :: proc(d: ^Dyn_Rules, allocator := context.temp_allocator) -> []Dyn_Rule {
	out := make([]Dyn_Rule, len(d.rules), allocator)
	copy(out, d.rules[:])
	slice.sort_by(out, proc(a, b: Dyn_Rule) -> bool {
		if a.src != b.src { return a.src == "*" || (b.src != "*" && a.src < b.src) }
		if a.dst != b.dst { return a.dst == "*" || (b.dst != "*" && a.dst < b.dst) }
		return a.type < b.type
	})
	return out
}

@(private)
Hash_List :: struct { h: [16]u32, s: [16]string, n: int }

// "a.b.c" -> a.b.c, b.c, c, *
@(private)
host_candidates :: proc(host: string, out: ^Hash_List) {
	h := host
	for h != "" && out.n < 15 {
		out.h[out.n], out.s[out.n] = adblock.hash_str(h), h
		out.n += 1
		d := strings.index_byte(h, '.')
		if d < 0 { break }
		h = h[d + 1:]
	}
	out.h[out.n], out.s[out.n] = adblock.hash_str("*"), "*"
	out.n += 1
}

// The kinds a request can be matched by, most specific first.
@(private)
kind_candidates :: proc(type: adblock.Resource, third_party: bool, out: ^[5]Dyn_Type) -> int {
	n := 0
	#partial switch type {
	case .Script: out[n] = third_party ? .Script_3p : .Script_1p; n += 1; out[n] = .Script; n += 1
	case .Subdocument: if third_party { out[n] = .Frame_3p; n += 1 }; out[n] = .Frame; n += 1
	case .Image: out[n] = .Image; n += 1
	case .Stylesheet: out[n] = .Css; n += 1
	case .Media: out[n] = .Media; n += 1
	case .Font: out[n] = .Font; n += 1
	case .Xhr, .Websocket, .Ping: out[n] = .Xhr; n += 1
	case: out[n] = .Other; n += 1
	}
	out[n] = third_party ? .Third_Party : .First_Party; n += 1
	out[n] = .All; n += 1
	return n
}

dyn_eval :: proc(d: ^Dyn_Rules, src_host, dst_host: string, type: adblock.Resource, third_party: bool, dest: fetch.Destination) -> (Dyn_Result, string) {
	src, dst: Hash_List
	host_candidates(src_host, &src)
	host_candidates(dst_host, &dst)
	kinds: [5]Dyn_Type
	nk := kind_candidates(type, third_party, &kinds)
	for di in 0 ..< dst.n {
		if _, ok := d.dst_set[dst.h[di]]; !ok { continue }
		for ki in 0 ..< nk {
			for si in 0 ..< src.n {
				if _, ok := d.src_set[src.h[si]]; !ok { continue }
				if a, ok := d.index[dyn_key(src.h[si], dst.h[di], kinds[ki])]; ok && a != .Noop {
					note := fmt.tprintf(i18n.tr("rule source, destination, kind, action", "dynamic rule: %s %s %s %s"), src.s[si], dst.s[di], DYN_TYPE_NAMES[kinds[ki]], a == .Block ? i18n.tr("rule action", "block") : i18n.tr("rule action", "allow"))
					return a == .Block ? .Block : .Allow, note
				}
			}
		}
	}
	return .Noop, ""
}
