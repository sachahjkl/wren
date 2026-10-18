package url

// URLSearchParams: the application/x-www-form-urlencoded parser and serializer of the URL Standard, and the list
// operations of the URLSearchParams interface. Pure code, no Lexbor.

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

Search_Param :: struct {
	name:  string,   // owned
	value: string,   // owned
}

Search_Params :: struct {
	list:      [dynamic]Search_Param,
	allocator: runtime.Allocator,
}

params_make :: proc(allocator := context.allocator) -> Search_Params {
	return Search_Params{list = make([dynamic]Search_Param, allocator), allocator = allocator}
}

params_destroy :: proc(sp: ^Search_Params) {
	for p in sp.list { delete(p.name, sp.allocator); delete(p.value, sp.allocator) }
	delete(sp.list)
	sp^ = {}
}

params_clear :: proc(sp: ^Search_Params) {
	for p in sp.list { delete(p.name, sp.allocator); delete(p.value, sp.allocator) }
	clear(&sp.list)
}

// application/x-www-form-urlencoded parsing: replaces the list. A leading "?" is the caller's business (the
// URLSearchParams constructor strips it, a URL's query never has it).
params_parse :: proc(sp: ^Search_Params, input: string) {
	if sp.allocator.procedure == nil { sp.allocator = context.allocator }
	params_clear(sp)
	rest := input
	for seq in strings.split_iterator(&rest, "&") {
		if seq == "" { continue }
		name, value := seq, ""
		if eq := strings.index_byte(seq, '='); eq >= 0 { name, value = seq[:eq], seq[eq + 1:] }
		append(&sp.list, Search_Param{form_decode(name, sp.allocator), form_decode(value, sp.allocator)})
	}
}

// '+' is a space, then percent-decoding, then UTF-8 decoding without BOM (invalid bytes become U+FFFD).
@(private)
form_decode :: proc(s: string, allocator: runtime.Allocator) -> string {
	bytes := make([dynamic]byte, 0, len(s), context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c == '+':
			append(&bytes, ' ')
		case c == '%' && i + 2 < len(s) && is_hex(s[i + 1]) && is_hex(s[i + 2]):
			append(&bytes, hex_val(s[i + 1]) << 4 | hex_val(s[i + 2]))
			i += 2
		case:
			append(&bytes, c)
		}
	}
	return utf8_decode(bytes[:], allocator)
}

@(private)
is_hex :: proc(c: u8) -> bool { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }

@(private)
hex_val :: proc(c: u8) -> u8 {
	switch c {
	case '0' ..= '9': return c - '0'
	case 'a' ..= 'f': return c - 'a' + 10
	case 'A' ..= 'F': return c - 'A' + 10
	}
	return 0
}

// The Encoding Standard's UTF-8 decoder (replacement mode, BOM kept): each maximal invalid subpart is one U+FFFD.
utf8_decode :: proc(b: []byte, allocator := context.allocator) -> string {
	out := strings.builder_make(0, len(b), allocator)
	i := 0
	for i < len(b) {
		c := b[i]
		if c < 0x80 { strings.write_byte(&out, c); i += 1; continue }
		need := 0
		lower, upper := u8(0x80), u8(0xBF)
		cp: rune
		switch c {
		case 0xC2 ..= 0xDF: need, cp = 1, rune(c & 0x1F)
		case 0xE0 ..= 0xEF:
			need, cp = 2, rune(c & 0x0F)
			if c == 0xE0 { lower = 0xA0 }
			if c == 0xED { upper = 0x9F }
		case 0xF0 ..= 0xF4:
			need, cp = 3, rune(c & 0x07)
			if c == 0xF0 { lower = 0x90 }
			if c == 0xF4 { upper = 0x8F }
		case:
			strings.write_rune(&out, 0xFFFD); i += 1; continue
		}
		j := i + 1
		ok := true
		for _ in 0 ..< need {
			if j >= len(b) || b[j] < lower || b[j] > upper { ok = false; break }
			cp = cp << 6 | rune(b[j] & 0x3F)
			j += 1
			lower, upper = 0x80, 0xBF
		}
		if !ok { strings.write_rune(&out, 0xFFFD); i = j; continue }
		strings.write_rune(&out, cp)
		i = j
	}
	return strings.to_string(out)
}

