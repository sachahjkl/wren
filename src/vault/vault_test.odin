package vault

// The Vault against a fake helper: an in-process transport that answers each request from a script, through the loop as
// the real one does. Tests wait with blocking_settle (bounded) or move a virtual clock; none sleeps. The answers are
// built by concatenation (fmt reads a "{" as the start of an argument index).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:config"
import "wb:host"

@(private = "file")
Script :: struct {
	answers:  map[string][dynamic]string,   // op -> the answers' fields, used in order (the last one stays); "" never answers; "EXIT": the helper dies; "LOCKED": it locks itself (the event, then its exit)
	used:     map[string]int,               // op -> the answers already given
	ops:      [dynamic]string,              // what the helper was asked, in order
	secrets:  [dynamic]string,              // "op:key" for each password, PIN, code or client secret that crossed
	notes:    [dynamic]string,              // "provider=<name>" and "resend" of each login, in order
	hello_idle: i64,                        // idle_seconds of the last hello
	spawned:  int,
	closed:   int,
}

@(private = "file")
Fake :: struct {
	using tr: Transport,
	script:   ^Script,
	dead:     bool,
}

@(private = "file")
Fx :: struct {
	loop:    host.Loop,
	pool:    host.Blocking_Pool,
	clock:   host.Virtual_Clock,
	prefs:   config.Prefs,
	v:       Vault,
	script:  Script,
	changes: int,
	filled:  [dynamic]string,   // "user:pass" of each applied fill ("user:pass:code" when a code came)
	copied:  [dynamic]string,   // "what:value" of each copy (a code's: "totp:value:seconds left")
	refuse:  bool,              // the fill hook drops the fill (the page changed)
	profile: string,            // a temporary profile folder ("" none); removed at the end
}

// (the Vault's `spawn` has no user data: the test's script is this thread's)
@(private = "file", thread_local)
the_script: ^Script

@(private = "file")
fake_spawn :: proc(v: ^Vault, path: string) -> ^Transport {
	f := new(Fake, base.process_allocator())
	f.send, f.close, f.destroy = fake_send, fake_close, fake_destroy
	f.vault, f.loop, f.script = v, v.loop, the_script
	f.script.spawned += 1
	return &f.tr
}

@(private = "file")
fake_send :: proc(t: ^Transport, frame: []u8) {
	f := (^Fake)(t)
	defer frame_free(frame)
	if f.dead { return }
	v, err := json.parse(frame[FRAME_HEAD:], .JSON, true, base.process_allocator())
	defer json_wipe(v)
	if err != .None { return }
	o := v.(json.Object)
	id := o["id"].(json.Integer)
	op := strings.clone(o["op"].(json.String))   // (kept in ops until the end: also the key of `used`)
	append(&f.script.ops, op)
	for key in ([]string{"password", "code", "pin", "client_secret"}) {
		if _, has := o[key]; has { append(&f.script.secrets, strings.concatenate({op, ":", key})) }
	}
	if p, has := o["provider"].(json.String); has { append(&f.script.notes, strings.concatenate({"provider=", p})) }
	if r, has := o["resend"].(json.Boolean); has && bool(r) { append(&f.script.notes, strings.clone("resend")) }
	if idle, has := o["idle_seconds"].(json.Integer); has { f.script.hello_idle = i64(idle) }
	if op == "search" {
		off, _ := o["offset"].(json.Integer)
		lim, _ := o["limit"].(json.Integer)
		kinds := make([dynamic]string, 0, 3, context.temp_allocator)
		if list, has := o["kinds"].(json.Array); has { for k in list { append(&kinds, string(k.(json.String))) } }
		append(&f.script.notes, fmt.aprintf("search=%d+%d:%s", off, lim, strings.join(kinds[:], ",", context.temp_allocator)))
	}
	if list, has := o["allow"].(json.Array); has {
		ids := make([dynamic]string, 0, len(list), context.temp_allocator)
		for n in list { append(&ids, string(n.(json.String))) }
		rp, _ := o["rp_id"].(json.String)
		append(&f.script.notes, strings.concatenate({"passkeys=", string(rp), ":", strings.join(ids[:], ",", context.temp_allocator)}))
	}
	if op == "passkey_assert" {
		parts := make([dynamic]string, 0, 4, context.temp_allocator)
		for key in ([]string{"item", "credential_id", "rp_id", "client_data_hash"}) {
			s, _ := o[key].(json.String)
			append(&parts, string(s))
		}
		append(&f.script.notes, strings.concatenate({"assert=", strings.join(parts[:], ",", context.temp_allocator)}))
	}
	if list, has := o["fields"].(json.Array); has {
		names := make([dynamic]string, 0, len(list), context.temp_allocator)
		for n in list { append(&names, string(n.(json.String))) }
		append(&f.script.notes, strings.concatenate({"fields=", strings.join(names[:], ",", context.temp_allocator)}))
	}
	list, found := f.script.answers[op]
	if !found || len(list) == 0 { return }
	n := f.script.used[op]
	f.script.used[op] = n + 1
	fields := list[min(n, len(list) - 1)]
	switch fields {
	case "": return
	case "EXIT":
		f.dead = true
		transport_post(t, nil, exited = true)
		return
	case "LOCKED":
		f.dead = true
		event, ok := answer_decode(transmute([]u8)string(`{"id":0,"ok":true,"event":"locked"}`))
		assert(ok)
		transport_post(t, event)
		transport_post(t, nil, exited = true)
		return
	}
	text := strings.concatenate({`{"id":`, fmt.tprint(id), ",", fields, "}"}, context.temp_allocator)
	a, ok := answer_decode(transmute([]u8)text)
	// (a script the protocol cannot read is the test's own mistake: say it rather than drop the answer)
	assert(ok, "the fake helper's answer does not decode")
	transport_post(t, a)
}

@(private = "file")
fake_close :: proc(t: ^Transport) {
	f := (^Fake)(t)
	f.script.closed += 1
	if !f.dead {
		f.dead = true
		transport_post(t, nil, exited = true)
	}
}

@(private = "file")
fake_destroy :: proc(t: ^Transport) { free((^Fake)(t), base.process_allocator()) }

// `profile`: the Vault gets a temporary profile folder (the account file is written there).
@(private = "file")
fx_make :: proc(enabled := true, virtual_clock := false, profile := false) -> ^Fx {
	x := new(Fx)
	host.loop_init(&x.loop)
	if virtual_clock { host.clock_virtual(&x.loop, &x.clock) }
	host.blocking_init(&x.pool, &x.loop, 1)
	x.prefs = config.prefs_make()
	register_prefs(&x.prefs)
	exe, _ := os.get_executable_path(context.temp_allocator)   // (a file that exists: what the fake "starts")
	_ = config.set_from_string(&x.prefs, "vault.helper.path", exe, .User)
	_ = config.set_from_string(&x.prefs, "vault.request.timeout_ms", "1000", .User)
	if enabled { _ = config.set_from_string(&x.prefs, "vault.enabled", "true", .User) }
	if profile {
		x.profile = strings.concatenate({base.temp_dir(context.temp_allocator), "/wren-vault-test-", base.unique_name(context.temp_allocator)})
		_ = os.make_directory_all(x.profile)
	}
	the_script = &x.script
	hooks := Hooks{
		user = x,
		changed = proc(user: rawptr) { (^Fx)(user).changes += 1 },
		fill = proc(user: rawptr, values: ^Fill_Values) -> bool {
			x := (^Fx)(user)
			if x.refuse { return false }
			switch {
			case values.has & CARD_FIELDS != {}:
				append(&x.filled, strings.concatenate({"card:", values.values[.Number], ":", values.values[.Exp_Month], "/", values.values[.Exp_Year]}))
			case .Totp in values.has:
				append(&x.filled, strings.concatenate({values.values[.Username], ":", values.values[.Password], ":", values.values[.Totp]}))
			case:
				append(&x.filled, strings.concatenate({values.values[.Username], ":", values.values[.Password]}))
			}
			return true
		},
		copy = proc(user: rawptr, what: Copy_What, value: string, seconds_left: int) {
			x := (^Fx)(user)
			names := [Copy_What]string{.Username = "username", .Password = "password", .Totp = "totp", .Number = "number", .Code = "code", .Email = "email"}
			if what == .Totp {
				append(&x.copied, strings.concatenate({names[what], ":", value, ":", fmt.tprint(seconds_left)}))
			} else {
				append(&x.copied, strings.concatenate({names[what], ":", value}))
			}
		},
	}
	vault_init(&x.v, &x.loop, &x.pool, &x.prefs, x.profile, "test", hooks, fake_spawn)
	settle(x)
	return x
}

