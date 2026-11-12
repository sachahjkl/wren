package vault

// The pipe protocol of the helper (docs/vault-protocol.md, and README.md of wren-vault): frames of a 4-byte
// little-endian length and one JSON object. Requests are written here by hand into one buffer reserved large enough at
// once (a buffer that grows would leave copies of a password in freed memory); answers are decoded into owned values and
// the parsed JSON is zeroed before it is freed. Nothing here logs.

import "core:encoding/json"
import "core:mem"
import "core:strconv"
import "wb:base"

PROTOCOL_VERSION :: 5
MAX_FRAME :: 1 << 20   // the helper's bound too: a larger frame is a broken peer
FRAME_HEAD :: 4

Op :: enum u8 {
	Hello, Login, Login_Api_Key, Unlock, Lock, Logout, Sync, Pin_Set, Pin_Clear, Logins_For, Search, Fill, Totp, Keepalive,
	Password_Hint, Device_Request, Device_Poll, Passkey_Options, Login_Passkey, Save, Generate,
}

OP_NAMES := [Op]string{
	.Hello = "hello", .Login = "login", .Login_Api_Key = "login_api_key", .Unlock = "unlock", .Lock = "lock", .Logout = "logout",
	.Sync = "sync", .Pin_Set = "pin_set", .Pin_Clear = "pin_clear", .Logins_For = "logins_for", .Search = "search", .Fill = "fill",
	.Totp = "totp", .Keepalive = "keepalive", .Password_Hint = "password_hint", .Device_Request = "device_request",
	.Device_Poll = "device_poll", .Passkey_Options = "passkey_options", .Login_Passkey = "login_passkey", .Save = "save",
	.Generate = "generate",
}

// The second steps of a login that the Vault supports (the helper's provider names).
Factor :: enum u8 { Authenticator, Email }
Factors :: bit_set[Factor; u8]

FACTOR_NAMES := [Factor]string{.Authenticator = "authenticator", .Email = "email"}

// What a `login` (or a `device_poll`) answered when it succeeded. Pending: the other device has not answered yet.
Login_Result :: enum u8 { None, Ok, Need_Two_Factor, Need_Device_Code, Pending }

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

// How the helper says a row matched (its `match`): the rule that Wren checks again (match.odin).
Match_Kind :: enum u8 { Domain, Host, Equivalent, Starts_With, Exact }

MATCH_NAMES := [Match_Kind]string{.Domain = "domain", .Host = "host", .Equivalent = "equivalent", .Starts_With = "starts_with", .Exact = "exact"}

// What an item of the vault is (a row's `kind`). Secure notes and SSH keys are never listed.
Item_Kind :: enum u8 { Login, Card, Identity }

ITEM_KIND_NAMES := [Item_Kind]string{.Login = "login", .Card = "card", .Identity = "identity"}

// One item of `logins_for` or `search`: what a surface shows. No password, no code. A card's `username` is its brand
// and last 4 digits, an identity's its full name or email; their `uri` is "".
Row :: struct {
	id, name, username, uri: string,   // owned
	kind:     Item_Kind,
	match:    Match_Kind,
	has_totp: bool,
}

// The values a `fill` can ask for: a login's, a card's, an identity's (FILL_FIELD_NAMES: the protocol's names).
Fill_Field :: enum u8 {
	Username, Password, Totp,
	Cardholder, Number, Exp_Month, Exp_Year, Code, Brand,
	Title, First_Name, Middle_Name, Last_Name, Full_Name, Address1, Address2, Address3, City, State, Postal_Code,
	Country, Company, Email, Phone, Ssn, Passport, License,
}
Fill_Fields :: bit_set[Fill_Field; u32]

FILL_FIELD_NAMES := [Fill_Field]string{
	.Username = "username", .Password = "password", .Totp = "totp",
	.Cardholder = "cardholder", .Number = "number", .Exp_Month = "exp_month", .Exp_Year = "exp_year", .Code = "code", .Brand = "brand",
	.Title = "title", .First_Name = "first_name", .Middle_Name = "middle_name", .Last_Name = "last_name", .Full_Name = "full_name",
	.Address1 = "address1", .Address2 = "address2", .Address3 = "address3", .City = "city", .State = "state",
	.Postal_Code = "postal_code", .Country = "country", .Company = "company", .Email = "email", .Phone = "phone",
	.Ssn = "ssn", .Passport = "passport", .License = "license",
}

CARD_FIELDS :: Fill_Fields{.Cardholder, .Number, .Exp_Month, .Exp_Year, .Code, .Brand}
IDENTITY_FIELDS :: Fill_Fields{.Title, .First_Name, .Middle_Name, .Last_Name, .Full_Name, .Address1, .Address2, .Address3,
	.City, .State, .Postal_Code, .Country, .Company, .Email, .Phone, .Ssn, .Passport, .License}

