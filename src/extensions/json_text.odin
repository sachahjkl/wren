package extensions

// JSON text of a parsed value (core:encoding/json's Value), for the API's answers: a stored value is kept as text, a
// default given to storage.get is parsed, then written back here. Numbers are written as JavaScript writes them for the
// integers it keeps exactly; the depth is bounded (a deeper value is written as null: the parser already refused
// anything near that deep).

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"

JSON_MAX_DEPTH :: 512

json_write :: proc(b: ^strings.Builder, v: json.Value, depth := 0) {
	if depth > JSON_MAX_DEPTH { strings.write_string(b, "null"); return }
	switch x in v {
	case json.Null:    strings.write_string(b, "null")
	case json.Boolean: strings.write_string(b, x ? "true" : "false")
	case json.Integer: fmt.sbprintf(b, "%d", x)
	case json.Float:
		switch {
		case math.is_nan(x) || math.is_inf(x): strings.write_string(b, "null")
		case x == math.trunc(x) && abs(x) < 9007199254740992: fmt.sbprintf(b, "%d", i64(x))
		case: fmt.sbprintf(b, "%.17g", x)
		}
	case json.String:
		strings.write_byte(b, '"')
		json_escape_into(b, x)
		strings.write_byte(b, '"')
	case json.Array:
		strings.write_byte(b, '[')
		for e, i in x {
			if i > 0 { strings.write_byte(b, ',') }
			json_write(b, e, depth + 1)
		}
		strings.write_byte(b, ']')
	case json.Object:
		strings.write_byte(b, '{')
		i := 0
		for k, e in x {
			if i > 0 { strings.write_byte(b, ',') }
			i += 1
			strings.write_byte(b, '"')
			json_escape_into(b, k)
			strings.write_string(b, "\":")
			json_write(b, e, depth + 1)
		}
		strings.write_byte(b, '}')
	case:
		strings.write_string(b, "null")
	}
}

// The JSON text of `v` (temp allocator).
json_text :: proc(v: json.Value) -> string {
	b := strings.builder_make(context.temp_allocator)
	json_write(&b, v)
	return strings.to_string(b)
}
