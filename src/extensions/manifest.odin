package extensions

// manifest.json (Manifest V3) into a typed Manifest (docs/extensions.md, section 3.3):
//   * an unknown key is a warning, a known key of a wrong type an error (the extension does not load);
//   * manifest_version other than 3 is an error;
//   * a permission Wren does not implement is a warning: its namespace is absent;
//   * every file the manifest names must be in the package (the index), and stay inside it.
// Every string of the Manifest is allocated with the allocator given (the image's arena).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "wb:base"

Flavour :: enum u8 { Chrome, Firefox }
FLAVOUR_NAMES := [Flavour]string{.Chrome = "chrome", .Firefox = "firefox"}

Run_At :: enum u8 { Document_Idle, Document_Start, Document_End }
World :: enum u8 { Isolated, Main }

Icon :: struct { size: int, path: string }

Action :: struct {
	popup: string,   // default_popup (a path of the package, "" when none)
	title: string,   // default_title
	icons: []Icon,   // default_icon, by size
}

Content_Script :: struct {
	matches, exclude_matches: []Pattern,
	include_globs, exclude_globs: []string,
	js, css:           []string,
	run_at:            Run_At,
	all_frames:        bool,
	match_about_blank: bool,
	match_origin_as_fallback: bool,
	world:             World,
}

Web_Resource :: struct {
	resources:       []string,    // globs of package paths
	matches:         []Pattern,
	use_dynamic_url: bool,
}

Command :: struct { name, description, key: string }

Manifest :: struct {
	text:             string,   // the manifest's JSON, comments removed and messages put in: runtime.getManifest
	name, short_name, version, version_name, description, author, homepage_url: string,
	default_locale:   string,
	minimum_chrome_version: string,
	key:              string,
	gecko_id:         string,
	background_worker: string,       // background.service_worker
	background_module: bool,         // background.type "module"
	background_scripts: []string,    // background.scripts (an event page: the Firefox flavour)
	has_action:       bool,
	action:           Action,
	icons:            []Icon,
	content_scripts:  []Content_Script,
	permissions, optional_permissions: []string,
	host_permissions, optional_host_permissions: []Pattern,
	csp_pages:        string,        // content_security_policy.extension_pages ("" : the default)
	csp_sandbox:      string,
	sandbox_pages:    []string,
	web_accessible:   []Web_Resource,
	commands:         []Command,
	options_page:     string,        // options_ui.page, else options_page
	flavour:          Flavour,
}

Problem :: struct {
	error: bool,
	text:  string,
}

// The permissions Wren implements: a namespace exists for each (with its context rules). Others are warned of.
IMPLEMENTED_PERMISSIONS := [?]string{"storage", "unlimitedStorage", "tabs", "alarms", "activeTab", "idle", "offscreen", "clipboardRead", "clipboardWrite", "scripting", "webNavigation"}

// The keys Wren reads or knowingly ignores (a key of neither list is warned of).
@(private = "file")
KNOWN_KEYS := [?]string{
	"manifest_version", "name", "short_name", "version", "version_name", "description", "author", "homepage_url", "icons",
	"default_locale", "minimum_chrome_version", "key", "browser_specific_settings", "background", "action", "content_scripts",
	"permissions", "optional_permissions", "host_permissions", "optional_host_permissions", "content_security_policy",
	"sandbox", "commands", "web_accessible_resources", "options_page", "options_ui",
	// read by other browsers, ignored here (docs/extensions.md, section 1)
	"storage", "side_panel", "sidebar_action", "update_url", "offline_enabled", "incognito", "minimum_edge_version",
	"externally_connectable", "declarative_net_request", "devtools_page", "chrome_url_overrides", "oauth2",
}

@(private = "file")
Manifest_Parser :: struct {
	problems:  ^[dynamic]Problem,
	files:     ^map[string]File_Entry,   // nil: files are not checked (a manifest alone, in tests of the parser)
	allocator: runtime.Allocator,
	failed:    bool,
}

@(private = "file")
mf_err :: proc(p: ^Manifest_Parser, format: string, args: ..any) {
	append(p.problems, Problem{error = true, text = fmt.aprintf(format, ..args, allocator = p.allocator)})
	p.failed = true
}

@(private = "file")
mf_warn :: proc(p: ^Manifest_Parser, format: string, args: ..any) {
	append(p.problems, Problem{error = false, text = fmt.aprintf(format, ..args, allocator = p.allocator)})
}

