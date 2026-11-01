#+private file
// Web Authentication in pages, on the virtual authenticator (the system's needs a person): navigator.credentials.create() then get()
// from JavaScript, the signature of the assertion verified here with the public key the page got from getPublicKey(); the client's
// rules as a page sees them (activation, RP ID, secure context, one ceremony at a time, mediation, aborts, the lifetime timer,
// excludeCredentials); parse*FromJSON, toJSON, getClientExtensionResults. No server.
//
// What the waits check depends on no machine's speed: a user who never answers (the longest security.webauthn.testing.virtual_delay_ms)
// leaves only the abort, the timer or the close to end a ceremony.
package webtests

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:page"
import "wb:webauthn"

SECURE :: "https://login.example.com/admin/login"
USER_NEVER_ANSWERS_MS :: 600_000
LIFETIME_MIN_MS :: 300             // the lifetime timer of a ceremony asking for less
CANCEL_GRACE_MS :: 300             // what an ignored abort waits for
SPKI_BYTES :: 91                   // a P-256 SubjectPublicKeyInfo:
SPKI_X :: 27                       // the point's X,
SPKI_Y :: 59                       // and Y
AUTH_DATA_BYTES :: 37              // no attested credential, no extensions
RP_HASH_BYTES :: 32
FLAGS_AT :: 32
FLAGS_UP_UV :: 0x05

PAGE :: `<!doctype html><title>login</title><body><button id=b>Login with Passkey</button>
<script>
const b64 = (buf) => { const u = new Uint8Array(buf); let s = ''; for (const x of u) s += String.fromCharCode(x); return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); };
const bytes = (s) => new TextEncoder().encode(s);
const show = (prefix) => [(v) => wrenTest.note(prefix + ' ok ' + (v === null ? 'null' : v.constructor.name)), (e) => wrenTest.note(prefix + ' err ' + (e && e.name) + ' ' + (e && e.message))];
const createOptions = (extra) => Object.assign({
  rp: { name: 'Example', id: 'example.com' },
  user: { id: bytes('user-42'), name: 'alice@example.com', displayName: 'Alice' },
  challenge: new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]),
  pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
  authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
  extensions: { credProps: true },
}, extra || {});
addEventListener('load', () => wrenTest.note('loaded'));
</script>`

CREATE :: `navigator.credentials.create({ publicKey: createOptions() }).then((c) => {
	window.cred = c;
	const r = c.response, cd = JSON.parse(new TextDecoder().decode(r.clientDataJSON)), j = c.toJSON();
	wrenTest.note('pk ' + b64(r.getPublicKey()));
	wrenTest.note('created ' + [c instanceof PublicKeyCredential, c.type, c.id === b64(c.rawId), c.rawId === c.rawId, c.response === c.response,
		r instanceof AuthenticatorAttestationResponse, cd.type, cd.challenge, cd.origin, cd.crossOrigin, r.getTransports().join(','),
		r.getPublicKeyAlgorithm(), r.getPublicKey().byteLength, r.getAuthenticatorData().byteLength > 37, r.attestationObject.byteLength > 100,
		c.authenticatorAttachment, c.getClientExtensionResults().credProps.rk, j.type, j.id === c.id, j.response.publicKeyAlgorithm, j.response.transports[0],
		j.clientExtensionResults.credProps.rk].join(' '));
}, (e) => wrenTest.note('created err ' + e.name + ' ' + e.message))`

CREATED :: "created true public-key true true true true webauthn.create AQIDBAUGBwgJCgsMDQ4PEA https://login.example.com false internal -7 91 true true platform true public-key true -7 internal true"

// The virtual authenticator, empty, for this test's pages. After `begin`.
authenticator :: proc() {
	settings.authn.virtual = true
	webauthn.virtual_reset()
}

open :: proc(t: ^testing.T, address: string = SECURE, loc := #caller_location) -> ^Probe {
	pr := open_page(t, "webauthn", PAGE, address)
	check(pr, wait_note(pr, "loaded", loc = loc), "the page loads", loc)
	return pr
}

// The end of the page and of the threads of its ceremonies, which use the test's settings.
shut :: proc(pr: ^Probe, min_checks: int, loc := #caller_location) {
	t := pr.t
	close_page(pr, min_checks = min_checks, loc = loc)
	ceremonies_ended(t)
}

