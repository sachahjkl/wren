type: Added

**TransformStream**, `TextDecoderStream` and `TextEncoderStream`: the transformer's `start` / `transform` / `flush` / `cancel`, `TransformStreamDefaultController` (`enqueue`, `error`, `terminate`, `desiredSize`), backpressure from the readable side to the writable one, both strategies, `pipeThrough()` into them; text decoded across chunks in any encoding (fatal, ignoreBOM), a surrogate pair cut between two chunks encoded whole.
