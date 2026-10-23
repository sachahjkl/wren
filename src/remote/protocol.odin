// Package remote: the remote control channel of Wren (`wren ctl`, and anything that speaks its protocol).
//
// Protocol: one JSON object per line (UTF-8, "\n" ends it), over the named pipe \\.\pipe\wren-remote-<name>.
//   request   {"id": 1, "method": "Page.navigate", "params": {"url": "https://example.com/"}}
//   response  {"id": 1, "result": {...}}   or   {"id": 1, "error": {"code": -32000, "message": "...", "data": ...}}
//   event     {"event": "Page.loadEventFired", "params": {...}}     (sent to a client after Remote.subscribe)
// `id` is any JSON number or string and is given back as it came. Responses of different requests may come in another
// order than the requests (a wait answers when its condition holds); a client that sends one request at a time never
// notices.
//
// Method names and parameters follow the Chrome DevTools Protocol where Wren has the same thing (Page.navigate,
// Page.captureScreenshot, Runtime.evaluate, Input.dispatchMouseEvent, Input.dispatchKeyEvent, Target.getTargets...), so an
// adapter that speaks CDP or WebDriver BiDi to a test framework can be put in front of this channel later without
// redrawing it: it translates, it does not add a second control path. Names the CDP does not have are in the `Wren.`
// domain (Wren.wait, Wren.stats, Wren.snapshot...).
//
// Codes of errors: the JSON-RPC ones (-32700 parse error, -32600 invalid request, -32601 unknown method, -32602 invalid
// parameters) and -32000 for a command that failed, -32001 for a wait that timed out.
package remote

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

ERR_PARSE     :: -32700
ERR_REQUEST   :: -32600
ERR_METHOD    :: -32601
ERR_PARAMS    :: -32602
ERR_FAILED    :: -32000
ERR_TIMEOUT   :: -32001

Request :: struct {
	id:     string,        // the id as JSON text ("null" when the request has none)
	method: string,
	params: json.Object,   // empty when absent
}

// Parses one request line. Everything is allocated with `allocator` (the frame's temporary one: nothing to free). On a
// failure `code` and `message` say why, and `id` is as much of the id as could be read (for the error response).
parse_request :: proc(line: []byte, allocator := context.temp_allocator) -> (req: Request, code: int, message: string) {
	req.id = "null"
	root, err := json.parse(line, json.Specification.JSON, true, allocator)
	if err != .None { return req, ERR_PARSE, "invalid JSON" }
	obj, is_obj := root.(json.Object)
	if !is_obj { return req, ERR_REQUEST, "a request is a JSON object" }
	if v, ok := obj["id"]; ok { req.id = id_text(v, allocator) }
	m, has_m := obj["method"].(json.String)
	if !has_m || m == "" { return req, ERR_REQUEST, "a request has a \"method\" string" }
	req.method = string(m)
	if p, ok := obj["params"]; ok {
		po, is_o := p.(json.Object)
		if !is_o { if _, is_null := p.(json.Null); !is_null { return req, ERR_PARAMS, "\"params\" is an object" } }
		req.params = po
	}
	return
}

@(private)
id_text :: proc(v: json.Value, allocator := context.temp_allocator) -> string {
	#partial switch x in v {
	case json.Integer: return fmt.aprintf("%d", i64(x), allocator = allocator)
	case json.Float:   return fmt.aprintf("%v", f64(x), allocator = allocator)
	case json.String:
		b := strings.builder_make(allocator)
		write_json_string(&b, string(x))
		return strings.to_string(b)
	}
	return "null"
}

////////////////////////////////
// Writing

// A JSON string literal of `s`: invalid UTF-8 becomes U+FFFD (the line must stay valid JSON whatever a page printed).
write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	rest := s
	for len(rest) > 0 {
		r, n := utf8.decode_rune_in_string(rest)
		if r == utf8.RUNE_ERROR && n <= 1 {
			strings.write_string(b, "\ufffd")
			rest = rest[max(n, 1):]
			continue
		}
		rest = rest[n:]
		switch r {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case 0 ..< 0x20, 0x2028, 0x2029: fmt.sbprintf(b, "\\u%04x", int(r))
		case: strings.write_rune(b, r)
		}
	}
	strings.write_byte(b, '"')
}

quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	write_json_string(&b, s)
	return strings.to_string(b)
}

// The line (without the final "\n") of a successful response; `result` is JSON text.
response_ok :: proc(id, result: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({`{"id":`, id, `,"result":`, result == "" ? "{}" : result, `}`}, allocator)
}

// `data`: JSON text or "".
response_error :: proc(id: string, code: int, message: string, data := "", allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, `{{"id":%s,"error":{{"code":%d,"message":`, id, code)
	write_json_string(&b, message)
	if data != "" { strings.write_string(&b, `,"data":`); strings.write_string(&b, data) }
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

event_line :: proc(name, params: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({`{"event":`, quote(name, allocator), `,"params":`, params == "" ? "{}" : params, `}`}, allocator)
}

////////////////////////////////
// Reading parameters (a wrong type counts as absent: the method decides whether that is an error)

param_string :: proc(p: json.Object, key: string, default := "") -> (string, bool) {
	if v, ok := p[key].(json.String); ok { return string(v), true }
	return default, false
}

param_int :: proc(p: json.Object, key: string, default := 0) -> (int, bool) {
	#partial switch v in p[key] {
	case json.Integer: return int(v), true
	case json.Float:   return int(v), true
	}
	return default, false
}

param_float :: proc(p: json.Object, key: string, default := 0.0) -> (f64, bool) {
	#partial switch v in p[key] {
	case json.Integer: return f64(v), true
	case json.Float:   return f64(v), true
	}
	return default, false
}

param_bool :: proc(p: json.Object, key: string, default := false) -> (bool, bool) {
	if v, ok := p[key].(json.Boolean); ok { return bool(v), true }
	return default, false
}

param_object :: proc(p: json.Object, key: string) -> (json.Object, bool) {
	if v, ok := p[key].(json.Object); ok { return v, true }
	return nil, false
}

param_array :: proc(p: json.Object, key: string) -> (json.Array, bool) {
	if v, ok := p[key].(json.Array); ok { return v, true }
	return nil, false
}
