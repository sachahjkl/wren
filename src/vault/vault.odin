// Package vault: the client of the Vault helper (docs/bitwarden.md). It starts and stops the helper, speaks its pipe
// protocol, keeps the one state of the Vault that every surface reads, and checks the rows of a page with Wren's own
// Public Suffix List. It has no interface and no dependency on the browser or the pages: the shell (src/browser/vault_*)
// draws it and applies a fill.
//
// Threads: every procedure here runs on the loop thread and returns at once. Starting the helper, the pipes, the files and
// the check of the rows run on the transport's threads and on the blocking pool; their results are posted to the loop.
//
// Secrets: a password or a code goes from the caller into one frame, which is zeroed once written. A fill's values live
// in one Answer for the time of the `fill` hook, then are zeroed. Rows (names, user names) live while a surface shows
// them (vault_release_rows). Nothing here logs.
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
	Need_Two_Factor,   // the account asks for its authenticator code
	Locked,            // an account is remembered; no helper holds its keys
	Unlocking,         // an unlock waits for its answer
	Unlocked,          // the helper holds the keys: rows and fills work
	Failed,            // the helper stopped or did not answer; the next login or unlock starts again
}

Rows_State :: enum u8 { None, Asked, Checking, Ready, Failed }

// The second state machine, per fill: Requested -> Answered -> Applied | Dropped (docs/bitwarden.md 4.3).
Fill_State :: enum u8 { None, Requested, Answered, Applied, Dropped }

// What a fill is for, checked again when its values come: the shell drops the fill when the tab, its page or its
// navigation changed meanwhile (docs/bitwarden.md 3.5, rule 9).
Fill_Ticket :: struct {
	tab:  u64,
	page: rawptr,
	nav:  rawptr,
	url:  string,   // owned by the Vault while the fill waits
}

// The values handed to the shell's `fill` hook: valid for the time of the call only, then zeroed.
Fill_Values :: struct {
	ticket:   Fill_Ticket,
	username, password: string,
	has_username, has_password: bool,
}

Hooks :: struct {
	user:    rawptr,
	changed: proc(user: rawptr),                              // the state, the rows or the message changed: draw again
	fill:    proc(user: rawptr, values: ^Fill_Values) -> bool,   // applies a fill; false: dropped
}

@(private)
Pending :: struct {
	id:      u64,
	op:      Op,
	timer:   base.Handle,
	timeout: ^Timeout,
	ticket:  Fill_Ticket,   // .Fill (its url owned)
	url:     string,        // .Logins_For: the document (owned)
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
	helper:         string,   // owned: the helper's path ("" until located)
	profile_dir:    string,   // owned: "" = nothing is written (browser.profile.persist off)
	client_version: string,   // owned
	t:              ^Transport,
	closed:         [dynamic]^Transport,   // closed, waiting for their Exited
	next_id:        u64,
	pending:        [dynamic]Pending,
	rows:           [dynamic]Row,          // the logins of rows_url, checked by Wren (match.odin)
	rows_url:       string,                // owned
	rows_state:     Rows_State,
	rows_gen:       u64,                   // each ask: a check of an older ask is dropped
	fill_state:     Fill_State,
	setup_gen:      u64,                   // each enable: a locate job of an older one is dropped
	jobs:           int,                   // blocking jobs on their way (vault_destroy waits for them)
	login_email:    string,                // owned: the email of a login that waits for its second factor
}

ACCOUNT_FILE :: "account"   // <profile>/vault/account: the email and the server of the remembered account (Wren's)
HELPER_NAME :: "wren-vault.exe" when ODIN_OS == .Windows else "wren-vault"

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
	drop_pending(v)
	if v.t != nil { v.t.destroy(v.t); v.t = nil }
	for t in v.closed { t.destroy(t) }
	delete(v.closed)
	// (after the threads are joined: nothing more is posted; what was posted and never ran is zeroed)
	host.discard_posted(v.loop, transport_posted, transport_discard)
	for v.jobs > 0 { host.blocking_settle(v.pool) }
	delete(v.pending)
	rows_free(&v.rows)
	string_wipe(&v.rows_url)
	string_wipe(&v.message)
	string_wipe(&v.email)
	string_wipe(&v.login_email)
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
	case v.settings.enabled && (old.server_url != v.settings.server_url || old.helper_path != v.settings.helper_path):
		// another server or another helper: what runs now is for the old one
		disable(v)
		enable(v)
	}
}

