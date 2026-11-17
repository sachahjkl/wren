package fuzz

// What a third party hands the browser: a filter list, an extension's manifest and its package.

import "core:hash"
import "wb:adblock"
import "wb:extensions"

ADBLOCK_SEEDS := []string{
	"! Title: list\n[Adblock Plus 2.0]\n||ads.example.com^\n@@||ads.example.com/ok^$script,domain=a.org|~b.org\n",
	"/banner[0-9]+\\.(gif|png)/$image,third-party,match-case\n|https://x.org/a*b|\n||e.org^$csp=script-src 'none',popup,redirect=noop.js\n",
	"example.org##.ad, #banner > div:nth-child(2)\nexample.org#@#.ad\n##body > .x:has(> .y)\nexample.org#?#div:-abp-has(.ad)\nexample.org##+js(set-constant, x, true)\n",
	"example.org#$#abort-on-property-read x\nexample.org#%#//scriptlet('abort-on-property-read', 'x')\n0.0.0.0 tracker.example.net\n127.0.0.1 a.b\n",
	"!#if (adguard && !adguard_ext_safari)\n||a.org^$removeparam=utm_source\n!#endif\n!#include other.txt\n$websocket,domain=x.org\n*$third-party,denyallow=a.org|b.org\n",
	"||e.org^$important,all\n||e.org^$badfilter\n||e.org^$header=set-cookie:/x/\n||e.org^$permissions=camera=()\n||e.org$1p,3p,doc,frame,css,xhr,font\n",
}

ADBLOCK_TOKENS := []string{
	"\n", "||", "|", "^", "*", "$", ",", "=", "~", "@@", "##", "#@#", "#?#", "#$#", "#%#", "##+js(", "/", "\\", ":has(", "domain=", "third-party",
	"script", "image", "redirect=", "csp=", "removeparam=", "important", "badfilter", "!#if", "!#endif", "!#include", "0.0.0.0 ", "[", "]", "(", ")", "{", "}",
}

// Requests the compiled filters are matched against: a document, a third-party script, an image of the page's own site,
// a websocket. The engine's indexes and its regular expressions run on what the input compiled.
@(private = "file")
Adblock_Request :: struct {
	url, source: string,
	type:        adblock.Resource,
}

@(private = "file")
ADBLOCK_REQUESTS := [?]Adblock_Request{
	{"https://example.org/", "", .Document},
	{"https://ads.example.com/banner123.gif?utm_source=x", "https://example.org/page", .Image},
	{"https://cdn.tracker.example.net/a/b.js", "https://example.org/", .Script},
	{"wss://x.org/socket", "https://a.org/", .Websocket},
	{"https://e.org/frame.html", "https://b.org/", .Subdocument},
}

target_adblock :: proc(data: []u8) {
	text := string(data)
	_, _ = adblock.validate_list(text)
	e := adblock.engine_from_text(text)
	if e == nil { return }
	defer adblock.engine_destroy(e)
	for r in ADBLOCK_REQUESTS {
		req := adblock.make_request(r.url, r.source, r.type)
		_ = adblock.match(e, &req)
	}
	_, _ = adblock.page_flags(e, "https://example.org/page")
}

MANIFEST_FILES := []Seed_Files{{dir = "examples/extensions", suffixes = {"manifest.json"}}}

MANIFEST_SEEDS := []string{
	`{"manifest_version": 3, "name": "a", "version": "1.0"}`,
	`{"manifest_version": 3, "name": "__MSG_name__", "version": "1.2.3.4", "default_locale": "en", "description": "d",` +
	` "icons": {"16": "i16.png", "128": "/i128.png"}, "action": {"default_popup": "popup.html", "default_icon": {"32": "x.png"}},` +
	` "background": {"service_worker": "bg.js", "type": "module"}, "permissions": ["storage", "tabs", "scripting"],` +
	` "host_permissions": ["<all_urls>", "*://*.example.org/*", "https://a.b/c*"], "content_scripts": [{"matches": ["http://*/*"],` +
	` "exclude_matches": ["*://x/*"], "js": ["a.js"], "css": ["a.css"], "run_at": "document_start", "all_frames": true, "include_globs": ["*a?b*"]}],` +
	` "web_accessible_resources": [{"resources": ["*.png"], "matches": ["<all_urls>"]}], "content_security_policy": {"extension_pages": "script-src 'self'"}}`,
	`{"manifest_version": 2, "name": "old", "version": "1", "background": {"scripts": ["a.js"], "persistent": false}, "browser_action": {}}`,
	`{"manifest_version": 3, "name": "x", "version": "1", "background": {"service_worker": "../out.js"}, "icons": {"16": "C:\\a"}, "permissions": [1, null, {}]}`,
	"<all_urls>", "*://*.example.org/path*", "https://a.b:8080/", "file:///*", "urn:x", "*://*/*",
}

