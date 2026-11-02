#+build windows
#+private file
// file: folders through the policy layer (package fetch): the redirect to the URL with '/', the index file, the listing made by the
// browser (links, order, hidden files, cap), errors, and who may open what. Everything is on the disk, in build\filetest_site.
package e2e_scenarios

import "core:os"
import "core:strings"
import win "core:sys/windows"
import "core:testing"
import "wb:base"
import "wb:fetch"
import "wb:http"
import "wb:url"

SITE :: "build/filetest_site"
SORTED_MAX_ENTRIES :: 1
DEFAULT_MAX_ENTRIES :: 5000
RUN_LIMIT :: 120.0

Result :: struct {
	done, failed, redirected: bool,
	error:     fetch.Error_Kind,
	detail:    string,
	status:    int,
	final_url: string,
	body:      string,
	mime:      string,
}

// What a test keeps of its requests, until its end: a temporary allocator (the runner frees it after each test).
on_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	r := (^Result)(user)
	context.allocator = base.process_context().temp_allocator
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

run_fetch :: proc(t: ^testing.T, d: fetch.Request_Desc) -> Result {
	r := new(Result, context.temp_allocator)
	fetch.start(&loader, {request = d, on_event = on_event, user = r, collect = true})
	if !wait_until(t, d.url, r, proc(r: ^Result) -> bool { return r.done }, RUN_LIMIT) { r.failed, r.detail = true, "timeout" }
	return r^
}

// A navigation, from the address bar (nil) or from a document.
nav :: proc(t: ^testing.T, target: string, from: ^fetch.Environment = nil) -> Result {
	return run_fetch(t, {url = target, mode = .Navigate, destination = .Document, credentials = .Include, initiator = from})
}

env :: proc(t: ^testing.T, doc_url: string) -> ^fetch.Environment {
	u, _ := url.parse_absolute(doc_url, context.temp_allocator)
	e := new(fetch.Environment)
	e^ = fetch.environment_make(u)
	testing.cleanup(t, proc(ptr: rawptr) { e := (^fetch.Environment)(ptr); fetch.environment_destroy(e); free(e) }, e)
	return e
}

write :: proc(path, text: string) { _ = os.write_entire_file(path, transmute([]byte)text) }

// The folder of the tests: index.html, page.html, sub\ (no index: a listing), sub2\ (index.htm). Its address, ending with '/'.
site :: proc() -> string {
	_ = os.make_directory_all(SITE + "/sub/inner dir")
	_ = os.make_directory_all(SITE + "/sub2")
	write(SITE + "/index.html", "<h1>root index</h1>")
	write(SITE + "/page.html", "<h1>page</h1>")
	write(SITE + "/sub/a b#1%.txt", "x")
	write(SITE + "/sub/été.txt", "1234567890")
	write(SITE + "/sub/secret.txt", "hidden")
	win.SetFileAttributesW(win.utf8_to_wstring(SITE + "/sub/secret.txt"), win.FILE_ATTRIBUTE_HIDDEN)
	write(SITE + "/sub2/index.htm", "<h1>htm index</h1>")
	cwd, _ := os.get_working_directory(context.temp_allocator)
	return fetch.file_url_from_path(strings.concatenate({cwd, "\\build\\filetest_site"}, context.temp_allocator), true, context.temp_allocator)
}

under :: proc(root, rel: string) -> string { return strings.concatenate({root, rel}, context.temp_allocator) }

@(test)
file_folders_open_their_index :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	root := site()
	r := nav(t, strings.trim_right(root, "/"))
	testing.expect(t, !r.failed && r.redirected && r.final_url == root, "a folder URL without '/' is redirected to the one with it")
	testing.expect(t, r.body == "<h1>root index</h1>" && r.mime == "text/html", "...and shows its index.html")
	r = nav(t, root)
	testing.expect(t, !r.failed && !r.redirected && r.body == "<h1>root index</h1>", "a folder URL with '/' shows its index.html")
	r = nav(t, under(root, "sub2/"))
	testing.expect(t, !r.failed && r.body == "<h1>htm index</h1>" && r.mime == "text/html", "index.htm when there is no index.html")
	r = nav(t, under(root, "sub2?x=1#frag"))
	testing.expect(t, !r.failed && r.redirected && r.final_url == under(root, "sub2/?x=1#frag"), "the redirect keeps query and fragment")
}

