package update

// The public key the update manifests are checked with (base64url of the 32 bytes of the Ed25519 public key). It is the half of
// the pair that cannot sign: it is safe in the repository and in every build. It is not the licence key.
//
// EMPTY until the pair is made: a build with no key refuses every update (it says so). Make the pair with
// `wrentool update keygen -private FILE` (docs/updates.md): it prints the line to put here. The private half is kept in
// secrets/production.yaml (UPDATE_SIGNING_KEY, encrypted) and in the release workflow's secret WREN_UPDATE_SIGNING_KEY.
//
// browser.update.public_key (about:config) replaces it at run time, for trying a release made with another pair (the tests).
UPDATE_PUBLIC_KEY :: "FFmnzv9bVZfK9x7LFk-R2M2m5SDs7YozvY46N17Hsws"
