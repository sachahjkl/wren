#+build linux
package webauthn

// Linux: security keys over USB HID and NFC by libfido2 (Yubico's CTAP2 library), loaded at run time with dlopen so the
// browser runs without it (navigator.credentials then answers NotAllowedError, as a Windows without webauthn.dll).
// This platform speaks CTAP2 directly to the key: it builds the FIDO credential / assertion from the request the client
// prepared (the effective RP ID, the clientDataJSON whose SHA-256 the key signs, the algorithms, the allow / exclude
// lists), runs the blocking call on the caller's own thread, and turns the key's answer into the authenticatorData,
// attestation object (CBOR), signature and user handle the response layer expects. The "hybrid" transport (a phone) is
// not here: that is a later, separate transport.
//
// The key's PIN: when the key has one and the request does not discourage user verification (Chrome's rule), the
// browser asks the person for it (pin.odin) before the key is touched; a wrong PIN is asked again with the tries left.
// The PRF extension goes to the key as hmac-secret, its salts SHA-256("WebAuthn PRF" || 0x00 || input) (WebAuthn
// §10.1.4); with evalByCredential and several allowed credentials, a silent probe (no touch) finds the one the key
// holds first, so that its own salts are sent. With an empty allow list and several passkeys of the site on the key,
// the first one the key gives is used (no account picker yet).

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "wb:base"

@(private = "file")
FIDO_OK :: 0
@(private = "file") FIDO_ERR_PIN_INVALID :: 0x31
@(private = "file") FIDO_ERR_PIN_BLOCKED :: 0x32
@(private = "file") FIDO_ERR_PIN_AUTH_BLOCKED :: 0x34
@(private = "file") FIDO_ERR_PIN_NOT_SET :: 0x35
@(private = "file") FIDO_ERR_NO_CREDENTIALS :: 0x2e
@(private = "file") FIDO_EXT_HMAC_SECRET :: 0x01
@(private = "file")
FIDO_ERR_PIN_REQUIRED :: 0x36
@(private = "file")
FIDO_ERR_UP_REQUIRED :: 0x37
@(private = "file")
FIDO_ERR_RX :: -14            // (negative libfido2 transport errors: a cancel lands here too)

// COSE_ES256 etc. are shared constants; libfido2 uses the same numbers.

