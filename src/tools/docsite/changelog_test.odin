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

// A home page's links to a release's files go to the files of the latest version; another link of the releases is left alone.
@(test)
download_links_follow_the_latest_version :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	page := `<a href="` + DOWNLOAD_PREFIX + `0.6.32/wren-0.6.32-windows-x64.exe">W</a> <a data-linux="` + DOWNLOAD_PREFIX + `0.6.32/wren-0.6.32-linux-x64.tar.gz">L</a> <a href="` + DOWNLOAD_PREFIX + `0.6.32/SHA256SUMS.txt">S</a>`
	want := `<a href="` + DOWNLOAD_PREFIX + `0.7.0/wren-0.7.0-windows-x64.exe">W</a> <a data-linux="` + DOWNLOAD_PREFIX + `0.7.0/wren-0.7.0-linux-x64.tar.gz">L</a> <a href="` + DOWNLOAD_PREFIX + `0.6.32/SHA256SUMS.txt">S</a>`
	testing.expect_value(t, stamp_download_links(page, "0.7.0"), want)
	testing.expect_value(t, stamp_download_links("no link", "0.7.0"), "no link")
}
