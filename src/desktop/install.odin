package desktop

// The installed copy: the files of a Wren that is *installed* (copied into a folder of its own, by Setup) as opposed to
// a Wren that runs from wherever it was unpacked. The integration (integration.odin: shortcuts, the PATH, the browser
// registration) says how the desktop reaches a program; this file puts the program where the desktop will reach it.
//
// What an installation is:
//   * the executable and what the release package ships next to it (the shell passes that list: `Install_Plan.payload`,
//     the names of tools\package.ps1; a name that is not there is skipped, so a development build installs just wren.exe),
//     copied into the install folder (default: %LOCALAPPDATA%\Programs\Wren, "Wren Dev" for the development channel);
//   * a manifest, `wren_install.txt`, in that folder: the version, the channel and every file placed. Uninstalling
//     removes exactly those files (and the folders that become empty), never anything a user put there;
//   * the system's record of it (Windows: Settings > Apps lists it; it also says where the copy is: integration_windows.odin).
//
// Replacing a copy that is running: Windows lets a running program's file be *renamed*, not overwritten or deleted. Each
// file that is already there goes to `<name>.old` first and the new one is written in its place; `clean_old` removes the
// `.old` files at the next start of the installed copy. Uninstalling the copy that is running cannot delete its own file
// either: `files_remove` returns what is left and the caller schedules its deletion for after the process ends.

import "core:os"
import "core:strings"

MANIFEST_NAME :: "wren_install.txt"
OLD_SUFFIX    :: ".old"

// What is on the disk about an installed copy.
Install_Info :: struct {
	dir:         string,   // the install folder (owned)
	exe:         string,   // dir + the executable's name (owned)
	exe_present: bool,
	manifest:    bool,     // wren_install.txt exists and reads
	version:     string,   // from the manifest ("" when unknown; owned)
	channel:     string,   // from the manifest (owned)
	files:       int,      // the files the manifest names
	missing:     int,      // ... of which are not there any more
}

install_info_destroy :: proc(i: ^Install_Info, allocator := context.allocator) {
	delete(i.dir, allocator); delete(i.exe, allocator); delete(i.version, allocator); delete(i.channel, allocator)
	i^ = {}
}

// What is copied, from where, and where to.
Install_Plan :: struct {
	src_exe:  string,     // the program to install (absolute): the running executable
	dir:      string,     // the install folder (absolute)
	exe_name: string,     // the file name of the executable in `dir`
	payload:  []string,   // names next to src_exe (files or folders, relative; '/' or '\'): copied when they exist
	version:  string,
	channel:  string,
}

// The executable's file name on the desktop: `identity.exe_name`, else the slug (with .exe on Windows).
exe_name_of :: proc(id: Identity) -> string {
	if id.exe_name != "" { return id.exe_name }
	when ODIN_OS == .Windows { return strings.concatenate({id.slug, ".exe"}, context.temp_allocator) }
	return id.slug
}

// Where the installed copy of these options is: the folder they name, else the one the system recorded, else the default.
install_target :: proc(o: ^Options, allocator := context.temp_allocator) -> string {
	if o.install_dir != "" { return strings.clone(o.install_dir, allocator) }
	if b := platform_backend(); b != nil {
		if b.locate != nil {
			if d := b.locate(o, allocator); d != "" { return d }
		}
		if b.default_install_dir != nil { return b.default_install_dir(o, allocator) }
	}
	return ""
}

// The platform's default install folder ("" when it has none).
default_install_dir :: proc(o: ^Options, allocator := context.temp_allocator) -> string {
	if b := platform_backend(); b != nil && b.default_install_dir != nil { return b.default_install_dir(o, allocator) }
	return ""
}

// Reads the installed copy in `dir` (the manifest, the executable). `dir` "" reads nothing.
installed_info :: proc(o: ^Options, dir: string, allocator := context.allocator) -> Install_Info {
	i: Install_Info
	if dir == "" { return i }
	i.dir = strings.clone(dir, allocator)
	i.exe = strings.clone(join_path(dir, exe_name_of(o.identity)), allocator)
	i.exe_present = os.is_file(i.exe)
	m, ok := manifest_read(join_path(dir, MANIFEST_NAME), context.temp_allocator)
	if ok {
		i.manifest = true
		i.version = strings.clone(m.version, allocator)
		i.channel = strings.clone(m.channel, allocator)
		i.files = len(m.files)
		for f in m.files { if !os.is_file(join_path(dir, f)) { i.missing += 1 } }
	}
	return i
}

