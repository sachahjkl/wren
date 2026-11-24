package browser

// The passkey ceremony of a Vault login or unlock ("Log in with passkey"): the helper hands the request's options
// (vault.vault_passkey_take, state Passkey), Wren runs the WebAuthn get with the PRF extension through its own platform
// (src/webauthn: the system's authenticator, a security key), for the web vault's origin, on a thread of its own; the
// answer goes back to the helper (vault.vault_passkey_done), which checks it with the server and opens the keys with the
// PRF output. The PRF output is a secret: zeroed here once handed over.

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:time"
import "wb:base"
import "wb:host"
import i18n "toolkit:i18n"
import "wb:page"
import "wb:url"
import "wb:vault"
import "wb:webauthn"

@(private)
Vault_Passkey_Op :: struct {
	app:      ^App,
	c:        ^webauthn.Ceremony,
	platform: ^webauthn.Platform,
	thread:   ^host.Thread,
	done:     b32,   // atomic: worker finished (or failed to start)
}

// Why a passkey cannot open the Vault on this computer ("": it can). Bitwarden's passkeys open the keys with the PRF
// extension: Wren's platform must pass it to the authenticator (Windows' webauthn.dll from version 6; on Linux libfido2,
// as hmac-secret).
vault_passkey_unsupported :: proc(app: ^App) -> string {
	pl := webauthn.platform_for(&app.page_settings.authn)
	if pl == nil { return webauthn.NO_PLATFORM_REASON }
	if .Prf not_in pl.capabilities(pl).extensions {
		// (Windows passes the PRF's salts to the authenticator from version 6 of its Web Authentication API: a system
		// with an older one cannot give the secret that opens the keys, whatever the passkey. Say which one was found.)
		if pl.name == "Windows" {
			return fmt.tprintf(i18n.tr("Logging in with a passkey needs the passkey's PRF extension, which Windows passes on from version 6 of its Web Authentication API (a recent Windows 11). This Windows has version %d. Use the master password, or update Windows."), pl.version)
		}
		return i18n.tr("Logging in with a passkey needs its PRF extension, which Wren does not support on this system yet. Use the master password or another device.")
	}
	return ""
}

// Each frame: a ceremony the Vault waits for starts (once).
vault_passkey_frame :: proc(app: ^App) {
	s := &app.vault
	if s.passkey_op != nil { return }
	v := &s.v
	options, _, ok := vault.vault_passkey_take(v)
	if !ok { return }
	origin_text := vault.web_vault_url(v.settings)
	u, parsed := url.parse(origin_text, allocator = context.temp_allocator)
	if origin_text == "" || !parsed {
		vault.vault_passkey_failed(v, "The web vault's address is not known: set vault.server.url.")
		return
	}
	cer := webauthn.ceremony_make(.Get)
	if cer == nil { vault.vault_passkey_failed(v, "Out of memory."); return }
	caller := webauthn.caller_of(url.origin_of(u, webauthn.ceremony_allocator(cer)), true, webauthn.ceremony_allocator(cer))
	st := webauthn.prepare_get(cer, options, caller, &app.page_settings.authn)
	if st.error != .None {
		vault.vault_passkey_failed(v, st.message)
		webauthn.ceremony_destroy(cer)
		return
	}
	// (the system's dialog belongs to the window the person is in)
	cer.get.window = rawptr(uintptr(window_native_handle(active_window(app).win)))
	pl := webauthn.platform_for(&app.page_settings.authn)
	if pl == nil {
		vault.vault_passkey_failed(v, vault_passkey_unsupported(app))
		webauthn.ceremony_destroy(cer)
		return
	}
	op := new(Vault_Passkey_Op, base.process_allocator())
	op^ = {app = app, c = cer, platform = pl}
	s.passkey_op = op
	op.thread = host.thread_start(proc(data: rawptr) {
		op := (^Vault_Passkey_Op)(data)
		webauthn.run(op.c, op.platform)
		sync.atomic_store(&op.done, true)
		host.post(&op.app.loop, passkey_finished, op.app)
	}, op, name = "wren-vault-passkey")
	if op.thread == nil {
		op.c.status = webauthn.fail(.Not_Allowed, "The passkey request could not start.")
		sync.atomic_store(&op.done, true)
		host.post(&app.loop, passkey_finished, app)
	}
}

// The dialog closed or the browser stops while the ceremony runs: the authenticator is told, the thread ends.
vault_passkey_cancel :: proc(app: ^App) {
	op := (^Vault_Passkey_Op)(app.vault.passkey_op)
	if op == nil { return }
	webauthn.cancel(op.platform, &op.c.cancel, .Abort)
}

// At exit: dismiss open security-key prompts, cancel a running ceremony, and wait within the grace period before the
// loop goes. A stuck authenticator call that ignores cancellation is left to process exit (matching page.webauthn_shutdown).
vault_passkey_destroy :: proc(app: ^App) {
	op := (^Vault_Passkey_Op)(app.vault.passkey_op)
	if op == nil { return }
	webauthn.pin_dismiss()
	webauthn.cancel(op.platform, &op.c.cancel, .Abort)
	grace_ms := app.page_settings.authn.cancel_grace_ms
	deadline := time.tick_now()
	for !host.thread_finished(op.thread) && time.duration_milliseconds(time.tick_since(deadline)) < f64(grace_ms) {
		time.sleep(page.WEBAUTHN_SHUTDOWN_POLL)
	}
	app.vault.passkey_op = nil
	if !host.thread_finished(op.thread) { return }
	host.thread_join(op.thread)
	webauthn.ceremony_destroy(op.c)
	free(op, base.process_allocator())
}

@(private = "file")
passkey_finished :: proc(data: rawptr) {
	app := (^App)(data)
	if app == nil || !app.vault.started { return }
	op := (^Vault_Passkey_Op)(app.vault.passkey_op)
	if op == nil || !sync.atomic_load(&op.done) { return }
	host.thread_join(op.thread)
	defer {
		webauthn.ceremony_destroy(op.c)
		if app.vault.passkey_op == op { app.vault.passkey_op = nil }
		free(op, base.process_allocator())
	}
	v := &app.vault.v
	st := op.c.status
	if st.error != .None {
		vault.vault_passkey_failed(v, st.error == .Abort ? "The passkey request was cancelled." : st.message)
		return
	}
	r := &op.c.result
	if !r.ext.has_prf_results || len(r.ext.prf_results.first) == 0 {
		vault.vault_passkey_failed(v, "This passkey cannot open the vault: it gave no PRF output (it must be one made for logging in to Bitwarden).")
		return
	}
	a := vault.Passkey_Assertion{
		credential_id      = webauthn.base64url_encode(r.raw_id, context.temp_allocator),
		authenticator_data = webauthn.base64url_encode(r.authenticator_data, context.temp_allocator),
		client_data_json   = webauthn.base64url_encode(r.client_data_json, context.temp_allocator),
		signature          = webauthn.base64url_encode(r.signature, context.temp_allocator),
		user_handle        = r.has_user_handle ? webauthn.base64url_encode(r.user_handle, context.temp_allocator) : "",
		prf                = webauthn.base64url_encode(r.ext.prf_results.first, context.temp_allocator),
	}
	vault.vault_passkey_done(v, a)
	// (the PRF output and its text are secrets: gone from this process once the helper has them)
	runtime.mem_zero(raw_data(a.prf), len(a.prf))
	runtime.mem_zero(raw_data(r.ext.prf_results.first), len(r.ext.prf_results.first))
}