@(private = "file")
fx_destroy :: proc(x: ^Fx) {
	vault_destroy(&x.v)
	host.blocking_destroy(&x.pool)
	host.loop_destroy(&x.loop)
	config.prefs_destroy(&x.prefs)
	for _, list in x.script.answers {
		for s in list { delete(s) }
		delete(list)
	}
	delete(x.script.answers)
	delete(x.script.used)
	for list in ([][dynamic]string{x.script.ops, x.script.secrets, x.script.notes}) {
		for s in list { delete(s) }
		delete(list)
	}
	for s in x.filled { delete(s) }
	delete(x.filled)
	for s in x.copied { delete(s) }
	delete(x.copied)
	if x.profile != "" {
		_ = base.remove_tree(x.profile)
		delete(x.profile)
	}
	the_script = nil
	free(x)
}

// What the helper answers to `op`, in order of the requests.
@(private = "file")
answer :: proc(x: ^Fx, op: string, fields: ..string) {
	list := x.script.answers[op]
	for f in fields { append(&list, strings.clone(f)) }
	x.script.answers[op] = list
}

// Runs the loop and the pool until neither has work (bounded: blocking_settle's rounds).
@(private = "file")
settle :: proc(x: ^Fx) { host.blocking_settle(&x.pool) }

@(private = "file")
set_pref :: proc(x: ^Fx, name, value: string) {
	_ = config.set_from_string(&x.prefs, name, value, .User)
	vault_prefs_changed(&x.v, &x.prefs)
	settle(x)
}

@(private = "file")
last_op :: proc(x: ^Fx) -> string { return x.script.ops[len(x.script.ops) - 1] }

@(private = "file")
count_op :: proc(x: ^Fx, op: string) -> (n: int) {
	for o in x.script.ops { if o == op { n += 1 } }
	return
}

@(private = "file")
seconds :: proc(n: i64) -> time.Duration { return time.Duration(n) * time.Second }

@(private = "file")
unlocked_fx :: proc(t: ^testing.T, virtual_clock := false, profile := false, idle_minutes := "") -> ^Fx {
	x := fx_make(virtual_clock = virtual_clock, profile = profile)
	if idle_minutes != "" { set_pref(x, "vault.lock.idle_minutes", idle_minutes) }
	answer(x, "hello", `"ok":true,"account":"none","email":""`)
	answer(x, "login", `"ok":true,"result":"ok"`)
	testing.expect(t, vault_login(&x.v, "me@example.com", "master"))
	settle(x)
	testing.expect_value(t, x.v.state, State.Unlocked)
	return x
}

@(test)
off_by_default_nothing_runs :: proc(t: ^testing.T) {
	x := fx_make(enabled = false)
	defer fx_destroy(x)
	testing.expect_value(t, x.v.state, State.Disabled)
	testing.expect(t, !vault_login(&x.v, "me@example.com", "master"))
	testing.expect_value(t, x.script.spawned, 0)
}

@(test)
enabling_locates_the_helper_then_a_login_unlocks :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	testing.expect_value(t, x.script.spawned, 1)
	testing.expect_value(t, len(x.script.ops), 2)
	testing.expect_value(t, x.script.ops[0], "hello")
	testing.expect_value(t, x.script.ops[1], "login")
	testing.expect_value(t, len(x.script.secrets), 1)   // the password crossed once
	testing.expect_value(t, x.v.email, "me@example.com")
	// the helper's own idle deadline is the Vault's (15 minutes) and a margin
	testing.expect_value(t, x.script.hello_idle, i64(15 * 60 + HELPER_IDLE_MARGIN_S))
}

@(test)
a_missing_helper_is_said :: proc(t: ^testing.T) {
	x := fx_make(enabled = false)
	defer fx_destroy(x)
	_ = config.set_from_string(&x.prefs, "vault.helper.path", "/nonexistent/wren-vault", .User)
	set_pref(x, "vault.enabled", "true")
	testing.expect_value(t, x.v.state, State.Helper_Missing)
	testing.expect_value(t, x.script.spawned, 0)
}

@(test)
the_second_factor_sends_the_code_without_the_password :: proc(t: ^testing.T) {
	x := fx_make()
	defer fx_destroy(x)
	answer(x, "hello", `"ok":true,"account":"none","email":""`)
	answer(x, "login", `"ok":true,"result":"need_two_factor","providers":["authenticator"]`, `"ok":true,"result":"ok"`)
	testing.expect(t, vault_login(&x.v, "me@example.com", "master"))
	settle(x)
	testing.expect_value(t, x.v.state, State.Need_Two_Factor)
	testing.expect_value(t, x.v.factor, Factor.Authenticator)
	testing.expect(t, !vault_send_code(&x.v))   // (no email code on this account)
	testing.expect(t, !vault_login(&x.v, "", "", "   "))   // (no code: nothing is sent)
	testing.expect(t, vault_login(&x.v, "", "", "123456"))
	settle(x)
	testing.expect_value(t, x.v.state, State.Unlocked)
	testing.expect_value(t, len(x.script.secrets), 2)
	testing.expect_value(t, x.script.secrets[0], "login:password")
	testing.expect_value(t, x.script.secrets[1], "login:code")
	testing.expect_value(t, len(x.script.notes), 1)
	testing.expect_value(t, x.script.notes[0], "provider=authenticator")
}

@(test)
an_email_code_is_asked_for_then_sent_with_its_provider :: proc(t: ^testing.T) {
	x := fx_make()
	defer fx_destroy(x)
	answer(x, "hello", `"ok":true,"account":"none","email":""`)
	answer(x, "login",
		`"ok":true,"result":"need_two_factor","providers":["authenticator","email"],"email_sent":false`,
		`"ok":true,"result":"need_two_factor","providers":["authenticator","email"],"email_sent":true`,
		`"ok":true,"result":"ok"`)
	testing.expect(t, vault_login(&x.v, "me@example.com", "master"))
	settle(x)
	testing.expect_value(t, x.v.factors, Factors{.Authenticator, .Email})
	testing.expect_value(t, x.v.factor, Factor.Authenticator)
	testing.expect(t, vault_send_code(&x.v))
	testing.expect_value(t, x.v.state, State.Logging_In)
	settle(x)
	testing.expect_value(t, x.v.state, State.Need_Two_Factor)
	testing.expect_value(t, x.v.factor, Factor.Email)
	testing.expect(t, x.v.email_sent)
	testing.expect(t, vault_login(&x.v, "", "", "111222"))
	settle(x)
	testing.expect_value(t, x.v.state, State.Unlocked)
	testing.expect_value(t, len(x.script.notes), 3)
	testing.expect_value(t, x.script.notes[0], "provider=email")
	testing.expect_value(t, x.script.notes[1], "resend")
	testing.expect_value(t, x.script.notes[2], "provider=email")
	// the master password crossed once, with the first step
	testing.expect_value(t, x.script.secrets[0], "login:password")
	testing.expect_value(t, len(x.script.secrets), 2)
}

@(test)
a_new_device_is_confirmed_with_the_mailed_code :: proc(t: ^testing.T) {
	x := fx_make()
	defer fx_destroy(x)
	answer(x, "hello", `"ok":true,"account":"none","email":""`)
	answer(x, "login", `"ok":true,"result":"need_device_code"`, `"ok":true,"result":"need_device_code"`, `"ok":true,"result":"ok"`)
	testing.expect(t, vault_login(&x.v, "me@example.com", "master"))
	settle(x)
	testing.expect_value(t, x.v.state, State.Need_Device_Code)
	testing.expect(t, vault_send_code(&x.v))   // (a new mail)
	settle(x)
	testing.expect_value(t, x.v.state, State.Need_Device_Code)
	testing.expect(t, vault_login(&x.v, "", "", "246810"))
	settle(x)
	testing.expect_value(t, x.v.state, State.Unlocked)
	testing.expect_value(t, x.script.notes[len(x.script.notes) - 1], "provider=device")
	testing.expect_value(t, count_op(x, "hello"), 1)   // (one helper all along: it keeps the password between the steps)
}