////////////////////////////////
// Where to install: what is refused

// "" when `dir` can be an install folder, else why not (for the field's note). Syntax and places only: nothing is
// touched unless `probe`, which also checks that a folder can be made there (the nearest folder that exists takes a file).
check_install_dir :: proc(dir: string, probe := false) -> string {
	d := strings.trim_space(dir)
	if d == "" { return "Enter the folder to install into." }
	if strings.contains_any(d, "\x00<>\"|?*") { return "The folder name has characters that Windows does not allow." }
	for r in d { if r < ' ' { return "The folder name has a control character." } }
	when ODIN_OS == .Windows {
		// a drive path, C:\dir; a colon only after the drive letter; no network share (a program is not installed there)
		if len(d) < 3 || !is_ascii_letter(d[0]) || d[1] != ':' || (d[2] != '\\' && d[2] != '/') {
			return "Use a full path on a local drive, such as C:\\Users\\you\\AppData\\Local\\Programs\\Wren."
		}
		if strings.contains(d[2:], ":") { return "The folder name has a colon after the drive letter." }
		if strings.trim_right(d[2:], "\\/") == "" { return "Pick a folder, not the root of a drive." }
	} else {
		if !strings.has_prefix(d, "/") { return "Use a full path." }
		if strings.trim_right(d, "/") == "" { return "Pick a folder, not the root." }
	}
	if len(d) > 180 { return "The path is too long (the files inside need room too)." }
	// a name made of dots and spaces cannot be made (Windows trims them)
	for part in split_path_parts(d) { if part != "" && strings.trim(part, ". ") == "" { return "A folder name cannot be only dots or spaces." } }
	if sys := system_folder_of(d); sys != "" { return strings.concatenate({"Not inside ", sys, ": that is the system's."}, context.temp_allocator) }
	if probe { return probe_dir(d) }
	return ""
}

@(private)
is_ascii_letter :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }

@(private)
split_path_parts :: proc(p: string) -> []string {
	r, _ := strings.replace_all(p, "\\", "/", context.temp_allocator)
	return strings.split(r, "/", context.temp_allocator)
}

// The nearest ancestor of `dir` that exists must be a folder that takes a file (a file made and deleted).
@(private)
probe_dir :: proc(dir: string) -> string {
	anc := strings.trim_right(dir, "\\/")
	for !os.exists(anc) {
		i := max(strings.last_index_byte(anc, '\\'), strings.last_index_byte(anc, '/'))
		if i <= 0 { return "No such drive or folder." }
		anc = strings.trim_right(anc[:i], "\\/")
		if anc == "" || (len(anc) == 2 && anc[1] == ':') { anc = strings.concatenate({anc, "\\"}, context.temp_allocator); break }
	}
	if !os.is_dir(anc) { return strings.concatenate({anc, " is a file, not a folder."}, context.temp_allocator) }
	probe := join_path(anc, ".wren_write_probe")
	if err := os.write_entire_file(probe, "x"); err != nil { return strings.concatenate({"Cannot write in ", anc, "."}, context.temp_allocator) }
	_ = os.remove(probe)
	return ""
}

// The system folder `dir` is (or is inside), for the message: "" when it is none.
@(private)
system_folder_of :: proc(dir: string) -> string {
	for sys in system_folders() {
		if sys == "" { continue }
		if same_path(dir, sys) || is_inside(dir, sys) { return sys }
	}
	return ""
}

// Is `path` inside `folder` (not equal)?
is_inside :: proc(path, folder: string) -> bool {
	a := strings.trim_right(normalize_slashes(path), "\\/")
	b := strings.trim_right(normalize_slashes(folder), "\\/")
	if len(a) <= len(b) + 1 { return false }
	when ODIN_OS == .Windows {
		if !strings.equal_fold(a[:len(b)], b) { return false }
	} else {
		if a[:len(b)] != b { return false }
	}
	return a[len(b)] == '\\' || a[len(b)] == '/'
}

@(private)
system_folders :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	when ODIN_OS == .Windows {
		for name in ([]string{"SystemRoot", "windir", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData", "CommonProgramFiles"}) {
			if v, ok := os.lookup_env(name, context.temp_allocator); ok && v != "" { append(&out, v) }
		}
	} else {
		for p in ([]string{"/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/boot", "/dev", "/proc", "/sys", "/var", "/opt", "/root"}) { append(&out, p) }
	}
	return out[:]
}

