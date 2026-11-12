package extensions

import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"

@(private = "file")
Parsed :: struct {
	arena:    base.Arena,
	m:        Manifest,
	ok:       bool,
	problems: [dynamic]Problem,
}

@(private = "file")
parse :: proc(p: ^Parsed, text: string, s: Settings = {}) {
	settings := s
	if settings.manifest_max_bytes == 0 { settings = settings_default() }
	_ = base.arena_init_growing(&p.arena)
	a := base.arena_allocator(&p.arena)
	p.problems = make([dynamic]Problem, 0, 8, a)
	p.m, p.ok = manifest_parse(text, nil, &settings, &p.problems, a)
}

@(private = "file")
parsed_destroy :: proc(p: ^Parsed) { base.arena_destroy(&p.arena) }

@(private = "file")
has_problem :: proc(p: ^Parsed, error: bool, part: string) -> bool {
	for x in p.problems { if x.error == error && strings.contains(x.text, part) { return true } }
	return false
}

@(private = "file")
fixture :: proc(name: string) -> string {
	data, err := os.read_entire_file(strings.concatenate({"examples/extensions/manifests/", name}, context.temp_allocator), context.temp_allocator)
	if err != nil { return "" }
	return string(data)
}

// Bitwarden's Chrome build (the target of phases 1 to 6): it loads, with warnings for what is not implemented yet.
@(test)
test_manifest_bitwarden_chrome :: proc(t: ^testing.T) {
	text := fixture("bitwarden-chrome.json")
	if !testing.expect(t, text != "", "the fixture examples/extensions/manifests/bitwarden-chrome.json is missing") { return }
	p: Parsed
	parse(&p, text)
	defer parsed_destroy(&p)
	testing.expectf(t, p.ok, "it must load: %v", p.problems)
	m := &p.m
	testing.expect_value(t, m.flavour, Flavour.Chrome)
	testing.expect_value(t, m.background_worker, "background.js")
	testing.expect(t, m.has_action)
	testing.expect_value(t, m.action.popup, "popup/index.html")
	testing.expect_value(t, m.action.title, "Bitwarden")
	testing.expect_value(t, len(m.content_scripts), 2)
	testing.expect_value(t, m.content_scripts[0].run_at, Run_At.Document_Start)
	testing.expect(t, m.content_scripts[1].all_frames)
	testing.expect_value(t, len(m.host_permissions), 2)
	testing.expect_value(t, m.csp_pages, "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'")
	testing.expect_value(t, len(m.sandbox_pages), 2)
	testing.expect_value(t, len(m.web_accessible), 1)
	testing.expect(t, m.web_accessible[0].use_dynamic_url)
	testing.expect_value(t, len(m.commands), 6)
	testing.expect(t, manifest_has_permission(m, "storage"))
	testing.expect(t, has_problem(&p, false, "\"webRequest\" is not implemented"))
	testing.expect(t, !has_problem(&p, false, "unknown key"))   // (side_panel and storage are known: ignored on purpose)
}

// The Firefox build: its flavour is found (gecko id, no service worker); it is not run by Wren yet.
@(test)
test_manifest_bitwarden_firefox :: proc(t: ^testing.T) {
	text := fixture("bitwarden-firefox.json")
	if !testing.expect(t, text != "", "the fixture examples/extensions/manifests/bitwarden-firefox.json is missing") { return }
	p: Parsed
	parse(&p, text)
	defer parsed_destroy(&p)
	testing.expect(t, p.ok)
	testing.expect_value(t, p.m.flavour, Flavour.Firefox)
	testing.expect_value(t, p.m.gecko_id, "{446900e4-71c2-419f-a6a7-df9c091e268b}")
	testing.expect_value(t, len(p.m.background_scripts), 1)
	testing.expect(t, has_problem(&p, false, "Firefox build"))
}

