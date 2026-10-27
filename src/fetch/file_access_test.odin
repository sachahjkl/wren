package fetch

import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:host"
import "wb:url"

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

@(private = "file")
join :: proc(parts: ..string) -> string { return strings.join(parts, FILE_SEP_STR, context.temp_allocator) }

// A file reached through a link to a folder (a junction on Windows, a symbolic link elsewhere) inside a document's
// folder is outside the folder: a subresource read is refused.
@(test)
link_out_of_the_document_tree :: proc(t: ^testing.T) {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	base_dir, _ := strings.replace_all(strings.concatenate({cwd, "/build/file_access_test"}, context.temp_allocator), "/", FILE_SEP_STR, context.temp_allocator)
	root := join(base_dir, "root")
	outside := join(base_dir, "outside")
	link := join(root, "link")
	_ = os.make_directory_all(root)
	_ = os.make_directory_all(outside)
	_ = os.write_entire_file(join(root, "inside.txt"), transmute([]byte)string("in"))
	_ = os.write_entire_file(join(outside, "secret.txt"), transmute([]byte)string("secret"))
	if !os.exists(link) { make_folder_link(link, outside) }
	defer {
		_ = os.remove(link)   // the link itself, not what it points to
		_ = os.remove(join(root, "inside.txt"))
		_ = os.remove(join(outside, "secret.txt"))
		_ = os.remove(root)
		_ = os.remove(outside)
		_ = os.remove(base_dir)
	}
	if !os.exists(link) { testing.expect(t, false, "the folder link could not be made: the case is not checked"); return }

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
	page_url := file_url_from_path(join(root, "page.html"), false, context.temp_allocator)
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
	in_tree := read(&l, &loop, &env, join(root, "inside.txt"))
	defer delete(in_tree.body)
	testing.expect(t, !in_tree.failed && string(in_tree.body[:]) == "in", "a file of the tree is read")
	through := read(&l, &loop, &env, join(link, "secret.txt"))
	defer delete(through.body)
	testing.expect(t, through.failed && len(through.body) == 0, "a file behind a link to another folder is not")
}
