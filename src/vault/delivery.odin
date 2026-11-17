package vault

// Where the helper is, and how a release gets the one it pins (src/md/features/vault-helper-delivery.md):
//   a development build   build/vault/wren-vault (beside build/wren's folder), else beside it: as it is
//   in the Nix store      beside it (the package's): as it is
//   a release             beside it, when its size and SHA-256 are the pin's (vault.version); else state Installing: the
//                         shell downloads the pinned program (Hooks.download), install_work places it, and the setup
//                         job runs again
// The checks and the placement run on the blocking pool; the state changes on the loop thread.

import "core:fmt"
import "core:os"
import "core:strings"
import "wb:base"
import "wb:host"
import i18n "toolkit:i18n"
import update "toolkit:update"
import vault_pin "wb:vault/pin"

// What the setup job is given to find the helper (Helper_Options, and the pin's program of this system).
@(private)
Helper_Find :: struct {
	development: bool,
	dir:         string,   // ("": the executable's)
	path:        string,   // tests: the helper, as it is
	asset:       vault_pin.Asset,
	pinned:      bool,     // the pin has a program for this system
}

// Why no helper was found.
@(private)
Missing :: enum u8 {
	None,
	Development,   // a development build without its own: wrentool build vault
	Package,       // the Nix package has none beside the browser
	Not_Pinned,    // a release whose pin names no program for this system
	Test_Path,     // the tests' path is no file
}

@(private)
missing_words :: proc(m: Missing) -> string {
	switch m {
	case .None:        return ""
	case .Development: return i18n.tr("This development build has no helper: build it with wrentool build vault.")
	case .Package:     return i18n.tr("This package has no wren-vault beside Wren.")
	case .Not_Pinned:  return i18n.tr("This build of Wren names no helper for this system.")
	case .Test_Path:   return i18n.tr("The helper is not there.")
	}
	return ""
}

// The helper to run, or where the pinned one goes when there is none (`target`), or why there is none. Off the loop
// thread: it reads the disk (a release's helper is read whole and hashed). Strings in `allocator`.
locate_helper :: proc(f: Helper_Find, allocator := context.allocator) -> (helper, target: string, missing: Missing) {
	if f.path != "" {
		if os.is_file(f.path) { return strings.clone(f.path, allocator), "", .None }
		return "", "", .Test_Path
	}
	dir := f.dir
	if dir == "" {
		exe_dir, err := os.get_executable_directory(context.temp_allocator)
		if err != nil { return "", "", f.development ? .Development : .Not_Pinned }
		dir = exe_dir
	}
	beside := join_path({dir, HELPER_NAME})
	if f.development {
		for c in ([]string{join_path({dir, "vault", HELPER_NAME}), beside}) {
			if os.is_file(c) { return strings.clone(c, allocator), "", .None }
		}
		return "", "", .Development
	}
	if strings.has_prefix(dir, "/nix/store/") {
		return os.is_file(beside) ? strings.clone(beside, allocator) : "", "", .Package
	}
	if !f.pinned { return "", "", .Not_Pinned }
	// (what an earlier placement left: the helper moved aside, a download never put in place)
	update.remove_leftovers(beside)
	if helper_is_pinned(beside, f.asset) { return strings.clone(beside, allocator), "", .None }
	return "", strings.clone(beside, allocator), .None
}

// Whether the file at `path` is the pinned program: its size, then its SHA-256.
helper_is_pinned :: proc(path: string, a: vault_pin.Asset) -> bool {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil || info.size != a.size { return false }
	data, read := os.read_entire_file(path, context.temp_allocator)
	if read != nil { return false }
	return update.sha256_hex(data, context.temp_allocator) == a.sha256
}

// Puts `data`, the pinned program as `m` says it, at `path`: update.place when a file is there (moved aside on Windows), else
// written beside as <path>.update, read back and renamed (update.place moves the program in place aside first: there is none).
place_helper :: proc(path: string, m: update.Manifest, data: []byte) -> update.Error {
	if os.exists(path) { return update.place(path, data, m) }
	if e := update.check_binary(m, data); e != .None { return e }
	if !update.is_program(data, m.platform) || m.platform != update.PLATFORM { return .Not_A_Program }
	next := fmt.tprintf("%s.update", path)
	if os.write_entire_file(next, data) != nil { _ = os.remove(next); return .Not_Written }
	back, err := os.read_entire_file(next, context.temp_allocator)
	if err != nil || update.check_binary(m, back) != .None { _ = os.remove(next); return .Not_Written_Whole }
	when ODIN_OS != .Windows { _ = os.chmod(next, os.Permissions_Default_File | {.Execute_User, .Execute_Group, .Execute_Other}) }
	if os.rename(next, path) != nil { _ = os.remove(next); return .Not_Placed }
	return .None
}

@(private)
Install_Job :: struct {
	v:      ^Vault,
	gen:    u64,
	target: string,            // owned
	m:      update.Manifest,   // owned
	data:   []byte,            // owned
	err:    update.Error,
}

// Loop thread: the shell's answer to Hooks.download. `data`: the body (valid for the call); `problem`: why it failed
// ("" when it came). Anything else than Installing drops it.
vault_helper_downloaded :: proc(v: ^Vault, data: []byte, problem: string) {
	if v.state != .Installing { return }
	if problem != "" {
		set_message(v, fmt.tprintf(i18n.tr("The helper could not be downloaded: %s"), problem))
		set_state(v, .Helper_Missing)
		return
	}
	a, _ := vault_pin.asset_of(v.helper_options.pin, update.PLATFORM)
	j := new(Install_Job, base.process_allocator())
	j^ = {v = v, gen = v.setup_gen, target = strings.clone(v.install_target, base.process_allocator()),
		m = vault_pin.manifest_of(v.helper_options.pin.version, a, base.process_allocator()), data = make([]byte, len(data), base.process_allocator())}
	copy(j.data, data)
	v.jobs += 1
	host.run_blocking(v.pool, install_work, install_done, j, install_discard)
}

@(private)
install_work :: proc(data: rawptr) {
	j := (^Install_Job)(data)
	j.err = place_helper(j.target, j.m, j.data)
}

@(private)
install_done :: proc(data: rawptr) {
	j := (^Install_Job)(data)
	v := j.v
	v.jobs -= 1
	defer install_free(j)
	if j.gen != v.setup_gen || v.state != .Installing { return }
	if j.err != .None {
		set_message(v, fmt.tprintf(i18n.tr("The helper could not be put beside Wren: %s"), update.error_text(j.err)))
		set_state(v, .Helper_Missing)
		return
	}
	// (the setup job finds it now, and checks it once more)
	enable(v)
}

@(private)
install_discard :: proc(data: rawptr) {
	j := (^Install_Job)(data)
	j.v.jobs -= 1
	install_free(j)
}

@(private)
install_free :: proc(j: ^Install_Job) {
	context.allocator = base.process_allocator()
	delete(j.target)
	update.manifest_destroy(&j.m)
	delete(j.data)
	free(j)
}
