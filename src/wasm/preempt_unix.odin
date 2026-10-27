#+build linux, darwin, freebsd, openbsd, netbsd
package wasm

import "core:time"

// nanosleep is high-resolution already (hrtimers on Linux): no timer object to keep.
@(private)
ticker_sleep :: proc(ms: int) { time.sleep(time.Duration(ms) * time.Millisecond) }

@(private)
ticker_sleep_destroy :: proc() {}
