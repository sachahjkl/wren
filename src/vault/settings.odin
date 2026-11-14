package vault

import "core:strings"
import "wb:config"

// The Vault's preferences (about:config, `vault.*`). Off by default: with vault.enabled off there is no button, no helper
// process and no network call.

US_IDENTITY_URL :: "https://identity.bitwarden.com"
US_API_URL :: "https://api.bitwarden.com"
EU_IDENTITY_URL :: "https://identity.bitwarden.eu"
EU_API_URL :: "https://api.bitwarden.eu"

Insecure_Fill :: enum u8 { Ask, Never }

// Where the account lives: Bitwarden's servers in the United States or in the European Union, or a server of one's own.
Region :: enum u8 { US, EU, Self }

REGION_NAMES := [Region]string{.US = "us", .EU = "eu", .Self = "self"}

// The helper locks itself this long after the Vault's own idle deadline, without a keepalive (the Vault locks first).
HELPER_IDLE_MARGIN_S :: 120

Settings :: struct {
	enabled:      bool,
	region:       Region,
	server_url:   string,   // owned: the base URL of a self-hosted server (region Self)
	idle_minutes: int,      // lock after this idle time; 0: only on demand and at exit
	sync_minutes: int,      // time between two syncs while unlocked
	timeout_ms:   int,      // deadline of one helper request
	helper_path:  string,   // owned: where the helper is ("" = beside the browser)
	insecure:     Insecure_Fill,
	test_remote:  bool,     // remote control may drive the Vault surfaces (automated tests only)
	dropdown:     bool,     // the list of logins under a focused login field
	clear_seconds: int,     // a copied password or code leaves the clipboard after this time; 0: never
	shortcut:     string,   // owned: the fill shortcut ("Ctrl+Shift+L"; "": none)
	remember_email: bool,   // the login dialog starts with the last email that logged in
	save_offer:   bool,     // after a login form is sent, offer to save or update its login
	totp_autofill: bool,    // a one-time-code field that comes after a fill of a login with a code gets the code
	totp_copy:    bool,     // a fill of a login with a code copies the code
	passkeys_offer: bool,   // a page's passkey request offers the unlocked vault's passkeys of the site
	remember:     Remember_Unlock,   // the unlock kept in the system's keyring (vault.unlock.remember)
	generator:    Generate_Options,   // the generator's defaults (its separator owned)
}

// How long the system's keyring keeps the vault's unlock (the helper's remember_unlock): not at all, until the computer
// restarts, or across restarts.
Remember_Unlock :: enum u8 { Never, Session, Always }
REMEMBER_UNLOCK_NAMES := [Remember_Unlock]string{.Never = "never", .Session = "session", .Always = "always"}

// What the generator makes (the helper's `generate`): a password of `length` characters of the classes that are on, or
// a passphrase of `words` words.
Generate_Options :: struct {
	passphrase:  bool,
	length:      int,
	uppercase, lowercase, numbers, special: bool,
	min_numbers, min_special: int,
	words:       int,
	separator:   string,
	capitalize, include_number: bool,
}

GENERATE_LENGTH_MIN :: 5
GENERATE_LENGTH_MAX :: 128
GENERATE_WORDS_MIN :: 3
GENERATE_WORDS_MAX :: 20
TOTP_AUTOFILL_NS :: i64(120) * 1_000_000_000   // a code's field must come this soon after the fill of its login

US_WEB_VAULT_URL :: "https://vault.bitwarden.com"
EU_WEB_VAULT_URL :: "https://vault.bitwarden.eu"

