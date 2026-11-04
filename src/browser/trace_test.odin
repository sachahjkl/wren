package browser

// Every phase of a frame is a region WPA can show (tools/wren_regions.xml): the Start and the Stop of its zone.

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file") REGIONS :: #load("../../tools/wren_regions.xml", string)

@(test)
every_phase_is_a_region_of_wpa :: proc(t: ^testing.T) {
	for p in Phase {
		if p == .None { continue }
		for opcode in ([]int{1, 2}) {
			event := fmt.tprintf(`Name="%v" Opcode="%d"`, p, opcode)
			testing.expectf(t, strings.contains(REGIONS, event), "tools/wren_regions.xml has %s", event)
		}
	}
}
