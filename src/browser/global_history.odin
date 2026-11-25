package browser

// Browser bridge for the global browsing history store (src/profile/global_history.odin).

import "wb:profile"

HISTORY_HEADER :: profile.HISTORY_HEADER
HISTORY_HEADER_V1 :: profile.HISTORY_HEADER_V1
HISTORY_COMPACT_RATIO :: profile.HISTORY_COMPACT_RATIO
HISTORY_COMPACT_SLACK :: profile.HISTORY_COMPACT_SLACK
HISTORY_TRIM_SLACK_DIV :: profile.HISTORY_TRIM_SLACK_DIV
HISTORY_TRIM_AGE_SLACK_MS :: profile.HISTORY_TRIM_AGE_SLACK_MS

Visit :: profile.Visit
Global_History :: profile.Global_History

now_ms :: profile.now_ms
visit_free :: profile.visit_free
visits_destroy :: profile.visits_destroy
history_address :: profile.history_address
history_write_visit :: profile.history_write_visit
history_write_title :: profile.history_write_title
history_serialize :: profile.history_serialize
history_parse :: profile.history_parse
history_trim :: profile.history_trim
history_trim_target :: profile.history_trim_target
history_search :: profile.history_search
history_delete :: profile.history_delete
history_needs_compaction :: profile.history_needs_compaction

@(private = "file")
history_limits :: proc(app: ^App) -> profile.History_Limits {
	return {
		enabled        = app.hcfg.global,
		retention_days = app.hcfg.retention_days,
		max_visits     = app.hcfg.max_visits,
		max_url_bytes  = app.hcfg.max_url_bytes,
		save_delay_ms  = app.hcfg.save_delay_ms,
		record_files   = app.hcfg.record_files,
	}
}

@(private = "file")
history_ensure_host :: proc(app: ^App) {
	if app.ghist.host.writer == nil { app.ghist.host = profile_store_host(app) }
	app.ghist.save_delay_ms = app.hcfg.save_delay_ms
}

global_history_init :: proc(app: ^App) {
	profile.history_init(&app.ghist, profile_store_host(app), history_limits(app))
}

// Preferences changed: limits apply now, and what they removed leaves the disk.
global_history_apply :: proc(app: ^App) {
	history_ensure_host(app)
	profile.history_apply_limits(&app.ghist, history_limits(app))
}

global_history_changed :: proc(app: ^App) {
	history_ensure_host(app)
	profile.history_changed(&app.ghist)
}

// Hands what changed to a write (one at a time): the lines of the log, or the whole history.
global_history_save :: proc(app: ^App) {
	history_ensure_host(app)
	profile.history_save(&app.ghist)
}

// At exit, after profile_files_flush: what is not written yet is written now, on this thread.
global_history_shutdown :: proc(app: ^App) {
	if app.ghist.path != "" { history_ensure_host(app) }
	profile.history_shutdown(&app.ghist)
}

// A tab shows `address` (a new document, or a same-document change of address).
global_history_visit :: proc(app: ^App, t: ^Tab, address, title: string) {
	history_ensure_host(app)
	profile.history_record_visit(&app.ghist, &t.nav_state.last_visit, address, title, history_limits(app))
}

// The document of `t` has this title and icon: the address's last visit takes them.
global_history_title :: proc(app: ^App, t: ^Tab, title: string, icon := "") {
	history_ensure_host(app)
	profile.history_update_title(&app.ghist, t.nav_state.last_visit, title, icon)
}

// Deleted visits leave the disk too: the next write is the whole history.
global_history_remove :: proc(app: ^App, ids: []u64) {
	history_ensure_host(app)
	profile.history_remove(&app.ghist, ids)
}

global_history_remove_range :: proc(app: ^App, from_ms, to_ms: i64) {
	history_ensure_host(app)
	profile.history_remove_range(&app.ghist, from_ms, to_ms)
	closed_forget_range(app, from_ms, to_ms)   // closed_tabs.odin: what was closed then holds those pages too
}
