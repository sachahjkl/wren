#+build !windows
package browser

// The system services the form shell asks for, off Windows (forms_shell_windows.odin has the Windows ones). The toolkit
// does not yet carry a file-type database, a colour picker or the desktop's caret / double-click settings on Linux, so:
//   * the MIME type comes only from the browser's own table (the caller falls back to it when this returns "");
//   * <input type=color> cannot open a system picker, so it keeps the field's value (an honest "unsupported"): the lead
//     should wire the toolkit's own colour picker or the XDG colour portal here once it exists;
//   * the caret blink and double-click intervals use the usual desktop defaults (530 ms, 500 ms), which a user can
//     still override through the forms.caret_blink_ms / forms.double_click_ms preferences.

import "toolkit:platform"

system_mime_of_path :: proc(path: string) -> string { return "" }

system_pick_color :: proc(owner: ^platform.Window, initial: u32) -> (result: u32, ok: bool) { return 0, false }

system_caret_blink_ms :: proc() -> int { return 530 }

system_double_click_ms :: proc() -> f64 { return 500 }
