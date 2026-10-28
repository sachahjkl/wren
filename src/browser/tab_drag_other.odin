#+build !windows
package browser

// The window-manager queries of tab tear-off off Windows (tab_drag_windows.odin has the Windows ones). Wayland does not
// let a client know the pointer's absolute position, the virtual-screen bounds or the window stacking order (the
// compositor owns all three), and X11 could but the toolkit does not surface them yet. So:
//   * pointer_screen returns the event-derived position the caller already has (correct for a single window and for the
//     injected input tests and the remote control drive a drag with; a tab torn into its own window follows the pointer
//     through the event stream, and move_window is a no-op on Wayland anyway);
//   * keep_on_screen does not clamp (the compositor places windows);
//   * windows_by_z returns the browser's own windows in their list order, so a drop still finds a window under the
//     pointer by its client rectangle — only the "topmost when two overlap" tie-break is missing.
// Tear-off across windows under a real X11 window manager is the piece for the lead to try (docs/portability.md).

import "toolkit:draw"

pointer_screen :: proc(fallback: draw.Vec2) -> draw.Vec2 { return fallback }

keep_on_screen :: proc(x, y: int, w: ^Browser_Window) -> (int, int) { return x, y }

windows_by_z :: proc(app: ^App) -> []^Browser_Window {
	out := make([]^Browser_Window, len(app.windows), context.temp_allocator)
	copy(out, app.windows[:])
	return out
}
