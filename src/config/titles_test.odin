package config

import "core:testing"

@(test)
titles_read_as_phrases :: proc(t: ^testing.T) {
	T :: struct { d: Def, want: string }
	cases := [?]T{
		{{name = "blocker.badge.style", kind = .String, category = "blocker"}, "Badge style"},
		{{name = "blocker.cosmetic.debounce_ms", kind = .Int, category = "blocker"}, "Cosmetic debounce"},
		{{name = "blocker.badge.enabled", kind = .Bool, category = "blocker"}, "Badge"},
		{{name = "blocker.enabled", kind = .Bool, category = "blocker"}, "Enabled"},                // nothing else to say
		{{name = "network.http.max_connections_per_host", kind = .Int, category = "network"}, "HTTP max connections per host"},
		{{name = "devtools.ui.font_size_px", kind = .Int, category = "devtools"}, "UI font size"},
		{{name = "security.webauthn.testing.virtual_mode", kind = .String, category = "testing"}, "WebAuthn testing virtual mode"},
		{{name = "text.ms", kind = .Int, category = "text"}, "Ms"},                               // a unit alone stays
		{{name = "solo", kind = .Int}, "Solo"},
	}
	for c in cases { testing.expect_value(t, title_of(c.d), c.want) }
	testing.expect_value(t, category_title("devtools"), "DevTools")
	testing.expect_value(t, category_title("privacy"), "Privacy")
	testing.expect_value(t, category_title("web_platform"), "Web platform")
}

@(test)
summary_is_the_first_sentence :: proc(t: ^testing.T) {
	T :: struct { text, summary, more: string }
	cases := [?]T{
		{"One sentence.", "One sentence.", ""},
		{"No full stop", "No full stop", ""},
		{"First. Second one.", "First.", "Second one."},
		{"Use e.g. this. Then that.", "Use e.g. this.", "Then that."},
		{"Scale 0.5 to 2. More.", "Scale 0.5 to 2.", "More."},
		{"Inside (see below. Then more) stays. Next.", "Inside (see below. Then more) stays.", "Next."},
		{"lower after. stop is not a sentence", "lower after. stop is not a sentence", ""},
		{"Why? Because.", "Why?", "Because."},
		{"  Spaces.   Around.  ", "Spaces.", "Around."},
	}
	for c in cases {
		s, m := summary_of(c.text)
		testing.expect_value(t, s, c.summary)
		testing.expect_value(t, m, c.more)
	}
}

@(test)
search_matches_every_word :: proc(t: ^testing.T) {
	d := Def{name = "blocker.badge.style", kind = .String, category = "blocker", description = "Where the blocked count goes on the shield."}
	testing.expect(t, matches(d, ""))
	testing.expect(t, matches(d, "badge"))
	testing.expect(t, matches(d, "badge style"))         // the title ("Badge style")
	testing.expect(t, matches(d, "shield count"))        // the description, any order
	testing.expect(t, matches(d, "blocker.badge"))       // the name
	testing.expect(t, !matches(d, "badge network"))      // every word must match
	testing.expect(t, !matches(d, "cookies"))
}