@(test)
file_a_folder_without_an_index_is_listed :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	root := site()
	r := nav(t, under(root, "sub"))
	testing.expect(t, !r.failed && r.redirected && r.final_url == under(root, "sub/"), "redirected to the folder URL")
	testing.expect(t, r.mime == "text/html" && strings.contains(r.body, "Index of ") && strings.contains(r.body, "filetest_site\\sub\\"), "a listing titled with the folder's path")
	testing.expect(t, strings.contains(r.body, `href="a%20b%231%25.txt"`), "an entry links to itself, escaped")
	testing.expect(t, strings.contains(r.body, `href="%C3%A9t%C3%A9.txt"`) && strings.contains(r.body, "été.txt"), "a Unicode name")
	testing.expect(t, strings.contains(r.body, `href="inner%20dir/"`), "a folder links with its '/'")
	testing.expect(t, strings.contains(r.body, `href="../"`), "a parent link")
	testing.expect(t, !strings.contains(r.body, "secret.txt"), "hidden files are left out")
	testing.expect(t, strings.index(r.body, "inner dir") < strings.index(r.body, "a b#1%.txt"), "folders first")
	testing.expect(t, !strings.contains(r.body, "<script"), "no script")

	// the listing's links work from the listing itself (a file: document navigating)
	listing := env(t, under(root, "sub/"))
	r = nav(t, under(root, "sub/a%20b%231%25.txt"), listing)
	testing.expect(t, !r.failed && r.body == "x", "an entry's link opens the file")
	r = nav(t, under(root, "sub/../page.html"), listing)
	testing.expect(t, !r.failed && r.body == "<h1>page</h1>", "the parent link leaves the folder's tree: a file: navigation may")
	r = nav(t, under(root, "sub/?sort=size&order=desc"), listing)
	testing.expect(t, !r.failed && strings.index(r.body, "été.txt") < strings.index(r.body, "a b#1%.txt"), "sorted by size, largest first")
	testing.expect(t, strings.contains(r.body, "Size \u25BE"), "the sorted column shows its order")
}

@(test)
file_errors :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	root := site()
	r := nav(t, under(root, "missing/"))
	testing.expect(t, r.failed && strings.contains(r.detail, "no such file or folder"), "a missing folder")
	r = nav(t, under(root, "missing.html"))
	testing.expect(t, r.failed && strings.contains(r.detail, "no such file or folder"), "a missing file")
	denied := `C:\System Volume Information`
	if win.GetFileAttributesW(win.utf8_to_wstring(denied)) != win.INVALID_FILE_ATTRIBUTES {
		r = nav(t, fetch.file_url_from_path(denied, true, context.temp_allocator))
		testing.expect(t, r.failed && strings.contains(r.detail, "access denied"), "a folder the user may not read")
	}
	r = nav(t, "file:///C:/")
	testing.expect(t, !r.failed && strings.contains(r.body, "Index of C:\\") && !strings.contains(r.body, `href="../"`), "a drive root: no parent")
	r = nav(t, "file:///C:")
	testing.expect(t, !r.failed && r.final_url == "file:///C:/", "a bare drive is its root")
}

@(test)
file_who_may_open_or_list_what :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	root := site()
	web := env(t, "https://example.com/")
	r := nav(t, root, web)
	testing.expect(t, r.failed && r.error == .Blocked_File, "a web page cannot open a local folder")
	r = nav(t, under(root, "page.html"), web)
	testing.expect(t, r.failed && r.error == .Blocked_File, "...nor a local file")
	r = run_fetch(t, {url = root, mode = .Cors, initiator = web})
	testing.expect(t, r.failed && r.error == .Blocked_File, "...nor fetch one")
	doc := env(t, under(root, "index.html"))
	r = run_fetch(t, {url = under(root, "sub/"), mode = .Cors, initiator = doc})
	testing.expect(t, r.failed && strings.contains(r.detail, "is a folder") && !strings.contains(r.body, "Index of"), "a document's fetch of a folder in its tree gets no listing")
	r = run_fetch(t, {url = under(root, "page.html"), mode = .Cors, initiator = doc})
	testing.expect(t, !r.failed && r.body == "<h1>page</h1>", "...while its files read as before")
}

@(test)
file_preferences :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	root := site()
	files := &profile.settings.files
	defer {
		files.listing, files.show_hidden = true, false
		files.max_entries = DEFAULT_MAX_ENTRIES
	}
	files.listing = false
	r := nav(t, under(root, "sub/"))
	testing.expect(t, r.failed && strings.contains(r.detail, "file.directory.listing"), "listings off: an error that names the preference")
	files.listing = true
	names := files.index_names
	files.index_names = nil
	r = nav(t, root)
	testing.expect(t, !r.failed && strings.contains(r.body, "Index of") && strings.contains(r.body, `href="index.html"`), "no index names: the listing")
	files.index_names = names
	files.show_hidden = true
	r = nav(t, under(root, "sub/"))
	testing.expect(t, !r.failed && strings.contains(r.body, "secret.txt"), "hidden files when asked for")
	files.show_hidden = false
	files.max_entries = SORTED_MAX_ENTRIES
	r = nav(t, under(root, "sub/"))
	testing.expect(t, !r.failed && strings.contains(r.body, "Showing 1 of 3"), "the cap")
}
