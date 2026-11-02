#+build !windows
package tooling

// What runs on another system has no desktop of its own to go to (Linux: xvfb-run for what needs a window).
ON_DESKTOP_VAR :: "WREN_ON_TEST_DESKTOP"
on_own_desktop :: proc(code: ^int, temp: string) -> bool { return false }
