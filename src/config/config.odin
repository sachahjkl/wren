// Package config: the preference registry behind about:config.
//
// Every tunable of the browser is a named, typed, documented preference with a default, optional bounds or a list of
// choices, and a layered source (default < user file < command line < policy). Subsystems declare their preferences next
// to the code that uses them (`Def` tables in each package's settings file), the shell registers them all, and the
// registry then provides:
//
//   * validated changes (type, range, choices, locks) from about:config, the command line (--pref name=value), the
//     profile file and an enterprise policy file;
//   * change notification by name prefix, so a running browser applies a new value without a restart when the subsystem
//     supports it (`restart` marks the ones that do not);
//   * persistence of user changes only (defaults are never written), atomically.
//
// Reads never go through string lookups on hot paths: callers resolve a name to a `Ref` once, or copy the values they need
// into a plain Settings struct and refresh it from an observer.
package config

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

Kind :: enum u8 { Bool, Int, Float, String }

Value :: struct {
	b: bool,
	i: i64,
	f: f64,
	s: string,   // owned by the registry
}

Def :: struct {
	name:        string,      // dotted, lower case: "network.max_connections_per_host"
	description: string,
	kind:        Kind,
	default:     Value,       // `s` must be a literal or otherwise outlive the registry
	min, max:    f64,         // Int / Float bounds, only when `bounded`
	bounded:     bool,
	choices:     []string,    // String: the allowed values (empty = free text)
	unit:        string,      // shown by about:config: "ms", "bytes", ...
	restart:     bool,        // takes effect at the next start
	bytes:       bool,        // Int: accepts K / M / G suffixes when typed
	category:    string,      // grouping in about:config; defaults to the first name segment
}

Source :: enum u8 { Default, User, Command_Line, Policy }

Entry :: struct {
	def:    Def,
	value:  Value,
	source: Source,
	locked: bool,   // set by policy: the user cannot change it
	// the user layer's value (text, owned) while a higher layer (command line, policy) decides the effective one: it is
	// what the profile file keeps, so a run with --pref or under a policy does not erase it
	user_text: string,
	has_user:  bool,
}

Ref :: distinct int
NO_REF :: Ref(-1)

Observer :: struct {
	prefix: string,   // owned
	fn:     proc(user: rawptr, name: string, p: ^Prefs),
	user:   rawptr,
	id:     int,
}

Prefs :: struct {
	entries:   [dynamic]Entry,
	index:     map[string]int,
	pending:   map[string]Pending,   // values read before their definition was registered
	observers: [dynamic]Observer,
	next_observer: int,
	version:   u64,                  // bumped on every change
	dirty:     bool,                 // user-visible state changed since the last save
	allocator: runtime.Allocator,
}

@(private)
Pending :: struct {
	value: [Source]string,   // owned; one slot per layer so none is lost when several arrive before registration
	has:   [Source]bool,
}

Set_Error :: enum u8 {
	None,
	Unknown,
	Locked,
	Bad_Type,      // the text does not parse as the preference's type
	Out_Of_Range,
	Not_A_Choice,
}

set_error_text :: proc(e: Set_Error) -> string {
	switch e {
	case .None: return ""
	case .Unknown: return "unknown preference"
	case .Locked: return "set by policy or on the command line for this run"
	case .Bad_Type: return "not a valid value for this type"
	case .Out_Of_Range: return "out of range"
	case .Not_A_Choice: return "not one of the allowed values"
	}
	return ""
}

prefs_make :: proc(allocator := context.allocator) -> Prefs {
	return Prefs{
		entries = make([dynamic]Entry, allocator), index = make(map[string]int, allocator),
		pending = make(map[string]Pending, allocator), observers = make([dynamic]Observer, allocator), allocator = allocator,
	}
}

