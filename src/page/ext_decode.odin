package page

// What the generated extension API (ext_api_generated.odin, from api/ext_<namespace>.widl by src/tools/bindgen) is
// built on: the shape of its tables, the matcher of a call's arguments to a signature, and the decoders of JSON values.
// Every decoder has the form proc(v: json.Value, out: ^T, err: ^string) -> bool: false with a message in err, which
// the callers above it prefix with the property, the index or the parameter, so the caller learns where it failed:
//   Error in invocation of tabs.create(object createProperties): Error at parameter 'createProperties': Error at
//   property 'url': Invalid type: expected string, found number.
// Values live in the temp allocator, as the parsed arguments do.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"

// The kinds of context a member allows ([Contexts=] of the description).
Ext_Contexts :: bit_set[Ext_Kind; u8]

// A routed method: the gate's facts, the trampoline that decodes and calls the implementation, and the decoder alone
// (the conformance cases call it).
Ext_Method :: struct {
	name:       string,
	permission: string,         // "" : none
	contexts:   Ext_Contexts,
	action:     bool,           // the manifest must have an action
	invoke:     proc(x: ^Ext_Call),
	check:      proc(args: json.Array) -> string,   // "" : the arguments decode; else the error
}

// An event, or a member the realm answers itself ([Local]: runtime.getURL, i18n.getMessage, runtime.id).
Ext_Member :: struct {
	name:       string,
	permission: string,
	contexts:   Ext_Contexts,
	action:     bool,
}

// The constants of a namespace (a JSON object: its const values and its enums as {KEY: "value"}).
Ext_Namespace_Info :: struct {
	name:      string,
	constants: string,
}

// The same member names as the generator's (src/tools/bindgen/idl/ext_check.odin): the generated specs name them.
Ext_Json_Kind :: enum u8 { Null, Bool, Number, String, Array, Object }
Ext_Json_Kinds :: bit_set[Ext_Json_Kind; u8]

// One parameter for the matcher: the JSON kinds it takes, and whether it may be left out.
Ext_Param_Spec :: struct {
	kinds:    Ext_Json_Kinds,
	optional: bool,
}

ext_json_kind :: proc(v: json.Value) -> Ext_Json_Kind {
	switch _ in v {
	case nil, json.Null:            return .Null
	case json.Boolean:              return .Bool
	case json.Integer, json.Float:  return .Number
	case json.String:               return .String
	case json.Array:                return .Array
	case json.Object:               return .Object
	}
	return .Null
}

@(private = "file")
EXT_JSON_KIND_NAMES := [Ext_Json_Kind]string{.Null = "null", .Bool = "boolean", .Number = "number", .String = "string", .Array = "array", .Object = "object"}

// Puts each argument in the slot of its parameter, as Chrome does: an optional parameter is left out when the argument
// there does not have its kind (tabs.update(props) is tabs.update(undefined, props)); null in place of an optional one
// leaves it out. The first assignment that uses every argument wins (the parameters are tried in order, each optional
// one first taken, then left out). False: no assignment fits ("No matching signature").
ext_match :: proc(args: json.Array, params: []Ext_Param_Spec, out: []json.Value) -> bool {
	step :: proc(args: json.Array, ai: int, params: []Ext_Param_Spec, pi: int, out: []json.Value) -> bool {
		if pi == len(params) { return ai == len(args) }
		p := params[pi]
		if ai < len(args) {
			k := ext_json_kind(args[ai])
			if k in p.kinds {
				out[pi] = args[ai]
				if step(args, ai + 1, params, pi + 1, out) { return true }
			} else if k == .Null && p.optional {
				out[pi] = nil
				if step(args, ai + 1, params, pi + 1, out) { return true }
			}
		}
		if !p.optional { return false }
		out[pi] = nil
		return step(args, ai, params, pi + 1, out)
	}
	for &o in out { o = nil }
	return step(args, 0, params, 0, out)
}

ext_signature_error :: proc(signature: string) -> string {
	return fmt.tprintf("Error in invocation of %s: No matching signature.", signature)
}

ext_param_error :: proc(signature, param, err: string) -> string {
	return fmt.tprintf("Error in invocation of %s: Error at parameter '%s': %s", signature, param, err)
}

