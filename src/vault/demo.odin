package vault

// The demo: the Vault as a picture needs it, from made-up items in memory (src/md/features/demo-states.md). The browser's
// demo states (src/browser/demo_states.odin) enter it so that a tool can capture the screens that an account opens.
//
// A Vault in demo starts no helper (ensure_helper), writes no file (file_job), calls no server, and answers its rows and
// its searches from `demo_items`: the person's vault, account file and keyring are neither read nor changed. It stays in
// demo until the browser ends: a demo is for an instance that a tool drives, and to leave it, the Vault would need a
// state to go back to that the demo never kept.

import "core:fmt"
import "core:strings"
import "wb:base"

// One made-up item. Its strings are constants of the caller: they outlive the Vault.
Demo_Item :: struct {
	name, username, uri: string,   // a card's username: its brand and last digits; an identity's: its name (as the helper sends them)
	kind:     Item_Kind,
	has_totp: bool,
}

// Enters the demo: the account `email`, Unlocked or Locked, with a PIN set or not. A helper that runs is closed and what
// it was asked is dropped, and a locate or an install on its way is forgotten (setup_gen): from now on the screens show
// the demo's items only. `items`: in the order of their names (a search keeps their order, as the helper sorts by name).
vault_demo :: proc(v: ^Vault, email: string, items: []Demo_Item, unlocked: bool, pin := false) {
	close_helper(v)
	rows_reset(v)
	v.setup_gen += 1
	v.demo, v.demo_items = true, items
	string_wipe(&v.email)
	v.email = strings.clone(email, base.process_allocator())
	v.pin, v.passkey = pin, false
	v.remember_refused = true   // (no keyring is asked: an unlock shows its dialog at once)
	string_wipe(&v.message)
	string_wipe(&v.login_email)
	string_wipe(&v.error)
	set_state(v, unlocked ? .Unlocked : .Locked)
	changed(v)
}

// The logins of `site` among the items (the Page and Frame sets): the rows that Wren's check keeps (row_matches).
@(private)
demo_logins :: proc(v: ^Vault, set: ^Row_Set, site: Site) {
	set.rows = make([dynamic]Row, base.process_allocator())
	for it, i in v.demo_items {
		if it.kind == .Login && row_matches(site, it.uri, .Domain) { append(&set.rows, demo_row(it, i)) }
	}
	set.total = len(set.rows)
	set.state = .Ready
}

// A search of the items (the Search and Items sets): every word of the query in the name, the user name or the address,
// case ignored, of the kinds asked. One page holds every row: the items are few.
@(private)
demo_search :: proc(v: ^Vault, set: ^Row_Set) {
	rows_free(&set.rows)
	set.rows = make([dynamic]Row, base.process_allocator())
	words := strings.fields(base.ascii_lower(set.key, context.temp_allocator), context.temp_allocator)
	items: for it, i in v.demo_items {
		if set.kinds != {} && it.kind not_in set.kinds { continue }
		for w in words {
			if !demo_holds(it.name, w) && !demo_holds(it.username, w) && !demo_holds(it.uri, w) { continue items }
		}
		append(&set.rows, demo_row(it, i))
	}
	set.total = len(set.rows)
	set.state = .Ready
}

@(private = "file")
demo_holds :: proc(text, lower_word: string) -> bool {
	return strings.contains(base.ascii_lower(text, context.temp_allocator), lower_word)
}

// A row of the item `i`, owned as the helper's rows are (row_free wipes it).
@(private = "file")
demo_row :: proc(it: Demo_Item, i: int) -> Row {
	a := base.process_allocator()
	own :: proc(s: string) -> string { return s == "" ? "" : strings.clone(s, base.process_allocator()) }
	return {id = fmt.aprintf("demo-%d", i, allocator = a), name = own(it.name), username = own(it.username), uri = own(it.uri), kind = it.kind, match = .Domain, has_totp = it.has_totp}
}
