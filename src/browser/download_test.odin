package browser

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

// RFC 6266 / 8187.
@(test)
content_disposition :: proc(t: ^testing.T) {
	att, name := parse_content_disposition(`attachment; filename="report.pdf"`)
	testing.expect(t, att)
	testing.expect_value(t, name, "report.pdf")
	att, name = parse_content_disposition(`ATTACHMENT; filename=plain.txt`)
	testing.expect(t, att)
	testing.expect_value(t, name, "plain.txt")
	att, name = parse_content_disposition(`inline; filename="a.png"`)
	testing.expect(t, !att)
	testing.expect_value(t, name, "a.png")
	// filename* wins, whatever the order
	_, name = parse_content_disposition(`attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf; filename="resume.pdf"`)
	testing.expect_value(t, name, "résumé.pdf")
	_, name = parse_content_disposition(`attachment; filename="resume.pdf"; filename*=utf-8'en'na%C3%AFve%20file.txt`)
	testing.expect_value(t, name, "naïve file.txt")
	_, name = parse_content_disposition(`attachment; filename*=iso-8859-1''%E9t%E9.txt`)
	testing.expect_value(t, name, "été.txt")
	// escapes in quoted strings, a semicolon inside quotes
	_, name = parse_content_disposition(`attachment; filename="a \"b\"; c.txt"`)
	testing.expect_value(t, name, `a "b"; c.txt`)
	// a bad filename* falls back to filename
	_, name = parse_content_disposition(`attachment; filename*=UTF-8''%ZZ; filename="ok.txt"`)
	testing.expect_value(t, name, "ok.txt")
	att, name = parse_content_disposition("")
	testing.expect(t, !att)
	testing.expect_value(t, name, "")
	att, _ = parse_content_disposition("attachment")
	testing.expect(t, att)
}

// Names Windows accepts, that never pick the folder.
@(test)
download_names :: proc(t: ^testing.T) {
	testing.expect_value(t, download_file_name("report.pdf", "", ""), "report.pdf")
	testing.expect_value(t, download_file_name("", "https://x.org/files/a%20b.zip?x=1#f", "application/zip"), "a b.zip")
	testing.expect_value(t, download_file_name("", "https://x.org/", "application/pdf"), "download.pdf")
	testing.expect_value(t, download_file_name("", "https://x.org/get", "application/octet-stream"), "get")
	testing.expect_value(t, download_file_name(`..\..\Windows\evil.exe`, "", ""), "evil.exe")
	testing.expect_value(t, download_file_name("/etc/passwd", "", ""), "passwd")
	testing.expect_value(t, download_file_name(`a<b>:c"d|e?f*.txt`, "", ""), "a_b__c_d_e_f_.txt")
	testing.expect_value(t, download_file_name("name. . ", "", ""), "name")
	testing.expect_value(t, download_file_name("CON.txt", "", ""), "_CON.txt")
	testing.expect_value(t, download_file_name("com1", "", ""), "_com1")
	testing.expect_value(t, download_file_name("tab\tand\x01ctl.txt", "", ""), "tabandctl.txt")
	testing.expect_value(t, download_file_name("innocent\u202Etxt.exe", "", ""), "innocenttxt.exe")   // no right-to-left override
	testing.expect_value(t, download_file_name("...", "", ""), "download")
	long := strings.repeat("é", 150, context.temp_allocator)   // 300 bytes
	n := download_file_name(strings.concatenate({long, ".txt"}, context.temp_allocator), "", "", max_bytes = 100)
	testing.expect(t, len(n) <= 100 && strings.has_suffix(n, ".txt"))
	testing.expect(t, strings.has_prefix(n, "é"))
	testing.expect_value(t, strings.rune_count(n[:len(n) - 4]) * 2, len(n) - 4)   // whole characters only
	testing.expect_value(t, download_file_name("report", "", "application/pdf"), "report.pdf")
}

@(test)
download_unique_names :: proc(t: ^testing.T) {
	taken :: proc(name: string, user: rawptr) -> bool {
		for n in (^[]string)(user)^ { if n == name { return true } }
		return false
	}
	existing := []string{"a.txt", "a (1).txt", "b"}
	testing.expect_value(t, unique_file_name("a.txt", taken, &existing), "a (2).txt")
	testing.expect_value(t, unique_file_name("b", taken, &existing), "b (1)")
	testing.expect_value(t, unique_file_name("c.txt", taken, &existing), "c.txt")
}