@(private)
enable :: proc(v: ^Vault) {
	set_state(v, .Locating)
	v.setup_gen += 1
	j := new(Setup_Job, base.process_allocator())
	j^ = {v = v, gen = v.setup_gen, profile_dir = strings.clone(v.profile_dir, base.process_allocator()), helper_setting = strings.clone(v.settings.helper_path, base.process_allocator())}
	v.jobs += 1
	host.run_blocking(v.pool, setup_work, setup_done, j, setup_discard)
}

@(private)
disable :: proc(v: ^Vault) {
	close_helper(v)
	v.setup_gen += 1
	rows_reset(v)
	string_wipe(&v.message)
	set_state(v, .Disabled)
}

////////////////////////////////
// What the shell asks (loop thread)

// A login: the email, the master password, and a code when the account asks for one (Need_Two_Factor: then the
// password is "" and the helper uses the one it keeps for this login).
vault_login :: proc(v: ^Vault, email, password: string, code := "") -> bool {
	switch v.state {
	case .Logged_Out, .Locked, .Failed:
		if password == "" { return false }
		if !ensure_helper(v) { return false }
		string_wipe(&v.login_email)
		v.login_email = strings.clone(strings.trim_space(email), base.process_allocator())
		r: Request
		request_begin(&r, next_id(v), .Login, len(email) + len(password))
		request_string(&r, "email", strings.trim_space(email))
		request_string(&r, "password", password)
		send(v, &r, .Login)
	case .Need_Two_Factor:
		c := strings.trim_space(code)
		if c == "" || v.t == nil { return false }
		r: Request
		request_begin(&r, next_id(v), .Login, len(v.login_email) + len(c))
		request_string(&r, "email", v.login_email)
		request_string(&r, "totp", c)
		send(v, &r, .Login)
	case .Disabled, .Locating, .Helper_Missing, .Logging_In, .Unlocking, .Unlocked:
		return false
	}
	string_wipe(&v.message)
	set_state(v, .Logging_In)
	return true
}

// An unlock of the remembered account.
vault_unlock :: proc(v: ^Vault, password: string) -> bool {
	if (v.state != .Locked && v.state != .Failed) || v.email == "" || password == "" { return false }
	if !ensure_helper(v) { return false }
	r: Request
	request_begin(&r, next_id(v), .Unlock, len(password))
	request_string(&r, "password", password)
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
	close_helper(v)
	rows_reset(v)
	string_wipe(&v.login_email)
	set_state(v, v.email != "" ? .Locked : .Logged_Out)
}

// The logins of the document at `address` (the shell asks when the panel opens or the tab's address changes). The rows
// come later (rows_state Ready).
vault_ask_rows :: proc(v: ^Vault, address: string) {
	if v.state != .Unlocked { return }
	// (the shell calls this each frame the panel shows: an address already asked, answered or refused is not asked again)
	if address == v.rows_url && v.rows_state != .None { return }
	rows_reset(v)
	v.rows_url = strings.clone(address, base.process_allocator())
	v.rows_gen += 1
	site, ok := site_of(address)
	if !ok {
		v.rows_state = .Ready   // (nothing is ever filled there: no row)
		changed(v)
		return
	}
	r: Request
	request_begin(&r, next_id(v), .Logins_For, len(site.url) + len(site.host) + len(site.domain))
	request_string(&r, "url", site.url)
	request_string(&r, "host", site.host)
	request_string(&r, "domain", site.domain)
	p := send(v, &r, .Logins_For)
	if p != nil { p.url = strings.clone(address, base.process_allocator()) }
	v.rows_state = .Asked
	changed(v)
}

// The rows are not shown any more: they are zeroed (docs/bitwarden.md 3.1).
vault_release_rows :: proc(v: ^Vault) { rows_reset(v) }

// A fill of the row `item` that the user picked, for the document of `ticket`. False: nothing was sent.
vault_fill :: proc(v: ^Vault, item: string, ticket: Fill_Ticket) -> bool {
	if v.state != .Unlocked || v.t == nil { return false }
	r: Request
	request_begin(&r, next_id(v), .Fill, len(item) + 32)
	request_string(&r, "item", item)
	request_list(&r, "fields", {"username", "password"})
	p := send(v, &r, .Fill)
	if p == nil { return false }
	p.ticket = ticket
	p.ticket.url = strings.clone(ticket.url, base.process_allocator())
	v.fill_state = .Requested
	return true
}

