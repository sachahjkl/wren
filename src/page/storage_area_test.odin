package page

import "core:fmt"
import "core:testing"

// Removing keys moves the last item into the gap: the index still names each item's position, and the area's size
// in UTF-16 units follows.
@(test)
storage_area_remove_keeps_the_index :: proc(t: ^testing.T) {
	a := new(Storage_Area)
	defer area_free(a)
	N :: 1000
	for i in 0 ..< N { area_put(a, fmt.tprintf("k%d", i), "vé𝄞") }
	for i := 0; i < N; i += 2 { testing.expect(t, area_remove(a, fmt.tprintf("k%d", i))) }
	testing.expect(t, !area_remove(a, "k0"))
	testing.expect_value(t, len(a.items), N / 2)
	testing.expect_value(t, len(a.index), N / 2)
	used := 0
	for it, i in a.items {
		testing.expect_value(t, a.index[it.key], i)
		used += utf16_length(it.key) + utf16_length(it.value)
	}
	testing.expect_value(t, a.used, used)
	testing.expect_value(t, utf16_length("vé𝄞"), 4)
}
