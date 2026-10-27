package page

import "core:testing"

// Navigation API keys and ids: a key per entry (its place), an id per entry made; replacing keeps the key, makes a new
// id and drops the Navigation API state; the state of other entries stays.
@(test)
navigation_keys_and_ids :: proc(t: ^testing.T) {
	sh: Session_History
	defer session_destroy(&sh)
	a := session_push(&sh, "https://a/1", 1)
	session_set_nav_state(&sh, "s1", true)
	b := session_push(&sh, "https://a/2", 1)
	testing.expect(t, a.id != b.id && a.nav_id != b.nav_id)
	testing.expect_value(t, b.has_nav_state, false)
	key, id := b.id, b.nav_id
	session_set_nav_state(&sh, "s2", true)
	session_replace(&sh, "https://a/3")
	cur := session_current(&sh)
	testing.expect_value(t, cur.id, key)
	testing.expect(t, cur.nav_id != id)
	testing.expect_value(t, cur.has_nav_state, false)
	testing.expect_value(t, a.nav_state, "s1")
	// session restore gives every entry an id of its own
	saved := []Saved_Entry{{id = 5, url = "https://a/x"}, {id = 6, parent = 5, url = "https://a/y"}}
	session_load(&sh, saved, 6, 50, 100)
	testing.expect_value(t, len(sh.entries), 2)
	testing.expect(t, sh.entries[0].nav_id != 0 && sh.entries[0].nav_id != sh.entries[1].nav_id)
}
