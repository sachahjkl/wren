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
// live in three sets (Row_Slot): the active tab's document and the focused frame's document while the Vault is unlocked
// (the address bar's chip, the fill shortcut and the field's dropdown need them at once), the palette's search while the
// palette is open. A lock, a release or another document zeroes them. Nothing here logs.
//
// Time: two timers run while the Vault is unlocked. The idle timer locks it `vault.lock.idle_minutes` after the last user
// activity (vault_activity); the sync timer asks for a sync every `vault.sync.interval_minutes`. The helper has its own
// idle deadline, later than the Vault's, renewed by the keepalives that activity sends (at most one a minute).
package vault

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
	Locked,            // an account is remembered; no helper holds its keys
	Unlocking,         // an unlock waits for its answer
	Unlocked,          // the helper holds the keys: rows and fills work
	Failed,            // the helper stopped or did not answer; the next login or unlock starts again
}

Rows_State :: enum u8 { None, Asked, Checking, Ready, Failed }

// The sets of rows the Vault keeps: the logins of the active tab's document, of the focused frame's document (a form in
// a frame: its own origin decides), and the palette's search.
Row_Slot :: enum u8 { Page, Frame, Search }

Row_Set :: struct {
	rows:  [dynamic]Row,   // Page, Frame: checked by Wren (match.odin); Search: as the helper sent them
	key:   string,         // owned: the document's address (Page, Frame) or the query (Search)
	state: Rows_State,
	gen:   u64,            // each ask: a check of an older ask is dropped
}

// What a fill asks of the helper.
Fill_Field :: enum u8 { Username, Password, Totp }
Fill_Fields :: bit_set[Fill_Field; u8]

// What a copy puts on the clipboard.
Copy_What :: enum u8 { Username, Password, Totp }

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
	ticket:   Fill_Ticket,
	username, password, totp: string,
	has_username, has_password, has_totp: bool,
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
	copy:    bool,          // .Fill, .Totp: for the clipboard (copy_what), not for a page
	copy_what: Copy_What,
}

@(private)
Timeout :: struct { v: ^Vault, id: u64 }

Vault :: struct {
	loop:           ^host.Loop,
	pool:           ^host.Blocking_Pool,
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
	syncing:        bool,                  // a sync waits for its answer
	last_sync:      i64,                   // Unix seconds of the last sync of this run (0: none)
	active_ns:      i64,                   // the loop's clock at the last user activity
	keepalive_ns:   i64,                   // the loop's clock at the last keepalive
	idle_timer:     base.Handle,
	sync_timer:     base.Handle,
	account_busy:   bool,                  // a job writes or removes the account file
	account_queued: bool,                  // and another waits for it:
	account_next:   string,                // owned: its text
	account_next_remove: bool,
}

ACCOUNT_FILE :: "account"   // <profile>/vault/account: the email, the server and the PIN mark of the remembered account (Wren's)
HELPER_NAME :: "wren-vault.exe" when ODIN_OS == .Windows else "wren-vault"
KEEPALIVE_EVERY_NS :: i64(60) * 1_000_000_000   // activity sends at most one keepalive a minute
PIN_MIN :: 4
SEARCH_LIMIT :: 50   // rows of one search: what a palette lists (the helper's bound too)

////////////////////////////////
// Life

// Loop thread. `profile_dir` "": nothing is written and no account is remembered between runs.
vault_init :: proc(v: ^Vault, loop: ^host.Loop, pool: ^host.Blocking_Pool, prefs: ^config.Prefs, profile_dir, client_version: string, hooks: Hooks, spawn: Spawn_Proc = process_spawn) {
	v.loop, v.pool, v.hooks, v.spawn = loop, pool, hooks, spawn
	v.settings = settings_from_prefs(prefs)
	v.profile_dir = strings.clone(profile_dir, base.process_allocator())
	v.client_version = strings.clone(client_version, base.process_allocator())
	v.closed = make([dynamic]^Transport)
	v.pending = make([dynamic]Pending)
	v.state = .Disabled
	if v.settings.enabled { enable(v) }
}

