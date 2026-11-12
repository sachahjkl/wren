type: Added

**Vault: use a Bitwarden® account**: a new setting (Settings > Vault, off by default) connects Wren to a Bitwarden account through a separate helper program, wren-vault. A lock button in the toolbar shows the Vault's state; its panel logs in (email, master password, then the authenticator code when the account asks for one) and unlocks the remembered account after a restart. Locking stops the helper, so no key stays in memory. Phase 1 uses the Bitwarden server in the United States; `vault.server.url` names a self-hosted server.
