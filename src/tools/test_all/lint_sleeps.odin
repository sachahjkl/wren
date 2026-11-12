package test_all

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "wb:tools/tooling"

// A test simulates a failure, it does not wait for it (docs/testing.md): a fake, a virtual clock, a condition, a gate of the test server. The sleeps left in test sources are the ones of
// tools/test_sleeps_allowed.txt, each with why it stays: a new one fails here, and so does a line that says more than the file has, so that the list shrinks with the code.
// A "sleep" is any wait whose end is a time and not a state: a sleep, a spin on the processor (thread.yield, base.await), a wait with a
// timeout on a semaphore or a futex, and the waits of e2e that let real time pass (busy_wait, wait_at_rest, rest_turns).

TEST_SLEEPS_ALLOWED :: "tools/test_sleeps_allowed.txt"
TEST_SLEEP_DIRS :: [?]string{"src/tools/e2e", "src/e2e"}   // (and every *_test.odin and *_test_<system>.odin under src)
TEST_SLEEP_CALLS :: [?]string{
	"time.sleep(", "win.Sleep(", "windows.Sleep(",
	"thread.yield(", "base.await(",                                      // a spin: a whole processor for the wait, which slows every other step
	"sema_wait_with_timeout(", "futex_wait_with_timeout(",              // a wait that ends on its timeout when nothing signals
	"busy_wait(", "wait_at_rest(", "rest_turns(",                       // e2e: real time while the page or the loop is left alone
}

@(private = "file")
is_test_source :: proc(path: string) -> bool {
	if !strings.has_suffix(path, ".odin") { return false }
	for dir in TEST_SLEEP_DIRS { if strings.has_prefix(path, dir) { return true } }
	name := filepath_name(path)
	return strings.contains(name, "_test.") || strings.contains(name, "_test_")
}

@(private = "file")
filepath_name :: proc(path: string) -> string { return path[strings.last_index_byte(path, '/') + 1:] }

// How many sleeps the source has, comments left out.
count_test_sleeps :: proc(text: string) -> int {
	n := 0
	rest := text
	calls := TEST_SLEEP_CALLS
	for line in strings.split_lines_iterator(&rest) {
		code := line
		if at := strings.index(code, "//"); at >= 0 { code = code[:at] }
		for call in calls { n += strings.count(code, call) }
	}
	return n
}

@(private = "file")
scan_test_sleeps :: proc(dir: string, found: ^map[string]int) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for e in entries {
		path := strings.concatenate({dir, "/", e.name})
		if e.type == .Directory {
			if !strings.has_prefix(e.name, ".") { scan_test_sleeps(path, found) }
			continue
		}
		if !is_test_source(path) { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil { continue }
		if n := count_test_sleeps(string(data)); n > 0 { found[path] = n }
	}
}

// "<path> <count>  # why", as the file has them: lines that say nothing are left out.
parse_test_sleeps_allowed :: proc(text: string) -> (allowed: map[string]int, bad: []string) {
	errors := make([dynamic]string)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || strings.has_prefix(l, "#") { continue }
		hash := strings.index(l, "#")
		fields := strings.fields(hash >= 0 ? l[:hash] : l, context.temp_allocator)
		n, ok := 0, false
		if len(fields) == 2 { n, ok = strconv.parse_int(fields[1]) }
		if !ok || hash < 0 || strings.trim_space(l[hash + 1:]) == "" { append(&errors, strings.clone(l)); continue }
		allowed[strings.clone(fields[0])] = n
	}
	return allowed, errors[:]
}

lint_test_sleeps :: proc(log := "") -> bool {
	out := strings.builder_make()
	errors := 0
	data, err := os.read_entire_file(TEST_SLEEPS_ALLOWED, context.allocator)
	if err != nil { tooling.say(log, fmt.tprintfln("error: %s cannot be read", TEST_SLEEPS_ALLOWED)); return false }
	allowed, bad := parse_test_sleeps_allowed(string(data))
	for l in bad { fmt.sbprintfln(&out, "error: %s: not `<path> <count>  # why`: %s", TEST_SLEEPS_ALLOWED, l); errors += 1 }
	found: map[string]int
	scan_test_sleeps("src", &found)
	names := make([dynamic]string)
	for path in found { append(&names, path) }
	for path in allowed { if path not_in found { append(&names, path) } }
	slice.sort(names[:])
	total := 0
	for path in names {
		n, listed := found[path] or_else 0, allowed[path] or_else 0
		total += n
		if n > listed { fmt.sbprintfln(&out, "error: %s: %d sleep(s), %d allowed: a test simulates what it waits for (docs/testing.md), or says in %s why not", path, n, listed, TEST_SLEEPS_ALLOWED); errors += 1 }
		if n < listed { fmt.sbprintfln(&out, "error: %s: %d sleep(s), %s says %d: lower it", path, n, TEST_SLEEPS_ALLOWED, listed); errors += 1 }
	}
	fmt.sbprintfln(&out, "sleeps in test sources: %d in %d files, %d error(s)", total, len(found), errors)
	tooling.say(log, strings.to_string(out))
	return errors == 0
}