@(test)
a_refused_code_ends_the_login :: proc(t: ^testing.T) {
	x := fx_make()
	defer fx_destroy(x)
	answer(x, "hello", `"ok":true,"account":"none","email":""`)
	answer(x, "login", `"ok":true,"result":"need_device_code"`, `"ok":false,"error":"bad_credentials","message":"Invalid new device OTP."`)
	vault_login(&x.v, "me@example.com", "master")
	settle(x)
	testing.expect(t, vault_login(&x.v, "", "", "000000"))
	settle(x)
	testing.expect_value(t, x.v.state, State.Logged_Out)
	testing.expect_value(t, x.v.message, "Invalid new device OTP.")
	testing.expect(t, x.v.t == nil)
}

@(test)
an_api_key_login_unlocks_and_takes_the_accounts_email :: proc(t: ^testing.T) {
	x := fx_make()
	defer fx_destroy(x)
	answer(x, "hello", `"ok":true,"account":"none","email":""`)
	answer(x, "login_api_key", `"ok":true,"result":"ok","email":"me@example.com"`)
	testing.expect(t, !vault_login_api_key(&x.v, "user.x", "", "master"))   // (no secret: nothing is sent)
	testing.expect(t, vault_login_api_key(&x.v, " user.x ", "s3cret", "master"))
	settle(x)
	testing.expect_value(t, x.v.state, State.Unlocked)
	testing.expect_value(t, x.v.email, "me@example.com")
	testing.expect_value(t, len(x.script.secrets), 2)
	// (the fake lists the secret fields of a request in its own order: password, code, pin, client_secret)
	testing.expect_value(t, x.script.secrets[0], "login_api_key:password")
	testing.expect_value(t, x.script.secrets[1], "login_api_key:client_secret")
}

@(test)
a_self_hosted_server_needs_its_address :: proc(t: ^testing.T) {
	x := fx_make()
	defer fx_destroy(x)
	set_pref(x, "vault.server.region", "self")
	testing.expect_value(t, x.v.state, State.Logged_Out)
	testing.expect(t, !vault_login(&x.v, "me@example.com", "master"))
	testing.expect_value(t, x.script.spawned, 0)
	testing.expect(t, x.v.message != "")
}

@(test)
server_addresses_follow_the_region :: proc(t: ^testing.T) {
	s := settings_default()
	defer settings_destroy(&s)
	identity, api := server_urls(s)
	testing.expect_value(t, identity, US_IDENTITY_URL)
	testing.expect_value(t, api, US_API_URL)
	s.region = .EU
	identity, api = server_urls(s)
	testing.expect_value(t, identity, EU_IDENTITY_URL)
	testing.expect_value(t, api, EU_API_URL)
	s.region = .Self
	identity, api = server_urls(s)
	testing.expect_value(t, identity, "")
	delete(s.server_url)
	s.server_url = strings.clone("https://vault.example.org/")
	identity, api = server_urls(s)
	testing.expect_value(t, identity, "https://vault.example.org/identity")
	testing.expect_value(t, api, "https://vault.example.org/api")
	o := s
	o.region = .US
	testing.expect(t, !same_server(s, o))
	o.region = .Self
	testing.expect(t, same_server(s, o))
}

@(test)
the_account_file_names_its_server :: proc(t: ^testing.T) {
	text := account_text({email = "me@example.com", identity = EU_IDENTITY_URL, pin = true, passkey = true, remembered = "me@example.com"})
	f := account_parse(text)
	testing.expect_value(t, f.email, "me@example.com")
	testing.expect_value(t, f.identity, EU_IDENTITY_URL)
	testing.expect(t, f.pin && f.passkey)
	testing.expect_value(t, f.remembered, "me@example.com")
	// a file of the first version (the email only) names no server: it is no account of any server
	f = account_parse("me@example.com\n")
	testing.expect_value(t, f.identity, "")
	testing.expect(t, !f.pin && !f.passkey)
}

@(test)
an_account_of_another_server_is_not_remembered :: proc(t: ^testing.T) {
	x := fx_make(enabled = false, profile = true)
	defer fx_destroy(x)
	dir := join_path({x.profile, "vault"})
	_ = os.make_directory_all(dir)
	_ = os.write_entire_file(join_path({dir, ACCOUNT_FILE}), transmute([]byte)account_text({email = "me@example.com", identity = US_IDENTITY_URL}))
	set_pref(x, "vault.server.region", "eu")
	set_pref(x, "vault.enabled", "true")
	testing.expect_value(t, x.v.state, State.Logged_Out)
	set_pref(x, "vault.server.region", "us")   // (another server: the Vault starts again for it)
	testing.expect_value(t, x.v.state, State.Locked)
	testing.expect_value(t, x.v.email, "me@example.com")
}

@(test)
a_wrong_password_stops_the_helper_and_says_why :: proc(t: ^testing.T) {
	x := fx_make()
	defer fx_destroy(x)
	answer(x, "hello", `"ok":true,"account":"none","email":""`)
	answer(x, "login", `"ok":false,"error":"bad_credentials","message":"Username or password is incorrect."`)
	testing.expect(t, vault_login(&x.v, "me@example.com", "wrong"))
	settle(x)
	testing.expect_value(t, x.v.state, State.Logged_Out)
	testing.expect_value(t, x.v.message, "Username or password is incorrect.")
	testing.expect_value(t, x.script.closed, 1)
	testing.expect(t, x.v.t == nil)
}

@(test)
a_request_without_an_answer_fails_at_its_deadline :: proc(t: ^testing.T) {
	x := fx_make(virtual_clock = true)
	defer fx_destroy(x)
	answer(x, "hello", `"ok":true,"account":"none","email":""`)
	answer(x, "login", "")   // (never answers)
	testing.expect(t, vault_login(&x.v, "me@example.com", "master"))
	settle(x)
	testing.expect_value(t, x.v.state, State.Logging_In)
	host.clock_advance(&x.loop, 999 * 1_000_000)
	settle(x)
	testing.expect_value(t, x.v.state, State.Logging_In)
	host.clock_advance(&x.loop, 2 * 1_000_000)
	settle(x)
	testing.expect_value(t, x.v.state, State.Failed)
	testing.expect_value(t, x.script.closed, 1)
}

@(test)
a_helper_that_dies_leaves_the_vault_failed :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "logins_for", "EXIT")
	vault_ask_rows(&x.v, "https://example.com/login")
	settle(x)
	testing.expect_value(t, x.v.state, State.Failed)
	testing.expect_value(t, x.v.message, "The Vault helper stopped.")
	testing.expect_value(t, len(x.v.sets[.Page].rows), 0)
}

@(test)
rows_are_checked_again_with_wrens_list :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	// the helper (no list of its own) offers three; only the one of the page's site stays
	answer(x, "logins_for", `"ok":true,"rows":[` +
		`{"id":"1","name":"Mine","username":"me","uri":"https://alice.github.io","match":"domain"},` +
		`{"id":"2","name":"Theirs","username":"them","uri":"https://mallory.github.io","match":"domain"},` +
		`{"id":"3","name":"Http","username":"x","uri":"https://alice.github.io:8443","match":"host"}]`)
	vault_ask_rows(&x.v, "https://alice.github.io/login")
	testing.expect_value(t, x.v.sets[.Page].state, Rows_State.Asked)
	settle(x)
	rows, state, _ := vault_rows(&x.v)
	testing.expect_value(t, state, Rows_State.Ready)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].id, "1")
	vault_release_rows(&x.v)
	testing.expect_value(t, len(x.v.sets[.Page].rows), 0)
	testing.expect_value(t, x.v.sets[.Page].state, Rows_State.None)
}

@(test)
rows_of_a_document_left_meanwhile_are_dropped :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "logins_for", `"ok":true,"rows":[{"id":"1","name":"A","username":"a","uri":"https://a.example","match":"domain"}]`,
		`"ok":true,"rows":[{"id":"2","name":"B","username":"b","uri":"https://b.example","match":"domain"}]`)
	vault_ask_rows(&x.v, "https://a.example/")
	vault_ask_rows(&x.v, "https://b.example/")   // (before the first answer runs)
	settle(x)
	testing.expect_value(t, len(x.v.sets[.Page].rows), 1)
	testing.expect_value(t, x.v.sets[.Page].rows[0].id, "2")
}

