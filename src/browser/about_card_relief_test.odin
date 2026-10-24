package browser

import "core:strings"
import "core:testing"

@(test)
the_relief_of_the_card_is_three_pictures_and_the_same_every_time :: proc(t: ^testing.T) {
	a := card_relief()
	b := card_relief()
	for u in ([]string{a.emboss, a.toward, a.away}) {
		testing.expect(t, strings.has_prefix(u, "data:image/png;base64,"), "a picture is a PNG data: URL")
		testing.expect(t, len(u) > 5000, "a picture holds the relief, not an empty square")
	}
	testing.expect(t, a.toward != a.away, "the slopes that face the sheen are not those that turn away from it")
	testing.expect(t, a.emboss != a.toward, "the embossing is not a mask")
	testing.expect(t, a.emboss == b.emboss && a.toward == b.toward && a.away == b.away, "no randomness: the same pictures at every build")
}

@(test)
the_card_css_carries_the_relief_and_the_sheen :: proc(t: ^testing.T) {
	css := card_css()
	for want in ([]string{"@keyframes sheen", ".lic .sha", ".lic .shb", ".lic .shc", "mask-image: url(\"data:image/png;base64,", ".lic .rel { background-image: url(\"data:image/png;base64,", "prefers-reduced-motion", ".lic.live .sha"}) {
		testing.expectf(t, strings.contains(css, want), "the card's style lacks %q", want)
	}
	testing.expect(t, strings.count(css, "mask-image: url(") == 2, "a mask for each side of the slopes")
}