package extensions

import "core:testing"

@(private = "file")
patterns :: proc(list: ..string) -> []Pattern {
	out := make([]Pattern, len(list), context.temp_allocator)
	for s, i in list {
		p, ok := pattern_parse(s)
		assert(ok, s)
		out[i] = p
	}
	return out
}

@(private = "file")
matching :: proc(ix: ^Script_Index, list: []Content_Script, href: string, top := true, fallback := false) -> []int {
	out := make([dynamic]int, 0, 4, context.temp_allocator)
	scripts_matching(ix, list, Script_Target{href = href, top = top, fallback = fallback}, &out)
	return out[:]
}

@(private = "file")
same :: proc(a, b: []int) -> bool {
	if len(a) != len(b) { return false }
	for x, i in a { if x != b[i] { return false } }
	return true
}

// Bitwarden's two entries (examples/extensions/manifests), a host entry, a subdomain entry and globs.
@(test)
test_content_scripts_matching :: proc(t: ^testing.T) {
	list := []Content_Script{
		{matches = patterns("*://*/*", "file:///*"), exclude_matches = patterns("*://*/*.xml*", "file:///*.xml*"), run_at = .Document_Start},
		{matches = patterns("*://*/*", "file:///*"), exclude_matches = patterns("*://*/*.xml*", "file:///*.xml*"), all_frames = true, run_at = .Document_Start},
		{matches = patterns("https://login.example.com/*")},
		{matches = patterns("https://*.example.org/*"), all_frames = true},
		{matches = patterns("https://*/*"), include_globs = {"*sign?in*"}, exclude_globs = {"*nope*"}},
		{matches = patterns("https://*/*"), match_about_blank = true, all_frames = true},
	}
	ix: Script_Index
	script_index_build(&ix, list, context.temp_allocator)

	testing.expect(t, same(matching(&ix, list, "https://login.example.com/form"), {0, 1, 2, 5}))
	testing.expect(t, same(matching(&ix, list, "https://example.com/feed.xml"), {5}), "exclude_matches leaves the feed out")
	testing.expect(t, same(matching(&ix, list, "https://a.b.example.org/x"), {0, 1, 3, 5}), "a subdomain pattern covers every level")
	testing.expect(t, same(matching(&ix, list, "https://example.org/x"), {0, 1, 3, 5}), "and the domain itself")
	testing.expect(t, same(matching(&ix, list, "https://evilexample.org/x"), {0, 1, 5}))
	testing.expect(t, same(matching(&ix, list, "https://site.test/sign-in"), {0, 1, 4, 5}), "include_globs: '?' is one character")
	testing.expect(t, same(matching(&ix, list, "https://site.test/sign-in/nope"), {0, 1, 5}), "exclude_globs")
	// a frame: only all_frames entries
	testing.expect(t, same(matching(&ix, list, "https://login.example.com/form", top = false), {1, 5}))
	// about:blank in a frame of a matching page: match_about_blank only
	testing.expect(t, same(matching(&ix, list, "https://login.example.com/form", top = false, fallback = true), {5}))
	// no web page: nothing
	testing.expect(t, len(matching(&ix, list, "chrome-extension://abcdefghijklmnopabcdefghijklmnop/popup.html")) == 0)
	testing.expect(t, len(matching(&ix, list, "about:blank")) == 0)
}

@(test)
test_content_scripts_registered :: proc(t: ^testing.T) {
	r: Registered_Scripts
	defer registered_destroy(&r)
	specs := []Registered_Spec{
		{id = "a", matches = {"https://*.example.com/*"}, js = {"a.js"}, run_at = .Document_End},
		{id = "b", matches = {"<all_urls>"}, css = {"b.css"}, all_frames = true, persist = true},
	}
	testing.expect(t, registered_set(&r, specs))
	testing.expect(t, registered_find(&r, "b") == 1)
	testing.expect(t, registered_find(&r, "c") == -1)
	testing.expect(t, same(matching(&r.index, r.list, "https://www.example.com/"), {0, 1}))
	testing.expect(t, same(matching(&r.index, r.list, "https://other.test/", top = false), {1}))
	// a change replaces every entry (the old arena goes)
	testing.expect(t, registered_set(&r, specs[1:]))
	testing.expect(t, len(r.list) == 1 && r.ids[0] == "b" && r.persist[0])
	testing.expect(t, same(matching(&r.index, r.list, "https://www.example.com/"), {0}))
}
