type: Changed

**Vault: tokens in the system keyring**: the tokens that open your account on the server are now kept in the system's keyring (the Secret Service on Linux, the Credential Manager on Windows), or in a private file when no keyring answers, and no longer in the Vault's state file. After this update, log in to the Vault once more.
