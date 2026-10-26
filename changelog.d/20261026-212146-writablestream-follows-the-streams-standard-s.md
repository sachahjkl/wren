type: Changed

**`WritableStream` follows the Streams Standard's algorithms**: the erroring state, one write or close in flight, `abort()` that waits for it and calls the sink's `abort`, the strategy's `size` and `highWaterMark`, backpressure through `desiredSize` and each writer's `ready`, each writer's own `closed`, and `controller.signal`. WPT `/streams/` (with `piping` now): 1662 of 2065 subtests, up from 1316 of 1565.
