// End-to-end test of file: folders through the policy layer (package fetch): the redirect to the URL with '/', the
// index file, the listing made by the browser (links, order, hidden files, cap), errors, and who may open what.
// Needs no server: everything is on the disk.
//   filetest.exe            (run from the repository root)
package filetest

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "core:time"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:http"
import "wb:net"
import "wb:url"

failures, checks: int
last: Result

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader

check :: proc(ok: bool, what: string, loc := #caller_location) {
	checks += 1
	if !ok { failures += 1; fmt.printf("FAIL %s  (line %d)   [last: failed=%v error=%v url=%q detail=%q body=%q]\n", what, loc.line, last.failed, last.error, last.final_url, last.detail, last.body[:min(len(last.body), 80)]) }
}

Result :: struct {
	done, failed, redirected: bool,
	error:     fetch.Error_Kind,
	detail:    string,
	status:    int,
	final_url: string,
	body:      string,
	mime:      string,
}

on_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	r := (^Result)(user)
	switch ev.kind {
	case .Response:
		r.status, r.redirected = ev.response.status, ev.response.redirected
		r.final_url = strings.clone(ev.response.url)
		if ev.response.has_mime { r.mime = strings.clone(http.mime_essence(ev.response.mime)) }
	case .Data:
	case .Done:
		r.done = true
		r.body = strings.clone(string(ev.data))
	case .Failed:
		r.done, r.failed = true, true
		r.error = ev.error
		r.detail = strings.clone(ev.detail)
	}
}

