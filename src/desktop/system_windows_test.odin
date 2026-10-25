package desktop

import "core:os"
import "core:strings"
import "core:testing"

@(test)
system_files_have_full_paths :: proc(t: ^testing.T) {
	for name in ([]string{"cmd.exe", "wevtutil.exe"}) {
		p := system_file(name, .System)
		testing.expect(t, len(p) > 3 && p[1] == ':' && p[2] == '\\', p)
		testing.expect(t, strings.has_suffix(strings.to_lower(p, context.temp_allocator), strings.concatenate({"\\system32\\", name}, context.temp_allocator)), p)
		testing.expect(t, os.exists(p), p)
	}
	p := system_file("explorer.exe", .Windows)
	testing.expect(t, len(p) > 3 && p[1] == ':' && p[2] == '\\' && os.exists(p), p)
	testing.expect(t, !strings.contains(strings.to_lower(p, context.temp_allocator), "system32"), p)
}