// Whether the vault's account is remembered (the panel offers Unlock rather than Log in).
vault_has_account :: proc(v: ^Vault) -> bool { return v.email != "" }

////////////////////////////////
// The helper

@(private)
ensure_helper :: proc(v: ^Vault) -> bool {
	if v.t != nil { return true }
	if v.helper == "" {
		set_state(v, .Helper_Missing)
		return false
	}
	v.t = v.spawn(v, v.helper)
	identity, api := server_urls(v.settings)
	state_dir := v.profile_dir != "" ? join_path({v.profile_dir, "vault"}) : ""
	r: Request
	request_begin(&r, next_id(v), .Hello, len(state_dir) + len(identity) + len(api) + len(v.client_version) + 16)
	request_int(&r, "protocol", PROTOCOL_VERSION)
	request_string(&r, "state_dir", state_dir)
	request_string(&r, "identity_url", identity)
	request_string(&r, "api_url", api)
	request_bool(&r, "persist", v.profile_dir != "")
	request_string(&r, "device_name", "Wren")
	request_string(&r, "client_version", v.client_version)
	send(v, &r, .Hello)
	return true
}

// Closes the helper (it exits once it read what is queued) and forgets what it was asked.
@(private)
close_helper :: proc(v: ^Vault) {
	drop_pending(v)
	if v.t == nil { return }
	v.t.close(v.t)
	append(&v.closed, v.t)
	v.t = nil
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
	string_wipe(&p.url)
}

