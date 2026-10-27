package page

// Web Authentication and navigator.credentials for a page (import module "credentials"; package webauthn does the
// client algorithms and talks to the platform).
//
//   * One ceremony at a time per document (Credential Management's "active credential types"): a second one is
//     NotAllowedError while the first runs.
//   * Before the ceremony, the page's own conditions: a secure context, the document not frozen, a recent key press or
//     click in it (HTML transient activation, recorded by `webauthn_note_input` from dispatch_event), its tab shown in
//     the focused window (asked of the embedder: `webauthn_embedder`), the mediation it asks for.
//   * The platform call blocks until the user answers the system's dialog: it runs on a thread of its own, started per
//     ceremony; the window keeps running (no frame while nothing changes) and the answer comes back by host.post. The
//     lifetime timer, the AbortSignal, the page closing and the address bar's cancel all cancel the platform operation
//     (again every security.webauthn cancel_retry while it has not returned: a cancel can arrive before Windows knows
//     the operation).
//   * Nothing about credentials is logged; the console only gets the error names a page would see anyway.

import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:webauthn"

// What the shell tells pages about their window. nil procs: no window (headless tools): every page counts as shown and
// focused, and the platform's dialog goes to the foreground window.
Webauthn_Embedder :: struct {
	// the window the page is shown in (an HWND) and whether its tab is the current one of a focused window
	window:  proc(p: ^Page) -> (hwnd: rawptr, focused: bool),
	// a ceremony of the page started or ended (the address bar shows it)
	changed: proc(p: ^Page),
}

webauthn_embedder: Webauthn_Embedder

// How often a cancellation is repeated until the platform call returns.
@(private="file") CANCEL_RETRY_MS :: 500

@(private="file")
Webauthn_Doc :: struct {
	page_id:      u64,
	activation_ns: i64,     // loop clock of the last activation-triggering input event
	has_activation: bool,
	active:       ^Webauthn_Op,
	cleanup:      base.Cleanup_Id,
}

Webauthn_Op :: struct {
	page_id:   u64,
	loop:      ^host.Loop,
	promise:   u64,
	owner:     u32,
	c:         ^webauthn.Ceremony,
	platform:  ^webauthn.Platform,
	thread:    ^host.Thread,
	signal:    u64,
	algo:      int,
	timer:     base.Handle,   // lifetime timer
	retry:     base.Handle,   // repeated cancellation
	rp_id:     string,        // in the ceremony's arena (address bar)
	cancel_ns: i64,           // loop clock of the first cancellation (0: none)
}

// UI thread only.
@(private="file") webauthn_docs: map[u64]^Webauthn_Doc
@(private="file") webauthn_ops: [dynamic]^Webauthn_Op   // every op whose thread may still run (shutdown joins them)

@(private="file")
webauthn_doc :: proc(p: ^Page, create := false) -> ^Webauthn_Doc {
	id := page_id(p)
	if id == 0 { return nil }
	if d, ok := webauthn_docs[id]; ok { return d }
	if !create { return nil }
	if webauthn_docs == nil { webauthn_docs = make(map[u64]^Webauthn_Doc, base.process_allocator()) }
	d := new(Webauthn_Doc, base.process_allocator())
	d.page_id = id
	webauthn_docs[id] = d
	d.cleanup = base.on_close(p.scope, webauthn_doc_closed, d)
	return d
}

// The document goes away: its ceremony is cancelled (the user cannot answer a dialog for a page that is gone) and its
// answer, when it comes, is dropped.
@(private="file")
webauthn_doc_closed :: proc(data: rawptr) {
	d := (^Webauthn_Doc)(data)
	delete_key(&webauthn_docs, d.page_id)
	if len(webauthn_docs) == 0 { delete(webauthn_docs); webauthn_docs = nil }   // made again by the next document
	if op := d.active; op != nil {
		webauthn.cancel(op.platform, &op.c.cancel, .Not_Allowed)
		// the page's timers go with its scope; the op lives on until its thread returns (webauthn_finished)
		op.timer, op.retry = base.NIL_HANDLE, base.NIL_HANDLE
		op.page_id = 0
	}
	free(d, base.process_allocator())
}