// What a navigation's answer becomes.
@(test)
document_actions :: proc(t: ^testing.T) {
	testing.expect_value(t, doc_action("text/html", "", "https://a/"), Doc_Action.Render)
	testing.expect_value(t, doc_action("", "", "https://a/"), Doc_Action.Render)
	testing.expect_value(t, doc_action("text/html", "attachment; filename=x.html", "https://a/"), Doc_Action.Download)
	testing.expect_value(t, doc_action("text/plain", "inline", "https://a/x.txt"), Doc_Action.Text)
	testing.expect_value(t, doc_action("application/json", "", "https://a/x"), Doc_Action.Text)
	testing.expect_value(t, doc_action("image/svg+xml", "", "https://a/x.svg"), Doc_Action.Image)
	testing.expect_value(t, doc_action("image/png", "", "https://a/x.png"), Doc_Action.Image)
	testing.expect_value(t, doc_action("image/x-unknown", "", "https://a/x"), Doc_Action.Download)
	testing.expect_value(t, doc_action("application/wasm", "", "https://a/m"), Doc_Action.Wasm)
	testing.expect_value(t, doc_action("application/octet-stream", "", "https://a/m.WASM?v=1"), Doc_Action.Wasm)
	testing.expect_value(t, doc_action("application/octet-stream", "", "https://a/setup.exe"), Doc_Action.Download)
	testing.expect_value(t, doc_action("application/pdf", "", "https://a/doc.pdf"), Doc_Action.Download)
	testing.expect_value(t, doc_action("application/zip", "", "https://a/a.zip"), Doc_Action.Download)
}

// What a saved file's name must be whatever the server sent: at most `max_bytes`, valid UTF-8, not empty, no folder part, no
// character or ending Windows refuses, and not a device (CON, NUL.txt, com1.tar.gz...).
@(private = "file")
file_name_ok :: proc(t: ^testing.T, n: string, max_bytes: int, label: string) {
	testing.expectf(t, n != "", "%s: empty name", label)
	testing.expectf(t, len(n) <= max(max_bytes, 1), "%s: %d bytes, limit %d", label, len(n), max_bytes)
	testing.expectf(t, utf8.valid_string(n), "%s: not UTF-8: %q", label, n)
	testing.expectf(t, !strings.contains_any(n, "<>:\"|?*/\\"), "%s: reserved character in %q", label, n)
	for r in n { testing.expectf(t, r >= 32 && r != 0x7f, "%s: control character in %q", label, n) }
	testing.expectf(t, n[len(n) - 1] != '.' && n[len(n) - 1] != ' ', "%s: ends with a dot or a space: %q", label, n)
	base := n
	if i := strings.index_byte(n, '.'); i >= 0 { base = n[:i] }
	base = strings.to_upper(strings.trim_right(base, " "), context.temp_allocator)
	testing.expectf(t, !(base == "CON" || base == "PRN" || base == "AUX" || base == "NUL" || base == "CONIN$" || base == "CONOUT$"), "%s: device name %q", label, n)
	if len(base) == 4 && (base[:3] == "COM" || base[:3] == "LPT") { testing.expectf(t, !(base[3] >= '0' && base[3] <= '9'), "%s: device name %q", label, n) }
}

// An extension longer than the name may be (the whole Content-Disposition filename of a server is its to choose): used to
// index past the end of the stem and end the browser.
@(test)
download_names_long_extension :: proc(t: ^testing.T) {
	x := strings.repeat("x", 250, context.temp_allocator)
	_, header_name := parse_content_disposition(strings.concatenate({`attachment; filename="a.`, x, `"`}, context.temp_allocator))
	n := download_file_name(header_name, "https://x.org/d", "application/octet-stream")
	file_name_ok(t, n, 200, "a.x*250")
	testing.expect(t, strings.has_prefix(n, "a.x"), n)
	for max_bytes in ([]int{1, 2, 5, 12, 13, 14, 100, 200, 255}) {
		file_name_ok(t, download_file_name(strings.concatenate({"a.", x}, context.temp_allocator), "", "application/octet-stream", max_bytes), max_bytes, "a.x*250")
		file_name_ok(t, download_file_name(strings.concatenate({".", x}, context.temp_allocator), "", "", max_bytes), max_bytes, ".x*250")
		file_name_ok(t, download_file_name(strings.concatenate({x, ".", x}, context.temp_allocator), "", "", max_bytes), max_bytes, "x*250.x*250")
		file_name_ok(t, download_file_name(strings.concatenate({"é", ".", strings.repeat("é", 150, context.temp_allocator)}, context.temp_allocator), "", "", max_bytes), max_bytes, "é.é*150")
	}
	// a long extension of a typed answer still gets the type's
	n = download_file_name(strings.concatenate({"a.", x}, context.temp_allocator), "", "application/pdf")
	file_name_ok(t, n, 200, "a.x*250 pdf")
	testing.expect(t, strings.has_suffix(n, ".pdf") || strings.has_prefix(n, "a.x"), n)
}