@(private)
drop_pending :: proc(v: ^Vault) {
	for &p in v.pending {
		if p.op == .Fill { v.fill_state = .Dropped }
		pending_free(v, &p, true)
	}
	clear(&v.pending)
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
	pending_free(v, &p, false)   // (frees `to`)
	switch p.op {
	case .Logins_For:
		rows_reset(v)
		v.rows_state = .Failed
		set_message(v, i18n.tr("The Vault did not answer in time."))
	case .Fill:
		v.fill_state = .Dropped
		set_message(v, i18n.tr("The fill took too long and was dropped."))
	case .Hello, .Login, .Unlock, .Lock, .Sync:
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
	p, found := take_pending(v, a.id)
	if !found { return }   // late (its deadline passed) or unknown: dropped
	defer pending_free(v, &p, true)
	switch p.op {
	case .Hello:
		if !a.ok { fail(v, a.message != "" ? a.message : i18n.tr("The Vault helper refused to start.")); return }
		if a.account == "locked" && a.email != "" && a.email != v.email {
			string_wipe(&v.email)
			v.email = strings.clone(a.email, base.process_allocator())
		}
	case .Login:
		if !a.ok {
			close_helper(v)
			string_wipe(&v.login_email)
			set_message(v, a.message != "" ? a.message : i18n.tr("The login failed."))
			set_state(v, v.email != "" ? .Locked : .Logged_Out)
			return
		}
		if a.need_two_factor {
			set_state(v, .Need_Two_Factor)
			return
		}
		string_wipe(&v.email)
		v.email, v.login_email = v.login_email, ""
		write_account(v)
		set_state(v, .Unlocked)
	case .Unlock:
		if !a.ok {
			close_helper(v)
			set_message(v, a.message != "" ? a.message : i18n.tr("The vault cannot be unlocked."))
			set_state(v, a.error == "no_account" ? .Logged_Out : .Locked)
			if a.error == "no_account" { string_wipe(&v.email) }
			return
		}
		set_state(v, .Unlocked)
		r: Request   // (once after an unlock: docs/bitwarden.md phase 1)
		request_begin(&r, next_id(v), .Sync, 0)
		send(v, &r, .Sync)
	case .Sync:
		if !a.ok { set_message(v, a.message != "" ? a.message : i18n.tr("The vault could not be synced.")); return }
		if v.rows_url != "" {   // (the rows shown may be older than the sync)
			address := strings.clone(v.rows_url, context.temp_allocator)
			rows_reset(v)
			vault_ask_rows(v, address)
		}
	case .Logins_For:
		if p.url == "" || p.url != v.rows_url { return }   // (another document was asked meanwhile, or the rows were released)
		if !a.ok {
			v.rows_state = .Failed
			set_message(v, a.message)
			changed(v)
			return
		}
		check_rows(v, a)
	case .Fill:
		v.fill_state = .Answered
		values := Fill_Values{ticket = p.ticket, username = a.username, password = a.password, has_username = a.has_username, has_password = a.has_password}
		applied := a.ok && v.hooks.fill != nil && v.hooks.fill(v.hooks.user, &values)
		v.fill_state = applied ? .Applied : .Dropped
		switch {
		case !a.ok: set_message(v, a.message)
		case !applied: set_message(v, i18n.tr("Nothing was filled: the page changed, or it has no login field."))
		case: string_wipe(&v.message)
		}
		changed(v)
	case .Lock:
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

@(private)
rows_reset :: proc(v: ^Vault) {
	rows_free(&v.rows)
	string_wipe(&v.rows_url)
	v.rows_state = .None
	v.rows_gen += 1
	// (an ask on its way is forgotten: its answer finds another url)
	for &p in v.pending {
		if p.op == .Logins_For { string_wipe(&p.url) }
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
	v:    ^Vault,
	gen:  u64,
	url:  string,         // owned
	rows: [dynamic]Row,   // owned: the helper's, then the kept ones
}

// The rows of an answer, checked with Wren's Public Suffix List on the pool (docs/bitwarden.md 3.5, rule 4).
@(private)
check_rows :: proc(v: ^Vault, a: ^Answer) {
	j := new(Check_Job, base.process_allocator())
	j^ = {v = v, gen = v.rows_gen, url = strings.clone(v.rows_url, base.process_allocator()), rows = a.rows}
	a.rows = nil   // (the job owns them now)
	v.rows_state = .Checking
	v.jobs += 1
	host.run_blocking(v.pool, check_work, check_done, j, check_discard)
}

@(private)
check_work :: proc(data: rawptr) {
	j := (^Check_Job)(data)
	site, ok := site_of(j.url)
	kept := make([dynamic]Row, 0, len(j.rows), base.process_allocator())
	for &r in j.rows {
		if ok && row_matches(site, r.uri, r.kind) { append(&kept, r) } else { row_free(&r) }
	}
	delete(j.rows)
	j.rows = kept
}

@(private)
check_done :: proc(data: rawptr) {
	j := (^Check_Job)(data)
	v := j.v
	v.jobs -= 1
	if j.gen == v.rows_gen && v.state == .Unlocked {
		rows_free(&v.rows)
		v.rows = j.rows
		j.rows = nil
		v.rows_state = .Ready
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
	string_wipe(&j.url)
	free(j, base.process_allocator())
}

@(private)
Setup_Job :: struct {
	v:              ^Vault,
	gen:            u64,
	profile_dir:    string,   // owned
	helper_setting: string,   // owned
	helper:         string,   // owned: found
	email:          string,   // owned: from the account file
}

// Off the loop: where the helper is, and which account the profile remembers.
@(private)
setup_work :: proc(data: rawptr) {
	j := (^Setup_Job)(data)
	context.allocator = base.process_allocator()
	j.helper = locate_helper(j.helper_setting)
	if j.profile_dir != "" {
		path := join_path({j.profile_dir, "vault", ACCOUNT_FILE})
		if bytes, err := os.read_entire_file(path, context.temp_allocator); err == nil {
			email, _, _ := strings.partition(string(bytes), "\n")
			j.email = strings.clone(strings.trim_space(email))
		}
	}
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
	v:     ^Vault,
	dir:   string,   // owned
	email: string,   // owned
	ok:    bool,
}

// The remembered account, for the next start (the locked icon is drawn without starting the helper).
@(private)
write_account :: proc(v: ^Vault) {
	if v.profile_dir == "" { return }
	j := new(Account_Job, base.process_allocator())
	j^ = {v = v, dir = join_path({v.profile_dir, "vault"}, base.process_allocator()), email = strings.clone(v.email, base.process_allocator())}
	v.jobs += 1
	host.run_blocking(v.pool, account_work, account_done, j, account_done)
}

@(private)
account_work :: proc(data: rawptr) {
	job := (^Account_Job)(data)
	_ = os.make_directory_all(job.dir, {.Read_User, .Write_User, .Execute_User})
	job.ok = os.write_entire_file(join_path({job.dir, ACCOUNT_FILE}), fmt.tprintf("%s\n", job.email), {.Read_User, .Write_User}) == nil
}

// (also its discard: the pool ended before it ran)
@(private)
account_done :: proc(data: rawptr) {
	job := (^Account_Job)(data)
	job.v.jobs -= 1
	account_free(job)
}

@(private)
account_free :: proc(j: ^Account_Job) {
	delete(j.dir, base.process_allocator())
	string_wipe(&j.email)
	free(j, base.process_allocator())
}
