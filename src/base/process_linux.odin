package base

import "core:os"
import "core:strconv"
import "core:strings"

@(private)
native_process_memory :: proc() -> Process_Memory {
	data, err := os.read_entire_file("/proc/self/status", context.temp_allocator)
	if err != nil { return {} }
	kib :: proc(line, key: string) -> (i64, bool) {
		if !strings.has_prefix(line, key) { return 0, false }
		v := strings.trim_space(strings.trim_suffix(strings.trim_space(line[len(key):]), "kB"))
		n, ok := strconv.parse_i64(v)
		return n * 1024, ok
	}
	m: Process_Memory
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if v, ok := kib(line, "VmRSS:"); ok { m.resident = v }
		if v, ok := kib(line, "RssAnon:"); ok { m.private += v }
		if v, ok := kib(line, "VmSwap:"); ok { m.private += v }
	}
	return m
}
