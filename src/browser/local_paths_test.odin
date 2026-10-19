package browser

import "core:strings"
import win "core:sys/windows"
import "core:testing"

@(private = "file")
path_url :: proc(s: string) -> string {
	u, ok := local_path_url(s)
	return ok ? u : "<not a path>"
}

// Paths typed or pasted in the address bar become file: URLs; anything else is left to the URL / search rules.
@(test)
typed_paths_become_file_urls :: proc(t: ^testing.T) {
	testing.expect_value(t, path_url(`C:\dir\page.html`), "file:///C:/dir/page.html")
	testing.expect_value(t, path_url(`S:/wasm_browser/examples/site`), "file:///S:/wasm_browser/examples/site")
	testing.expect_value(t, path_url(`S:\wasm_browser\examples\site\`), "file:///S:/wasm_browser/examples/site/")
	testing.expect_value(t, path_url(`  "C:\My Documents\a b#1%.html"  `), "file:///C:/My%20Documents/a%20b%231%25.html")   // Explorer's "Copy as path"
	testing.expect_value(t, path_url(`D:\Privé\été.html`), "file:///D:/Priv%C3%A9/%C3%A9t%C3%A9.html")
	testing.expect_value(t, path_url(`C:`), "file:///C:/")
	testing.expect_value(t, path_url(`c:\`), "file:///c:/")
	testing.expect_value(t, path_url(`\\server\share\doc.html`), "file://server/share/doc.html")
	testing.expect_value(t, path_url(`\\?\C:\long\path`), "file:///C:/long/path")

	home: [win.MAX_PATH_WIDE]u16
	if n := win.GetEnvironmentVariableW(win.utf8_to_wstring("USERPROFILE"), raw_data(home[:]), u32(len(home))); n > 0 {
		h, _ := win.utf16_to_utf8(home[:n], context.temp_allocator)
		u := path_url(`~\Documents`)
		testing.expectf(t, strings.has_prefix(u, "file:///") && strings.has_suffix(u, "/Documents"), "~ is the user's folder: %s (%s)", u, h)
		testing.expect(t, strings.has_suffix(path_url("~"), "/"), "~ alone is the folder")
	}

	for s in ([]string{"docs\\a.html", "example.com", "https://a.test/", "about:demos", "C:foo", "hello world", `\\`, `\\\x`, "", "~user", `C:\a|b`}) {
		testing.expectf(t, path_url(s) == "<not a path>", "%q is not a local path", s)
	}
}

@(test)
address_bar_rules :: proc(t: ^testing.T) {
	testing.expect_value(t, address_or_search(`S:\wb\examples\site`), "file:///S:/wb/examples/site")
	testing.expect_value(t, address_or_search(`\\nas\films`), "file://nas/films")
	testing.expect(t, strings.contains(address_or_search(`docs\a.html`), "?q="), "a relative path is ambiguous: a search")
	testing.expect_value(t, address_or_search("example.com"), "example.com")
	testing.expect_value(t, address_or_search("about:"), "about:")
	testing.expect_value(t, normalize_address("about:"), ABOUT_URL)
	testing.expect_value(t, normalize_address(`C:\x y\`), "file:///C:/x%20y/")
	testing.expect_value(t, normalize_address("file:///C:/x"), "file:///C:/x")
	testing.expect_value(t, normalize_address("example.com"), "https://example.com")
}

@(test)
about_about_lists_the_builtin_pages :: proc(t: ^testing.T) {
	html := about_pages_html()
	for u in ([]string{HOME_URL, DEMOS_URL, "about:config", ABOUT_URL, "about:blank"}) {
		testing.expectf(t, strings.contains(html, strings.concatenate({`href="`, u, `"`}, context.temp_allocator)), "%s is listed", u)
	}
}
