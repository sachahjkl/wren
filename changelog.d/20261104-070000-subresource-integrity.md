type: Security

**Subresource Integrity everywhere**: `fetch(url, {integrity})` rejects a response whose body does not match its sha256 / sha384 / sha512 hash (base64 or base64url), `<script type="module" integrity>` checks its module, and `<link rel="stylesheet" integrity>` refuses a stylesheet that does not match, as classic scripts already did.
