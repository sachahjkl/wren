type: Fixed

**Licence Worker order object** (`LicenseOrder`) : a transaction that first arrived without a customer e-mail (answered 422) and was redelivered with one is now issued instead of crashing, and the KV copy the thank-you page reads is written for every mail state, the "skipped" state (no `EMAIL` binding or `MAIL_FROM`) included, so `txn:<id>` is never missing.
