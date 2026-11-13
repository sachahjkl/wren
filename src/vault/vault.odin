// Package vault: the client of the Vault helper (docs/bitwarden.md). It starts and stops the helper, speaks its pipe
// protocol, keeps the one state of the Vault that every surface reads, and checks the rows of a page with Wren's own
// Public Suffix List. It has no interface and no dependency on the browser or the pages: the shell (src/browser/vault_*)
// draws it and applies a fill.
//
// Threads: every procedure here runs on the loop thread and returns at once. Starting the helper, the pipes, the files and
// the check of the rows run on the transport's threads and on the blocking pool; their results are posted to the loop.
//
// Secrets: a password, a PIN or a code goes from the caller into one frame, which is zeroed once written. A fill's or a
// copy's values live in one Answer for the time of the `fill` or `copy` hook, then are zeroed. Rows (names, user names)
// live in four sets (Row_Slot): the active tab's document and the focused frame's document while the Vault is unlocked
// (the address bar's chip, the fill shortcut and the field's dropdown need them at once), the search of the palette or
// the panel while one is open, the cards and identities while a card or address field has the focus. A lock, a release
// or another document zeroes them. The password of a save offer and a generated value are kept until they are used or
// dropped, then zeroed; a lock zeroes them too. Nothing here logs.
//
// Time: two timers run while the Vault is unlocked. The idle timer locks it `vault.lock.idle_minutes` after the last user
// activity (vault_activity); the sync timer asks for a sync every `vault.sync.interval_minutes`. The helper has its own
// idle deadline, later than the Vault's, renewed by the keepalives that activity sends (at most one a minute).
package vault

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "wb:base"
import "wb:config"
import "wb:host"
import "wb:i18n"

State :: enum u8 {
	Disabled,          // vault.enabled is off: nothing runs
	Locating,          // looking for the helper and the remembered account (a blocking job)
	Helper_Missing,    // the helper program is not there
	Logged_Out,        // no account: the next step is a login
	Logging_In,        // a login waits for its answer
	Need_Two_Factor,   // the account asks for the code of a second step (`factors`, `factor`)
	Need_Device_Code,  // the account must confirm this new device with the code that the server mailed
	Waiting_Device,    // a login waits for another device of the account to approve it (`fingerprint`; polled on a timer)
	Passkey,           // a passkey ceremony waits for the person (the shell runs it with `passkey_options`)
	Locked,            // an account is remembered; no helper holds its keys
	Unlocking,         // an unlock waits for its answer
	Unlocked,          // the helper holds the keys: rows and fills work
	Failed,            // the helper stopped or did not answer; the next login or unlock starts again
}

Rows_State :: enum u8 { None, Asked, Checking, Ready, Failed }

// The sets of rows the Vault keeps: the logins of the active tab's document, of the focused frame's document (a form in
// a frame: its own origin decides), the search of the palette or the panel, and the cards or the identities that the
// dropdown of a card or address field lists (a search of one kind).
Row_Slot :: enum u8 { Page, Frame, Search, Items }

// Search and Items hold a search page by page: the first page makes the set Ready, each later one (vault_search_more)
// is appended until `total` rows are there. A page asked for an older query, or for another offset, is dropped.
Row_Set :: struct {
	rows:  [dynamic]Row,   // Page, Frame: checked by Wren (match.odin); Search, Items: as the helper sent them
	key:   string,         // owned: the document's address (Page, Frame) or the query (Search, Items)
	state: Rows_State,
	gen:   u64,            // each ask: a check or a page of an older ask is dropped
	// Search, Items
	kinds:       Item_Kinds,   // the kinds of item asked
	limit:       int,          // the rows of each page
	total:       int,          // how many items match in all (the helper's count)
	more_asked:  bool,         // a next page is on its way
	more_failed: bool,         // a next page failed: no other is asked for this query
}

// What a copy puts on the clipboard: a login's, a card's (its number, its security code), an identity's email.
Copy_What :: enum u8 { Username, Password, Totp, Number, Code, Email }

COPY_FIELDS := [Copy_What]Fill_Field{.Username = .Username, .Password = .Password, .Totp = .Totp, .Number = .Number, .Code = .Code, .Email = .Email}

// The second state machine, per fill: Requested -> Answered -> Applied | Dropped (docs/bitwarden.md 4.3).
Fill_State :: enum u8 { None, Requested, Answered, Applied, Dropped }

// What a fill is for, checked again when its values come: the shell drops the fill when the tab, its page or its
// navigation changed meanwhile (docs/bitwarden.md 3.5, rule 9).
Fill_Ticket :: struct {
	tab:      u64,
	page:     rawptr,        // the document's page (a frame's, for a form in a frame)
	nav:      rawptr,
	url:      string,        // owned by the Vault while the fill waits
	forms_id: u64,           // the document's forms model (a page that goes and another at its address is not it)
	field:    base.Handle,   // the field the user acted on: its group is filled (docs/bitwarden.md 3.5, rule 8)
}

// The values handed to the shell's `fill` hook: valid for the time of the call only, then zeroed.
Fill_Values :: struct {
	ticket: Fill_Ticket,
	values: [Fill_Field]string,
	has:    Fill_Fields,
}

// The offer to save a login after a form was sent (docs/bitwarden.md 4.10): None -> [Waiting (the site's logins are not
// known yet: at most OFFER_WAIT_MS for them)] -> [Checking (the password of the login with the same user name is asked,
// to compare)] -> Save | Update -> Saving -> None. Same password, or no rows in time: None. A lock, another capture or a
// dismissal ends it; its password is zeroed then.
Offer_State :: enum u8 { None, Waiting, Checking, Save, Update, Saving }

OFFER_WAIT_MS :: 10_000

Offer :: struct {
	state:    Offer_State,
	id:       u64,      // each capture: the check of an older one is dropped
	host:     string,   // owned: the site's host (the new login's name)
	url:      string,   // owned: the document's address (the login's uri)
	username: string,   // owned
	password: string,   // owned, a secret
	item:     string,   // owned: Update, the login to change ("" for Save)
	timer:    base.Handle,   // Waiting: its deadline
	// Checking: the site's logins whose password is compared, one after the other (owned ids): the one of the same user
	// name, or every login of the site when the form sent no user name (a page with a password field alone)
	candidates: [dynamic]string,
	next:       int,
}

Hooks :: struct {
	user:    rawptr,
	changed: proc(user: rawptr),                                       // the state, the rows or the message changed: draw again
	fill:    proc(user: rawptr, values: ^Fill_Values) -> bool,            // applies a fill; false: dropped
	copy:    proc(user: rawptr, what: Copy_What, value: string, seconds_left: int),   // puts a value on the clipboard (valid for the call only); seconds_left: a code's
}

@(private)
Pending :: struct {
	id:      u64,
	op:      Op,
	timer:   base.Handle,
	timeout: ^Timeout,
	ticket:  Fill_Ticket,   // .Fill (its url owned)
	key:     string,        // .Logins_For: the document; .Search: the query (owned)
	slot:    Row_Slot,      // .Logins_For, .Search
	gen:     u64,           // .Logins_For, .Search: the set's gen when asked (another gen: the set was asked again or let go)
	offset:  int,           // .Search: the page's first row (0: the first page)
	offer:   u64,           // .Fill, .Save: for the save offer of this id (0: not)
	copy:    bool,          // .Fill, .Totp: for the clipboard (copy_what), not for a page
	copy_what: Copy_What,
	resend:  bool,          // .Login: a code asked again; a failure keeps the login waiting (`back`)
	back:    State,         // .Login with resend: the step it came from
	passkey_done: Passkey_Callback,   // .Passkeys_For, .Passkey_Assert: called once (nil: its caller forgot it)
	passkey_user: rawptr,
}

// The answer to a page's passkey request (vault_passkeys_for, vault_passkey_assert), handed to its callback once: the
// rows of the site, or the signed assertion, or a failure (`error`: the helper's code; "timeout" past
// vault.request.timeout_ms; "locked" when the Vault locked or stopped meanwhile). Valid for the call only: the strings
// are zeroed after it.
Passkey_Answer :: struct {
	ok:     bool,
	error:  string,
	rows:   []Passkey_Row,
	signed: Passkey_Signed,
}

// Runs on the loop thread. `ticket`: what vault_passkeys_for or vault_passkey_assert returned.
Passkey_Callback :: proc(user: rawptr, ticket: u64, answer: ^Passkey_Answer)

// What a passkey ceremony is for.
Passkey_Purpose :: enum u8 { Login, Unlock }

// The answer of a passkey ceremony, each value in base64url (`prf`: the PRF extension's output, a secret). The shell
// fills it from the authenticator's answer; the Vault zeroes nothing of it (the caller does).
Passkey_Assertion :: struct {
	credential_id, authenticator_data, client_data_json, signature, user_handle: string,
	prf: string,
}

DEVICE_POLL_MS :: 4000                                   // between two looks at a device's approval
DEVICE_WAIT_NS :: i64(15 * 60 + 30) * 1_000_000_000      // the server keeps the request 15 minutes; then it is expired

@(private)
Timeout :: struct { v: ^Vault, id: u64 }

Vault :: struct {
	loop:           ^host.Loop,
	pool:           ^host.Blocking_Pool,
	writer:         ^host.File_Writer,   // the profile's (nil in tests): the account file's writes
	hooks:          Hooks,
	spawn:          Spawn_Proc,
	settings:       Settings,
	state:          State,
	message:        string,   // owned: what the dialog or the panel says about the last request (never a secret)
	email:          string,   // owned: the remembered account
	pin:            bool,     // a PIN can unlock the remembered account
	helper:         string,   // owned: the helper's path ("" until located)
	profile_dir:    string,   // owned: "" = nothing is written (browser.profile.persist off)
	client_version: string,   // owned
	t:              ^Transport,
	closed:         [dynamic]^Transport,   // closed, waiting for their Exited
	next_id:        u64,
	pending:        [dynamic]Pending,
	sets:           [Row_Slot]Row_Set,
	fill_state:     Fill_State,
	setup_gen:      u64,                   // each enable: a locate job of an older one is dropped
	jobs:           int,                   // blocking jobs on their way (vault_destroy waits for them)
	login_email:    string,                // owned: the email of a login that waits for its second step
	factors:        Factors,               // Need_Two_Factor: the second steps that the account offers
	factor:         Factor,                // Need_Two_Factor: the one whose code the dialog asks
	email_sent:     bool,                  // Need_Two_Factor: a code was mailed
	error:          string,                // owned: the code of the last refusal ("captcha_required"...; "" none): the dialog acts on some
	remembered:     string,                // owned: the last email that logged in (vault.login.remember_email), kept after a logout
	passkey:        bool,                  // a passkey of the remembered account can unlock it
	hint_busy:      bool,                  // a master password hint was asked and not answered yet
	fingerprint:    string,                // owned: Waiting_Device: the phrase that the other device shows too
	device_since:   i64,                   // Waiting_Device: the loop's clock when the request was made
	device_timer:   base.Handle,           // Waiting_Device: the next look at the approval
	device_back:    State,                 // Waiting_Device: where a cancel or a refusal goes back to
	passkey_purpose: Passkey_Purpose,      // Passkey: what the ceremony is for
	passkey_options: string,               // owned: Passkey: the ceremony's options, until the shell takes them
	passkey_taken:  bool,                  // Passkey: the shell took them (its ceremony runs)
	syncing:        bool,                  // a sync waits for its answer
	last_sync:      i64,                   // Unix seconds of the last sync of this run (0: none)
	active_ns:      i64,                   // the loop's clock at the last user activity
	keepalive_ns:   i64,                   // the loop's clock at the last keepalive
	idle_timer:     base.Handle,
	sync_timer:     base.Handle,
	account_file:   File_Queue,            // the account file's writes
	never_file:     File_Queue,            // the never-save list's writes
	never:          [dynamic]string,       // owned: the hosts where no save is offered (vault.save.offer; "Never for this site")
	offer:          Offer,
	next_offer:     u64,
	generated:      string,                // owned, a secret: the last generated value, until the shell takes it
	generated_id:   u64,                   // the request it answers
}

