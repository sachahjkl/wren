package vault

// The pipe protocol of the helper (docs/vault-protocol.md, and README.md of wren-vault): frames of a 4-byte
// little-endian length and one JSON object. Requests are written here by hand into one buffer reserved large enough at
// once (a buffer that grows would leave copies of a password in freed memory); answers are decoded into owned values and
// the parsed JSON is zeroed before it is freed. Nothing here logs.

import "core:encoding/json"
import "core:mem"
import "core:strconv"
import "wb:base"

PROTOCOL_VERSION :: 1
MAX_FRAME :: 1 << 20   // the helper's bound too: a larger frame is a broken peer
FRAME_HEAD :: 4

Op :: enum u8 { Hello, Login, Unlock, Lock, Sync, Logins_For, Fill }

OP_NAMES := [Op]string{
	.Hello = "hello", .Login = "login", .Unlock = "unlock", .Lock = "lock", .Sync = "sync", .Logins_For = "logins_for", .Fill = "fill",
}

////////////////////////////////
// Requests

// A request being written: the frame's head, then the JSON object. Its buffer never grows past what `request_begin`
// reserved (request_end fails then).
Request :: struct {
	buf:      [dynamic]u8,
	reserved: int,
	first:    bool,   // no field written yet after id and op
}

// `room`: the bytes of the values to come (each string may grow 6 times when escaped).
request_begin :: proc(r: ^Request, id: u64, op: Op, room: int) {
	r.reserved = FRAME_HEAD + 64 + 6 * room
	r.buf = make([dynamic]u8, 0, r.reserved, base.process_allocator())
	append(&r.buf, 0, 0, 0, 0)
	append(&r.buf, `{"id":`)
	n: [24]u8
	append(&r.buf, strconv.write_uint(n[:], id, 10))
	append(&r.buf, `,"op":"`)
	append(&r.buf, OP_NAMES[op])
	append(&r.buf, '"')
}

request_string :: proc(r: ^Request, key, value: string) {
	append(&r.buf, ',')
	json_string(&r.buf, key)
	append(&r.buf, ':')
	json_string(&r.buf, value)
}

request_bool :: proc(r: ^Request, key: string, value: bool) {
	append(&r.buf, ',')
	json_string(&r.buf, key)
	append(&r.buf, value ? ":true" : ":false")
}

request_int :: proc(r: ^Request, key: string, value: int) {
	append(&r.buf, ',')
	json_string(&r.buf, key)
	append(&r.buf, ':')
	n: [24]u8
	append(&r.buf, strconv.write_int(n[:], i64(value), 10))
}

request_list :: proc(r: ^Request, key: string, values: []string) {
	append(&r.buf, ',')
	json_string(&r.buf, key)
	append(&r.buf, ":[")
	for v, i in values {
		if i > 0 { append(&r.buf, ',') }
		json_string(&r.buf, v)
	}
	append(&r.buf, ']')
}

// Closes the object and writes the length. ok = false when the frame outgrew its reservation or the protocol's bound:
// the buffer is zeroed and freed then.
request_end :: proc(r: ^Request) -> (frame: []u8, ok: bool) {
	append(&r.buf, '}')
	if cap(r.buf) != r.reserved || len(r.buf) - FRAME_HEAD > MAX_FRAME {
		frame_free(r.buf[:])
		r.buf = nil
		return nil, false
	}
	n := u32(len(r.buf) - FRAME_HEAD)
	r.buf[0], r.buf[1], r.buf[2], r.buf[3] = u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)
	frame = r.buf[:]
	r.buf = nil
	return frame, true
}

// Zeroes a frame (it may hold a password) and frees it. The frame must come from request_end or a transport.
frame_free :: proc(frame: []u8) {
	if frame == nil { return }
	mem.zero_explicit(raw_data(frame), len(frame))
	delete(frame, base.process_allocator())
}

// Appends `s` as a JSON string (UTF-8 kept as it is; control characters escaped).
json_string :: proc(b: ^[dynamic]u8, s: string) {
	hex := "0123456789abcdef"
	append(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '"' || c == '\\' {
			append(b, '\\', c)
		} else if c < 0x20 {
			append(b, u8('\\'), 'u', '0', '0', hex[c >> 4], hex[c & 15])
		} else {
			append(b, c)
		}
	}
	append(b, '"')
}

// The length of a frame from its head; ok = false outside 1 ... MAX_FRAME.
frame_length :: proc(head: [FRAME_HEAD]u8) -> (n: int, ok: bool) {
	n = int(u32(head[0]) | u32(head[1]) << 8 | u32(head[2]) << 16 | u32(head[3]) << 24)
	return n, n >= 1 && n <= MAX_FRAME
}

////////////////////////////////
// Answers

Match_Kind :: enum u8 { Domain, Host }