ceremonies_ended :: proc(t: ^testing.T, loc := #caller_location) -> bool {
	return wait_until(t, "the threads of the ceremonies", 0, proc(_: int) -> bool { return page.webauthn_in_flight() == 0 }, loc = loc)
}

// A click in the page: what gives it transient activation.
click :: proc(pr: ^Probe) {
	page.dispatch_event(pr.p, pr.p.body, dom.Event{type = "mousedown", bubbles = true, cancelable = true})
}

said :: proc(pr: ^Probe, prefix: string) -> string {
	#reverse for n in pr.section.notes { if strings.has_prefix(n, prefix) { return n } }
	return ""
}

Saying :: struct { pr: ^Probe, prefix: string }

// Runs `src`, which ends by noting `prefix ...`, and waits for that: what it noted.
ask :: proc(pr: ^Probe, prefix, src: string, loc := #caller_location) -> string {
	run(pr, src, loc)
	wait_until(pr.t, prefix, Saying{pr, prefix}, proc(s: Saying) -> bool { return said(s.pr, s.prefix) != "" }, loc = loc)
	return said(pr, prefix)
}

// The page's passkey, in window.cred. One check.
a_credential :: proc(pr: ^Probe, loc := #caller_location) {
	click(pr)
	s := ask(pr, "created ", CREATE, loc)
	check(pr, s == CREATED, fmt.tprintf("create(): a PublicKeyCredential with its attestation response, clientDataJSON, getters and toJSON (%s)", s), loc)
}

// The ceremony has started: the shell can see it.
wait_pending :: proc(pr: ^Probe, loc := #caller_location) -> bool {
	return wait_until(pr.t, "the ceremony", pr, proc(pr: ^Probe) -> bool {
		busy, _, _ := page.webauthn_pending(pr.p)
		return busy
	}, loc = loc)
}

@(test)
webauthn_what_a_page_detects :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	s := ask(pr, "detect ", `Promise.all([PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(), PublicKeyCredential.isConditionalMediationAvailable(), PublicKeyCredential.getClientCapabilities()])
		.then(([uv, cond, caps]) => wrenTest.note('detect ' + [typeof navigator.credentials.get, navigator.credentials === navigator.credentials, navigator.credentials instanceof CredentialsContainer, uv, cond, caps.userVerifyingPlatformAuthenticator, caps.conditionalGet, caps['extension:credProps'], Object.keys(caps)[0]].join(' ')))`)
	check(pr, s == "detect function true true true false true false true conditionalCreate", fmt.tprintf("navigator.credentials, UVPAA, no conditional mediation, capabilities (%s)", s))
	shut(pr, min_checks = 2)
}

@(test)
webauthn_no_activation_refused :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	s := ask(pr, "noact ", `navigator.credentials.create({ publicKey: createOptions() }).then(...show('noact'))`)
	check(pr, strings.has_prefix(s, "noact err NotAllowedError"), fmt.tprintf("create() without a click: NotAllowedError (%s)", s))
	shut(pr, min_checks = 2)
}

// TypeError whatever the user did.
@(test)
webauthn_malformed_options :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	s := ask(pr, "bad ", `navigator.credentials.create({ publicKey: { rp: { name: 'x' }, user: { id: new Uint8Array(65), name: 'u', displayName: 'U' }, challenge: new Uint8Array(4), pubKeyCredParams: [] } }).then(...show('bad'))`)
	check(pr, strings.has_prefix(s, "bad err TypeError"), fmt.tprintf("user.id of 65 bytes: TypeError (%s)", s))
	s = ask(pr, "bad2 ", `navigator.credentials.create({ publicKey: { rp: { name: 'x' }, user: { id: new Uint8Array(4), name: 'u', displayName: 'U' }, pubKeyCredParams: [] } }).then(...show('bad2'))`)
	check(pr, strings.has_prefix(s, "bad2 err TypeError"), fmt.tprintf("no challenge: TypeError (%s)", s))
	s = ask(pr, "none ", `navigator.credentials.create({}).then(...show('none'))`)
	check(pr, strings.has_prefix(s, "none err NotSupportedError"), fmt.tprintf("no credential type: NotSupportedError (%s)", s))
	shut(pr, min_checks = 4)
}

