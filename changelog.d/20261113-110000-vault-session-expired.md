type: Fixed

**The Vault's sync no longer fails with "401 Unauthorized"**: the helper keeps the server's new refresh token after every request, not only after a sync that succeeded, so the next unlock still has a valid session. When the server ends the session anyway, the Vault logs out and asks for the master password again, with the email filled in.