// The tab's document and a frame's are two sets: a form in a frame lists the logins of its own origin.
@(test)
a_frame_has_its_own_rows :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "logins_for", `"ok":true,"rows":[{"id":"1","name":"Top","username":"a","uri":"https://top.example","match":"domain"}]`,
		`"ok":true,"rows":[{"id":"2","name":"Pay","username":"b","uri":"https://pay.example","match":"domain"}]`)
	vault_ask_rows(&x.v, "https://top.example/", .Page)
	vault_ask_rows(&x.v, "https://pay.example/form", .Frame)
	settle(x)
	testing.expect_value(t, x.v.sets[.Page].rows[0].id, "1")
	testing.expect_value(t, x.v.sets[.Frame].rows[0].id, "2")
	testing.expect(t, vault_row_find(&x.v, "2", .Page) == nil)   // (the frame's login is not the tab's: rule 10)
	vault_ask_rows(&x.v, "https://pay.example/form", .Frame)   // (asked already: no request)
	testing.expect_value(t, count_op(x, "logins_for"), 2)
	vault_lock(&x.v)
	settle(x)
	testing.expect_value(t, len(x.v.sets[.Frame].rows), 0)
	testing.expect_value(t, x.v.sets[.Page].key, "")
}

// An "equivalent" row stays only when the answer's own list holds the saved host's registrable domain; a rule this
// version does not know is dropped when the answer is read.
@(test)
equivalent_rows_are_checked_against_the_answers_list :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "logins_for", `"ok":true,"equivalent":["google.com"],"rows":[` +
		`{"id":"1","name":"Google","username":"me","uri":"https://accounts.google.com","match":"equivalent"},` +
		`{"id":"2","name":"Evil","username":"me","uri":"https://evil.example","match":"equivalent"},` +
		`{"id":"3","name":"Regex","username":"me","uri":"https://www.youtube.com","match":"regular_expression"}]`)
	vault_ask_rows(&x.v, "https://www.youtube.com/")
	settle(x)
	rows, state, _ := vault_rows(&x.v)
	testing.expect_value(t, state, Rows_State.Ready)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].id, "1")
}

// The palette's search: the helper's rows for one query; the same query is not asked again, an answer for an older
// query is dropped, and the rows go when the palette lets them go.
@(test)
a_search_keeps_the_rows_of_its_last_query :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "search", `"ok":true,"rows":[{"id":"1","name":"Git","username":"a","uri":"https://git.example","has_totp":true}]`,
		`"ok":true,"rows":[{"id":"2","name":"GitHub","username":"b","uri":"https://github.com"}]`)
	vault_search(&x.v, "git")
	vault_search(&x.v, "github")   // (before the first answer runs)
	settle(x)
	rows, state, key := vault_rows(&x.v, .Search)
	testing.expect_value(t, state, Rows_State.Ready)
	testing.expect_value(t, key, "github")
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].id, "2")
	vault_search(&x.v, "github")
	testing.expect_value(t, count_op(x, "search"), 2)
	vault_release_rows(&x.v, .Search)
	testing.expect_value(t, len(x.v.sets[.Search].rows), 0)
	testing.expect_value(t, x.v.sets[.Search].key, "")
}

// A new query keeps the last one's rows until its own come: the panel's list does not empty and fill at each letter.
@(test)
a_new_query_keeps_the_last_rows_until_its_own :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "search", `"ok":true,"rows":[{"id":"1","name":"Git","username":"a","uri":"https://git.example"}]`,
		`"ok":true,"rows":[{"id":"2","name":"GitHub","username":"b","uri":"https://github.com"},{"id":"3","name":"GitLab","username":"c","uri":"https://gitlab.com"}]`)
	vault_search(&x.v, "gi")
	settle(x)
	vault_search(&x.v, "git")
	rows, state, key := vault_rows(&x.v, .Search)
	testing.expect_value(t, state, Rows_State.Asked)
	testing.expect_value(t, key, "git")
	testing.expect_value(t, len(rows), 1)   // (the last query's, shown meanwhile)
	settle(x)
	rows, state, key = vault_rows(&x.v, .Search)
	testing.expect_value(t, state, Rows_State.Ready)
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[0].id, "2")
}

// A copy's value goes to the copy hook only, never to a page; a code comes with the seconds it stays valid.
@(test)
copies_go_to_the_clipboard_hook :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "fill", `"ok":true,"password":"s3cret"`, `"ok":true`)
	answer(x, "totp", `"ok":true,"totp":"123456","period":30,"remaining":12`)
	testing.expect(t, vault_copy(&x.v, "1", .Password))
	testing.expect(t, vault_copy(&x.v, "1", .Totp))
	testing.expect(t, vault_copy(&x.v, "1", .Username))   // (the item has no user name: said, nothing copied)
	settle(x)
	testing.expect_value(t, len(x.copied), 2)
	testing.expect_value(t, x.copied[0], "password:s3cret")
	testing.expect_value(t, x.copied[1], "totp:123456:12")
	testing.expect_value(t, len(x.filled), 0)
	testing.expect_value(t, x.v.fill_state, Fill_State.None)
	testing.expect_value(t, x.v.message, "This login has no user name.")
	testing.expect_value(t, x.script.notes[len(x.script.notes) - 1], "fields=username")
}

// A fill may ask for the code too (a one-time-code field in the group): it comes with the user name and the password.
@(test)
a_fill_can_carry_the_code :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "fill", `"ok":true,"username":"me","password":"s3cret","totp":"654321"`)
	testing.expect(t, vault_fill(&x.v, "1", {tab = 1, url = "https://example.com/"}, {.Username, .Password, .Totp}))
	settle(x)
	testing.expect_value(t, x.script.notes[len(x.script.notes) - 1], "fields=username,password,totp")
	testing.expect_value(t, len(x.filled), 1)
	testing.expect_value(t, x.filled[0], "me:s3cret:654321")
	testing.expect(t, !vault_fill(&x.v, "1", {}, {}))   // (nothing asked: nothing sent)
}

@(test)
a_locked_vault_neither_searches_nor_copies :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	vault_lock(&x.v)
	settle(x)
	vault_search(&x.v, "git")
	testing.expect(t, !vault_copy(&x.v, "1", .Password))
	testing.expect_value(t, count_op(x, "search"), 0)
	testing.expect_value(t, x.v.sets[.Search].state, Rows_State.None)
}

@(test)
a_fill_hands_the_values_to_the_shell_once :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "fill", `"ok":true,"username":"me","password":"s3cret"`)
	testing.expect(t, vault_fill(&x.v, "1", {tab = 1, url = "https://example.com/"}))
	testing.expect_value(t, x.v.fill_state, Fill_State.Requested)
	settle(x)
	testing.expect_value(t, x.v.fill_state, Fill_State.Applied)
	testing.expect_value(t, len(x.filled), 1)
	testing.expect_value(t, x.filled[0], "me:s3cret")
}

@(test)
a_fill_for_a_page_that_changed_is_dropped :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	x.refuse = true
	answer(x, "fill", `"ok":true,"username":"me","password":"s3cret"`)
	testing.expect(t, vault_fill(&x.v, "1", {tab = 1, url = "https://example.com/"}))
	settle(x)
	testing.expect_value(t, x.v.fill_state, Fill_State.Dropped)
	testing.expect_value(t, len(x.filled), 0)
}

@(test)
a_late_fill_is_dropped :: proc(t: ^testing.T) {
	x := unlocked_fx(t, virtual_clock = true)
	defer fx_destroy(x)
	answer(x, "fill", "")
	testing.expect(t, vault_fill(&x.v, "1", {tab = 1, url = "https://example.com/"}))
	host.clock_advance(&x.loop, 1001 * 1_000_000)
	settle(x)
	testing.expect_value(t, x.v.fill_state, Fill_State.Dropped)
	testing.expect_value(t, x.v.state, State.Unlocked)   // (a late fill does not stop the helper)
}

