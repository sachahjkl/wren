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
import "wb:url"

url_native_parse :: proc(s: string) -> (string, bool) {
	u, ok := url.parse(s)
	return u.href, ok
}

reg: abi_url.Registry

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
	u, err := abi_guest.URL_parse("https://user:pass@example.com:8080/a/b?x=1&y=2#frag")
	expect(err == .None, "URL_parse ok")
	expect(abi_guest.URL_get(u, .Protocol) == "https:", "URL protocol")
	expect(abi_guest.URL_get(u, .Hostname) == "example.com", "URL hostname")
	expect(abi_guest.URL_get(u, .Port) == "8080", "URL port")
	expect(abi_guest.URL_get(u, .Pathname) == "/a/b", "URL pathname")
	expect(abi_guest.URL_get(u, .Hash) == "#frag", "URL hash")

	// Relative resolution against a base (optional argument present).
	u2, err2 := abi_guest.URL_parse("../c", "https://example.com/a/b")
	expect(err2 == .None, "URL_parse relative ok")
	expect(abi_guest.URL_get(u2, .Pathname) == "/c", "URL relative pathname")

	// An invalid URL raises Type.
	_, err3 := abi_guest.URL_parse("http://")
	expect(err3 == .Type, "URL_parse invalid raises Type")

	// canParse.
	expect(abi_guest.URL_canParse("https://example.com"), "canParse valid")
	expect(!abi_guest.URL_canParse("::::"), "canParse invalid")

	// URLSearchParams: create, append, get, has, size, toString, delete, sort.
	sp, _ := abi_guest.URLSearchParams_create("a=1&b=2")
	expect(abi_guest.URLSearchParams_size(sp) == 2, "params size")
	abi_guest.URLSearchParams_append(sp, "c", "3")
	expect(abi_guest.URLSearchParams_size(sp) == 3, "params size after append")
	got, gerr := abi_guest.URLSearchParams_get(sp, "b")
	expect(gerr == .None && got == "2", "params get b")
	expect(abi_guest.URLSearchParams_has(sp, "c"), "params has c")
	_, nerr := abi_guest.URLSearchParams_get(sp, "zzz")
	expect(nerr == .Not_Found, "params get missing raises Not_Found")
	abi_guest.URLSearchParams_set(sp, "a", "9")
	a9, _ := abi_guest.URLSearchParams_get(sp, "a")
	expect(a9 == "9", "params set a")
	abi_guest.URLSearchParams_delete(sp, "b")
	expect(!abi_guest.URLSearchParams_has(sp, "b"), "params delete b")
	abi_guest.URLSearchParams_sort(sp)
	s := abi_guest.URLSearchParams_toString(sp)
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
	expect(abi_guest.URLPattern_test(pat, "https://example.com/books/123"), "URLPattern test match")
	expect(!abi_guest.URLPattern_test(pat, "https://example.com/music/1"), "URLPattern test no-match")
}

// The cost of one serialised call: a getter with a handle + enum argument and a string result (URL_get), over 1 M
// calls. Prints ns/call. (Measured in-process here; the Wasm figure comes from the wasmbench extension.)
benchmark :: proc() {
	u, _ := abi_guest.URL_parse("https://example.com/path?q=1")
	N :: 1_000_000
	t0 := time.tick_now()
	acc := 0
	for _ in 0 ..< N {
		s := abi_guest.URL_get(u, .Pathname)
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