// HTML "activation-triggering input event": keydown (not Escape), mousedown, pointerdown of a mouse, pointerup of
// another pointer, touchend. Called by dispatch_event for the shell's (trusted) input.
webauthn_note_input :: proc(p: ^Page, ev: dom.Event) {
	trigger := false
	switch ev.type {
	case "keydown": trigger = ev.key != 27
	case "mousedown", "pointerdown", "touchend": trigger = true
	}
	if !trigger { return }
	d := webauthn_doc(p, true)
	if d == nil { return }
	d.activation_ns, d.has_activation = host.now_ns(p.loop), true
}

// Whether the page has transient activation now.
webauthn_has_activation :: proc(p: ^Page) -> bool {
	d := webauthn_doc(p)
	if d == nil || !d.has_activation { return false }
	return host.now_ns(p.loop) - d.activation_ns <= i64(p.settings.authn.user_activation_ms) * 1_000_000
}

// Nanoseconds since the page's last activation-triggering input event (ok = false: it had none).
activation_age_ns :: proc(p: ^Page) -> (age: i64, ok: bool) {
	d := webauthn_doc(p)
	if d == nil || !d.has_activation { return 0, false }
	return host.now_ns(p.loop) - d.activation_ns, true
}

// HTML transient activation for the purpose of popup blocking: a click or key press in the page within the transient
// activation lifetime (5 s, the HTML default). Used by the content blocker to tell a user-opened window from one a script
// opens on its own ($popup).
POPUP_ACTIVATION_NS :: i64(5_000) * 1_000_000

popup_has_gesture :: proc(p: ^Page) -> bool {
	age, ok := activation_age_ns(p)
	return ok && age <= POPUP_ACTIVATION_NS
}

// For the shell: the ceremony the page is waiting for, if any.
webauthn_pending :: proc(p: ^Page) -> (pending: bool, create: bool, rp_id: string) {
	d := webauthn_doc(p)
	if d == nil || d.active == nil { return false, false, "" }
	return true, d.active.c.kind == .Create, d.active.rp_id
}

// For the shell: the user cancelled from the browser's interface (NotAllowedError for the page).
webauthn_cancel :: proc(p: ^Page) {
	d := webauthn_doc(p)
	if d == nil || d.active == nil { return }
	webauthn_cancel_op(p, d.active, .Not_Allowed)
}

// Whether a ceremony of the page is in progress (the back/forward cache cannot keep it).
webauthn_busy :: proc(p: ^Page) -> bool {
	d := webauthn_doc(p)
	return d != nil && d.active != nil
}

// Ceremonies whose platform call has not returned yet, every page included (tests, shutdown).
webauthn_in_flight :: proc() -> int { return len(webauthn_ops) }

// At exit, before the loop goes: every ceremony cancelled and its thread joined. A platform call that does not come
// back within grace_ms of its cancellation (a system dialog that ignores it) is left to the end of the process: its
// thread and its ceremony are not freed (the thread still uses them), and the exit is not held up.
webauthn_shutdown :: proc(grace_ms := 3000) {
	for op in webauthn_ops { webauthn.cancel(op.platform, &op.c.cancel, .Not_Allowed) }
	deadline := time.tick_now()
	for op in webauthn_ops {
		for !host.thread_finished(op.thread) && time.duration_milliseconds(time.tick_since(deadline)) < f64(grace_ms) {
			time.sleep(10 * time.Millisecond)
		}
		if !host.thread_finished(op.thread) { continue }
		host.thread_join(op.thread)
		webauthn.ceremony_destroy(op.c)
		free(op, base.process_allocator())
	}
	delete(webauthn_ops)
	webauthn_ops = nil
	webauthn.virtual_reset()
}

////////////////////////////////
// Credentials (host objects)

Webauthn_Credential :: struct {
	c:      ^webauthn.Ceremony,   // everything lives in its arena
	id:     string,
	facts:  webauthn.Attestation_Facts,
	has_facts: bool,
	ext_json: string,
	json:   string,
}

webauthn_credential_vt := Object_VTable{
	name = "PublicKeyCredential",
	destroy = proc(p: ^Page, data: rawptr) {
		w := (^Webauthn_Credential)(data)
		webauthn.ceremony_destroy(w.c)
		free(w, base.process_allocator())
	},
}

lookup_PublicKeyCredential :: proc(c: ^Call, h: u64) -> ^Webauthn_Credential { return (^Webauthn_Credential)(object_data(c.page, h, &webauthn_credential_vt)) }