@(test)
webauthn_a_foreign_rp_id :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	click(pr)
	s := ask(pr, "rp ", `navigator.credentials.create({ publicKey: createOptions({ rp: { name: 'x', id: 'evil.com' } }) }).then(...show('rp'))`)
	check(pr, strings.has_prefix(s, "rp err SecurityError"), fmt.tprintf("rp.id evil.com from login.example.com: SecurityError (%s)", s))
	click(pr)
	s = ask(pr, "rp2 ", `navigator.credentials.create({ publicKey: createOptions({ rp: { name: 'x', id: 'com' } }) }).then(...show('rp2'))`)
	check(pr, strings.has_prefix(s, "rp2 err SecurityError"), fmt.tprintf("rp.id com (a public suffix): SecurityError (%s)", s))
	shut(pr, min_checks = 3)
}

@(test)
webauthn_create :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	a_credential(pr)
	spki, _ := webauthn.base64url_decode(strings.trim_prefix(said(pr, "pk "), "pk "), context.temp_allocator)
	check(pr, len(spki) == SPKI_BYTES, "getPublicKey(): a P-256 SubjectPublicKeyInfo")
	shut(pr, min_checks = 3)
}

@(test)
webauthn_exclude_credentials :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	a_credential(pr)
	click(pr)
	s := ask(pr, "excl ", `navigator.credentials.create({ publicKey: createOptions({ excludeCredentials: [{ type: 'public-key', id: cred.rawId }] }) }).then(...show('excl'))`)
	check(pr, strings.has_prefix(s, "excl err InvalidStateError"), fmt.tprintf("excludeCredentials with the credential: InvalidStateError (%s)", s))
	shut(pr, min_checks = 3)
}

// get, and the signature checked here
@(test)
webauthn_get_and_its_signature :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	a_credential(pr)
	spki, _ := webauthn.base64url_decode(strings.trim_prefix(said(pr, "pk "), "pk "), context.temp_allocator)
	click(pr)
	s := ask(pr, "assert ", `navigator.credentials.get({ publicKey: { challenge: bytes('sign-in challenge'), rpId: 'example.com', allowCredentials: [{ type: 'public-key', id: cred.rawId, transports: ['internal'] }] } }).then((a) => {
		const r = a.response, cd = JSON.parse(new TextDecoder().decode(r.clientDataJSON));
		wrenTest.note('assertdata ' + b64(r.authenticatorData) + ' ' + b64(r.clientDataJSON) + ' ' + b64(r.signature));
		wrenTest.note('assert ' + [a.id === cred.id, r instanceof AuthenticatorAssertionResponse, cd.type, cd.origin, new TextDecoder().decode(r.userHandle), r.signature.byteLength > 60, a.toJSON().response.userHandle === b64(r.userHandle), a.authenticatorAttachment].join(' '));
	}, (e) => wrenTest.note('assert err ' + e.name + ' ' + e.message))`)
	check(pr, s == "assert true true webauthn.get https://login.example.com user-42 true true platform", fmt.tprintf("get(): an assertion with the user handle (%s)", s))
	parts := strings.split(strings.trim_prefix(said(pr, "assertdata "), "assertdata "), " ", context.temp_allocator)
	check(pr, len(parts) == 3 && len(spki) == SPKI_BYTES, "the assertion's data reached the test")
	if len(parts) == 3 && len(spki) == SPKI_BYTES {
		ad, _ := webauthn.base64url_decode(parts[0], context.temp_allocator)
		cdj, _ := webauthn.base64url_decode(parts[1], context.temp_allocator)
		sig, _ := webauthn.base64url_decode(parts[2], context.temp_allocator)
		h := webauthn.sha256(cdj)
		msg := strings.concatenate({string(ad), string(h[:])}, context.temp_allocator)
		check(pr, webauthn.es256_verify(spki[SPKI_X:SPKI_Y], spki[SPKI_Y:SPKI_BYTES], transmute([]byte)msg, sig), "the assertion's signature verifies with getPublicKey()'s key")
		rp := webauthn.sha256(transmute([]byte)string("example.com"))
		check(pr, len(ad) == AUTH_DATA_BYTES && string(ad[:RP_HASH_BYTES]) == string(rp[:]) && ad[FLAGS_AT] & FLAGS_UP_UV == FLAGS_UP_UV, "authenticatorData: rpIdHash of example.com, UP and UV")
		check(pr, strings.has_prefix(string(cdj), `{"type":"webauthn.get","challenge":"c2lnbi1pbiBjaGFsbGVuZ2U","origin":"https://login.example.com","crossOrigin":false}`), "clientDataJSON: exact bytes")
	}
	shut(pr, min_checks = 7)
}