@(private = "file")
Fido2_Lib :: struct {
	handle: posix.Symbol_Table,
	// init
	fido_init:              proc "c" (flags: c.int),
	// device discovery
	fido_dev_info_new:      proc "c" (n: c.size_t) -> rawptr,
	fido_dev_info_free:     proc "c" (p: ^rawptr, n: c.size_t),
	fido_dev_info_manifest: proc "c" (p: rawptr, n: c.size_t, olen: ^c.size_t) -> c.int,
	fido_dev_info_ptr:      proc "c" (p: rawptr, i: c.size_t) -> rawptr,
	fido_dev_info_path:     proc "c" (di: rawptr) -> cstring,
	// device
	fido_dev_new:           proc "c" () -> rawptr,
	fido_dev_free:          proc "c" (p: ^rawptr),
	fido_dev_open:          proc "c" (dev: rawptr, path: cstring) -> c.int,
	fido_dev_close:         proc "c" (dev: rawptr) -> c.int,
	fido_dev_cancel:        proc "c" (dev: rawptr) -> c.int,
	fido_dev_has_pin:       proc "c" (dev: rawptr) -> b32,
	fido_dev_is_fido2:      proc "c" (dev: rawptr) -> b32,
	fido_dev_get_retry_count: proc "c" (dev: rawptr, retries: ^c.int) -> c.int,
	// credential (make)
	fido_cred_new:          proc "c" () -> rawptr,
	fido_cred_free:         proc "c" (p: ^rawptr),
	fido_cred_set_type:     proc "c" (cred: rawptr, cose_alg: c.int) -> c.int,
	fido_cred_set_clientdata_hash: proc "c" (cred: rawptr, ptr: [^]u8, len: c.size_t) -> c.int,
	fido_cred_set_rp:       proc "c" (cred: rawptr, id, name: cstring) -> c.int,
	fido_cred_set_user:     proc "c" (cred: rawptr, user_id: [^]u8, user_id_len: c.size_t, name, display_name, icon: cstring) -> c.int,
	fido_cred_set_rk:       proc "c" (cred: rawptr, rk: c.int) -> c.int,
	fido_cred_set_uv:       proc "c" (cred: rawptr, uv: c.int) -> c.int,
	fido_cred_set_extensions: proc "c" (cred: rawptr, flags: c.int) -> c.int,
	fido_cred_exclude:      proc "c" (cred: rawptr, id: [^]u8, len: c.size_t) -> c.int,
	fido_cred_authdata_raw_ptr: proc "c" (cred: rawptr) -> [^]u8,
	fido_cred_authdata_raw_len: proc "c" (cred: rawptr) -> c.size_t,
	fido_cred_attstmt_ptr:  proc "c" (cred: rawptr) -> [^]u8,
	fido_cred_attstmt_len:  proc "c" (cred: rawptr) -> c.size_t,
	fido_cred_fmt:          proc "c" (cred: rawptr) -> cstring,
	fido_cred_id_ptr:       proc "c" (cred: rawptr) -> [^]u8,
	fido_cred_id_len:       proc "c" (cred: rawptr) -> c.size_t,
	fido_dev_make_cred:     proc "c" (dev, cred: rawptr, pin: cstring) -> c.int,
	// assertion (get)
	fido_assert_new:        proc "c" () -> rawptr,
	fido_assert_free:       proc "c" (p: ^rawptr),
	fido_assert_set_clientdata_hash: proc "c" (a: rawptr, ptr: [^]u8, len: c.size_t) -> c.int,
	fido_assert_set_rp:     proc "c" (a: rawptr, id: cstring) -> c.int,
	fido_assert_allow_cred: proc "c" (a: rawptr, id: [^]u8, len: c.size_t) -> c.int,
	fido_assert_set_uv:     proc "c" (a: rawptr, uv: c.int) -> c.int,
	fido_assert_set_up:     proc "c" (a: rawptr, up: c.int) -> c.int,
	fido_assert_set_extensions: proc "c" (a: rawptr, flags: c.int) -> c.int,
	fido_assert_set_hmac_salt: proc "c" (a: rawptr, ptr: [^]u8, len: c.size_t) -> c.int,
	fido_assert_hmac_secret_ptr: proc "c" (a: rawptr, idx: c.size_t) -> [^]u8,
	fido_assert_hmac_secret_len: proc "c" (a: rawptr, idx: c.size_t) -> c.size_t,
	fido_assert_count:      proc "c" (a: rawptr) -> c.size_t,
	fido_assert_authdata_raw_ptr: proc "c" (a: rawptr, idx: c.size_t) -> [^]u8,
	fido_assert_authdata_raw_len: proc "c" (a: rawptr, idx: c.size_t) -> c.size_t,
	fido_assert_sig_ptr:    proc "c" (a: rawptr, idx: c.size_t) -> [^]u8,
	fido_assert_sig_len:    proc "c" (a: rawptr, idx: c.size_t) -> c.size_t,
	fido_assert_id_ptr:     proc "c" (a: rawptr, idx: c.size_t) -> [^]u8,
	fido_assert_id_len:     proc "c" (a: rawptr, idx: c.size_t) -> c.size_t,
	fido_assert_user_id_ptr: proc "c" (a: rawptr, idx: c.size_t) -> [^]u8,
	fido_assert_user_id_len: proc "c" (a: rawptr, idx: c.size_t) -> c.size_t,
	fido_dev_get_assert:    proc "c" (dev, a: rawptr, pin: cstring) -> c.int,
}

// FIDO_OPT_* (libfido2): omit / true / false for a tri-state option like uv and rk.
@(private = "file") FIDO_OPT_OMIT :: 0
@(private = "file") FIDO_OPT_FALSE :: 1
@(private = "file") FIDO_OPT_TRUE :: 2

@(private = "file")
fido2: Fido2_Lib
@(private = "file")
fido2_once: sync.Once
@(private = "file")
fido2_ok: bool

@(private = "file")
FIDO2_SONAMES :: [?]string{ "libfido2.so.1", "libfido2.so" }