// Loop thread. Kills a helper that still works, waits for the jobs, zeroes what is kept.
vault_destroy :: proc(v: ^Vault) {
	timers_stop(v)
	drop_pending(v)
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
	string_wipe(&v.account_next)
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
vault_login :: proc(v: ^Vault, email, password: string, code := "") -> bool {
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
		provider := v.state == .Need_Device_Code ? "device" : FACTOR_NAMES[v.factor]
		r: Request
		request_begin(&r, next_id(v), .Login, len(v.login_email) + len(c) + 32)
		request_string(&r, "email", v.login_email)
		request_string(&r, "code", c)
		request_string(&r, "provider", provider)
		send(v, &r, .Login)
	case .Disabled, .Locating, .Helper_Missing, .Logging_In, .Unlocking, .Unlocked:
		return false
	}
	string_wipe(&v.message)
	set_state(v, .Logging_In)
	return true
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
	string_wipe(&v.message)
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
	send(v, &r, .Login)
	string_wipe(&v.message)
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
	string_wipe(&v.message)
	set_state(v, .Unlocking)
	return true
}

// Lock: the helper exits (docs/bitwarden.md 3.2). Also what a cancelled login does.
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
	string_wipe(&v.message)
	v.pin = false
	remove_account(v)
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
	if v.state != .Unlocked || slot == .Search { return }
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
		p.slot = slot
	}
	set.state = .Asked
	changed(v)
}

// The logins whose name, user name or address hold every word of `query` (the palette's Vault prefix). The helper
// searches (Wren does no work in proportion to the vault); an answer for an older query is dropped. The rows come later
// (Search state Ready); they hold no password.
vault_search :: proc(v: ^Vault, query: string) {
	if v.state != .Unlocked { return }
	set := &v.sets[.Search]
	if set.state != .None && query == set.key { return }
	set_reset(v, .Search)
	set.key = strings.clone(query, base.process_allocator())
	r: Request
	request_begin(&r, next_id(v), .Search, len(query) + 16)
	request_string(&r, "query", query)
	request_int(&r, "limit", SEARCH_LIMIT)
	p := send(v, &r, .Search)
	if p != nil {
		p.key = strings.clone(query, base.process_allocator())
		p.slot = .Search
	}
	set.state = .Asked
	changed(v)
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
	request_begin(&r, next_id(v), .Fill, len(item) + 48)
	request_string(&r, "item", item)
	names := make([dynamic]string, 0, 3, context.temp_allocator)
	if .Username in fields { append(&names, "username") }
	if .Password in fields { append(&names, "password") }
	if .Totp in fields { append(&names, "totp") }
	request_list(&r, "fields", names[:])
	p := send(v, &r, .Fill)
	if p == nil { return false }
	p.ticket = ticket
	p.ticket.url = strings.clone(ticket.url, base.process_allocator())
	v.fill_state = .Requested
	return true
}