// One file of the profile that jobs write or remove, one job at a time: the pool's workers run in any order, and a
// removal must not be undone by an older write. A job asked meanwhile waits (only the last one: it says what the file
// must be).
@(private)
File_Queue :: struct {
	busy:        bool,
	queued:      bool,
	next:        string,   // owned: the waiting job's text
	next_remove: bool,
}

ACCOUNT_FILE :: "account"   // <profile>/vault/account: the email, the server and the PIN mark of the remembered account (Wren's)
NEVER_FILE :: "never_save"  // <profile>/vault/never_save: one host a line, where no save is offered
HELPER_NAME :: "wren-vault.exe" when ODIN_OS == .Windows else "wren-vault"
KEEPALIVE_EVERY_NS :: i64(60) * 1_000_000_000   // activity sends at most one keepalive a minute
PIN_MIN :: 4

////////////////////////////////
// Life

// Loop thread. `profile_dir` "": nothing is written and no account is remembered between runs.
vault_init :: proc(v: ^Vault, loop: ^host.Loop, pool: ^host.Blocking_Pool, prefs: ^config.Prefs, profile_dir, client_version: string, hooks: Hooks, spawn: Spawn_Proc = process_spawn, writer: ^host.File_Writer = nil) {
	v.loop, v.pool, v.hooks, v.spawn, v.writer = loop, pool, hooks, spawn, writer
	v.settings = settings_from_prefs(prefs)
	v.profile_dir = strings.clone(profile_dir, base.process_allocator())
	v.client_version = strings.clone(client_version, base.process_allocator())
	v.closed = make([dynamic]^Transport)
	v.pending = make([dynamic]Pending)
	v.never = make([dynamic]string, base.process_allocator())
	v.state = .Disabled
	if v.settings.enabled { enable(v) }
}

// Loop thread. Kills a helper that still works, waits for the jobs, zeroes what is kept.
vault_destroy :: proc(v: ^Vault) {
	timers_stop(v)
	drop_pending(v, notify = false)
	if v.t != nil { v.t.destroy(v.t); v.t = nil }
	for t in v.closed { t.destroy(t) }
	delete(v.closed)
	// (after the threads are joined: nothing more is posted; what was posted and never ran is zeroed)
	host.discard_posted(v.loop, transport_posted, transport_discard)
	for v.jobs > 0 { host.blocking_settle(v.pool) }
	delete(v.pending)
	for &set in v.sets {
		rows_free(&set.rows)
		string_wipe(&set.key)
	}
	string_wipe(&v.message)
	string_wipe(&v.email)
	string_wipe(&v.login_email)
	string_wipe(&v.error)
	string_wipe(&v.remembered)
	string_wipe(&v.fingerprint)
	string_wipe(&v.passkey_options)
	string_wipe(&v.account_file.next)
	string_wipe(&v.never_file.next)
	strings_free(&v.never)
	offer_reset(v)
	string_wipe(&v.generated)
	delete(v.helper, base.process_allocator())
	delete(v.profile_dir, base.process_allocator())
	delete(v.client_version, base.process_allocator())
	settings_destroy(&v.settings)
	v^ = {}
}

// Loop thread: a `vault.*` preference changed.
vault_prefs_changed :: proc(v: ^Vault, prefs: ^config.Prefs) {
	old := v.settings
	v.settings = settings_from_prefs(prefs)
	defer settings_destroy(&old)
	switch {
	case !v.settings.enabled && old.enabled:
		disable(v)
	case v.settings.enabled && !old.enabled:
		enable(v)
	case v.settings.enabled && (!same_server(old, v.settings) || old.helper_path != v.settings.helper_path):
		// another server or another helper: what runs now is for the old one
		disable(v)
		enable(v)
	case v.state == .Unlocked && (old.idle_minutes != v.settings.idle_minutes || old.sync_minutes != v.settings.sync_minutes):
		timers_start(v)
	}
	if old.remember_email && !v.settings.remember_email && v.remembered != "" {
		// (the person does not want it kept: it goes from memory and from the file now)
		string_wipe(&v.remembered)
		write_account(v)
		changed(v)
	}
}

@(private)
enable :: proc(v: ^Vault) {
	set_state(v, .Locating)
	v.setup_gen += 1
	identity, _ := server_urls(v.settings)
	j := new(Setup_Job, base.process_allocator())
	j^ = {v = v, gen = v.setup_gen, profile_dir = strings.clone(v.profile_dir, base.process_allocator()),
		helper_setting = strings.clone(v.settings.helper_path, base.process_allocator()), identity = strings.clone(identity, base.process_allocator())}
	v.jobs += 1
	host.run_blocking(v.pool, setup_work, setup_done, j, setup_discard)
}

@(private)
disable :: proc(v: ^Vault) {
	close_helper(v)
	v.setup_gen += 1
	rows_reset(v)
	string_wipe(&v.message)
	string_wipe(&v.login_email)
	set_state(v, .Disabled)
}

////////////////////////////////
// What the shell asks (loop thread)

// A login: the email and the master password; then, when the account asks for a second step (Need_Two_Factor or
// Need_Device_Code), its code only: the password is "" and the helper uses the one it keeps for this login.
// `remember` (a two-step code): the server remembers this device, and the next login of the account here needs no code.
vault_login :: proc(v: ^Vault, email, password: string, code := "", remember := false) -> bool {
	switch v.state {
	case .Logged_Out, .Locked, .Failed:
		address := strings.trim_space(email)
		if password == "" || address == "" { return false }
		if !ensure_helper(v) { return false }
		string_wipe(&v.login_email)
		v.login_email = strings.clone(address, base.process_allocator())
		r: Request
		request_begin(&r, next_id(v), .Login, len(address) + len(password))
		request_string(&r, "email", address)
		request_string(&r, "password", password)
		send(v, &r, .Login)
	case .Need_Two_Factor, .Need_Device_Code:
		c := strings.trim_space(code)
		if c == "" || v.t == nil { return false }
		device := v.state == .Need_Device_Code
		provider := device ? "device" : FACTOR_NAMES[v.factor]
		r: Request
		request_begin(&r, next_id(v), .Login, len(v.login_email) + len(c) + 48)
		request_string(&r, "email", v.login_email)
		request_string(&r, "code", c)
		request_string(&r, "provider", provider)
		if remember && !device { request_bool(&r, "remember", true) }
		send(v, &r, .Login)
	case .Disabled, .Locating, .Helper_Missing, .Logging_In, .Unlocking, .Unlocked, .Waiting_Device, .Passkey:
		return false
	}
	clear_problem(v)
	set_state(v, .Logging_In)
	return true
}

// The message and the code of the last refusal go (a new request starts).
@(private)
clear_problem :: proc(v: ^Vault) {
	string_wipe(&v.message)
	string_wipe(&v.error)
}

// Logged_Out, Locked or Failed: a login of another kind may start (a device's approval, a passkey, a hint).
@(private)
can_start_login :: proc(v: ^Vault) -> bool {
	#partial switch v.state {
	case .Logged_Out, .Locked, .Failed: return true
	}
	return false
}

// Asks the server to mail the master password hint of the account `email`. The answer is a message; the state stays.
vault_password_hint :: proc(v: ^Vault, email: string) -> bool {
	address := strings.trim_space(email)
	if !can_start_login(v) || address == "" || v.hint_busy { return false }
	if !ensure_helper(v) { return false }
	r: Request
	request_begin(&r, next_id(v), .Password_Hint, len(address))
	request_string(&r, "email", address)
	if send(v, &r, .Password_Hint) == nil { return false }
	v.hint_busy = true
	clear_problem(v)
	changed(v)
	return true
}

// A login that another device of the account approves (Bitwarden's "log in with device"). The helper makes the request
// and answers its fingerprint phrase (Waiting_Device); the Vault then asks for the approval every DEVICE_POLL_MS, for
// DEVICE_WAIT_NS at most.
vault_login_device :: proc(v: ^Vault, email: string) -> bool {
	address := strings.trim_space(email)
	if !can_start_login(v) || address == "" { return false }
	if !ensure_helper(v) { return false }
	string_wipe(&v.login_email)
	v.login_email = strings.clone(address, base.process_allocator())
	r: Request
	request_begin(&r, next_id(v), .Device_Request, len(address))
	request_string(&r, "email", address)
	if send(v, &r, .Device_Request) == nil { return false }
	v.device_back = v.email != "" ? .Locked : .Logged_Out
	clear_problem(v)
	set_state(v, .Logging_In)
	return true
}

// A login (Logged_Out, Locked, Failed) or an unlock (Locked, Failed, with `passkey`) with a passkey. The helper gives the
// ceremony's options (state Passkey); the shell takes them (vault_passkey_take), runs the ceremony and hands its answer
// to vault_passkey_done, or says why it failed (vault_passkey_failed). `rp_id`: the web vault's domain, the relying party
// of an unlock when no passkey login named one.
vault_passkey_begin :: proc(v: ^Vault, purpose: Passkey_Purpose, rp_id: string) -> bool {
	if !can_start_login(v) { return false }
	if purpose == .Unlock && (v.email == "" || !v.passkey) { return false }
	if !ensure_helper(v) { return false }
	r: Request
	request_begin(&r, next_id(v), .Passkey_Options, len(rp_id) + 16)
	request_string(&r, "purpose", purpose == .Login ? "login" : "unlock")
	request_string(&r, "rp_id", rp_id)
	if send(v, &r, .Passkey_Options) == nil { return false }
	v.passkey_purpose = purpose
	v.passkey_taken = false
	string_wipe(&v.passkey_options)
	clear_problem(v)
	set_state(v, purpose == .Login ? .Logging_In : .Unlocking)
	return true
}

// Passkey: the ceremony's options, once (the caller owns and frees the text). ok false: not now, or taken already.
vault_passkey_take :: proc(v: ^Vault) -> (options: string, purpose: Passkey_Purpose, ok: bool) {
	if v.state != .Passkey || v.passkey_taken || v.passkey_options == "" { return "", .Login, false }
	options, v.passkey_options = v.passkey_options, ""
	v.passkey_taken = true
	return options, v.passkey_purpose, true
}

