type: Added

**Security keys with a PIN on Linux**: when a site or the Vault asks for your security key and the key has a PIN, Wren asks for it in a dialog (again with the tries left after a wrong one), then you touch the key. The key also gives the PRF output now, so a YubiKey passkey can log in to and unlock the Vault.
