package config

import "core:testing"

@(private = "file")
SNAP_DEFS := [?]Def{
	{name = "net.max_conns", description = "Connections per host", kind = .Int, default = {i = 6}, bounded = true, min = 1, max = 64},
	{name = "net.enabled", description = "Network on", kind = .Bool, default = {b = true}},
	{name = "net.agent", description = "UA", kind = .String, default = {s = "wb/1"}},
	{name = "ui.scale", description = "Scale", kind = .Float, default = {f = 1.0}, bounded = true, min = 0.5, max = 3},
}

@(private = "file")
Heard :: struct { calls: int }

@(private = "file")
heard :: proc(user: rawptr, name: string, p: ^Prefs) { (^Heard)(user).calls += 1 }

@(test)
restoring_a_snapshot_puts_every_layer_back :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, SNAP_DEFS[:])
	// a state with a user value, a command-line value over a user value, and a default
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "12", .User), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "net.agent", "mine", .User), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "net.agent", "cmd", .Command_Line), Set_Error.None)
	snap := snapshot(&p)
	defer snapshot_destroy(snap)

	// then the run changes things: over the user's value, over the command line's, a default turned off, a float
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "30", .User), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "net.agent", "other", .Command_Line), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "net.enabled", "false", .User), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "ui.scale", "1.75", .User), Set_Error.None)
	h := Heard{}
	watch(&p, "net.", heard, &h)

	testing.expect_value(t, restore(&p, snap), 4)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 12)
	testing.expect_value(t, string_of(&p, "net.agent"), "cmd")
	testing.expect_value(t, bool_of(&p, "net.enabled"), true)
	testing.expect_value(t, float_of(&p, "ui.scale"), 1.0)
	testing.expect_value(t, entry(&p, ref_of(&p, "net.enabled")).source, Source.Default)
	testing.expect_value(t, entry(&p, ref_of(&p, "net.agent")).source, Source.Command_Line)
	testing.expect_value(t, entry(&p, ref_of(&p, "net.agent")).user_text, "mine")   // the user layer under the command line is still there
	testing.expect_value(t, h.calls, 3)   // the observers of "net." heard of the three that changed
	testing.expect_value(t, restore(&p, snap), 0)   // nothing left to put back
}

@(test)
a_command_line_value_changed_by_the_run_comes_back_over_a_user_one :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, SNAP_DEFS[:])
	snap := snapshot(&p)   // (everything is a default)
	defer snapshot_destroy(snap)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "9", .User), Set_Error.None)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "8", .Command_Line), Set_Error.None)
	testing.expect_value(t, restore(&p, snap), 1)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 6)
	testing.expect(t, !entry(&p, ref_of(&p, "net.max_conns")).has_user)
}

@(test)
policy_values_are_not_restored_over :: proc(t: ^testing.T) {
	p := prefs_make()
	defer prefs_destroy(&p)
	register(&p, SNAP_DEFS[:])
	snap := snapshot(&p)
	defer snapshot_destroy(snap)
	testing.expect_value(t, set_from_string(&p, "net.max_conns", "3", .Policy), Set_Error.None)
	testing.expect_value(t, restore(&p, snap), 0)
	testing.expect_value(t, int_of(&p, "net.max_conns"), 3)
}