// The ceremony's answer: a login sends it to the helper (the server checks the assertion), an unlock sends the PRF
// output only (the helper opens the account's keys with it). The secrets go into one frame, zeroed once written.
vault_passkey_done :: proc(v: ^Vault, a: Passkey_Assertion) -> bool {
	if v.state != .Passkey || v.t == nil || a.prf == "" { return false }
	r: Request
	switch v.passkey_purpose {
	case .Login:
		request_begin(&r, next_id(v), .Login_Passkey, len(a.credential_id) + len(a.authenticator_data) + len(a.client_data_json) + len(a.signature) + len(a.user_handle) + len(a.prf) + 128)
		request_string(&r, "credential_id", a.credential_id)
		request_string(&r, "authenticator_data", a.authenticator_data)
		request_string(&r, "client_data_json", a.client_data_json)
		request_string(&r, "signature", a.signature)
		request_string(&r, "user_handle", a.user_handle)
		request_string(&r, "prf", a.prf)
		if send(v, &r, .Login_Passkey) == nil { return false }
		set_state(v, .Logging_In)
	case .Unlock:
		request_begin(&r, next_id(v), .Unlock, len(a.prf) + len(a.credential_id) + 32)
		request_string(&r, "prf", a.prf)
		request_string(&r, "credential_id", a.credential_id)
		if send(v, &r, .Unlock) == nil { return false }
		set_state(v, .Unlocking)
	}
	return true
}

// The ceremony did not give an answer (cancelled, timed out, no authenticator): the helper stops (lock is its exit) and
// the Vault goes back to where the login or the unlock started, saying why.
vault_passkey_failed :: proc(v: ^Vault, why: string) {
	if v.state != .Passkey { return }
	back_out(v, why)
}

// A login with a device, a passkey's ceremony, or a login's second step is given up: its helper stops (nothing it holds
// is needed), the Vault is Locked or Logged_Out again and says `why` ("": nothing).
vault_cancel :: proc(v: ^Vault, why := "") {
	#partial switch v.state {
	case .Waiting_Device, .Passkey, .Need_Two_Factor, .Need_Device_Code, .Logging_In, .Unlocking:
		back_out(v, why)
	}
}

@(private)
back_out :: proc(v: ^Vault, why: string) {
	if v.t != nil {
		r: Request
		request_begin(&r, next_id(v), .Lock, 0)
		if frame, ok := request_end(&r); ok { v.t.send(v.t, frame) }
	}
	lock_down(v)
	if why != "" { set_message(v, why) }
}

// A login with the account's personal API key (client id `user.<uuid>` and its secret), then the master password for
// the keys. For accounts whose second step the Vault does not support (Duo, a security key).
vault_login_api_key :: proc(v: ^Vault, client_id, client_secret, password: string) -> bool {
	#partial switch v.state {
	case .Logged_Out, .Locked, .Failed:
	case: return false
	}
	id := strings.trim_space(client_id)
	secret := strings.trim_space(client_secret)
	if id == "" || secret == "" || password == "" { return false }
	if !ensure_helper(v) { return false }
	string_wipe(&v.login_email)
	r: Request
	request_begin(&r, next_id(v), .Login_Api_Key, len(id) + len(secret) + len(password))
	request_string(&r, "client_id", id)
	request_string(&r, "client_secret", secret)
	request_string(&r, "password", password)
	send(v, &r, .Login_Api_Key)
	clear_problem(v)
	set_state(v, .Logging_In)
	return true
}

// Need_Two_Factor: the dialog asks for the code of `f` (one the account offers). No request.
vault_choose_factor :: proc(v: ^Vault, f: Factor) {
	if v.state != .Need_Two_Factor || f not_in v.factors || v.factor == f { return }
	v.factor = f
	string_wipe(&v.message)
	changed(v)
}

// Asks for the code again: Need_Two_Factor, a mail with the email code (and the dialog asks for it); Need_Device_Code, a
// new mail with the new-device code.
vault_send_code :: proc(v: ^Vault) -> bool {
	if v.t == nil { return false }
	provider: string
	#partial switch v.state {
	case .Need_Two_Factor:
		if .Email not_in v.factors { return false }
		provider = "email"
	case .Need_Device_Code:
		provider = "device"
	case:
		return false
	}
	r: Request
	request_begin(&r, next_id(v), .Login, len(v.login_email) + 32)
	request_string(&r, "email", v.login_email)
	request_string(&r, "provider", provider)
	request_bool(&r, "resend", true)
	p := send(v, &r, .Login)
	if p == nil { return false }
	// (a resend that fails comes back to this step: the login still waits for its code)
	p.resend, p.back = true, v.state
	clear_problem(v)
	set_state(v, .Logging_In)
	return true
}

// An unlock of the remembered account, with its master password, or with its PIN (`pin`: when one is set).
vault_unlock :: proc(v: ^Vault, secret: string, pin := false) -> bool {
	if (v.state != .Locked && v.state != .Failed) || v.email == "" || secret == "" { return false }
	if pin && !v.pin { return false }
	if !ensure_helper(v) { return false }
	r: Request
	request_begin(&r, next_id(v), .Unlock, len(secret))
	request_string(&r, pin ? "pin" : "password", secret)
	send(v, &r, .Unlock)
	clear_problem(v)
	set_state(v, .Unlocking)
	return true
}

// Lock: the helper exits (docs/bitwarden.md 3.2). Also what a cancelled login does (vault_cancel says why).
vault_lock :: proc(v: ^Vault) {
	if v.state == .Disabled || v.state == .Locating || v.state == .Helper_Missing { return }
	if v.t != nil {
		r: Request
		request_begin(&r, next_id(v), .Lock, 0)
		if frame, ok := request_end(&r); ok { v.t.send(v.t, frame) }
	}
	lock_down(v)
}

// Logout: the helper forgets the account here (its state, its tokens in the system store, the PIN) and exits; the account
// file goes. A helper is started for that when none runs.
vault_logout :: proc(v: ^Vault) -> bool {
	#partial switch v.state {
	case .Disabled, .Locating, .Helper_Missing: return false
	}
	if v.email == "" && v.t == nil { return false }
	if ensure_helper(v) {
		r: Request
		request_begin(&r, next_id(v), .Logout, 0)
		if frame, ok := request_end(&r); ok { v.t.send(v.t, frame) }
	}
	close_helper(v)   // (it reads what is queued, the logout included, then its input ends)
	rows_reset(v)
	string_wipe(&v.login_email)
	string_wipe(&v.email)
	clear_problem(v)
	v.pin, v.passkey = false, false
	write_account(v)   // (the account goes; the remembered email stays, when vault.login.remember_email says so)
	if v.state != .Helper_Missing { set_state(v, .Logged_Out) }
	return true
}

// A sync now (the panel's button; the sync timer). False: locked, or one is on its way.
vault_sync :: proc(v: ^Vault) -> bool {
	if v.state != .Unlocked || v.t == nil || v.syncing { return false }
	r: Request
	request_begin(&r, next_id(v), .Sync, 0)
	if send(v, &r, .Sync) == nil { return false }
	v.syncing = true
	changed(v)
	return true
}

// Sets the PIN that unlocks this account in this profile (at least PIN_MIN characters). Only with a kept profile: the
// helper keeps the PIN's envelope in its state.
vault_pin_set :: proc(v: ^Vault, pin: string) -> bool {
	if v.state != .Unlocked || v.t == nil || !vault_can_pin(v) || len(pin) < PIN_MIN { return false }
	r: Request
	request_begin(&r, next_id(v), .Pin_Set, len(pin))
	request_string(&r, "pin", pin)
	if send(v, &r, .Pin_Set) == nil { return false }
	string_wipe(&v.message)
	return true
}

// Removes the PIN: only the master password unlocks from now on.
vault_pin_clear :: proc(v: ^Vault) -> bool {
	if v.state != .Unlocked || v.t == nil || !v.pin { return false }
	r: Request
	request_begin(&r, next_id(v), .Pin_Clear, 0)
	return send(v, &r, .Pin_Clear) != nil
}

// The user pressed a key or a button in the browser: the idle deadline starts again. Cheap: the shell calls it for the
// frames that have input. A keepalive goes to the helper at most once a minute.
vault_activity :: proc(v: ^Vault) {
	if v.t == nil { return }
	now := host.now_ns(v.loop)
	v.active_ns = now
	if now - v.keepalive_ns < KEEPALIVE_EVERY_NS { return }
	v.keepalive_ns = now
	r: Request
	request_begin(&r, next_id(v), .Keepalive, 0)
	if frame, ok := request_end(&r); ok { v.t.send(v.t, frame) }
}

// The logins of the document at `address`, in `slot` (Page: the active tab's document; Frame: the focused frame's).
// The shell calls this each frame: an address already asked, answered or refused is not asked again. The rows come
// later (state Ready).
vault_ask_rows :: proc(v: ^Vault, address: string, slot := Row_Slot.Page) {
	if v.state != .Unlocked || slot == .Search || slot == .Items { return }
	set := &v.sets[slot]
	if address == "" {
		// (no document: the set is let go once, not reset each frame)
		if set.state != .None || set.key != "" { set_reset(v, slot) }
		return
	}
	if address == set.key && set.state != .None { return }
	set_reset(v, slot)
	set.key = strings.clone(address, base.process_allocator())
	site, ok := site_of(address)
	if !ok {
		set.state = .Ready   // (nothing is ever filled there: no row)
		changed(v)
		return
	}
	r: Request
	request_begin(&r, next_id(v), .Logins_For, len(site.url) + len(site.host) + len(site.domain))
	request_string(&r, "url", site.url)
	request_string(&r, "host", site.host)
	request_string(&r, "domain", site.domain)
	p := send(v, &r, .Logins_For)
	if p != nil {
		p.key = strings.clone(address, base.process_allocator())
		p.slot, p.gen = slot, set.gen
	}
	set.state = .Asked
	changed(v)
}

// The items of `kinds` whose name, user name or address hold every word of `query` ("": every item of those kinds),
// sorted by name, one page of `limit` rows at a time: the first page here, the next ones with vault_search_more (the
// palette's Vault prefix and the panel's search: slot Search; the dropdown of a card or address field: slot Items). The
// helper searches (Wren does no work in proportion to the vault); an answer for an older query is dropped. The rows
// come later (state Ready); they hold no password. The same query and kinds asked again: nothing is sent.
vault_search :: proc(v: ^Vault, query: string, slot := Row_Slot.Search, kinds := ALL_KINDS, limit := SEARCH_PAGE) {
	if v.state != .Unlocked || (slot != .Search && slot != .Items) { return }
	set := &v.sets[slot]
	if set.state != .None && query == set.key && kinds == set.kinds { return }
	set_reset(v, slot, keep_rows = true)
	set.key = strings.clone(query, base.process_allocator())
	set.kinds, set.limit = kinds, clamp(limit, 1, SEARCH_PAGE_MAX)
	set.state = .Asked
	if !search_send(v, slot, 0) { set.state = .Failed }
	changed(v)
}