// A copy of one value of the row `item` (a click or a palette choice of the user). The value goes to the `copy` hook
// when it comes; the shell clears the clipboard after vault.clipboard.clear_seconds. False: nothing was sent.
vault_copy :: proc(v: ^Vault, item: string, what: Copy_What) -> bool {
	if v.state != .Unlocked || v.t == nil || item == "" { return false }
	r: Request
	p: ^Pending
	switch what {
	case .Username, .Password:
		request_begin(&r, next_id(v), .Fill, len(item) + 32)
		request_string(&r, "item", item)
		request_list(&r, "fields", {what == .Username ? "username" : "password"})
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

@(private)
drop_pending :: proc(v: ^Vault) {
	for &p in v.pending {
		if p.op == .Fill && !p.copy { v.fill_state = .Dropped }
		pending_free(v, &p, true)
	}
	clear(&v.pending)
	v.syncing = false
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
	current := p.key != "" && p.key == v.sets[p.slot].key
	key := strings.clone(p.key, context.temp_allocator)
	pending_free(v, &p, false)   // (frees `to`, wipes p.key)
	switch p.op {
	case .Logins_For, .Search:
		if !current { return }
		set_reset(v, p.slot)
		// (the key stays: the shell asks each frame, and a failed ask is not sent again for the same document)
		v.sets[p.slot].key = strings.clone(key, base.process_allocator())
		v.sets[p.slot].state = .Failed
		set_message(v, i18n.tr("The Vault did not answer in time."))
	case .Fill, .Totp:
		if p.copy {
			set_message(v, i18n.tr("The copy took too long and was dropped."))
		} else {
			v.fill_state = .Dropped
			set_message(v, i18n.tr("The fill took too long and was dropped."))
		}
	case .Hello, .Login, .Login_Api_Key, .Unlock, .Lock, .Logout, .Sync, .Pin_Set, .Pin_Clear, .Keepalive:
		// (the helper answers in order: one that does not answer holds every later request)
		fail(v, i18n.tr("The Vault helper did not answer in time. It was stopped."))
	}
	changed(v)
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
		}
	case .Login, .Login_Api_Key:
		if !a.ok {
			close_helper(v)
			string_wipe(&v.login_email)
			set_message(v, a.message != "" ? a.message : i18n.tr("The login failed."))
			set_state(v, v.email != "" ? .Locked : .Logged_Out)
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
		}
		string_wipe(&v.email)
		if p.op == .Login_Api_Key {
			v.email = a.email != "" ? strings.clone(a.email, base.process_allocator()) : ""
			string_wipe(&v.login_email)
		} else {
			v.email, v.login_email = v.login_email, ""
		}
		v.pin = false   // (a new login starts without a PIN)
		write_account(v)
		became_unlocked(v)
	case .Unlock:
		if !a.ok {
			close_helper(v)
			if a.error == "pin_reset" || a.error == "no_pin" {
				v.pin = false
				write_account(v)
			}
			set_message(v, a.message != "" ? a.message : i18n.tr("The vault cannot be unlocked."))
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
		if !a.ok { set_message(v, a.message != "" ? a.message : i18n.tr("The vault could not be synced.")); return }
		v.last_sync = a.last_sync
		// (the rows kept may be older than the sync)
		for slot in Row_Slot {
			key := strings.clone(v.sets[slot].key, context.temp_allocator)
			if key == "" && slot != .Search { continue }
			if v.sets[slot].state == .None { continue }
			set_reset(v, slot)
			if slot == .Search { vault_search(v, key) } else { vault_ask_rows(v, key, slot) }
		}
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
		if set.state != .Asked || p.key != set.key { return }
		if !a.ok {
			set.state = .Failed
			set_message(v, a.message)
			changed(v)
			return
		}
		if p.op == .Search {
			// (no page to check them against: a search row fills only when it is also a row of the document)
			rows_free(&set.rows)
			set.rows, a.rows = a.rows, nil
			set.state = .Ready
			changed(v)
			return
		}
		check_rows(v, p.slot, a)
	case .Totp:
		if !a.ok { set_message(v, a.message); return }
		if p.copy && a.has_totp && v.hooks.copy != nil { v.hooks.copy(v.hooks.user, .Totp, a.totp, a.remaining) }
		changed(v)
	case .Fill:
		if p.copy {
			if !a.ok { set_message(v, a.message); return }
			value, has := a.username, a.has_username
			if p.copy_what == .Password { value, has = a.password, a.has_password }
			if !has || value == "" {
				set_message(v, p.copy_what == .Password ? i18n.tr("This login has no password.") : i18n.tr("This login has no user name."))
				return
			}
			if v.hooks.copy != nil { v.hooks.copy(v.hooks.user, p.copy_what, value, 0) }
			string_wipe(&v.message)
			changed(v)
			return
		}
		v.fill_state = .Answered
		values := Fill_Values{ticket = p.ticket, username = a.username, password = a.password, totp = a.totp,
			has_username = a.has_username, has_password = a.has_password, has_totp = a.has_totp}
		applied := a.ok && v.hooks.fill != nil && v.hooks.fill(v.hooks.user, &values)
		v.fill_state = applied ? .Applied : .Dropped
		switch {
		case !a.ok: set_message(v, a.message)
		case !applied: set_message(v, i18n.tr("Nothing was filled: the page changed, or it has no login field."))
		case: string_wipe(&v.message)
		}
		changed(v)
	case .Lock, .Logout, .Keepalive:
	}
}

@(private)
set_state :: proc(v: ^Vault, s: State) {
	if v.state == s { return }
	v.state = s
	changed(v)
}

@(private)
set_message :: proc(v: ^Vault, text: string) {
	string_wipe(&v.message)
	if text != "" { v.message = strings.clone(text, base.process_allocator()) }
	changed(v)
}

@(private)
changed :: proc(v: ^Vault) {
	if v.hooks.changed != nil { v.hooks.changed(v.hooks.user) }
}

// Every set of rows goes (a lock, a logout, a failure).
@(private)
rows_reset :: proc(v: ^Vault) {
	for slot in Row_Slot { set_reset(v, slot) }
}

@(private)
set_reset :: proc(v: ^Vault, slot: Row_Slot) {
	set := &v.sets[slot]
	rows_free(&set.rows)
	string_wipe(&set.key)
	set.state = .None
	set.gen += 1
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
		if ok && row_matches(site, r.uri, r.kind, j.equivalent[:]) { append(&kept, r) } else { row_free(&r) }
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
			email, server, pin := account_parse(string(bytes))
			if email != "" && server == j.identity {
				j.email = strings.clone(email)
				j.pin = pin
			}
		}
	}
}

