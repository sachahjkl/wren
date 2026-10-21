// Headless end-to-end test of Web Authentication in pages, on the virtual authenticator (the system's needs a person):
// navigator.credentials.create() then get() from JavaScript, the signature of the assertion verified here with the
// public key the page got from getPublicKey(); the client's rules as a page sees them (activation, RP ID, secure
// context, one ceremony at a time, mediation, aborts, the lifetime timer, excludeCredentials); parse*FromJSON, toJSON,
// getClientExtensionResults. No server, no window. Run from the repository root:
//   webauthntest.exe
package webauthntest

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:js"
import "wb:net"
import "wb:page"
import "wb:wasm"
import "wb:webauthn"
import "wb:tools/testenv"

failures: int
passes: int
logs: [dynamic]string

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok { passes += 1; fmt.printf("PASS %s\n", what) } else { fmt.printf("FAIL %s  (line %d)\n", what, loc.line); failures += 1 }
}

console :: proc(user: rawptr, level: page.Log_Level, message: string) {
	append(&logs, strings.clone(message))
	if level == .Error { fmt.printf("  [%v] %s\n", level, message) }
}

logged :: proc(text: string) -> bool {
	for l in logs { if l == text { return true } }
	return false
}

logged_prefix :: proc(prefix: string) -> string {
	for i := len(logs) - 1; i >= 0; i -= 1 { if strings.has_prefix(logs[i], prefix) { return logs[i] } }
	return ""
}

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
settings: page.Settings

pump :: proc(ms: f64, until := "") {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < ms {
		if until != "" && logged_prefix(until) != "" { return }
		host.loop_wait(&loop, 2)
	}
}

open :: proc(process: ^base.Scope, address: string, source := PAGE) -> ^page.Page {
	p := page.page_create(&loop, &loader, &settings, process, address, console)
	page.load_html(p, transmute([]byte)source)
	page.scripts_start(p)
	pump(5000, "loaded")
	return p
}

run :: proc(p: ^page.Page, src: string) { page.js_run(p, transmute([]byte)src, "probe.js") }

// A click in the page: what gives it transient activation.
click :: proc(p: ^page.Page) {
	page.dispatch_event(p, p.body, dom.Event{type = "mousedown", bubbles = true, cancelable = true})
}

// Runs `src` (which must end by logging `prefix ...`) and waits for it.
ask :: proc(p: ^page.Page, prefix, src: string, ms := 5000.0) -> string {
	run(p, src)
	pump(ms, prefix)
	return logged_prefix(prefix)
}

PAGE :: `<!doctype html><title>login</title><body><button id=b>Login with Passkey</button>
<script>
const b64 = (buf) => { const u = new Uint8Array(buf); let s = ''; for (const x of u) s += String.fromCharCode(x); return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); };
const bytes = (s) => new TextEncoder().encode(s);
const show = (prefix) => [(v) => console.log(prefix + ' ok ' + (v === null ? 'null' : v.constructor.name)), (e) => console.log(prefix + ' err ' + (e && e.name) + ' ' + (e && e.message))];
const createOptions = (extra) => Object.assign({
  rp: { name: 'Example', id: 'example.com' },
  user: { id: bytes('user-42'), name: 'alice@example.com', displayName: 'Alice' },
  challenge: new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]),
  pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
  authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
  extensions: { credProps: true },
}, extra || {});
addEventListener('load', () => console.log('loaded'));
</script>`

