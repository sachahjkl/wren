package browser

import "core:sync"
import "core:testing"
import "core:thread"
import "toolkit:font"

// The measurement cache gives what the toolkit gives (ASCII, Latin-1, anything else), also from several threads at once.

@(private = "file")
MEASURE_TEXTS := [?]string{
	"", "a", "Hello, world", "AVATAR Toto WAVE", "kerning: AV To Ty Wa",
	"déjà vu à la française, ça suffit", "Ærøskøbing ÿ ½ « guillemets »", "naïve café",
	"œuvre — l’été", "日本語のテキスト", "mixed é and 漢字", "tab\tand\nnewline",
}

@(test)
measure_matches_toolkit :: proc(t: ^testing.T) {
	fs: font.State
	font.init(&fs)
	defer font.destroy(&fs)
	id, ok := font.load_embedded(&fs, font.FALLBACK_UI_DATA)
	testing.expect(t, ok)
	m: Measure
	defer measure_destroy(&m)
	for size in ([]f32{9, 13.5, 16, 31}) {
		for text in MEASURE_TEXTS {
			want := font.text_width(&fs, id, size, text)
			for _ in 0 ..< 2 {   // computed, then from the tables
				got := measure_width(&m, &fs, id, size, text)
				testing.expectf(t, got == want, "size %v %q: %v, toolkit %v", size, text, got, want)
			}
		}
	}
}

@(private = "file")
Measure_Race :: struct {
	m:      ^Measure,
	fs:     ^font.State,
	id:     font.Font_Id,
	want:   [len(MEASURE_TEXTS)][3]f32,
	bad:    int,
}

@(test)
measure_concurrent :: proc(t: ^testing.T) {
	fs: font.State
	font.init(&fs)
	defer font.destroy(&fs)
	id, _ := font.load_embedded(&fs, font.FALLBACK_UI_DATA)
	r := new(Measure_Race)
	defer free(r)
	r.fs, r.id = &fs, id
	SIZES :: [3]f32{11, 15, 22}
	sizes := SIZES
	for text, i in MEASURE_TEXTS { for s, k in sizes { r.want[i][k] = font.text_width(&fs, id, s, text) } }
	m: Measure
	defer measure_destroy(&m)
	r.m = &m
	threads: [6]^thread.Thread
	for &th in threads {
		th = thread.create_and_start_with_data(r, proc(data: rawptr) {
			r := (^Measure_Race)(data)
			sizes := SIZES
			for round in 0 ..< 200 {
				for text, i in MEASURE_TEXTS {
					k := (round + i) % 3
					if measure_width(r.m, r.fs, r.id, sizes[k], text) != r.want[i][k] { sync.atomic_add(&r.bad, 1) }
				}
			}
		})
	}
	for th in threads { thread.join(th); thread.destroy(th) }
	testing.expect_value(t, r.bad, 0)
}