@(private = "file")
mf_clone :: proc(p: ^Manifest_Parser, s: string) -> string { return strings.clone(s, p.allocator) }

// A string member (absent: "", true). A wrong type is an error.
@(private = "file")
mf_string :: proc(p: ^Manifest_Parser, o: json.Object, key: string, where_ := "") -> string {
	v, ok := o[key]
	if !ok { return "" }
	s, sok := v.(json.String)
	if !sok { mf_err(p, "%s%s must be a string", where_, key); return "" }
	return mf_clone(p, s)
}

@(private = "file")
mf_bool :: proc(p: ^Manifest_Parser, o: json.Object, key: string, where_ := "") -> bool {
	v, ok := o[key]
	if !ok { return false }
	b, bok := v.(json.Boolean)
	if !bok { mf_err(p, "%s%s must be true or false", where_, key); return false }
	return b
}

// A list of strings (absent: nil). A wrong type is an error.
@(private = "file")
mf_strings :: proc(p: ^Manifest_Parser, o: json.Object, key: string, where_ := "") -> []string {
	v, ok := o[key]
	if !ok { return nil }
	arr, aok := v.(json.Array)
	if !aok { mf_err(p, "%s%s must be a list of strings", where_, key); return nil }
	out := make([]string, len(arr), p.allocator)
	for e, i in arr {
		s, sok := e.(json.String)
		if !sok { mf_err(p, "%s%s[%d] must be a string", where_, key, i); return nil }
		out[i] = mf_clone(p, s)
	}
	return out
}

@(private = "file")
mf_patterns :: proc(p: ^Manifest_Parser, o: json.Object, key: string, where_ := "") -> []Pattern {
	list := mf_strings(p, o, key, where_)
	out := make([dynamic]Pattern, 0, len(list), p.allocator)
	for s in list {
		pat, ok := pattern_parse(s)
		if !ok { mf_warn(p, "%s%s: %q is not a match pattern; it is left out", where_, key, s); continue }
		append(&out, pat)
	}
	return out[:]
}

// A file the manifest names: normalised, and it must be in the package.
@(private = "file")
mf_file :: proc(p: ^Manifest_Parser, path, what: string) -> string {
	if path == "" { return "" }
	n, ok := package_path_normalize(path, p.allocator)
	if !ok || n == "" { mf_err(p, "%s: %q leaves the package", what, path); return "" }
	if p.files != nil {
		if _, found := p.files^[n]; !found { mf_err(p, "%s: %q is not in the package", what, path); return "" }
	}
	return n
}

@(private = "file")
mf_files :: proc(p: ^Manifest_Parser, list: []string, what: string) -> []string {
	for &s in list { s = mf_file(p, s, what) }
	return list
}

// "icons" / "default_icon": {"16": "a.png", ...} or one path.
@(private = "file")
mf_icons :: proc(p: ^Manifest_Parser, v: json.Value, what: string) -> []Icon {
	out := make([dynamic]Icon, 0, 4, p.allocator)
	#partial switch x in v {
	case json.String:
		append(&out, Icon{size = 0, path = mf_file(p, x, what)})
	case json.Object:
		for size_text, pv in x {
			ps, ok := pv.(json.String)
			if !ok { mf_err(p, "%s[%q] must be a path", what, size_text); continue }
			n, nok := strconv.parse_int(size_text, 10)
			if !nok || n <= 0 { mf_warn(p, "%s: %q is not a size; it is left out", what, size_text); continue }
			// (an icon that is absent does not stop the extension: Chrome shows a letter for it)
			if np, okp := package_path_normalize(ps, p.allocator); okp && (p.files == nil || np in p.files^) {
				append(&out, Icon{size = n, path = np})
			} else {
				mf_warn(p, "%s: %q is not in the package", what, ps)
			}
		}
	case:
		mf_err(p, "%s must be a path or an object of paths by size", what)
	}
	// smallest first: the toolbar takes the first one at least as large as it needs
	for i in 1 ..< len(out) {
		for k := i; k > 0 && out[k - 1].size > out[k].size; k -= 1 { out[k - 1], out[k] = out[k], out[k - 1] }
	}
	return out[:]
}

