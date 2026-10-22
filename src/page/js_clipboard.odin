package page

// navigator.clipboard.writeText / readText (api/js_web.widl, module navigator; Clipboard API §5). Clipboard.write / read
// and ClipboardItem are JavaScript on top of these (native/js/prelude/clipboard.js).
//
// What browsers ask, as far as a browser without permission prompts can:
//   * writeText: the document is focused (its tab is the current one of an active window) or has transient activation (a
//     click or key press a few seconds ago, the same record the passkeys use: webauthn_has_activation);
//   * readText: focused AND with transient activation. Chromium asks the user for a permission; here the gesture is the
//     consent, so a page cannot read the clipboard behind the user's back;
//   * both can be turned off (navigator.clipboard_write / navigator.clipboard_read).
// Without a window (the headless tools) there is no focus or gesture to ask for, and the text lives in a variable of the
// process instead of the system clipboard.

import "core:strings"
import "wb:base"

// The system clipboard, as the shell offers it. nil procs: the process's own variable (headless tools, tests).
Clipboard_Embedder :: struct {
	read:  proc() -> (text: string, ok: bool),   // the text, valid until the call returns (copied here)
	write: proc(text: string) -> bool,
}

clipboard_embedder: Clipboard_Embedder

@(private = "file")
fake_clipboard: string   // owned, process allocator

Clipboard_Verdict :: enum u8 { Allowed, Not_Focused, No_Gesture, Disabled }

// The rules above, apart from the page (unit tests).
clipboard_verdict :: proc(write, enabled, windowed, focused, gesture: bool) -> Clipboard_Verdict {
	if !enabled { return .Disabled }
	if !windowed { return .Allowed }
	if write { return focused || gesture ? .Allowed : .Not_Focused }
	if !focused { return .Not_Focused }
	return gesture ? .Allowed : .No_Gesture
}

@(private = "file")
clipboard_check :: proc(p: ^Page, write: bool) -> Clipboard_Verdict {
	s := &p.settings.js_web
	windowed, focused := webauthn_embedder.window != nil, true
	if windowed { _, focused = webauthn_embedder.window(p) }
	return clipboard_verdict(write, write ? s.clipboard_write : s.clipboard_read, windowed, focused, webauthn_has_activation(p))
}

@(private = "file")
clipboard_denied :: proc(op: string, v: Clipboard_Verdict) -> string {
	switch v {
	case .Allowed:     return ""
	case .Not_Focused: return strings.concatenate({"NotAllowedError: Failed to execute '", op, "' on 'Clipboard': Document is not focused."}, context.temp_allocator)
	case .No_Gesture:  return strings.concatenate({"NotAllowedError: Failed to execute '", op, "' on 'Clipboard': Read permission denied (reading needs a click or key press in the page)."}, context.temp_allocator)
	case .Disabled:    return strings.concatenate({"NotAllowedError: Failed to execute '", op, "' on 'Clipboard': ", op == "readText" ? "reading" : "writing", " the clipboard is turned off (navigator.clipboard_", op == "readText" ? "read" : "write", ")."}, context.temp_allocator)
	}
	return ""
}

@(private = "file")
clipboard_put :: proc(text: string) -> bool {
	if clipboard_embedder.write != nil { return clipboard_embedder.write(text) }
	delete(fake_clipboard, base.process_allocator())
	fake_clipboard = strings.clone(text, base.process_allocator())
	return true
}

@(private = "file")
clipboard_get :: proc() -> (string, bool) {
	if clipboard_embedder.read != nil { return clipboard_embedder.read() }
	return fake_clipboard, true
}

// The text the headless tools' clipboard holds (tests).
clipboard_fake_text :: proc() -> string { return fake_clipboard }

Clipboard_writeText :: proc(c: ^Call, data: string) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	if v := clipboard_check(p, true); v != .Allowed {
		reject_later(p, pr, i64(Api_Error.Not_Allowed), clipboard_denied("writeText", v))
		return pr
	}
	if !clipboard_put(data) {
		reject_later(p, pr, i64(Api_Error.Not_Allowed), "NotAllowedError: Failed to execute 'writeText' on 'Clipboard': the system clipboard is not available.")
		return pr
	}
	resolve_later(p, pr, 0)
	return pr
}

Clipboard_readText :: proc(c: ^Call) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	if v := clipboard_check(p, false); v != .Allowed {
		reject_later(p, pr, i64(Api_Error.Not_Allowed), clipboard_denied("readText", v))
		return pr
	}
	text, ok := clipboard_get()
	if !ok {
		reject_later(p, pr, i64(Api_Error.Not_Allowed), "NotAllowedError: Failed to execute 'readText' on 'Clipboard': the system clipboard is not available.")
		return pr
	}
	resolve_later(p, pr, 0, text)
	return pr
}
