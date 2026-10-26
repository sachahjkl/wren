package browser

import "core:os"
import "core:strings"
import "core:testing"
import "wb:config"

// about:demos lists every page of examples\site (run from the repository root, as the test suite does), its links
// point where they should, and folder paths become file: URLs.
@(test)
demos_cover_every_page :: proc(t: ^testing.T) {
	listed := make(map[string]bool, context.temp_allocator)
	for d in DEMOS {
		if d.path == "" || d.perf || strings.has_prefix(d.path, "/") { continue }
		listed[d.path] = true
		testing.expectf(t, os.exists(strings.concatenate({"examples/site/", d.path}, context.temp_allocator)), "%s is listed but not in examples/site", d.path)
	}
	pages := make([dynamic]string, context.temp_allocator)
	walk :: proc(dir, rel: string, pages: ^[dynamic]string) {
		list, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for fi in list {
			sub := rel == "" ? fi.name : strings.concatenate({rel, "/", fi.name}, context.temp_allocator)
			if fi.type == .Directory {
				walk(strings.concatenate({dir, "/", fi.name}, context.temp_allocator), sub, pages)
			} else if strings.has_suffix(fi.name, ".html") {
				append(pages, sub)
			}
		}
	}
	walk("examples/site", "", &pages)
	testing.expect(t, len(pages) >= 20, "the pages of examples/site are found")
	for p in pages {
		if p == "index.html" { continue }   // the index of them all, made from the table (demos_index.odin)
		if strings.has_prefix(p, "partition/") { continue }   // the fixtures of tools\partition_e2e.ps1 (a page that embeds the third party given in the query): not demos
		testing.expectf(t, listed[p], "examples/site/%s is missing from about:demos (demos.odin, DEMOS)", p)
	}
}

@(test)
demos_links :: proc(t: ^testing.T) {
	testing.expect_value(t, file_url_of_dir(`C:\wren\my demos\`), "file:///C:/wren/my%20demos/")
	testing.expect_value(t, file_url_of_dir(`\\host\share\d`), "file://host/share/d/")
	testing.expect_value(t, file_url_of_dir(`D:\Privé`), "file:///D:/Priv%C3%A9/")

	app := new(App)
	defer free(app)
	app.prefs = config.prefs_make()
	defer config.prefs_destroy(&app.prefs)
	register_all_prefs(&app.prefs)
	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.demos.path", `C:\demos`, .User), config.Set_Error.None)
	base_url, source := demos_base(app)
	testing.expect_value(t, base_url, "file:///C:/demos/")
	testing.expect_value(t, source, Demos_Source.Preference)
	for d in DEMOS {
		href := demo_href(app, d, base_url)
		switch {
		case d.path == "": testing.expect_value(t, href, "")
		case strings.has_prefix(d.path, "/"): testing.expectf(t, href == strings.concatenate({"http://127.0.0.1:8765", d.path}, context.temp_allocator), "%s -> %s", d.path, href)
		case d.server: testing.expectf(t, href == strings.concatenate({"http://127.0.0.1:8765/site/", d.path}, context.temp_allocator), "%s -> %s", d.path, href)
		case !d.perf: testing.expectf(t, href == strings.concatenate({"file:///C:/demos/", d.path}, context.temp_allocator), "%s -> %s", d.path, href)
		}
	}
	html := demos_html(app)
	testing.expect(t, strings.contains(html, `href="file:///C:/demos/effects.html"`), "a static page links into the folder")
	testing.expect(t, strings.contains(html, `href="http://127.0.0.1:8765/site/images.html"`), "a server page links to the server")
}