@(private = "file")
fido2_load :: proc() {
	flags := posix.RTLD_LOCAL + {.NOW}
	h: posix.Symbol_Table
	for name in FIDO2_SONAMES {
		c := strings.clone_to_cstring(name, context.temp_allocator)
		h = posix.dlopen(c, flags)
		if h != nil { break }
	}
	if h == nil { return }
	l := &fido2
	l.handle = h
	ok := true
	sym :: proc(h: posix.Symbol_Table, name: string, ok: ^bool) -> rawptr {
		c := strings.clone_to_cstring(name, context.temp_allocator)
		p := posix.dlsym(h, c)
		if p == nil { ok^ = false }
		return p
	}
	l.fido_init = auto_cast sym(h, "fido_init", &ok)
	l.fido_dev_info_new = auto_cast sym(h, "fido_dev_info_new", &ok)
	l.fido_dev_info_free = auto_cast sym(h, "fido_dev_info_free", &ok)
	l.fido_dev_info_manifest = auto_cast sym(h, "fido_dev_info_manifest", &ok)
	l.fido_dev_info_ptr = auto_cast sym(h, "fido_dev_info_ptr", &ok)
	l.fido_dev_info_path = auto_cast sym(h, "fido_dev_info_path", &ok)
	l.fido_dev_new = auto_cast sym(h, "fido_dev_new", &ok)
	l.fido_dev_free = auto_cast sym(h, "fido_dev_free", &ok)
	l.fido_dev_open = auto_cast sym(h, "fido_dev_open", &ok)
	l.fido_dev_close = auto_cast sym(h, "fido_dev_close", &ok)
	l.fido_dev_cancel = auto_cast sym(h, "fido_dev_cancel", &ok)
	l.fido_dev_has_pin = auto_cast sym(h, "fido_dev_has_pin", &ok)
	l.fido_dev_is_fido2 = auto_cast sym(h, "fido_dev_is_fido2", &ok)
	l.fido_cred_new = auto_cast sym(h, "fido_cred_new", &ok)
	l.fido_cred_free = auto_cast sym(h, "fido_cred_free", &ok)
	l.fido_cred_set_type = auto_cast sym(h, "fido_cred_set_type", &ok)
	l.fido_cred_set_clientdata_hash = auto_cast sym(h, "fido_cred_set_clientdata_hash", &ok)
	l.fido_cred_set_rp = auto_cast sym(h, "fido_cred_set_rp", &ok)
	l.fido_cred_set_user = auto_cast sym(h, "fido_cred_set_user", &ok)
	l.fido_cred_set_rk = auto_cast sym(h, "fido_cred_set_rk", &ok)
	l.fido_cred_set_uv = auto_cast sym(h, "fido_cred_set_uv", &ok)
	l.fido_cred_exclude = auto_cast sym(h, "fido_cred_exclude", &ok)
	l.fido_cred_authdata_raw_ptr = auto_cast sym(h, "fido_cred_authdata_raw_ptr", &ok)
	l.fido_cred_authdata_raw_len = auto_cast sym(h, "fido_cred_authdata_raw_len", &ok)
	l.fido_cred_attstmt_ptr = auto_cast sym(h, "fido_cred_attstmt_ptr", &ok)
	l.fido_cred_attstmt_len = auto_cast sym(h, "fido_cred_attstmt_len", &ok)
	l.fido_cred_fmt = auto_cast sym(h, "fido_cred_fmt", &ok)
	l.fido_cred_id_ptr = auto_cast sym(h, "fido_cred_id_ptr", &ok)
	l.fido_cred_id_len = auto_cast sym(h, "fido_cred_id_len", &ok)
	l.fido_dev_make_cred = auto_cast sym(h, "fido_dev_make_cred", &ok)
	l.fido_assert_new = auto_cast sym(h, "fido_assert_new", &ok)
	l.fido_assert_free = auto_cast sym(h, "fido_assert_free", &ok)
	l.fido_assert_set_clientdata_hash = auto_cast sym(h, "fido_assert_set_clientdata_hash", &ok)
	l.fido_assert_set_rp = auto_cast sym(h, "fido_assert_set_rp", &ok)
	l.fido_assert_allow_cred = auto_cast sym(h, "fido_assert_allow_cred", &ok)
	l.fido_assert_set_uv = auto_cast sym(h, "fido_assert_set_uv", &ok)
	l.fido_assert_set_up = auto_cast sym(h, "fido_assert_set_up", &ok)
	l.fido_assert_set_extensions = auto_cast sym(h, "fido_assert_set_extensions", &ok)
	l.fido_assert_set_hmac_salt = auto_cast sym(h, "fido_assert_set_hmac_salt", &ok)
	l.fido_assert_hmac_secret_ptr = auto_cast sym(h, "fido_assert_hmac_secret_ptr", &ok)
	l.fido_assert_hmac_secret_len = auto_cast sym(h, "fido_assert_hmac_secret_len", &ok)
	l.fido_dev_get_retry_count = auto_cast sym(h, "fido_dev_get_retry_count", &ok)
	l.fido_cred_set_extensions = auto_cast sym(h, "fido_cred_set_extensions", &ok)
	l.fido_assert_count = auto_cast sym(h, "fido_assert_count", &ok)
	l.fido_assert_authdata_raw_ptr = auto_cast sym(h, "fido_assert_authdata_raw_ptr", &ok)
	l.fido_assert_authdata_raw_len = auto_cast sym(h, "fido_assert_authdata_raw_len", &ok)
	l.fido_assert_sig_ptr = auto_cast sym(h, "fido_assert_sig_ptr", &ok)
	l.fido_assert_sig_len = auto_cast sym(h, "fido_assert_sig_len", &ok)
	l.fido_assert_id_ptr = auto_cast sym(h, "fido_assert_id_ptr", &ok)
	l.fido_assert_id_len = auto_cast sym(h, "fido_assert_id_len", &ok)
	l.fido_assert_user_id_ptr = auto_cast sym(h, "fido_assert_user_id_ptr", &ok)
	l.fido_assert_user_id_len = auto_cast sym(h, "fido_assert_user_id_len", &ok)
	l.fido_dev_get_assert = auto_cast sym(h, "fido_dev_get_assert", &ok)
	if !ok { return }
	l.fido_init(0)
	fido2_ok = true
}

