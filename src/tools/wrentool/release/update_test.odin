package release

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

// A new key goes to a file that does not exist yet: outside a work tree it is written; in one (a folder holding .git)
// it is refused. (The absolute path of the missing file failed, and every new key was refused.)
@(test)
a_new_key_is_refused_only_inside_a_work_tree :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/wren-keygen-%d", os.temp_directory(context.temp_allocator) or_else "/tmp", time.to_unix_nanoseconds(time.now()))
	outside := fmt.tprintf("%s/outside", root)
	inside := fmt.tprintf("%s/repo/keys", root)
	testing.expect(t, os.make_directory_all(outside) == nil && os.make_directory_all(inside) == nil, "the folders")
	defer os.remove_all(root)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/repo/.git", root)) == nil, "a work tree's .git")

	testing.expect(t, !update_inside_git_tree(fmt.tprintf("%s/release.key", outside)), "a new key outside a work tree")
	testing.expect(t, update_inside_git_tree(fmt.tprintf("%s/release.key", inside)), "a new key inside a work tree")
}