@(test)
webauthn_discoverable_credentials :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	a_credential(pr)
	click(pr)
	s := ask(pr, "disc ", `navigator.credentials.get({ publicKey: { challenge: bytes('x'), rpId: 'example.com' } }).then((a) => wrenTest.note('disc ' + (a.id === cred.id)), (e) => wrenTest.note('disc err ' + e.name))`)
	check(pr, s == "disc true", fmt.tprintf("get() without allowCredentials finds the passkey (%s)", s))
	// another site's RP ID has nothing
	click(pr)
	s = ask(pr, "other ", `navigator.credentials.get({ publicKey: { challenge: bytes('x') } }).then(...show('other'))`)
	check(pr, strings.has_prefix(s, "other err NotAllowedError"), fmt.tprintf("no credential for login.example.com: NotAllowedError (%s)", s))
	shut(pr, min_checks = 4)
}

@(test)
webauthn_mediation :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	s := ask(pr, "silent ", `navigator.credentials.get({ mediation: 'silent', publicKey: { challenge: bytes('x') } }).then(...show('silent'))`)
	check(pr, s == "silent ok null", fmt.tprintf("silent mediation: null without asking (%s)", s))
	s = ask(pr, "cond ", `navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: bytes('x') } }).then(...show('cond'))`)
	check(pr, strings.has_prefix(s, "cond err TypeError"), fmt.tprintf("conditional mediation: TypeError (%s)", s))
	shut(pr, min_checks = 3)
}

@(test)
webauthn_aborts :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	a_credential(pr)
	s := ask(pr, "pre ", `navigator.credentials.get({ signal: AbortSignal.abort('stop'), publicKey: { challenge: bytes('x') } }).then(() => wrenTest.note('pre ok'), (e) => wrenTest.note('pre ' + e))`)
	check(pr, s == "pre stop", fmt.tprintf("an aborted signal: the reason (%s)", s))
	settings.authn.virtual_delay_ms = USER_NEVER_ANSWERS_MS
	click(pr)
	run(pr, `window.ac = new AbortController(); navigator.credentials.get({ signal: ac.signal, publicKey: { challenge: bytes('x'), rpId: 'example.com' } }).then(() => wrenTest.note('abort resolved'), (e) => wrenTest.note('abort ' + (e === 'gone')))`)
	wait_pending(pr)
	busy, _, rp_id := page.webauthn_pending(pr.p)
	check(pr, busy && rp_id == "example.com", "the shell sees the pending request and its RP ID")
	check(pr, .Request_In_Flight in page.bfcache_blockers(pr.p), "a page waiting for a passkey cannot go into the back/forward cache")
	click(pr)
	s = ask(pr, "second ", `navigator.credentials.get({ publicKey: { challenge: bytes('y'), rpId: 'example.com' } }).then(...show('second'))`)
	check(pr, strings.has_prefix(s, "second err NotAllowedError"), fmt.tprintf("a second ceremony while one runs: NotAllowedError (%s)", s))
	s = ask(pr, "abort ", `ac.abort('gone')`)
	check(pr, s == "abort true", fmt.tprintf("abort() during the ceremony: the reason, the user never answering (%s)", s))
	busy, _, _ = page.webauthn_pending(pr.p)
	check(pr, !busy, "nothing pending afterwards")
	shut(pr, min_checks = 8)
}

@(test)
webauthn_the_lifetime_timer :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	a_credential(pr)
	settings.authn.virtual_delay_ms = USER_NEVER_ANSWERS_MS
	settings.authn.timeout_min_ms = LIFETIME_MIN_MS
	click(pr)
	s := ask(pr, "timer ", `navigator.credentials.get({ publicKey: { challenge: bytes('x'), rpId: 'example.com', timeout: 1 } }).then(() => wrenTest.note('timer ok'), (e) => wrenTest.note('timer err ' + e.name))`)
	check(pr, s == "timer err NotAllowedError", fmt.tprintf("the lifetime timer (raised to security.webauthn.timeout.min_ms), the user never answering: NotAllowedError (%s)", s))
	shut(pr, min_checks = 3)
}

