package docsite

import "core:testing"

// A highlight of a release note is shown whole: its first line and the indented lines that go on with it.
@(test)
release_bullets_are_whole :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	note := "# Wren 9.9.9\n\n**Lead.**\n\n### Highlights\n\n- **One**: a line that goes on\n  on the next one, and ends here.\n- **Two** in one line.\n\n### Fixed\n\n- not a highlight\n"
	r: Release
	release_bullets(note, &r)
	testing.expect_value(t, len(r.bullets), 2)
	if len(r.bullets) == 2 {
		testing.expect_value(t, r.bullets[0], "**One**: a line that goes on on the next one, and ends here.")
		testing.expect_value(t, r.bullets[1], "**Two** in one line.")
	}
	testing.expect_value(t, r.lead, "Lead.")
}