@(private = "file")
fido2_available :: proc() -> bool {
	sync.once_do(&fido2_once, fido2_load)
	return fido2_ok
}

@(private = "file")
FIDO2_PLATFORM := Platform{
	name = "libfido2",
	version = 2,
	capabilities = fido2_capabilities,
	make_credential = fido2_make_credential,
	get_assertion = fido2_get_assertion,
	cancel = fido2_cancel,
	prepare_cancel = fido2_prepare_cancel,
}

// Why system_platform is nil here, for the page's error and the Vault's message.
NO_PLATFORM_REASON :: "libfido2 was not found: install it (Debian, Ubuntu: libfido2-1; Fedora, Arch: libfido2) to use security keys"

system_platform :: proc() -> ^Platform {
	if !fido2_available() { return nil }
	return &FIDO2_PLATFORM
}

@(private = "file")
fido2_capabilities :: proc(pl: ^Platform) -> Capabilities {
	// Roaming authenticators only: no platform authenticator (no Windows Hello / Touch ID equivalent here), no hybrid
	// yet. The extensions libfido2 lets us pass are added as each is wired.
	return Capabilities{
		user_verifying_platform = false,
		passkey_platform = false,
		hybrid = false,
		extensions = {.Cred_Protect, .Hmac_Secret, .Prf},
	}
}

// The open device for a running operation, so cancel reaches it from another thread.
@(private = "file")
Fido2_Op :: struct {
	dev: rawptr,
	mu:  sync.Mutex,
}

@(private = "file")
fido2_prepare_cancel :: proc(pl: ^Platform, token: ^Cancel_Token) {
	op := new(Fido2_Op, base.process_allocator())
	// store the op in the token's platform id slot (a pointer, little-endian) so cancel can find it
	ptr := uintptr(op)
	for i in 0 ..< size_of(uintptr) { token.platform[i] = u8(ptr >> uint(i * 8)) }
	token.has_platform = true
}

@(private = "file")
op_of :: proc(token: ^Cancel_Token) -> ^Fido2_Op {
	if !token.has_platform { return nil }
	ptr: uintptr
	for i in 0 ..< size_of(uintptr) { ptr |= uintptr(token.platform[i]) << uint(i * 8) }
	return (^Fido2_Op)(ptr)
}

@(private = "file")
fido2_cancel :: proc(pl: ^Platform, token: ^Cancel_Token) {
	op := op_of(token)
	if op == nil { return }
	sync.mutex_lock(&op.mu)
	if op.dev != nil { fido2.fido_dev_cancel(op.dev) }
	sync.mutex_unlock(&op.mu)
}