@(private="file")
credential_create :: proc(p: ^Page, cer: ^webauthn.Ceremony, owner: u32) -> u64 {
	w := new(Webauthn_Credential, base.process_allocator())
	w.c = cer
	a := webauthn.ceremony_allocator(cer)
	r := &cer.result
	w.id = webauthn.base64url_encode(r.raw_id, a)
	if r.kind == .Create { w.facts, w.has_facts = webauthn.attestation_facts(r.attestation_object, a) }
	w.ext_json = webauthn.extension_outputs_json(r.ext, a)
	w.json = webauthn.credential_json(r, a)
	return object_create(p, &webauthn_credential_vt, w, owner)
}

////////////////////////////////
// Ceremonies

@(private)
reject_later :: proc(p: ^Page, pr: u64, code: i64, message: string) {
	R :: struct { pr: u64, code: i64, msg: string }
	r := new(R, base.process_allocator())
	r^ = {pr, code, strings.clone(message, base.process_allocator())}
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		r := (^R)(data)
		defer { delete(r.msg, base.process_allocator()); free(r, base.process_allocator()) }
		if pg != nil { promise_reject(pg, r.pr, r.code, r.msg) }
	}, r)
}

@(private)
resolve_later :: proc(p: ^Page, pr: u64, value: i64, text := "") {
	R :: struct { pr: u64, value: i64, text: string }
	r := new(R, base.process_allocator())
	r^ = {pr, value, strings.clone(text, base.process_allocator())}
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		r := (^R)(data)
		defer { delete(r.text, base.process_allocator()); free(r, base.process_allocator()) }
		if pg != nil { promise_resolve(pg, r.pr, r.value, r.text) }
	}, r)
}

@(private="file")
error_code :: proc(e: webauthn.Error) -> i64 {
	switch e {
	case .None: return 0
	case .Type: return WEB_ERR_TYPE
	case .Not_Allowed, .Constraint: return i64(Api_Error.Not_Allowed)
	case .Invalid_State: return WEB_ERR_INVALID_STATE
	case .Not_Supported: return WEB_ERR_NOT_SUPPORTED
	case .Security: return WEB_ERR_SECURITY
	case .Abort: return WEB_ERR_ABORT
	case .Encoding: return WEB_ERR_ENCODING
	case .Syntax: return WEB_ERR_SYNTAX
	}
	return i64(Api_Error.Not_Allowed)
}

// The document-side checks shared by create() and get() (Credential Management §2.5.1 / §2.5.4 and the user agent's
// own rules). Returns 0 when the ceremony may start, else rejects `pr` and returns the code.
@(private="file")
webauthn_gate :: proc(p: ^Page, pr: u64, signal: Api_AbortSignal) -> bool {
	s := &p.settings.authn
	if !s.enabled { reject_later(p, pr, WEB_ERR_NOT_SUPPORTED, "NotSupportedError: Web Authentication is turned off (security.webauthn.enabled)"); return false }
	if !p.env.secure_context { reject_later(p, pr, WEB_ERR_SECURITY, "SecurityError: Web Authentication needs a secure context (https or localhost)"); return false }
	if p.web == nil || p.web.frozen || p.worker != nil { reject_later(p, pr, WEB_ERR_INVALID_STATE, "InvalidStateError: the document is not fully active"); return false }
	if signal.handle != 0 {
		if aborted, code, reason := signal_aborted(p, signal.handle); aborted {
			reject_later(p, pr, code != 0 ? code : WEB_ERR_ABORT, reason != "" ? reason : ABORT_REASON)
			return false
		}
	}
	if d := webauthn_doc(p); d != nil && d.active != nil {
		reject_later(p, pr, i64(Api_Error.Not_Allowed), "NotAllowedError: a request is already pending")
		return false
	}
	return true
}

// Activation and focus: checked last, so that malformed options are a TypeError whatever the user did.
@(private="file")
webauthn_user_gate :: proc(p: ^Page, pr: u64) -> (window: rawptr, ok: bool) {
	s := &p.settings.authn
	focused := true
	if webauthn_embedder.window != nil { window, focused = webauthn_embedder.window(p) }
	if s.require_focus && !focused {
		reject_later(p, pr, i64(Api_Error.Not_Allowed), "NotAllowedError: the document is not focused (security.webauthn.require_focus)")
		return nil, false
	}
	if s.require_user_activation && !webauthn_has_activation(p) {
		reject_later(p, pr, i64(Api_Error.Not_Allowed), "NotAllowedError: a passkey request needs a recent click or key press in the page (security.webauthn.require_user_activation)")
		return nil, false
	}
	return window, true
}