////////////////////////////////
// Manifest

@(private)
Manifest :: struct {
	version, channel, exe: string,
	files:                 [dynamic]string,   // relative, with '/'
}

@(private)
manifest_read :: proc(path: string, allocator := context.temp_allocator) -> (m: Manifest, ok: bool) {
	data, err := os.read_entire_file(path, allocator)
	if err != nil { return {}, false }
	m.files = make([dynamic]string, allocator)
	for line in strings.split_lines(string(data), allocator) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' { continue }
		eq := strings.index_byte(l, '=')
		if eq < 0 { continue }
		k, v := l[:eq], l[eq + 1:]
		switch k {
		case "version": m.version = v
		case "channel": m.channel = v
		case "exe":     m.exe = v
		case "file":
			if v != "" && !strings.contains(v, "..") && !strings.has_prefix(v, "/") && !strings.contains(v, ":") { append(&m.files, v) }   // (a hand-edited manifest never reaches outside its folder)
		}
	}
	return m, true
}

@(private)
manifest_text :: proc(plan: Install_Plan, files: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "# Written by Wren Setup: the files it placed in this folder. Uninstalling removes exactly these.\n")
	strings.write_string(&sb, "version="); strings.write_string(&sb, plan.version); strings.write_string(&sb, "\n")
	strings.write_string(&sb, "channel="); strings.write_string(&sb, plan.channel); strings.write_string(&sb, "\n")
	strings.write_string(&sb, "exe="); strings.write_string(&sb, plan.exe_name); strings.write_string(&sb, "\n")
	for f in files { strings.write_string(&sb, "file="); strings.write_string(&sb, f); strings.write_string(&sb, "\n") }
	return strings.to_string(sb)
}

////////////////////////////////
// Copy

// Copies the executable and the payload of `plan` into its folder and writes the manifest. A file that is there already
// goes to `<name>.old` first (a running program's file can be renamed, not overwritten).
files_install :: proc(plan: Install_Plan) -> Result {
	if plan.src_exe == "" || !os.is_file(plan.src_exe) { return {.No_Executable, strings.concatenate({"no such file: ", plan.src_exe}, context.temp_allocator)} }
	if plan.dir == "" || plan.exe_name == "" { return {.Bad_Options, "no install folder"} }
	if !ensure_dir(plan.dir) { return {.Io, strings.concatenate({"cannot create ", plan.dir}, context.temp_allocator)} }

	files := make([dynamic]string, context.temp_allocator)
	if r := place_file(plan.src_exe, join_path(plan.dir, plan.exe_name)); r.error != .None { return r }
	append(&files, plan.exe_name)

	src_dir := parent_dir(plan.src_exe)
	for name in plan.payload {
		rel, _ := strings.replace_all(strings.trim(name, "\\/"), "\\", "/", context.temp_allocator)
		if rel == "" || strings.contains(rel, "..") || strings.contains(rel, ":") { continue }
		if rel == plan.exe_name { continue }
		src := join_path(src_dir, rel)
		if os.is_file(src) {
			if r := place_file(src, join_path(plan.dir, rel)); r.error != .None { return r }
			append(&files, rel)
		} else if os.is_dir(src) {
			if r := place_tree(src, join_path(plan.dir, rel), rel, &files); r.error != .None { return r }
		}
	}
	text := manifest_text(plan, files[:])
	manifest := join_path(plan.dir, MANIFEST_NAME)
	if err := os.write_entire_file(manifest, text); err != nil { return {.Io, strings.concatenate({"cannot write ", manifest}, context.temp_allocator)} }
	return {}
}

@(private)
place_tree :: proc(src_dir, dst_dir, rel: string, files: ^[dynamic]string) -> Result {
	infos, err := os.read_all_directory_by_path(src_dir, context.temp_allocator)
	if err != nil { return {.Io, strings.concatenate({"cannot read ", src_dir}, context.temp_allocator)} }
	if !ensure_dir(dst_dir) { return {.Io, strings.concatenate({"cannot create ", dst_dir}, context.temp_allocator)} }
	for fi in infos {
		rel_child := strings.concatenate({rel, "/", fi.name}, context.temp_allocator)
		switch fi.type {
		case .Regular:
			if r := place_file(join_path(src_dir, fi.name), join_path(dst_dir, fi.name)); r.error != .None { return r }
			append(files, rel_child)
		case .Directory:
			if r := place_tree(join_path(src_dir, fi.name), join_path(dst_dir, fi.name), rel_child, files); r.error != .None { return r }
		case .Undetermined, .Symlink, .Named_Pipe, .Socket, .Block_Device, .Character_Device:   // (a link is not followed: it could leave the folder)
		}
	}
	return {}
}