// Asks the next page of the search in `slot` (appended to its rows when it comes). False when there is none to ask:
// the first page has not come, a page is on its way, every row is there, or a page failed.
vault_search_more :: proc(v: ^Vault, slot := Row_Slot.Search) -> bool {
	if v.state != .Unlocked || (slot != .Search && slot != .Items) { return false }
	set := &v.sets[slot]
	if set.state != .Ready || set.more_asked || set.more_failed || len(set.rows) >= set.total { return false }
	if !search_send(v, slot, len(set.rows)) { set.more_failed = true; return false }
	set.more_asked = true
	changed(v)
	return true
}

// How many items match the search in `slot` in all (its rows may be fewer: the pages not asked yet).
vault_search_total :: proc(v: ^Vault, slot := Row_Slot.Search) -> int { return v.sets[slot].total }

@(private)
search_send :: proc(v: ^Vault, slot: Row_Slot, offset: int) -> bool {
	set := &v.sets[slot]
	r: Request
	request_begin(&r, next_id(v), .Search, len(set.key) + 96)
	request_search(&r, set.key, offset, set.limit, set.kinds)
	p := send(v, &r, .Search)
	if p == nil { return false }
	p.key = strings.clone(set.key, base.process_allocator())
	p.slot, p.gen, p.offset = slot, set.gen, offset
	return true
}

// The rows of a set as they are now (valid until the Vault changes them: use them within the frame).
vault_rows :: proc(v: ^Vault, slot := Row_Slot.Page) -> (rows: []Row, state: Rows_State, key: string) {
	set := &v.sets[slot]
	return set.rows[:], set.state, set.key
}

// The row `id` of a set, nil when it is not there (a fill from the palette needs the item in the document's checked rows:
// docs/bitwarden.md 3.5, rule 10).
vault_row_find :: proc(v: ^Vault, id: string, slot: Row_Slot) -> ^Row {
	for &r in v.sets[slot].rows { if r.id == id { return &r } }
	return nil
}

// The rows are not shown any more: they are zeroed (docs/bitwarden.md 3.1).
vault_release_rows :: proc(v: ^Vault, slot := Row_Slot.Page) { set_reset(v, slot) }

// A fill of the row `item` that the user picked, for the document of `ticket`. False: nothing was sent.
vault_fill :: proc(v: ^Vault, item: string, ticket: Fill_Ticket, fields := Fill_Fields{.Username, .Password}) -> bool {
	if v.state != .Unlocked || v.t == nil || fields == {} { return false }
	r: Request
	request_begin(&r, next_id(v), .Fill, len(item) + 16 * len(Fill_Field))
	request_string(&r, "item", item)
	request_fields(&r, fields)
	p := send(v, &r, .Fill)
	if p == nil { return false }
	p.ticket = ticket
	p.ticket.url = strings.clone(ticket.url, base.process_allocator())
	v.fill_state = .Requested
	return true
}

// The `fields` list of a fill, in the protocol's names.
@(private)
request_fields :: proc(r: ^Request, fields: Fill_Fields) {
	names := make([dynamic]string, 0, len(Fill_Field), context.temp_allocator)
	for f in Fill_Field { if f in fields { append(&names, FILL_FIELD_NAMES[f]) } }
	request_list(r, "fields", names[:])
}

// A copy of one value of the row `item` (a click or a palette choice of the user). The value goes to the `copy` hook
// when it comes; the shell clears the clipboard after vault.clipboard.clear_seconds. False: nothing was sent.
vault_copy :: proc(v: ^Vault, item: string, what: Copy_What) -> bool {
	if v.state != .Unlocked || v.t == nil || item == "" { return false }
	r: Request
	p: ^Pending
	switch what {
	case .Username, .Password, .Number, .Code, .Email:
		request_begin(&r, next_id(v), .Fill, len(item) + 32)
		request_string(&r, "item", item)
		request_list(&r, "fields", {FILL_FIELD_NAMES[COPY_FIELDS[what]]})
		p = send(v, &r, .Fill)
	case .Totp:
		request_begin(&r, next_id(v), .Totp, len(item) + 8)
		request_string(&r, "item", item)
		p = send(v, &r, .Totp)
	}
	if p == nil { return false }
	p.copy, p.copy_what = true, what
	return true
}

// Whether the vault's account is remembered (the panel offers Unlock rather than Log in).
vault_has_account :: proc(v: ^Vault) -> bool { return v.email != "" }

// Whether a PIN can be set: the helper keeps its envelope in the profile, so not without one.
vault_can_pin :: proc(v: ^Vault) -> bool { return v.profile_dir != "" }

// Creates a login (`item` "") or updates the login `item` (its non-empty user name and password; the helper adds `uri`
// to its addresses when none matches it). The helper encrypts and sends it, then the rows are asked again. The answer is
// a message. False: nothing was sent.
vault_save :: proc(v: ^Vault, item, name, uri, username, password: string) -> bool {
	if v.state != .Unlocked || v.t == nil || (password == "" && item == "") { return false }
	r: Request
	request_begin(&r, next_id(v), .Save, len(item) + len(name) + len(uri) + len(username) + len(password) + 32)
	request_string(&r, "item", item)
	request_string(&r, "name", name)
	request_string(&r, "uri", uri)
	request_string(&r, "username", username)
	request_string(&r, "password", password)
	p := send(v, &r, .Save)
	if p == nil { return false }
	p.key = strings.clone(item, base.process_allocator())   // ("": a creation; the message says which)
	string_wipe(&v.message)
	changed(v)
	return true
}

// Asks the helper for a password or a passphrase. The value comes later: vault_generated_take, with the id returned here
// (0: nothing was sent).
vault_generate :: proc(v: ^Vault, o: Generate_Options) -> u64 {
	if v.state != .Unlocked || v.t == nil { return 0 }
	r: Request
	request_begin(&r, next_id(v), .Generate, len(o.separator) + 256)
	if o.passphrase {
		request_string(&r, "kind", "passphrase")
		request_int(&r, "words", clamp(o.words, GENERATE_WORDS_MIN, GENERATE_WORDS_MAX))
		request_string(&r, "separator", o.separator)
		request_bool(&r, "capitalize", o.capitalize)
		request_bool(&r, "include_number", o.include_number)
	} else {
		request_string(&r, "kind", "password")
		request_int(&r, "length", clamp(o.length, GENERATE_LENGTH_MIN, GENERATE_LENGTH_MAX))
		request_bool(&r, "uppercase", o.uppercase)
		request_bool(&r, "lowercase", o.lowercase)
		request_bool(&r, "numbers", o.numbers)
		request_bool(&r, "special", o.special)
		request_int(&r, "min_numbers", o.min_numbers)
		request_int(&r, "min_special", o.min_special)
	}
	id := v.next_id
	if send(v, &r, .Generate) == nil { return 0 }
	return id
}

// The generated value, once (the caller owns it and zeroes it: string_wipe). ok false: none came since the last take.
vault_generated_take :: proc(v: ^Vault) -> (value: string, id: u64, ok: bool) {
	if v.generated == "" { return "", 0, false }
	value, id = v.generated, v.generated_id
	v.generated, v.generated_id = "", 0
	return value, id, true
}

////////////////////////////////
// Passkeys of sites (docs/bitwarden.md 4.11)

// Whether a page's passkey request asks the Vault first: unlocked, with vault.passkeys.offer on. Locked or off, the
// request goes to the platform's authenticator as without a Vault.
vault_passkeys_offered :: proc(v: ^Vault) -> bool {
	return v.state == .Unlocked && v.t != nil && v.settings.passkeys_offer
}

// Asks the vault's passkeys of the relying party `rp_id` (in `allow`, the page's allowCredentials ids in base64url, when
// it gives some). `done` gets the rows once, or a failure. Returns the request's ticket; 0: nothing was asked
// (vault_passkeys_offered is false) and `done` is never called.
vault_passkeys_for :: proc(v: ^Vault, rp_id: string, allow: []string, done: Passkey_Callback, user: rawptr) -> u64 {
	if !vault_passkeys_offered(v) || rp_id == "" || done == nil { return 0 }
	room := len(rp_id) + 32
	for a in allow { room += len(a) + 3 }
	r: Request
	request_begin(&r, next_id(v), .Passkeys_For, room)
	request_string(&r, "rp_id", rp_id)
	request_list(&r, "allow", allow)
	id := v.next_id
	p := send(v, &r, .Passkeys_For)
	if p == nil { return 0 }
	p.passkey_done, p.passkey_user = done, user
	return id
}

// Asks the helper to sign a page's assertion with the passkey `credential_id` of `item` (a row of vault_passkeys_for).
// `client_data_hash`: the SHA-256 of the clientDataJSON that Wren made, in base64url. `done` gets the signed values once,
// or a failure. Returns the ticket; 0: nothing was asked and `done` is never called.
vault_passkey_assert :: proc(v: ^Vault, item, credential_id, rp_id, client_data_hash: string, done: Passkey_Callback, user: rawptr) -> u64 {
	if v.state != .Unlocked || v.t == nil || item == "" || credential_id == "" || rp_id == "" || done == nil { return 0 }
	r: Request
	request_begin(&r, next_id(v), .Passkey_Assert, len(item) + len(credential_id) + len(rp_id) + len(client_data_hash) + 64)
	request_string(&r, "item", item)
	request_string(&r, "credential_id", credential_id)
	request_string(&r, "rp_id", rp_id)
	request_string(&r, "client_data_hash", client_data_hash)
	id := v.next_id
	p := send(v, &r, .Passkey_Assert)
	if p == nil { return 0 }
	p.passkey_done, p.passkey_user = done, user
	return id
}

// The caller of a passkey request is gone (its page closed, its ceremony ended): its callback is never called. The
// answer, when it comes, is dropped.
vault_passkey_forget :: proc(v: ^Vault, ticket: u64) {
	if ticket == 0 { return }
	for &p in v.pending {
		if p.id == ticket { p.passkey_done, p.passkey_user = nil, nil }
	}
}

// Calls a passkey request's callback once with `answer`, then forgets it.
@(private)
passkey_reply :: proc(p: ^Pending, answer: ^Passkey_Answer) {
	done, user := p.passkey_done, p.passkey_user
	p.passkey_done, p.passkey_user = nil, nil
	if done != nil { done(user, p.id, answer) }
}

// A passkey request that ends without the helper's answer: the callback hears `why`.
@(private)
passkey_fail :: proc(p: ^Pending, why: string) {
	answer := Passkey_Answer{ok = false, error = why}
	passkey_reply(p, &answer)
}

////////////////////////////////
// The save offer