// Parses `text` (comments allowed). `files`: the package's index, for the checks of the files named (nil: no check).
// `problems` gets the errors and warnings (allocated with `allocator`); ok is false when an error stops the extension.
manifest_parse :: proc(text: string, files: ^map[string]File_Entry, s: ^Settings, problems: ^[dynamic]Problem, allocator := context.allocator) -> (m: Manifest, ok: bool) {
	p := Manifest_Parser{problems = problems, files = files, allocator = allocator}
	if len(text) > s.manifest_max_bytes { mf_err(&p, "manifest.json is larger than extensions.manifest.max_bytes"); return {}, false }
	stripped := json_strip_comments(text, context.temp_allocator)
	root, perr := json.parse_string(stripped, .JSON, false, context.temp_allocator)
	if perr != .None { mf_err(&p, "manifest.json is not valid JSON (%v)", perr); return {}, false }
	o, isobj := root.(json.Object)
	if !isobj { mf_err(&p, "manifest.json must be a JSON object"); return {}, false }
	m.text = mf_clone(&p, stripped)

	for key in o {
		known := false
		for k in KNOWN_KEYS { if k == key { known = true; break } }
		if !known { mf_warn(&p, "unknown key %q is ignored", key) }
	}

	if mv, has := o["manifest_version"]; has {
		n, isnum := mv.(json.Float)
		if !isnum || n != 3 { mf_err(&p, "manifest_version must be 3 (Manifest V2 is not supported)") }
	} else {
		mf_err(&p, "manifest_version is missing (it must be 3)")
	}
	m.name = mf_string(&p, o, "name")
	if m.name == "" && !p.failed { mf_err(&p, "name is missing") }
	m.short_name = mf_string(&p, o, "short_name")
	m.version = mf_string(&p, o, "version")
	if m.version == "" && !p.failed { mf_err(&p, "version is missing") }
	m.version_name = mf_string(&p, o, "version_name")
	m.description = mf_string(&p, o, "description")
	m.homepage_url = mf_string(&p, o, "homepage_url")
	if av, has := o["author"]; has {
		#partial switch a in av {
		case json.String: m.author = mf_clone(&p, a)
		case json.Object: m.author = mf_string(&p, a, "email", "author.")
		case: mf_err(&p, "author must be a string or an object")
		}
	}
	m.default_locale = mf_string(&p, o, "default_locale")
	m.minimum_chrome_version = mf_string(&p, o, "minimum_chrome_version")
	m.key = mf_string(&p, o, "key")
	if iv, has := o["icons"]; has { m.icons = mf_icons(&p, iv, "icons") }

	// browser_specific_settings.gecko: the Firefox flavour (with no service worker), and its id
	if bv, has := o["browser_specific_settings"]; has {
		if bo, bok := bv.(json.Object); bok {
			if gv, ghas := bo["gecko"]; ghas {
				if go_, gok := gv.(json.Object); gok { m.gecko_id = mf_string(&p, go_, "id", "browser_specific_settings.gecko.") } else { mf_err(&p, "browser_specific_settings.gecko must be an object") }
			}
		} else {
			mf_err(&p, "browser_specific_settings must be an object")
		}
	}

	if bv, has := o["background"]; has {
		bo, bok := bv.(json.Object)
		if !bok {
			mf_err(&p, "background must be an object")
		} else {
			m.background_worker = mf_file(&p, mf_string(&p, bo, "service_worker", "background."), "background.service_worker")
			m.background_scripts = mf_files(&p, mf_strings(&p, bo, "scripts", "background."), "background.scripts")
			m.background_module = mf_string(&p, bo, "type", "background.") == "module"
			if _, persistent := bo["persistent"]; persistent { mf_warn(&p, "background.persistent is a Manifest V2 key; it is ignored") }
		}
	}
	m.flavour = m.gecko_id != "" && m.background_worker == "" ? .Firefox : .Chrome
	if m.flavour == .Firefox { mf_warn(&p, "this is a Firefox build: Wren runs the Chrome build of extensions for now (the Firefox flavour comes later)") }

	if av, has := o["action"]; has {
		ao, aok := av.(json.Object)
		if !aok {
			mf_err(&p, "action must be an object")
		} else {
			m.has_action = true
			m.action.popup = mf_file(&p, mf_string(&p, ao, "default_popup", "action."), "action.default_popup")
			m.action.title = mf_string(&p, ao, "default_title", "action.")
			if iv, ihas := ao["default_icon"]; ihas { m.action.icons = mf_icons(&p, iv, "action.default_icon") }
		}
	}
	if _, has := o["browser_action"]; has { mf_warn(&p, "browser_action is a Manifest V2 key; it is ignored") }

	if cv, has := o["content_scripts"]; has {
		arr, aok := cv.(json.Array)
		switch {
		case !aok:
			mf_err(&p, "content_scripts must be a list")
		case len(arr) > s.content_scripts_max:
			mf_err(&p, "content_scripts has more entries than extensions.content_scripts.max_entries")
		case:
			list := make([dynamic]Content_Script, 0, len(arr), allocator)
			for e, i in arr {
				eo, eok := e.(json.Object)
				if !eok { mf_err(&p, "content_scripts[%d] must be an object", i); continue }
				w := fmt.tprintf("content_scripts[%d].", i)
				cs: Content_Script
				cs.matches = mf_patterns(&p, eo, "matches", w)
				if len(cs.matches) == 0 { mf_warn(&p, "%smatches is empty: the entry never runs", w) }
				cs.exclude_matches = mf_patterns(&p, eo, "exclude_matches", w)
				cs.include_globs = mf_strings(&p, eo, "include_globs", w)
				cs.exclude_globs = mf_strings(&p, eo, "exclude_globs", w)
				cs.js = mf_files(&p, mf_strings(&p, eo, "js", w), fmt.tprintf("%sjs", w))
				cs.css = mf_files(&p, mf_strings(&p, eo, "css", w), fmt.tprintf("%scss", w))
				cs.all_frames = mf_bool(&p, eo, "all_frames", w)
				cs.match_about_blank = mf_bool(&p, eo, "match_about_blank", w)
				cs.match_origin_as_fallback = mf_bool(&p, eo, "match_origin_as_fallback", w)
				switch mf_string(&p, eo, "run_at", w) {
				case "document_start": cs.run_at = .Document_Start
				case "document_end":   cs.run_at = .Document_End
				case "", "document_idle": cs.run_at = .Document_Idle
				case: mf_err(&p, "%srun_at must be document_start, document_end or document_idle", w)
				}
				switch mf_string(&p, eo, "world", w) {
				case "MAIN": cs.world = .Main
				case "", "ISOLATED": cs.world = .Isolated
				case: mf_err(&p, "%sworld must be ISOLATED or MAIN", w)
				}
				append(&list, cs)
			}
			m.content_scripts = list[:]
		}
	}

	m.permissions = mf_strings(&p, o, "permissions")
	m.optional_permissions = mf_strings(&p, o, "optional_permissions")
	for perm in m.permissions {
		implemented := false
		for k in IMPLEMENTED_PERMISSIONS { if k == perm { implemented = true; break } }
		if !implemented { mf_warn(&p, "the permission %q is not implemented yet: its API is absent", perm) }
	}
	m.host_permissions = mf_patterns(&p, o, "host_permissions")
	m.optional_host_permissions = mf_patterns(&p, o, "optional_host_permissions")

	if cv, has := o["content_security_policy"]; has {
		#partial switch c in cv {
		case json.Object:
			m.csp_pages = mf_string(&p, c, "extension_pages", "content_security_policy.")
			m.csp_sandbox = mf_string(&p, c, "sandbox", "content_security_policy.")
		case json.String:
			mf_err(&p, "content_security_policy must be an object in Manifest V3 (extension_pages, sandbox)")
		case:
			mf_err(&p, "content_security_policy must be an object")
		}
		if m.csp_pages != "" {
			if why := csp_refusal(m.csp_pages); why != "" { mf_err(&p, "content_security_policy.extension_pages: %s", why) }
		}
	}

	if sv, has := o["sandbox"]; has {
		if so, sok := sv.(json.Object); sok { m.sandbox_pages = mf_files(&p, mf_strings(&p, so, "pages", "sandbox."), "sandbox.pages") } else { mf_err(&p, "sandbox must be an object") }
	}

	if wv, has := o["web_accessible_resources"]; has {
		arr, aok := wv.(json.Array)
		if !aok {
			mf_err(&p, "web_accessible_resources must be a list")
		} else {
			list := make([dynamic]Web_Resource, 0, len(arr), allocator)
			for e, i in arr {
				eo, eok := e.(json.Object)
				if !eok { mf_err(&p, "web_accessible_resources[%d] must be an object (Manifest V3)", i); continue }
				w := fmt.tprintf("web_accessible_resources[%d].", i)
				r := Web_Resource{resources = mf_strings(&p, eo, "resources", w), matches = mf_patterns(&p, eo, "matches", w), use_dynamic_url = mf_bool(&p, eo, "use_dynamic_url", w)}
				for &res in r.resources { res = strings.trim_prefix(res, "/") }
				append(&list, r)
			}
			m.web_accessible = list[:]
		}
	}

	if cv, has := o["commands"]; has {
		co, cok := cv.(json.Object)
		if !cok {
			mf_err(&p, "commands must be an object")
		} else {
			list := make([dynamic]Command, 0, len(co), allocator)
			for name, e in co {
				eo, eok := e.(json.Object)
				if !eok { mf_err(&p, "commands.%s must be an object", name); continue }
				c := Command{name = mf_clone(&p, name), description = mf_string(&p, eo, "description", "commands.")}
				if kv, khas := eo["suggested_key"]; khas {
					#partial switch k in kv {
					case json.String: c.key = mf_clone(&p, k)
					case json.Object:
						c.key = mf_string(&p, k, "default", "commands.suggested_key.")
						when ODIN_OS == .Linux { if l := mf_string(&p, k, "linux", "commands.suggested_key."); l != "" { c.key = l } }
						when ODIN_OS == .Windows { if wk := mf_string(&p, k, "windows", "commands.suggested_key."); wk != "" { c.key = wk } }
					case: mf_err(&p, "commands.%s.suggested_key must be a string or an object", name)
					}
				}
				append(&list, c)
			}
			m.commands = list[:]
		}
	}

	if ov, has := o["options_ui"]; has {
		if oo, ook := ov.(json.Object); ook { m.options_page = mf_file(&p, mf_string(&p, oo, "page", "options_ui."), "options_ui.page") } else { mf_err(&p, "options_ui must be an object") }
	}
	if m.options_page == "" { m.options_page = mf_file(&p, mf_string(&p, o, "options_page"), "options_page") }

	if m.minimum_chrome_version != "" {
		need, _ := strconv.parse_int(strings.split(m.minimum_chrome_version, ".", context.temp_allocator)[0], 10)
		if need > CHROME_MAJOR { mf_err(&p, "it needs Chrome %s; Wren is compatible with Chrome %d", m.minimum_chrome_version, CHROME_MAJOR) }
	}
	return m, !p.failed
}

