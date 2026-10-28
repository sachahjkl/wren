// A standalone driver for the generic-ABI prototype (not a test_all step): it installs the URL domain on the host
// side, wires the guest bindings' `host_call` stub to the in-process dispatcher, and exercises the exact guest
// bindings end to end — the same code that compiles to wasm32 — checking the result against the native `wb:url`.
// Then it times a hot function over 1 M calls to measure what the serialised boundary costs per call.
//
//   odin run native/js/odin_abi/check -collection:wb=src -collection:toolkit=ext/gui_toolkit -out:build/abi_check.exe
package abi_check

import "core:fmt"
import "core:os"
import "core:time"
import "../abi"
import "../abi_guest"
import "../abi_host"
import "../abi_url"
import "../api_decl"
import "wb:url"

url_native_parse :: proc(s: string) -> (string, bool) {
	u, ok := url.parse(s)
	return u.href, ok
}

reg: abi_url.Registry

url_get :: proc(u: abi_guest.URL, c: abi_guest.URLComponent) -> string { s, _ := abi_guest.URL_get(u, c); return s }
params_tostring :: proc(p: abi_guest.URLSearchParams) -> string { s, _ := abi_guest.URLSearchParams_toString(p); return s }

fails: int

expect :: proc(cond: bool, what: string) {
	if !cond { fmt.eprintfln("FAIL: %s", what); fails += 1 }
}

main :: proc() {
	// Install the host side and point the guest stub at the in-process dispatcher.
	reg = abi_url.build_registry()
	_ = abi_host.install(&reg)
	abi_guest.install_host_call(abi_host.dispatch_native)
	defer abi_url.host_destroy()

	// Sanity: does the native parser work in this harness at all?
	if nu, nok := url_native_parse("https://example.com/x"); nok {
		fmt.printfln("native url.parse ok: href=%q", nu)
	} else {
		fmt.eprintln("native url.parse FAILED (lexbor shim not working in this build)")
	}

	round_trip()
	benchmark()

	if fails > 0 { os.exit(1) }
	fmt.println("abi_check: all round-trip checks passed")
}

round_trip :: proc() {
	// URL parsing and getters.
	u, err := abi_guest.URL_parse("https://user:pass@example.com:8080/a/b?x=1&y=2#frag", nil)
	expect(err == .None, "URL_parse ok")
	expect(url_get(u, .Protocol) == "https:", "URL protocol")
	expect(url_get(u, .Hostname) == "example.com", "URL hostname")
	expect(url_get(u, .Port) == "8080", "URL port")
	expect(url_get(u, .Pathname) == "/a/b", "URL pathname")
	expect(url_get(u, .Hash) == "#frag", "URL hash")

	// Relative resolution against a base (optional argument present).
	u2, err2 := abi_guest.URL_parse("../c", "https://example.com/a/b")
	expect(err2 == .None, "URL_parse relative ok")
	expect(url_get(u2, .Pathname) == "/c", "URL relative pathname")

	// An invalid URL raises Type.
	_, err3 := abi_guest.URL_parse("http://", nil)
	expect(err3 == .Type, "URL_parse invalid raises Type")

	// canParse.
	expect(abi_guest.URL_canParse("https://example.com", nil), "canParse valid")
	expect(!abi_guest.URL_canParse("::::", nil), "canParse invalid")

	// URLSearchParams: create, append, get, has, size, toString, delete, sort.
	sp, _ := abi_guest.URLSearchParams_create("a=1&b=2")
	expect(abi_guest.URLSearchParams_size(sp) == 2, "params size")
	abi_guest.URLSearchParams_append(sp, "c", "3")
	expect(abi_guest.URLSearchParams_size(sp) == 3, "params size after append")
	got, gerr := abi_guest.URLSearchParams_get(sp, "b")
	expect(gerr == .None && got == "2", "params get b")
	expect(abi_guest.URLSearchParams_has(sp, "c", nil), "params has c")
	_, nerr := abi_guest.URLSearchParams_get(sp, "zzz")
	expect(nerr == .Not_Found, "params get missing raises Not_Found")
	abi_guest.URLSearchParams_set(sp, "a", "9")
	a9, _ := abi_guest.URLSearchParams_get(sp, "a")
	expect(a9 == "9", "params set a")
	abi_guest.URLSearchParams_delete(sp, "b", nil)
	expect(!abi_guest.URLSearchParams_has(sp, "b", nil), "params delete b")
	abi_guest.URLSearchParams_sort(sp)
	s := params_tostring(sp)
	expect(s == "a=9&c=3", fmt.tprintf("params toString after sort (got %q)", s))

	// url.searchParams is linked both ways (a borrowed handle).
	sp2 := abi_guest.URL_searchParams(u)
	expect(abi_guest.URLSearchParams_size(sp2) == 2, "url.searchParams size")
	v, _ := abi_guest.URLSearchParams_get(sp2, "x")
	expect(v == "1", "url.searchParams get x")

	// URLPattern: a dictionary-argument constructor (the manual escape hatch), getters, test().
	init := abi_guest.URLPatternInit{pathname = "/books/:id", has_pathname = true}
	pat, perr := abi_guest.URLPattern_create(init)
	expect(perr == .None, "URLPattern_create ok")
	expect(abi_guest.URLPattern_component(pat, .Pathname) == "/books/:id", "URLPattern pathname component")
	expect(abi_guest.URLPattern_test(pat, "https://example.com/books/123", nil), "URLPattern test match")
	expect(!abi_guest.URLPattern_test(pat, "https://example.com/music/1", nil), "URLPattern test no-match")
	ci := abi_guest.URLPatternInit{pathname = "/A/*", has_pathname = true, ignore_case = true}
	cpat, _ := abi_guest.URLPattern_create(ci)
	expect(abi_guest.URLPattern_test(cpat, "https://x.org/a/b", nil), "URLPattern ignoreCase (a dictionary bool after the strings)")

	// the reads the JS binding's getAll and iterators use
	gp, _ := abi_guest.URLSearchParams_create("k=1&x=2&k=3")
	expect(abi_guest.URLSearchParams_count(gp, "k") == 2, "params count")
	k1, k1e := abi_guest.URLSearchParams_getNth(gp, "k", 1)
	expect(k1e == .None && k1 == "3", "params getNth")
	_, k2e := abi_guest.URLSearchParams_getNth(gp, "k", 2)
	expect(k2e == .Not_Found, "params getNth past the end raises Not_Found")
	n1, _ := abi_guest.URLSearchParams_nameAt(gp, 1)
	expect(n1 == "x", "params nameAt")   // (a string result lives in the result buffer until the next call)
	v1, _ := abi_guest.URLSearchParams_valueAt(gp, 1)
	expect(v1 == "2", "params valueAt")

	abi_shapes()
}

