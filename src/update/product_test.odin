package wren_update

import "core:testing"
import signing "../../ext/gui_toolkit/src/signing"

@(test)
the_update_key_is_a_key :: proc(t: ^testing.T) {
	_, ok := signing.key_decode(PRODUCT.public_key)
	testing.expect(t, ok, "32 bytes of base64url")
}