@(private="file")
webauthn_start :: proc(c: ^Call, kind: webauthn.Ceremony_Kind, options: string, mediation: Api_CredentialMediation, signal: Api_AbortSignal) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	if !webauthn_gate(p, pr, signal) { return pr }
	// Permissions Policy (frames.odin): a cross-origin frame uses passkeys only when its embedder delegates them
	feature := kind == .Create ? Feature.Publickey_Credentials_Create : Feature.Publickey_Credentials_Get
	if !feature_enabled(p, feature) {
		reject_later(p, pr, i64(Api_Error.Not_Allowed), kind == .Create ? "NotAllowedError: 'publickey-credentials-create' is not allowed in this document (Permissions Policy: the frame's allow attribute)" : "NotAllowedError: 'publickey-credentials-get' is not allowed in this document (Permissions Policy: the frame's allow attribute)")
		return pr
	}
	switch mediation {
	case .Conditional:
		// get: Credential Management §2.5.1 step 9 (TypeError); create: WebAuthn §5.1.3 step 20 (NotAllowedError)
		if kind == .Get { reject_later(p, pr, WEB_ERR_TYPE, "TypeError: conditional mediation is not supported") } else { reject_later(p, pr, i64(Api_Error.Not_Allowed), "NotAllowedError: conditional creation is not supported") }
		return pr
	case .Silent:
		// every public key credential needs the user: silent mediation hands back null without asking (§2.5.1 step 15)
		resolve_later(p, pr, 0)
		return pr
	case .Optional, .Required:
	}

	cer := webauthn.ceremony_make(kind)
	if cer == nil { reject_later(p, pr, i64(Api_Error.Not_Allowed), "NotAllowedError: out of memory"); return pr }
	caller := webauthn.caller_of(p.env.origin, p.env.secure_context, webauthn.ceremony_allocator(cer))
	st: webauthn.Status
	if kind == .Create { st = webauthn.prepare_create(cer, options, caller, &p.settings.authn) } else { st = webauthn.prepare_get(cer, options, caller, &p.settings.authn) }
	if st.error == .None {
		window, ok := webauthn_user_gate(p, pr)
		if !ok { webauthn.ceremony_destroy(cer); return pr }
		cer.make.window, cer.get.window = window, window
	} else {
		reject_later(p, pr, error_code(st.error), st.message)
		webauthn.ceremony_destroy(cer)
		return pr
	}
	pl := webauthn.platform_for(&p.settings.authn)
	if pl == nil {
		reject_later(p, pr, WEB_ERR_NOT_SUPPORTED, "NotSupportedError: this computer has no Web Authentication platform (Windows 10 1903 or later)")
		webauthn.ceremony_destroy(cer)
		return pr
	}

	op := new(Webauthn_Op, base.process_allocator())
	op^ = Webauthn_Op{page_id = page_id(p), loop = p.loop, promise = pr, owner = c.owner, c = cer, platform = pl, signal = signal.handle}
	op.rp_id = kind == .Create ? cer.make.rp_id : cer.get.rp_id
	timeout := kind == .Create ? cer.make.timeout_ms : cer.get.timeout_ms
	d := webauthn_doc(p, true)
	d.active = op
	append(&webauthn_ops, op)
	if op.signal != 0 {
		op.algo = signal_add_algorithm(p, op.signal, proc(pg: ^Page, data: u64, signal: u64) {
			webauthn_cancel_op(pg, (^Webauthn_Op)(uintptr(data)), .Abort)
		}, u64(uintptr(op)))
	}
	op.timer = host.set_timer(p.loop, f64(timeout), 0, proc(data: rawptr) {
		op := (^Webauthn_Op)(data)
		op.timer = base.NIL_HANDLE
		webauthn_cancel_op(page_by_id(op.page_id), op, .Not_Allowed)
	}, op, p.scope)
	op.thread = host.thread_start(proc(data: rawptr) {
		op := (^Webauthn_Op)(data)
		webauthn.run(op.c, op.platform)
		host.post(op.loop, webauthn_finished, op)
	}, op, name = "wren-webauthn")
	if op.thread == nil {
		// no thread: finish at once as a failure (the op is in the registry: webauthn_finished removes it)
		op.c.status = webauthn.fail(.Not_Allowed, "NotAllowedError: the browser could not start the request")
		host.post(p.loop, webauthn_finished, op)
	}
	if webauthn_embedder.changed != nil { webauthn_embedder.changed(p) }
	return pr
}

