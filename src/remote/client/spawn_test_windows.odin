#+build windows
package client

import "core:testing"
import win "core:sys/windows"

@(test)
a_process_is_the_one_written_down_by_creation_time_and_program :: proc(t: ^testing.T) {
	was := Identity{created = 134_000_000_000_000_000, image = `C:\Apps\Wren\wren.exe`}
	testing.expect(t, same_process(was, was))
	testing.expect(t, same_process(was, {created = was.created, image = `c:/apps/wren/WREN.EXE`}), "case and slashes are not a different program")
	testing.expect(t, !same_process(was, {created = was.created + 1, image = was.image}), "a pid reused by a program started later")
	testing.expect(t, !same_process(was, {created = was.created, image = `C:\Windows\System32\ping.exe`}), "same instant, other program")
	testing.expect(t, !same_process({}, {}), "a record of an older wren ctl (nothing written) names nobody")
	testing.expect(t, !same_process({created = 5}, {created = 5, image = `C:\x.exe`}), "no program written")
	testing.expect(t, !same_process({image = `C:\x.exe`}, {image = `C:\x.exe`}), "no creation time written")
}

@(test)
this_process_can_be_told_again :: proc(t: ^testing.T) {
	h := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, win.GetCurrentProcessId())
	testing.expect(t, h != nil)
	defer win.CloseHandle(h)
	a, ok := identity_of(h)
	testing.expect(t, ok && a.created != 0 && a.image != "")
	b, ok2 := identity_of(win.GetCurrentProcess())
	testing.expect(t, ok2 && same_process(a, b), "the handle of a pid and the pseudo handle of the process say the same")
}