// Opens the first FIDO2 roaming authenticator found. Returns nil when none is present or none could be opened.
@(private = "file")
fido2_open_any :: proc(op: ^Fido2_Op) -> rawptr {
	const_N :: 8
	list := fido2.fido_dev_info_new(const_N)
	if list == nil { return nil }
	defer { l := list; fido2.fido_dev_info_free(&l, const_N) }
	olen: c.size_t
	if fido2.fido_dev_info_manifest(list, const_N, &olen) != FIDO_OK { return nil }
	for i in 0 ..< int(olen) {
		di := fido2.fido_dev_info_ptr(list, c.size_t(i))
		if di == nil { continue }
		path := fido2.fido_dev_info_path(di)
		dev := fido2.fido_dev_new()
		if dev == nil { continue }
		if fido2.fido_dev_open(dev, path) != FIDO_OK {
			d := dev; fido2.fido_dev_free(&d)
			continue
		}
		if !fido2.fido_dev_is_fido2(dev) {
			fido2.fido_dev_close(dev)
			d := dev; fido2.fido_dev_free(&d)
			continue
		}
		sync.mutex_lock(&op.mu)
		op.dev = dev
		sync.mutex_unlock(&op.mu)
		return dev
	}
	return nil
}

@(private = "file")
fido2_close :: proc(op: ^Fido2_Op) {
	sync.mutex_lock(&op.mu)
	dev := op.dev
	op.dev = nil
	sync.mutex_unlock(&op.mu)
	if dev != nil {
		fido2.fido_dev_close(dev)
		d := dev; fido2.fido_dev_free(&d)
	}
}

@(private = "file")
cstr :: proc(s: string, allocator: runtime.Allocator) -> cstring {
	return strings.clone_to_cstring(s, allocator)
}

@(private = "file")
status_of_fido :: proc(r: c.int, token: ^Cancel_Token) -> Status {
	if c, _ := cancelled(token); c { return fail(.Not_Allowed, "NotAllowedError: the operation was cancelled") }
	if r == FIDO_ERR_PIN_REQUIRED { return fail(.Not_Allowed, "NotAllowedError: this security key needs its PIN") }
	if r == FIDO_ERR_PIN_BLOCKED { return fail(.Not_Allowed, "NotAllowedError: this security key's PIN is blocked after too many wrong tries; reset the key to use it again") }
	if r == FIDO_ERR_PIN_AUTH_BLOCKED { return fail(.Not_Allowed, "NotAllowedError: too many wrong PINs: remove the security key and insert it again") }
	if r == FIDO_ERR_PIN_NOT_SET { return fail(.Not_Allowed, "NotAllowedError: this site needs a PIN on the security key, and the key has none: set one with its maker's tool") }
	if r == FIDO_ERR_NO_CREDENTIALS { return fail(.Not_Allowed, "NotAllowedError: this security key has no passkey for this site") }
	if r == FIDO_ERR_UP_REQUIRED { return fail(.Not_Allowed, "NotAllowedError: the security key was not touched") }
	return fail(.Not_Allowed, "NotAllowedError: the security key refused or was removed")
}