@(private="file")
webauthn_cancel_op :: proc(p: ^Page, op: ^Webauthn_Op, reason: webauthn.Error) {
	webauthn.cancel(op.platform, &op.c.cancel, reason)
	if p == nil || op.retry != base.NIL_HANDLE { return }
	op.cancel_ns = host.now_ns(p.loop)
	op.retry = host.set_timer(p.loop, CANCEL_RETRY_MS, CANCEL_RETRY_MS, proc(data: rawptr) {
		op := (^Webauthn_Op)(data)
		if op.platform.cancel != nil { op.platform.cancel(op.platform, &op.c.cancel) }
		p := page_by_id(op.page_id)
		if p != nil && host.now_ns(p.loop) - op.cancel_ns > i64(p.settings.authn.cancel_grace_ms) * 1_000_000 { webauthn_give_up(p, op) }
	}, op, p.scope)
}

// The platform did not give the cancelled operation back in time (security.webauthn.cancel_grace_ms): the page is
// answered as if it had (the signal's reason, or NotAllowedError) and may start another ceremony; the thread is left to
// finish on its own, and its answer is dropped.
@(private="file")
webauthn_give_up :: proc(p: ^Page, op: ^Webauthn_Op) {
	_, reason := webauthn.cancelled(&op.c.cancel)
	if op.timer != base.NIL_HANDLE { host.clear_timer(p.loop, op.timer); op.timer = base.NIL_HANDLE }
	if op.retry != base.NIL_HANDLE { host.clear_timer(p.loop, op.retry); op.retry = base.NIL_HANDLE }
	if d := webauthn_doc(p); d != nil && d.active == op { d.active = nil }
	op.page_id = 0   // webauthn_finished only frees it
	if reason == .Abort && op.signal != 0 {
		_, code, text := signal_aborted(p, op.signal)
		if op.algo != 0 { signal_remove_algorithm(p, op.signal, op.algo) }
		promise_reject(p, op.promise, code != 0 ? code : WEB_ERR_ABORT, text != "" ? text : ABORT_REASON)
	} else {
		if op.signal != 0 && op.algo != 0 { signal_remove_algorithm(p, op.signal, op.algo) }
		promise_reject(p, op.promise, i64(Api_Error.Not_Allowed), "NotAllowedError: the operation either timed out or was not allowed")
	}
	log(p, .Warn, "Web Authentication: the system did not end the cancelled request in time (security.webauthn.cancel_grace_ms); the page was answered anyway")
	if webauthn_embedder.changed != nil { webauthn_embedder.changed(p) }
}

// The platform call returned (UI thread).
@(private="file")
webauthn_finished :: proc(data: rawptr) {
	op := (^Webauthn_Op)(data)
	host.thread_join(op.thread)
	for x, i in webauthn_ops { if x == op { unordered_remove(&webauthn_ops, i); break } }
	defer free(op, base.process_allocator())
	p := op.page_id != 0 ? page_by_id(op.page_id) : nil
	if p == nil {
		webauthn.ceremony_destroy(op.c)
		return
	}
	if op.timer != base.NIL_HANDLE { host.clear_timer(p.loop, op.timer) }
	if op.retry != base.NIL_HANDLE { host.clear_timer(p.loop, op.retry) }
	if op.signal != 0 && op.algo != 0 { signal_remove_algorithm(p, op.signal, op.algo) }
	if d := webauthn_doc(p); d != nil && d.active == op { d.active = nil }
	defer if webauthn_embedder.changed != nil && !p.closed { webauthn_embedder.changed(p) }

	st := op.c.status
	if st.error == .Abort && op.signal != 0 {
		_, code, reason := signal_aborted(p, op.signal)
		webauthn.ceremony_destroy(op.c)
		promise_reject(p, op.promise, code != 0 ? code : WEB_ERR_ABORT, reason != "" ? reason : ABORT_REASON)
		return
	}
	if st.error != .None {
		msg := strings.clone(st.message, context.temp_allocator)
		webauthn.ceremony_destroy(op.c)
		log(p, .Warn, msg)
		promise_reject(p, op.promise, error_code(st.error), msg)
		return
	}
	h := credential_create(p, op.c, op.owner)   // the credential owns the ceremony from here
	promise_resolve_object(p, op.promise, h)
}

