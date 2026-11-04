package browser

import "core:strings"
import "core:testing"
import "wb:images"

// Until the first painting is there, the page says that one is on its way (a spinner and a sentence), not only a bare gradient.
@(test)
the_art_page_says_that_a_painting_is_on_its_way :: proc(t: ^testing.T) {
	app := test_app(t)
	app.art.fails = 0
	app.art.cfg.show_caption = true
	html := art_page_html(app, nil, true)
	testing.expect(t, strings.contains(html, `<div class="art-loading">`), "a loading indicator")
	testing.expect(t, strings.contains(html, "Fetching a painting"), "and its sentence")
	// after a failure it says it tries again instead (the spinner is not shown for good)
	app.art.fails = 1
	html2 := art_page_html(app, nil, true)
	testing.expect(t, !strings.contains(html2, `<div class="art-loading">`), "no spinner after a failure")
	testing.expect(t, strings.contains(html2, "Trying again"), "it says it tries again")
}

// The page names the painting's file: the document stays small however large the painting is, and the image reaches the decoder without
// going through the text of the page.
@(test)
the_art_page_loads_the_painting_from_its_file :: proc(t: ^testing.T) {
	app := test_app(t)
	it := Art_Item{file = "C:/profile/it's/painting.jpg", width = 2000, height = 1000}
	html := art_page_html(app, &it, true)
	testing.expect(t, !strings.contains(html, "data:"), "no data: URL")
	testing.expect(t, strings.contains(html, "url('file:///C:/profile/it%27s/painting.jpg')"), "the file's address, its quote encoded")
	testing.expect_value(t, strings.count(html, "file:///"), 1)   // where it fills the window
	testing.expect_value(t, strings.count(art_page_html(app, &it, false), "file:///"), 2)   // with the blurred fill behind it
}

// The source's bytes stay when there is nothing to gain: no reduction and a small file, or a JPEG that would be no smaller. Otherwise the
// painting is kept as the JPEG of the reduced pixels.
@(test)
a_painting_is_encoded_again_only_for_a_gain :: proc(t: ^testing.T) {
	W :: 800
	H :: 600
	SHORT :: 300
	QUALITY :: f32(0.8)
	rgba := make([]u8, W * H * 4, context.temp_allocator)
	for i in 0 ..< W * H { rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3] = u8(i * 7), u8(i / W), u8(i * 13), 255 }
	source, ok := images.encode_rgba(rgba, W, H, .Jpeg, 1, false, context.temp_allocator)
	testing.expect(t, ok, "the source is encoded")

	small, _, err := images.decode_now(source, art_decode_options(images.LIMITS_DEFAULT, SHORT))
	testing.expect_value(t, err, images.Error.None)
	defer images.image_destroy(small)
	testing.expect_value(t, small.height, SHORT)   // (the shorter side)
	testing.expect(t, small.reduced, "decoded at the smaller size")
	out := art_reencoded(source, small, QUALITY, context.temp_allocator)
	testing.expect(t, out != nil && len(out) < len(source), "a reduced painting is encoded, smaller")
	testing.expect(t, art_reencoded(source[:1], small, QUALITY, context.temp_allocator) == nil, "a JPEG no smaller than the source is not kept")

	natural, _, nerr := images.decode_now(source, art_decode_options(images.LIMITS_DEFAULT, H))
	testing.expect_value(t, nerr, images.Error.None)
	defer images.image_destroy(natural)
	testing.expect(t, !natural.reduced, "no reduction asked of a painting of that size")
	testing.expect(t, art_reencoded(source[:ART_KEEP_AS_IS_BYTES / 2], natural, QUALITY, context.temp_allocator) == nil, "a small one is kept as it came")
}