prefs_destroy :: proc(p: ^Prefs) {
	a := p.allocator
	for &e in p.entries { delete(e.value.s, a); delete(e.user_text, a) }
	delete(p.entries)
	delete(p.index)
	for k, v in p.pending { delete(k, a); for s in v.value { delete(s, a) } }
	delete(p.pending)
	for o in p.observers { delete(o.prefix, a) }
	delete(p.observers)
	p^ = {}
}

////////////////////////////////
// Registration

// Adds definitions. Registering a name again with the same kind is a no-op; a different kind is a programming error.
register :: proc(p: ^Prefs, defs: []Def) {
	for d in defs {
		if i, exists := p.index[d.name]; exists {
			assert(p.entries[i].def.kind == d.kind, "preference registered twice with different kinds")
			continue
		}
		e := Entry{def = d, value = d.default}
		if e.def.category == "" { e.def.category = first_segment(d.name) }
		e.value.s = strings.clone(d.default.s, p.allocator)
		idx := len(p.entries)
		append(&p.entries, e)
		p.index[e.def.name] = idx
		// a value waiting for this definition (profile file or command line read before registration)
		if pv, found := p.pending[d.name]; found {
			key, _ := delete_key(&p.pending, d.name)
			delete(key, p.allocator)
			layers := [3]Source{.User, .Command_Line, .Policy}
			for src in layers {
				if pv.has[src] { set_from_string(p, d.name, pv.value[src], src) }
				delete(pv.value[src], p.allocator)
			}
		}
	}
}

@(private)
first_segment :: proc(name: string) -> string {
	if i := strings.index_byte(name, '.'); i >= 0 { return name[:i] }
	return name
}

ref_of :: proc(p: ^Prefs, name: string) -> Ref {
	if i, ok := p.index[name]; ok { return Ref(i) }
	return NO_REF
}

entry :: proc(p: ^Prefs, r: Ref) -> ^Entry { return &p.entries[int(r)] }

// Registered names, sorted (for about:config).
sorted_names :: proc(p: ^Prefs, allocator := context.temp_allocator) -> []string {
	names := make([dynamic]string, allocator)
	for e in p.entries { append(&names, e.def.name) }
	slice.sort(names[:])
	return names[:]
}

////////////////////////////////
// Reads. An unknown name or a kind mismatch is a programming error: it asserts (and a release build without asserts would
// fail the bounds check).

get_bool :: proc(p: ^Prefs, r: Ref) -> bool {
	assert(r != NO_REF && p.entries[int(r)].def.kind == .Bool)
	return p.entries[int(r)].value.b
}
get_int :: proc(p: ^Prefs, r: Ref) -> i64 {
	assert(r != NO_REF && p.entries[int(r)].def.kind == .Int)
	return p.entries[int(r)].value.i
}
get_float :: proc(p: ^Prefs, r: Ref) -> f64 {
	assert(r != NO_REF && p.entries[int(r)].def.kind == .Float)
	return p.entries[int(r)].value.f
}
get_string :: proc(p: ^Prefs, r: Ref) -> string {
	assert(r != NO_REF && p.entries[int(r)].def.kind == .String)
	return p.entries[int(r)].value.s
}

// By name: convenient for rare reads; hot paths resolve a Ref once.
bool_of :: proc(p: ^Prefs, name: string) -> bool { return get_bool(p, ref_of(p, name)) }
int_of :: proc(p: ^Prefs, name: string) -> i64 { return get_int(p, ref_of(p, name)) }
float_of :: proc(p: ^Prefs, name: string) -> f64 { return get_float(p, ref_of(p, name)) }
string_of :: proc(p: ^Prefs, name: string) -> string { return get_string(p, ref_of(p, name)) }

////////////////////////////////
// Writes