PREFS := [?]config.Def{
	{name = "vault.enabled", kind = .Bool, default = {b = false},
		description = "Use a Bitwarden® account. The Vault keeps your logins in your Bitwarden account and fills them into the login forms of pages when you ask. It runs a separate helper program (wren-vault, GPL-3.0) that holds the keys. The Vault is not made or supported by Bitwarden Inc.",
		tags = {"password", "passwords", "logins", "bitwarden", "password manager"}},
	{name = "vault.server.region", kind = .String, default = {s = "us"}, choices = {"us", "eu", "self"},
		description = "Where your account lives: Bitwarden's servers in the United States (us) or in the European Union (eu), or a server of your own (self, at vault.server.url)."},
	{name = "vault.server.url", kind = .String, default = {s = ""},
		description = "Base address of your own server, for vault.server.region self (it serves /identity and /api). Must be https, or http to this machine. A server with a certificate of a private authority needs that authority in the system's certificate store."},
	{name = "vault.unlock.remember", kind = .String, default = {s = "never"}, choices = {"never", "session", "always"},
		description = "Unlock the Vault without its password, from the system's keyring (GNOME Keyring, KWallet, Windows' Credential Manager): at the start of the browser, and at a click on Unlock. session: until the computer restarts; always: across restarts too; never: each unlock asks for the master password, a PIN or a passkey. Whoever can use your session can then open the Vault. The key is only ever in the keyring, never in a file.",
		tags = {"keyring", "unlock", "password", "remember", "keychain"}},
	{name = "vault.lock.idle_minutes", kind = .Int, default = {i = 15}, bounded = true, min = 0, max = 1440, unit = "min",
		description = "Lock the Vault after this time without a key press or a click in the browser. 0: lock only on demand and when the browser exits."},
	{name = "vault.sync.interval_minutes", kind = .Int, default = {i = 30}, bounded = true, min = 5, max = 1440, unit = "min",
		description = "Time between two syncs with the server while the Vault is unlocked."},
	{name = "vault.request.timeout_ms", kind = .Int, default = {i = 15_000}, bounded = true, min = 1000, max = 120_000, unit = "ms",
		description = "How long the Vault waits for one answer of its helper (a login, an unlock, the logins of a page, a fill). Past it the request is dropped and the helper is stopped."},
	{name = "vault.helper.path", kind = .String, default = {s = ""},
		description = "Where the helper program wren-vault is. Empty: beside the browser, or in its vault folder. For development and for packagers."},
	{name = "vault.fill.insecure", kind = .String, default = {s = "ask"}, choices = {"ask", "never"},
		description = "On a page served over plain http (not this machine), ask before each fill, or never fill."},
	{name = "vault.fill.dropdown", kind = .Bool, default = {b = true},
		description = "Under a focused user name, password or one-time-code field, list the Vault's logins for the page. Down moves into the list, Enter fills, Escape closes it."},
	{name = "vault.fill.shortcut", kind = .String, default = {s = "Ctrl+Shift+L"},
		description = "The key that fills the page's login from the Vault: the only login of the page at once, or the list of its logins. Modifiers Ctrl, Alt, Shift, then a letter, a digit or F1 to F12 (\"Ctrl+Shift+L\"). Empty: no key."},
	{name = "vault.clipboard.clear_seconds", kind = .Int, default = {i = 30}, bounded = true, min = 0, max = 600, unit = "s",
		description = "A user name, password or one-time code that the Vault copied leaves the clipboard after this time, if the clipboard still holds it. 0: it stays."},
	{name = "vault.login.remember_email", kind = .Bool, default = {b = true},
		description = "The Vault's login starts with the email of the last login in this profile. It stays after a log out. Off: the email is forgotten, and each login starts empty.",
		tags = {"email", "remember"}},
	{name = "vault.save.offer", kind = .Bool, default = {b = true},
		description = "After you send a login form, offer to save its login in the Vault, or to update the password of the login that has its user name. The offer never fills or saves anything by itself.",
		tags = {"save", "password", "update"}},
	{name = "vault.totp.autofill", kind = .Bool, default = {b = true},
		description = "After the Vault filled a login that has a one-time code, fill the code into the code field that the same site shows within 2 minutes."},
	{name = "vault.totp.copy_on_fill", kind = .Bool, default = {b = false},
		description = "When the Vault fills a login that has a one-time code, copy the code to the clipboard (cleared after vault.clipboard.clear_seconds)."},
	{name = "vault.passkeys.offer", kind = .Bool, default = {b = true},
		description = "When a page asks for a passkey and the unlocked Vault holds passkeys of that site, ask which to use: one of the Vault's, or a security key or this device. Off: a page's passkey request goes to the security key or this device only.",
		tags = {"passkey", "passkeys", "webauthn"}},
	{name = "vault.generator.kind", kind = .String, default = {s = "password"}, choices = {"password", "passphrase"},
		description = "What the password generator makes first: a password of random characters, or a passphrase of random words."},
	{name = "vault.generator.length", kind = .Int, default = {i = 20}, bounded = true, min = GENERATE_LENGTH_MIN, max = GENERATE_LENGTH_MAX,
		description = "The length of a generated password, in characters."},
	{name = "vault.generator.uppercase", kind = .Bool, default = {b = true}, description = "A generated password has capital letters (A-Z)."},
	{name = "vault.generator.lowercase", kind = .Bool, default = {b = true}, description = "A generated password has small letters (a-z)."},
	{name = "vault.generator.numbers", kind = .Bool, default = {b = true}, description = "A generated password has digits (0-9)."},
	{name = "vault.generator.special", kind = .Bool, default = {b = true}, description = "A generated password has special characters (!@#$%^&*)."},
	{name = "vault.generator.min_numbers", kind = .Int, default = {i = 1}, bounded = true, min = 0, max = 9,
		description = "The fewest digits in a generated password that has digits."},
	{name = "vault.generator.min_special", kind = .Int, default = {i = 1}, bounded = true, min = 0, max = 9,
		description = "The fewest special characters in a generated password that has them."},
	{name = "vault.generator.words", kind = .Int, default = {i = 5}, bounded = true, min = GENERATE_WORDS_MIN, max = GENERATE_WORDS_MAX,
		description = "The number of words of a generated passphrase."},
	{name = "vault.generator.separator", kind = .String, default = {s = "-"},
		description = "What goes between the words of a generated passphrase."},
	{name = "vault.generator.capitalize", kind = .Bool, default = {b = false}, description = "Each word of a generated passphrase starts with a capital letter."},
	{name = "vault.generator.include_number", kind = .Bool, default = {b = false}, description = "A generated passphrase has a digit after one of its words."},
	{name = "vault.test.remote", kind = .Bool, default = {b = false},
		description = "For automated tests only, with a throwaway profile: remote control can use the Vault's panel. Off: the Vault refuses to work while the browser is remote-controlled."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	s: Settings
	s.enabled = config.bool_of(p, "vault.enabled")
	switch config.string_of(p, "vault.server.region") {
	case "eu":   s.region = .EU
	case "self": s.region = .Self
	case:        s.region = .US
	}
	s.server_url = strings.clone(strings.trim_space(config.string_of(p, "vault.server.url")))
	s.idle_minutes = int(config.int_of(p, "vault.lock.idle_minutes"))
	s.sync_minutes = int(config.int_of(p, "vault.sync.interval_minutes"))
	s.timeout_ms = int(config.int_of(p, "vault.request.timeout_ms"))
	s.helper_path = strings.clone(strings.trim_space(config.string_of(p, "vault.helper.path")))
	s.insecure = config.string_of(p, "vault.fill.insecure") == "never" ? .Never : .Ask
	s.test_remote = config.bool_of(p, "vault.test.remote")
	s.dropdown = config.bool_of(p, "vault.fill.dropdown")
	s.clear_seconds = int(config.int_of(p, "vault.clipboard.clear_seconds"))
	s.shortcut = strings.clone(strings.trim_space(config.string_of(p, "vault.fill.shortcut")))
	s.remember_email = config.bool_of(p, "vault.login.remember_email")
	s.save_offer = config.bool_of(p, "vault.save.offer")
	s.totp_autofill = config.bool_of(p, "vault.totp.autofill")
	s.totp_copy = config.bool_of(p, "vault.totp.copy_on_fill")
	s.passkeys_offer = config.bool_of(p, "vault.passkeys.offer")
	switch config.string_of(p, "vault.unlock.remember") {
	case "session": s.remember = .Session
	case "always":  s.remember = .Always
	case:           s.remember = .Never
	}
	g := &s.generator
	g.passphrase = config.string_of(p, "vault.generator.kind") == "passphrase"
	g.length = int(config.int_of(p, "vault.generator.length"))
	g.uppercase = config.bool_of(p, "vault.generator.uppercase")
	g.lowercase = config.bool_of(p, "vault.generator.lowercase")
	g.numbers = config.bool_of(p, "vault.generator.numbers")
	g.special = config.bool_of(p, "vault.generator.special")
	g.min_numbers = int(config.int_of(p, "vault.generator.min_numbers"))
	g.min_special = int(config.int_of(p, "vault.generator.min_special"))
	g.words = int(config.int_of(p, "vault.generator.words"))
	g.separator = strings.clone(config.string_of(p, "vault.generator.separator"))
	g.capitalize = config.bool_of(p, "vault.generator.capitalize")
	g.include_number = config.bool_of(p, "vault.generator.include_number")
	return s
}

// The web vault of the configured server: where a person solves a captcha, and the origin of a passkey ceremony (its
// relying party is that origin's host or a suffix of it). "" for region Self without an address.
web_vault_url :: proc(s: Settings, allocator := context.temp_allocator) -> string {
	switch s.region {
	case .US: return US_WEB_VAULT_URL
	case .EU: return EU_WEB_VAULT_URL
	case .Self:
	}
	return strings.clone(strings.trim_right(s.server_url, "/"), allocator)
}

settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}

settings_destroy :: proc(s: ^Settings) {
	delete(s.server_url)
	delete(s.helper_path)
	delete(s.shortcut)
	delete(s.generator.separator)
	s^ = {}
}

// The identity and API addresses of the configured server. Both "" for region Self without an address (the shell asks
// for one; the helper would refuse it).
server_urls :: proc(s: Settings, allocator := context.temp_allocator) -> (identity, api: string) {
	switch s.region {
	case .US: return US_IDENTITY_URL, US_API_URL
	case .EU: return EU_IDENTITY_URL, EU_API_URL
	case .Self:
	}
	b := strings.trim_right(s.server_url, "/")
	if b == "" { return "", "" }
	return strings.concatenate({b, "/identity"}, allocator), strings.concatenate({b, "/api"}, allocator)
}

// Whether two settings name the same server (another server: what runs is for the old one).
same_server :: proc(a, b: Settings) -> bool {
	return a.region == b.region && (a.region != .Self || a.server_url == b.server_url)
}