main :: proc() {
	context = testenv.context_of_process()
	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings = page.settings_default()
	settings.authn.virtual = true
	wasm.configure_from_args(os.args[1:])
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }
	js.cache_start({memory_bytes = 16 << 20, min_source_bytes = 0})
	process := base.scope_make("process")
	webauthn.virtual_reset()

	p := open(process, "https://login.example.com/admin/login")
	check(logged("loaded"), "the page loads")

	// what a page detects
	s := ask(p, "detect ", `Promise.all([PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(), PublicKeyCredential.isConditionalMediationAvailable(), PublicKeyCredential.getClientCapabilities()])
		.then(([uv, cond, caps]) => console.log('detect ' + [typeof navigator.credentials.get, navigator.credentials === navigator.credentials, navigator.credentials instanceof CredentialsContainer, uv, cond, caps.userVerifyingPlatformAuthenticator, caps.conditionalGet, caps['extension:credProps'], Object.keys(caps)[0]].join(' ')))`)
	check(s == "detect function true true true false true false true conditionalCreate", fmt.tprintf("navigator.credentials, UVPAA, no conditional mediation, capabilities (%s)", s))

	// no activation: refused
	s = ask(p, "noact ", `navigator.credentials.create({ publicKey: createOptions() }).then(...show('noact'))`)
	check(strings.has_prefix(s, "noact err NotAllowedError"), fmt.tprintf("create() without a click: NotAllowedError (%s)", s))

	// malformed options: TypeError whatever the user did
	s = ask(p, "bad ", `navigator.credentials.create({ publicKey: { rp: { name: 'x' }, user: { id: new Uint8Array(65), name: 'u', displayName: 'U' }, challenge: new Uint8Array(4), pubKeyCredParams: [] } }).then(...show('bad'))`)
	check(strings.has_prefix(s, "bad err TypeError"), fmt.tprintf("user.id of 65 bytes: TypeError (%s)", s))
	s = ask(p, "bad2 ", `navigator.credentials.create({ publicKey: { rp: { name: 'x' }, user: { id: new Uint8Array(4), name: 'u', displayName: 'U' }, pubKeyCredParams: [] } }).then(...show('bad2'))`)
	check(strings.has_prefix(s, "bad2 err TypeError"), fmt.tprintf("no challenge: TypeError (%s)", s))
	s = ask(p, "none ", `navigator.credentials.create({}).then(...show('none'))`)
	check(strings.has_prefix(s, "none err NotSupportedError"), fmt.tprintf("no credential type: NotSupportedError (%s)", s))

	// a foreign RP ID
	click(p)
	s = ask(p, "rp ", `navigator.credentials.create({ publicKey: createOptions({ rp: { name: 'x', id: 'evil.com' } }) }).then(...show('rp'))`)
	check(strings.has_prefix(s, "rp err SecurityError"), fmt.tprintf("rp.id evil.com from login.example.com: SecurityError (%s)", s))
	click(p)
	s = ask(p, "rp2 ", `navigator.credentials.create({ publicKey: createOptions({ rp: { name: 'x', id: 'com' } }) }).then(...show('rp2'))`)
	check(strings.has_prefix(s, "rp2 err SecurityError"), fmt.tprintf("rp.id com (a public suffix): SecurityError (%s)", s))

	// create
	click(p)
	s = ask(p, "created ", `navigator.credentials.create({ publicKey: createOptions() }).then((c) => {
		window.cred = c;
		const r = c.response, cd = JSON.parse(new TextDecoder().decode(r.clientDataJSON)), j = c.toJSON();
		console.log('pk ' + b64(r.getPublicKey()));
		console.log('created ' + [c instanceof PublicKeyCredential, c.type, c.id === b64(c.rawId), c.rawId === c.rawId, c.response === c.response,
			r instanceof AuthenticatorAttestationResponse, cd.type, cd.challenge, cd.origin, cd.crossOrigin, r.getTransports().join(','),
			r.getPublicKeyAlgorithm(), r.getPublicKey().byteLength, r.getAuthenticatorData().byteLength > 37, r.attestationObject.byteLength > 100,
			c.authenticatorAttachment, c.getClientExtensionResults().credProps.rk, j.type, j.id === c.id, j.response.publicKeyAlgorithm, j.response.transports[0],
			j.clientExtensionResults.credProps.rk].join(' '));
	}, (e) => console.log('created err ' + e.name + ' ' + e.message))`)
	check(s == "created true public-key true true true true webauthn.create AQIDBAUGBwgJCgsMDQ4PEA https://login.example.com false internal -7 91 true true platform true public-key true -7 internal true",
		fmt.tprintf("create(): a PublicKeyCredential with its attestation response, clientDataJSON, getters and toJSON (%s)", s))
	spki, _ := webauthn.base64url_decode(strings.trim_prefix(logged_prefix("pk "), "pk "), context.temp_allocator)
	check(len(spki) == 91, "getPublicKey(): a P-256 SubjectPublicKeyInfo")

	// the same credential in excludeCredentials
	click(p)
	s = ask(p, "excl ", `navigator.credentials.create({ publicKey: createOptions({ excludeCredentials: [{ type: 'public-key', id: cred.rawId }] }) }).then(...show('excl'))`)
	check(strings.has_prefix(s, "excl err InvalidStateError"), fmt.tprintf("excludeCredentials with the credential: InvalidStateError (%s)", s))

	// get, and the signature checked here
	click(p)
	s = ask(p, "assert ", `navigator.credentials.get({ publicKey: { challenge: bytes('sign-in challenge'), rpId: 'example.com', allowCredentials: [{ type: 'public-key', id: cred.rawId, transports: ['internal'] }] } }).then((a) => {
		const r = a.response, cd = JSON.parse(new TextDecoder().decode(r.clientDataJSON));
		console.log('assertdata ' + b64(r.authenticatorData) + ' ' + b64(r.clientDataJSON) + ' ' + b64(r.signature));
		console.log('assert ' + [a.id === cred.id, r instanceof AuthenticatorAssertionResponse, cd.type, cd.origin, new TextDecoder().decode(r.userHandle), r.signature.byteLength > 60, a.toJSON().response.userHandle === b64(r.userHandle), a.authenticatorAttachment].join(' '));
	}, (e) => console.log('assert err ' + e.name + ' ' + e.message))`)
	check(s == "assert true true webauthn.get https://login.example.com user-42 true true platform", fmt.tprintf("get(): an assertion with the user handle (%s)", s))
	parts := strings.split(strings.trim_prefix(logged_prefix("assertdata "), "assertdata "), " ", context.temp_allocator)
	if len(parts) == 3 && len(spki) == 91 {
		ad, _ := webauthn.base64url_decode(parts[0], context.temp_allocator)
		cdj, _ := webauthn.base64url_decode(parts[1], context.temp_allocator)
		sig, _ := webauthn.base64url_decode(parts[2], context.temp_allocator)
		h := webauthn.sha256(cdj)
		msg := strings.concatenate({string(ad), string(h[:])}, context.temp_allocator)
		check(webauthn.es256_verify(spki[27:59], spki[59:91], transmute([]byte)msg, sig), "the assertion's signature verifies with getPublicKey()'s key")
		rp := webauthn.sha256(transmute([]byte)string("example.com"))
		check(len(ad) == 37 && string(ad[:32]) == string(rp[:]) && ad[32] & 0x05 == 0x05, "authenticatorData: rpIdHash of example.com, UP and UV")
		check(strings.has_prefix(string(cdj), `{"type":"webauthn.get","challenge":"c2lnbi1pbiBjaGFsbGVuZ2U","origin":"https://login.example.com","crossOrigin":false}`), "clientDataJSON: exact bytes")
	} else {
		check(false, "the assertion's data reached the test")
	}

	// discoverable credentials: get() without allowCredentials
	click(p)
	s = ask(p, "disc ", `navigator.credentials.get({ publicKey: { challenge: bytes('x'), rpId: 'example.com' } }).then((a) => console.log('disc ' + (a.id === cred.id)), (e) => console.log('disc err ' + e.name))`)
	check(s == "disc true", fmt.tprintf("get() without allowCredentials finds the passkey (%s)", s))

	// another site's RP ID has nothing
	click(p)
	s = ask(p, "other ", `navigator.credentials.get({ publicKey: { challenge: bytes('x') } }).then(...show('other'))`)
	check(strings.has_prefix(s, "other err NotAllowedError"), fmt.tprintf("no credential for login.example.com: NotAllowedError (%s)", s))

	// mediation
	s = ask(p, "silent ", `navigator.credentials.get({ mediation: 'silent', publicKey: { challenge: bytes('x') } }).then(...show('silent'))`)
	check(s == "silent ok null", fmt.tprintf("silent mediation: null without asking (%s)", s))
	s = ask(p, "cond ", `navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: bytes('x') } }).then(...show('cond'))`)
	check(strings.has_prefix(s, "cond err TypeError"), fmt.tprintf("conditional mediation: TypeError (%s)", s))

	// aborts
	s = ask(p, "pre ", `navigator.credentials.get({ signal: AbortSignal.abort('stop'), publicKey: { challenge: bytes('x') } }).then(() => console.log('pre ok'), (e) => console.log('pre ' + e))`)
	check(s == "pre stop", fmt.tprintf("an aborted signal: the reason (%s)", s))
	settings.authn.virtual_delay_ms = 3000
	click(p)
	run(p, `window.ac = new AbortController(); window.t0 = performance.now(); navigator.credentials.get({ signal: ac.signal, publicKey: { challenge: bytes('x'), rpId: 'example.com' } }).then(() => console.log('abort resolved'), (e) => console.log('abort ' + (e === 'gone') + ' ' + (performance.now() - t0 < 2500)))`)
	pump(100)
	busy, _, rp_id := page.webauthn_pending(p)
	check(busy && rp_id == "example.com", "the shell sees the pending request and its RP ID")
	check(.Request_In_Flight in page.bfcache_blockers(p), "a page waiting for a passkey cannot go into the back/forward cache")
	click(p)
	s = ask(p, "second ", `navigator.credentials.get({ publicKey: { challenge: bytes('y'), rpId: 'example.com' } }).then(...show('second'))`)
	check(strings.has_prefix(s, "second err NotAllowedError"), fmt.tprintf("a second ceremony while one runs: NotAllowedError (%s)", s))
	s = ask(p, "abort ", `ac.abort('gone')`)
	check(s == "abort true true", fmt.tprintf("abort() during the ceremony: the reason, at once (%s)", s))
	busy, _, _ = page.webauthn_pending(p)
	check(!busy, "nothing pending afterwards")

	// the lifetime timer
	settings.authn.timeout_min_ms = 300
	click(p)
	s = ask(p, "timer ", `window.t1 = performance.now(); navigator.credentials.get({ publicKey: { challenge: bytes('x'), rpId: 'example.com', timeout: 1 } }).then(() => console.log('timer ok'), (e) => console.log('timer err ' + e.name + ' ' + (performance.now() - t1 < 2500)))`)
	check(s == "timer err NotAllowedError true", fmt.tprintf("the lifetime timer (raised to security.webauthn.timeout.min_ms): NotAllowedError (%s)", s))
	settings.authn.virtual_delay_ms = 0
	settings.authn.timeout_min_ms = 300_000

	// the user declines
	settings.authn.virtual_mode = .Decline
	click(p)
	s = ask(p, "decline ", `navigator.credentials.get({ publicKey: { challenge: bytes('x'), rpId: 'example.com' } }).then(...show('decline'))`)
	check(strings.has_prefix(s, "decline err NotAllowedError"), fmt.tprintf("the user declines: NotAllowedError (%s)", s))
	settings.authn.virtual_mode = .Accept

	// JSON forms
	s = ask(p, "json ", `const o = PublicKeyCredential.parseCreationOptionsFromJSON({ rp: { name: 'R' }, user: { id: 'dXNlcg', name: 'u', displayName: 'U' }, challenge: 'AQID', pubKeyCredParams: [{ type: 'public-key', alg: -7 }], excludeCredentials: [{ type: 'public-key', id: 'BAUG' }], extensions: { prf: { eval: { first: 'AA' } }, credProps: true } });
		const q = PublicKeyCredential.parseRequestOptionsFromJSON({ challenge: 'AQID', allowCredentials: [{ type: 'public-key', id: 'BAUG', transports: ['usb'] }] });
		let enc = ''; try { PublicKeyCredential.parseRequestOptionsFromJSON({ challenge: 'A*' }) } catch (e) { enc = e.name }
		console.log('json ' + [o.user.id instanceof ArrayBuffer, new TextDecoder().decode(o.user.id), o.challenge.byteLength, o.excludeCredentials[0].id.byteLength, o.extensions.prf.eval.first.byteLength, o.extensions.credProps,
			o.attestation, o.hints.length, q.allowCredentials[0].transports[0], q.userVerification, enc].join(' '))`)
	check(s == "json true user 3 3 1 true none 0 usb preferred EncodingError", fmt.tprintf("parseCreationOptionsFromJSON / parseRequestOptionsFromJSON (%s)", s))
	click(p)
	s = ask(p, "roundtrip2 ", `navigator.credentials.get({ publicKey: PublicKeyCredential.parseRequestOptionsFromJSON({ challenge: 'AQID', rpId: 'example.com' }) }).then((a) => { const j = a.toJSON(); console.log('roundtrip2 ' + [j.type, typeof j.response.signature, typeof j.response.clientDataJSON, JSON.stringify(j.clientExtensionResults)].join(' ')) }, (e) => console.log('roundtrip2 err ' + e.name))`)
	check(s == "roundtrip2 public-key string string {}", fmt.tprintf("options from JSON into get(), toJSON() of the answer (%s)", s))

	// store / preventSilentAccess / signals
	s = ask(p, "store ", `navigator.credentials.store(cred).then(...show('store'))`)
	check(strings.has_prefix(s, "store err NotSupportedError"), fmt.tprintf("store(a PublicKeyCredential): NotSupportedError (%s)", s))
	s = ask(p, "psa ", `navigator.credentials.preventSilentAccess().then((v) => console.log('psa ' + v))`)
	check(s == "psa undefined", "preventSilentAccess() resolves")
	s = ask(p, "sig ", `Promise.all([PublicKeyCredential.signalUnknownCredential({ rpId: 'example.com', credentialId: 'AQID' }).then(() => 'ok', (e) => e.name),
		PublicKeyCredential.signalUnknownCredential({ rpId: 'evil.com', credentialId: 'AQID' }).then(() => 'ok', (e) => e.name),
		PublicKeyCredential.signalCurrentUserDetails({ rpId: 'example.com', userId: '*', name: 'a', displayName: 'b' }).then(() => 'ok', (e) => e.name)]).then((r) => console.log('sig ' + r.join(' ')))`)
	check(s == "sig ok SecurityError TypeError", fmt.tprintf("signal methods: RP ID and base64url checked (%s)", s))
	s = ask(p, "illegal ", `let n = ''; try { new PublicKeyCredential() } catch (e) { n = e.name } console.log('illegal ' + n + ' ' + Object.getPrototypeOf(PublicKeyCredential.prototype).constructor.name)`)
	check(s == "illegal TypeError Credential", fmt.tprintf("PublicKeyCredential has no constructor and inherits from Credential (%s)", s))

	// a system dialog that ignores the cancellation: the page is answered after security.webauthn.cancel_grace_ms
	settings.authn.virtual_mode, settings.authn.virtual_delay_ms, settings.authn.cancel_grace_ms = .Stuck, 2500, 300
	click(p)
	s = ask(p, "stuck ", `window.ac2 = new AbortController(); window.t2 = performance.now(); navigator.credentials.get({ signal: ac2.signal, publicKey: { challenge: bytes('x'), rpId: 'example.com' } }).then(() => console.log('stuck ok'), (e) => console.log('stuck ' + e + ' ' + (performance.now() - t2 < 2000))); setTimeout(() => ac2.abort('late'), 50)`)
	check(s == "stuck late true", fmt.tprintf("an abort the platform ignores: the reason after the grace period, not after the dialog (%s)", s))
	busy, _, _ = page.webauthn_pending(p)
	check(!busy && page.webauthn_in_flight() == 1, "the page may start another request; the platform call is left to finish")
	start0 := time.tick_now()
	for page.webauthn_in_flight() > 0 && time.duration_milliseconds(time.tick_since(start0)) < 5000 { host.loop_wait(&loop, 5) }
	check(page.webauthn_in_flight() == 0, "... and its thread is joined when it does")
	settings.authn.virtual_mode, settings.authn.virtual_delay_ms, settings.authn.cancel_grace_ms = .Accept, 0, 3000

	// the page closes with a ceremony pending: cancelled, nothing leaks
	settings.authn.virtual_delay_ms = 3000
	click(p)
	run(p, `navigator.credentials.get({ publicKey: { challenge: bytes('x'), rpId: 'example.com' } })`)
	pump(50)
	page.page_close(p)
	check(page.webauthn_in_flight() == 1, "the ceremony's thread still runs right after the page closed")
	start := time.tick_now()
	for page.webauthn_in_flight() > 0 && time.duration_milliseconds(time.tick_since(start)) < 2500 { host.loop_wait(&loop, 5) }
	check(page.webauthn_in_flight() == 0, fmt.tprintf("closing the page cancels its ceremony: the thread is done in %.0f ms, not after the user's 3 s", time.duration_milliseconds(time.tick_since(start))))
	settings.authn.virtual_delay_ms = 0

	// insecure context: absent
	q := open(process, "http://example.com/")
	s = ask(q, "insecure ", `console.log('insecure ' + [typeof navigator.credentials, typeof PublicKeyCredential, isSecureContext].join(' '))`)
	check(s == "insecure undefined undefined false", fmt.tprintf("not a secure context: no navigator.credentials, no PublicKeyCredential (%s)", s))
	page.page_close(q)

	// localhost is a secure context and its own RP ID
	l := open(process, "http://localhost:8765/webauthn/")
	click(l)
	s = ask(l, "local ", `navigator.credentials.create({ publicKey: createOptions({ rp: { name: 'Local' } }) }).then((c) => console.log('local ' + JSON.parse(new TextDecoder().decode(c.response.clientDataJSON)).origin), (e) => console.log('local err ' + e.name + ' ' + e.message))`)
	check(s == "local http://localhost:8765", fmt.tprintf("http://localhost: secure context, RP ID localhost (%s)", s))
	page.page_close(l)

	// turned off: absent
	settings.authn.enabled = false
	off := open(process, "https://login.example.com/")
	s = ask(off, "off ", `console.log('off ' + [typeof PublicKeyCredential, typeof navigator.credentials].join(' '))`)
	check(s == "off undefined object", fmt.tprintf("security.webauthn.enabled off: no PublicKeyCredential (%s)", s))
	page.page_close(off)
	settings.authn.enabled = true

	base.scope_close(process)
	host.blocking_settle(&blocking)
	page.process_shutdown()
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	host.loop_destroy(&loop)
	page.settings_destroy(&settings)
	for l in logs { delete(l) }
	delete(logs)
	failures += testenv.mem_check("webauthntest")
	fmt.printf("\n%d checks passed, %d failure(s)\n", passes, failures)
	os.exit(failures > 0 ? 1 : 0)
}