// Parses `text` according to the preference's kind (Int accepts `_` separators and K/M/G for byte-valued prefs).
parse_value :: proc(d: Def, text: string) -> (v: Value, err: Set_Error) {
	t := strings.trim_space(text)
	switch d.kind {
	case .Bool:
		switch strings.to_lower(t, context.temp_allocator) {
		case "true", "1", "yes", "on":  v.b = true
		case "false", "0", "no", "off": v.b = false
		case: return {}, .Bad_Type
		}
	case .Int:
		s, _ := strings.replace_all(t, "_", "", context.temp_allocator)
		mult := i64(1)
		if d.bytes && len(s) > 1 {
			switch s[len(s) - 1] {
			case 'k', 'K': mult, s = 1 << 10, s[:len(s) - 1]
			case 'm', 'M': mult, s = 1 << 20, s[:len(s) - 1]
			case 'g', 'G': mult, s = 1 << 30, s[:len(s) - 1]
			}
		}
		n, ok := strconv.parse_i64(s, 10)
		if !ok { return {}, .Bad_Type }
		if mult > 1 && (n > max(i64) / mult || n < min(i64) / mult) { return {}, .Out_Of_Range }
		v.i = n * mult
		if d.bounded && (f64(v.i) < d.min || f64(v.i) > d.max) { return {}, .Out_Of_Range }
	case .Float:
		f, ok := strconv.parse_f64(t)
		if !ok || math.is_nan(f) || math.is_inf(f) { return {}, .Bad_Type }
		v.f = f
		if d.bounded && (f < d.min || f > d.max) { return {}, .Out_Of_Range }
	case .String:
		v.s = text   // not trimmed: a string may legitimately have spaces
		if len(d.choices) > 0 {
			found := false
			for c in d.choices { if c == text { found = true; break } }
			if !found { return {}, .Not_A_Choice }
		}
	}
	return v, .None
}

// Sets by name from text, with full validation. Precedence: policy > command line > user > default. A value from a
// lower layer is refused (`.Locked`) while a higher layer owns the preference for this run; a policy value also locks it.
set_from_string :: proc(p: ^Prefs, name: string, text: string, source: Source) -> Set_Error {
	i, ok := p.index[name]
	if !ok {
		// not registered (yet): remember it per layer, it applies when the definition arrives
		if source != .Default {
			pv, had := p.pending[name]
			if !had { p.pending[strings.clone(name, p.allocator)] = Pending{} }
			pv = p.pending[name]
			delete(pv.value[source], p.allocator)
			pv.value[source] = strings.clone(text, p.allocator)
			pv.has[source] = true
			p.pending[name] = pv
		}
		return .Unknown
	}
	e := &p.entries[i]
	if source == .User && (e.locked || e.source == .Command_Line || e.source == .Policy) {
		// a higher layer decides for this run: the user's value is kept for the profile file (validated first)
		if _, err := parse_value(e.def, text); err != .None { return err }
		keep_user_text(p, e, text)
		return .Locked
	}
	if e.locked && source != .Policy { return .Locked }
	v, err := parse_value(e.def, text)
	if err != .None { return err }
	// a higher layer over the user's value: that value stays the user's
	if source > .User && e.source == .User { keep_user_text(p, e, value_text(e.def, e.value)) }
	assign(p, i, v, source)
	if source == .Policy { e.locked = true }
	return .None
}
@(private)
keep_user_text :: proc(p: ^Prefs, e: ^Entry, text: string) {
	s := strings.clone(text, p.allocator)
	delete(e.user_text, p.allocator)
	e.user_text, e.has_user = s, true
}

@(private)
assign :: proc(p: ^Prefs, i: int, v: Value, source: Source) {
	e := &p.entries[i]
	changed := e.value.b != v.b || e.value.i != v.i || e.value.f != v.f || e.value.s != v.s
	new_s := strings.clone(v.s, p.allocator)
	delete(e.value.s, p.allocator)
	e.value = v
	e.value.s = new_s
	if source != e.source || changed {
		e.source = source
		p.version += 1
		if source == .User { p.dirty = true }
		notify(p, e.def.name)
	}
}

