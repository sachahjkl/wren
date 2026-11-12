package browser

// The pure parts of the Vault's fill everywhere (vault_fill.odin): the shortcut's text, the rule of frames, where the
// dropdown goes for a transformed or scrolled field, the clipboard's clearing, the palette's keys.

import "core:math"
import "core:testing"
import "toolkit:draw"
import "wb:url"

@(test)
vault_shortcut_texts :: proc(t: ^testing.T) {
	s, ok := vault_shortcut_parse("Ctrl+Shift+L")
	testing.expect(t, ok)
	testing.expect_value(t, s, VAULT_FILL_DEFAULT)
	testing.expect_value(t, shortcut_text(s), "Ctrl+Shift+L")
	a, a_ok := vault_shortcut_parse(" alt + 7 ")
	testing.expect(t, a_ok)
	testing.expect_value(t, shortcut_text(a), "Alt+7")
	f, f_ok := vault_shortcut_parse("F9")
	testing.expect(t, f_ok)
	testing.expect_value(t, shortcut_text(f), "F9")
	for bad in ([]string{"", "L", "Shift+L", "Ctrl+Hyper+L", "Ctrl+", "Ctrl+LL", "F13", "Ctrl+F0"}) {
		_, b_ok := vault_shortcut_parse(bad)
		testing.expect(t, !b_ok, bad)
	}
}

// The default shortcut is the registry's (commands_build); the preference moves it and an invalid text removes it.
@(test)
vault_fill_command_follows_its_preference :: proc(t: ^testing.T) {
	app := test_app(t)
	c := command(app, "vault.fill")
	testing.expect(t, c != nil)
	testing.expect_value(t, command_shortcut_text(c), "Ctrl+Shift+L")
	app.vault.v.settings.shortcut = "Alt+K"
	vault_shortcut_apply(app)
	testing.expect_value(t, command_shortcut_text(c), "Alt+K")
	app.vault.v.settings.shortcut = "K"
	vault_shortcut_apply(app)
	testing.expect_value(t, len(c.keys), 0)
	app.vault.v.settings.shortcut = "Ctrl+Shift+L"   // (the registry may outlive this test: as it was)
	vault_shortcut_apply(app)
	app.vault.v.settings.shortcut = ""
}

@(test)
vault_frame_rules :: proc(t: ^testing.T) {
	top := url.Origin{scheme = "https", host = "shop.example", port = 443}
	same := url.Origin{scheme = "https", host = "shop.example", port = 443}
	other := url.Origin{scheme = "https", host = "pay.example", port = 443}
	port := url.Origin{scheme = "https", host = "shop.example", port = 8443}
	opaque := url.Origin{opaque = true, nonce = 7}
	testing.expect_value(t, frame_fill_rule(top, top, false), Frame_Fill.Fill)
	testing.expect_value(t, frame_fill_rule(top, same, true), Frame_Fill.Fill)
	testing.expect_value(t, frame_fill_rule(top, other, true), Frame_Fill.Confirm)
	testing.expect_value(t, frame_fill_rule(top, port, true), Frame_Fill.Confirm)   // (another port: another origin)
	testing.expect_value(t, frame_fill_rule(top, opaque, true), Frame_Fill.Never)
	testing.expect_value(t, frame_fill_rule(opaque, opaque, false), Frame_Fill.Never)
}

// The field's painted bounds are where it shows: under a rotation and a scale, then a scroll (a translation), the list
// still starts under the bounds and stays in the page area; with no room under it, it goes above.
@(test)
vault_dropdown_geometry :: proc(t: ^testing.T) {
	area := draw.Rect{{0, 100}, {800, 700}}
	content := draw.Rect{{0, 0}, {200, 30}}
	xf := draw.affine_mul(draw.affine_translate({300, 250}), draw.affine_mul(draw.affine_rotate(math.PI / 12), draw.affine_scale({1.5, 1.5})))
	field := draw.affine_bounds(xf, content)
	r := vault_dropdown_place(field, area, 240, 120)
	testing.expect_value(t, r.min.y, field.max.y)
	testing.expect_value(t, r.min.x, field.min.x)
	testing.expect_value(t, r.max.x - r.min.x, f32(240))
	// scrolled down the page: the field near the bottom, the list above it
	scrolled := draw.affine_mul(draw.affine_translate({0, 380}), xf)
	low := draw.affine_bounds(scrolled, content)
	up := vault_dropdown_place(low, area, 240, 120)
	testing.expect_value(t, up.max.y, low.min.y)
	// near the right edge: kept inside
	right := vault_dropdown_place({{780, 200}, {800, 230}}, area, 240, 120)
	testing.expect_value(t, right.max.x, area.max.x)
}

@(test)
vault_clipboard_is_cleared_only_when_it_still_holds_the_copy :: proc(t: ^testing.T) {
	h := vault_hash("s3cret")
	testing.expect(t, vault_clip_still_ours("s3cret", h, 6))
	testing.expect(t, !vault_clip_still_ours("something else", h, 6))
	testing.expect(t, !vault_clip_still_ours("s3creT", h, 6))
	testing.expect(t, !vault_clip_still_ours("", 0, 0))   // (nothing copied: nothing cleared)
}

@(test)
vault_palette_keys :: proc(t: ^testing.T) {
	act, item, ok := vault_palette_key("pass:4f1c-9")
	testing.expect(t, ok)
	testing.expect_value(t, act, "pass")
	testing.expect_value(t, item, "4f1c-9")
	for bad in ([]string{"", "fill:", ":x", "dump:x", "fill"}) {
		_, _, b_ok := vault_palette_key(bad)
		testing.expect(t, !b_ok, bad)
	}
}
