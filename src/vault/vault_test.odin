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
	filled:  [dynamic]string,   // "user:pass" of each applied fill
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
			append(&x.filled, strings.concatenate({values.username, ":", values.password}))
			return true
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
	text := account_text("me@example.com", EU_IDENTITY_URL, true)
	email, server, pin := account_parse(text)
	testing.expect_value(t, email, "me@example.com")
	testing.expect_value(t, server, EU_IDENTITY_URL)
	testing.expect(t, pin)
	// a file of the first version (the email only) names no server: it is no account of any server
	email, server, pin = account_parse("me@example.com\n")
	testing.expect_value(t, server, "")
	testing.expect(t, !pin)
}

@(test)
an_account_of_another_server_is_not_remembered :: proc(t: ^testing.T) {
	x := fx_make(enabled = false, profile = true)
	defer fx_destroy(x)
	dir := join_path({x.profile, "vault"})
	_ = os.make_directory_all(dir)
	_ = os.write_entire_file(join_path({dir, ACCOUNT_FILE}), account_text("me@example.com", US_IDENTITY_URL, false))
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
	testing.expect_value(t, len(x.v.rows), 0)
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
	testing.expect_value(t, x.v.rows_state, Rows_State.Asked)
	settle(x)
	testing.expect_value(t, x.v.rows_state, Rows_State.Ready)
	testing.expect_value(t, len(x.v.rows), 1)
	testing.expect_value(t, x.v.rows[0].id, "1")
	vault_release_rows(&x.v)
	testing.expect_value(t, len(x.v.rows), 0)
	testing.expect_value(t, x.v.rows_state, Rows_State.None)
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
	testing.expect_value(t, len(x.v.rows), 1)
	testing.expect_value(t, x.v.rows[0].id, "2")
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
	_, _, pin := account_parse(string(bytes))
	testing.expect(t, pin)

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
	_, _, pin = account_parse(string(bytes))
	testing.expect(t, !pin)
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
	testing.expect(t, !os.exists(file))
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
