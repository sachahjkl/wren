package browser

import "core:testing"
import "toolkit:platform"
import "wb:remote"

@(test)
key_combos_parse :: proc(t: ^testing.T) {
	k, m, ok := parse_combo("Ctrl+Shift+T")
	testing.expect(t, ok && k == .T && m == {.Ctrl, .Shift})
	k, m, ok = parse_combo("Enter")
	testing.expect(t, ok && k == .Return && m == {})
	k, m, ok = parse_combo("F5")
	testing.expect(t, ok && k == .F5)
	k, m, ok = parse_combo("ArrowLeft")
	testing.expect(t, ok && k == .Left)
	k, m, ok = parse_combo("Ctrl++")   // the plus key
	testing.expect(t, ok && k == .Equal && m == {.Ctrl})
	k, m, ok = parse_combo("a")
	testing.expect(t, ok && k == .A)
	_, _, ok = parse_combo("Hyper+X")
	testing.expect(t, !ok)
	_, _, ok = parse_combo("Nonsense")
	testing.expect(t, !ok)
}

@(test)
keys_type_their_character_without_ctrl_or_alt :: proc(t: ^testing.T) {
	testing.expect_value(t, key_text(.A, {}), 'a')
	testing.expect_value(t, key_text(.A, {.Shift}), 'A')
	testing.expect_value(t, key_text(.A, {.Ctrl}), rune(0))
	testing.expect_value(t, key_text(.N1, {.Shift}), '!')
	testing.expect_value(t, key_text(.Space, {}), ' ')
	testing.expect_value(t, key_text(.Return, {}), rune(0))
}

@(test)
scaling_a_picture_averages_what_a_pixel_covers :: proc(t: ^testing.T) {
	src := []u8{
		0, 0, 0, 255,   100, 0, 0, 255,
		0, 100, 0, 255, 100, 100, 0, 255,
	}
	out, w, h := scale_rgba(src, 2, 2, 0.5)
	defer delete(out)
	testing.expect_value(t, w, 1)
	testing.expect_value(t, h, 1)
	testing.expect_value(t, out[0], 50)
	testing.expect_value(t, out[1], 50)
	up, uw, uh := scale_rgba(src, 2, 2, 2)
	defer delete(up)
	testing.expect_value(t, uw, 4)
	testing.expect_value(t, uh, 4)
	testing.expect_value(t, up[(3 * 4 + 3) * 4], 100)   // the far corner is the source's
}

@(test)
the_script_wrapper_carries_the_prefix_the_id_and_the_text :: proc(t: ^testing.T) {
	the_remote.prefix = "\x01p:"
	defer the_remote.prefix = ""
	src := eval_source(7, `1 + "q\""`, true)
	testing.expect(t, contains_all(src, {`"\u0001p:"`, "I=7", `(0,eval)("1 + \"q\\\"\"")`, "true&&r&&typeof r.then"}))
	// braces balance: the wrapper is one expression
	depth := 0
	for c in src { if c == '{' { depth += 1 } else if c == '}' { depth -= 1 } }
	testing.expect_value(t, depth, 0)
	_ = platform.Key.A
	_ = remote.PROTOCOL_VERSION
}

@(private = "file")
contains_all :: proc(s: string, parts: []string) -> bool {
	for p in parts {
		found := false
		for i in 0 ..= len(s) - len(p) { if s[i:i + len(p)] == p { found = true; break } }
		if !found { return false }
	}
	return true
}
