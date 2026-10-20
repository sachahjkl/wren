package browser

import "core:strings"
import "core:testing"

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
