package browser

import "core:fmt"
import "core:os"
import "core:testing"
import "wb:base"
import "wb:config"
import update "toolkit:update"
import wren_update "wb:update"

// A fake "program": 1 MiB starting as a program of this system does (the MZ header on Windows, ELF elsewhere).
@(private = "file")
fake_program :: proc(seed: byte) -> []byte {
	data := make([]byte, update.MIN_BINARY, context.temp_allocator)
	for i in 0 ..< len(data) { data[i] = byte(i * 13) ~ seed }
	copy(data, ODIN_OS == .Windows ? "MZ" : "\x7fELF")
	return data
}

@(private = "file")
manifest_of :: proc(version: string, data: []byte) -> update.Manifest {
	return {
		version = version, platform = update.PLATFORM,
		file = update.expected_file_name(wren_update.PRODUCT, version, update.PLATFORM, context.temp_allocator),
		sha256 = update.sha256_hex(data, context.temp_allocator), size = i64(len(data)),
	}
}

// A folder of its own (the platform's temporary folder) holding "wren.exe", the old program. The caller removes it (base.remove_tree).
@(private = "file")
installed_copy :: proc(t: ^testing.T) -> (dir, exe: string, old: []byte) {
	dir = fmt.tprintf("%s/wren-update-test-%s", base.temp_dir(context.temp_allocator), base.unique_name(context.temp_allocator))
	testing.expect(t, os.make_directory_all(dir) == nil, "the test folder")
	exe = fmt.tprintf("%s/wren.exe", dir)
	old = fake_program(1)
	testing.expect(t, os.write_entire_file(exe, old) == nil, "the old program")
	return
}

@(private = "file")
same :: proc(path: string, want: []byte) -> bool {
	got, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil && string(got) == string(want)
}

// What is in the folder: no half-written file may be left whatever happened.
@(private = "file")
names_in :: proc(dir: string) -> string {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return "?" }
	out := ""
	for e in entries { out = fmt.tprintf("%s%s ", out, e.name) }
	return out
}

// An App whose preferences are registered (test_app leaves app.prefs empty).
@(private = "file")
app_with_prefs :: proc(t: ^testing.T) -> ^App {
	app := test_app(t)
	app.prefs = config.prefs_make()
	testing.cleanup(t, proc(p: rawptr) { config.prefs_destroy(&(^App)(p).prefs) }, app)
	register_desktop_shell_prefs(&app.prefs)
	return app
}

@(test)
a_verified_update_replaces_the_program :: proc(t: ^testing.T) {
	dir, exe, old := installed_copy(t)
	defer base.remove_tree(dir)
	fresh := fake_program(2)
	problem := update_apply(exe, manifest_of("0.6.29", fresh), fresh)
	testing.expect_value(t, problem, "")
	testing.expect(t, same(exe, fresh), "wren.exe is the new program")
	// the old one is kept aside while it can be (deleted at the next start, or at once when the system allows it), the staging file is gone
	testing.expect(t, !os.exists(fmt.tprintf("%s/wren.exe.update", dir)), "no staging file left")
	testing.expect(t, !os.exists(fmt.tprintf("%s/wren.exe.new", dir)), "no .new file left")
	if os.exists(fmt.tprintf("%s/wren.exe.old", dir)) { testing.expect(t, same(fmt.tprintf("%s/wren.exe.old", dir), old), "the old program is the .old") }
}

@(test)
a_second_update_over_a_first_one_works :: proc(t: ^testing.T) {
	dir, exe, _ := installed_copy(t)
	defer base.remove_tree(dir)
	a, b := fake_program(2), fake_program(3)
	testing.expect_value(t, update_apply(exe, manifest_of("0.6.29", a), a), "")
	testing.expect_value(t, update_apply(exe, manifest_of("0.6.30", b), b), "")   // (a .old of the first may still be there: it is replaced)
	testing.expect(t, same(exe, b), "wren.exe is the newest")
}

@(test)
a_wrong_checksum_changes_nothing :: proc(t: ^testing.T) {
	dir, exe, old := installed_copy(t)
	defer base.remove_tree(dir)
	fresh := fake_program(2)
	m := manifest_of("0.6.29", fresh)
	tampered := make([]byte, len(fresh), context.temp_allocator)
	copy(tampered, fresh)
	tampered[len(tampered) / 3] ~= 0x01   // one bit
	testing.expect(t, update_apply(exe, m, tampered) != "", "refused")
	testing.expect(t, same(exe, old), "the program is untouched")
	testing.expectf(t, names_in(dir) == "wren.exe ", "nothing else in the folder: %s", names_in(dir))
}

@(test)
a_wrong_length_changes_nothing :: proc(t: ^testing.T) {
	dir, exe, old := installed_copy(t)
	defer base.remove_tree(dir)
	fresh := fake_program(2)
	m := manifest_of("0.6.29", fresh)
	for data in ([][]byte{fresh[:len(fresh) - 1], fresh[:len(fresh) / 2], nil}) {
		testing.expect(t, update_apply(exe, m, data) != "", "a truncated download is refused")
	}
	longer := make([]byte, len(fresh) + 1, context.temp_allocator)
	copy(longer, fresh)
	testing.expect(t, update_apply(exe, m, longer) != "", "a longer download is refused")
	testing.expect(t, same(exe, old), "the program is untouched")
	testing.expectf(t, names_in(dir) == "wren.exe ", "nothing else in the folder: %s", names_in(dir))
}

