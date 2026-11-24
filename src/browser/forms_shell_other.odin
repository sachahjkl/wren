#+build !windows
package browser

// The system services the form shell asks for, off Windows (forms_shell_windows.odin has the Windows ones):
//   * the MIME type comes only from the browser's own table (the caller falls back to it when this returns "");
//   * <input type=color> opens the toolkit's in-window colour picker popover (ui.color_picker, forms_shell.odin);
//   * the caret blink and double-click intervals use the usual desktop defaults (530 ms, 500 ms), which a user can
//     still override through the forms.caret_blink_ms / forms.double_click_ms preferences.

import "toolkit:platform"
import "wb:base"
import "wb:page"

system_mime_of_path :: proc(path: string) -> string { return "" }

shell_open_color_picker :: proc(app: ^App, p: ^page.Page, input: base.Handle) { forms_color_popover_open(app, p, input) }

system_pick_color :: proc(owner: ^platform.Window, initial: u32) -> (result: u32, ok: bool) { return 0, false }

system_caret_blink_ms :: proc() -> int { return 530 }

system_double_click_ms :: proc() -> f64 { return 500 }