// A login was sent from the document at `url` with these values (a form's submission, or a page left with a password
// typed and not sent by a form). When the Vault is unlocked, vault.save.offer is on and the host is not in the never
// list, the values are compared with the logins of the site: no login with this user name: Save; one with another
// password: Update (its password is asked first, to compare); the same: nothing. When the site's rows are not known
// yet, the offer waits for them (Waiting) for OFFER_WAIT_MS, then is dropped. The values are copied (the password
// zeroed when the offer ends). False: no offer.
vault_offer_capture :: proc(v: ^Vault, url, username, password: string) -> bool {
	if v.state != .Unlocked || !v.settings.save_offer || password == "" { return false }
	site, ok := site_of(url)
	if !ok || vault_never_has(v, site.host) { return false }
	offer_reset(v)
	v.next_offer += 1
	o := &v.offer
	o.id = v.next_offer
	o.host = strings.clone(site.host, base.process_allocator())
	o.url = strings.clone(url, base.process_allocator())
	o.username = strings.clone(strings.trim_space(username), base.process_allocator())
	o.password = strings.clone(password, base.process_allocator())
	if slot, ready := offer_rows(v); ready { return offer_compare(v, v.sets[slot].rows[:]) }
	// (the rows to compare with are not known yet: they come with the document's ask, or never)
	o.state = .Waiting
	o.timer = host.set_timer(v.loop, OFFER_WAIT_MS, 0, offer_wait_due, v)
	changed(v)
	return true
}

// The set whose rows decide the offer: a document's set (Page or Frame) that is Ready, for the offer's address, else for
// another address of the same host (the page that followed a login is often another of the site's).
@(private)
offer_rows :: proc(v: ^Vault) -> (slot: Row_Slot, ok: bool) {
	o := &v.offer
	for s in ([]Row_Slot{.Page, .Frame}) {
		if v.sets[s].state == .Ready && v.sets[s].key == o.url { return s, true }
	}
	for s in ([]Row_Slot{.Page, .Frame}) {
		set := &v.sets[s]
		if set.state != .Ready || set.key == "" { continue }
		if site, web := site_of(set.key); web && base.ascii_equal_fold(site.host, o.host) { return s, true }
	}
	return .Page, false
}

// The offer against the site's logins: Save, Checking (then Update or nothing), or nothing.
@(private)
offer_compare :: proc(v: ^Vault, rows: []Row) -> bool {
	o := &v.offer
	if o.timer != base.NIL_HANDLE { host.clear_timer(v.loop, o.timer); o.timer = base.NIL_HANDLE }
	for &r in rows {
		if r.kind != .Login { continue }
		if o.username == "" || base.ascii_equal_fold(strings.trim_space(r.username), o.username) {
			if o.candidates.allocator.procedure == nil { o.candidates = make([dynamic]string, base.process_allocator()) }
			append(&o.candidates, strings.clone(r.id, base.process_allocator()))
			if o.username != "" { break }
		}
	}
	if len(o.candidates) == 0 {
		o.state = .Save
		changed(v)
		return true
	}
	o.next = 0
	return offer_check_next(v)
}

// Asks the password of the next candidate login (the answer: vault_answer's .Fill with an offer).
@(private)
offer_check_next :: proc(v: ^Vault) -> bool {
	o := &v.offer
	id := o.candidates[o.next]
	r: Request
	request_begin(&r, next_id(v), .Fill, len(id) + 32)
	request_string(&r, "item", id)
	request_fields(&r, {.Password})
	p := send(v, &r, .Fill)
	if p == nil { offer_reset(v); changed(v); return false }
	p.offer = o.id
	o.state = .Checking
	changed(v)
	return true
}

// A document's rows became Ready: a waiting offer of that site compares now.
@(private)
offer_rows_came :: proc(v: ^Vault) {
	if v.offer.state != .Waiting { return }
	if slot, ready := offer_rows(v); ready { offer_compare(v, v.sets[slot].rows[:]) }
}

@(private)
offer_wait_due :: proc(data: rawptr) {
	v := (^Vault)(data)
	v.offer.timer = base.NIL_HANDLE
	if v.offer.state != .Waiting { return }
	offer_reset(v)   // (the site's logins never came: no offer rather than a wrong one)
	changed(v)
}

// Save or Update: the offer is accepted, the login goes to the helper.
vault_offer_accept :: proc(v: ^Vault) -> bool {
	o := &v.offer
	if o.state != .Save && o.state != .Update { return false }
	if !vault_save(v, o.item, o.host, o.url, o.username, o.password) { return false }
	v.pending[len(v.pending) - 1].offer = o.id
	string_wipe(&o.password)   // (it crossed: nothing keeps it now)
	o.state = .Saving
	changed(v)
	return true
}

// "Not now" (`never` false) or "Never for this site": the offer ends; its host goes to the never list.
vault_offer_dismiss :: proc(v: ^Vault, never := false) {
	if v.offer.state == .None { return }
	if never && v.offer.host != "" && !vault_never_has(v, v.offer.host) {
		append(&v.never, strings.clone(base.ascii_lower(v.offer.host, context.temp_allocator), base.process_allocator()))
		write_never(v)
	}
	offer_reset(v)
	changed(v)
}

// Whether `host` is in the never list (case does not matter).
vault_never_has :: proc(v: ^Vault, host: string) -> bool {
	for h in v.never { if base.ascii_equal_fold(h, host) { return true } }
	return false
}

@(private)
offer_reset :: proc(v: ^Vault) {
	o := &v.offer
	if o.timer != base.NIL_HANDLE { host.clear_timer(v.loop, o.timer); o.timer = base.NIL_HANDLE }
	string_wipe(&o.host)
	string_wipe(&o.url)
	string_wipe(&o.username)
	string_wipe(&o.password)
	string_wipe(&o.item)
	for &c in o.candidates { delete(c, base.process_allocator()) }
	delete(o.candidates)
	o.candidates, o.next = {}, 0
	o.state = .None
}

// Every set of rows that is kept is asked again (a sync or a save changed the items).
@(private)
rows_refresh :: proc(v: ^Vault) {
	for slot in Row_Slot {
		key := strings.clone(v.sets[slot].key, context.temp_allocator)
		kinds, limit := v.sets[slot].kinds, v.sets[slot].limit
		if key == "" && slot != .Search && slot != .Items { continue }
		if v.sets[slot].state == .None { continue }
		set_reset(v, slot)
		// (a search starts again at its first page: the next ones come as they are asked)
		if slot == .Search || slot == .Items { vault_search(v, key, slot, kinds, limit) } else { vault_ask_rows(v, key, slot) }
	}
}

////////////////////////////////
// The helper

@(private)
ensure_helper :: proc(v: ^Vault) -> bool {
	if v.t != nil { return true }
	if v.helper == "" {
		set_state(v, .Helper_Missing)
		return false
	}
	identity, api := server_urls(v.settings)
	if identity == "" {
		set_message(v, i18n.tr("Type the address of your server first (vault.server.url)."))
		return false
	}
	v.t = v.spawn(v, v.helper)
	state_dir := v.profile_dir != "" ? join_path({v.profile_dir, "vault"}) : ""
	idle_s := v.settings.idle_minutes > 0 ? v.settings.idle_minutes * 60 + HELPER_IDLE_MARGIN_S : 0
	r: Request
	request_begin(&r, next_id(v), .Hello, len(state_dir) + len(identity) + len(api) + len(v.client_version) + 32)
	request_int(&r, "protocol", PROTOCOL_VERSION)
	request_string(&r, "state_dir", state_dir)
	request_string(&r, "identity_url", identity)
	request_string(&r, "api_url", api)
	request_bool(&r, "persist", v.profile_dir != "")
	request_string(&r, "device_name", "Wren")
	request_string(&r, "client_version", v.client_version)
	request_int(&r, "idle_seconds", idle_s)
	send(v, &r, .Hello)
	return true
}

// Closes the helper (it exits once it read what is queued) and forgets what it was asked.
@(private)
close_helper :: proc(v: ^Vault) {
	timers_stop(v)
	drop_pending(v)
	// (a login with a device or a passkey lives in this helper: it ends with it)
	if v.device_timer != base.NIL_HANDLE { host.clear_timer(v.loop, v.device_timer) }
	v.device_timer = base.NIL_HANDLE
	string_wipe(&v.fingerprint)
	string_wipe(&v.passkey_options)
	v.passkey_taken = false
	v.hint_busy = false
	if v.t == nil { return }
	v.t.close(v.t)
	append(&v.closed, v.t)
	v.t = nil
}

// The keys are gone (a lock, the helper's own idle lock): the Vault is Locked, or Logged_Out without an account.
@(private)
lock_down :: proc(v: ^Vault) {
	close_helper(v)
	rows_reset(v)
	string_wipe(&v.login_email)
	set_state(v, v.email != "" ? .Locked : .Logged_Out)
}

@(private)
became_unlocked :: proc(v: ^Vault) {
	v.active_ns = host.now_ns(v.loop)
	v.keepalive_ns = v.active_ns
	set_state(v, .Unlocked)
	timers_start(v)
}

@(private)
next_id :: proc(v: ^Vault) -> u64 {
	v.next_id += 1
	return v.next_id
}

// Ends the request, queues it, and arms its deadline. nil when it could not be written (the request is dropped).
@(private)
send :: proc(v: ^Vault, r: ^Request, op: Op) -> ^Pending {
	id := v.next_id
	frame, ok := request_end(r)
	if !ok || v.t == nil {
		frame_free(frame)
		return nil
	}
	v.t.send(v.t, frame)
	to := new(Timeout)
	to^ = {v = v, id = id}
	timer := host.set_timer(v.loop, f64(v.settings.timeout_ms), 0, request_timed_out, to)
	append(&v.pending, Pending{id = id, op = op, timer = timer, timeout = to})
	return &v.pending[len(v.pending) - 1]
}

@(private)
pending_free :: proc(v: ^Vault, p: ^Pending, clear_timer: bool) {
	if clear_timer { host.clear_timer(v.loop, p.timer) }
	free(p.timeout)
	string_wipe(&p.ticket.url)
	string_wipe(&p.key)
}

// `notify`: a page's passkey request hears that the Vault went ("locked"), after the table is cleared (its callback may
// ask again). vault_destroy calls none: the browser is ending.
@(private)
drop_pending :: proc(v: ^Vault, notify := true) {
	waiting := make([dynamic]Pending, 0, 0, context.temp_allocator)
	for &p in v.pending {
		if p.op == .Fill && !p.copy && p.offer == 0 { v.fill_state = .Dropped }
		if notify && p.passkey_done != nil { append(&waiting, p) }
		pending_free(v, &p, true)
	}
	clear(&v.pending)
	v.syncing = false
	for &p in waiting { passkey_fail(&p, "locked") }
}

@(private)
take_pending :: proc(v: ^Vault, id: u64) -> (p: Pending, ok: bool) {
	for x, i in v.pending {
		if x.id == id {
			ordered_remove(&v.pending, i)
			return x, true
		}
	}
	return {}, false
}

