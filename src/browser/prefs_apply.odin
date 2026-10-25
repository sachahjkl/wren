package browser

// Which subsystems a preference write configures again (apply_prefs, main.odin). Every write used to hand the network
// client, the HTTP cache and the downloads their settings again (the client re-examines its queues, the cache its
// limits): a drag of the tab sidebar's edge, which writes browser.tabs.sidebar_width at every step, did all that work
// for nothing. Each subsystem now only takes the writes of its own preferences; "" (an unknown or bulk change: a reset,
// the appearance of the system) still configures everything.

import "core:strings"
import "wb:net"

Pref_Group :: enum u8 { Net, Http_Cache, Downloads, Touch }
Pref_Groups :: bit_set[Pref_Group; u8]

PREF_GROUPS_ALL :: Pref_Groups{.Net, .Http_Cache, .Downloads, .Touch}

// How many times each subsystem was configured again since the start (the measure of this file's effect; tests).
prefs_apply_counts: [Pref_Group]int

// The subsystems a write of preference `name` concerns. Pure.
pref_groups_of :: proc(name: string) -> Pref_Groups {
	switch {
	case name == "": return PREF_GROUPS_ALL
	case strings.has_prefix(name, "network.cache."): return {.Http_Cache}
	case strings.has_prefix(name, "network."): return {.Net}
	case strings.has_prefix(name, "browser.download."): return {.Downloads}
	case name == "browser.touch.expose": return {.Touch}
	}
	return {}
}

// The network client's settings again (limits and timeouts at once; its queues are looked at again).
net_apply :: proc(app: ^App) {
	ns := net.settings_from_prefs(&app.prefs)
	net.client_apply(&app.client, ns)
	net.settings_destroy(&ns)
	prefs_apply_counts[.Net] += 1
}
