package fuzz

// The table of targets (src/md/features/fuzzing.md, "Targets"). A target is one file, target_<name>.odin: the procedure
// that hands an input to the browser's entry points and frees what they give back, its seeds and its dictionary.
// `wrentool fuzz -Target all` runs them in this order.

Target :: struct {
	name, about: string,
	run:         proc(data: []u8),
	seeds:       []string,                      // inline seeds: the forms of the format no file of the repository shows
	files:       []Seed_Files,                  // seeds from the repository
	make_seeds:  proc(out: ^[dynamic][]u8),     // seeds built at start (a zip with its checksums); nil: none
	dictionary:  []string,                      // the format's tokens, inserted or written over by the mutations
}

Seed_Files :: struct {
	dir:      string,
	suffixes: []string,
}

TARGETS := []Target{
	{name = "html", about = "html.parse_into, html.parse_fragment (Lexbor and Wren's tree builder)", run = target_html, seeds = HTML_SEEDS, files = HTML_FILES, dictionary = HTML_TOKENS},
	{name = "html_scan", about = "html.scan_feed (the preload scanner, whole and in chunks), html.decode_document", run = target_html_scan, seeds = HTML_SEEDS, files = HTML_FILES, dictionary = HTML_TOKENS},
	{name = "css", about = "css.parse_stylesheet, css.parse_declarations", run = target_css, seeds = CSS_SEEDS, files = CSS_FILES, dictionary = CSS_TOKENS},
	{name = "css_select", about = "css.parse_component_values, then css.parse_selector_list and css.parse_media_query_list", run = target_css_select, seeds = CSS_SELECT_SEEDS, dictionary = CSS_TOKENS},
	{name = "url", about = "url.parse (absolute and against a base), url.component, url.origin_of", run = target_url, seeds = URL_SEEDS, dictionary = URL_TOKENS},
	{name = "images", about = "images.sniff, images.header_size, images.looks_complete (Wren's checks before a decoder)", run = target_images, seeds = IMAGE_SEEDS, files = IMAGE_FILES, dictionary = IMAGE_TOKENS},
	{name = "image_decode", about = "images.probe_now, images.decode_now with small limits (the decoders behind Wren's checks)", run = target_image_decode, seeds = IMAGE_SEEDS, files = IMAGE_FILES, dictionary = IMAGE_TOKENS},
	{name = "webfont", about = "webfont.decode (sfnt, WOFF, WOFF2, collections), webfont.read_tables", run = target_webfont, seeds = WEBFONT_SEEDS, files = WEBFONT_FILES, dictionary = WEBFONT_TOKENS},
	{name = "mp4", about = "media.mp4_feed, whole and in chunks", run = target_mp4, seeds = MP4_SEEDS, files = MP4_FILES, dictionary = MP4_TOKENS},
	{name = "webm", about = "media.webm_feed, whole and in chunks", run = target_webm, seeds = WEBM_SEEDS, files = WEBM_FILES, dictionary = WEBM_TOKENS},
	{name = "media_text", about = "media.vtt_parse, media.vtt_cue_from_text, media.parse_type", run = target_media_text, seeds = MEDIA_TEXT_SEEDS, dictionary = MEDIA_TEXT_TOKENS},
	{name = "http", about = "http.parse_header_block, http.extract_mime, http.parse_mime", run = target_http, seeds = HTTP_SEEDS, dictionary = HTTP_TOKENS},
	{name = "cookies", about = "cookies.parse_set_cookie, cookies.parse_cookie_date", run = target_cookies, seeds = COOKIE_SEEDS, dictionary = COOKIE_TOKENS},
	{name = "csp", about = "csp.parse_header, then csp.check_request and csp.check_nonce on what it parsed", run = target_csp, seeds = CSP_SEEDS, dictionary = CSP_TOKENS},
	{name = "adblock", about = "adblock.engine_from_text, adblock.validate_list, then adblock.match on fixed requests", run = target_adblock, seeds = ADBLOCK_SEEDS, dictionary = ADBLOCK_TOKENS},
	{name = "ext_manifest", about = "extensions.manifest_parse, extensions.pattern_parse", run = target_ext_manifest, seeds = MANIFEST_SEEDS, files = MANIFEST_FILES, dictionary = MANIFEST_TOKENS},
	{name = "ext_archive", about = "extensions.archive_open, extensions.archive_read of each entry (CRX3 and zip)", run = target_ext_archive, make_seeds = archive_seeds, dictionary = ARCHIVE_TOKENS},
	{name = "wasm", about = "wasm.analyze_image, wasm.patch_image, wasm.unbound_tables", run = target_wasm, seeds = WASM_SEEDS, files = WASM_FILES, dictionary = WASM_TOKENS},
}