@(test)
what_is_not_a_program_of_this_system_is_refused :: proc(t: ^testing.T) {
	dir, exe, old := installed_copy(t)
	defer base.remove_tree(dir)
	// signed and checksummed, but not an executable (a manifest that named the wrong file)
	notexe := make([]byte, update.MIN_BINARY, context.temp_allocator)
	for i in 0 ..< len(notexe) { notexe[i] = 'x' }
	testing.expect(t, update_apply(exe, manifest_of("0.6.29", notexe), notexe) != "", "refused")
	testing.expect(t, same(exe, old), "the program is untouched")
}

@(test)
a_missing_target_is_refused :: proc(t: ^testing.T) {
	fresh := fake_program(2)
	testing.expect(t, update_apply("", manifest_of("0.6.29", fresh), fresh) != "", "no path")
	nowhere := fmt.tprintf("%s/wren-update-test-%s/wren.exe", base.temp_dir(context.temp_allocator), base.unique_name(context.temp_allocator))
	testing.expect(t, update_apply(nowhere, manifest_of("0.6.29", fresh), fresh) != "", "no such program")
	testing.expect(t, !os.exists(fmt.tprintf("%s.update", nowhere)), "and nothing was written")
}

@(test)
a_folder_that_cannot_be_written_leaves_the_program :: proc(t: ^testing.T) {
	// the program is a directory entry that cannot be replaced: a folder where the file should be
	dir := fmt.tprintf("%s/wren-update-test-%s", base.temp_dir(context.temp_allocator), base.unique_name(context.temp_allocator))
	defer base.remove_tree(dir)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/wren.exe", dir)) == nil, "a folder named wren.exe")
	fresh := fake_program(2)
	testing.expect(t, update_apply(fmt.tprintf("%s/wren.exe", dir), manifest_of("0.6.29", fresh), fresh) != "", "refused: it is not a file")
}

@(test)
leftovers_of_an_update_are_removed_at_start :: proc(t: ^testing.T) {
	dir, exe, old := installed_copy(t)
	defer base.remove_tree(dir)
	for suffix in ([]string{".old", ".update"} ) { _ = os.write_entire_file(fmt.tprintf("%s%s", exe, suffix), []byte{1, 2, 3}) }
	update.remove_leftovers(exe)
	testing.expectf(t, names_in(dir) == "wren.exe ", "only the program is left: %s", names_in(dir))
	testing.expect(t, same(exe, old), "the program itself is untouched")
}

@(test)
only_a_release_may_install :: proc(t: ^testing.T) {
	app := app_with_prefs(t)
	ok, why := update_install_allowed(app)
	// the tests run a development build: it is not a release, and it says so
	if IS_DEV_BUILD {
		testing.expect(t, !ok, "a development build does not install")
		testing.expect(t, why != "", "and says why")
	}
	if !update_install_supported() { testing.expect(t, !ok, "not available on this platform") }
	// the preference that the tests of the updater use lifts only the development-build rule
	if IS_DEV_BUILD && update_install_supported() && wren_update.PRODUCT.public_key != "" && APP_VERSION_LABEL == "" {
		testing.expect_value(t, config.set_from_string(&app.prefs, "browser.update.allow_development_build", "true", .User), config.Set_Error.None)
		ok2, _ := update_install_allowed(app)
		testing.expect(t, ok2, "the test preference allows it")
	}
}

@(test)
the_download_address_is_one_the_person_may_set :: proc(t: ^testing.T) {
	app := app_with_prefs(t)
	set :: proc(app: ^App, v: string) { _ = config.set_from_string(&app.prefs, "update.base_url", v, .User) }
	testing.expect_value(t, update_base_url(app), UPDATE_DOWNLOAD_BASE)
	set(app, "https://mirror.example/wren/")
	testing.expect_value(t, update_base_url(app), "https://mirror.example/wren/")
	set(app, "http://127.0.0.1:8765/updates/")
	testing.expect_value(t, update_base_url(app), "http://127.0.0.1:8765/updates/")
	// refused, the default is used: no trailing slash, plain http to elsewhere, other schemes, a space
	for bad in ([]string{"https://mirror.example/wren", "http://mirror.example/wren/", "file:///C:/x/", "ftp://x/", "https://a b/", "javascript:/", "//x/"}) {
		set(app, bad)
		testing.expectf(t, update_base_url(app) == UPDATE_DOWNLOAD_BASE, "%q is not accepted", bad)
	}
}

@(test)
the_key_comes_from_the_build_unless_the_tests_name_one :: proc(t: ^testing.T) {
	app := app_with_prefs(t)
	testing.expect_value(t, update_public_key(app), wren_update.PRODUCT.public_key)
	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.update.public_key", "abc", .User), config.Set_Error.None)
	testing.expect_value(t, update_public_key(app), "abc")
}

@(test)
the_page_says_what_is_known :: proc(t: ^testing.T) {
	app := app_with_prefs(t)
	s := update_summary(app)
	testing.expect(t, s.shown, "the Updates section is shown")
	testing.expect(t, s.text != "", "it says something")
	testing.expect(t, !s.can_install, "nothing verified: nothing to install")
	testing.expect(t, s.can_check, "but it can ask")
	app.upd.phase = .Installed
	app.upd.installed = "9.9.9"
	defer { app.upd.installed = ""; app.upd.phase = .Idle }
	testing.expect(t, update_summary(app).text != s.text, "an installed update is said")
}