@(private)
request_timed_out :: proc(data: rawptr) {
	to := (^Timeout)(data)
	v := to.v
	p, ok := take_pending(v, to.id)
	if !ok { return }
	// (an ask that was replaced or released: the set is another's)
	current := (p.op == .Logins_For || p.op == .Search) && p.gen == v.sets[p.slot].gen
	key := strings.clone(p.key, context.temp_allocator)
	pending_free(v, &p, false)   // (frees `to`, wipes p.key)
	switch p.op {
	case .Logins_For, .Search:
		if !current { return }
		if p.op == .Search && p.offset > 0 {
			// (a later page: the rows there stay, no other page is asked for this query)
			set := &v.sets[p.slot]
			if set.more_asked && p.offset == len(set.rows) { set.more_asked, set.more_failed = false, true }
			set_message(v, i18n.tr("The Vault did not answer in time."))
			changed(v)
			return
		}
		kinds, limit := v.sets[p.slot].kinds, v.sets[p.slot].limit
		set_reset(v, p.slot)
		// (the key and the kinds stay: the shell asks each frame, and a failed ask is not sent again for the same document
		// or query)
		v.sets[p.slot].key = strings.clone(key, base.process_allocator())
		v.sets[p.slot].kinds, v.sets[p.slot].limit = kinds, limit
		v.sets[p.slot].state = .Failed
		set_message(v, i18n.tr("The Vault did not answer in time."))
	case .Fill, .Totp:
		if p.offer != 0 {
			if p.offer == v.offer.id { offer_reset(v) }
		} else if p.copy {
			set_message(v, i18n.tr("The copy took too long and was dropped."))
		} else {
			v.fill_state = .Dropped
			set_message(v, i18n.tr("The fill took too long and was dropped."))
		}
	case .Save:
		if p.offer != 0 && p.offer == v.offer.id { offer_reset(v) }
		set_message(v, i18n.tr("The Vault did not answer in time: the login may not be saved. Sync, then look."))
	case .Generate:
		set_message(v, i18n.tr("The password generator did not answer in time."))
	case .Passkeys_For, .Passkey_Assert:
		// (the page's request goes on without the Vault, or fails: its caller decides; the helper is not stopped)
		passkey_fail(&p, "timeout")
	case .Hello, .Login, .Login_Api_Key, .Unlock, .Lock, .Logout, .Sync, .Pin_Set, .Pin_Clear, .Keepalive,
	     .Password_Hint, .Device_Request, .Device_Poll, .Passkey_Options, .Login_Passkey:
		// (the helper answers in order: one that does not answer holds every later request)
		fail(v, i18n.tr("The Vault helper did not answer in time. It was stopped."))
	}
	changed(v)
}

// The next look at a device's approval, DEVICE_POLL_MS from now.
@(private)
device_poll_later :: proc(v: ^Vault) {
	if v.device_timer != base.NIL_HANDLE { host.clear_timer(v.loop, v.device_timer) }
	v.device_timer = host.set_timer(v.loop, DEVICE_POLL_MS, 0, device_poll_due, v)
}

@(private)
device_poll_due :: proc(data: rawptr) {
	v := (^Vault)(data)
	v.device_timer = base.NIL_HANDLE
	if v.state != .Waiting_Device || v.t == nil { return }
	if host.now_ns(v.loop) - v.device_since > DEVICE_WAIT_NS {
		set_error(v, "expired")
		back_out(v, refusal_words("expired", ""))
		return
	}
	r: Request
	request_begin(&r, next_id(v), .Device_Poll, 0)
	if send(v, &r, .Device_Poll) == nil { back_out(v, i18n.tr("The Vault helper stopped.")) }
}

@(private)
set_error :: proc(v: ^Vault, code: string) {
	string_wipe(&v.error)
	if code != "" { v.error = strings.clone(code, base.process_allocator()) }
}

// What the Vault says for a refusal of the helper (its error `code`): Wren's own sentence, translated, for the codes the
// login steps meet; the helper's `message` for the others, and with the server's own words (a wrong password).
refusal_words :: proc(code, message: string) -> string {
	switch code {
	case "bad_credentials":
		return message != "" ? message : i18n.tr("The email or the master password is wrong.")
	case "account_locked":
		return message != "" ? message : i18n.tr("The server says that this account is locked.")
	case "bad_password":
		return i18n.tr("The master password is wrong.")
	case "network":
		return i18n.tr("The server cannot be reached. Check its address and the network connection.")
	case "captcha_required":
		return i18n.tr("The server asks to solve a captcha first. Log in once on the web vault, then try again here.")
	case "bad_auth_email":
		return i18n.tr("The server refused the account's email. Check the email, then log in again.")
	case "unsupported_two_factor":
		return i18n.tr("This account's second step is not supported here (Duo, a security key, YubiKey). Log in with a device, a passkey or the account's API key.")
	case "unsupported_account":
		return i18n.tr("This account does not unlock with a master password (single sign-on, Key Connector): the Vault cannot open it.")
	case "denied":
		return i18n.tr("The other device refused the login.")
	case "expired":
		return i18n.tr("The login with a device expired without an approval. Ask again.")
	case "passkey_no_unlock":
		return i18n.tr("This passkey logs in but does not open the vault. Turn on its use for encryption in the web vault, or log in with the master password.")
	case "passkey_failed":
		return i18n.tr("The passkey's answer does not open the vault. Use the passkey registered for this account, or the master password.")
	case "no_passkey":
		return i18n.tr("No passkey of this account unlocks the vault. Unlock with the master password.")
	case "save_failed":
		return message != "" ? strings.concatenate({i18n.tr("The login was not saved: "), message}, context.temp_allocator) : i18n.tr("The login was not saved: the server refused it or cannot be reached.")
	}
	return message
}

// The helper is stopped and the Vault says why. The next login or unlock starts a new one.
@(private)
fail :: proc(v: ^Vault, why: string) {
	close_helper(v)
	rows_reset(v)
	string_wipe(&v.login_email)
	set_message(v, why)
	set_state(v, .Failed)
}

////////////////////////////////
// The timers of an unlocked Vault

@(private)
timers_start :: proc(v: ^Vault) {
	timers_stop(v)
	if v.settings.idle_minutes > 0 {
		v.idle_timer = host.set_timer(v.loop, f64(v.settings.idle_minutes) * 60_000, 0, idle_due, v)
	}
	every := f64(max(v.settings.sync_minutes, 1)) * 60_000
	v.sync_timer = host.set_timer(v.loop, every, every, sync_due, v)
}

@(private)
timers_stop :: proc(v: ^Vault) {
	if v.idle_timer != base.NIL_HANDLE { host.clear_timer(v.loop, v.idle_timer) }
	if v.sync_timer != base.NIL_HANDLE { host.clear_timer(v.loop, v.sync_timer) }
	v.idle_timer, v.sync_timer = base.NIL_HANDLE, base.NIL_HANDLE
}

// The idle deadline came: the Vault locks if nothing happened since; else the timer waits for the rest.
@(private)
idle_due :: proc(data: rawptr) {
	v := (^Vault)(data)
	v.idle_timer = base.NIL_HANDLE
	if v.state != .Unlocked { return }
	left := v.active_ns + i64(v.settings.idle_minutes) * 60 * 1_000_000_000 - host.now_ns(v.loop)
	if left > 0 {
		v.idle_timer = host.set_timer(v.loop, f64(left) / 1e6, 0, idle_due, v)
		return
	}
	vault_lock(v)
	set_message(v, i18n.tr("The Vault locked itself after a time without activity."))
}

@(private)
sync_due :: proc(data: rawptr) { _ = vault_sync((^Vault)(data)) }

////////////////////////////////
// What the helper says

