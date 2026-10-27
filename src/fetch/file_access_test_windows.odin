package fetch

import "core:os"
import "core:testing"
import "wb:url"

// A junction: it needs no privilege (a symbolic link does).
@(private)
make_folder_link :: proc(link, target: string) {
	_, _, _, _ = os.process_exec({command = {"cmd", "/c", "mklink", "/J", link, target}}, context.temp_allocator)
}

@(private = "file")
path_of :: proc(s: string) -> (string, bool) {
	u, ok := url.parse_absolute(s, context.temp_allocator)
	if !ok { return "", false }
	return file_path_from_url(u, context.temp_allocator)
}

// What Windows would open as another file than the URL names is refused before any access check.
@(test)
file_urls_that_windows_would_rewrite :: proc(t: ^testing.T) {
	refused := []string{
		"file:///C:/site/a%5C..%5C..%5Csecret.txt",   // encoded separators around ".."
		"file:///C:/site/a%2F..%2F..%2Fsecret.txt",
		"file:///C:/site/%2e%2e%5Csecret.txt",
		"file:///C:/site/page.html:hidden",            // an alternate data stream
		"file:///C:/site/CON",
		"file:///C:/site/nul.txt",
		"file:///C:/site/com1.log",
		"file:///C:/site/LPT9",
		"file:///C:/site/aux%20.html",
		"file:///C:/site/CONOUT$",
		"file:///C:/site/page.html.",                  // trailing dot: Windows opens page.html
		"file:///C:/site/page.html%20",
		"file:////%3F/C:/x",                           // \\?\C:\x, a device path
		"file:///C:/site/a%01b",
	}
	for s in refused {
		p, ok := path_of(s)
		testing.expectf(t, !ok, "%s refused (got %q)", s, p)
	}
	allowed := []struct { url, path: string }{
		{"file:///C:/site/conx.txt/console.html", `C:\site\conx.txt\console.html`},
		{"file:///C:/site/COM10", `C:\site\COM10`},
		{"file:///C:/site/.hidden", `C:\site\.hidden`},
		{"file:///C:/site/a..b.txt", `C:\site\a..b.txt`},
		{"file://server/share/f.txt", `\\server\share\f.txt`},
	}
	for a in allowed {
		p, ok := path_of(a.url)
		testing.expectf(t, ok && p == a.path, "%s -> %q (%v), want %q", a.url, p, ok, a.path)
	}
}
