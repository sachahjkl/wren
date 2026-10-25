package base

import "core:testing"

@(test)
perf_is_opt_in_and_never_on_the_ci :: proc(t: ^testing.T) {
	testing.expect(t, !perf_decide("", ""), "off by default")
	testing.expect(t, !perf_decide("0", ""), "WREN_PERF=0 is off")
	testing.expect(t, perf_decide("1", ""), "WREN_PERF=1 is on")
	testing.expect(t, perf_decide("true", ""), "WREN_PERF=true is on")
	testing.expect(t, !perf_decide("1", "true"), "the CI variable wins over WREN_PERF")
	testing.expect(t, !perf_decide("", "true"), "off on the CI")
}