// Loop thread (transport.odin): one answer (owned here: zeroed at the end), or the end of a helper.
vault_deliver :: proc(v: ^Vault, t: ^Transport, a: ^Answer, exited, broken: bool) {
	if exited {
		t.exited = true
		if t == v.t {
			v.t = nil
			if v.state != .Disabled {
				fail(v, broken ? i18n.tr("The Vault helper sent a wrong answer and was stopped.") : i18n.tr("The Vault helper stopped."))
			}
		} else {
			for x, i in v.closed { if x == t { unordered_remove(&v.closed, i); break } }
		}
		reap(v, t)
		return
	}
	defer answer_free(a)
	if t != v.t { return }   // a helper that was closed: dropped
	if a.id == 0 {
		// an event: the helper locked itself at its own idle deadline (its exit follows)
		if a.event == "locked" {
			lock_down(v)
			set_message(v, i18n.tr("The Vault locked itself after a time without activity."))
		}
		return
	}
	p, found := take_pending(v, a.id)
	if !found { return }   // late (its deadline passed) or unknown: dropped
	defer pending_free(v, &p, true)
	switch p.op {
	case .Hello:
		if !a.ok { fail(v, a.message != "" ? a.message : i18n.tr("The Vault helper refused to start.")); return }
		if a.account == "locked" && a.email != "" {
			if a.email != v.email {
				string_wipe(&v.email)
				v.email = strings.clone(a.email, base.process_allocator())
			}
			v.pin = a.pin
			if v.passkey != a.passkey {
				v.passkey = a.passkey
				write_account(v)
			}
		}
	case .Login, .Login_Api_Key, .Login_Passkey, .Device_Request, .Device_Poll:
		if !a.ok {
			set_error(v, a.error)
			words := refusal_words(a.error, a.message != "" ? a.message : i18n.tr("The login failed."))
			if p.resend {
				// (the code was not sent again; the login still waits for one)
				set_message(v, words)
				set_state(v, p.back)
				return
			}
			if p.op == .Device_Poll && a.error == "network" && v.state == .Waiting_Device {
				// (the helper keeps the request: the network may come back before it expires)
				set_message(v, words)
				device_poll_later(v)
				return
			}
			close_helper(v)
			string_wipe(&v.login_email)
			set_message(v, words)
			set_state(v, v.email != "" ? .Locked : .Logged_Out)
			return
		}
		if p.op == .Device_Request {
			string_wipe(&v.fingerprint)
			v.fingerprint, a.fingerprint = a.fingerprint, ""
			v.device_since = host.now_ns(v.loop)
			set_state(v, .Waiting_Device)
			device_poll_later(v)
			return
		}
		#partial switch a.result {
		case .Need_Two_Factor:
			v.factors = a.factors
			v.email_sent = a.email_sent
			// (the email's code when it was mailed, or when the account has no authenticator app)
			v.factor = (a.email_sent || .Authenticator not_in a.factors) ? Factor.Email : Factor.Authenticator
			set_state(v, .Need_Two_Factor)
			return
		case .Need_Device_Code:
			set_state(v, .Need_Device_Code)
			return
		case .Pending:
			if v.state == .Waiting_Device { device_poll_later(v) }
			return
		}
		string_wipe(&v.email)
		string_wipe(&v.fingerprint)
		// (the helper names the account when the login did not: an API key, a passkey, another device's approval)
		if a.email != "" {
			v.email = strings.clone(a.email, base.process_allocator())
			string_wipe(&v.login_email)
		} else {
			v.email, v.login_email = v.login_email, ""
		}
		if v.settings.remember_email && v.email != "" {
			string_wipe(&v.remembered)
			v.remembered = strings.clone(v.email, base.process_allocator())
		}
		v.pin = false   // (a new login starts without a PIN)
		v.passkey = a.passkey   // (the login's sync says whether a passkey of the account unlocks it)
		write_account(v)
		became_unlocked(v)
	case .Password_Hint:
		v.hint_busy = false
		if !a.ok {
			set_error(v, a.error)
			set_message(v, refusal_words(a.error, a.message))
			return
		}
		set_message(v, i18n.tr("If an account has this email, the server mailed its master password hint to it."))
	case .Passkey_Options:
		if !a.ok || a.options == "" {
			set_error(v, a.error)
			back_out(v, refusal_words(a.error, a.message != "" ? a.message : i18n.tr("The server does not offer a login with a passkey.")))
			return
		}
		string_wipe(&v.passkey_options)
		v.passkey_options, a.options = a.options, ""
		v.passkey_taken = false
		set_state(v, .Passkey)
	case .Unlock:
		if !a.ok {
			close_helper(v)
			set_error(v, a.error)
			if a.error == "pin_reset" || a.error == "no_pin" {
				v.pin = false
				write_account(v)
			}
			if a.error == "no_passkey" && v.passkey {
				v.passkey = false
				write_account(v)
			}
			set_message(v, refusal_words(a.error, a.message != "" ? a.message : i18n.tr("The vault cannot be unlocked.")))
			if a.error == "no_account" {
				string_wipe(&v.email)
				v.pin = false
			}
			set_state(v, a.error == "no_account" ? .Logged_Out : .Locked)
			return
		}
		became_unlocked(v)
		vault_sync(v)   // (the items may have changed since the last run)
	case .Sync:
		v.syncing = false
		changed(v)
		if !a.ok && a.error == "session_expired" {
			// (the server refuses the session and its token cannot be renewed: only a new login opens one; the vault's
			// copy would go stale while it stays open, so the account is logged out, its email remembered for the login)
			vault_logout(v)
			set_message(v, a.message != "" ? a.message : i18n.tr("The server ended this session. Log in again with the master password."))
			return
		}
		if !a.ok { set_message(v, a.message != "" ? a.message : i18n.tr("The vault could not be synced.")); return }
		v.last_sync = a.last_sync
		if a.passkey != v.passkey {
			// (a passkey for the vault's encryption was added or removed in the web vault)
			v.passkey = a.passkey
			write_account(v)
		}
		rows_refresh(v)   // (the rows kept may be older than the sync)
	case .Pin_Set:
		if !a.ok { set_message(v, a.message != "" ? a.message : i18n.tr("The PIN could not be set.")); return }
		v.pin = true
		write_account(v)
		set_message(v, i18n.tr("The PIN is set: it unlocks the Vault in this profile."))
	case .Pin_Clear:
		if !a.ok { set_message(v, a.message); return }
		v.pin = false
		write_account(v)
		set_message(v, i18n.tr("The PIN is removed."))
	case .Logins_For, .Search:
		set := &v.sets[p.slot]
		// (another document or query was asked meanwhile, or the rows were released)
		if p.gen != set.gen { return }
		if p.op == .Search && p.offset > 0 {
			search_page_came(v, set, p.offset, a)
			return
		}
		if set.state != .Asked { return }
		if !a.ok {
			set.state = .Failed
			set_message(v, a.message)
			changed(v)
			return
		}
		if p.op == .Search {
			// (no page to check them against: a search row fills only when it is also a row of the document; a card or
			// an identity has no site)
			rows_free(&set.rows)
			set.rows, a.rows = a.rows, nil
			// (a helper that does not count says nothing of other pages: what it sent is all)
			set.total = a.total >= len(set.rows) ? a.total : len(set.rows)
			set.state = .Ready
			changed(v)
			return
		}
		check_rows(v, p.slot, a)
	case .Totp:
		if !a.ok { set_message(v, a.message); return }
		if p.copy && .Totp in a.has && v.hooks.copy != nil { v.hooks.copy(v.hooks.user, .Totp, a.values[.Totp], a.remaining) }
		changed(v)
	case .Fill:
		if p.offer != 0 {
			o := &v.offer
			if o.id != p.offer || o.state != .Checking { return }   // (another capture, or dismissed)
			if !a.ok { offer_reset(v); changed(v); return }
			if a.values[.Password] == o.password {
				offer_reset(v)   // (a login is as it was sent: nothing to offer)
				changed(v)
				return
			}
			o.next += 1
			if o.next < len(o.candidates) { offer_check_next(v); return }
			// (none holds this password: the one login it can be is updated; among several, a new one is saved)
			if len(o.candidates) == 1 {
				string_wipe(&o.item)
				o.item = strings.clone(o.candidates[0], base.process_allocator())
				o.state = .Update
			} else {
				o.state = .Save
			}
			changed(v)
			return
		}
		if p.copy {
			if !a.ok { set_message(v, a.message); return }
			field := COPY_FIELDS[p.copy_what]
			value := a.values[field]
			if field not_in a.has || value == "" {
				missing := i18n.tr("This login has no user name.")
				#partial switch p.copy_what {
				case .Password: missing = i18n.tr("This login has no password.")
				case .Number:   missing = i18n.tr("This card has no number.")
				case .Code:     missing = i18n.tr("This card has no security code.")
				case .Email:    missing = i18n.tr("This identity has no email.")
				}
				set_message(v, missing)
				return
			}
			if v.hooks.copy != nil { v.hooks.copy(v.hooks.user, p.copy_what, value, 0) }
			string_wipe(&v.message)
			changed(v)
			return
		}
		v.fill_state = .Answered
		values := Fill_Values{ticket = p.ticket, values = a.values, has = a.has}   // (the strings stay the answer's: zeroed with it)
		applied := a.ok && v.hooks.fill != nil && v.hooks.fill(v.hooks.user, &values)
		v.fill_state = applied ? .Applied : .Dropped
		switch {
		case !a.ok: set_message(v, a.message)
		case !applied: set_message(v, i18n.tr("Nothing was filled: the page changed, or it has no login field."))
		case: string_wipe(&v.message)
		}
		changed(v)
	case .Save:
		if p.offer != 0 && p.offer == v.offer.id { offer_reset(v) }
		if !a.ok {
			set_message(v, refusal_words(a.error == "" ? "save_failed" : a.error, a.message))
			return
		}
		set_message(v, p.key == "" ? i18n.tr("The login is saved in the Vault.") : i18n.tr("The login is updated in the Vault."))
		rows_refresh(v)   // (the helper's copy has it now: the rows are asked again)
	case .Generate:
		if !a.ok || a.value == "" {
			set_message(v, refusal_words(a.error, a.message != "" ? a.message : i18n.tr("No password was generated.")))
			return
		}
		string_wipe(&v.generated)
		v.generated, a.value = a.value, ""
		v.generated_id = p.id
		changed(v)
	case .Passkeys_For, .Passkey_Assert:
		answer := Passkey_Answer{ok = a.ok, error = a.error, rows = a.passkeys[:], signed = a.signed}
		if a.ok && p.op == .Passkey_Assert && (a.signed.authenticator_data == "" || a.signed.signature == "" || a.signed.credential_id == "") {
			// (an answer without what the page needs is no assertion)
			answer.ok, answer.error = false, "assert_failed"
		}
		if !answer.ok && answer.error == "" { answer.error = "failed" }
		passkey_reply(&p, &answer)
	case .Lock, .Logout, .Keepalive:
	}
}

// A later page of a search: appended when it is the page the set waits for (its offset is the rows it holds); a failed
// page ends the paging of this query, its rows stay.
@(private)
search_page_came :: proc(v: ^Vault, set: ^Row_Set, offset: int, a: ^Answer) {
	if set.state != .Ready || !set.more_asked || offset != len(set.rows) { return }
	set.more_asked = false
	if !a.ok {
		set.more_failed = true
		set_message(v, a.message)
		changed(v)
		return
	}
	n := len(a.rows)
	for r in a.rows { append(&set.rows, r) }
	clear(&a.rows)   // (the set owns the rows now)
	if a.total >= 0 { set.total = a.total }
	// (an empty page, or a helper that does not count: no page after this one, which would be asked again and again)
	if n == 0 || a.total < 0 || set.total < len(set.rows) { set.total = len(set.rows) }
	changed(v)
}

// Whether a request of `op` is on its way (the shell shows its wait).
vault_waits_for :: proc(v: ^Vault, op: Op) -> bool {
	for p in v.pending { if p.op == op { return true } }
	return false
}

@(private)
set_state :: proc(v: ^Vault, s: State) {
	if v.state == s { return }
	v.state = s
	changed(v)
}

// A message of the shell for the dialog (what the person must do before a button can work).
vault_say :: proc(v: ^Vault, text: string) { set_message(v, text) }

@(private)
set_message :: proc(v: ^Vault, text: string) {
	// (on the standard error too: a failure the panel shows once, a sync's or a search's, is in the log to read again)
	if !ODIN_TEST && text != "" { fmt.eprintfln("vault: %s", text) }
	string_wipe(&v.message)
	if text != "" { v.message = strings.clone(text, base.process_allocator()) }
	changed(v)
}

@(private)
changed :: proc(v: ^Vault) {
	if v.hooks.changed != nil { v.hooks.changed(v.hooks.user) }
}

// Every set of rows goes (a lock, a logout, a failure), and the secrets kept for the shell with them.
@(private)
rows_reset :: proc(v: ^Vault) {
	for slot in Row_Slot { set_reset(v, slot) }
	offer_reset(v)
	string_wipe(&v.generated)
	v.generated_id = 0
}

@(private)
set_reset :: proc(v: ^Vault, slot: Row_Slot, keep_rows := false) {
	set := &v.sets[slot]
	// (keep_rows: a new query's rows replace the last one's when they come; meanwhile the list shows those, it does not
	// empty and fill again at each letter typed)
	if !keep_rows {
		rows_free(&set.rows)
		set.total = 0
	}
	string_wipe(&set.key)
	set.state = .None
	set.gen += 1
	set.kinds, set.limit = {}, 0
	set.more_asked, set.more_failed = false, false
	// (an ask on its way is forgotten: its answer finds another key)
	for &p in v.pending {
		if (p.op == .Logins_For || p.op == .Search) && p.slot == slot { string_wipe(&p.key) }
	}
}

////////////////////////////////
// Blocking jobs

@(private)
Reap_Job :: struct { v: ^Vault, t: ^Transport }

// A helper that exited: its threads are joined and it is freed on the pool (a join is a system call).
@(private)
reap :: proc(v: ^Vault, t: ^Transport) {
	j := new(Reap_Job, base.process_allocator())
	j^ = {v = v, t = t}
	v.jobs += 1
	host.run_blocking(v.pool, reap_work, reap_done, j, reap_discard)
}

@(private)
reap_work :: proc(data: rawptr) {
	job := (^Reap_Job)(data)
	job.t.destroy(job.t)
}

@(private)
reap_done :: proc(data: rawptr) {
	job := (^Reap_Job)(data)
	job.v.jobs -= 1
	free(job, base.process_allocator())
}