MANIFEST_TOKENS := []string{
	"{", "}", "[", "]", ":", ",", "\"", "\\u0000", "\\", "null", "true", "false", "1e999", "-0", "\"manifest_version\"", "\"name\"", "\"version\"",
	"\"background\"", "\"service_worker\"", "\"content_scripts\"", "\"matches\"", "\"permissions\"", "\"host_permissions\"", "\"icons\"", "\"action\"",
	"\"web_accessible_resources\"", "\"<all_urls>\"", "\"*://*/*\"", "__MSG_", "../", "/", "*", "://",
}

ARCHIVE_TOKENS := []string{"PK\x03\x04", "PK\x01\x02", "PK\x05\x06", "Cr24", "\x03\x00\x00\x00", "\x08\x00", "\x00\x00", "\xff\xff\xff\xff", "\xff\xff", "manifest.json", "../", "/", "\x12", "\x0a"}

target_ext_manifest :: proc(data: []u8) {
	text := string(data)
	settings := extensions.settings_default()
	problems := make([dynamic]extensions.Problem, 0, 8, context.temp_allocator)
	// (the browser parses a manifest into an arena of its own, as the tests do: what it allocates is not checked here)
	_, _ = extensions.manifest_parse(text, nil, &settings, &problems, context.temp_allocator)
	_, _ = extensions.pattern_parse(text)
}

// At most this many entries read from one input: a list of thousands is the limits' business, not the reader's.
@(private = "file")
ARCHIVE_MAX_READS :: 64

target_ext_archive :: proc(data: []u8) {
	settings := extensions.settings_default()
	a, err := extensions.archive_open(data, &settings)
	if err != .None { return }
	for e, i in a.entries {
		if i == ARCHIVE_MAX_READS { break }
		bytes, _ := extensions.archive_read(&a, e)
		delete(bytes)
	}
}

// A zip of stored files with their checksums, and the same zip in a CRX3 envelope: without valid checksums the
// mutations never reach the reading of an entry.
archive_seeds :: proc(out: ^[dynamic][]u8) {
	files := [?][2]string{
		{"manifest.json", `{"manifest_version": 3, "name": "a", "version": "1"}`},
		{"popup/popup.html", "<p>popup</p>"},
		{"empty.txt", ""},
	}
	zip := make([dynamic]u8)
	central := make([dynamic]u8, context.temp_allocator)
	for f in files {
		name, body := f[0], transmute([]u8)f[1]
		crc := hash.crc32(body)
		offset := len(zip)
		put32(&zip, 0x04034b50); put16(&zip, 20); put16(&zip, 0); put16(&zip, 0); put16(&zip, 0); put16(&zip, 0)
		put32(&zip, crc); put32(&zip, u32(len(body))); put32(&zip, u32(len(body))); put16(&zip, u16(len(name))); put16(&zip, 0)
		append(&zip, name)
		append(&zip, ..body)
		put32(&central, 0x02014b50); put16(&central, 20); put16(&central, 20); put16(&central, 0); put16(&central, 0); put16(&central, 0); put16(&central, 0)
		put32(&central, crc); put32(&central, u32(len(body))); put32(&central, u32(len(body))); put16(&central, u16(len(name)))
		put16(&central, 0); put16(&central, 0); put16(&central, 0); put16(&central, 0); put32(&central, 0); put32(&central, u32(offset))
		append(&central, name)
	}
	central_at := len(zip)
	append(&zip, ..central[:])
	put32(&zip, 0x06054b50); put16(&zip, 0); put16(&zip, 0); put16(&zip, u16(len(files))); put16(&zip, u16(len(files)))
	put32(&zip, u32(len(central))); put32(&zip, u32(central_at)); put16(&zip, 0)
	append(out, zip[:])

	// CRX3: "Cr24", version 3, the header's size, then the header: field 2 (an RSA proof) holding field 1 (the key)
	// and field 2 (the signature). The reader takes the key, it does not check the signature.
	KEY :: "a public key of 32 bytes........"
	SIGNATURE :: "a signature"
	proof := make([dynamic]u8, context.temp_allocator)
	append(&proof, 0x0a, u8(len(KEY)))
	append(&proof, KEY)
	append(&proof, 0x12, u8(len(SIGNATURE)))
	append(&proof, SIGNATURE)
	header := make([dynamic]u8, context.temp_allocator)
	append(&header, 0x12, u8(len(proof)))
	append(&header, ..proof[:])
	crx := make([dynamic]u8)
	append(&crx, "Cr24")
	put32(&crx, 3)
	put32(&crx, u32(len(header)))
	append(&crx, ..header[:])
	append(&crx, ..zip[:])
	append(out, crx[:])
}

@(private = "file")
put16 :: proc(b: ^[dynamic]u8, v: u16) { append(b, u8(v), u8(v >> 8)) }

@(private = "file")
put32 :: proc(b: ^[dynamic]u8, v: u32) { append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)) }