@(test)
webauthn_the_user_declines :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	a_credential(pr)
	settings.authn.virtual_mode = .Decline
	click(pr)
	s := ask(pr, "decline ", `navigator.credentials.get({ publicKey: { challenge: bytes('x'), rpId: 'example.com' } }).then(...show('decline'))`)
	check(pr, strings.has_prefix(s, "decline err NotAllowedError"), fmt.tprintf("the user declines: NotAllowedError (%s)", s))
	shut(pr, min_checks = 3)
}

@(test)
webauthn_json_forms :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	a_credential(pr)
	s := ask(pr, "json ", `const o = PublicKeyCredential.parseCreationOptionsFromJSON({ rp: { name: 'R' }, user: { id: 'dXNlcg', name: 'u', displayName: 'U' }, challenge: 'AQID', pubKeyCredParams: [{ type: 'public-key', alg: -7 }], excludeCredentials: [{ type: 'public-key', id: 'BAUG' }], extensions: { prf: { eval: { first: 'AA' } }, credProps: true } });
		const q = PublicKeyCredential.parseRequestOptionsFromJSON({ challenge: 'AQID', allowCredentials: [{ type: 'public-key', id: 'BAUG', transports: ['usb'] }] });
		let enc = ''; try { PublicKeyCredential.parseRequestOptionsFromJSON({ challenge: 'A*' }) } catch (e) { enc = e.name }
		wrenTest.note('json ' + [o.user.id instanceof ArrayBuffer, new TextDecoder().decode(o.user.id), o.challenge.byteLength, o.excludeCredentials[0].id.byteLength, o.extensions.prf.eval.first.byteLength, o.extensions.credProps,
			o.attestation, o.hints.length, q.allowCredentials[0].transports[0], q.userVerification, enc].join(' '))`)
	check(pr, s == "json true user 3 3 1 true none 0 usb preferred EncodingError", fmt.tprintf("parseCreationOptionsFromJSON / parseRequestOptionsFromJSON (%s)", s))
	click(pr)
	s = ask(pr, "roundtrip2 ", `navigator.credentials.get({ publicKey: PublicKeyCredential.parseRequestOptionsFromJSON({ challenge: 'AQID', rpId: 'example.com' }) }).then((a) => { const j = a.toJSON(); wrenTest.note('roundtrip2 ' + [j.type, typeof j.response.signature, typeof j.response.clientDataJSON, JSON.stringify(j.clientExtensionResults)].join(' ')) }, (e) => wrenTest.note('roundtrip2 err ' + e.name))`)
	check(pr, s == "roundtrip2 public-key string string {}", fmt.tprintf("options from JSON into get(), toJSON() of the answer (%s)", s))
	shut(pr, min_checks = 4)
}

@(test)
webauthn_store_silent_access_and_signals :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	a_credential(pr)
	s := ask(pr, "store ", `navigator.credentials.store(cred).then(...show('store'))`)
	check(pr, strings.has_prefix(s, "store err NotSupportedError"), fmt.tprintf("store(a PublicKeyCredential): NotSupportedError (%s)", s))
	s = ask(pr, "psa ", `navigator.credentials.preventSilentAccess().then((v) => wrenTest.note('psa ' + v))`)
	check(pr, s == "psa undefined", "preventSilentAccess() resolves")
	s = ask(pr, "sig ", `Promise.all([PublicKeyCredential.signalUnknownCredential({ rpId: 'example.com', credentialId: 'AQID' }).then(() => 'ok', (e) => e.name),
		PublicKeyCredential.signalUnknownCredential({ rpId: 'evil.com', credentialId: 'AQID' }).then(() => 'ok', (e) => e.name),
		PublicKeyCredential.signalCurrentUserDetails({ rpId: 'example.com', userId: '*', name: 'a', displayName: 'b' }).then(() => 'ok', (e) => e.name)]).then((r) => wrenTest.note('sig ' + r.join(' ')))`)
	check(pr, s == "sig ok SecurityError TypeError", fmt.tprintf("signal methods: RP ID and base64url checked (%s)", s))
	s = ask(pr, "illegal ", `let n = ''; try { new PublicKeyCredential() } catch (e) { n = e.name } wrenTest.note('illegal ' + n + ' ' + Object.getPrototypeOf(PublicKeyCredential.prototype).constructor.name)`)
	check(pr, s == "illegal TypeError Credential", fmt.tprintf("PublicKeyCredential has no constructor and inherits from Credential (%s)", s))
	shut(pr, min_checks = 6)
}

