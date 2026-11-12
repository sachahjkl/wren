type: Added

**Sign in to sites with the Vault's passkeys** (`vault.passkeys.offer`): when a page asks for a passkey and the unlocked Vault holds passkeys of that site, Wren asks which to use: one of the Vault's (its item name and user name), or a security key or this device. The Vault signs the sign-in, and the page gets its passkey as from this device. A locked Vault, or one without a passkey of the site, asks nothing: the security key or this device answers as before. Creating a passkey still uses the security key or this device.