// Every shape the serialised bridge carries, through the boundary's own conformance functions (api_decl/abitest).
abi_shapes :: proc() {
	u, _ := abi_guest.URL_parse("https://example.com/", nil)
	want := abi_url.abi_mix8_expected(-7, 1 << 40, 2.5, true, .Pathname, "héllo", "opt", u)
	got := abi_guest.Abi_Mix8(-7, 1 << 40, 2.5, true, .Pathname, "héllo", "opt", u)
	expect(got == want, fmt.tprintf("Mix8: eight arguments of every scalar and span shape (got %d, want %d)", got, want))
	want2 := abi_url.abi_mix8_expected(1, 2, 3, false, .Href, "", nil, u)
	expect(abi_guest.Abi_Mix8(1, 2, 3, false, .Href, "", nil, u) == want2, "Mix8 with an absent optional and an empty string")

	expect(abi_guest.Abi_Sum([]i64{1, 2, 3, 1 << 33}) == 6 + (1 << 33), "Sum: a slice argument")
	expect(abi_guest.Abi_Sum(nil) == 0, "Sum: an empty slice")
	parts := abi_guest.Abi_Split("a,bc,,d")
	expect(len(parts) == 4 && parts[0] == "a" && parts[1] == "bc" && parts[2] == "" && parts[3] == "d", "Split: a slice result of strings")

	expect(abi_guest.Abi_Opt(21) == 42, "Opt: a present optional scalar")
	expect(abi_guest.Abi_Opt(nil) == -1, "Opt: an absent optional scalar")
	f, fok := abi_guest.Abi_Find("present").?
	expect(fok && f == "found it", "Find: a present optional string result")
	_, nok := abi_guest.Abi_Find("absent").?
	expect(!nok, "Find: an absent optional string result")

	owned, merr := abi_guest.Abi_Make("https://owned.example/p")
	expect(merr == .None && url_get(owned.handle, .Hostname) == "owned.example", "Make: an Owned handle result")
	_, berr := abi_guest.Abi_Make("not a url")
	expect(berr == .Type, "Make: the error of a (value, error) result")

	d := api_decl.Abi_Dict{name = "dict", count = 41, ratio = 1.25, flag = true, tag = "t", ids = []i32{5, 6}, kind = .Search}
	e, eerr := abi_guest.Abi_Echo(d)
	expect(eerr == .None && e.name == "dict!" && e.count == 42 && e.ratio == 2.5 && !e.flag, "Echo: a dictionary of strings and scalars, both ways")
	etag, etok := e.tag.?
	expect(etok && etag == "t" && e.kind == .Search, "Echo: a dictionary's optional string and enum")
	expect(len(e.ids) == 3 && e.ids[0] == 5 && e.ids[1] == 6 && e.ids[2] == 2, "Echo: a dictionary's slice")
	d.tag = nil
	e2, _ := abi_guest.Abi_Echo(d)
	_, has_tag := e2.tag.?
	expect(!has_tag, "Echo: a dictionary's absent optional")
	d.count = -1
	_, rerr := abi_guest.Abi_Echo(d)
	expect(rerr == .Range, "Echo: a raised error")
}

// The cost of one serialised call: a getter with a handle + enum argument and a string result (URL_get), over 1 M
// calls. Prints ns/call. (Measured in-process here; the Wasm figure comes from the wasmbench extension.)
benchmark :: proc() {
	u, _ := abi_guest.URL_parse("https://example.com/path?q=1", nil)
	N :: 1_000_000
	t0 := time.tick_now()
	acc := 0
	for _ in 0 ..< N {
		s := url_get(u, .Pathname)
		acc += len(s)
	}
	d := time.duration_nanoseconds(time.tick_since(t0))
	fmt.printfln("serialised URL_get: %.1f ns/call (in-process, %d calls, acc=%d)", f64(d) / f64(N), N, acc)

	// A pure scalar getter (handle in, i32 out): the cheapest serialised shape.
	sp, _ := abi_guest.URLSearchParams_create("a=1&b=2&c=3")
	t1 := time.tick_now()
	sum: i64
	for _ in 0 ..< N { sum += i64(abi_guest.URLSearchParams_size(sp)) }
	d1 := time.duration_nanoseconds(time.tick_since(t1))
	fmt.printfln("serialised URLSearchParams_size: %.1f ns/call (in-process, %d calls, sum=%d)", f64(d1) / f64(N), N, sum)

	_ = abi.ABSENT
}
