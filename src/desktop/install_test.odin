package desktop

// The installed copy on scratch folders in %TEMP% (never the real install folder).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private)
Tree :: struct {
	root: string,   // the scratch folder
	src:  string,   // a folder standing for the unpacked package: wren.exe, vcruntime140.dll, licenses\, demos\
	dst:  string,   // the install folder (not made)
	opts: Options,
}

@(private)
tree_make :: proc() -> Tree {
	tmp, _ := os.temp_dir(context.allocator)
	defer delete(tmp)
	t: Tree
	t.root = fmt.aprintf("%s/wren_install_test_%d", strings.trim_right(tmp, "\\/"), time.to_unix_nanoseconds(time.now()))
	t.src = fmt.aprintf("%s/package", t.root)
	t.dst = fmt.aprintf("%s/installed/Wren", t.root)
	put :: proc(path, text: string) {
		_ = os.make_directory_all(parent_dir(path))
		_ = os.write_entire_file(path, text)
	}
	put(fmt.tprintf("%s/wren.exe", t.src), "MZ program v1")
	put(fmt.tprintf("%s/vcruntime140.dll", t.src), "runtime")
	put(fmt.tprintf("%s/licenses/a.txt", t.src), "licence a")
	put(fmt.tprintf("%s/licenses/sub/b.txt", t.src), "licence b")
	put(fmt.tprintf("%s/demos/index.html", t.src), "<p>demos")
	put(fmt.tprintf("%s/notes.txt", t.src), "not in the payload")
	t.opts = Options{identity = Identity{name = "Wren", key = "Wren", slug = "wren", aumid = "FromentSoftware.Wren.Test", exe_name = "wren.exe"}}
	return t
}

@(private)
tree_destroy :: proc(t: ^Tree) {
	_ = os.remove_all(t.root)
	delete(t.root); delete(t.src); delete(t.dst)
}

@(private = "file") TEST_PAYLOAD := [?]string{"vcruntime140.dll", "licenses", "demos", "README.txt", "missing_dir"}

@(private)
plan_of :: proc(t: ^Tree, version := "0.3.0") -> Install_Plan {
	return Install_Plan{
		src_exe = fmt.tprintf("%s/wren.exe", t.src), dir = t.dst, exe_name = "wren.exe",
		payload = TEST_PAYLOAD[:],
		version = version, channel = "release",
	}
}

@(private = "file")
read :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : "<unreadable>"
}

@(test)
install_copies_the_payload_and_writes_the_manifest :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	r := files_install(plan_of(&tr))
	testing.expect_value(t, r.error, Error.None)
	if r.error != .None { testing.expect(t, false, r.detail); return }
	for rel in ([]string{"wren.exe", "vcruntime140.dll", "licenses/a.txt", "licenses/sub/b.txt", "demos/index.html", MANIFEST_NAME}) {
		testing.expectf(t, os.is_file(fmt.tprintf("%s/%s", tr.dst, rel)), "%s is installed", rel)
	}
	testing.expect(t, !os.exists(fmt.tprintf("%s/notes.txt", tr.dst)), "what is not in the payload stays behind")
	testing.expect(t, !os.exists(fmt.tprintf("%s/README.txt", tr.dst)), "a name that is missing is skipped")

	info := installed_info(&tr.opts, tr.dst, context.temp_allocator)
	testing.expect(t, info.exe_present && info.manifest, "the copy reads back")
	testing.expect_value(t, info.version, "0.3.0")
	testing.expect_value(t, info.channel, "release")
	testing.expect_value(t, info.files, 5)
	testing.expect_value(t, info.missing, 0)
	_ = os.remove(fmt.tprintf("%s/demos/index.html", tr.dst))
	info = installed_info(&tr.opts, tr.dst, context.temp_allocator)
	testing.expect_value(t, info.missing, 1)
}