@(test)
download_names_hostile :: proc(t: ^testing.T) {
	cases := []string{
		"", " ", "   ", ".", "..", "...", ". . .", " . ", "\x00", "\x01\x02\x03", "\x7f", "\u202e", "\u202e\u202d.txt",
		"<>", "<>:\"|?*", "????", "a:b", "a:b:c.txt", "file.txt:evil.exe", "con", "CON", "con.txt", "Con.tar.gz", "nul", "NUL.", "NUL .txt",
		"aux", "prn.log", "com1", "COM9.txt", "lpt1", "LPT9.a.b", "com0", "COM\xc2\xb9", "conin$", "CONOUT$.x", "con ", "con...", "c o n",
		"..\\..\\..\\Windows\\System32\\cmd.exe", "../../etc/passwd", "/", "\\", "a/", "a\\", "/a", "C:\\x", "\\\\server\\share\\x", "dir/..",
		"\xff", "\xff\xfe.txt", "abc\xc3", "abc\xe2\x82", "\xf0\x9f\x98", "a\xc0\xafb", "\xed\xa0\x80.txt", "\xef\xbf\xbe",
		".hidden", ".a.b.c.d", "a.", "a..", "a. ", "a .", "a.b ", "x.\x00y", "a.\u202etxt",
	}
	for c, i in cases {
		for max_bytes in ([]int{1, 3, 8, 200, 255}) {
			for mime in ([]string{"", "application/octet-stream", "application/pdf"}) {
				file_name_ok(t, download_file_name(c, "", mime, max_bytes), max_bytes, c)
				file_name_ok(t, download_file_name("", c, mime, max_bytes), max_bytes, c)   // the same bytes as the last segment of an address
				file_name_ok(t, download_file_name(c, "https://x.org/fallback%ff%00%2e%2e", mime, max_bytes), max_bytes, c)
			}
		}
		_ = i
	}
	// names of 255, 256, 300 and 1000 bytes, with and without an extension, in one-, two-, three- and four-byte characters
	for ch in ([]string{"a", "é", "€", "😀"}) {
		for count in ([]int{1, 50, 63, 64, 85, 100, 199, 200, 201, 255, 256, 300, 1000}) {
			stem := strings.repeat(ch, count, context.temp_allocator)
			file_name_ok(t, download_file_name(stem, "", ""), 200, stem)
			file_name_ok(t, download_file_name(strings.concatenate({stem, ".txt"}, context.temp_allocator), "", ""), 200, stem)
			file_name_ok(t, download_file_name(strings.concatenate({stem, ".", stem}, context.temp_allocator), "", ""), 200, stem)
		}
	}
	// the extension is kept when it fits, and only whole characters are cut
	long := strings.repeat("€", 100, context.temp_allocator)
	n := download_file_name(strings.concatenate({long, ".tar.gz"}, context.temp_allocator), "", "")
	testing.expect(t, strings.has_suffix(n, ".gz") && len(n) <= 200, n)
	testing.expect_value(t, download_file_name("Con.tar.gz", "", ""), "_Con.tar.gz")
	testing.expect_value(t, download_file_name("NUL .txt", "", ""), "_NUL .txt")
	testing.expect_value(t, download_file_name("COM\xc2\xb9.txt", "", ""), "_COM\xc2\xb9.txt")
	testing.expect_value(t, download_file_name("com0", "", ""), "_com0")
	testing.expect_value(t, download_file_name("\xff.txt", "", ""), "\uFFFD.txt")
	testing.expect_value(t, download_file_name("a.\u202etxt", "", ""), "a.txt")
}

// Pseudo-random names built from the pieces that went wrong before: the same invariants, 30000 times.
@(test)
download_names_random :: proc(t: ^testing.T) {
	pieces := []string{
		"a", "b", "Z", "é", "€", "😀", ".", "..", " ", "_", "-", "x", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "con", "NUL", "com1", "LPT3", "aux", "prn",
		".txt", ".tar", ".gz", ".exe", ".pdf", "<", ">", ":", "\"", "|", "?", "*", "/", "\\", "\x00", "\x1f", "\u202e", "\xff", "\xc3", "\xe2\x82", "%", "%2e", "%00",
	}
	seed := u64(0x9E3779B97F4A7C15)
	next :: proc(seed: ^u64) -> u64 {
		seed^ = seed^ * 6364136223846793005 + 1442695040888963407
		return seed^ >> 33
	}
	maxes := []int{1, 2, 4, 9, 14, 40, 200, 255}
	mimes := []string{"", "application/octet-stream", "application/pdf", "text/html"}
	for _ in 0 ..< 30000 {
		sb := strings.builder_make(context.temp_allocator)
		for _ in 0 ..< int(next(&seed) % 40) { strings.write_string(&sb, pieces[next(&seed) % u64(len(pieces))]) }
		name := strings.to_string(sb)
		max_bytes := maxes[next(&seed) % u64(len(maxes))]
		mime := mimes[next(&seed) % u64(len(mimes))]
		file_name_ok(t, download_file_name(name, "", mime, max_bytes), max_bytes, name)
		file_name_ok(t, download_file_name("", name, mime, max_bytes), max_bytes, name)
		free_all(context.temp_allocator)
	}
}