////////////////////////////////
// Imports

CredentialsContainer_create :: proc(c: ^Call, options: string, mediation: Api_CredentialMediation, signal: Api_AbortSignal) -> u64 {
	return webauthn_start(c, .Create, options, mediation, signal)
}

CredentialsContainer_get :: proc(c: ^Call, options: string, mediation: Api_CredentialMediation, signal: Api_AbortSignal) -> u64 {
	return webauthn_start(c, .Get, options, mediation, signal)
}

CredentialsContainer_preventSilentAccess :: proc(c: ^Call) -> u64 {
	pr := promise_create(c.page, c.owner)
	if c.page.web == nil || c.page.web.frozen { reject_later(c.page, pr, WEB_ERR_INVALID_STATE, "InvalidStateError: the document is not fully active") } else { resolve_later(c.page, pr, 0) }
	return pr
}

PublicKeyCredential_enabled :: proc(c: ^Call) -> bool { return c.page.settings.authn.enabled && c.page.env.secure_context }

@(private="file")
Caps_Kind :: enum u8 { UVPAA, Capabilities }

@(private="file")
Caps_Job :: struct {
	page:     u64,
	promise:  u64,
	kind:     Caps_Kind,
	settings: webauthn.Settings,   // a copy without the owned lists
	caps:     webauthn.Capabilities,
	has_platform: bool,
}

// The capabilities ask the platform (WebAuthNIsUserVerifyingPlatformAuthenticatorAvailable may take a while): on the
// blocking pool, never on the UI thread.
@(private="file")
caps_start :: proc(c: ^Call, kind: Caps_Kind) -> u64 {
	p := c.page
	pr := promise_create(p, c.owner)
	j := new(Caps_Job, base.process_allocator())
	j^ = Caps_Job{page = page_id(p), promise = pr, kind = kind, settings = p.settings.authn}
	j.settings.enterprise_rp_ids = nil
	work :: proc(data: rawptr) {
		j := (^Caps_Job)(data)
		if !j.settings.enabled { return }
		pl := webauthn.platform_for(&j.settings)
		if pl == nil { return }
		j.caps, j.has_platform = pl.capabilities(pl), true
	}
	done :: proc(data: rawptr) {
		j := (^Caps_Job)(data)
		defer free(j, base.process_allocator())
		pg := page_by_id(j.page)
		if pg == nil { return }
		s := &j.settings
		switch j.kind {
		case .UVPAA:
			promise_resolve(pg, j.promise, j.has_platform && s.allow_platform && j.caps.user_verifying_platform ? 1 : 0)
		case .Capabilities:
			promise_resolve(pg, j.promise, 0, capabilities_json(j, context.temp_allocator))
		}
	}
	if p.loader != nil && p.loader.blocking != nil {
		host.run_blocking(p.loader.blocking, work, done, j)
	} else {
		work(j)
		host.post(p.loop, done, j)
	}
	return pr
}

