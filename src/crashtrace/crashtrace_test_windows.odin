package crashtrace

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "core:testing"

// The helper the report runs is the system folder's, by its full path: never a bare name that CreateProcess would look up in the
// working directory first.
@(test)
system_tool_has_a_full_path :: proc(t: ^testing.T) {
	exe, line := system_tool_command(`C:\Windows\System32`, "wevtutil.exe", "qe Application /c:40")
	testing.expect_value(t, exe, `C:\Windows\System32\wevtutil.exe`)
	testing.expect_value(t, line, `"C:\Windows\System32\wevtutil.exe" qe Application /c:40`)
	exe, _ = system_tool_command(`C:\Windows\System32\`, "wevtutil.exe", "")
	testing.expect_value(t, exe, `C:\Windows\System32\wevtutil.exe`)
	exe, line = system_tool_command(`D:\Win dows\System32`, "wevtutil.exe", "x")
	testing.expect_value(t, exe, `D:\Win dows\System32\wevtutil.exe`)
	testing.expect(t, strings.has_prefix(line, `"D:\Win dows\`), "a path with a space is quoted")
}

// The fingerprint read from the image in memory is the one of the file on disk (what build.bat and the symbolizer read).
@(test)
fingerprint_is_the_files :: proc(t: ^testing.T) {
	buf: [32]u8
	fp := build_fingerprint(buf[:])
	testing.expect(t, len(fp) >= 9, fp)
	path: [520]u16
	n := win.GetModuleFileNameW(nil, &path[0], len(path))
	exe, _ := win.utf16_to_utf8(path[:n], context.temp_allocator)
	data, err := os.read_entire_file(exe, context.temp_allocator)
	testing.expect(t, err == nil, exe)
	stamp, size, ok := pe_stamp_and_size(uintptr(raw_data(data)))   // the headers are at the same offsets in the file
	testing.expect(t, ok)
	testing.expect_value(t, fp, fmt.tprintf("%08X%X", stamp, size))
	junk: [256]u8
	testing.expect_value(t, build_fingerprint(buf[:], uintptr(&junk[0])), "")   // not an image: nothing read past a bad "MZ"
}

@(test)
system_directory_is_the_systems :: proc(t: ^testing.T) {
	dir := system_directory()
	testing.expect(t, dir != "")
	testing.expect(t, strings.has_suffix(strings.to_lower(dir, context.temp_allocator), `\system32`), dir)
}

// The event of the process that ended, by the data the event holds, from when it began.
@(test)
the_event_of_a_session_is_asked_for_by_its_process :: proc(t: ^testing.T) {
	STARTED :: 134382674049103565   // 2026-11-04 in FILETIME ticks
	query := application_error_query(0x28074, STARTED)
	testing.expect(t, strings.contains(query, "EventData[Data='0x28074']"), query)   // (as the event writes it)
	testing.expect(t, strings.contains(query, "TimeCreated[@SystemTime>='2026-"), query)
}

@(test)
what_ended_a_session_is_said :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(unclean_cause(7, "Event[0]\n  Exception code: 0xc0000409", false), "0xc0000409"), "the event says it")
	testing.expect(t, strings.contains(unclean_cause(7, "", true), "restarted"), "a restart")
	testing.expect(t, strings.contains(unclean_cause(7, "", false), "killed from outside"), "what is left")
	HOUR_MS :: 3_600_000
	HOUR_TICKS :: u64(HOUR_MS) * 10_000
	NOW :: 100 * HOUR_TICKS
	testing.expect(t, session_before_boot(NOW - 2 * HOUR_TICKS, NOW, HOUR_MS), "the session is older than the machine's start")
	testing.expect(t, !session_before_boot(NOW - HOUR_TICKS / 2, NOW, HOUR_MS), "the machine is older than the session")
}

// A stack walked in a copy: its frames found, and what is no stack ends the walk at the address it has, where a walk in place would fault.
@(test)
a_stack_is_walked_in_a_copy :: proc(t: ^testing.T) {
	stack: Stack_Copy
	testing.expect(t, stack_copy_init(&stack))
	defer stack_copy_destroy(&stack)
	ctx: win.CONTEXT
	RtlCaptureContext(&ctx)
	testing.expect(t, stack_copy_take(&stack, ctx.Rsp))
	pcs: [MAX_FRAMES]u64
	testing.expect(t, stack_walk(&stack, &ctx, pcs[:]) > 2, "the frames down to the thread's start")

	WILD :: 0x2000010
	wild: win.CONTEXT
	wild.Rip, wild.Rsp, wild.Rbp = 0x1234, WILD, WILD
	testing.expect(t, !stack_copy_take(&stack, wild.Rsp), "nothing there")
	testing.expect_value(t, stack_walk(&stack, &wild, pcs[:]), 1)

	// a real stack with frame registers pointing at nothing: the walk ends, it does not read them
	RtlCaptureContext(&ctx)
	testing.expect(t, stack_copy_take(&stack, ctx.Rsp))
	ctx.Rbp, ctx.Rbx, ctx.Rsi, ctx.Rdi = WILD, WILD, WILD, WILD
	ctx.R12, ctx.R13, ctx.R14, ctx.R15 = WILD, WILD, WILD, WILD
	testing.expect(t, stack_walk(&stack, &ctx, pcs[:]) >= 1)
}
