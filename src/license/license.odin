package license

// Wren's support licence, as the toolkit's gt:licence describes a product: the browser checks it (license_shell.odin),
// wrentool license issues it, the shop's Worker (licence/worker) signs it. The format is the toolkit's, with Wren's own tag,
// signing context and extension: the licences already sold verify as before. It unlocks nothing; about:wren says who the
// supporter is. No network is used.

import licence "../../ext/gui_toolkit/src/licence"

// The public key licences are checked with (base64url of the Ed25519 public key): the half of the pair that cannot sign.
// browser.license.public_key replaces it at run time (a test, a fork that sells its own).
PRODUCTION_PUBLIC_KEY :: "6vZ2PkrA6JVQvH9T9O9wffaz_SmFcChOaHcMW61LoqI"

// A key pair for development (the tests, the experimental builds' demonstration licence), public on purpose: a release
// refuses its licences. DEV_SEED is base64url of "wren-dev-license-test-seed-0001!".
DEV_SEED :: "d3Jlbi1kZXYtbGljZW5zZS10ZXN0LXNlZWQtMDAwMSE"
DEV_PUBLIC_KEY :: "NLbdwv2jpoDIMu5pVxyjYBUMEu2Lvfd8StzxR0PGqs8"
// A second pair, for "signed by somebody else" tests: "wren-other-license-key-0000002!!".
OTHER_DEV_SEED :: "d3Jlbi1vdGhlci1saWNlbnNlLWtleS0wMDAwMDAyISE"

WREN :: licence.Product{
	name           = "wren",
	title          = "Wren",
	version_tag    = "WREN1",
	sign_context   = "wren-license-v1\n",
	file_extension = ".wrenlicense",
	public_key     = PRODUCTION_PUBLIC_KEY,
	dev_public_key = DEV_PUBLIC_KEY,
	editions       = {0 = {id = "supporter", title = "Supporter"}, 1 = {id = "patron", title = "Patron"}},
}
