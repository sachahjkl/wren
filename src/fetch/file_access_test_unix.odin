#+build linux, darwin, freebsd, openbsd, netbsd
package fetch

import "core:strings"
import "core:sys/posix"
import "core:testing"
import "wb:url"

@(private)
make_folder_link :: proc(link, target: string) {
	posix.symlink(strings.clone_to_cstring(target, context.temp_allocator), strings.clone_to_cstring(link, context.temp_allocator))
}

// On POSIX only "." and ".." segments and control characters are refused: '\', ':', CON and trailing dots are names.
@(test)
file_urls_on_posix :: proc(t: ^testing.T) {
	path_of :: proc(s: string) -> (string, bool) {
		u, ok := url.parse_absolute(s, context.temp_allocator)
		if !ok { return "", false }
		return file_path_from_url(u, context.temp_allocator)
	}
	for s in ([]string{"file:///site/a%2F..%2F..%2Fsecret.txt", "file:///site/a%01b", "file://server/share/f.txt"}) {
		p, ok := path_of(s)
		testing.expectf(t, !ok, "%s refused (got %q)", s, p)
	}
	allowed := []struct { url, path: string }{
		{"file:///site/a%5C..%5Csecret.txt", `/site/a\..\secret.txt`},   // one name: '\' separates nothing here
		{"file:///site/CON", "/site/CON"},
		{"file:///site/page.html:x", "/site/page.html:x"},
		{"file:///site/.hidden", "/site/.hidden"},
		{"file://localhost/etc/hosts", "/etc/hosts"},
	}
	for a in allowed {
		p, ok := path_of(a.url)
		testing.expectf(t, ok && p == a.path, "%s -> %q (%v), want %q", a.url, p, ok, a.path)
	}
}