@(private = "file")
fido2_make_credential :: proc(pl: ^Platform, rq: ^Make_Request, out: ^Credential, allocator := context.allocator) -> Status {
	op := op_of(rq.cancel)
	if op == nil { return fail(.Not_Allowed, "NotAllowedError: the operation was not prepared") }
	defer fido2_close(op)
	if c, _ := cancelled(rq.cancel); c { return fail(.Not_Allowed, "NotAllowedError: the operation was cancelled") }
	dev := fido2_open_any(op)
	if dev == nil { return fail(.Not_Allowed, "NotAllowedError: no security key is connected") }

	cred := fido2.fido_cred_new()
	if cred == nil { return fail(.Not_Allowed, "NotAllowedError: out of memory") }
	defer { c := cred; fido2.fido_cred_free(&c) }

	o := rq.options
	// The first algorithm the client listed that the key supports; libfido2 takes one type per credential.
	alg := len(o.algorithms) > 0 ? c.int(o.algorithms[0]) : c.int(COSE_ES256)
	if fido2.fido_cred_set_type(cred, alg) != FIDO_OK { return fail(.Not_Supported, "NotSupportedError: the algorithm is not supported") }
	hash := clientdata_hash(rq.client_data_json)
	if fido2.fido_cred_set_clientdata_hash(cred, raw_data(hash[:]), len(hash)) != FIDO_OK { return fail(.Not_Allowed, "NotAllowedError: bad client data") }
	if fido2.fido_cred_set_rp(cred, cstr(rq.rp_id, context.temp_allocator), cstr(o.rp_name, context.temp_allocator)) != FIDO_OK { return fail(.Not_Allowed, "NotAllowedError: bad relying party") }
	uid := o.user_id
	if fido2.fido_cred_set_user(cred, raw_data(uid), c.size_t(len(uid)), cstr(o.user_name, context.temp_allocator), cstr(o.user_display_name, context.temp_allocator), nil) != FIDO_OK { return fail(.Not_Allowed, "NotAllowedError: bad user") }
	fido2.fido_cred_set_rk(cred, o.resident_key == .Required ? FIDO_OPT_TRUE : FIDO_OPT_OMIT)
	fido2.fido_cred_set_uv(cred, o.user_verification == .Required ? FIDO_OPT_TRUE : FIDO_OPT_OMIT)
	for d in o.exclude { if len(d.id) > 0 { fido2.fido_cred_exclude(cred, raw_data(d.id), c.size_t(len(d.id))) } }
	if o.ext.prf { fido2.fido_cred_set_extensions(cred, FIDO_EXT_HMAC_SECRET) }

	need_pin := bool(fido2.fido_dev_has_pin(dev)) && o.user_verification != .Discouraged
	r := with_pin(dev, rq.cancel, rq.rp_id, need_pin, proc(dev, obj: rawptr, pin: cstring) -> c.int {
		// (the PIN gives the key's verification: the uv option with it is refused by some keys)
		if pin != nil { fido2.fido_cred_set_uv(obj, FIDO_OPT_OMIT) }
		return fido2.fido_dev_make_cred(dev, obj, pin)
	}, cred)
	if r != FIDO_OK { return status_of_fido(r, rq.cancel) }

	// authenticatorData (raw) and the attestation object = CBOR {fmt, attStmt, authData}.
	ad := cred_authdata(cred, allocator)
	out.kind = .Create
	out.authenticator_data = ad
	out.attestation_object = cred_attestation_object(cred, ad, allocator)
	out.raw_id = clone_bytes_wa(ptr_slice(fido2.fido_cred_id_ptr(cred), fido2.fido_cred_id_len(cred)), allocator)
	out.transports = {.USB}
	out.attachment = .Cross_Platform
	out.used_transport = {.USB}
	if o.ext.prf {
		out.ext.has_prf = true
		out.ext.has_prf_enabled, out.ext.prf_enabled = true, authdata_has_hmac_secret(ad)
	}
	return OK
}