// getClientCapabilities() (§5.1.7): the record, keys in ascending order.
@(private="file")
capabilities_json :: proc(j: ^Caps_Job, allocator := context.allocator) -> string {
	s := &j.settings
	on := j.has_platform
	Entry :: struct { key: string, value: bool }
	entries := make([dynamic]Entry, context.temp_allocator)
	append(&entries,
		Entry{"conditionalCreate", false},
		Entry{"conditionalGet", on && j.caps.conditional_get},
		Entry{"hybridTransport", on && s.allow_hybrid && j.caps.hybrid},
		Entry{"passkeyPlatformAuthenticator", on && s.allow_platform && j.caps.passkey_platform},
		Entry{"relatedOrigins", false},
		Entry{"signalAllAcceptedCredentials", false},
		Entry{"signalCurrentUserDetails", false},
		Entry{"signalUnknownCredential", false},
		Entry{"userVerifyingPlatformAuthenticator", on && s.allow_platform && j.caps.user_verifying_platform},
	)
	if on {
		for x in webauthn.Platform_Extension {
			if x in j.caps.extensions { append(&entries, Entry{strings.concatenate({"extension:", webauthn.EXTENSION_NAMES[x]}, context.temp_allocator), true}) }
		}
	}
	// insertion sort: a dozen keys
	for i in 1 ..< len(entries) {
		for k := i; k > 0 && entries[k].key < entries[k - 1].key; k -= 1 { entries[k], entries[k - 1] = entries[k - 1], entries[k] }
	}
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '{')
	for e, i in entries {
		if i > 0 { strings.write_byte(&b, ',') }
		strings.write_byte(&b, '"'); strings.write_string(&b, e.key); strings.write_string(&b, `":`)
		strings.write_string(&b, e.value ? "true" : "false")
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

PublicKeyCredential_isUserVerifyingPlatformAuthenticatorAvailable :: proc(c: ^Call) -> u64 { return caps_start(c, .UVPAA) }

PublicKeyCredential_isConditionalMediationAvailable :: proc(c: ^Call) -> u64 {
	pr := promise_create(c.page, c.owner)
	resolve_later(c.page, pr, 0)
	return pr
}

PublicKeyCredential_getClientCapabilities :: proc(c: ^Call) -> u64 { return caps_start(c, .Capabilities) }

PublicKeyCredential_checkRpId :: proc(c: ^Call, rp_id: string) -> Api_Error {
	caller := webauthn.caller_of(c.page.env.origin, c.page.env.secure_context, context.temp_allocator)
	if _, st := webauthn.resolve_rp_id(caller, rp_id, true, context.temp_allocator); st.error != .None {
		return fail(c, st.error == .Security ? .Security : .Not_Allowed, st.message)
	}
	return .None
}

PublicKeyCredential_isAssertion :: proc(c: ^Call, credential: Api_PublicKeyCredential) -> bool { return credential.data.c.result.kind == .Get }

PublicKeyCredential_id :: proc(c: ^Call, credential: Api_PublicKeyCredential) -> string { return credential.data.id }

PublicKeyCredential_bytes :: proc(c: ^Call, credential: Api_PublicKeyCredential, which: Api_CredentialBytes) -> (u64, Api_Error) {
	w := credential.data
	r := &w.c.result
	b: []byte
	ok := true
	switch which {
	case .Raw_Id: b = r.raw_id
	case .Client_Data_JSON: b = r.client_data_json
	case .Attestation_Object: b, ok = r.attestation_object, r.kind == .Create
	case .Authenticator_Data:
		b = r.authenticator_data
		if r.kind == .Create && w.has_facts { b = w.facts.auth_data }
	case .Signature: b, ok = r.signature, r.kind == .Get
	case .User_Handle: b, ok = r.user_handle, r.kind == .Get && r.has_user_handle
	case .Public_Key: b, ok = w.facts.public_key, w.has_facts && w.facts.has_public_key
	}
	if !ok { return 0, .Not_Found }
	h := buffer_create(c.page, b, c.owner)
	if h == 0 { return 0, fail(c, .Quota, "QuotaExceededError: page memory limit") }
	return h, .None
}

PublicKeyCredential_authenticatorAttachment :: proc(c: ^Call, credential: Api_PublicKeyCredential) -> (string, Api_Error) {
	a := credential.data.c.result.attachment
	if a == .Any { return "", .Not_Found }
	return webauthn.attachment_name(a), .None
}

PublicKeyCredential_transports :: proc(c: ^Call, credential: Api_PublicKeyCredential) -> string {
	return strings.join(webauthn.transport_names(credential.data.c.result.transports, context.temp_allocator), ",", context.temp_allocator)
}

PublicKeyCredential_publicKeyAlgorithm :: proc(c: ^Call, credential: Api_PublicKeyCredential) -> i32 {
	w := credential.data
	return w.has_facts ? i32(w.facts.algorithm) : 0
}

PublicKeyCredential_clientExtensionResults :: proc(c: ^Call, credential: Api_PublicKeyCredential) -> string { return credential.data.ext_json }

PublicKeyCredential_toJSON :: proc(c: ^Call, credential: Api_PublicKeyCredential) -> string { return credential.data.json }