@(test)
install_replaces_a_copy_and_leaves_no_old_file :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	testing.expect_value(t, files_install(plan_of(&tr, "0.3.0")).error, Error.None)
	testing.expect_value(t, read(fmt.tprintf("%s/wren.exe", tr.dst)), "MZ program v1")

	_ = os.write_entire_file(fmt.tprintf("%s/wren.exe", tr.src), "MZ program v2")
	testing.expect_value(t, files_install(plan_of(&tr, "0.4.0")).error, Error.None)
	testing.expect_value(t, read(fmt.tprintf("%s/wren.exe", tr.dst)), "MZ program v2")
	testing.expect_value(t, installed_info(&tr.opts, tr.dst, context.temp_allocator).version, "0.4.0")
	testing.expect(t, !os.exists(fmt.tprintf("%s/wren.exe.old", tr.dst)), "the old file is gone when nothing holds it")
}

@(test)
install_in_the_folder_the_program_is_in :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	p := plan_of(&tr)
	p.dir = tr.src
	testing.expect_value(t, files_install(p).error, Error.None)
	testing.expect_value(t, read(fmt.tprintf("%s/wren.exe", tr.src)), "MZ program v1")   // untouched, not copied onto itself
	testing.expect(t, os.is_file(fmt.tprintf("%s/%s", tr.src, MANIFEST_NAME)), "the manifest is written")
	testing.expect(t, !os.exists(fmt.tprintf("%s/wren.exe.old", tr.src)), "nothing moved aside")
}

@(test)
install_clean_old_removes_only_the_manifest_files_old_copies :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	testing.expect_value(t, files_install(plan_of(&tr)).error, Error.None)
	_ = os.write_entire_file(fmt.tprintf("%s/wren.exe.old", tr.dst), "old")
	_ = os.write_entire_file(fmt.tprintf("%s/licenses/a.txt.old", tr.dst), "old")
	_ = os.write_entire_file(fmt.tprintf("%s/mine.old", tr.dst), "the user's")
	clean_old(tr.dst)
	testing.expect(t, !os.exists(fmt.tprintf("%s/wren.exe.old", tr.dst)), "wren.exe.old is gone")
	testing.expect(t, !os.exists(fmt.tprintf("%s/licenses/a.txt.old", tr.dst)), "a nested .old is gone")
	testing.expect(t, os.exists(fmt.tprintf("%s/mine.old", tr.dst)), "a file that is not the install's stays")
}

@(test)
install_remove_takes_only_what_the_manifest_names :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	testing.expect_value(t, files_install(plan_of(&tr)).error, Error.None)
	_ = os.write_entire_file(fmt.tprintf("%s/my_policies.txt", tr.dst), "the user's own file")
	r := files_remove(&tr.opts, tr.dst)
	testing.expect_value(t, r.result.error, Error.None)
	testing.expect_value(t, len(r.leftovers), 0)
	testing.expect(t, !os.exists(fmt.tprintf("%s/wren.exe", tr.dst)), "the executable is gone")
	testing.expect(t, !os.exists(fmt.tprintf("%s/licenses", tr.dst)), "the folders that became empty are gone")
	testing.expect(t, !os.exists(fmt.tprintf("%s/%s", tr.dst, MANIFEST_NAME)), "the manifest is gone")
	testing.expect(t, os.is_file(fmt.tprintf("%s/my_policies.txt", tr.dst)), "a user's file stays")
	testing.expect(t, os.is_dir(tr.dst), "so does the folder that holds it")
	testing.expect(t, !r.folder, "the folder is reported as kept")

	// nothing of the user's: the folder goes too
	_ = os.remove(fmt.tprintf("%s/my_policies.txt", tr.dst))
	testing.expect_value(t, files_install(plan_of(&tr)).error, Error.None)
	r = files_remove(&tr.opts, tr.dst)
	testing.expect(t, r.folder && !os.exists(tr.dst), "an install folder with nothing else in it is removed")
	testing.expect_value(t, files_remove(&tr.opts, tr.dst).result.error, Error.None)   // again: nothing to do
}

@(test)
install_manifest_cannot_reach_outside_its_folder :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	outside := fmt.tprintf("%s/outside.txt", tr.root)
	_ = os.write_entire_file(outside, "must stay")
	_ = os.make_directory_all(tr.dst)
	_ = os.write_entire_file(fmt.tprintf("%s/%s", tr.dst, MANIFEST_NAME), "version=1\nfile=../../outside.txt\nfile=/etc/passwd\nfile=C:/Windows/x.dll\nfile=inside.txt\n")
	_ = os.write_entire_file(fmt.tprintf("%s/inside.txt", tr.dst), "ours")
	files_remove(&tr.opts, tr.dst)
	testing.expect(t, os.is_file(outside), "a hand-edited manifest does not delete outside the folder")
	testing.expect(t, !os.exists(fmt.tprintf("%s/inside.txt", tr.dst)), "its good entry was removed")
}

