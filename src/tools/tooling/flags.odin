package tooling

import "core:fmt"
import "core:strconv"
import "core:strings"

// A command's flags, as test_all reads its own: `-Name` or `-Name value`, the case does not matter; what does not begin with a dash is a positional argument.
Flags :: struct {
	values: map[string]string,   // by lower-case name, with its dash; a switch has ""
	rest:   []string,
}

// `spec` names the flags, space-separated: `-Check -Version= -Out=` (`=`: it takes a value). A repeated flag joins its values with a comma. ok false: said on standard error.
parse_flags :: proc(args: []string, spec: string, allocator := context.allocator) -> (f: Flags, ok: bool) {
	context.allocator = allocator
	known := make(map[string]bool, context.temp_allocator)   // the name: does it take a value
	for s in strings.fields(spec, context.temp_allocator) {
		name := strings.to_lower(strings.trim_suffix(s, "="), context.temp_allocator)
		known[name] = strings.has_suffix(s, "=")
	}
	rest := make([dynamic]string)
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if !strings.has_prefix(a, "-") || len(a) == 1 { append(&rest, a); continue }
		name := strings.to_lower(a)
		takes, is_known := known[name]
		if !is_known { fmt.eprintfln("unknown flag %s (%s)", a, spec); return f, false }
		value := ""
		if takes {
			i += 1
			if i >= len(args) { fmt.eprintfln("%s takes a value", a); return f, false }
			value = args[i]
		}
		if was, again := f.values[name]; again { value = fmt.aprintf("%s,%s", was, value) }
		f.values[name] = value
	}
	f.rest = rest[:]
	return f, true
}

flag_has :: proc(f: Flags, name: string) -> bool { return strings.to_lower(name, context.temp_allocator) in f.values }

flag :: proc(f: Flags, name: string, otherwise := "") -> string {
	if v, ok := f.values[strings.to_lower(name, context.temp_allocator)]; ok { return v }
	return otherwise
}

// A flag's list: `-Only a,b -Only c`.
flag_list :: proc(f: Flags, name: string, otherwise: []string = nil) -> []string {
	v, ok := f.values[strings.to_lower(name, context.temp_allocator)]
	if !ok { return otherwise }
	return strings.split(v, ",")
}

flag_int :: proc(f: Flags, name: string, otherwise: int) -> int {
	v, ok := f.values[strings.to_lower(name, context.temp_allocator)]
	if !ok { return otherwise }
	n, good := strconv.parse_int(v)
	return good ? n : otherwise
}
