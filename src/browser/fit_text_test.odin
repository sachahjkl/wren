package browser

import "core:strings"
import "core:testing"
import "toolkit:font"

// fit_text, as a text field with text-overflow: ellipsis shows its placeholder ("Composant, valeur, p…"): the text when
// it fits, else the longest start that fits with the ellipsis after it.
@(test)
fit_text_ends_with_an_ellipsis :: proc(t: ^testing.T) {
	SIZE :: 14
	TEXT :: "Composant, valeur, path"
	ROOM :: 0.75   // of the text's width
	fs: font.State
	font.init(&fs)
	defer font.destroy(&fs)
	id, ok := font.load_embedded(&fs, font.FALLBACK_UI_DATA)
	testing.expect(t, ok, "the fallback face loads")
	full := font.text_width(&fs, id, SIZE, TEXT)
	testing.expect_value(t, fit_text(&fs, id, SIZE, TEXT, full), TEXT)

	avail := full * ROOM
	got := fit_text(&fs, id, SIZE, TEXT, avail)
	testing.expectf(t, strings.has_suffix(got, "…") && len(got) > len("…"), "an ellipsis after a start: %q", got)
	testing.expectf(t, strings.has_prefix(TEXT, got[:len(got) - len("…")]), "the start of the text: %q", got)
	testing.expectf(t, font.text_width(&fs, id, SIZE, got) <= avail, "it fits: %q", got)
	text := TEXT
	longer := strings.concatenate({text[:len(got) - len("…") + 1], "…"}, context.temp_allocator)
	testing.expectf(t, font.text_width(&fs, id, SIZE, longer) > avail, "one more letter does not fit: %q", longer)
}