// `dst` becomes a copy of `src`: written beside it and renamed over it, the old one kept as `.old` meanwhile.
@(private)
place_file :: proc(src, dst: string) -> Result {
	if same_path(src, dst) { return {} }   // installing into the folder the program already is in
	if !ensure_dir(parent_dir(dst)) { return {.Io, strings.concatenate({"cannot create the folder of ", dst}, context.temp_allocator)} }
	fresh := strings.concatenate({dst, ".new"}, context.temp_allocator)
	if err := os.copy_file(fresh, src); err != nil {
		_ = os.remove(fresh)
		return {.Io, strings.concatenate({"cannot copy ", src, " to ", fresh}, context.temp_allocator)}
	}
	old := strings.concatenate({dst, OLD_SUFFIX}, context.temp_allocator)
	had := os.exists(dst)
	if had {
		_ = os.remove(old)   // (an earlier .old: gone, or still in use by a program that runs it: then the rename below fails and says so)
		if err := os.rename(dst, old); err != nil {
			_ = os.remove(fresh)
			return {.Io, strings.concatenate({"cannot move ", dst, " aside (is it in use by another program?)"}, context.temp_allocator)}
		}
	}
	if err := os.rename(fresh, dst); err != nil {
		_ = os.remove(fresh)
		if had { _ = os.rename(old, dst) }   // put the old one back
		return {.Io, strings.concatenate({"cannot write ", dst}, context.temp_allocator)}
	}
	if had { _ = os.remove(old) }   // gone at once unless a running program holds it; clean_old gets it later
	return {}
}

// Removes the `.old` files an earlier replacement left in `dir` (those of the manifest's files only).
clean_old :: proc(dir: string) {
	m, ok := manifest_read(join_path(dir, MANIFEST_NAME), context.temp_allocator)
	if !ok { return }
	for f in m.files {
		old := strings.concatenate({join_path(dir, f), OLD_SUFFIX}, context.temp_allocator)
		if os.is_file(old) { _ = os.remove(old) }
	}
}

////////////////////////////////
// Remove

Remove_Files_Result :: struct {
	result:    Result,
	leftovers: [dynamic]string,   // files that could not be deleted now (a running program's), absolute; the caller's temporary allocator
	removed:   int,
	folder:    bool,              // the install folder itself is gone
}

