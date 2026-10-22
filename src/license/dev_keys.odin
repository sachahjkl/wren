package license

// A key pair for development: the tests, screenshots of about:wren with a licence (`tools\license.ps1 issue -dev`,
// browser.license.public_key = `tools\license.ps1 pubkey -dev`). It is public on purpose and means nothing: the
// production public key (public_key.odin) is another pair, so a licence made with this one is refused by a build that
// carries the production key.
DEV_SEED       := [32]byte{'w','r','e','n','-','d','e','v','-','l','i','c','e','n','s','e','-','t','e','s','t','-','s','e','e','d','-','0','0','0','1','!'}
// A second pair, for "signed by somebody else" tests.
OTHER_DEV_SEED := [32]byte{'w','r','e','n','-','o','t','h','e','r','-','l','i','c','e','n','s','e','-','k','e','y','-','0','0','0','0','0','0','2','!','!'}