@(private = "file")
fido2_get_assertion :: proc(pl: ^Platform, rq: ^Get_Request, out: ^Credential, allocator := context.allocator) -> Status {
	op := op_of(rq.cancel)
	if op == nil { return fail(.Not_Allowed, "NotAllowedError: the operation was not prepared") }
	defer fido2_close(op)
	if c, _ := cancelled(rq.cancel); c { return fail(.Not_Allowed, "NotAllowedError: the operation was cancelled") }
	dev := fido2_open_any(op)
	if dev == nil { return fail(.Not_Allowed, "NotAllowedError: no security key is connected") }

	as := fido2.fido_assert_new()
	if as == nil { return fail(.Not_Allowed, "NotAllowedError: out of memory") }
	defer { a := as; fido2.fido_assert_free(&a) }

	o := rq.options
	if fido2.fido_assert_set_rp(as, cstr(rq.rp_id, context.temp_allocator)) != FIDO_OK { return fail(.Not_Allowed, "NotAllowedError: bad relying party") }
	hash := clientdata_hash(rq.client_data_json)
	if fido2.fido_assert_set_clientdata_hash(as, raw_data(hash[:]), len(hash)) != FIDO_OK { return fail(.Not_Allowed, "NotAllowedError: bad client data") }
	// PRF: the salts of the credential the key will use (evalByCredential), else of `eval`
	prf_values: Prf_Values
	has_prf := false
	allow_only: []byte   // the one allowed credential the silent probe found (nil: the request's list)
	if o.ext.prf {
		if len(o.ext.prf_by_credential) > 0 {
			held := o.allow[0].id if len(o.allow) == 1 else probe_held(dev, rq, hash[:])
			for pc in o.ext.prf_by_credential {
				if string(pc.credential) == string(held) { prf_values, has_prf = pc.values, true; allow_only = held }
			}
		}
		if !has_prf && o.ext.has_prf_eval { prf_values, has_prf = o.ext.prf_eval, true }
	}
	if allow_only != nil {
		fido2.fido_assert_allow_cred(as, raw_data(allow_only), c.size_t(len(allow_only)))
	} else {
		for d in o.allow { if len(d.id) > 0 { fido2.fido_assert_allow_cred(as, raw_data(d.id), c.size_t(len(d.id))) } }
	}
	if has_prf {
		salt: [64]u8
		n := prf_salt(prf_values, &salt)
		fido2.fido_assert_set_extensions(as, FIDO_EXT_HMAC_SECRET)
		fido2.fido_assert_set_hmac_salt(as, raw_data(salt[:]), c.size_t(n))
	}
	fido2.fido_assert_set_uv(as, o.user_verification == .Required ? FIDO_OPT_TRUE : FIDO_OPT_OMIT)

	need_pin := bool(fido2.fido_dev_has_pin(dev)) && o.user_verification != .Discouraged
	r := with_pin(dev, rq.cancel, rq.rp_id, need_pin, proc(dev, obj: rawptr, pin: cstring) -> c.int {
		if pin != nil { fido2.fido_assert_set_uv(obj, FIDO_OPT_OMIT) }
		return fido2.fido_dev_get_assert(dev, obj, pin)
	}, as)
	if r != FIDO_OK { return status_of_fido(r, rq.cancel) }
	if int(fido2.fido_assert_count(as)) == 0 { return fail(.Not_Allowed, "NotAllowedError: the security key returned no assertion") }

	idx := c.size_t(0)
	out.kind = .Get
	out.authenticator_data = clone_bytes_wa(ptr_slice(fido2.fido_assert_authdata_raw_ptr(as, idx), fido2.fido_assert_authdata_raw_len(as, idx)), allocator)
	out.signature = clone_bytes_wa(ptr_slice(fido2.fido_assert_sig_ptr(as, idx), fido2.fido_assert_sig_len(as, idx)), allocator)
	out.raw_id = clone_bytes_wa(ptr_slice(fido2.fido_assert_id_ptr(as, idx), fido2.fido_assert_id_len(as, idx)), allocator)
	if uid := ptr_slice(fido2.fido_assert_user_id_ptr(as, idx), fido2.fido_assert_user_id_len(as, idx)); len(uid) > 0 {
		out.user_handle = clone_bytes_wa(uid, allocator)
		out.has_user_handle = true
	}
	out.attachment = .Cross_Platform
	out.used_transport = {.USB}
	if o.ext.prf {
		out.ext.has_prf = true
		if secret := ptr_slice(fido2.fido_assert_hmac_secret_ptr(as, idx), fido2.fido_assert_hmac_secret_len(as, idx)); has_prf && len(secret) >= 32 {
			out.ext.has_prf_results = true
			out.ext.prf_results.first = clone_bytes_wa(secret[:32], allocator)
			if len(secret) >= 64 && prf_values.has_second {
				out.ext.prf_results.second, out.ext.prf_results.has_second = clone_bytes_wa(secret[32:64], allocator), true
			}
		}
	}
	return OK
}

// Runs `call` (a make or a get on `obj`) with the key's PIN when it needs one: asked of the person first when
// `need_pin`, asked again with the tries left after a wrong one, asked when the key answers that it needs one. The
// PIN is zeroed after each try.
@(private = "file")
with_pin :: proc(dev: rawptr, token: ^Cancel_Token, rp_id: string, need_pin: bool, call: proc(dev, obj: rawptr, pin: cstring) -> c.int, obj: rawptr) -> c.int {
	ask := need_pin
	wrong := false
	for {
		if !ask {
			touch_begin(&FIDO2_PLATFORM, token, rp_id)
			defer touch_end()
			return call(dev, obj, nil)
		}
		retries: c.int = -1
		if fido2.fido_dev_get_retry_count(dev, &retries) != FIDO_OK { retries = -1 }
		if retries == 0 { return FIDO_ERR_PIN_BLOCKED }
		buf: [PIN_MAX + 1]u8
		_, given := pin_ask(token, rp_id, int(retries), wrong, &buf)
		if !given {
			for &b in buf { b = 0 }
			if c, _ := cancelled(token); c { return FIDO_ERR_RX }
			return FIDO_ERR_PIN_REQUIRED
		}
		touch_begin(&FIDO2_PLATFORM, token, rp_id)
		r := call(dev, obj, cstring(raw_data(buf[:])))
		touch_end()
		for &b in buf { b = 0 }
		switch r {
		case FIDO_ERR_PIN_INVALID: wrong = true   // (asked again, with the tries left)
		case FIDO_ERR_PIN_REQUIRED: ask = true
		case: return r
		}
	}
}

