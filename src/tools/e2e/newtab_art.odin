package e2e_scenarios

// The artistic new tab with no network: a painting's way from the answer of a source to the disk (the image comes from a file: address,
// fetched like any), and what an earlier session left, taken back by the scan and shown from its file at the first new tab.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:browser"
import "wb:e2e"
import "wb:fetch"
import "wb:images"

@(private = "file") ART_SIZE :: [2]int{1280, 800}
@(private = "file") FOLDER :: "/tmp/newtab-art"
@(private = "file") PAINTED :: [3]u8{200, 40, 30}         // the colour of the painting kept
@(private = "file") OTHER :: [3]u8{0, 0, 0}               // of the others
@(private = "file") JPEG_SLACK :: 12                      // what a JPEG may move a flat colour by
@(private = "file") SOURCE_W :: 1000                      // the answer of a source, larger than what is kept
@(private = "file") SOURCE_H :: 800
@(private = "file") KEPT_SHORT_SIDE :: 320
@(private = "file") KEPT_W :: 400                         // SOURCE_W x SOURCE_H with its shorter side at KEPT_SHORT_SIDE
@(private = "file") SOURCE_QUALITY :: f32(1)

// What art_encode_work leaves: a flat painting and its JSON file.
@(private = "file")
leave_painting :: proc(dir, stem: string, format: int, fetched: i64, colour: [3]u8) {
	rgba := make([]u8, SOURCE_W * SOURCE_H * 4, context.temp_allocator)
	for i in 0 ..< SOURCE_W * SOURCE_H { rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3] = colour.r, colour.g, colour.b, 255 }
	data, _ := images.encode_rgba(rgba, SOURCE_W, SOURCE_H, .Jpeg, SOURCE_QUALITY, false, context.temp_allocator)
	file := strings.concatenate({stem, ".jpg"}, context.temp_allocator)
	_ = os.write_entire_file(strings.concatenate({dir, "/", file}, context.temp_allocator), data)
	it := browser.Art_Item{format = format, id = stem, file = file, source = "test", title = stem, width = SOURCE_W, height = SOURCE_H, bytes = i64(len(data)), fetched = fetched}
	meta, _ := json.marshal(it, {}, context.temp_allocator)
	_ = os.write_entire_file(strings.concatenate({dir, "/", stem, ".json"}, context.temp_allocator), meta)
}

@(private = "file")
in_folder :: proc(dir, name: string) -> bool { return os.exists(strings.concatenate({dir, "/", name}, context.temp_allocator)) }

// A painting of a source goes through the decoder and a worker: it is kept at its shorter side's size, as a smaller JPEG with its JSON file beside it.
@(test)
art_a_painting_is_kept_reduced :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = ART_SIZE, prefs = {fmt.tprintf("browser.newtab.art.short_side_px=%d", KEPT_SHORT_SIDE), fmt.tprintf("browser.newtab.art.min_width_px=%d", KEPT_SHORT_SIDE)}})
	// a picture with detail: a flat one would come out no smaller
	rgba := make([]u8, SOURCE_W * SOURCE_H * 4, context.temp_allocator)
	for i in 0 ..< SOURCE_W * SOURCE_H { rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3] = u8(i * 7), u8(i / SOURCE_W), u8(i * 13), 255 }
	source, ok := images.encode_rgba(rgba, SOURCE_W, SOURCE_H, .Jpeg, SOURCE_QUALITY, false, context.temp_allocator)
	testing.expect(t, ok, "the source is encoded")
	path := strings.concatenate({e2e.profile_dir(s), "/source.jpg"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, source) == nil, "the source is written")
	address := fetch.file_url_from_path(path, allocator = context.temp_allocator)
	{
		context = s.ctx
		browser.art_download({id = strings.clone("test:1"), image_url = strings.clone(address), source = strings.clone("test"), title = strings.clone("t")})
	}
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return len(s.app.art.ready) == 1 }, "the painting is kept")
	it := s.app.art.ready[0]
	testing.expect_value(t, it.height, KEPT_SHORT_SIDE)
	testing.expect_value(t, it.width, KEPT_W)
	testing.expectf(t, it.bytes < i64(len(source)), "%d bytes kept of %d", it.bytes, len(source))
	testing.expect(t, strings.has_suffix(it.file, ".jpg") && os.exists(it.file), "the file is there")
	testing.expect(t, in_folder(strings.concatenate({e2e.profile_dir(s), FOLDER}, context.temp_allocator), "test_1.json"), "and its JSON file")
}

// What an earlier session left: the newest painting comes back and the first new tab shows it from its file; a shown one leaves the disk; the
// rest of the folder goes (one too many for the window, the print-sized files of the old format, a stray).
@(test)
art_the_first_new_tab_shows_what_a_session_left :: proc(t: ^testing.T) {
	profile := e2e.temp_profile(t)
	dir := strings.concatenate({profile, FOLDER}, context.temp_allocator)
	_ = os.make_directory_all(dir)
	leave_painting(dir, "newest", browser.ART_CACHE_FORMAT, 2, PAINTED)
	leave_painting(dir, "older", browser.ART_CACHE_FORMAT, 1, OTHER)
	leave_painting(dir, "old_format", browser.ART_CACHE_FORMAT - 1, 3, OTHER)
	_ = os.write_entire_file(strings.concatenate({dir, "/stray.jpg"}, context.temp_allocator), []byte{1})
	s := e2e.start(t, {pixels = true, size = ART_SIZE, profile = profile, prefs = {"browser.newtab.art.enabled=true", "browser.newtab.art.window=1"}})
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return s.app.art.scan == .Done }, "the scan")
	testing.expect_value(t, len(s.app.art.ready), 1)
	testing.expect(t, in_folder(dir, "newest.jpg") && in_folder(dir, "newest.json"), "the newest stays")
	for gone in ([]string{"older.jpg", "older.json", "old_format.jpg", "old_format.json", "stray.jpg"}) { testing.expectf(t, !in_folder(dir, gone), "%s goes", gone) }
	s.app.loader.hold = true   // (the window refills once this one is shown: no request)
	e2e.navigate_begin(s, "about:home")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool {
		img := e2e.capture(s)
		c := (img.height / 2 * img.width + img.width / 2) * 4
		for want, i in PAINTED { if abs(int(img.rgba[c + i]) - int(want)) > JPEG_SLACK { return false } }
		return true
	}, "the painting in the middle of the window")
	e2e.restart(s, {size = ART_SIZE, profile = profile})   // (the option off in this one: it looks at nothing)
	testing.expect(t, !in_folder(dir, "newest.jpg") && !in_folder(dir, "newest.json"), "seen, it left the disk")
}