@(test)
lock_stops_the_helper :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	vault_lock(&x.v)
	settle(x)
	testing.expect_value(t, x.v.state, State.Locked)
	testing.expect(t, x.v.t == nil)
	testing.expect_value(t, x.script.closed, 1)
	testing.expect_value(t, last_op(x), "lock")
	testing.expect(t, !vault_fill(&x.v, "1", {}))
}

@(test)
unlock_then_one_sync :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	vault_lock(&x.v)
	settle(x)
	answer(x, "unlock", `"ok":false,"error":"bad_password","message":"The master password is wrong."`, `"ok":true`)
	answer(x, "sync", `"ok":true,"items":3,"last_sync":1`)
	testing.expect(t, vault_unlock(&x.v, "wrong"))
	settle(x)
	testing.expect_value(t, x.v.state, State.Locked)
	testing.expect_value(t, x.v.message, "The master password is wrong.")
	testing.expect(t, vault_unlock(&x.v, "master"))
	settle(x)
	testing.expect_value(t, x.v.state, State.Unlocked)
	testing.expect_value(t, last_op(x), "sync")
	testing.expect_value(t, x.v.last_sync, i64(1))
	testing.expect(t, !x.v.syncing)
}

@(test)
the_vault_locks_after_its_idle_time_and_activity_postpones_it :: proc(t: ^testing.T) {
	x := unlocked_fx(t, virtual_clock = true, idle_minutes = "1")
	defer fx_destroy(x)
	host.clock_advance(&x.loop, seconds(30))
	vault_activity(&x.v)   // (30 s after the unlock: no keepalive yet)
	testing.expect_value(t, count_op(x, "keepalive"), 0)
	host.clock_advance(&x.loop, seconds(40))   // (70 s: the first deadline passed, the activity moved it to 90 s)
	settle(x)
	testing.expect_value(t, x.v.state, State.Unlocked)
	vault_activity(&x.v)   // (a minute since the last keepalive: one goes)
	testing.expect_value(t, count_op(x, "keepalive"), 1)
	host.clock_advance(&x.loop, seconds(59))   // (129 s: the deadline is 130 s)
	settle(x)
	testing.expect_value(t, x.v.state, State.Unlocked)
	host.clock_advance(&x.loop, seconds(2))
	settle(x)
	testing.expect_value(t, x.v.state, State.Locked)
	testing.expect_value(t, last_op(x), "lock")
	testing.expect(t, x.v.message != "")
}

@(test)
no_idle_lock_with_zero_minutes :: proc(t: ^testing.T) {
	x := unlocked_fx(t, virtual_clock = true, idle_minutes = "0")
	defer fx_destroy(x)
	testing.expect_value(t, x.script.hello_idle, i64(0))   // (the helper has no deadline either)
	answer(x, "sync", `"ok":true,"items":0,"last_sync":2`)
	host.clock_advance(&x.loop, seconds(3 * 3600))
	settle(x)
	testing.expect_value(t, x.v.state, State.Unlocked)
}

@(test)
the_sync_runs_on_its_timer_while_unlocked :: proc(t: ^testing.T) {
	x := fx_make(virtual_clock = true)
	defer fx_destroy(x)
	set_pref(x, "vault.sync.interval_minutes", "5")
	set_pref(x, "vault.lock.idle_minutes", "0")
	answer(x, "hello", `"ok":true,"account":"none","email":""`)
	answer(x, "login", `"ok":true,"result":"ok"`)
	answer(x, "sync", `"ok":true,"items":4,"last_sync":7`)
	vault_login(&x.v, "me@example.com", "master")
	settle(x)
	testing.expect_value(t, count_op(x, "sync"), 0)
	host.clock_advance(&x.loop, seconds(5 * 60))
	settle(x)
	testing.expect_value(t, count_op(x, "sync"), 1)
	host.clock_advance(&x.loop, seconds(5 * 60))
	settle(x)
	testing.expect_value(t, count_op(x, "sync"), 2)
	vault_lock(&x.v)
	settle(x)
	host.clock_advance(&x.loop, seconds(10 * 60))
	settle(x)
	testing.expect_value(t, count_op(x, "sync"), 2)   // (locked: no timer runs)
}

@(test)
the_helper_locking_itself_is_a_lock_not_a_failure :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "sync", "LOCKED")
	testing.expect(t, vault_sync(&x.v))
	settle(x)
	testing.expect_value(t, x.v.state, State.Locked)
	testing.expect(t, x.v.t == nil)
	testing.expect(t, !x.v.syncing)
	testing.expect_value(t, x.v.message, "The Vault locked itself after a time without activity.")
}

// The server refused the session and the helper could not renew it: the account is logged out (only a new login opens
// one), its message kept for the login.
@(test)
a_session_the_server_ended_logs_out :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "sync", `"ok":false,"error":"session_expired","message":"The server ended this session. Log in again with the master password."`)
	testing.expect(t, vault_sync(&x.v))
	settle(x)
	testing.expect_value(t, x.v.state, State.Logged_Out)
	testing.expect_value(t, x.v.message, "The server ended this session. Log in again with the master password.")
	testing.expect_value(t, last_op(x), "logout")
}

@(test)
a_pin_unlocks_and_too_many_wrong_ones_remove_it :: proc(t: ^testing.T) {
	x := unlocked_fx(t, profile = true)
	defer fx_destroy(x)
	testing.expect(t, !vault_pin_set(&x.v, "12"))   // (too short: nothing is sent)
	answer(x, "pin_set", `"ok":true`)
	testing.expect(t, vault_pin_set(&x.v, "1234"))
	settle(x)
	testing.expect(t, x.v.pin)
	vault_lock(&x.v)
	settle(x)
	// the account file says so: the next start offers the PIN without starting the helper
	file := join_path({x.profile, "vault", ACCOUNT_FILE})
	bytes, err := os.read_entire_file(file, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, account_parse(string(bytes)).pin)

	answer(x, "unlock",
		`"ok":false,"error":"bad_pin","message":"The PIN is wrong. 4 tries left.","tries_left":4`,
		`"ok":false,"error":"pin_reset","message":"Too many wrong PINs: the PIN was removed. Unlock with the master password."`)
	testing.expect(t, vault_unlock(&x.v, "0000", pin = true))
	settle(x)
	testing.expect_value(t, x.v.state, State.Locked)
	testing.expect(t, x.v.pin)
	testing.expect(t, vault_unlock(&x.v, "0000", pin = true))
	settle(x)
	testing.expect(t, !x.v.pin)
	testing.expect(t, !vault_unlock(&x.v, "1234", pin = true))   // (no PIN any more: the master password only)
	bytes, err = os.read_entire_file(file, context.temp_allocator)
	testing.expect(t, !account_parse(string(bytes)).pin)
	testing.expect_value(t, x.script.secrets[len(x.script.secrets) - 1], "unlock:pin")
}

@(test)
no_pin_without_a_kept_profile :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	testing.expect(t, !vault_can_pin(&x.v))
	testing.expect(t, !vault_pin_set(&x.v, "1234"))
	testing.expect_value(t, count_op(x, "pin_set"), 0)
}

@(test)
logout_forgets_the_account :: proc(t: ^testing.T) {
	x := unlocked_fx(t, profile = true)
	defer fx_destroy(x)
	file := join_path({x.profile, "vault", ACCOUNT_FILE})
	testing.expect(t, os.exists(file))
	testing.expect(t, vault_logout(&x.v))
	settle(x)
	testing.expect_value(t, x.v.state, State.Logged_Out)
	testing.expect_value(t, x.v.email, "")
	testing.expect_value(t, last_op(x), "logout")
	// the account goes; the last email that logged in stays for the next login dialog (vault.login.remember_email)
	bytes, err := os.read_entire_file(file, context.temp_allocator)
	testing.expect(t, err == nil)
	f := account_parse(string(bytes))
	testing.expect(t, f.email == "" && f.identity == "" && !f.pin && !f.passkey)
	testing.expect_value(t, x.v.remembered, f.remembered)
}