ext_type_error :: proc(err: ^string, expected: string, v: json.Value) -> bool {
	found := EXT_JSON_KIND_NAMES[ext_json_kind(v)]
	if n, ok := ext_number(v); ok && n == math.trunc(n) && expected != "number" { found = "integer" }
	err^ = fmt.tprintf("Invalid type: expected %s, found %s.", expected, found)
	return false
}

ext_at_property :: proc(err: ^string, name: string) -> bool {
	err^ = fmt.tprintf("Error at property '%s': %s", name, err^)
	return false
}

ext_at_index :: proc(err: ^string, i: int) -> bool {
	err^ = fmt.tprintf("Error at index %d: %s", i, err^)
	return false
}

ext_missing_property :: proc(err: ^string, name: string) -> bool {
	err^ = fmt.tprintf("Missing required property '%s'.", name)
	return false
}

@(private = "file")
ext_number :: proc(v: json.Value) -> (f64, bool) {
	#partial switch n in v {
	case json.Float:   return n, true
	case json.Integer: return f64(n), true
	}
	return 0, false
}

ext_dec_bool :: proc(v: json.Value, out: ^bool, err: ^string) -> bool {
	b, ok := v.(json.Boolean)
	if !ok { return ext_type_error(err, "boolean", v) }
	out^ = b
	return true
}

// An integer: a JSON number without a fraction, within the range a double holds exactly.
ext_dec_int :: proc(v: json.Value, out: ^i64, err: ^string) -> bool {
	n, ok := ext_number(v)
	if !ok || n != math.trunc(n) || math.is_nan(n) { return ext_type_error(err, "integer", v) }
	if abs(n) > 9007199254740991 { err^ = "Value must be a safe integer."; return false }
	out^ = i64(n)
	return true
}

ext_dec_int_in :: proc(v: json.Value, lo, hi: i64, out: ^i64, err: ^string) -> bool {
	if !ext_dec_int(v, out, err) { return false }
	if out^ < lo { err^ = fmt.tprintf("Value must be at least %d.", lo); return false }
	if out^ > hi { err^ = fmt.tprintf("Value must not be greater than %d.", hi); return false }
	return true
}

ext_dec_f64 :: proc(v: json.Value, out: ^f64, err: ^string) -> bool {
	n, ok := ext_number(v)
	if !ok || math.is_nan(n) || math.is_inf(n) { return ext_type_error(err, "number", v) }
	out^ = n
	return true
}

ext_dec_f64_in :: proc(v: json.Value, lo, hi: f64, out: ^f64, err: ^string) -> bool {
	if !ext_dec_f64(v, out, err) { return false }
	if out^ < lo { err^ = fmt.tprintf("Value must be at least %v.", lo); return false }
	if out^ > hi { err^ = fmt.tprintf("Value must not be greater than %v.", hi); return false }
	return true
}

ext_dec_string :: proc(v: json.Value, out: ^string, err: ^string) -> bool {
	s, ok := v.(json.String)
	if !ok { return ext_type_error(err, "string", v) }
	out^ = s
	return true
}

ext_dec_any :: proc(v: json.Value, out: ^json.Value, err: ^string) -> bool {
	out^ = v
	return true
}

ext_dec_object :: proc(v: json.Value, out: ^json.Object, err: ^string) -> bool {
	o, ok := v.(json.Object)
	if !ok { return ext_type_error(err, "object", v) }
	out^ = o
	return true
}

ext_dec_enum :: proc(v: json.Value, values: []string, out: ^string, err: ^string) -> bool {
	s, ok := v.(json.String)
	if !ok { return ext_type_error(err, "string", v) }
	for x in values {
		if x == s { out^ = s; return true }
	}
	b := strings.builder_make(context.temp_allocator)
	for x, i in values {
		if i > 0 { strings.write_string(&b, ", ") }
		strings.write_byte(&b, '"')
		strings.write_string(&b, x)
		strings.write_byte(&b, '"')
	}
	err^ = fmt.tprintf("Value must be one of %s.", strings.to_string(b))
	return false
}

ext_dec_list :: proc(v: json.Value, out: ^[]$T, dec: proc(v: json.Value, out: ^T, err: ^string) -> bool, err: ^string) -> bool {
	list, ok := v.(json.Array)
	if !ok { return ext_type_error(err, "array", v) }
	items := make([]T, len(list), context.temp_allocator)
	for e, i in list {
		if !dec(e, &items[i], err) { return ext_at_index(err, i) }
	}
	out^ = items
	return true
}
