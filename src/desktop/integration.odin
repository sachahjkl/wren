// Package desktop: the files that make a portable program part of the user's desktop. Wren is one executable with no
// installer; integrating it means adding, in the user's own profile (never system-wide, never with administrator
// rights), what the operating system needs to list it: a launcher in the application menu, its icon, and the
// registration as a program that can open web addresses and web documents.
//
// The package is the abstract interface (`Options`, `Status`, `status`, `install`, `remove`, `open_default_apps`) and
// one implementation per platform in its own files:
//
//     integration_windows.odin   Start menu shortcut (IShellLink, with the AppUserModelID) and the registration as a
//                                candidate browser (HKCU\Software\Clients\StartMenuInternet, RegisteredApplications,
//                                a ProgID)
//     integration_linux.odin     the XDG .desktop file and the icons of the hicolor theme
//     integration_darwin.odin    nothing that makes sense for an executable outside a bundle (documented stub)
//     integration_other.odin     every other target: unsupported
//
// Nothing here is a preference of the user: the state is read from the disk (the registry) every time it is asked, so
// a box that shows it is always true. Every location is a field of `Options` (an injectable root), which is how the
// tests work on a scratch folder and a scratch registry key and never touch the real desktop.
//
// Removal deletes only what carries the mark of the program: a shortcut with its AppUserModelID, a key or a .desktop
// file that names its executable or holds its marker. A file of the same name made by something else stays.
package desktop

import "base:runtime"
import "core:os"
import "core:strings"

// What the program calls itself on the desktop. Everything platform-specific derives from these, so a second channel
// of the program (development builds) lives next to the release one without sharing a single file or key.
Identity :: struct {
	name:        string,   // "Wren": the menu entry, the browser's name in the system's lists
	key:         string,   // "Wren": registry key and ProgID stem (letters and digits)
	slug:        string,   // "wren": .desktop file, icon name, window class (lower case, hyphens)
	aumid:       string,   // "FromentSoftware.Wren": Windows AppUserModelID, the same the window declares
	description: string,   // one line, for the menu entry
	vendor:      string,   // "Froment Software"
}

// An icon of the theme (Linux): a square PNG of `size` pixels.
Icon :: struct {
	size: int,
	png:  []byte,
}

Options :: struct {
	identity:         Identity,
	exe:              string,     // the program to integrate (absolute); "" = the running executable
	register_browser: bool,       // also register as a program that opens http(s) addresses and the file types
	file_types:       []string,   // extensions with their dot (".html"): registered when register_browser

	// Where things go. The zero value is the user's real desktop; a test (or WREN_DESKTOP_* in the environment, roots_from_env)
	// points each at a scratch place.
	menu_dir:         string,     // Windows: the Programs folder of the user's Start menu
	registry_root:    string,     // Windows: the subkey of HKEY_CURRENT_USER that stands for "Software" (default "Software")
	applications_dir: string,     // Linux: $XDG_DATA_HOME/applications
	icons_dir:        string,     // Linux: $XDG_DATA_HOME/icons/hicolor
	icons:            []Icon,     // Linux: the PNGs to install (the program embeds them; Windows uses the executable's own icon)
	notify_system:    bool,       // tell the system once done (SHChangeNotify, update-desktop-database); off for scratch roots
}

// The parts of an integration, as the platforms keep them (`Backend.parts`).
Part :: enum u8 {
	Launcher,       // the shortcut in the application menu, the .desktop file
	Registration,   // the registry keys that list the program as a browser (Windows)
	Icons,          // the icons of the theme (Linux)
}
Parts :: bit_set[Part]

Part_Status :: struct {
	present: bool,     // something of the part is there (and is the program's: see the backend's marks)
	partial: bool,     // present, but some of its pieces are missing (a key of the registry, an icon size)
	target:  string,   // the program the part launches ("" when it cannot say); owned by the Status
	stale:   bool,     // present but pointing to another program than the one integrated
}

// absent: nothing of it exists. installed: every part exists and runs this program. repair: something exists and it is
// not all there, or it runs another executable (the program was moved or updated into another folder).
State :: enum u8 { Absent, Installed, Repair }

Status :: struct {
	state:      State,
	parts:      [Part]Part_Status,
	wanted:     Parts,      // the parts an installation of these options has
	stale_exe:  string,     // the first other program a part points to (owned); "" when none
	incomplete: bool,       // some wanted part is missing while another exists
	error:      Error,      // reading failed (the state is then Absent: nothing could be seen)
}