// One login of `logins_for`: what the panel shows. No password.
Row :: struct {
	id, name, username, uri: string,   // owned
	kind:     Match_Kind,
	has_totp: bool,
}

// One answer of the helper, owned (process allocator). answer_free zeroes every string.
Answer :: struct {
	id:             u64,
	ok:             bool,
	error, message: string,
	// hello
	account, email, helper_version: string,
	// login
	need_two_factor: bool,
	// sync
	items:          int,
	last_sync:      i64,
	// logins_for
	rows:           [dynamic]Row,
	// fill
	username, password: string,
	has_username, has_password: bool,
}

// Decodes the JSON of one answer. ok = false when it is not an answer of this protocol.
answer_decode :: proc(body: []u8) -> (a: ^Answer, ok: bool) {
	context.allocator = base.process_allocator()
	v, err := json.parse(body, .JSON, true)
	defer json_wipe(v)
	if err != .None { return nil, false }
	o, is_object := v.(json.Object)
	if !is_object { return nil, false }
	id, has_id := o["id"].(json.Integer)
	okv, has_ok := o["ok"].(json.Boolean)
	if !has_id || !has_ok || id < 0 { return nil, false }
	a = new(Answer)
	a.id, a.ok = u64(id), bool(okv)
	a.error = owned_string(o, "error")
	a.message = owned_string(o, "message")
	a.account = owned_string(o, "account")
	a.email = owned_string(o, "email")
	a.helper_version = owned_string(o, "helper_version")
	if r, is_str := o["result"].(json.String); is_str { a.need_two_factor = r == "need_two_factor" }
	if n, is_int := o["items"].(json.Integer); is_int { a.items = int(n) }
	if n, is_int := o["last_sync"].(json.Integer); is_int { a.last_sync = i64(n) }
	if s, is_str := o["username"].(json.String); is_str { a.username, a.has_username = clone(s), true }
	if s, is_str := o["password"].(json.String); is_str { a.password, a.has_password = clone(s), true }
	if rows, is_array := o["rows"].(json.Array); is_array {
		a.rows = make([dynamic]Row, 0, len(rows))
		for r in rows {
			ro, row_ok := r.(json.Object)
			if !row_ok { continue }
			row := Row{id = owned_string(ro, "id"), name = owned_string(ro, "name"), username = owned_string(ro, "username"), uri = owned_string(ro, "uri")}
			if m, is_str := ro["match"].(json.String); is_str && m == "host" { row.kind = .Host }
			if t, is_bool := ro["has_totp"].(json.Boolean); is_bool { row.has_totp = bool(t) }
			if row.id == "" { row_free(&row); continue }
			append(&a.rows, row)
		}
	}
	return a, true
}

@(private = "file")
clone :: proc(s: string) -> string {
	if s == "" { return "" }
	out := make([]u8, len(s), base.process_allocator())
	copy(out, s)
	return string(out)
}

@(private = "file")
owned_string :: proc(o: json.Object, key: string) -> string {
	if s, ok := o[key].(json.String); ok { return clone(s) }
	return ""
}

// Zeroes and frees an owned string ("" and literals are left alone: only what this package cloned comes here).
string_wipe :: proc(s: ^string) {
	if len(s^) > 0 {
		mem.zero_explicit(raw_data(s^), len(s^))
		delete(s^, base.process_allocator())
	}
	s^ = ""
}

row_free :: proc(r: ^Row) {
	string_wipe(&r.id)
	string_wipe(&r.name)
	string_wipe(&r.username)
	string_wipe(&r.uri)
}

rows_free :: proc(rows: ^[dynamic]Row) {
	for &r in rows { row_free(&r) }
	delete(rows^)
	rows^ = nil
}

answer_free :: proc(a: ^Answer) {
	if a == nil { return }
	string_wipe(&a.error)
	string_wipe(&a.message)
	string_wipe(&a.account)
	string_wipe(&a.email)
	string_wipe(&a.helper_version)
	string_wipe(&a.username)
	string_wipe(&a.password)
	rows_free(&a.rows)
	free(a, base.process_allocator())
}

// Zeroes every string of a parsed value, then frees it (process allocator). Iterative: no recursion on the depth that
// a broken peer could send.
json_wipe :: proc(v: json.Value) {
	stack := make([dynamic]json.Value, 0, 16, base.process_allocator())
	defer delete(stack)
	append(&stack, v)
	for len(stack) > 0 {
		x := pop(&stack)
		#partial switch e in x {
		case json.String:
			if len(e) > 0 { mem.zero_explicit(raw_data(e), len(e)) }
		case json.Array:
			for c in e { append(&stack, c) }
		case json.Object:
			for k, c in e {
				if len(k) > 0 { mem.zero_explicit(raw_data(k), len(k)) }
				append(&stack, c)
			}
		}
	}
	json.destroy_value(v, base.process_allocator())
}