// The Chrome major version of Wren's user agent (src/net/settings.odin: Chrome/148.0.0.0): minimum_chrome_version is
// compared with it.
CHROME_MAJOR :: 148

// The policy of extension pages when the manifest gives none (Chrome's).
DEFAULT_PAGE_CSP :: "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"

// Why a manifest's extension_pages policy is refused ("" : accepted): a remote script source, 'unsafe-eval' or
// 'unsafe-inline' for scripts would let a page of the extension run code that is not in its package.
csp_refusal :: proc(policy: string) -> string {
	rest := policy
	for directive in strings.split_iterator(&rest, ";") {
		words := strings.fields(directive, context.temp_allocator)
		if len(words) == 0 { continue }
		name := base.ascii_lower(words[0], context.temp_allocator)
		if name != "script-src" && name != "script-src-elem" && name != "default-src" && name != "worker-src" { continue }
		for w in words[1:] {
			lw := base.ascii_lower(w, context.temp_allocator)
			switch {
			case lw == "'unsafe-eval'", lw == "'unsafe-inline'":
				return fmt.tprintf("%s allows %s", name, w)
			case lw == "'self'", lw == "'none'", lw == "'wasm-unsafe-eval'", strings.has_prefix(lw, "'sha"), strings.has_prefix(lw, "'nonce-"):
			case strings.has_prefix(lw, "http://localhost"), strings.has_prefix(lw, "http://127.0.0.1"):
			case:
				return fmt.tprintf("%s allows the remote source %s", name, w)
			}
		}
	}
	return ""
}

// Whether the manifest asks for `perm` (a permission of the list "permissions").
manifest_has_permission :: proc(m: ^Manifest, perm: string) -> bool {
	for x in m.permissions { if x == perm { return true } }
	return false
}