@(test)
a_locked_logout_starts_a_helper_for_it :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	vault_lock(&x.v)
	settle(x)
	testing.expect(t, vault_logout(&x.v))
	settle(x)
	testing.expect_value(t, x.script.spawned, 2)
	testing.expect_value(t, x.script.ops[len(x.script.ops) - 2], "hello")
	testing.expect_value(t, last_op(x), "logout")
	testing.expect_value(t, x.v.state, State.Logged_Out)
}

@(test)
disabling_stops_everything :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	set_pref(x, "vault.enabled", "false")
	testing.expect_value(t, x.v.state, State.Disabled)
	testing.expect(t, x.v.t == nil)
	testing.expect_value(t, x.script.closed, 1)
}

////////////////////////////////
// Protocol 5: saves, the save offer, the generator, cards and identities

// A save creates a login (no item) or updates one; its answer is a message, and the kept rows are asked again so that
// the new login shows at once.
@(test)
a_save_sends_the_login_then_asks_the_rows_again :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "logins_for", `"ok":true,"rows":[]`, `"ok":true,"rows":[{"id":"9","name":"example.com","username":"me","uri":"https://example.com","match":"domain"}]`)
	answer(x, "save", `"ok":true,"item":"9"`)
	vault_ask_rows(&x.v, "https://example.com/login")
	settle(x)
	testing.expect(t, !vault_save(&x.v, "", "example.com", "https://example.com/login", "me", ""))   // (a new login needs a password)
	testing.expect(t, vault_save(&x.v, "", "example.com", "https://example.com/login", "me", "s3cret"))
	settle(x)
	testing.expect_value(t, x.v.message, "The login is saved in the Vault.")
	testing.expect_value(t, count_op(x, "logins_for"), 2)
	rows, _, _ := vault_rows(&x.v)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, x.script.secrets[len(x.script.secrets) - 1], "save:password")
}

@(test)
a_refused_save_says_why :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "save", `"ok":false,"error":"save_failed","message":"The server cannot be reached."`)
	testing.expect(t, vault_save(&x.v, "1", "example.com", "", "", "new"))
	settle(x)
	testing.expect_value(t, x.v.message, "The login was not saved: The server cannot be reached.")
	testing.expect_value(t, x.v.state, State.Unlocked)   // (a refused save does not stop the helper)
}

@(private = "file")
offer_fx :: proc(t: ^testing.T, profile := false) -> ^Fx {
	x := unlocked_fx(t, profile = profile)
	answer(x, "logins_for", `"ok":true,"rows":[{"id":"1","name":"Site","username":"Me@Example.com","uri":"https://example.com","match":"domain"}]`)
	vault_ask_rows(&x.v, "https://example.com/login")
	settle(x)
	return x
}

// The save offer: a new user name is a Save, a known one with another password an Update, the same login nothing.
@(test)
a_sent_login_is_offered_for_a_save_or_an_update :: proc(t: ^testing.T) {
	x := offer_fx(t)
	defer fx_destroy(x)
	testing.expect(t, vault_offer_capture(&x.v, "https://example.com/login", "other", "pw"))
	testing.expect_value(t, x.v.offer.state, Offer_State.Save)
	testing.expect_value(t, x.v.offer.host, "example.com")
	testing.expect_value(t, count_op(x, "fill"), 0)   // (nothing to compare: no login has this user name)

	answer(x, "fill", `"ok":true,"password":"old"`, `"ok":true,"password":"same"`)
	testing.expect(t, vault_offer_capture(&x.v, "https://example.com/login", " me@example.com ", "new"))
	testing.expect_value(t, x.v.offer.state, Offer_State.Checking)
	settle(x)
	testing.expect_value(t, x.v.offer.state, Offer_State.Update)
	testing.expect_value(t, x.v.offer.item, "1")
	testing.expect_value(t, len(x.filled), 0)   // (the compared password never reaches a page)

	testing.expect(t, vault_offer_capture(&x.v, "https://example.com/login", "me@example.com", "same"))
	settle(x)
	testing.expect_value(t, x.v.offer.state, Offer_State.None)
	testing.expect_value(t, x.v.offer.password, "")

	// a form of a password alone (no user name): the site's logins are compared; the same password, nothing; another one,
	// an Update of the one login it can be (it offered a Save each time: no login has the user name "")
	answer(x, "fill", `"ok":true,"password":"same"`, `"ok":true,"password":"old"`)
	testing.expect(t, vault_offer_capture(&x.v, "https://example.com/admin", "", "same"))
	settle(x)
	testing.expect_value(t, x.v.offer.state, Offer_State.None)
	testing.expect(t, vault_offer_capture(&x.v, "https://example.com/admin", "", "new"))
	settle(x)
	testing.expect_value(t, x.v.offer.state, Offer_State.Update)
	testing.expect_value(t, x.v.offer.item, "1")
}

@(test)
an_accepted_offer_saves_and_a_lock_drops_one :: proc(t: ^testing.T) {
	x := offer_fx(t)
	defer fx_destroy(x)
	answer(x, "save", `"ok":true,"item":"2"`)
	testing.expect(t, vault_offer_capture(&x.v, "https://other.example/", "u", "pw"))   // (no rows of that site yet: it waits)
	testing.expect_value(t, x.v.offer.state, Offer_State.Waiting)
	testing.expect(t, !vault_offer_capture(&x.v, "https://example.com/login", "u", ""))   // (no password)
	testing.expect(t, vault_offer_capture(&x.v, "https://example.com/login", "new", "pw"))
	testing.expect(t, vault_offer_accept(&x.v))
	testing.expect_value(t, x.v.offer.state, Offer_State.Saving)
	testing.expect_value(t, x.v.offer.password, "")   // (it crossed: zeroed)
	settle(x)
	testing.expect_value(t, x.v.offer.state, Offer_State.None)
	testing.expect_value(t, last_op(x), "logins_for")   // (the rows asked again after the save)
	testing.expect(t, vault_offer_capture(&x.v, "https://example.com/login", "new2", "pw"))   // (the rows came again)
	vault_lock(&x.v)
	settle(x)
	testing.expect_value(t, x.v.offer.state, Offer_State.None)
	testing.expect_value(t, x.v.offer.password, "")
}

@(test)
an_offer_is_not_made_when_turned_off :: proc(t: ^testing.T) {
	x := offer_fx(t)
	defer fx_destroy(x)
	set_pref(x, "vault.save.offer", "false")
	testing.expect(t, !vault_offer_capture(&x.v, "https://example.com/login", "other", "pw"))
	testing.expect_value(t, x.v.offer.state, Offer_State.None)
}

// "Never for this site": the host is kept in the profile and no offer is made there again, after a restart too.
@(test)
never_for_this_site_is_remembered :: proc(t: ^testing.T) {
	x := offer_fx(t, profile = true)
	defer fx_destroy(x)
	testing.expect(t, vault_offer_capture(&x.v, "https://example.com/login", "other", "pw"))
	vault_offer_dismiss(&x.v, never = true)
	settle(x)
	testing.expect_value(t, x.v.offer.state, Offer_State.None)
	testing.expect(t, vault_never_has(&x.v, "EXAMPLE.com"))
	testing.expect(t, !vault_offer_capture(&x.v, "https://example.com/login", "other", "pw"))
	bytes, err := os.read_entire_file(join_path({x.profile, "vault", NEVER_FILE}), context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect_value(t, string(bytes), "example.com\n")
	// a new start reads it
	set_pref(x, "vault.enabled", "false")
	strings_free(&x.v.never)
	x.v.never = make([dynamic]string, base.process_allocator())
	set_pref(x, "vault.enabled", "true")
	testing.expect(t, vault_never_has(&x.v, "example.com"))
}

@(test)
the_never_list_is_one_host_a_line :: proc(t: ^testing.T) {
	hosts := never_parse("a.example\n\n B.Example \na.example\r\n")
	defer strings_free(&hosts)
	testing.expect_value(t, len(hosts), 2)
	testing.expect_value(t, hosts[1], "b.example")
	testing.expect_value(t, never_text(hosts[:]), "a.example\nb.example\n")
}

// The generator: the value comes once, to the taker; a lock zeroes one not taken.
@(test)
a_generated_value_is_taken_once :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "generate", `"ok":true,"value":"correct-horse-battery"`, `"ok":false,"error":"bad_request","message":"The length is out of range."`)
	o := x.v.settings.generator
	o.passphrase = true
	id := vault_generate(&x.v, o)
	testing.expect(t, id != 0)
	settle(x)
	value, got, ok := vault_generated_take(&x.v)
	testing.expect(t, ok)
	testing.expect_value(t, got, id)
	testing.expect_value(t, value, "correct-horse-battery")
	string_wipe(&value)
	_, _, again := vault_generated_take(&x.v)
	testing.expect(t, !again)
	testing.expect(t, vault_generate(&x.v, x.v.settings.generator) != 0)
	settle(x)
	_, _, none := vault_generated_take(&x.v)
	testing.expect(t, !none)
	testing.expect_value(t, x.v.message, "The length is out of range.")
	vault_lock(&x.v)
	settle(x)
	testing.expect_value(t, vault_generate(&x.v, x.v.settings.generator), u64(0))
}

