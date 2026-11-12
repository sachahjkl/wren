package vault

import "core:strings"
import "wb:config"

// The Vault's preferences (about:config, `vault.*`). Off by default: with vault.enabled off there is no button, no helper
// process and no network call.

US_IDENTITY_URL :: "https://identity.bitwarden.com"
US_API_URL :: "https://api.bitwarden.com"

Insecure_Fill :: enum u8 { Ask, Never }

Settings :: struct {
	enabled:     bool,
	server_url:  string,   // owned: the base URL of a self-hosted server ("" = the US server)
	timeout_ms:  int,      // deadline of one helper request
	helper_path: string,   // owned: where the helper is ("" = beside the browser)
	insecure:    Insecure_Fill,
	test_remote: bool,     // remote control may drive the Vault surfaces (automated tests only)
}

PREFS := [?]config.Def{
	{name = "vault.enabled", kind = .Bool, default = {b = false},
		description = "Use a Bitwarden® account. The Vault keeps your logins in your Bitwarden account and fills them into the login forms of pages when you ask. It runs a separate helper program (wren-vault, GPL-3.0) that holds the keys. The Vault is not made or supported by Bitwarden Inc.",
		tags = {"password", "passwords", "logins", "bitwarden", "password manager"}},
	{name = "vault.server.url", kind = .String, default = {s = ""},
		description = "Base address of a self-hosted server (it serves /identity and /api). Empty: the Bitwarden server in the United States. Must be https, or http to this machine."},
	{name = "vault.request.timeout_ms", kind = .Int, default = {i = 15_000}, bounded = true, min = 1000, max = 120_000, unit = "ms",
		description = "How long the Vault waits for one answer of its helper (a login, an unlock, the logins of a page, a fill). Past it the request is dropped and the helper is stopped."},
	{name = "vault.helper.path", kind = .String, default = {s = ""},
		description = "Where the helper program wren-vault is. Empty: beside the browser, or in its vault folder. For development and for packagers."},
	{name = "vault.fill.insecure", kind = .String, default = {s = "ask"}, choices = {"ask", "never"},
		description = "On a page served over plain http (not this machine), ask before each fill, or never fill."},
	{name = "vault.test.remote", kind = .Bool, default = {b = false},
		description = "For automated tests only, with a throwaway profile: remote control can use the Vault's panel. Off: the Vault refuses to work while the browser is remote-controlled."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	s: Settings
	s.enabled = config.bool_of(p, "vault.enabled")
	s.server_url = strings.clone(strings.trim_space(config.string_of(p, "vault.server.url")))
	s.timeout_ms = int(config.int_of(p, "vault.request.timeout_ms"))
	s.helper_path = strings.clone(strings.trim_space(config.string_of(p, "vault.helper.path")))
	s.insecure = config.string_of(p, "vault.fill.insecure") == "never" ? .Never : .Ask
	s.test_remote = config.bool_of(p, "vault.test.remote")
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
	s^ = {}
}

// The identity and API addresses of the configured server.
server_urls :: proc(s: Settings, allocator := context.temp_allocator) -> (identity, api: string) {
	if s.server_url == "" { return US_IDENTITY_URL, US_API_URL }
	b := strings.trim_right(s.server_url, "/")
	return strings.concatenate({b, "/identity"}, allocator), strings.concatenate({b, "/api"}, allocator)
}