// application/x-www-form-urlencoded serializing: only ASCII alphanumerics and *-._ stay as they are, space is '+'.
params_serialize :: proc(sp: Search_Params, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for p, i in sp.list {
		if i > 0 { strings.write_byte(&b, '&') }
		form_encode(&b, p.name)
		strings.write_byte(&b, '=')
		form_encode(&b, p.value)
	}
	return strings.to_string(b)
}

@(private)
form_encode :: proc(b: ^strings.Builder, s: string) {
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c == ' ': strings.write_byte(b, '+')
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '*' || c == '-' || c == '.' || c == '_':
			strings.write_byte(b, c)
		case:
			strings.write_byte(b, '%'); strings.write_byte(b, HEX[c >> 4]); strings.write_byte(b, HEX[c & 15])
		}
	}
}

params_append :: proc(sp: ^Search_Params, name, value: string) {
	if sp.allocator.procedure == nil { sp.allocator = context.allocator }
	append(&sp.list, Search_Param{strings.clone(name, sp.allocator), strings.clone(value, sp.allocator)})
}

// delete(name) or delete(name, value): every matching pair. Returns how many were removed.
params_delete :: proc(sp: ^Search_Params, name: string, value: string = "", match_value := false) -> int {
	w, removed := 0, 0
	for p in sp.list {
		if p.name == name && (!match_value || p.value == value) {
			delete(p.name, sp.allocator); delete(p.value, sp.allocator)
			removed += 1
			continue
		}
		sp.list[w] = p
		w += 1
	}
	resize(&sp.list, w)
	return removed
}

params_get :: proc(sp: Search_Params, name: string) -> (string, bool) {
	for p in sp.list { if p.name == name { return p.value, true } }
	return "", false
}

// The n-th value of `name` (getAll, one at a time).
params_get_nth :: proc(sp: Search_Params, name: string, n: int) -> (string, bool) {
	k := 0
	for p in sp.list {
		if p.name != name { continue }
		if k == n { return p.value, true }
		k += 1
	}
	return "", false
}

params_count :: proc(sp: Search_Params, name: string) -> int {
	k := 0
	for p in sp.list { if p.name == name { k += 1 } }
	return k
}

params_has :: proc(sp: Search_Params, name: string, value: string = "", match_value := false) -> bool {
	for p in sp.list { if p.name == name && (!match_value || p.value == value) { return true } }
	return false
}

// set(name, value): the first pair named `name` gets the value, the others are removed; appended when there is none.
params_set :: proc(sp: ^Search_Params, name, value: string) {
	found := false
	w := 0
	for p in sp.list {
		if p.name == name {
			if found { delete(p.name, sp.allocator); delete(p.value, sp.allocator); continue }
			found = true
			q := p
			delete(q.value, sp.allocator)
			q.value = strings.clone(value, sp.allocator)
			sp.list[w] = q
			w += 1
			continue
		}
		sp.list[w] = p
		w += 1
	}
	resize(&sp.list, w)
	if !found { params_append(sp, name, value) }
}

// Stable sort by name, comparing UTF-16 code units as the standard requires (so U+10000 sorts before U+E000).
params_sort :: proc(sp: ^Search_Params) {
	slice.stable_sort_by(sp.list[:], proc(a, b: Search_Param) -> bool { return utf16_less(a.name, b.name) })
}

// a < b in UTF-16 code unit order.
utf16_less :: proc(a, b: string) -> bool {
	ua, ub := a, b
	ia, ib := 0, 0
	pend_a, pend_b: u16   // second unit of a surrogate pair, 0 = none
	for {
		ca, ok_a := next_unit(ua, &ia, &pend_a)
		cb, ok_b := next_unit(ub, &ib, &pend_b)
		if !ok_a || !ok_b { return !ok_a && ok_b }
		if ca != cb { return ca < cb }
	}
}

@(private)
next_unit :: proc(s: string, i: ^int, pending: ^u16) -> (u16, bool) {
	if pending^ != 0 { u := pending^; pending^ = 0; return u, true }
	if i^ >= len(s) { return 0, false }
	r, w := decode_rune_at(s, i^)
	i^ += w
	if r >= 0x10000 {
		v := u32(r) - 0x10000
		pending^ = u16(0xDC00 + (v & 0x3FF))
		return u16(0xD800 + (v >> 10)), true
	}
	return u16(r), true
}

@(private)
decode_rune_at :: proc(s: string, i: int) -> (rune, int) {
	r, w := utf8.decode_rune_in_string(s[i:])
	return r, max(w, 1)
}