// The account file: the email, the server's identity address, then "pin" when a PIN is set; one per line.
account_text :: proc(email, identity: string, pin: bool, allocator := context.temp_allocator) -> string {
	return strings.concatenate({email, "\n", identity, "\n", pin ? "pin" : "", "\n"}, allocator)
}

account_parse :: proc(text: string) -> (email, identity: string, pin: bool) {
	rest := text
	e, _, r1 := strings.partition(rest, "\n")
	s, _, r2 := strings.partition(r1, "\n")
	p, _, _ := strings.partition(r2, "\n")
	return strings.trim_space(e), strings.trim_space(s), strings.trim_space(p) == "pin"
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
Account_Job :: struct {
	v:      ^Vault,
	dir:    string,   // owned
	text:   string,   // owned: what the file holds ("" with `remove`)
	remove: bool,     // logout: the file goes
	ok:     bool,
}

// The remembered account, for the next start (the locked icon is drawn without starting the helper).
@(private)
write_account :: proc(v: ^Vault) {
	if v.profile_dir == "" || v.email == "" { return }
	identity, _ := server_urls(v.settings)
	account_job(v, account_text(v.email, identity, v.pin, base.process_allocator()), false)
}

@(private)
remove_account :: proc(v: ^Vault) {
	if v.profile_dir == "" { return }
	account_job(v, "", true)
}

// One job on the file at a time: the pool's workers run in any order, and a removal must not be undone by an older
// write. A job asked meanwhile waits (only the last one: it says what the file must be). Takes `text` (owned).
@(private)
account_job :: proc(v: ^Vault, text: string, remove: bool) {
	if v.account_busy {
		string_wipe(&v.account_next)
		v.account_next, v.account_queued, v.account_next_remove = text, true, remove
		return
	}
	j := new(Account_Job, base.process_allocator())
	j^ = {v = v, dir = join_path({v.profile_dir, "vault"}, base.process_allocator()), text = text, remove = remove}
	v.jobs += 1
	v.account_busy = true
	host.run_blocking(v.pool, account_work, account_done, j, account_discard)
}

@(private)
account_work :: proc(data: rawptr) {
	job := (^Account_Job)(data)
	path := join_path({job.dir, ACCOUNT_FILE})
	if job.remove {
		job.ok = os.remove(path) == nil
		return
	}
	_ = os.make_directory_all(job.dir, {.Read_User, .Write_User, .Execute_User})
	job.ok = os.write_entire_file(path, job.text, {.Read_User, .Write_User}) == nil
}

@(private)
account_done :: proc(data: rawptr) {
	job := (^Account_Job)(data)
	v := job.v
	v.jobs -= 1
	v.account_busy = false
	account_free(job)
	if v.account_queued {
		text := v.account_next
		v.account_next, v.account_queued = "", false
		account_job(v, text, v.account_next_remove)
	}
}

// The pool ended before the job ran: nothing more is started.
@(private)
account_discard :: proc(data: rawptr) {
	job := (^Account_Job)(data)
	job.v.jobs -= 1
	job.v.account_busy = false
	account_free(job)
}

@(private)
account_free :: proc(j: ^Account_Job) {
	delete(j.dir, base.process_allocator())
	string_wipe(&j.text)
	free(j, base.process_allocator())
}
