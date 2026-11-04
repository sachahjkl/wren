package page

import "core:testing"
import "wb:base"
import "wb:fetch"
import "wb:host"

// The text of a fetched classic script: its charset attribute's encoding when nothing else says one, the Content-Type's
// charset before it, a byte order mark before both; ASCII as it came.
@(test)
classic_script_decoding :: proc(t: ^testing.T) {
	test_pages(t)
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	settings := settings_default()
	defer settings_destroy(&settings)
	loader: fetch.Loader
	scope := base.scope_make("test")
	defer base.scope_close(scope)
	p := page_create(&loop, &loader, &settings, scope, "http://127.0.0.1:8765/t.html")
	defer page_close(p)
	text :: proc(p: ^Page, bytes: string, header, attribute: string) -> string {
		f := Script_Fetch{charset = header}
		append(&f.bytes, ..transmute([]byte)bytes)
		defer delete(f.bytes)
		sc := Page_Script{charset = attribute}
		script_decode(p, &sc, &f)
		out := string(sc.source[:])
		defer delete(sc.source)
		return clone_temp(out)
	}
	clone_temp :: proc(s: string) -> string { b := make([]byte, len(s), context.temp_allocator); copy(b, s); return string(b) }
	testing.expect_value(t, text(p, "s='\x9c'", "", "windows-1250"), "s='ś'")   // ś in windows-1250
	testing.expect_value(t, text(p, "s='ś'", "utf-8", "windows-1250"), "s='ś'")
	testing.expect_value(t, text(p, "\xef\xbb\xbfs='ś'", "windows-1250", ""), "s='ś'")
	testing.expect_value(t, text(p, "s=1", "", "windows-1250"), "s=1")
}

// Subresource Integrity: base64 or base64url, the padding optional; the strongest algorithm decides; unknown
// algorithms allow anything; an opaque response matches nothing.
@(test)
integrity_metadata :: proc(t: ^testing.T) {
	ABC_SHA256 :: "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0="
	ABC_SHA256_URL :: "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"
	abc := transmute([]byte)string("abc")
	testing.expect(t, integrity_ok(nil, "sha256-" + ABC_SHA256, abc, false), "base64")
	testing.expect(t, integrity_ok(nil, "sha256-" + ABC_SHA256_URL, abc, false), "base64url without padding")
	testing.expect(t, !integrity_ok(nil, "sha256-" + ABC_SHA256, transmute([]byte)string("abd"), false), "another body")
	testing.expect(t, !integrity_ok(nil, "sha256-" + ABC_SHA256 + " sha512-AAAA", abc, false), "a stronger hash that does not match decides")
	testing.expect(t, integrity_ok(nil, "md5-AAAA", abc, false), "no algorithm known: anything")
	testing.expect(t, !integrity_ok(nil, "sha256-" + ABC_SHA256, abc, true), "an opaque response")
}
