package vault

// The Vault against a fake helper: an in-process transport that answers each request from a script, through the loop as
// the real one does. Tests wait with blocking_settle (bounded) or move a virtual clock; none sleeps.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:config"
import "wb:host"

@(private = "file")
Script :: struct {
	answers:  map[string][dynamic]string,   // op -> the answers' fields, used in order (the last one stays); "" never answers; "EXIT": the helper dies
	used:     map[string]int,               // op -> the answers already given
	ops:      [dynamic]string,              // what the helper was asked, in order
	secrets:  [dynamic]string,              // "op:key" for each password or totp that crossed
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
	for key in ([]string{"password", "totp"}) {
		if _, has := o[key]; has { append(&f.script.secrets, fmt.aprintf("%s:%s", op, key)) }
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
	}
	// (no fmt format here: fmt reads a "{" as the start of an argument index)
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

@(private = "file")
fx_make :: proc(enabled := true, virtual_clock := false) -> ^Fx {
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
	the_script = &x.script
	hooks := Hooks{
		user = x,
		changed = proc(user: rawptr) { (^Fx)(user).changes += 1 },
		fill = proc(user: rawptr, values: ^Fill_Values) -> bool {
			x := (^Fx)(user)
			if x.refuse { return false }
			append(&x.filled, fmt.aprintf("%s:%s", values.username, values.password))
			return true
		},
	}
	vault_init(&x.v, &x.loop, &x.pool, &x.prefs, "", "test", hooks, fake_spawn)
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
	for s in x.script.ops { delete(s) }
	delete(x.script.ops)
	for s in x.script.secrets { delete(s) }
	delete(x.script.secrets)
	for s in x.filled { delete(s) }
	delete(x.filled)
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
unlocked_fx :: proc(t: ^testing.T) -> ^Fx {
	x := fx_make()
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
}

@(test)
a_missing_helper_is_said :: proc(t: ^testing.T) {
	x := fx_make(enabled = false)
	defer fx_destroy(x)
	_ = config.set_from_string(&x.prefs, "vault.helper.path", "/nonexistent/wren-vault", .User)
	_ = config.set_from_string(&x.prefs, "vault.enabled", "true", .User)
	vault_prefs_changed(&x.v, &x.prefs)
	settle(x)
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
	testing.expect(t, !vault_login(&x.v, "", "", "   "))   // (no code: nothing is sent)
	testing.expect(t, vault_login(&x.v, "", "", "123456"))
	settle(x)
	testing.expect_value(t, x.v.state, State.Unlocked)
	testing.expect_value(t, len(x.script.secrets), 2)
	testing.expect_value(t, x.script.secrets[0], "login:password")
	testing.expect_value(t, x.script.secrets[1], "login:totp")
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
	x := fx_make(virtual_clock = true)
	defer fx_destroy(x)
	answer(x, "hello", `"ok":true,"account":"none","email":""`)
	answer(x, "login", `"ok":true,"result":"ok"`)
	vault_login(&x.v, "me@example.com", "master")
	settle(x)
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
	testing.expect_value(t, x.script.ops[len(x.script.ops) - 1], "lock")
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
	testing.expect_value(t, x.script.ops[len(x.script.ops) - 1], "sync")
}

@(test)
disabling_stops_everything :: proc(t: ^testing.T) {
	x := unlocked_fx(t)
	defer fx_destroy(x)
	_ = config.set_from_string(&x.prefs, "vault.enabled", "false", .User)
	vault_prefs_changed(&x.v, &x.prefs)
	settle(x)
	testing.expect_value(t, x.v.state, State.Disabled)
	testing.expect(t, x.v.t == nil)
	testing.expect_value(t, x.script.closed, 1)
}
