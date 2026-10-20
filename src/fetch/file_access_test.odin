package fetch

import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:host"
import "wb:url"

@(private = "file")
path_of :: proc(s: string) -> (string, bool) {
	u, ok := url.parse_absolute(s, context.temp_allocator)
	if !ok { return "", false }
	return file_path_from_url(u, context.temp_allocator)
}

// What Windows would open as another file than the URL names is refused before any access check.
@(test)
file_urls_that_windows_would_rewrite :: proc(t: ^testing.T) {
	refused := []string{
		"file:///C:/site/a%5C..%5C..%5Csecret.txt",   // encoded separators around ".."
		"file:///C:/site/a%2F..%2F..%2Fsecret.txt",
		"file:///C:/site/%2e%2e%5Csecret.txt",
		"file:///C:/site/page.html:hidden",            // an alternate data stream
		"file:///C:/site/CON",
		"file:///C:/site/nul.txt",
		"file:///C:/site/com1.log",
		"file:///C:/site/LPT9",
		"file:///C:/site/aux%20.html",
		"file:///C:/site/CONOUT$",
		"file:///C:/site/page.html.",                  // trailing dot: Windows opens page.html
		"file:///C:/site/page.html%20",
		"file:////%3F/C:/x",                           // \\?\C:\x, a device path
		"file:///C:/site/a%01b",
	}
	for s in refused {
		p, ok := path_of(s)
		testing.expectf(t, !ok, "%s refused (got %q)", s, p)
	}
	allowed := []struct { url, path: string }{
		{"file:///C:/site/conx.txt/console.html", `C:\site\conx.txt\console.html`},
		{"file:///C:/site/COM10", `C:\site\COM10`},
		{"file:///C:/site/.hidden", `C:\site\.hidden`},
		{"file:///C:/site/a..b.txt", `C:\site\a..b.txt`},
		{"file://server/share/f.txt", `\\server\share\f.txt`},
	}
	for a in allowed {
		p, ok := path_of(a.url)
		testing.expectf(t, ok && p == a.path, "%s -> %q (%v), want %q", a.url, p, ok, a.path)
	}
}

// A local page cannot make Windows connect (and sign in) to another machine by navigating to file://server/.
@(test)
file_navigation_to_another_machine :: proc(t: ^testing.T) {
	local := environment_make(U3("file:///C:/site/index.html"))
	defer environment_destroy(&local)
	share := environment_make(U3("file://server/share/index.html"))
	defer environment_destroy(&share)
	testing.expect(t, !file_navigation_allowed(&local, .Own_Tree, "attacker"), "a local page does not open file://attacker/")
	testing.expect(t, file_navigation_allowed(&local, .Own_Tree, ""), "a local page opens local files")
	testing.expect(t, file_navigation_allowed(&share, .Own_Tree, "SERVER"), "a page of a share opens files of its server")
	testing.expect(t, !file_navigation_allowed(&share, .Own_Tree, "other"), "...not of another one")
	testing.expect(t, file_navigation_allowed(nil, .Own_Tree, "server"), "the address bar opens any share")
}

@(private = "file")
U3 :: proc(s: string) -> url.URL {
	u, _ := url.parse_absolute(s, context.temp_allocator)
	return u
}

@(private = "file")
Got :: struct { done: bool, failed: bool, kind: Error_Kind, body: [dynamic]byte }

// A file reached through a junction inside a document's folder is outside the folder: a subresource read is refused.
@(test)
junction_out_of_the_document_tree :: proc(t: ^testing.T) {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	base_dir, _ := strings.replace_all(strings.concatenate({cwd, `\build\file_access_test`}, context.temp_allocator), "/", `\`, context.temp_allocator)
	root := strings.concatenate({base_dir, `\root`}, context.temp_allocator)
	outside := strings.concatenate({base_dir, `\outside`}, context.temp_allocator)
	link := strings.concatenate({root, `\link`}, context.temp_allocator)
	_ = os.make_directory_all(root)
	_ = os.make_directory_all(outside)
	_ = os.write_entire_file(strings.concatenate({root, `\inside.txt`}, context.temp_allocator), transmute([]byte)string("in"))
	_ = os.write_entire_file(strings.concatenate({outside, `\secret.txt`}, context.temp_allocator), transmute([]byte)string("secret"))
	if !os.exists(link) {
		// a junction needs no privilege (a symbolic link does)
		_, _, _, _ = os.process_exec({command = {"cmd", "/c", "mklink", "/J", link, outside}}, context.temp_allocator)
	}
	defer {
		_ = os.remove(link)   // the junction itself, not what it points to
		_ = os.remove(strings.concatenate({root, `\inside.txt`}, context.temp_allocator))
		_ = os.remove(strings.concatenate({outside, `\secret.txt`}, context.temp_allocator))
		_ = os.remove(root)
		_ = os.remove(outside)
		_ = os.remove(base_dir)
	}
	if !os.exists(link) { testing.expect(t, false, "mklink /J failed: the junction case is not checked"); return }

	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	pool: host.Blocking_Pool
	host.blocking_init(&pool, &loop, 1)
	defer host.blocking_destroy(&pool)
	profile := profile_make()
	defer profile_destroy(&profile)
	l: Loader
	loader_init(&l, &loop, nil, &pool, &profile)
	defer loader_destroy(&l)
	page_url := file_url_from_path(strings.concatenate({root, `\page.html`}, context.temp_allocator), false, context.temp_allocator)
	env := environment_make(U3(page_url))
	defer environment_destroy(&env)

	read :: proc(l: ^Loader, loop: ^host.Loop, env: ^Environment, path: string) -> Got {
		g: Got
		start(l, {
			request = {url = file_url_from_path(path, false, context.temp_allocator), mode = .No_Cors, initiator = env, max_body = 1 << 20},
			on_event = proc(user: rawptr, task: base.Handle, ev: ^Event) {
				g := (^Got)(user)
				#partial switch ev.kind {
				case .Done:   g.done = true; append(&g.body, ..ev.data)
				case .Failed: g.done, g.failed, g.kind = true, true, ev.error
				}
			},
			user = &g, collect = true,
		})
		for !g.done { host.loop_wait(loop) }   // a file read ends with a post: the wait always ends
		return g
	}
	in_tree := read(&l, &loop, &env, strings.concatenate({root, `\inside.txt`}, context.temp_allocator))
	defer delete(in_tree.body)
	testing.expect(t, !in_tree.failed && string(in_tree.body[:]) == "in", "a file of the tree is read")
	through := read(&l, &loop, &env, strings.concatenate({link, `\secret.txt`}, context.temp_allocator))
	defer delete(through.body)
	testing.expect(t, through.failed && len(through.body) == 0, "a file behind a junction to another folder is not")
}