// A card's fill asks for the card's fields by their names, and its values reach the fill hook.
@(test)
a_card_fill_asks_for_the_cards_fields :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "fill", `"ok":true,"number":"4111111111111111","exp_month":"7","exp_year":"2031","code":"123"`)
	testing.expect(t, vault_fill(&x.v, "c1", {tab = 1, url = "https://shop.example/pay"}, {.Cardholder, .Number, .Exp_Month, .Exp_Year, .Code}))
	settle(x)
	testing.expect_value(t, x.script.notes[len(x.script.notes) - 1], "fields=cardholder,number,exp_month,exp_year,code")
	testing.expect_value(t, len(x.filled), 1)
	testing.expect_value(t, x.filled[0], "card:4111111111111111:7/2031")
}

// The cards of a card field (slot Items, one kind asked) are their own set: the palette's search does not replace it,
// and the same kinds asked again send nothing; other kinds start the set again.
@(test)
the_items_set_is_apart_from_the_search :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "search", `"ok":true,"total":1,"rows":[{"id":"c","kind":"card","name":"Visa","username":"Visa *1111","uri":""}]`,
		`"ok":true,"total":1,"rows":[{"id":"l","kind":"login","name":"Git","username":"a","uri":"https://git.example"}]`,
		`"ok":true,"total":1,"rows":[{"id":"i","kind":"identity","name":"Me","username":"Ada","uri":""}]`)
	vault_search(&x.v, "", .Items, {.Card})
	vault_search(&x.v, "git")
	settle(x)
	testing.expect_value(t, x.script.notes[0], "search=0+100:card")
	testing.expect_value(t, x.script.notes[1], "search=0+100:login,card,identity")
	items, state, _ := vault_rows(&x.v, .Items)
	testing.expect_value(t, state, Rows_State.Ready)
	testing.expect_value(t, len(items), 1)
	testing.expect_value(t, items[0].kind, Item_Kind.Card)
	found, _, _ := vault_rows(&x.v, .Search)
	testing.expect_value(t, len(found), 1)
	vault_search(&x.v, "", .Items, {.Card})
	testing.expect_value(t, count_op(x, "search"), 2)
	vault_search(&x.v, "", .Items, {.Identity})
	settle(x)
	testing.expect_value(t, x.script.notes[2], "search=0+100:identity")
	items, _, _ = vault_rows(&x.v, .Items)
	testing.expect_value(t, items[0].id, "i")
	vault_ask_rows(&x.v, "https://x.example/", .Items)   // (not a document's set: nothing is asked)
	testing.expect_value(t, count_op(x, "logins_for"), 0)
}

// Rows of one search page, with the helper's count: `n` rows named from `first`.
@(private = "file")
page_rows :: proc(first, n, total: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `"ok":true,"total":`)
	strings.write_string(&b, fmt.tprint(total))
	strings.write_string(&b, `,"rows":[`)
	for i in 0 ..< n {
		if i > 0 { strings.write_byte(&b, ',') }
		id := fmt.tprint(first + i)
		strings.write_string(&b, strings.concatenate({`{"id":"`, id, `","kind":"login","name":"Item `, id, `","username":"u","uri":""}`}, context.temp_allocator))
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// A search comes page by page: each next page is asked at its offset and appended, one at a time, until the count.
@(test)
a_search_comes_page_by_page :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "search", page_rows(0, 2, 5), page_rows(2, 2, 5), page_rows(4, 1, 5))
	testing.expect(t, !vault_search_more(&x.v))   // (nothing asked yet)
	vault_search(&x.v, "", limit = 2)
	testing.expect(t, !vault_search_more(&x.v))   // (the first page has not come)
	settle(x)
	rows, state, _ := vault_rows(&x.v, .Search)
	testing.expect_value(t, state, Rows_State.Ready)
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, vault_search_total(&x.v), 5)
	testing.expect(t, vault_search_more(&x.v))
	testing.expect(t, !vault_search_more(&x.v))   // (one page on its way at a time)
	settle(x)
	testing.expect(t, vault_search_more(&x.v))
	settle(x)
	rows, _, _ = vault_rows(&x.v, .Search)
	testing.expect_value(t, len(rows), 5)
	testing.expect_value(t, rows[4].id, "4")
	testing.expect(t, !vault_search_more(&x.v))   // (every row is there)
	testing.expect_value(t, count_op(x, "search"), 3)
	testing.expect_value(t, x.script.notes[1], "search=2+2:login,card,identity")
	testing.expect_value(t, x.script.notes[2], "search=4+2:login,card,identity")
}

// A page of an older query comes after a new query was asked: it is dropped, and the new query's rows are alone.
@(test)
a_late_page_of_an_older_query_is_dropped :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "search", page_rows(0, 2, 4), page_rows(2, 2, 4), page_rows(100, 1, 1))
	vault_search(&x.v, "a", limit = 2)
	settle(x)
	testing.expect(t, vault_search_more(&x.v))
	vault_search(&x.v, "b", limit = 2)   // (before the page of "a" runs)
	settle(x)
	rows, state, key := vault_rows(&x.v, .Search)
	testing.expect_value(t, state, Rows_State.Ready)
	testing.expect_value(t, key, "b")
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].id, "100")
	testing.expect_value(t, vault_search_total(&x.v), 1)
}

// A page that fails keeps the rows there, and no other page is asked for this query (the shell asks at each frame).
@(test)
a_failed_page_keeps_the_rows :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "search", page_rows(0, 2, 6), `"ok":false,"error":"locked","message":"no"`)
	vault_search(&x.v, "", limit = 2)
	settle(x)
	testing.expect(t, vault_search_more(&x.v))
	settle(x)
	rows, state, _ := vault_rows(&x.v, .Search)
	testing.expect_value(t, state, Rows_State.Ready)
	testing.expect_value(t, len(rows), 2)
	testing.expect(t, !vault_search_more(&x.v))
	testing.expect_value(t, count_op(x, "search"), 2)
}

// The save offer before the site's logins are known: it waits for them, then compares.
@(test)
an_offer_waits_for_the_sites_logins :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "logins_for", `"ok":true,"rows":[{"id":"1","name":"Site","username":"me","uri":"https://example.com","match":"domain"}]`)
	answer(x, "fill", `"ok":true,"password":"old"`)
	testing.expect(t, vault_offer_capture(&x.v, "https://example.com/login", "me", "new"))
	testing.expect_value(t, x.v.offer.state, Offer_State.Waiting)
	testing.expect_value(t, count_op(x, "fill"), 0)
	// (the rows of another page of the same host decide too: the page after a login)
	vault_ask_rows(&x.v, "https://example.com/home")
	settle(x)
	testing.expect_value(t, x.v.offer.state, Offer_State.Update)
	testing.expect_value(t, x.v.offer.item, "1")
}

// The site's logins never come: the offer goes after OFFER_WAIT_MS, its password zeroed.
@(test)
a_waiting_offer_ends_after_its_wait :: proc(t: ^testing.T) {
	x := unlocked_fx(t, virtual_clock = true, idle_minutes = "0")
	defer fx_destroy(x)
	testing.expect(t, vault_offer_capture(&x.v, "https://example.com/login", "me", "pw"))
	testing.expect_value(t, x.v.offer.state, Offer_State.Waiting)
	host.clock_advance(&x.loop, seconds(9))
	settle(x)
	testing.expect_value(t, x.v.offer.state, Offer_State.Waiting)
	host.clock_advance(&x.loop, seconds(2))
	settle(x)
	testing.expect_value(t, x.v.offer.state, Offer_State.None)
	testing.expect_value(t, x.v.offer.password, "")
	// (rows that come later make no offer)
	answer(x, "logins_for", `"ok":true,"rows":[]`)
	vault_ask_rows(&x.v, "https://example.com/login")
	settle(x)
	testing.expect_value(t, x.v.offer.state, Offer_State.None)
}