// Deletes what the manifest of `dir` names (and what a replacement left as `.old`), then the folders that are empty, then
// the manifest, then `dir` when it is empty. A file that cannot be deleted (the running program's own, a loaded DLL) goes
// to `leftovers`, renamed to `.old` when it can be so that the name is free. Without a manifest only the executable goes.
files_remove :: proc(o: ^Options, dir: string) -> Remove_Files_Result {
	r: Remove_Files_Result
	r.leftovers = make([dynamic]string, context.temp_allocator)
	if dir == "" || !os.is_dir(dir) { return r }
	manifest_path := join_path(dir, MANIFEST_NAME)
	m, has := manifest_read(manifest_path, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	if has { for f in m.files { append(&names, f) } } else { append(&names, exe_name_of(o.identity)) }

	dirs := make(map[string]bool, 8, context.temp_allocator)
	for f in names {
		path := join_path(dir, f)
		for cand in ([]string{path, strings.concatenate({path, OLD_SUFFIX}, context.temp_allocator)}) {
			if !os.exists(cand) { continue }
			if err := os.remove(cand); err == nil {
				r.removed += 1
			} else {
				// in use: out of the way if it can be renamed, and listed for later
				moved := cand
				if !strings.has_suffix(cand, OLD_SUFFIX) {
					aside := strings.concatenate({cand, OLD_SUFFIX}, context.temp_allocator)
					_ = os.remove(aside)
					if os.rename(cand, aside) == nil { moved = aside }
				}
				append(&r.leftovers, moved)
			}
		}
		if i := strings.last_index_byte(f, '/'); i > 0 { dirs[f[:i]] = true }
	}
	// the folders of the files, deepest first; one that still holds something stays (it is not ours)
	order := make([dynamic]string, context.temp_allocator)
	for d in dirs {
		// every ancestor too
		p := d
		for p != "" {
			append(&order, p)
			i := strings.last_index_byte(p, '/')
			p = i > 0 ? p[:i] : ""
		}
	}
	for a in 1 ..< len(order) {   // longest first
		v := order[a]
		b := a - 1
		for b >= 0 && len(order[b]) < len(v) { order[b + 1] = order[b]; b -= 1 }
		order[b + 1] = v
	}
	for d in order { _ = os.remove(join_path(dir, d)) }   // (a non-empty folder refuses)

	if len(r.leftovers) == 0 {
		_ = os.remove(manifest_path)
		if os.remove(dir) == nil { r.folder = true }
	}   // else the manifest stays: the leftovers are still the install's, and the next start (clean_old) or the helper finishes
	return r
}

////////////////////////////////
// Versions

// "0.3.0", "v0.10.2-rc1" -> compared numerically part by part: <0, 0, >0. Anything after a '-' or '+' is ignored; a
// missing part is 0.
compare_versions :: proc(a, b: string) -> int {
	pa, pb := version_parts(a), version_parts(b)
	for i in 0 ..< max(len(pa), len(pb)) {
		x := i < len(pa) ? pa[i] : 0
		y := i < len(pb) ? pb[i] : 0
		if x != y { return x < y ? -1 : 1 }
	}
	return 0
}

@(private)
version_parts :: proc(v: string) -> []int {
	s := strings.trim_space(v)
	s = strings.trim_prefix(s, "v")
	if i := strings.index_any(s, "-+ "); i >= 0 { s = s[:i] }
	out := make([dynamic]int, context.temp_allocator)
	for p in strings.split(s, ".", context.temp_allocator) {
		n := 0
		for c in p { if c >= '0' && c <= '9' { n = n * 10 + int(c - '0') } else { break } }
		append(&out, n)
	}
	return out[:]
}

////////////////////////////////
// Paths

@(private)
join_path :: proc(dir, name: string) -> string {
	d := strings.trim_right(dir, "\\/")
	n, _ := strings.replace_all(name, "/", sep(), context.temp_allocator)
	return strings.concatenate({d, sep(), n}, context.temp_allocator)
}

@(private)
sep :: proc() -> string {
	when ODIN_OS == .Windows { return "\\" } else { return "/" }
}

// The folder of a path ("" when it has none).
parent_dir :: proc(path: string) -> string {
	i := max(strings.last_index_byte(path, '\\'), strings.last_index_byte(path, '/'))
	return i > 0 ? path[:i] : ""
}

////////////////////////////////
// The system's record, the deferred deletion, the PATH of a folder that goes away

// Records the installed copy in `dir` with the system (Windows: the Apps list). Nothing to do where there is no record.
record_install :: proc(o: ^Options, dir, version: string) -> Result {
	b := platform_backend()
	if b == nil { return {.Unsupported, error_text(.Unsupported)} }
	if b.record == nil { return {} }
	return b.record(o, dir, version)
}

unrecord_install :: proc(o: ^Options) -> Result {
	b := platform_backend()
	if b == nil || b.unrecord == nil { return {} }
	return b.unrecord(o)
}

// Deletes `files` (and `folder`, when it is empty) after process `pid` ends: for what a running program holds. False
// when there is no way to schedule it here.
cleanup_later :: proc(files: []string, folder: string, pid: u32) -> bool {
	b := platform_backend()
	return b != nil && b.cleanup_later != nil && b.cleanup_later(files, folder, pid)
}

// Takes `dir` out of the user's PATH whatever put it there (a folder that is about to be deleted or moved). Nothing on
// platforms that have no PATH to edit.
forget_path :: proc(o: ^Options, dir: string) -> Result {
	b := platform_backend()
	if b == nil || b.path_remove == nil { return {} }
	return b.path_remove(o, dir)
}

// The path separator of this platform.
PATH_SEP :: "\\" when ODIN_OS == .Windows else "/"

// This process's id (what a deferred deletion waits for).
current_process_id :: proc() -> u32 { return u32(os.get_pid()) }