// A system dialog that ignores the cancellation: the page is answered after security.webauthn.cancel_grace_ms.
@(test)
webauthn_an_abort_the_platform_ignores :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	a_credential(pr)
	testing.expect(t, ceremonies_ended(t), "the first ceremony's thread is joined: the count below is this one's")
	settings.authn.virtual_mode, settings.authn.virtual_delay_ms, settings.authn.cancel_grace_ms = .Stuck, USER_NEVER_ANSWERS_MS, CANCEL_GRACE_MS
	click(pr)
	run(pr, `window.ac2 = new AbortController(); navigator.credentials.get({ signal: ac2.signal, publicKey: { challenge: bytes('x'), rpId: 'example.com' } }).then(() => wrenTest.note('stuck ok'), (e) => wrenTest.note('stuck ' + e))`)
	// (the abort comes once the dialog is up: earlier, the ceremony's thread would stop before showing it)
	wait_until(t, "the dialog", 0, proc(_: int) -> bool { return webauthn.virtual_stuck_waiting() > 0 })
	s := ask(pr, "stuck ", `ac2.abort('late')`)
	check(pr, s == "stuck late", fmt.tprintf("an abort the platform ignores: the reason after the grace period, not after the dialog (%s)", s))
	busy, _, _ := page.webauthn_pending(pr.p)
	check(pr, !busy && page.webauthn_in_flight() == 1, "the page may start another request; the platform call is left to finish")
	webauthn.virtual_release_stuck()
	check(pr, ceremonies_ended(t), "... and its thread is joined when it does")
	shut(pr, min_checks = 5)
}

// The page closes with a ceremony pending: cancelled, nothing leaks.
@(test)
webauthn_the_page_closes_during_a_ceremony :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t)
	a_credential(pr)
	testing.expect(t, ceremonies_ended(t), "the first ceremony's thread is joined: the count below is this one's")
	settings.authn.virtual_delay_ms = USER_NEVER_ANSWERS_MS
	click(pr)
	run(pr, `navigator.credentials.get({ publicKey: { challenge: bytes('x'), rpId: 'example.com' } })`)
	wait_pending(pr)
	close_page(pr, min_checks = 2)
	testing.expect(t, page.webauthn_in_flight() == 1, "the ceremony's thread still runs right after the page closed")
	testing.expect(t, ceremonies_ended(t), "closing the page cancels its ceremony: the thread is done, the user never answering")
}

@(test)
webauthn_not_a_secure_context :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t, "http://example.com/")
	s := ask(pr, "insecure ", `wrenTest.note('insecure ' + [typeof navigator.credentials, typeof PublicKeyCredential, isSecureContext].join(' '))`)
	check(pr, s == "insecure undefined undefined false", fmt.tprintf("not a secure context: no navigator.credentials, no PublicKeyCredential (%s)", s))
	shut(pr, min_checks = 2)
}

// localhost is a secure context and its own RP ID.
@(test)
webauthn_localhost :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	pr := open(t, "http://localhost:8765/webauthn/")
	click(pr)
	s := ask(pr, "local ", `navigator.credentials.create({ publicKey: createOptions({ rp: { name: 'Local' } }) }).then((c) => wrenTest.note('local ' + JSON.parse(new TextDecoder().decode(c.response.clientDataJSON)).origin), (e) => wrenTest.note('local err ' + e.name + ' ' + e.message))`)
	check(pr, s == "local http://localhost:8765", fmt.tprintf("http://localhost: secure context, RP ID localhost (%s)", s))
	shut(pr, min_checks = 2)
}

@(test)
webauthn_turned_off :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t)
	defer end()
	authenticator()
	settings.authn.enabled = false
	pr := open(t, "https://login.example.com/")
	s := ask(pr, "off ", `wrenTest.note('off ' + [typeof PublicKeyCredential, typeof navigator.credentials].join(' '))`)
	check(pr, s == "off undefined object", fmt.tprintf("security.webauthn.enabled off: no PublicKeyCredential (%s)", s))
	shut(pr, min_checks = 2)
}