@(test)
card_and_identity_copies_name_what_is_missing :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	answer(x, "fill", `"ok":true,"number":"4111"`, `"ok":true`)
	testing.expect(t, vault_copy(&x.v, "c", .Number))
	testing.expect(t, vault_copy(&x.v, "i", .Email))
	settle(x)
	testing.expect_value(t, len(x.copied), 1)
	testing.expect_value(t, x.copied[0], "number:4111")
	testing.expect_value(t, x.v.message, "This identity has no email.")
	testing.expect_value(t, x.script.notes[len(x.script.notes) - 1], "fields=email")
}

// What a page's passkey request heard from the Vault (copies: the answer is zeroed after the callback).
@(private = "file")
Heard :: struct {
	calls:  int,
	ticket: u64,
	ok:     bool,
	error:  string,
	rows:   [dynamic]string,   // "item:name:username:credential_id:user_handle"
	signed: string,            // "authenticator_data:signature:user_handle:credential_id"
}

@(private = "file")
heard_passkey :: proc(user: rawptr, ticket: u64, a: ^Passkey_Answer) {
	h := (^Heard)(user)
	h.calls += 1
	h.ticket, h.ok = ticket, a.ok
	delete(h.error)
	h.error = strings.clone(a.error)
	for r in a.rows {
		append(&h.rows, strings.concatenate({r.item, ":", r.name, ":", r.username, ":", r.credential_id, ":", r.user_handle}))
	}
	s := a.signed
	if s.signature != "" {
		delete(h.signed)
		h.signed = strings.concatenate({s.authenticator_data, ":", s.signature, ":", s.user_handle, ":", s.credential_id})
	}
}

@(private = "file")
heard_free :: proc(h: ^Heard) {
	delete(h.error)
	for r in h.rows { delete(r) }
	delete(h.rows)
	delete(h.signed)
}

@(test)
passkeys_for_gives_the_sites_rows_to_its_caller :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	heard: Heard
	defer heard_free(&heard)
	answer(x, "passkeys_for",
		`"ok":true,"rows":[{"item":"i1","name":"Example","username":"me","credential_id":"Y3JlZA","user_handle":"dXNlcg"},{"item":"","name":"No item","credential_id":"eA"}]`)
	ticket := vault_passkeys_for(&x.v, "example.com", {"Y3JlZA", "b3RoZXI"}, heard_passkey, &heard)
	testing.expect(t, ticket != 0)
	testing.expect_value(t, heard.calls, 0)   // (the answer comes through the loop)
	settle(x)
	testing.expect_value(t, heard.calls, 1)
	testing.expect_value(t, heard.ticket, ticket)
	testing.expect(t, heard.ok)
	testing.expect_value(t, len(heard.rows), 1)   // (a row without its item is no passkey to use)
	testing.expect_value(t, heard.rows[0], "i1:Example:me:Y3JlZA:dXNlcg")
	testing.expect_value(t, x.script.notes[len(x.script.notes) - 1], "passkeys=example.com:Y3JlZA,b3RoZXI")
	testing.expect_value(t, x.v.state, State.Unlocked)
}

@(test)
a_locked_vault_or_the_offer_off_asks_nothing :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	heard: Heard
	defer heard_free(&heard)
	set_pref(x, "vault.passkeys.offer", "false")
	testing.expect(t, !vault_passkeys_offered(&x.v))
	testing.expect_value(t, vault_passkeys_for(&x.v, "example.com", nil, heard_passkey, &heard), u64(0))
	set_pref(x, "vault.passkeys.offer", "true")
	testing.expect(t, vault_passkeys_offered(&x.v))
	vault_lock(&x.v)
	settle(x)
	testing.expect(t, !vault_passkeys_offered(&x.v))
	testing.expect_value(t, vault_passkeys_for(&x.v, "example.com", nil, heard_passkey, &heard), u64(0))
	testing.expect_value(t, vault_passkey_assert(&x.v, "i1", "Y3JlZA", "example.com", "aGFzaA", heard_passkey, &heard), u64(0))
	testing.expect_value(t, heard.calls, 0)
	testing.expect_value(t, count_op(x, "passkeys_for"), 0)
}

@(test)
passkey_assert_gives_the_signed_values_or_the_refusal :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	heard: Heard
	defer heard_free(&heard)
	answer(x, "passkey_assert",
		`"ok":true,"authenticator_data":"YWQ","signature":"c2ln","user_handle":"dWg","credential_id":"Y3JlZA"`,
		`"ok":false,"error":"no_item","message":"The passkey is not in the vault any more."`,
		`"ok":true,"authenticator_data":"YWQ","credential_id":"Y3JlZA"`)
	ticket := vault_passkey_assert(&x.v, "i1", "Y3JlZA", "example.com", "aGFzaA", heard_passkey, &heard)
	testing.expect(t, ticket != 0)
	settle(x)
	testing.expect_value(t, heard.calls, 1)
	testing.expect_value(t, heard.ticket, ticket)
	testing.expect(t, heard.ok)
	testing.expect_value(t, heard.signed, "YWQ:c2ln:dWg:Y3JlZA")
	testing.expect_value(t, x.script.notes[len(x.script.notes) - 1], "assert=i1,Y3JlZA,example.com,aGFzaA")
	testing.expect(t, vault_passkey_assert(&x.v, "i1", "Y3JlZA", "example.com", "aGFzaA", heard_passkey, &heard) != 0)
	settle(x)
	testing.expect_value(t, heard.calls, 2)
	testing.expect(t, !heard.ok)
	testing.expect_value(t, heard.error, "no_item")
	// (an answer without a signature is no assertion)
	testing.expect(t, vault_passkey_assert(&x.v, "i1", "Y3JlZA", "example.com", "aGFzaA", heard_passkey, &heard) != 0)
	settle(x)
	testing.expect_value(t, heard.calls, 3)
	testing.expect(t, !heard.ok)
	testing.expect_value(t, heard.error, "assert_failed")
	testing.expect_value(t, x.v.state, State.Unlocked)
}

@(test)
a_passkey_request_hears_a_timeout_a_lock_or_nothing_once_forgotten :: proc(t: ^testing.T) {
	x := unlocked_fx(t, virtual_clock = true, idle_minutes = "0")
	defer fx_destroy(x)
	heard: Heard
	defer heard_free(&heard)
	answer(x, "passkeys_for", "")
	answer(x, "passkey_assert", "")
	// past vault.request.timeout_ms: "timeout", and the helper goes on
	ticket := vault_passkeys_for(&x.v, "example.com", nil, heard_passkey, &heard)
	testing.expect(t, ticket != 0)
	host.clock_advance(&x.loop, 999 * 1_000_000)
	settle(x)
	testing.expect_value(t, heard.calls, 0)
	host.clock_advance(&x.loop, 2 * 1_000_000)
	settle(x)
	testing.expect_value(t, heard.calls, 1)
	testing.expect_value(t, heard.error, "timeout")
	testing.expect_value(t, x.v.state, State.Unlocked)
	// a forgotten request is never heard
	ticket = vault_passkey_assert(&x.v, "i1", "Y3JlZA", "example.com", "aGFzaA", heard_passkey, &heard)
	vault_passkey_forget(&x.v, ticket)
	host.clock_advance(&x.loop, 1001 * 1_000_000)
	settle(x)
	testing.expect_value(t, heard.calls, 1)
	// a lock while it waits: "locked", at once
	ticket = vault_passkey_assert(&x.v, "i1", "Y3JlZA", "example.com", "aGFzaA", heard_passkey, &heard)
	vault_lock(&x.v)
	testing.expect_value(t, heard.calls, 2)
	testing.expect_value(t, heard.ticket, ticket)
	testing.expect_value(t, heard.error, "locked")
	settle(x)
	testing.expect_value(t, heard.calls, 2)
}
