package license

// The public key licences are checked with (base64url of the 32 bytes of the Ed25519 public key). It is the half of
// the pair that cannot sign: it is safe in the repository and in every build.
//
// EMPTY until the production pair is made: with no key a build reads no licence (about:wren stays on "Unregistered") and
// says why when one is pasted. Make the pair with `tools\license.ps1 keygen` (docs/licence.md): it prints the line to
// put here. The private half stays outside the repository (%USERPROFILE%\.wren-license\private.key).
//
// browser.license.public_key (about:config) replaces it at run time, for trying a licence made with another pair
// (the tests, a fork that sells its own licences).
PRODUCTION_PUBLIC_KEY :: ""
