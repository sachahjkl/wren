type: Added

**Managed Media Source Extensions** (`ManagedMediaSource`, `ManagedSourceBuffer`, `BufferedChangeEvent`): the variant where the user agent says when to stream. `ManagedMediaSource.streaming` and the `startstreaming` / `endstreaming` events follow how much is buffered ahead (`media.mse.managed.low_seconds` / `high_seconds`); a `ManagedSourceBuffer` fires `bufferedchange` with the ranges added and removed when its buffered ranges change.