@(test)
install_check_dir :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		good := []string{`C:\Users\someone\AppData\Local\Programs\Wren`, `D:/Tools/Wren`, `C:\Wren`}
		for g in good { testing.expectf(t, check_install_dir(g) == "", "%q is fine: %q", g, check_install_dir(g)) }
		bad := []string{``, `   `, `wren`, `\\server\share\Wren`, `C:`, `C:\`, `Wren\bin`, `C:\a<b`, `C:\a|b`, `C:\a?b`, `C:\x:y`, `C:\ok\..\..`, `C:\...`, `C:\a\ \b`, `C:\Windows\Wren`, `C:\Windows`, `C:\Program Files\Wren`, `c:\program files (x86)\Wren`}
		for b in bad { testing.expectf(t, check_install_dir(b) != "", "%q is refused", b) }
		long, _ := strings.repeat("a", 190, context.temp_allocator)
		testing.expect(t, check_install_dir(fmt.tprintf("C:\\%s", long)) != "", "a path too long is refused")
	} else {
		testing.expect(t, check_install_dir("/home/me/.local/share/wren") == "", "a home folder is fine")
		for b in ([]string{"", "wren", "/", "/usr/bin/wren", "/etc"}) { testing.expectf(t, check_install_dir(b) != "", "%q is refused", b) }
	}
}

@(test)
install_check_dir_probe :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	testing.expect_value(t, check_install_dir(tr.dst, probe = true), "")   // a folder that can be made under the scratch root
	_ = os.write_entire_file(fmt.tprintf("%s/afile", tr.root), "x")
	testing.expect(t, check_install_dir(fmt.tprintf("%s/afile/sub", tr.root), probe = true) != "", "under a file")
	testing.expect(t, !os.exists(fmt.tprintf("%s/.wren_write_probe", tr.root)), "the probe leaves nothing behind")
	testing.expect(t, !os.exists(tr.dst), "and creates nothing")
}

@(test)
install_versions :: proc(t: ^testing.T) {
	testing.expect_value(t, compare_versions("0.3.0", "0.3.0"), 0)
	testing.expect(t, compare_versions("0.3.0", "0.10.0") < 0, "numeric, not alphabetical")
	testing.expect(t, compare_versions("v1.0", "0.9.9") > 0, "a leading v")
	testing.expect_value(t, compare_versions("1.0", "1.0.0"), 0)
	testing.expect_value(t, compare_versions("0.3.0-rc1", "0.3.0"), 0)
	testing.expect(t, compare_versions("", "0.1") < 0, "unknown is oldest")
}

@(test)
install_is_inside :: proc(t: ^testing.T) {
	testing.expect(t, is_inside(`C:\Windows\System32`, `C:\Windows`), "inside")
	testing.expect(t, !is_inside(`C:\Windows`, `C:\Windows`), "not itself")
	testing.expect(t, !is_inside(`C:\WindowsApps`, `C:\Windows`), "a longer name is not inside")
	testing.expect(t, is_inside(`c:/windows/x`, `C:\Windows\`), "slash direction and case (Windows)")
}

@(test)
install_exe_name :: proc(t: ^testing.T) {
	testing.expect_value(t, exe_name_of(Identity{slug = "wren", exe_name = "wren.exe"}), "wren.exe")
	when ODIN_OS == .Windows { testing.expect_value(t, exe_name_of(Identity{slug = "wren-dev"}), "wren-dev.exe") }
}

@(test)
install_refuses_a_folder_inside_what_it_copies :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	p := plan_of(&tr)
	p.dir = fmt.tprintf("%s/demos/app", tr.src)   // would copy demos\ into itself for ever
	r := files_install(p)
	testing.expect_value(t, r.error, Error.Bad_Options)
	testing.expect(t, !os.exists(fmt.tprintf("%s/demos/app", tr.src)), "nothing was made")
}