set_bool :: proc(p: ^Prefs, r: Ref, v: bool, source := Source.User) -> Set_Error { return set_from_string(p, p.entries[int(r)].def.name, v ? "true" : "false", source) }
set_int :: proc(p: ^Prefs, r: Ref, v: i64, source := Source.User) -> Set_Error {
	return set_from_string(p, p.entries[int(r)].def.name, fmt.tprintf("%d", v), source)
}
set_string :: proc(p: ^Prefs, r: Ref, v: string, source := Source.User) -> Set_Error { return set_from_string(p, p.entries[int(r)].def.name, v, source) }

// Back to the default (the user layer only: command line and policy values stay).
reset :: proc(p: ^Prefs, name: string) -> Set_Error {
	i, ok := p.index[name]
	if !ok { return .Unknown }
	e := &p.entries[i]
	if e.has_user {
		delete(e.user_text, p.allocator)
		e.user_text, e.has_user = "", false
		p.dirty = true
	}
	if e.source == .Policy || e.locked { return .Locked }
	if e.source == .Command_Line { return .None }   // this run keeps the command line's value
	if e.source == .Default { return .None }
	assign(p, i, e.def.default, .Default)
	p.dirty = true
	return .None
}

is_default :: proc(p: ^Prefs, r: Ref) -> bool { return p.entries[int(r)].source == .Default }

////////////////////////////////
// Observers

// `fn` runs (synchronously, on the changing thread) after any preference whose name starts with `prefix` changes.
// Returns an id for `unwatch`.
watch :: proc(p: ^Prefs, prefix: string, fn: proc(user: rawptr, name: string, p: ^Prefs), user: rawptr) -> int {
	p.next_observer += 1
	append(&p.observers, Observer{prefix = strings.clone(prefix, p.allocator), fn = fn, user = user, id = p.next_observer})
	return p.next_observer
}

unwatch :: proc(p: ^Prefs, id: int) {
	for o, i in p.observers {
		if o.id == id { delete(o.prefix, p.allocator); ordered_remove(&p.observers, i); return }
	}
}

@(private)
notify :: proc(p: ^Prefs, name: string) {
	// an observer may add or remove observers: iterate a copy of the ids
	ids := make([dynamic]int, context.temp_allocator)
	for o in p.observers { if strings.has_prefix(name, o.prefix) { append(&ids, o.id) } }
	for id in ids {
		for o in p.observers {
			if o.id == id { o.fn(o.user, name, p); break }
		}
	}
}

////////////////////////////////
// Layers: command line, profile file, policy file

// `--pref name=value` pairs (anything else is ignored: the caller handles its own flags). Returns the arguments that were
// not preferences, so the shell can treat the rest as its own.
apply_args :: proc(p: ^Prefs, args: []string, allocator := context.allocator) -> (rest: [dynamic]string, errors: [dynamic]string) {
	rest = make([dynamic]string, allocator)
	errors = make([dynamic]string, allocator)
	i := 0
	for i < len(args) {
		a := args[i]
		spec := ""
		switch {
		case a == "--pref" && i + 1 < len(args): spec = args[i + 1]; i += 2
		case strings.has_prefix(a, "--pref="):   spec = a[len("--pref="):]; i += 1
		case:
			append(&rest, a)
			i += 1
			continue
		}
		eq := strings.index_byte(spec, '=')
		if eq <= 0 { append(&errors, fmt.aprintf("--pref %q: expected name=value", spec, allocator = allocator)); continue }
		name, value := spec[:eq], spec[eq + 1:]
		if err := set_from_string(p, name, value, .Command_Line); err != .None && err != .Unknown {
			append(&errors, fmt.aprintf("--pref %s: %s", name, set_error_text(err), allocator = allocator))
		}
	}
	return
}

USER_MAGIC :: "wbprefs 1"

