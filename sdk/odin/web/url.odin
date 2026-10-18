package web

// URL and URLSearchParams (import module "url"). Release both with Object_release.

foreign import url_mod "url"

Url_Component :: enum i32 { Href, Protocol, Username, Password, Host, Hostname, Port, Pathname, Search, Hash, Origin }

@(default_calling_convention = "contextless")
foreign url_mod {
	@(link_name = "URL_parse") raw_urlParse :: proc(input: [^]u8, il: i32, base: [^]u8, bl: i32, has_base: i32) -> Handle ---
	@(link_name = "URL_canParse") raw_urlCanParse :: proc(input: [^]u8, il: i32, base: [^]u8, bl: i32, has_base: i32) -> i32 ---
	@(link_name = "URL_get") raw_urlGet :: proc(u: Handle, c: Url_Component, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "URL_set") raw_urlSet :: proc(u: Handle, c: Url_Component, value: [^]u8, vl: i32) -> i32 ---
	URL_searchParams :: proc(u: Handle) -> Handle ---
	@(link_name = "URLSearchParams_create") raw_paramsCreate :: proc(init: [^]u8, n: i32) -> Handle ---
	URLSearchParams_size :: proc(p: Handle) -> i32 ---
	@(link_name = "URLSearchParams_append") raw_paramsAppend :: proc(p: Handle, name: [^]u8, nl: i32, value: [^]u8, vl: i32) -> i32 ---
	@(link_name = "URLSearchParams_delete") raw_paramsDelete :: proc(p: Handle, name: [^]u8, nl: i32, value: [^]u8, vl: i32, has_value: i32) -> i32 ---
	@(link_name = "URLSearchParams_get") raw_paramsGet :: proc(p: Handle, name: [^]u8, nl: i32, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "URLSearchParams_count") raw_paramsCount :: proc(p: Handle, name: [^]u8, nl: i32) -> i32 ---
	@(link_name = "URLSearchParams_getNth") raw_paramsGetNth :: proc(p: Handle, name: [^]u8, nl: i32, n: i32, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "URLSearchParams_has") raw_paramsHas :: proc(p: Handle, name: [^]u8, nl: i32, value: [^]u8, vl: i32, has_value: i32) -> i32 ---
	@(link_name = "URLSearchParams_set") raw_paramsSet :: proc(p: Handle, name: [^]u8, nl: i32, value: [^]u8, vl: i32) -> i32 ---
	URLSearchParams_sort :: proc(p: Handle) -> i32 ---
	@(link_name = "URLSearchParams_toString") raw_paramsToString :: proc(p: Handle, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "URLSearchParams_nameAt") raw_paramsNameAt :: proc(p: Handle, index: i32, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "URLSearchParams_valueAt") raw_paramsValueAt :: proc(p: Handle, index: i32, buf: [^]u8, cap: i32) -> i32 ---
}

@(private)
fit :: proc "contextless" (buf: []u8, n: i32) -> string { return string(buf[:min(int(max(n, 0)), len(buf))]) }

// new URL(input[, base]); 0 for a TypeError.
url_parse :: proc "contextless" (input: string, base: string = "", has_base := false) -> Handle {
	return raw_urlParse(raw_data(input), i32(len(input)), raw_data(base), i32(len(base)), has_base ? 1 : 0)
}

url_can_parse :: proc "contextless" (input: string, base: string = "", has_base := false) -> bool {
	return raw_urlCanParse(raw_data(input), i32(len(input)), raw_data(base), i32(len(base)), has_base ? 1 : 0) == 1
}

url_get :: proc "contextless" (u: Handle, c: Url_Component, buf: []u8) -> string { return fit(buf, raw_urlGet(u, c, raw_data(buf), i32(len(buf)))) }

url_set :: proc "contextless" (u: Handle, c: Url_Component, value: string) -> i32 { return raw_urlSet(u, c, raw_data(value), i32(len(value))) }

search_params :: proc "contextless" (init: string) -> Handle { return raw_paramsCreate(raw_data(init), i32(len(init))) }

params_append :: proc "contextless" (p: Handle, name, value: string) -> i32 {
	return raw_paramsAppend(p, raw_data(name), i32(len(name)), raw_data(value), i32(len(value)))
}
params_set :: proc "contextless" (p: Handle, name, value: string) -> i32 {
	return raw_paramsSet(p, raw_data(name), i32(len(name)), raw_data(value), i32(len(value)))
}
params_delete :: proc "contextless" (p: Handle, name: string, value: string = "", has_value := false) -> i32 {
	return raw_paramsDelete(p, raw_data(name), i32(len(name)), raw_data(value), i32(len(value)), has_value ? 1 : 0)
}
params_has :: proc "contextless" (p: Handle, name: string, value: string = "", has_value := false) -> bool {
	return raw_paramsHas(p, raw_data(name), i32(len(name)), raw_data(value), i32(len(value)), has_value ? 1 : 0) == 1
}
params_get :: proc "contextless" (p: Handle, name: string, buf: []u8) -> (string, bool) {
	n := raw_paramsGet(p, raw_data(name), i32(len(name)), raw_data(buf), i32(len(buf)))
	if n < 0 { return "", false }
	return fit(buf, n), true
}
params_get_all_count :: proc "contextless" (p: Handle, name: string) -> int { return int(raw_paramsCount(p, raw_data(name), i32(len(name)))) }
params_get_nth :: proc "contextless" (p: Handle, name: string, n: int, buf: []u8) -> (string, bool) {
	r := raw_paramsGetNth(p, raw_data(name), i32(len(name)), i32(n), raw_data(buf), i32(len(buf)))
	if r < 0 { return "", false }
	return fit(buf, r), true
}
params_to_string :: proc "contextless" (p: Handle, buf: []u8) -> string { return fit(buf, raw_paramsToString(p, raw_data(buf), i32(len(buf)))) }
params_name_at :: proc "contextless" (p: Handle, i: int, buf: []u8) -> string { return fit(buf, raw_paramsNameAt(p, i32(i), raw_data(buf), i32(len(buf)))) }
params_value_at :: proc "contextless" (p: Handle, i: int, buf: []u8) -> string { return fit(buf, raw_paramsValueAt(p, i32(i), raw_data(buf), i32(len(buf)))) }
