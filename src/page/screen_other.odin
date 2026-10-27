#+build !windows
package page

// No display the engine can name on this system yet (the toolkit's platform layer will tell): Screen_get falls back to
// the page's viewport.
@(private)
primary_screen :: proc() -> (screen, work: [4]i32, ok: bool) { return }