// Writes the user's changes (and only those). Atomic: a crash leaves the previous file intact.
save_user :: proc(p: ^Prefs, path: string) -> bool {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, USER_MAGIC)
	strings.write_byte(&sb, '\n')
	for name in sorted_names(p) {
		e := &p.entries[p.index[name]]
		switch {
		case e.source == .User: fmt.sbprintf(&sb, "%s\t%s\n", name, escape(value_text(e.def, e.value)))
		case e.has_user:        fmt.sbprintf(&sb, "%s\t%s\n", name, escape(e.user_text))
		}
	}
	// values for preferences that are not registered in this run must survive a round trip
	for name, pv in p.pending {
		if pv.has[.User] { fmt.sbprintf(&sb, "%s\t%s\n", name, escape(pv.value[.User])) }
	}
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, transmute([]byte)strings.to_string(sb)); err != nil { return false }
	if err := os.rename(tmp, path); err != nil {
		_ = os.remove(path)
		if err2 := os.rename(tmp, path); err2 != nil { return false }
	}
	p.dirty = false
	return true
}

// Reads a preference file as `source` (User for the profile, Policy for the enterprise file). Missing file = no changes.
// `applied` counts the lines accepted, including those waiting for their definition.
load_file :: proc(p: ^Prefs, path: string, source: Source) -> (applied: int, problems: [dynamic]string) {
	problems = make([dynamic]string, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return 0, problems }
	text := string(data)
	first := true
	for line in strings.split_lines_iterator(&text) {
		if first {
			first = false
			// a byte-order mark (a file saved by Notepad) is not part of the magic
			magic := strings.trim_prefix(line, "\xEF\xBB\xBF")
			if magic == USER_MAGIC || magic == "wbpolicy 1" { continue }
			append(&problems, fmt.aprintf("%s: not a preference file", path, allocator = context.temp_allocator))
			return
		}
		if line == "" || line[0] == '#' { continue }
		tab := strings.index_byte(line, '\t')
		if tab <= 0 { append(&problems, fmt.aprintf("malformed line %q", line, allocator = context.temp_allocator)); continue }
		name, value := line[:tab], unescape(line[tab + 1:])
		e := set_from_string(p, name, value, source)
		switch e {
		case .None: applied += 1
		case .Unknown: applied += 1   // not registered yet: kept, applied when the definition arrives
		case .Locked, .Bad_Type, .Out_Of_Range, .Not_A_Choice:
			append(&problems, fmt.aprintf("%s: %s", name, set_error_text(e), allocator = context.temp_allocator))
		}
	}
	return
}

@(private)
value_text :: proc(d: Def, v: Value) -> string {
	switch d.kind {
	case .Bool:   return v.b ? "true" : "false"
	case .Int:    return fmt.tprintf("%d", v.i)
	case .Float:  return fmt.tprintf("%v", v.f)
	case .String: return v.s
	}
	return ""
}

// Text form of the current value (about:config).
value_string :: proc(p: ^Prefs, r: Ref, allocator := context.temp_allocator) -> string {
	e := &p.entries[int(r)]
	return strings.clone(value_text(e.def, e.value), allocator)
}

default_string :: proc(p: ^Prefs, r: Ref, allocator := context.temp_allocator) -> string {
	e := &p.entries[int(r)]
	return strings.clone(value_text(e.def, e.def.default), allocator)
}

@(private)
escape :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		switch c {
		case '\\': strings.write_string(&sb, "\\\\")
		case '\n': strings.write_string(&sb, "\\n")
		case '\r': strings.write_string(&sb, "\\r")
		case '\t': strings.write_string(&sb, "\\t")
		case: strings.write_byte(&sb, c)
		}
	}
	return strings.to_string(sb)
}

@(private)
unescape :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 'n': strings.write_byte(&sb, '\n')
			case 'r': strings.write_byte(&sb, '\r')
			case 't': strings.write_byte(&sb, '\t')
			case: strings.write_byte(&sb, s[i])
			}
			continue
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}
