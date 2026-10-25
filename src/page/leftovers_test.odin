package page

import "core:testing"
import "wb:forms"
import "wb:media"

@(test)
video_quality_from_the_player :: proc(t: ^testing.T) {
	q := video_quality_numbers(1234, {}, false)
	testing.expect_value(t, q, [5]f64{1234, 0, 0, 0, 0})
	s := media.Player_Stats{decoded = 100, dropped = 7, presented = 90, delay_ns = 250_000_000}
	q = video_quality_numbers(50, s, true)
	testing.expect_value(t, q[1], 7)
	testing.expect_value(t, q[2], 100)
	testing.expect_value(t, q[3], 0)
	testing.expect_value(t, q[4], 0.25)
	// a decoder that counts less than what was shown and dropped: the total still covers them
	q = video_quality_numbers(50, media.Player_Stats{decoded = 3, dropped = 2, presented = 4}, true)
	testing.expect_value(t, q[2], 6)
}

@(test)
entries_paths_stay_inside_the_drop :: proc(t: ^testing.T) {
	r, ok := fs_resolve("", "sub/b.txt")
	testing.expect(t, ok && r == "sub/b.txt")
	r, ok = fs_resolve("sub", "./c/../d")
	testing.expect(t, !ok, "'..' is refused")
	r, ok = fs_resolve("sub", "c//d/")
	testing.expect(t, ok && r == "sub/c/d")
	r, ok = fs_resolve("sub", "/top.txt")
	testing.expect(t, ok && r == "top.txt", "from the dropped item")
	_, ok = fs_resolve("", "a:b")
	testing.expect(t, !ok, "no drive or stream names")
	e := Fs_Entry{root = "C:\\drop\\dir", rel = "sub/b.txt"}
	testing.expect_value(t, fs_entry_path(&e), "C:\\drop\\dir/sub/b.txt")
	testing.expect_value(t, root_name("C:\\drop\\dir\\"), "dir")
}

@(test)
accept_attribute :: proc(t: ^testing.T) {
	testing.expect(t, forms.accept_matches("", "a.bin", ""))
	testing.expect(t, forms.accept_matches(".TXT, image/*", "notes.txt", "text/plain"))
	testing.expect(t, forms.accept_matches(".txt,image/*", "p.png", "image/png"))
	testing.expect(t, !forms.accept_matches(".txt,image/*", "a.bin", ""))
	testing.expect(t, forms.accept_matches("application/pdf", "x", "application/PDF"))
	testing.expect(t, forms.accept_matches("text/*", "a.bin", ""), "text/* is no wildcard of the standard: no valid token, everything")
	testing.expect(t, forms.accept_matches("bogus", "a.bin", ""), "no valid token: everything")
}
