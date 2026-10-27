package fetch

import "core:os"
import "core:strings"
import "core:testing"
import "wb:config"
import "wb:url"

@(private = "file")
round_trip :: proc(t: ^testing.T, path, want_url: string, directory := false, want_path := "") {
	got := file_url_from_path(path, directory, context.temp_allocator)
	testing.expectf(t, got == want_url, "%s -> %s, want %s", path, got, want_url)
	u, ok := url.parse_absolute(got, context.temp_allocator)
	testing.expectf(t, ok, "%s parses", got)
	back, _ := file_path_from_url(u, context.temp_allocator)
	expect := want_path != "" ? want_path : path
	testing.expectf(t, back == expect, "%s -> %s -> %s", path, got, back)
}

// The system's paths: Windows' drive letters, UNC and \\?\ forms; elsewhere POSIX paths, where '\' is a name's.
@(test)
system_paths_become_file_urls :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		round_trip(t, `C:\dir\page.html`, "file:///C:/dir/page.html")
		round_trip(t, `C:\my dir\a b#1%.html`, "file:///C:/my%20dir/a%20b%231%25.html")
		round_trip(t, `D:\Privé\été ☃.txt`, "file:///D:/Priv%C3%A9/%C3%A9t%C3%A9%20%E2%98%83.txt")
		round_trip(t, `S:\a%b;c&d.html`, "file:///S:/a%25b%3Bc%26d.html")
		round_trip(t, `\\server\share\x y\f.txt`, "file://server/share/x%20y/f.txt")
		round_trip(t, `C:\site`, "file:///C:/site/", directory = true, want_path = `C:\site\`)
		round_trip(t, `C:\site\`, "file:///C:/site/", want_path = `C:\site\`)
		round_trip(t, `C:`, "file:///C:/", want_path = `C:\`)
		round_trip(t, `C:\`, "file:///C:/")
		round_trip(t, `\\?\C:\very\long`, "file:///C:/very/long", want_path = `C:\very\long`)
		round_trip(t, `\\?\UNC\srv\s\f`, "file://srv/s/f", want_path = `\\srv\s\f`)
		round_trip(t, `C:/forward/slashes`, "file:///C:/forward/slashes", want_path = `C:\forward\slashes`)
	} else {
		round_trip(t, "/home/a/page.html", "file:///home/a/page.html")
		round_trip(t, "/my dir/a b#1%.html", "file:///my%20dir/a%20b%231%25.html")
		round_trip(t, "/Privé/été ☃.txt", "file:///Priv%C3%A9/%C3%A9t%C3%A9%20%E2%98%83.txt")
		round_trip(t, `/a\b.txt`, "file:///a%5Cb.txt")
		round_trip(t, "/site", "file:///site/", directory = true, want_path = "/site/")
		round_trip(t, "/", "file:///")
		u, _ := url.parse_absolute("file://server/share/f.txt", context.temp_allocator)
		_, remote := file_path_from_url(u, context.temp_allocator)
		testing.expect(t, !remote, "a host other than localhost is not a local file")
	}
}

@(test)
listing_links_and_redirects :: proc(t: ^testing.T) {
	testing.expect_value(t, listing_href("a b#1%.txt", false), "a%20b%231%25.txt")
	testing.expect_value(t, listing_href("sub dir", true), "sub%20dir/")
	testing.expect_value(t, listing_href("C:x", false), "C%3Ax")   // never read as a scheme
	testing.expect_value(t, listing_href("été", false), "%C3%A9t%C3%A9")
	testing.expect_value(t, listing_href("q?.txt", false), "q%3F.txt")

	// every href resolves inside the folder, to the file it names (of the names Windows allows: "C:x" and "q?.txt" are refused as paths)
	base_url := "file:///C:/my%20dir/" when ODIN_OS == .Windows else "file:///my%20dir/"
	folder := `C:\my dir\` when ODIN_OS == .Windows else "/my dir/"
	base, _ := url.parse_absolute(base_url, context.temp_allocator)
	for name in ([]string{"a b#1%.txt", "été ☃", "..x", "-"}) {
		r, ok := url.parse(listing_href(name, false), &base, context.temp_allocator)
		testing.expectf(t, ok, "%s resolves", name)
		p, _ := file_path_from_url(r, context.temp_allocator)
		testing.expectf(t, p == strings.concatenate({folder, name}, context.temp_allocator), "%s -> %s -> %s", name, r.href, p)
	}

	testing.expect_value(t, directory_redirect_href("file", "", "/C:/site", "", "", false, false, context.temp_allocator), "file:///C:/site/")
	testing.expect_value(t, directory_redirect_href("file", "srv", "/share/d", "sort=size", "top", true, true, context.temp_allocator), "file://srv/share/d/?sort=size#top")

	when ODIN_OS == .Windows {
		testing.expect(t, path_is_root(`C:\`))
		testing.expect(t, path_is_root(`C:`))
		testing.expect(t, path_is_root(`\\srv\share\`))
		testing.expect(t, !path_is_root(`\\srv\share\d\`))
		testing.expect(t, !path_is_root(`C:\site\`))
	} else {
		testing.expect(t, path_is_root("/"))
		testing.expect(t, !path_is_root("/site/"))
	}

	s := File_Settings{sort = .Name}
	so, desc := listing_order("sort=size&order=desc", &s)
	testing.expect(t, so == .Size && desc)
	so, desc = listing_order("", &s)
	testing.expect(t, so == .Name && !desc, "no query: the preferences")
	so, desc = listing_order("sort=bogus&order=asc", &s)
	testing.expect(t, so == .Name && !desc)

	testing.expect_value(t, size_text(0), "0 B")
	testing.expect_value(t, size_text(1536), "1.5 KB")
	testing.expect_value(t, size_text(200 << 20), "200 MB")
}

@(test)
file_settings_from_the_registry :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_prefs(&p)
	s := settings_from_prefs(&p)
	defer settings_destroy(&s)
	testing.expect_value(t, len(s.files.index_names), 2)
	testing.expect(t, s.files.index_names[0] == "index.html" && s.files.index_names[1] == "index.htm")
	testing.expect(t, s.files.listing && !s.files.show_hidden && s.files.folders_first)
	testing.expect_value(t, config.set_from_string(&p, "file.directory.index", " default.htm , ../up.html, a\\b.html,,home.html", .User), config.Set_Error.None)
	f := file_settings_from_prefs(&p)
	defer file_settings_destroy(&f)
	testing.expect_value(t, len(f.index_names), 2)   // a name that climbs or names a path is ignored
	testing.expect(t, f.index_names[0] == "default.htm" && f.index_names[1] == "home.html")
}

// A web page can neither open nor list the disk; the browser UI and file: documents navigate to any file.
@(test)
file_navigation_policy :: proc(t: ^testing.T) {
	web := environment_make(U2("https://example.com/"))
	defer environment_destroy(&web)
	local := environment_make(U2("file:///C:/site/index.html"))
	defer environment_destroy(&local)
	testing.expect(t, file_navigation_allowed(nil, .Own_Tree), "address bar, built-in pages")
	testing.expect(t, !file_navigation_allowed(&web, .Own_Tree), "a web page never opens a file")
	testing.expect(t, !file_navigation_allowed(&web, .All), "...whatever file: documents may read")
	testing.expect(t, file_navigation_allowed(&local, .Own_Tree), "a listing's parent link, a local page's links")
	testing.expect(t, !file_navigation_allowed(&local, .None), "file: documents may read nothing")
	testing.expect(t, !file_access_allowed(&web, `C:\site\`, .Own_Tree), "...nor read a folder")
}

@(private = "file")
U2 :: proc(s: string) -> url.URL {
	u, _ := url.parse_absolute(s, context.temp_allocator)
	return u
}

@(test)
folder_listing :: proc(t: ^testing.T) {
	dir := "build/dirlist_test"
	_ = os.make_directory_all("build/dirlist_test/Sub dir")
	files := []string{"b.txt", "a10.txt", "a2.txt", "x#y 1%.html", "a&b'c.txt", HIDDEN_NAME, "big.bin"}
	for f in files { _ = os.write_entire_file(strings.concatenate({dir, "/", f}, context.temp_allocator), transmute([]byte)string("12345")) }
	_ = os.write_entire_file("build/dirlist_test/big.bin", make([]byte, 5000, context.temp_allocator))
	defer {
		for f in files { _ = os.remove(strings.concatenate({dir, "/", f}, context.temp_allocator)) }
		_ = os.remove("build/dirlist_test/Sub dir")
		_ = os.remove(dir)
	}
	mark_hidden(strings.concatenate({dir, "/", HIDDEN_NAME}, context.temp_allocator))
	cwd, _ := os.get_working_directory(context.temp_allocator)
	abs, _ := strings.replace_all(strings.concatenate({cwd, "/build/dirlist_test/"}, context.temp_allocator), "/", FILE_SEP_STR, context.temp_allocator)

	s := File_Settings{max_entries = 100, folders_first = true}
	l, st := read_directory(abs, &s)
	defer dir_listing_destroy(&l)
	testing.expect_value(t, st, File_Status.Ok)
	testing.expect_value(t, l.hidden, 1)
	testing.expect_value(t, len(l.entries), 7)
	sort_listing(&l, .Name, false, true)
	names := make([]string, len(l.entries), context.temp_allocator)
	for e, i in l.entries { names[i] = e.name }
	want := []string{"Sub dir", "a&b'c.txt", "a2.txt", "a10.txt", "b.txt", "big.bin", "x#y 1%.html"}
	testing.expectf(t, slice_eq(names, want), "folders first, then names as Explorer sorts them: %v", names)

	sort_listing(&l, .Size, true, true)
	testing.expectf(t, l.entries[0].name == "Sub dir" && l.entries[1].name == "big.bin", "largest first, the folder still leads: %v %v", l.entries[0].name, l.entries[1].name)

	html := directory_listing_html(abs, &l, .Size, true, context.temp_allocator)
	testing.expect(t, strings.contains(html, `<title>Index of `), "titled")
	testing.expect(t, strings.contains(html, `href="x%23y%201%25.html"`), "a name with '#', ' ' and '%' links to itself")
	testing.expect(t, strings.contains(html, `href="Sub%20dir/"`), "a folder links with its '/'")
	testing.expect(t, strings.contains(html, `a&amp;b&#39;c.txt`), "names are escaped")
	testing.expect(t, strings.contains(html, `href="a%26b%27c.txt"`))
	{
		// (Windows refuses '<' and '>' in names; other file systems reached by a share do not)
		w := []u16{'<', 'i', '>', 0}
		fake := Dir_Listing{entries = make([dynamic]Dir_Entry, context.temp_allocator)}
		append(&fake.entries, Dir_Entry{name = "<i>.txt", wide = w})
		h := directory_listing_html(abs, &fake, .Name, false, context.temp_allocator)
		testing.expect(t, strings.contains(h, `&lt;i&gt;.txt`) && strings.contains(h, `href="%3Ci%3E.txt"`) && !strings.contains(h, "<i>"), "no markup from a file name")
	}
	testing.expect(t, strings.contains(html, `href="../"`), "a parent link")
	testing.expect(t, strings.contains(html, `href="?sort=size&amp;order=asc"`), "the current column flips the order")
	testing.expect(t, strings.contains(html, `color-scheme`), "light and dark")
	testing.expect(t, !strings.contains(html, HIDDEN_NAME), "hidden files are left out")
	testing.expect(t, !strings.contains(html, "<script"), "no script")

	s.max_entries = 3
	s.show_hidden = true
	l2, _ := read_directory(abs, &s)
	defer dir_listing_destroy(&l2)
	testing.expect(t, l2.truncated && len(l2.entries) == 3 && l2.found == 8, "the cap lists 3, counts them all")
	html2 := directory_listing_html(abs, &l2, .Name, false, context.temp_allocator)
	testing.expect(t, strings.contains(html2, "Showing 3 of 8"), "the cap is said")

	_, missing := read_directory(strings.concatenate({abs, "nope", FILE_SEP_STR}, context.temp_allocator), &s)
	testing.expect_value(t, missing, File_Status.Not_Found)
	_, ast := file_attributes(strings.concatenate({abs, "nope"}, context.temp_allocator))
	testing.expect_value(t, ast, File_Status.Not_Found)
	a, ok := file_attributes(abs)
	testing.expect(t, ok == .Ok && a.folder)
	root := file_url_from_path(abs, true, context.temp_allocator)
	testing.expect(t, strings.has_suffix(root, "/build/dirlist_test/"))
}

@(private = "file")
slice_eq :: proc(a, b: []string) -> bool {
	if len(a) != len(b) { return false }
	for x, i in a { if x != b[i] { return false } }
	return true
}