// One answer of the helper, owned (process allocator). answer_free zeroes every string. Id 0: an event (`event`).
Answer :: struct {
	id:             u64,
	ok:             bool,
	error, message: string,
	event:          string,   // id 0: "locked" (the helper locked itself at its idle deadline and exits)
	// hello
	account, email, helper_version: string,
	pin:            bool,     // a PIN can unlock the remembered account
	passkey:        bool,     // a passkey of the remembered account can unlock it
	// login, login_api_key, device_poll, login_passkey (and `email`)
	result:         Login_Result,
	// device_request: the phrase that the other device shows too
	fingerprint:    string,
	// passkey_options: the ceremony's options (WebAuthn's PublicKeyCredentialRequestOptionsJSON)
	options:        string,
	factors:        Factors,  // Need_Two_Factor: the second steps that the account offers and the Vault supports
	email_sent:     bool,     // Need_Two_Factor: a code was mailed already
	// unlock with a PIN: bad_pin
	tries_left:     int,
	// sync
	items:          int,
	last_sync:      i64,
	// logins_for, search
	rows:           [dynamic]Row,
	equivalent:     [dynamic]string,   // logins_for: the domains the account makes equivalent to the page's
	// fill (and totp: `totp`): one value per asked field that the item has
	values:         [Fill_Field]string,
	has:            Fill_Fields,
	// totp
	period, remaining: int,
	// save: `item`
	item:           string,
	// generate: a secret
	value:          string,
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
	a.event = owned_string(o, "event")
	if r, is_str := o["result"].(json.String); is_str {
		switch r {
		case "ok":               a.result = .Ok
		case "need_two_factor":  a.result = .Need_Two_Factor
		case "need_device_code": a.result = .Need_Device_Code
		case "pending":          a.result = .Pending
		}
	}
	a.fingerprint = owned_string(o, "fingerprint")
	a.options = owned_string(o, "options")
	if b, is_bool := o["passkey"].(json.Boolean); is_bool { a.passkey = bool(b) }
	if list, is_array := o["providers"].(json.Array); is_array {
		for p in list {
			name, is_str := p.(json.String)
			if !is_str { continue }
			for f in Factor { if FACTOR_NAMES[f] == name { a.factors += {f} } }
		}
	}
	if b, is_bool := o["email_sent"].(json.Boolean); is_bool { a.email_sent = bool(b) }
	if b, is_bool := o["pin"].(json.Boolean); is_bool { a.pin = bool(b) }
	if n, is_int := o["tries_left"].(json.Integer); is_int { a.tries_left = int(n) }
	if n, is_int := o["items"].(json.Integer); is_int { a.items = int(n) }
	if n, is_int := o["last_sync"].(json.Integer); is_int { a.last_sync = i64(n) }
	for f in Fill_Field {
		if s, is_str := o[FILL_FIELD_NAMES[f]].(json.String); is_str {
			a.values[f] = clone(s)
			a.has += {f}
		}
	}
	a.item = owned_string(o, "item")
	a.value = owned_string(o, "value")
	if n, is_int := o["period"].(json.Integer); is_int { a.period = int(n) }
	if n, is_int := o["remaining"].(json.Integer); is_int { a.remaining = int(n) }
	if list, is_array := o["equivalent"].(json.Array); is_array {
		a.equivalent = make([dynamic]string, 0, len(list))
		for d in list {
			if ds, is_str := d.(json.String); is_str && ds != "" { append(&a.equivalent, clone(ds)) }
		}
	}
	if rows, is_array := o["rows"].(json.Array); is_array {
		a.rows = make([dynamic]Row, 0, len(rows))
		for r in rows {
			ro, row_ok := r.(json.Object)
			if !row_ok { continue }
			row := Row{id = owned_string(ro, "id"), name = owned_string(ro, "name"), username = owned_string(ro, "username"), uri = owned_string(ro, "uri")}
			known := true
			if m, is_str := ro["match"].(json.String); is_str {
				known = false
				for k in Match_Kind { if MATCH_NAMES[k] == m { row.match, known = k, true } }
			}
			// (no kind: a login, as every row of version 4 was; a kind this version does not know is no item it can show)
			if k, is_str := ro["kind"].(json.String); is_str {
				kind_known := false
				for ik in Item_Kind { if ITEM_KIND_NAMES[ik] == k { row.kind, kind_known = ik, true } }
				known = known && kind_known
			}
			if t, is_bool := ro["has_totp"].(json.Boolean); is_bool { row.has_totp = bool(t) }
			// (a rule this version does not know is no rule Wren can check: the row goes)
			if row.id == "" || !known { row_free(&row); continue }
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

strings_free :: proc(list: ^[dynamic]string) {
	for &s in list { string_wipe(&s) }
	delete(list^)
	list^ = nil
}

answer_free :: proc(a: ^Answer) {
	if a == nil { return }
	string_wipe(&a.error)
	string_wipe(&a.message)
	string_wipe(&a.account)
	string_wipe(&a.email)
	string_wipe(&a.helper_version)
	string_wipe(&a.event)
	string_wipe(&a.fingerprint)
	string_wipe(&a.options)
	for &value in a.values { string_wipe(&value) }
	string_wipe(&a.item)
	string_wipe(&a.value)
	rows_free(&a.rows)
	strings_free(&a.equivalent)
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
