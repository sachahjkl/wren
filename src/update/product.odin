// What Wren is to the toolkit's update package (toolkit:update, docs/updates.md): its name in the manifests and the release's file
// names, what its signatures cover, and the public half of its update key (wrentool update keygen; the private half is in the release
// workflow's secrets and in secrets/production.yaml; it is not the key that signs licences). The browser checks with it
// (src/browser/update_install.odin), the release tool signs with it (src/tools/wrentool/release/update.odin). Wren has no channels.
package wren_update

import update "../../ext/gui_toolkit/src/update"

PRODUCT :: update.Product{
	name         = "wren",
	sign_context = "wren-update-v1\n",
	public_key   = "FFmnzv9bVZfK9x7LFk-R2M2m5SDs7YozvY46N17Hsws",
}