@(private)
reap_discard :: proc(data: rawptr) {
	reap_work(data)
	reap_done(data)
}

@(private)
Check_Job :: struct {
	v:          ^Vault,
	slot:       Row_Slot,
	gen:        u64,
	url:        string,            // owned
	rows:       [dynamic]Row,      // owned: the helper's, then the kept ones
	equivalent: [dynamic]string,   // owned: the answer's equivalent domains
}

// The rows of an answer, checked with Wren's Public Suffix List on the pool (docs/bitwarden.md 3.5, rule 4).
@(private)
check_rows :: proc(v: ^Vault, slot: Row_Slot, a: ^Answer) {
	set := &v.sets[slot]
	j := new(Check_Job, base.process_allocator())
	j^ = {v = v, slot = slot, gen = set.gen, url = strings.clone(set.key, base.process_allocator()), rows = a.rows, equivalent = a.equivalent}
	a.rows, a.equivalent = nil, nil   // (the job owns them now)
	set.state = .Checking
	v.jobs += 1
	host.run_blocking(v.pool, check_work, check_done, j, check_discard)
}

@(private)
check_work :: proc(data: rawptr) {
	j := (^Check_Job)(data)
	site, ok := site_of(j.url)
	kept := make([dynamic]Row, 0, len(j.rows), base.process_allocator())
	for &r in j.rows {
		if ok && row_matches(site, r.uri, r.match, j.equivalent[:]) { append(&kept, r) } else { row_free(&r) }
	}
	delete(j.rows)
	j.rows = kept
}

@(private)
check_done :: proc(data: rawptr) {
	j := (^Check_Job)(data)
	v := j.v
	v.jobs -= 1
	set := &v.sets[j.slot]
	if j.gen == set.gen && v.state == .Unlocked {
		rows_free(&set.rows)
		set.rows = j.rows
		j.rows = nil
		set.state = .Ready
		offer_rows_came(v)
		changed(v)
	}
	check_free(j)
}

@(private)
check_discard :: proc(data: rawptr) {
	j := (^Check_Job)(data)
	j.v.jobs -= 1
	check_free(j)
}

@(private)
check_free :: proc(j: ^Check_Job) {
	rows_free(&j.rows)
	strings_free(&j.equivalent)
	string_wipe(&j.url)
	free(j, base.process_allocator())
}

@(private)
Setup_Job :: struct {
	v:              ^Vault,
	gen:            u64,
	profile_dir:    string,   // owned
	helper_setting: string,   // owned
	identity:       string,   // owned: the server's identity address (an account of another server is not this one's)
	helper:         string,   // owned: found
	email:          string,   // owned: from the account file
	pin:            bool,     // from the account file
	passkey:        bool,     // from the account file: a passkey of the account can unlock it
	remembered:     string,   // owned: from the account file: the last email that logged in
	never:          [dynamic]string,   // owned: from the never-save list
}

// Off the loop: where the helper is, and which account the profile remembers for this server.
@(private)
setup_work :: proc(data: rawptr) {
	j := (^Setup_Job)(data)
	context.allocator = base.process_allocator()
	j.helper = locate_helper(j.helper_setting)
	if j.profile_dir != "" {
		path := join_path({j.profile_dir, "vault", ACCOUNT_FILE})
		if bytes, err := os.read_entire_file(path, context.temp_allocator); err == nil {
			f := account_parse(string(bytes))
			if f.email != "" && f.identity == j.identity {
				j.email = strings.clone(f.email)
				j.pin, j.passkey = f.pin, f.passkey
			}
			// (the remembered email is the profile's, whatever the server: a logout keeps it)
			if f.remembered != "" { j.remembered = strings.clone(f.remembered) }
		}
		if bytes, err := os.read_entire_file(join_path({j.profile_dir, "vault", NEVER_FILE}), context.temp_allocator); err == nil {
			j.never = never_parse(string(bytes))
		}
	}
}

// The never-save list's text: one host a line, in lower case; empty lines and repeats are left out. Owned (process
// allocator).
never_parse :: proc(text: string) -> (hosts: [dynamic]string) {
	hosts = make([dynamic]string, base.process_allocator())
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		h := base.ascii_lower(strings.trim_space(line), context.temp_allocator)
		if h == "" { continue }
		seen := false
		for x in hosts { if x == h { seen = true; break } }
		if !seen { append(&hosts, strings.clone(h, base.process_allocator())) }
	}
	return
}

never_text :: proc(hosts: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for h in hosts {
		strings.write_string(&b, h)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// What the account file says (Wren's; no secret): the remembered account (its email, its server's identity address, the
// ways it unlocks besides its master password), and the last email that logged in (vault.login.remember_email), which a
// logout keeps.
Account_File :: struct {
	email, identity: string,
	pin, passkey:    bool,
	remembered:      string,
}

// One value per line: the email, the server, the marks ("pin", "passkey", separated by spaces), the remembered email.
// A file of an earlier version has fewer lines: what is missing is empty.
account_text :: proc(f: Account_File, allocator := context.temp_allocator) -> string {
	marks := f.pin && f.passkey ? "pin passkey" : (f.pin ? "pin" : (f.passkey ? "passkey" : ""))
	return strings.concatenate({f.email, "\n", f.identity, "\n", marks, "\n", f.remembered, "\n"}, allocator)
}

// The values are slices of `text`.
account_parse :: proc(text: string) -> (f: Account_File) {
	e, _, r1 := strings.partition(text, "\n")
	s, _, r2 := strings.partition(r1, "\n")
	m, _, r3 := strings.partition(r2, "\n")
	r, _, _ := strings.partition(r3, "\n")
	f.email, f.identity, f.remembered = strings.trim_space(e), strings.trim_space(s), strings.trim_space(r)
	marks := strings.trim_space(m)
	for word in strings.split_iterator(&marks, " ") {
		switch word {
		case "pin":     f.pin = true
		case "passkey": f.passkey = true
		}
	}
	return
}

@(private)
setup_done :: proc(data: rawptr) {
	j := (^Setup_Job)(data)
	v := j.v
	v.jobs -= 1
	defer setup_free(j)
	if j.gen != v.setup_gen || v.state != .Locating { return }
	delete(v.helper, base.process_allocator())
	v.helper, j.helper = j.helper, ""
	string_wipe(&v.email)
	v.email, j.email = j.email, ""
	v.pin = v.email != "" && j.pin
	v.passkey = v.email != "" && j.passkey
	if j.remembered != "" && v.settings.remember_email {
		string_wipe(&v.remembered)
		v.remembered, j.remembered = j.remembered, ""
	}
	if j.never != nil {
		strings_free(&v.never)
		v.never, j.never = j.never, nil
	}
	if v.helper == "" { set_state(v, .Helper_Missing); return }
	set_state(v, v.email != "" ? .Locked : .Logged_Out)
}

@(private)
setup_discard :: proc(data: rawptr) {
	j := (^Setup_Job)(data)
	j.v.jobs -= 1
	setup_free(j)
}

@(private)
setup_free :: proc(j: ^Setup_Job) {
	context.allocator = base.process_allocator()
	delete(j.profile_dir)
	delete(j.helper_setting)
	delete(j.identity)
	delete(j.helper)
	string_wipe(&j.email)
	string_wipe(&j.remembered)
	strings_free(&j.never)
	free(j)
}

// A path of parts joined with the system's separator (temporary unless `allocator` says otherwise).
join_path :: proc(parts: []string, allocator := context.temp_allocator) -> string {
	p, _ := filepath.join(parts, allocator)
	return p
}

// The helper's path: the preference, else beside the browser, else in its vault folder (build/vault/ beside build/wren).
// "" when none is a file. Off the loop thread (it reads the disk).
locate_helper :: proc(setting: string, allocator := context.allocator) -> string {
	if setting != "" { return os.is_file(setting) ? strings.clone(setting, allocator) : "" }
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil { return "" }
	for c in ([]string{join_path({dir, HELPER_NAME}), join_path({dir, "vault", HELPER_NAME})}) {
		if os.is_file(c) { return strings.clone(c, allocator) }
	}
	return ""
}

@(private)
File_Job :: struct {
	v:      ^Vault,
	queue:  ^File_Queue,
	dir:    string,   // owned: <profile>/vault
	name:   string,   // the file's name in it (a constant)
	text:   string,   // owned: what the file holds ("" with `remove`)
	remove: bool,     // the file goes
	ok:     bool,
}

// The remembered account, for the next start (the locked icon is drawn without starting the helper).
@(private)
write_account :: proc(v: ^Vault) {
	if v.profile_dir == "" { return }
	if v.email == "" && v.remembered == "" { file_job(v, &v.account_file, ACCOUNT_FILE, "", true); return }   // (nothing to remember: the file goes)
	identity, _ := server_urls(v.settings)
	if v.email == "" { identity = "" }   // (no account: the email to offer only, of no server)
	f := Account_File{email = v.email, identity = identity, pin = v.pin, passkey = v.passkey, remembered = v.remembered}
	file_job(v, &v.account_file, ACCOUNT_FILE, account_text(f, base.process_allocator()), false)
}

// The never-save list, for the next start.
@(private)
write_never :: proc(v: ^Vault) {
	if v.profile_dir == "" { return }
	file_job(v, &v.never_file, NEVER_FILE, never_text(v.never[:], base.process_allocator()), false)
}

// One job on a file at a time (File_Queue). Takes `text` (owned).
@(private)
file_job :: proc(v: ^Vault, q: ^File_Queue, name, text: string, remove: bool) {
	if q.busy {
		string_wipe(&q.next)
		q.next, q.queued, q.next_remove = text, true, remove
		return
	}
	j := new(File_Job, base.process_allocator())
	j^ = {v = v, queue = q, dir = join_path({v.profile_dir, "vault"}, base.process_allocator()), name = name, text = text, remove = remove}
	v.jobs += 1
	q.busy = true
	host.run_blocking(v.pool, file_work, file_done, j, file_discard)
}

@(private)
file_work :: proc(data: rawptr) {
	job := (^File_Job)(data)
	path := join_path({job.dir, job.name})
	if job.remove {
		job.ok = host.file_drop(job.v.writer, path)
		return
	}
	_ = os.make_directory_all(job.dir, {.Read_User, .Write_User, .Execute_User})
	job.ok = host.file_put(job.v.writer, path, transmute([]byte)job.text, private = true)
}

@(private)
file_done :: proc(data: rawptr) {
	job := (^File_Job)(data)
	v, q, name := job.v, job.queue, job.name
	v.jobs -= 1
	q.busy = false
	file_free(job)
	if q.queued {
		text := q.next
		q.next, q.queued = "", false
		file_job(v, q, name, text, q.next_remove)
	}
}

// The pool ended before the job ran: nothing more is started.
@(private)
file_discard :: proc(data: rawptr) {
	job := (^File_Job)(data)
	job.v.jobs -= 1
	job.queue.busy = false
	file_free(job)
}

@(private)
file_free :: proc(j: ^File_Job) {
	delete(j.dir, base.process_allocator())
	string_wipe(&j.text)
	free(j, base.process_allocator())
}