Error :: enum u8 {
	None,
	Unsupported,     // this platform has no integration (or none that makes sense)
	No_Executable,   // the executable to integrate is unknown or does not exist
	Bad_Options,     // an identity field is empty, a path is not absolute
	Io,              // a file could not be written or removed
	System,          // the system refused (COM, registry)
}

Result :: struct {
	error:  Error,
	detail: string,   // what failed, for a message; in the temporary allocator
}

error_text :: proc(e: Error) -> string {
	switch e {
	case .None:          return "ok"
	case .Unsupported:   return "desktop integration is not available on this platform"
	case .No_Executable: return "the program's executable is unknown"
	case .Bad_Options:   return "invalid options"
	case .Io:            return "a file could not be written or removed"
	case .System:        return "the system refused"
	}
	return ""
}

// What one platform implements. A backend reads and changes the disk only through the roots of `Options`.
Backend :: struct {
	name:          string,
	targets:       string,   // what the integration adds, for a label: "Start menu, default apps"
	parts:         Parts,
	status:        proc(o: ^Options, allocator: runtime.Allocator) -> Status,   // fills parts and error only (classify does the rest)
	install:       proc(o: ^Options) -> Result,
	remove:        proc(o: ^Options) -> Result,
	open_defaults: proc() -> bool,   // the system's page where the user picks the default programs
}

DEFAULT_FILE_TYPES :: ".htm,.html,.xhtml,.svg,.webp,.avif"

status_destroy :: proc(s: ^Status, allocator := context.allocator) {
	for &p in s.parts { delete(p.target, allocator) }
	delete(s.stale_exe, allocator)
	s^ = {}
}

// The options with this program's identity, the running executable, the default file types.
options_make :: proc(identity: Identity, allocator := context.temp_allocator) -> Options {
	return Options{
		identity = identity,
		exe = executable_path(allocator),
		register_browser = true,
		file_types = split_list(DEFAULT_FILE_TYPES, allocator),
		notify_system = true,
	}
}

// A copy of `o` that owns its strings (for a job on another thread). The icons are shared: they are the program's own
// embedded data.
options_clone :: proc(o: Options, allocator := context.allocator) -> Options {
	c := o   // (the identity's strings are the program's constants)
	c.exe = clone_or_empty(o.exe, allocator)
	c.menu_dir = clone_or_empty(o.menu_dir, allocator)
	c.registry_root = clone_or_empty(o.registry_root, allocator)
	c.applications_dir = clone_or_empty(o.applications_dir, allocator)
	c.icons_dir = clone_or_empty(o.icons_dir, allocator)
	types := make([]string, len(o.file_types), allocator)
	for ft, i in o.file_types { types[i] = strings.clone(ft, allocator) }
	c.file_types = types
	return c
}

options_destroy :: proc(o: ^Options, allocator := context.allocator) {
	delete(o.exe, allocator); delete(o.menu_dir, allocator); delete(o.registry_root, allocator)
	delete(o.applications_dir, allocator); delete(o.icons_dir, allocator)
	for ft in o.file_types { delete(ft, allocator) }
	delete(o.file_types, allocator)
	o^ = {}
}

// The path of the running executable ("" when the system cannot say).
executable_path :: proc(allocator := context.temp_allocator) -> string {
	p, err := os.get_executable_path(allocator)
	if err != nil { return "" }
	return p
}

// Every part of the backend that these options ask for.
parts_wanted :: proc(b: ^Backend, o: ^Options) -> Parts {
	w := b.parts
	if !o.register_browser { w -= {.Registration} }
	if len(o.icons) == 0 { w -= {.Icons} }   // nothing to install: nothing to miss
	return w
}

// What the platform's integration of `o` looks like on the disk. `o.exe` is the program it should run.
status :: proc(o: ^Options, allocator := context.allocator) -> Status {
	b := platform_backend()
	if b == nil { return Status{error = .Unsupported} }
	if e := validate(o, need_exe = false); e.error != .None { return Status{error = e.error} }
	s := b.status(o, allocator)
	classify(&s, parts_wanted(b, o), allocator)
	return s
}

install :: proc(o: ^Options) -> Result {
	b := platform_backend()
	if b == nil { return {.Unsupported, error_text(.Unsupported)} }
	if e := validate(o, need_exe = true); e.error != .None { return e }
	return b.install(o)
}

remove :: proc(o: ^Options) -> Result {
	b := platform_backend()
	if b == nil { return {.Unsupported, error_text(.Unsupported)} }
	if e := validate(o, need_exe = false); e.error != .None { return e }
	return b.remove(o)
}

