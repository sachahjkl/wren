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
}

PREFS := [?]config.Def{
	{name = "vault.enabled", kind = .Bool, default = {b = false},
		description = "Use a Bitwarden® account. The Vault keeps your logins in your Bitwarden account and fills them into the login forms of pages when you ask. It runs a separate helper program (wren-vault, GPL-3.0) that holds the keys. The Vault is not made or supported by Bitwarden Inc.",
		tags = {"password", "passwords", "logins", "bitwarden", "password manager"}},
	{name = "vault.server.region", kind = .String, default = {s = "us"}, choices = {"us", "eu", "self"},
		description = "Where your account lives: Bitwarden's servers in the United States (us) or in the European Union (eu), or a server of your own (self, at vault.server.url)."},
	{name = "vault.server.url", kind = .String, default = {s = ""},
		description = "Base address of your own server, for vault.server.region self (it serves /identity and /api). Must be https, or http to this machine. A server with a certificate of a private authority needs that authority in the system's certificate store."},
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
	return s
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