// The credential of the allow list that the key holds, by a silent assertion (no touch, no PIN): the first it answers.
// nil when it holds none, or does not answer a probe.
@(private = "file")
probe_held :: proc(dev: rawptr, rq: ^Get_Request, hash: []u8) -> []byte {
	as := fido2.fido_assert_new()
	if as == nil { return nil }
	defer { a := as; fido2.fido_assert_free(&a) }
	fido2.fido_assert_set_rp(as, cstr(rq.rp_id, context.temp_allocator))
	fido2.fido_assert_set_clientdata_hash(as, raw_data(hash), c.size_t(len(hash)))
	for d in rq.options.allow { if len(d.id) > 0 { fido2.fido_assert_allow_cred(as, raw_data(d.id), c.size_t(len(d.id))) } }
	fido2.fido_assert_set_up(as, FIDO_OPT_FALSE)
	if fido2.fido_dev_get_assert(dev, as, nil) != FIDO_OK || fido2.fido_assert_count(as) == 0 { return nil }
	id := ptr_slice(fido2.fido_assert_id_ptr(as, 0), fido2.fido_assert_id_len(as, 0))
	for d in rq.options.allow { if string(d.id) == string(id) { return d.id } }
	return nil
}

// Whether a new credential's authenticatorData says hmac-secret: true in its extensions (flag ED, the CBOR text
// "hmac-secret" then true).
@(private = "file")
authdata_has_hmac_secret :: proc(ad: []u8) -> bool {
	if len(ad) < 33 || ad[32] & 0x80 == 0 { return false }
	key := "\x6bhmac-secret\xf5"
	return len(ad) >= len(key) && contains_bytes(ad, transmute([]u8)string(key))
}

@(private = "file")
contains_bytes :: proc(hay, needle: []u8) -> bool {
	outer: for i in 0 ..= len(hay) - len(needle) {
		for b, j in needle { if hay[i + j] != b { continue outer } }
		return true
	}
	return false
}

// SHA-256 of the clientDataJSON: what the key signs (crypto.odin's hash).
@(private = "file")
clientdata_hash :: proc(cdj: []byte) -> [32]u8 { return sha256(cdj) }

@(private = "file")
cred_authdata :: proc(cred: rawptr, allocator: runtime.Allocator) -> []byte {
	return clone_bytes_wa(ptr_slice(fido2.fido_cred_authdata_raw_ptr(cred), fido2.fido_cred_authdata_raw_len(cred)), allocator)
}

// The attestation object: CBOR map {"fmt": <fmt>, "attStmt": <attStmt map>, "authData": <authData bytes>}. libfido2
// gives the format name and the attestation statement already as a CBOR map (fido_cred_attstmt_ptr).
@(private = "file")
cred_attestation_object :: proc(cred: rawptr, authdata: []byte, allocator: runtime.Allocator) -> []byte {
	fmt_c := fido2.fido_cred_fmt(cred)
	fmt := fmt_c != nil ? string(fmt_c) : "none"
	attstmt := ptr_slice(fido2.fido_cred_attstmt_ptr(cred), fido2.fido_cred_attstmt_len(cred))
	b := strings.builder_make(allocator)
	cbor_write_head(&b, .Map, 3)
	cbor_write_text(&b, "fmt"); cbor_write_text(&b, fmt)
	cbor_write_text(&b, "attStmt")
	if len(attstmt) > 0 {
		strings.write_bytes(&b, attstmt)   // already a CBOR map
	} else {
		cbor_write_head(&b, .Map, 0)       // empty attStmt (fmt "none")
	}
	cbor_write_text(&b, "authData"); cbor_write_bytes(&b, authdata)
	return b.buf[:]
}

@(private = "file")
ptr_slice :: proc(p: [^]u8, n: c.size_t) -> []u8 {
	if p == nil || n == 0 { return nil }
	return p[:int(n)]
}

@(private = "file")
clone_bytes_wa :: proc(b: []u8, allocator: runtime.Allocator) -> []u8 {
	if len(b) == 0 { return nil }
	c := make([]u8, len(b), allocator)
	copy(c, b)
	return c
}
