package e2e_scenarios

// Downloads on both network stacks: a navigation to an attachment (handed over to the download manager), a binary named by its URL and a slow
// body, each must land whole in browser.download.directory. The transport under a download (net.set_max_body, back-pressure, a long body) is what
// differs between the stacks; the result must not.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") PART_SUFFIX :: ".wrenpart"
@(private = "file") ATTACHMENT_BYTES :: 3145728
@(private = "file") BINARY_BYTES :: 5000000
@(private = "file") SLOW_BYTES :: 1048576
@(private = "file") SLOW_CHUNK_MS :: 50

@(private = "file")
Wanted :: struct { name: string, bytes: i64 }

@(private = "file")
downloads_whole :: proc(t: ^testing.T, backend: string) {
	server := e2e.test_server(t)
	dir := e2e.temp_folder(t, "downloads")
	s := e2e.start(t, {prefs = {fmt.tprintf("network.backend=%s", backend), "browser.download.ask=false", fmt.tprintf("browser.download.directory=%s", dir)}})
	wanted := [?]Wanted{{"att.txt", ATTACHMENT_BYTES}, {"blob.bin", BINARY_BYTES}, {"slow", SLOW_BYTES}}
	addresses := [?]string{
		fmt.tprintf("/download/attachment?bytes=%d&name=att.txt", ATTACHMENT_BYTES),
		fmt.tprintf("/download/binary/blob.bin?bytes=%d", BINARY_BYTES),
		fmt.tprintf("/download/slow?bytes=%d&ms=%d", SLOW_BYTES, SLOW_CHUNK_MS),
	}
	for a, i in addresses {
		// (the next navigation would cancel a request that has not become a download yet)
		e2e.navigate_begin(s, e2e.url(server, a))
		e2e.wait_until(s, i + 1, proc(s: ^e2e.Session, n: int) -> bool { return len(e2e.downloads(s)) >= n }, "the navigation to become a download")
	}
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool {
		for d in e2e.downloads(s) { if !d.finished { return false } }
		return true
	}, "the downloads to end")
	for d in e2e.downloads(s) { testing.expectf(t, d.saved, "%s: %s has been saved: %s", backend, d.name, d.error) }

	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expect_value(t, err, nil)
	for w in wanted {
		size := i64(-1)
		for f in files { if strings.has_prefix(f.name, w.name) && !strings.has_suffix(f.name, PART_SUFFIX) { size = f.size } }
		testing.expectf(t, size == w.bytes, "%s: %s has %d bytes, want %d", backend, w.name, size, w.bytes)
	}
}

@(test)
downloads_whole_on_the_rust_stack :: proc(t: ^testing.T) { downloads_whole(t, "rust") }

@(test)
downloads_whole_on_winhttp :: proc(t: ^testing.T) { downloads_whole(t, "winhttp") }