run :: proc(d: fetch.Request_Desc) -> Result {
	r := new(Result)
	fetch.start(&loader, {request = d, on_event = on_event, user = r, collect = true})
	start := time.tick_now()
	for !r.done && time.duration_seconds(time.tick_since(start)) < 120 {   // the bound only ends a failing run host.loop_wait(&loop, 10) }
	if !r.done { r.failed, r.detail = true, "timeout" }
	last = r^
	return r^
}

// A navigation, from the address bar (nil) or from a document.
nav :: proc(target: string, from: ^fetch.Environment = nil) -> Result {
	return run({url = target, mode = .Navigate, destination = .Document, credentials = .Include, initiator = from})
}

envs: [dynamic]^fetch.Environment
env :: proc(doc_url: string) -> ^fetch.Environment {
	u, _ := url.parse_absolute(doc_url, context.temp_allocator)
	e := new(fetch.Environment)
	e^ = fetch.environment_make(u)
	append(&envs, e)
	return e
}

write :: proc(path, text: string) { _ = os.write_entire_file(path, transmute([]byte)text) }

main :: proc() {
	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)

	// build\filetest_site\ : index.html, page.html, sub\ (no index: a listing), sub2\ (index.htm)
	_ = os.make_directory_all("build/filetest_site/sub")
	_ = os.make_directory_all("build/filetest_site/sub2")
	_ = os.make_directory_all("build/filetest_site/sub/inner dir")
	write("build/filetest_site/index.html", "<h1>root index</h1>")
	write("build/filetest_site/page.html", "<h1>page</h1>")
	write("build/filetest_site/sub/a b#1%.txt", "x")
	write("build/filetest_site/sub/été.txt", "1234567890")
	write("build/filetest_site/sub/secret.txt", "hidden")
	win.SetFileAttributesW(win.utf8_to_wstring("build/filetest_site/sub/secret.txt"), win.FILE_ATTRIBUTE_HIDDEN)
	write("build/filetest_site/sub2/index.htm", "<h1>htm index</h1>")
	cwd, _ := os.get_working_directory(context.temp_allocator)
	root_dir := strings.concatenate({cwd, "\\build\\filetest_site"}, context.temp_allocator)
	root := fetch.file_url_from_path(root_dir, true, context.temp_allocator)   // ends with '/'
	no_slash := strings.trim_right(root, "/")
	U :: proc(root, rel: string) -> string { return strings.concatenate({root, rel}, context.temp_allocator) }

	fmt.println("-- folders open their index")
	{
		r := nav(no_slash)
		check(!r.failed && r.redirected && r.final_url == root, "a folder URL without '/' is redirected to the one with it")
		check(r.body == "<h1>root index</h1>" && r.mime == "text/html", "...and shows its index.html")
		r = nav(root)
		check(!r.failed && !r.redirected && r.body == "<h1>root index</h1>", "a folder URL with '/' shows its index.html")
		r = nav(U(root, "sub2/"))
		check(!r.failed && r.body == "<h1>htm index</h1>" && r.mime == "text/html", "index.htm when there is no index.html")
		r = nav(U(root, "sub2?x=1#frag"))
		check(!r.failed && r.redirected && r.final_url == U(root, "sub2/?x=1#frag"), "the redirect keeps query and fragment")
	}

	fmt.println("-- a folder without an index: the listing")
	{
		r := nav(U(root, "sub"))
		check(!r.failed && r.redirected && r.final_url == U(root, "sub/"), "redirected to the folder URL")
		check(r.mime == "text/html" && strings.contains(r.body, "Index of ") && strings.contains(r.body, "filetest_site\\sub\\"), "a listing titled with the folder's path")
		check(strings.contains(r.body, `href="a%20b%231%25.txt"`), "an entry links to itself, escaped")
		check(strings.contains(r.body, `href="%C3%A9t%C3%A9.txt"`) && strings.contains(r.body, "été.txt"), "a Unicode name")
		check(strings.contains(r.body, `href="inner%20dir/"`), "a folder links with its '/'")
		check(strings.contains(r.body, `href="../"`), "a parent link")
		check(!strings.contains(r.body, "secret.txt"), "hidden files are left out")
		check(strings.index(r.body, "inner dir") < strings.index(r.body, "a b#1%.txt"), "folders first")
		check(!strings.contains(r.body, "<script"), "no script")

		// the listing's links work from the listing itself (a file: document navigating)
		listing := env(U(root, "sub/"))
		r = nav(U(root, "sub/a%20b%231%25.txt"), listing)
		check(!r.failed && r.body == "x", "an entry's link opens the file")
		r = nav(U(root, "sub/../page.html"), listing)
		check(!r.failed && r.body == "<h1>page</h1>", "the parent link leaves the folder's tree: a file: navigation may")
		r = nav(U(root, "sub/?sort=size&order=desc"), listing)
		check(!r.failed && strings.index(r.body, "été.txt") < strings.index(r.body, "a b#1%.txt"), "sorted by size, largest first")
		check(strings.contains(r.body, "Size \u25BE"), "the sorted column shows its order")
	}

	fmt.println("-- errors")
	{
		r := nav(U(root, "missing/"))
		check(r.failed && strings.contains(r.detail, "no such file or folder"), "a missing folder")
		r = nav(U(root, "missing.html"))
		check(r.failed && strings.contains(r.detail, "no such file or folder"), "a missing file")
		denied := `C:\System Volume Information`
		attrs := win.GetFileAttributesW(win.utf8_to_wstring(denied))
		if attrs != win.INVALID_FILE_ATTRIBUTES {
			r = nav(fetch.file_url_from_path(denied, true, context.temp_allocator))
			check(r.failed && strings.contains(r.detail, "access denied"), "a folder the user may not read")
		}
		r = nav("file:///C:/")
		check(!r.failed && strings.contains(r.body, "Index of C:\\") && !strings.contains(r.body, `href="../"`), "a drive root: no parent")
		r = nav("file:///C:")
		check(!r.failed && r.final_url == "file:///C:/", "a bare drive is its root")
	}

	fmt.println("-- who may open or list what")
	{
		web := env("https://example.com/")
		r := nav(root, web)
		check(r.failed && r.error == .Blocked_File, "a web page cannot open a local folder")
		r = nav(U(root, "page.html"), web)
		check(r.failed && r.error == .Blocked_File, "...nor a local file")
		r = run({url = root, mode = .Cors, initiator = web})
		check(r.failed && r.error == .Blocked_File, "...nor fetch one")
		doc := env(U(root, "index.html"))
		r = run({url = U(root, "sub/"), mode = .Cors, initiator = doc})
		check(r.failed && strings.contains(r.detail, "is a folder") && !strings.contains(r.body, "Index of"), "a document's fetch of a folder in its tree gets no listing")
		r = run({url = U(root, "page.html"), mode = .Cors, initiator = doc})
		check(!r.failed && r.body == "<h1>page</h1>", "...while its files read as before")
	}

	fmt.println("-- preferences")
	{
		profile.settings.files.listing = false
		r := nav(U(root, "sub/"))
		check(r.failed && strings.contains(r.detail, "file.directory.listing"), "listings off: an error that names the preference")
		profile.settings.files.listing = true
		names := profile.settings.files.index_names
		profile.settings.files.index_names = nil
		r = nav(root)
		check(!r.failed && strings.contains(r.body, "Index of") && strings.contains(r.body, `href="index.html"`), "no index names: the listing")
		profile.settings.files.index_names = names
		profile.settings.files.show_hidden = true
		r = nav(U(root, "sub/"))
		check(!r.failed && strings.contains(r.body, "secret.txt"), "hidden files when asked for")
		profile.settings.files.show_hidden = false
		profile.settings.files.max_entries = 1
		r = nav(U(root, "sub/"))
		check(!r.failed && strings.contains(r.body, "Showing 1 of 3"), "the cap")
		profile.settings.files.max_entries = 5000
	}

	fmt.printf("\n%d checks, %d failure(s)\n", checks, failures)
	for e in envs { fetch.environment_destroy(e) }
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	host.loop_destroy(&loop)
	os.exit(failures)
}