@(test)
test_manifest_wrong_types :: proc(t: ^testing.T) {
	Case :: struct { text, part: string }
	cases := [?]Case{
		{`{"manifest_version": 2, "name": "a", "version": "1"}`, "manifest_version must be 3"},
		{`{"name": "a", "version": "1"}`, "manifest_version is missing"},
		{`{"manifest_version": 3, "name": 5, "version": "1"}`, "name must be a string"},
		{`{"manifest_version": 3, "name": "a"}`, "version is missing"},
		{`{"manifest_version": 3, "name": "a", "version": "1", "permissions": "storage"}`, "permissions must be a list"},
		{`{"manifest_version": 3, "name": "a", "version": "1", "permissions": [1]}`, "permissions[0] must be a string"},
		{`{"manifest_version": 3, "name": "a", "version": "1", "background": []}`, "background must be an object"},
		{`{"manifest_version": 3, "name": "a", "version": "1", "action": "x"}`, "action must be an object"},
		{`{"manifest_version": 3, "name": "a", "version": "1", "content_scripts": {}}`, "content_scripts must be a list"},
		{`{"manifest_version": 3, "name": "a", "version": "1", "content_scripts": [{"matches": ["<all_urls>"], "run_at": "soon"}]}`, "run_at must be"},
		{`{"manifest_version": 3, "name": "a", "version": "1", "content_security_policy": "script-src 'self'"}`, "must be an object in Manifest V3"},
		{`{"manifest_version": 3, "name": "a", "version": "1", "content_security_policy": {"extension_pages": "script-src 'self' 'unsafe-eval'"}}`, "allows 'unsafe-eval'"},
		{`{"manifest_version": 3, "name": "a", "version": "1", "content_security_policy": {"extension_pages": "script-src 'self' https://cdn.example.com"}}`, "remote source"},
		{`{"manifest_version": 3, "name": "a", "version": "1", "web_accessible_resources": ["a.png"]}`, "must be an object (Manifest V3)"},
		{`{"manifest_version": 3, "name": "a", "version": "1", "minimum_chrome_version": "999"}`, "it needs Chrome 999"},
		{`[1, 2]`, "must be a JSON object"},
		{`{"manifest_version": 3,`, "not valid JSON"},
	}
	for c in cases {
		p: Parsed
		parse(&p, c.text)
		testing.expectf(t, !p.ok, "%s must not load", c.text)
		testing.expectf(t, has_problem(&p, true, c.part), "%s: expected an error with %q, got %v", c.text, c.part, p.problems)
		parsed_destroy(&p)
	}
}

@(test)
test_manifest_warnings_and_comments :: proc(t: ^testing.T) {
	text := `// a comment
	{ /* another */ "manifest_version": 3, "name": "a // not a comment", "version": "1", "frobnicate": true,
	  "browser_action": {}, "permissions": ["storage", "bookmarks"], "host_permissions": ["not a pattern", "https://*/*"] }`
	p: Parsed
	parse(&p, text)
	defer parsed_destroy(&p)
	testing.expect(t, p.ok)
	testing.expect_value(t, p.m.name, "a // not a comment")
	testing.expect(t, has_problem(&p, false, "unknown key \"frobnicate\""))
	testing.expect(t, has_problem(&p, false, "browser_action is a Manifest V2 key"))
	testing.expect(t, has_problem(&p, false, "\"bookmarks\" is not implemented"))
	testing.expect(t, has_problem(&p, false, "is not a match pattern"))
	testing.expect_value(t, len(p.m.host_permissions), 1)
}

@(test)
test_manifest_limits :: proc(t: ^testing.T) {
	s := settings_default()
	s.manifest_max_bytes = 16
	p: Parsed
	parse(&p, `{"manifest_version": 3, "name": "a", "version": "1"}`, s)
	defer parsed_destroy(&p)
	testing.expect(t, !p.ok)
	testing.expect(t, has_problem(&p, true, "extensions.manifest.max_bytes"))

	s2 := settings_default()
	s2.content_scripts_max = 1
	q: Parsed
	parse(&q, `{"manifest_version": 3, "name": "a", "version": "1", "content_scripts": [{"matches": ["<all_urls>"]}, {"matches": ["<all_urls>"]}]}`, s2)
	defer parsed_destroy(&q)
	testing.expect(t, !q.ok)
	testing.expect(t, has_problem(&q, true, "extensions.content_scripts.max_entries"))
}

// Every file the manifest names must be in the package, inside it.
@(test)
test_manifest_files :: proc(t: ^testing.T) {
	s := settings_default()
	files := make(map[string]File_Entry, 4, context.temp_allocator)
	files["background.js"] = {size = 10}
	files["popup.html"] = {size = 10}
	arena: base.Arena
	_ = base.arena_init_growing(&arena)
	defer base.arena_destroy(&arena)
	a := base.arena_allocator(&arena)
	problems := make([dynamic]Problem, 0, 4, a)
	_, ok := manifest_parse(`{"manifest_version": 3, "name": "a", "version": "1", "background": {"service_worker": "/background.js"}, "action": {"default_popup": "./popup.html"}}`, &files, &s, &problems, a)
	testing.expect(t, ok)
	clear(&problems)
	_, ok2 := manifest_parse(`{"manifest_version": 3, "name": "a", "version": "1", "background": {"service_worker": "../outside.js"}}`, &files, &s, &problems, a)
	testing.expect(t, !ok2)
	clear(&problems)
	_, ok3 := manifest_parse(`{"manifest_version": 3, "name": "a", "version": "1", "action": {"default_popup": "missing.html"}}`, &files, &s, &problems, a)
	testing.expect(t, !ok3)
}
