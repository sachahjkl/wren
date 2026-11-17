type: Fixed

**A failed passkey request names its real error again.** A site that asks to create a passkey that the authenticator already holds now gets InvalidStateError, and a site whose request is malformed gets its own error. On Windows, every failure came back as NotAllowedError.