// Opens the system's own page of default programs; false when there is none.
open_default_apps :: proc() -> bool {
	b := platform_backend()
	return b != nil && b.open_defaults != nil && b.open_defaults()
}

// True when this platform can integrate at all (the shell hides the box otherwise).
supported :: proc() -> bool { return platform_backend() != nil }

// What the integration adds on this platform, for a label: "Start menu, default apps".
targets :: proc() -> string {
	b := platform_backend()
	return b == nil ? "" : b.targets
}

// True when the system has a page where the user picks the default programs.
has_default_apps_page :: proc() -> bool {
	b := platform_backend()
	return b != nil && b.open_defaults != nil
}

@(private)
validate :: proc(o: ^Options, need_exe: bool) -> Result {
	id := o.identity
	if id.name == "" || id.key == "" || id.slug == "" || id.aumid == "" { return {.Bad_Options, "the identity has an empty field"} }
	for r in id.key { if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') { return {.Bad_Options, "identity.key is letters and digits only"} } }
	for r in id.slug { if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') { return {.Bad_Options, "identity.slug is lower case letters, digits and hyphens"} } }
	if strings.contains_any(id.name, "\\/:*?\"<>|\x00") { return {.Bad_Options, "identity.name is used in a file name"} }
	if o.exe == "" { o.exe = executable_path() }
	if need_exe {
		if o.exe == "" { return {.No_Executable, error_text(.No_Executable)} }
		if !os.is_file(o.exe) { return {.No_Executable, strings.concatenate({"no such file: ", o.exe}, context.temp_allocator)} }
	}
	return {}
}

// Works out `state`, `wanted`, `incomplete` and `stale_exe` from the parts a backend read.
classify :: proc(s: ^Status, wanted: Parts, allocator := context.allocator) {
	s.wanted = wanted
	any_present, all_wanted, any_stale := false, true, false
	for p in Part {
		ps := &s.parts[p]
		if ps.present { any_present = true }
		if ps.present && ps.stale {
			any_stale = true
			if s.stale_exe == "" && ps.target != "" { s.stale_exe = strings.clone(ps.target, allocator) }
		}
		if p in wanted && (!ps.present || ps.partial) { all_wanted = false }
	}
	switch {
	case !any_present:                      s.state = .Absent
	case all_wanted && !any_stale:          s.state = .Installed
	case:                                   s.state = .Repair
	}
	s.incomplete = any_present && !all_wanted
}

// The shell's one-line description of a status ("Installed", "points to C:\old\wren.exe", ...), for logs and the
// command line.
describe :: proc(s: ^Status) -> string {
	switch s.state {
	case .Absent:    return "absent"
	case .Installed: return "installed"
	case .Repair:
		if s.stale_exe != "" { return strings.concatenate({"to repair: points to ", s.stale_exe}, context.temp_allocator) }
		return "to repair: incomplete"
	}
	return ""
}

// Same file? Windows paths ignore case and slash direction; the others are exact.
same_path :: proc(a, b: string) -> bool {
	if a == "" || b == "" { return false }
	when ODIN_OS == .Windows {
		return strings.equal_fold(normalize_slashes(a), normalize_slashes(b))
	} else {
		return a == b
	}
}

@(private)
normalize_slashes :: proc(s: string) -> string {
	if strings.index_byte(s, '/') < 0 { return s }
	r, _ := strings.replace_all(s, "/", "\\", context.temp_allocator)
	return r
}

// "a, b;c" -> ["a", "b", "c"] (commas, semicolons and spaces separate; empty items go).
split_list :: proc(v: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := v
	for len(rest) > 0 {
		i := strings.index_any(rest, ", \t;")
		item := strings.trim_space(i < 0 ? rest : rest[:i])
		rest = i < 0 ? "" : rest[i + 1:]
		if item != "" { append(&out, item) }
	}
	return out[:]
}

// An extension as the registry and the MIME table want it: lower case, with its dot.
normalize_extension :: proc(ext: string, allocator := context.temp_allocator) -> string {
	e := strings.to_lower(strings.trim_space(ext), allocator)
	if e == "" || e == "." { return "" }
	return e[0] == '.' ? e : strings.concatenate({".", e}, allocator)
}

@(private)
clone_or_empty :: proc(s: string, allocator: runtime.Allocator) -> string { return s == "" ? "" : strings.clone(s, allocator) }
